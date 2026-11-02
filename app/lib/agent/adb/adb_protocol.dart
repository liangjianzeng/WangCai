/// ADB 线协议编解码 —— app 内直连其他手机的 **零依赖协议层**。
///
/// 为什么不用 adb 二进制：targetSdk 34 的 W^X 约束下 app 数据目录不可 exec
/// （见 AGENTS「L1 内嵌沙箱」定案），jniLibs 白名单位置塞不进动态链接的 adb；
/// 唯一可行且可离线验证的路子是把协议在 Dart 里实现一遍。协议本体很简单
/// （24 字节头 + payload 的固定帧），复杂度全在 RSA 认证（见 adb_rsa.dart）。
///
/// 帧格式（全部小端）：
/// ```text
/// command(4) arg0(4) arg1(4) data_length(4) data_check(4) magic(4) [payload]
/// ```
/// `data_check` = payload 字节和；`magic` = `command ^ 0xffffffff`。adbd 对
/// 两者都校验，任一不符即**直接断开连接**（不给错误码），所以解码必须自检。
///
/// 本文件刻意不 import dart:io / flutter —— 协议单测可纯 Dart 跑。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 消息头长度（字节）。
const int kAdbHeaderSize = 24;

/// 协议版本（adb 的 `A_VERSION`，1.0）。
const int kAdbVersion = 0x01000001;

/// 我方声明的单包上限。adbd 侧常见为 256KB（新版 1MB），取小端协商 min。
const int kAdbMaxData = 256 * 1024;

/// CNXN 横幅。声明 shell_v2（拿到 stderr 与退出码）+ cmd + stat_v2。
///
/// 只声明**真的实现了的**特性：`reversed`（adbd 反向连我们）、`sendrecv` 等
/// 一律不报——报而不实现会让 adbd 按新语义发帧，症状是"连上但一切命令无输出"。
// 只广告**真实现了**的特性：广告了 stat_v2/ls_v2，adbd 就会用 v2 的
// file_attr 结构（32/64 字节）回 STA/DIR，我们的 v1 解包直接错位（真机踩过）。
// 真 adb 广告一大串是因为它全实现了；我们按最小可信集来。
const String kAdbBanner = 'host::features=shell_v2,cmd';

/// 协议命令（fourcc）。注意 ADB 是把 ASCII 四字符按小端读成 uint32，
/// 这里直接用 [fourcc] 现算，避免手抄常量出错。
class AdbCommand {
  static const int sync = 0x434e5953; // 'SYNC'（历史遗留，未使用）
  static const int cnxn = 0x4e584e43; // 'CNXN'
  static const int open = 0x4e45504f; // 'OPEN'
  static const int okay = 0x59414b4f; // 'OKAY'
  static const int clse = 0x45534c43; // 'CLSE'
  static const int wrte = 0x45545257; // 'WRTE'
  static const int auth = 0x48545541; // 'AUTH'
  static const int stls = 0x534c5453; // 'STLS'（Android 11+ 无线调试 TLS，未实现）
}

/// AUTH 子类型。
class AdbAuth {
  static const int token = 1; // adbd → host：20 字节随机 token
  static const int signature = 2; // host → adbd：RSA 签名
  static const int rsaPublicKey = 3; // host → adbd：公钥 blob（触发用户授权弹窗）
}

/// shell_v2 子帧 id —— 对应 adbd `services.cpp` 的 **legacy** shell_v2
/// （即 `shell,v2,raw:` 走的那条路，不是 `shell_service_v2.cpp` 的 SUBCMD 套娃版）。
///
/// 数值以 2026-10-27 真机抓包为准（`01 …"PROBE_OK\n"` / `03 01000000 00` /
/// 客户端发 `04 00000000`），不是照抄某版头文件：网上流传的 "stdout=0,stdin=1"
/// 与 "SUBCMD 从 0 起" 两套写法在真机上都会解出乱码。
class ShellPacketId {
  static const int stdin = 0;
  static const int stdout = 1;
  static const int stderr = 2;
  static const int exit = 3;
  static const int closeStdin = 4;
  static const int windowSizeAdjust = 5;
}

/// 协议层异常（解码失败 / 对端异常关流 / 认证被拒）。
class AdbProtocolException implements Exception {
  final String message;
  const AdbProtocolException(this.message);
  @override
  String toString() => 'AdbProtocolException: $message';
}

