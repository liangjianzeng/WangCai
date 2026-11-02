/// ADB RSA 认证 —— app 内自持密钥的**零依赖**实现。
///
/// ## 为什么必须自己实现
/// adbd 的认证只认 RSA-2048/4096 + PKCS#1 v1.5(SHA-1) 裸模幂（mincrypt 那套），
/// 而 pubspec 里只有 pinenacl（ed25519）与 crypto（哈希），没有任何 RSA 库；
/// 为一个认证环节引 pointycastle 不划算，Dart 的 [BigInt.modPow] 已够用
/// （实测本机 RSA-2048 单素数生成 ~15ms、单次签名 ~30µs）。
///
/// ## 线格式（用真机 `~/.android/adbkey.pub` 逐字节反解验证，非照抄文档）
/// AUTH(RSAPUBLICKEY) 的 payload = **base64(下面这个结构)**，全部小端、**不做整体反转**：
/// ```text
/// u32 len      = bits / 32            （2048 位 → 64）
/// u32 n0inv    = -n[0]^{-1} mod 2^32
/// u32 n[len]   = 模数，32 位字小端数组
/// u32 rr[len]  = R^2 mod n，R = 2^(8*keyBytes)（Montgomery 常量，adbd 自校验用）
/// u32 exponent = 65537
/// ```
/// AUTH(SIGNATURE) 的 payload = **256 字节标准大端 PKCS#1 v1.5 签名**，
/// 且**签名对象是 token 原文，不是 sha1(token)** —— adbd 生成的 token 本身就已经是
/// 20 字节 SHA-1 摘要，adb 直接把它当 digest 塞进 DigestInfo。
///
/// 这两条不是抄来的：2026-10-27 用 TCP 代理抓了真 `adb 1.0.41` ↔ 真 adbd（小米13）
/// 的 AUTH 帧，拿真签名做 `S^e mod n` 反推出 EMSA：
/// ```text
/// 00 01 FF..FF 00 | 3021300906052b0e03021a05000414 | <20 字节 token 原文>
/// ```
/// 再 hash 一次 = 签名对不上 = adbd 反复重发 TOKEN、最后弹框/断链（当时就是这症状）。
/// 单测 `test/agent/adb_rsa_test.dart` 把这条抓包固化成回归向量，防再次想当然。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// PKCS#1 v1.5 的 SHA-1 DigestInfo 前缀（15 字节，RFC 8017 定值）。
const List<int> _kSha1DigestInfoPrefix = [
  0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, //
  0x05, 0x00, 0x04, 0x14,
];

/// 试除用的小素数表（先筛掉 ~80% 候选，比直接 Miller-Rabin 快一个量级）。
final List<int> _kSmallPrimes = () {
  const limit = 1000;
  final sieve = List<bool>.filled(limit, true);
  final out = <int>[];
  for (var i = 2; i < limit; i++) {
    if (sieve[i]) {
      out.add(i);
      for (var j = i * i; j < limit; j += i) {
        sieve[j] = false;
      }
    }
  }
  return out;
}();

/// ADB 用的 RSA 密钥对（自生成或从 `~/.android/adbkey` 导入）。
class AdbRsaKeyPair {
  final BigInt n;
  final BigInt e;
  final BigInt d;
  final BigInt p;
  final BigInt q;

  const AdbRsaKeyPair({
    required this.n,
    required this.e,
    required this.d,
    required this.p,
    required this.q,
  });

  /// 模数位长（2048 / 4096）。
  int get bitLength => n.bitLength;

  /// 模数字节数（2048 位 → 256）。
  int get keyBytes => (bitLength + 7) ~/ 8;

  /// 生成新密钥对。
  ///
  /// [bits] 支持 2048/4096；真机默认 2048（**更快且 adbd 全版本兼容**——
  /// 部分 ROM 的 adbd 对 4096 位密钥的 mincrypt 校验有兼容问题）。
  /// 端侧实测 2048 位生成在手机上亚秒级，无需后台化。
  factory AdbRsaKeyPair.generate({int bits = 2048, Random? random}) {
    if (bits % 1024 != 0 || bits < 1024) {
      throw ArgumentError('bits 需为 1024 的整数倍：$bits');
    }
    final rnd = random ?? Random.secure();
    final half = bits ~/ 2;
    final e = BigInt.from(65537);
    while (true) {
      final p = _generatePrime(half, rnd);
      final q = _generatePrime(half, rnd);
      if (p == q) continue;
      final phi = (p - BigInt.one) * (q - BigInt.one);
      if (phi.gcd(e) != BigInt.one) continue; // 极罕见：e 整除 phi，重摇
      final n = p * q;
      if (n.bitLength != bits) continue; // 两个素数最高位都置了 1，正常不会掉
      final d = e.modInverse(phi);
      return AdbRsaKeyPair(n: n, e: e, d: d, p: p, q: q);
    }
  }

