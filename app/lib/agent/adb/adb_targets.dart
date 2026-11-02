/// ADB 目标机配置与设备授权密钥托管。
///
/// 两块职责，都刻意与协议层（[adb_protocol.dart] / [adb_connection.dart]）分离：
/// 1. **[AdbTarget]** —— 用户在设置页维护的"可控制哪些手机"白名单。工具层
///    只允许连这里的条目，模型无权自己指定任意 IP（防被提示词注入拿去扫内网）。
/// 2. **密钥托管** —— app 首次使用时生成**一把**RSA 密钥对并存进安全存储，
///    之后所有目标机共用它授权（与 `~/.android/adbkey` 同构）。密钥是私钥，
///    绝不落 settings JSON —— 照 SSH 凭据的既有做法走 [AdbSecretStore]。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'adb_rsa.dart';

/// 一台可控制的/target 手机（Wi-Fi ADB）。
class AdbTarget {
  final String id;
  final String name;

  /// IP 或主机名（Tailscale 网段内直连）。
  final String host;
  final int port;

  /// 关掉 = 不出现在设备发现里，工具也连不上（比删除更快，保留 IP 备用）。
  final bool enabled;

  const AdbTarget({
    required this.id,
    required this.name,
    required this.host,
    this.port = 5555,
    this.enabled = true,
  });

  /// `ip:port`，与 `adb devices -l` 的序列号同形，模型看到的也是它。
  String get serial => '$host:$port';

  AdbTarget copyWith(
          {String? name,
          String? host,
          int? port,
          bool? enabled,
          String? id}) =>
      AdbTarget(
        id: id ?? this.id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        enabled: enabled ?? this.enabled,
      );

  @override
  bool operator ==(Object o) =>
      o is AdbTarget &&
      o.id == id &&
      o.name == name &&
      o.host == host &&
      o.port == port &&
      o.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, name, host, port, enabled);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'enabled': enabled,
      };

  factory AdbTarget.fromJson(Map<String, dynamic> json) => AdbTarget(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        host: '${json['host'] ?? ''}'.trim(),
        port: (json['port'] as num?)?.toInt() ?? 5555,
        enabled: json['enabled'] != false,
      );

  /// 从 `192.168.1.30:5555` / `192.168.1.30` 解析出 host/port（设置页快捷输入）。
  static ({String host, int port})? parseSerial(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final i = t.lastIndexOf(':');
    if (i <= 0) return (host: t, port: 5555);
    final host = t.substring(0, i).trim();
    final port = int.tryParse(t.substring(i + 1));
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    return (host: host, port: port);
  }
}

/// 解析设置 JSON 里的目标表（脏数据一律跳过，不让一条坏记录毁掉整个设置加载）。
List<AdbTarget> parseAdbTargets(dynamic raw) {
  if (raw is! List) return const [];
  final out = <AdbTarget>[];
  final seen = <String>{};
  for (final e in raw) {
    if (e is! Map) continue;
    final t = AdbTarget.fromJson(Map<String, dynamic>.from(e));
    if (t.host.isEmpty || !seen.add(t.serial)) continue;
    out.add(t.id.isEmpty
        ? t.copyWith(id: 'adb-${out.length}-${t.serial.hashCode.abs()}')
        : t);
  }
  return out;
}

// ---------------------------------------------------------------- 密钥托管

/// 抽象存储（生产 = flutter_secure_storage / EncryptedSharedPreferences，
/// 测试 = 内存实现）。键名统一加 `adb_` 前缀，与 SSH 凭据分区不互相踩。
abstract class AdbSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterAdbSecretStore implements AdbSecretStore {
  final FlutterSecureStorage _storage;
  FlutterAdbSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'adb_';

  @override
  Future<String?> read(String key) =>
      _storage.read(key: '$_prefix$key').catchError((_) => null);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: '$_prefix$key', value: value);

  @override
  Future<void> delete(String key) =>
      _storage.delete(key: '$_prefix$key').catchError((_) {});
}

/// 测试/无安全存储平台用的内存实现。
class InMemoryAdbSecretStore implements AdbSecretStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

/// app 自有设备授权私钥在安全存储里的键（**全局一把**，不分目标机）。
const String kAdbKeySlot = 'rsa_key_pkcs1';

/// 取本 app 的设备授权密钥；**首次调用时生成并落盘**。
///
/// 2048 位是 adb 的标准位长（`adbkey` 就是 2048），别为了省启动时间降到 1024：
/// 部分 ROM 的 adbd 会直接拒绝短密钥。生成只在第一次发生，且是在设置页
/// 点「生成密钥」时同步做，不在回合里做。
Future<AdbRsaKeyPair> loadOrCreateAdbKey(AdbSecretStore store,
    {int bits = 2048}) async {
  final pem = await store.read(kAdbKeySlot);
  if (pem != null && pem.trim().isNotEmpty) {
    try {
      return AdbRsaKeyPair.fromPem(pem);
    } on FormatException {
      // 存坏了（手改过/截断）不静默重建：那会让所有已授权设备集体掉授权，
      // 用户必须在设置页明确看到并重新一键授权。
      rethrow;
    }
  }
  final fresh = AdbRsaKeyPair.generate(bits: bits);
  await store.write(kAdbKeySlot, fresh.toPem());
  return fresh;
}

/// 导入用户已有的 `~/.android/adbkey`（那台机器上早已授权过的手机可免重新弹窗）。
///
/// 先解析再落盘：塞进去一个解不开的 PEM，等于把所有目标机变成"连不上且不知道为什么"。
Future<void> importAdbPrivateKeyPem(AdbSecretStore store, String pem) async {
  final parsed = AdbRsaKeyPair.fromPem(pem); // 解析失败直接抛给 UI 显示
  await store.write(kAdbKeySlot, parsed.toPem());
}

/// 公钥的 adb 线上形态（设置页展示，便于和 `~/.android/adbkey.pub` 比对是否同一把）。
String adbPublicKeyLine(AdbRsaKeyPair key) =>
    '${key.publicKeyBase64()} tongyi-lite@app';

/// 公钥指纹（线上形态的前 8 字节 hex）：给 UI 做"这是哪把钥匙"的肉眼标识，
/// 与 `adbkey.pub` 对同一把钥匙时该串必须一致。
String adbKeyFingerprint(AdbRsaKeyPair key) {
  final blob = base64.decode(key.publicKeyBase64());
  final sb = StringBuffer();
  for (final b in blob.take(8)) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