/// 四字符命令 → uint32（小端读法，与 adbd 一致）。
int fourcc(String tag) {
  if (tag.length != 4) {
    throw ArgumentError('fourcc 需要 4 个 ASCII 字符：$tag');
  }
  final b = tag.codeUnits;
  return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
}

/// 一条完整消息。
class AdbMessage {
  final int command;
  final int arg0;
  final int arg1;
  final Uint8List payload;

  const AdbMessage(this.command, this.arg0, this.arg1, this.payload);

  factory AdbMessage.create(
          int command, int arg0, int arg1, [List<int> payload = const []]) =>
      AdbMessage(
        command,
        arg0,
        arg1,
        payload is Uint8List ? payload : Uint8List.fromList(payload),
      );

  /// payload 按 UTF-8 宽松解码（服务名、横幅、shell 文本输出等场景；
  /// 二进制场景一律直接用 [payload]，别过这个 getter——exec-out 的 PNG
  /// 走 String 会当场损坏）。
  String get text => utf8.decode(payload, allowMalformed: true);

  @override
  String toString() =>
      'AdbMessage(${commandName(command)}, arg0=$arg0, arg1=$arg1, len=${payload.length})';
}

/// 命令名（日志/错误信息用）。
String commandName(int command) {
  const names = {
    AdbCommand.cnxn: 'CNXN',
    AdbCommand.open: 'OPEN',
    AdbCommand.okay: 'OKAY',
    AdbCommand.clse: 'CLSE',
    AdbCommand.wrte: 'WRTE',
    AdbCommand.auth: 'AUTH',
    AdbCommand.stls: 'STLS',
  };
  return names[command] ?? '0x${command.toRadixString(16)}';
}

/// payload 校验和（字节和，mod 2^32）。
int adbChecksum(List<int> payload) {
  var sum = 0;
  for (final b in payload) {
    sum = (sum + b) & 0xffffffff;
  }
  return sum;
}

/// 编码一条消息（含 payload）。
Uint8List adbEncode(AdbMessage m) {
  final out = Uint8List(kAdbHeaderSize + m.payload.length);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, m.command, Endian.little);
  bd.setUint32(4, m.arg0, Endian.little);
  bd.setUint32(8, m.arg1, Endian.little);
  bd.setUint32(12, m.payload.length, Endian.little);
  bd.setUint32(16, adbChecksum(m.payload), Endian.little);
  bd.setUint32(20, (~m.command) & 0xffffffff, Endian.little);
  out.setRange(kAdbHeaderSize, out.length, m.payload);
  return out;
}

/// 解码结果（头 + 已按长度取出的 payload）。
class AdbDecoded {
  final AdbMessage message;
  final int consumed;
  const AdbDecoded(this.message, this.consumed);
}

/// 尝试从缓冲区头部解出一条消息；数据不足返回 null（等待更多字节）。
///
/// ## 入站帧**不**严格校验校验和 —— 2026-10-27 真机（小米13 / 100.109.138.2:5555）定案
/// 真 adbd 发来的 **AUTH(TOKEN) 帧 `data_check` 字段是 0**，而载荷真实字节和是 0x83e
/// （线上原始帧头：`41555448 01000000 00000000 14000000 00000000 beaaabb7`）。
/// 原因在 AOSP 侧：apacket 先分配、token 后生成，发送前没人回填这个字段。
/// 入站若严格校验 → 第一次握手就被自己拒了（真机 host adb 同样不校验）。
///
/// 对齐性靠什么保证？靠 **magic = ~command**（32 位反码，字节流跑偏后几乎不可能命中）
/// 加长度上限。magic 不符 → 抛 [AdbProtocolException]（与 adbd 一样直接断链，
/// 绝不把跑偏的字节流当正常帧继续读）。[requireChecksum] 仅供单测自检使用。
AdbDecoded? adbTryDecode(List<int> buffer, {bool requireChecksum = false}) {
  if (buffer.length < kAdbHeaderSize) return null;
  final bd = ByteData.sublistView(
      buffer is Uint8List ? buffer : Uint8List.fromList(buffer), 0, kAdbHeaderSize);
  final command = bd.getUint32(0, Endian.little);
  final arg0 = bd.getUint32(4, Endian.little);
  final arg1 = bd.getUint32(8, Endian.little);
  final length = bd.getUint32(12, Endian.little);
  final check = bd.getUint32(16, Endian.little);
  final magic = bd.getUint32(20, Endian.little);
  if (magic != ((~command) & 0xffffffff)) {
    throw const AdbProtocolException('帧 magic 不匹配（字节流已跑偏）');
  }
  // 单帧上限兜 4MB：异常长度（跑偏字节流）不该让我们无界缓冲。
  if (length > 4 * 1024 * 1024) {
    throw AdbProtocolException('非法帧长度 $length');
  }
  if (buffer.length < kAdbHeaderSize + length) return null;
  final payload = Uint8List.fromList(
      buffer.sublist(kAdbHeaderSize, kAdbHeaderSize + length));
  if (requireChecksum && check != 0 && adbChecksum(payload) != check) {
    // 诊断信息带帧头：真机排障时"哪条帧、什么命令、长度多少"决定是不是
    // 我们自己把流读跑偏了（历史上 shell_v2 封装猜错过一次，全靠这行看出来）。
    final hex = payload
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    throw AdbProtocolException('载荷校验和不匹配：${commandName(command)} '
        'arg0=$arg0 arg1=$arg1 len=$length expect=0x${check.toRadixString(16)} '
        'got=0x${adbChecksum(payload).toRadixString(16)} head=$hex');
  }
  return AdbDecoded(AdbMessage(command, arg0, arg1, payload), kAdbHeaderSize + length);
}