  /// 从 PEM 私钥导入（兼容 adb 的 `BEGIN RSA PRIVATE KEY`（PKCS#1）
  /// 与 `BEGIN PRIVATE KEY`（PKCS#8 包 PKCS#1）两种形态）。
  ///
  /// 用途：目标手机已信任某台 PC 的 `~/.android/adbkey`（ rooted 设备写过
  /// adb_keys、或就想复用 PC 密钥）时，用户把该 PEM 贴进设置即可直连，
  /// 省掉一次"允许调试"弹窗。
  factory AdbRsaKeyPair.fromPem(String pem) {
    // 真机 `~/.android/adbkey` 里 **同时**有 RSA PRIVATE KEY 段和 PUBLIC KEY 段，
    // 只取第一个私钥块（把两段 base64 拼一起必然解不出来）。
    final blocks = RegExp(
      r'-----BEGIN ([A-Z ]*PRIVATE KEY)-----([\s\S]*?)-----END \1-----',
    ).firstMatch(pem.replaceAll('\r\n', '\n'));
    if (blocks == null) {
      throw const FormatException(
          'PEM 里找不到私钥块（需要 -----BEGIN RSA PRIVATE KEY----- 或 '
          '-----BEGIN PRIVATE KEY-----；adbkey.pub 是公钥，不能用来认证）');
    }
    final body = blocks.group(2)!.replaceAll(RegExp(r'\s'), '');
    if (body.isEmpty) {
      throw const FormatException('PEM 私钥块为空');
    }
    Uint8List der;
    try {
      der = base64.decode(body);
    } on FormatException {
      throw const FormatException('PEM base64 解析失败（粘贴时是否被截断？）');
    }
    final seq = _Der.readSequence(der);
    var ints = _Der.readIntegers(seq);
    if (ints.length < 9) {
      // PKCS#8（现代 adb 的 `~/.android/adbkey` 就是这形态，头是 `BEGIN PRIVATE KEY`）：
      // SEQUENCE { INTEGER version, SEQUENCE algid, OCTET STRING{PKCS#1} }
      try {
        final inner = _Der.readOctetString(seq);
        ints = _Der.readIntegers(_Der.readSequence(inner));
      } on FormatException {
        // 落到下面的统一报错，别在这里抛"找不到 OCTET STRING"迷惑用户
      }
    }
    // PKCS#1 RSAPrivateKey：version, n, e, d, p, q, dp, dq, qinv —— **version 在前**，
    // 早先按 ints[0]=n 取会整把钥匙错位（表现 = adbd 反复拒绝认证）。
    if (ints.length < 9) {
      throw FormatException('不是 RSA 私钥（解出 ${ints.length} 个整数字段，需 9 个）');
    }
    return AdbRsaKeyPair(
      n: ints[1],
      e: ints[2],
      d: ints[3],
      p: ints[4],
      q: ints[5],
    );
  }

  /// 导出 PKCS#1 PEM（与 `~/.android/adbkey` 同格式，可拷去别的机器复用）。
  String toPem() {
    final body = base64.encode(_Der.rsaPrivateKeyDer(this));
    final sb = StringBuffer('-----BEGIN RSA PRIVATE KEY-----\n');
    for (var i = 0; i < body.length; i += 64) {
      sb.write(body.substring(i, i + 64 > body.length ? body.length : i + 64));
      sb.write('\n');
    }
    sb.write('-----END RSA PRIVATE KEY-----\n');
    return sb.toString();
  }