// ---------------------------------------------------------------------------
// shell_v2 子帧
// ---------------------------------------------------------------------------

/// shell_v2 子帧头长度：`uint8_t id` + `uint32_t payload_size`（小端，packed，无 seq）。
///
/// **2026-10-27 真机取证定案**（代理抓 `adb 1.0.41` ↔ adbd 小米13 的线上字节）：
/// ```text
/// 01 09000000 50524f42455f4f4b0a   → STDOUT(1) size=9 "PROBE_OK\n"
/// 03 01000000 00                   → EXIT(3)   size=1 exit=0
/// 04 00000000                       → CLOSE_STDIN(4) size=0（客户端发完 stdin 后发它）
/// ```
/// 不少第三方实现把这里写成 `id + seq`（照抄早期文档），真机上会解出乱码 ——
/// 这里以线上取证为准，单测里也用这几串真实字节做回归向量。
const int kShellPacketHeaderSize = 5;

/// shell_v2 的一个子帧。
class ShellPacket {
  final int id;
  final Uint8List payload;
  const ShellPacket(this.id, this.payload);

  /// 退出码子帧的载荷（1 字节）；非 EXIT 帧返回 null。
  int? get exitCode =>
      id == ShellPacketId.exit && payload.isNotEmpty ? payload[0] : null;
}

/// 编码 shell_v2 子帧（写 stdin / closeStdin 用）。
Uint8List shellPacketEncode(int id, [List<int> payload = const []]) {
  final out = Uint8List(kShellPacketHeaderSize + payload.length);
  out[0] = id & 0xff;
  ByteData.sublistView(out).setUint32(1, payload.length, Endian.little);
  out.setRange(kShellPacketHeaderSize, out.length, payload);
  return out;
}

/// 从连续字节流里增量解出 shell_v2 子帧。
///
/// adbd 会把多个子帧塞进同一个 WRTE（上面取证里 stdout+stdout 就是分两帧来的），
/// 也可能把一帧拆到两个 WRTE，所以必须基于**累积缓冲区**解帧，
/// 绝不能"一个 WRTE 当一个子帧"。
class ShellPacketDecoder {
  final _buf = BytesBuilder(copy: true);

  /// 追加字节并返回本次可解出的所有完整子帧。
  List<ShellPacket> feed(List<int> bytes) {
    _buf.add(bytes);
    final data = _buf.toBytes();
    final out = <ShellPacket>[];
    var off = 0;
    while (data.length - off >= kShellPacketHeaderSize) {
      final size =
          ByteData.sublistView(data, off + 1, off + 5).getUint32(0, Endian.little);
      // 尺寸明显跑偏（adbd 不会发 >maxdata 的子帧）说明流已错位，抛出去比
      // 无界缓冲一个 4GB 的"载荷"要好。
      if (size > kAdbMaxData) {
        _buf.clear();
        throw AdbProtocolException('shell_v2 子帧长度异常：$size（字节流已跑偏）');
      }
      if (data.length - off - kShellPacketHeaderSize < size) break; // 等更多字节
      out.add(ShellPacket(
          data[off],
          Uint8List.fromList(data.sublist(
              off + kShellPacketHeaderSize, off + kShellPacketHeaderSize + size))));
      off += kShellPacketHeaderSize + size;
    }
    _buf.clear();
    if (off < data.length) _buf.add(data.sublist(off));
    return out;
  }

  void reset() => _buf.clear();
}

// ---------------------------------------------------------------------------
// sync: 子协议（push / pull）
// ---------------------------------------------------------------------------

/// sync 子协议的请求消息。
///
/// **请求侧只有 8 字节头**（`id(4) + arg0(4)`，小端），随后紧跟变长体 ——
/// 与"回复侧"结构不同（回复头长随 id 变，见 adb_client._SyncReader）。
/// 各命令 arg0 的语义（真机 2026-10-27 实测 + `file_sync_service.h`）：
/// - `SEND`：**路径长度**，随后是 `"<路径>,<st_mode 十进制>"` 字节 —— adbd 的 SEND
///   **没有独立 mode 字段**，权限以 `0o100000|权限` 的十进制形式拼在路径尾部
///   （真机抓 `adb push` 取证：`SEND u32(35) "/data/local/tmp/x.bin,33188"`）。
///   曾按 `(mode<<16)|pathlen` 的 16 字节头写 → adbd 把路径前 4 字节当长度 →
///   `FAIL "path too long"`。
/// - `DATA`：本段字节数；`DONE`：mtime（秒）
/// - `RECV` / `LIST`：路径长度，随后路径；`STAT`：路径长度，随后路径
/// - `QUIT`：只有 4 字节 id（[syncEncodeQuit]）
class SyncMessage {
  final String id;
  final int arg0;
  final Uint8List payload;

  const SyncMessage(this.id, this.arg0, this.payload);

  factory SyncMessage.create(String id, int arg0, [List<int> payload = const []]) =>
      SyncMessage(id, arg0,
          payload is Uint8List ? payload : Uint8List.fromList(payload));
}

/// 编码 sync 请求（8 字节头 + 变长体）。
Uint8List syncEncode(SyncMessage m) {
  final out = Uint8List(8 + m.payload.length);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < 4; i++) {
    out[i] = m.id.codeUnitAt(i) & 0xff;
  }
  bd.setUint32(4, m.arg0, Endian.little);
  out.setRange(8, out.length, m.payload);
  return out;
}

/// `QUIT` 只有 id 四个字节（adbd 读到它就退出 sync 循环）。
Uint8List syncEncodeQuit() => syncEncode(SyncMessage('QUIT', 0, Uint8List(0)));

/// 解析 sync **回复**头（8 字节：id + 一个 u32；其后的变长体由调用方按 id 读取）。
({String id, int a0})? syncTryDecodeReplyHeader(List<int> buffer) {
  if (buffer.length < 8) return null;
  final bd = ByteData.sublistView(
      buffer is Uint8List ? buffer : Uint8List.fromList(buffer), 0, 8);
  return (id: String.fromCharCodes(buffer.sublist(0, 4)), a0: bd.getUint32(4, Endian.little));
}

/// sync 权限常量（push 默认 0644，可执行文件用 0755）。
const int kSyncModeFile = 0x1a4; // 0644
const int kSyncModeExec = 0x1ed; // 0755

/// CNXN 横幅解析：`host::features=a,b;ro.product.model=X` → map。
///
/// adbd 侧字段分隔历史上混用 `;` 与空格，两者都吃；`features=` 单独成键。
Map<String, String> adbParseBanner(String banner) {
  var s = banner;
  // 我方发 `host::features=…`，adbd 回 `device::ro.product.model=…`：
  // 前缀一律剥掉，否则第一个键变成 device::ro.product.model（真机实测属性全 null）。
  final sep = s.indexOf('::');
  if (sep >= 0 && sep <= 8 && !s.substring(0, sep).contains('=')) s = s.substring(sep + 2);
  final out = <String, String>{};
  for (final part in s.split(RegExp(r'[;\s]+'))) {
    if (part.isEmpty) continue;
    final i = part.indexOf('=');
    if (i <= 0) continue;
    out[part.substring(0, i)] = part.substring(i + 1);
  }
  return out;
}