  /// 签名 adbd 发来的 token → 256 字节**大端** PKCS#1 v1.5 签名。
  ///
  /// 注意 [token] **本身就是 SHA-1 摘要**（adbd 用 `sha1(random)` 生成它），
  /// 所以这里绝不能再 hash 一遍——真机取证结论，见文件头。
  Uint8List signToken(List<int> token) {
    if (token.length != 20) {
      throw ArgumentError('adbd 的 AUTH token 应为 20 字节 SHA-1 摘要，收到 ${token.length}');
    }
    final digestInfo = [..._kSha1DigestInfoPrefix, ...token];
    if (digestInfo.length + 11 > keyBytes) {
      throw StateError('密钥过短，装不下 PKCS#1 v1.5 填充');
    }
    // EM = 0x00 0x01 [0xff...] 0x00 DigestInfo
    final em = Uint8List(keyBytes);
    em[0] = 0x00;
    em[1] = 0x01;
    for (var i = 2; i < keyBytes - digestInfo.length - 1; i++) {
      em[i] = 0xff;
    }
    em[keyBytes - digestInfo.length - 1] = 0x00;
    em.setRange(keyBytes - digestInfo.length, keyBytes, digestInfo);

    final m = _bytesToBigInt(em);
    final s = m.modPow(d, n);
    // 链上就是标准大端（真机反推 EMSA 验证过），不做任何反转。
    return _bigIntToBytes(s, keyBytes);
  }

  /// adbd 认的公钥 blob（base64，不含结尾 NUL——NUL 由传输层补）。
  String publicKeyBase64() {
    final words = bitLength ~/ 32;
    final out = BytesBuilder(copy: false);
    final bd = ByteData(4);
    void putU32(int v) {
      bd.setUint32(0, v, Endian.little);
      out.add(Uint8List.fromList(
          [bd.getUint8(0), bd.getUint8(1), bd.getUint8(2), bd.getUint8(3)]));
    }

    putU32(words);
    // n0inv = -n[0]^{-1} mod 2^32（模数是奇数，逆元必存在）
    final n0 = n & BigInt.from(0xffffffff);
    final inv = n0.modInverse(BigInt.from(4294967296));
    putU32(((BigInt.from(4294967296) - inv) % BigInt.from(4294967296)).toInt());
    for (var i = 0; i < words; i++) {
      putU32(((n >> (32 * i)) & BigInt.from(0xffffffff)).toInt());
    }
    // rr = R^2 mod n，R = 2^(8*keyBytes)
    final r = BigInt.one << (8 * keyBytes);
    final rr = (r * r) % n;
    for (var i = 0; i < words; i++) {
      putU32(((rr >> (32 * i)) & BigInt.from(0xffffffff)).toInt());
    }
    putU32(e.toInt());
    return base64.encode(out.toBytes());
  }
}

// ---------------------------------------------------------------------------
// 素数生成（Miller-Rabin + 小素数试除）
// ---------------------------------------------------------------------------

BigInt _randomBits(int bits, Random rnd) {
  final bytes = Uint8List((bits + 7) ~/ 8);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = rnd.nextInt(256);
  }
  // 清掉多余高位，保证位长精确
  final extra = bytes.length * 8 - bits;
  if (extra > 0) {
    bytes[0] = bytes[0] & ((1 << (8 - extra)) - 1);
  }
  return _bytesToBigInt(bytes);
}

/// 生成 [bits] 位素数（最高位与最低位置 1）。
BigInt _generatePrime(int bits, Random rnd) {
  final two = BigInt.two;
  while (true) {
    var c = _randomBits(bits, rnd) | (BigInt.one << (bits - 1)) | BigInt.one;
    // 1) 小素数试除：绝大多数合数在这里就被踢掉
    var composite = false;
    for (final sp in _kSmallPrimes) {
      if (c % BigInt.from(sp) == BigInt.zero) {
        composite = true;
        break;
      }
    }
    if (composite) continue;
    // 2) Miller-Rabin：8 轮误判率 ~4^-8，密钥场景绰绰有余
    if (_millerRabin(c, 8, rnd, two)) return c;
  }
}

bool _millerRabin(BigInt n, int rounds, Random rnd, BigInt two) {
  if (n < two) return false;
  var d = n - BigInt.one;
  var r = 0;
  while (d.isEven) {
    d = d >> 1;
    r++;
  }
  final nMinusOne = n - BigInt.one;
  for (var i = 0; i < rounds; i++) {
    BigInt a;
    do {
      a = _randomBits(n.bitLength, rnd) % nMinusOne;
    } while (a < two);
    var x = a.modPow(d, n);
    if (x == BigInt.one || x == nMinusOne) continue;
    var probablyPrime = false;
    for (var j = 1; j < r; j++) {
      x = x.modPow(two, n);
      if (x == nMinusOne) {
        probablyPrime = true;
        break;
      }
    }
    if (!probablyPrime) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 字节序 / 最小 DER（只为 RSA 私钥读写，不引 asn1 依赖）
// ---------------------------------------------------------------------------

BigInt _bytesToBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b & 0xff);
  }
  return v;
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

/// 极简 DER（只覆盖 PKCS#1 RSA 私钥的读与写）。
class _Der {
  /// 读 SEQUENCE，返回其内容字节。
  static Uint8List readSequence(Uint8List der) {
    if (der.length < 2 || der[0] != 0x30) {
      throw const FormatException('DER：期望 SEQUENCE(0x30)');
    }
    final (len, header) = _readLength(der, 1);
    if (der.length < header + len) {
      throw const FormatException('DER：长度字段越界');
    }
    return Uint8List.sublistView(der, header, header + len);
  }

  /// 读 SEQUENCE 内容里的所有 INTEGER（跳过非 INTEGER 标签，兼容 PKCS#8 外层）。
  static List<BigInt> readIntegers(Uint8List content) {
    final out = <BigInt>[];
    var off = 0;
    while (off < content.length) {
      final tag = content[off];
      final (len, bodyStart) = _readLength(content, off + 1);
      if (bodyStart + len > content.length) break; // 尾部填充/截断：就此收
      if (tag == 0x02) {
        out.add(_bytesToBigInt(
            _stripLeadingZero(Uint8List.sublistView(content, bodyStart, bodyStart + len))));
      }
      off = bodyStart + len;
    }
    return out;
  }

  /// 读 OCTET STRING（PKCS#8 私钥的 inner key）。
  static Uint8List readOctetString(Uint8List content) {
    var off = 0;
    while (off < content.length) {
      final tag = content[off];
      final (len, bodyStart) = _readLength(content, off + 1);
      if (bodyStart + len > content.length) break;
      if (tag == 0x04) return Uint8List.sublistView(content, bodyStart, bodyStart + len);
      off = bodyStart + len;
    }
    throw const FormatException('DER：找不到 OCTET STRING');
  }

  /// 写 PKCS#1 RSAPrivateKey DER。
  static Uint8List rsaPrivateKeyDer(AdbRsaKeyPair k) {
    final fields = <BigInt>[
      BigInt.zero, // version
      k.n,
      k.e,
      k.d,
      k.p,
      k.q,
      k.d % (k.p - BigInt.one), // exponent1
      k.d % (k.q - BigInt.one), // exponent2
      k.q.modInverse(k.p), // coefficient
    ];
    final body = BytesBuilder(copy: false);
    for (final f in fields) {
      body.add(_encodeInteger(f));
    }
    return _encodeTlv(0x30, body.toBytes());
  }

  static Uint8List _encodeInteger(BigInt v) {
    var bytes = _unsignedBytes(v);
    if (bytes.isEmpty) bytes = Uint8List(1);
    if (bytes[0] & 0x80 != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }
    return _encodeTlv(0x02, bytes);
  }

  static Uint8List _unsignedBytes(BigInt v) {
    if (v == BigInt.zero) return Uint8List(1);
    final hex = v.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    final out = Uint8List(padded.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(padded.substring(i * 2, i * 2 + 2), radix: 16);
    }
    // 去掉多余的前导 0（保留至少 1 字节）
    var start = 0;
    while (start < out.length - 1 && out[start] == 0) {
      start++;
    }
    return Uint8List.sublistView(out, start);
  }

  static Uint8List _stripLeadingZero(Uint8List b) {
    var start = 0;
    while (start < b.length - 1 && b[start] == 0) {
      start++;
    }
    return Uint8List.sublistView(b, start);
  }

  static Uint8List _encodeTlv(int tag, Uint8List body) {
    final out = BytesBuilder(copy: false);
    out.addByte(tag);
    out.add(_encodeLength(body.length));
    out.add(body);
    return out.toBytes();
  }

  static Uint8List _encodeLength(int len) {
    if (len < 0x80) return Uint8List.fromList([len]);
    final bytes = <int>[];
    var v = len;
    while (v > 0) {
      bytes.insert(0, v & 0xff);
      v >>= 8;
    }
    return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
  }

  static (int length, int headerSize) _readLength(Uint8List data, int offset) {
    if (offset >= data.length) throw const FormatException('DER：长度字段缺失');
    final first = data[offset];
    if (first < 0x80) return (first, offset + 1);
    final count = first & 0x7f;
    if (count == 0 || count > 4) throw const FormatException('DER：不支持的长度编码');
    var len = 0;
    for (var i = 0; i < count; i++) {
      len = (len << 8) | data[offset + 1 + i];
    }
    return (len, offset + 1 + count);
  }
}
