/// Sec-MS-GEC **v2** token（微软 2026-10 起强制；v1 纯 SHA-256 已被服务端 403 拒收）。
///
/// 与 v1 的差异（上游 python edge-tts PR #492 抓包定案）：
///   * 待哈希串不变：`<100ns Windows ticks><trusted client token>`（5 分钟对齐）；
///   * 摘要换成「魔改 SHA-256」（K[14] 与两个 σ 常量被替换）+ 一路 CS64 摘要，
///     输出格式 `<16 hex>-<64 hex>`；
///   * `Sec-MS-GEC-Version` 前缀必须同步从 `1-` 改成 `2-`，只改前缀或只改 token 都仍 403。
///
/// 本文件是上游 `drm.py` 的机械移植（含其「跳过首块前 14 轮」的预计算捷径：
/// `_sha256State` / `_sha256Schedule` 两组常量即预计算结果）。移植要点：
///   * Python 大整数 → Dart 64 位有符号整数：所有乘积 < 2^64，低 32 位语义不变；
///   * `rot = x * 0x100000001` 可能 ≥ 2^63 变负，右移必须用无符号 `>>>`（用 `>>`
///     会符号扩展 → token 全错且服务端 403，属静默错误，改动后务必跑 golden 校验）。
library;

import 'dart:convert';
import 'dart:typed_data';

const int _u32 = 0xFFFFFFFF;

/// SHA-256 标准初始 IV（FIPS 180-4）。
const List<int> _sha256Initial = <int>[
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, //
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];

/// 全零前缀块跑到第 14 轮时的工作寄存器快照（上游预计算常量）。
const List<int> _sha256State = <int>[
  0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, //
  0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
];

/// 全零前缀块的消息扩展预计算值（words[16..29]）。
const List<int> _sha256Schedule = <int>[
  0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, //
  0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
  0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
  0xD258B060, 0x72766564,
];

const List<int> _sha256RoundConstants = <int>[
  0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, //
  0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
  0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
  0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
  0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
  0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
  0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
  0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
  0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
  0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
  0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
  0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
  0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
  0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
  0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
  0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
];

/// 魔改点 1：K[14] 由 0x9BDC06A7 换成 0xC9DC06A7。
const int _sha256Adjustment = 0xC9DC06A7;

/// 魔改点 2/3：σ0 / σ1 各再异或一个常量（仅在首块边界字上生效）。
const int _sha256Sigma0Adjustment = 0x059C0B80;
const int _sha256Sigma1Adjustment = 0x000B92C0;

final List<int> _sha256BlockConstants = <int>[
  ..._sha256RoundConstants.sublist(0, 14),
  _sha256Adjustment,
  ..._sha256RoundConstants.sublist(15),
];

const List<List<int>> _cs64Coefficients = <List<int>>[
  <int>[0xE82E91B1, 0xB32700D0], <int>[0x44DE24C6, 0x88DFF51D],
  <int>[0x3BEB65BC, 0x29514038], <int>[0xC89C5933, 0xB328CBDF],
  <int>[0x8D1EC211, 0xD405B4D5], <int>[0x314EF5D5, 0x26E55F3C],
  <int>[0xE92491B1, 0x607801C6], <int>[0xF0A5B9D5, 0x82B2C1FB],
  <int>[0x06064CF3, 0xFA51A3DA], <int>[0xDA79FA60, 0x207CC464],
  <int>[0xBED20560, 0x3C3C74F3], <int>[0x89F9C9F8, 0xD2D14B61],
  <int>[0x35FA38C6, 0xBB04A2C1], <int>[0xCB49E3C6, 0xC5626167],
];

const int _cs64Factor = 0x82893933;
const int _cs64Adjustment0 = 0xF2F90B1A;
const int _cs64Adjustment1 = 0x0B1A0000;

int _rol16(int value) {
  final v = value & _u32;
  return ((v << 16) | (v >>> 16)) & _u32;
}

/// 小端 32 位字切分，补齐 4 字节对齐并凑成偶数个。
List<int> _wordsLe4Even(List<int> data) {
  final pad = (4 - data.length % 4) % 4;
  final bytes = Uint8List(data.length + pad);
  bytes.setRange(0, data.length, data);
  final words = <int>[];
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i + 4 <= bytes.length; i += 4) {
    words.add(bd.getUint32(i, Endian.little));
  }
  if (words.length.isOdd) words.add(0);
  return words;
}

/// 小端序版 σ0（截断一次，末位再掩码）。
int _sigma0(int value) => ((value >>> 7) ^ (value << 25) ^ (value >>> 18) ^
        (value << 14) ^ (value >>> 3)) &
    _u32;

/// 小端序版 σ1。
int _sigma1(int value) => ((value >>> 17) ^ (value << 15) ^ (value >>> 19) ^
        (value << 13) ^ (value >>> 10)) &
    _u32;

/// 跑 SHA-256 轮函数；[firstRound] != 0 表示从首块中间续跑（用替换过 K 的常量表）。
///
/// 与上游同构：先单轮跑到 8 的整数倍（让寄存器回到原始次序），之后每 8 轮一组
/// 成对展开。所有 `x * 0x100000001`（ROTR 的 64 位拼接技巧）都可能 ≥2^63 变负，
/// 右移必须用无符号 `>>>`。
List<int> _sha256Rounds(List<int> state, List<int> words, {int firstRound = 0}) {
  var a = state[0], b = state[1], c = state[2], d = state[3];
  var e = state[4], f = state[5], g = state[6], h = state[7];
  final constants =
      firstRound == 14 ? _sha256BlockConstants : _sha256RoundConstants;
  var aligned = ((firstRound + 7) ~/ 8) * 8;
  if (aligned > 64) aligned = 64;

  for (var index = firstRound; index < aligned; index++) {
    final rotE = e * 0x100000001;
    final rotA = a * 0x100000001;
    final t1 = h +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (g ^ (e & (f ^ g))) +
        constants[index] +
        words[index];
    final t2 = ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
        ((a & b) | (c & (a | b)));
    final na = (t1 + t2) & _u32;
    final nd = (d + t1) & _u32;
    h = g;
    g = f;
    f = e;
    e = nd;
    d = c;
    c = b;
    b = a;
    a = na;
  }

  for (var index = aligned; index < 64; index += 8) {
    // 8 轮成对展开（上游写法）：每对更新两个寄存器，避免整组轮转。
    var rotE = e * 0x100000001;
    var rotA = a * 0x100000001;
    var t1 = h +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (g ^ (e & (f ^ g))) +
        constants[index] +
        words[index];
    d = (d + t1) & _u32;
    h = (t1 +
            ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
            ((a & b) | (c & (a | b)))) &
        _u32;

    rotE = d * 0x100000001;
    rotA = h * 0x100000001;
    t1 = g +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (f ^ (d & (e ^ f))) +
        constants[index + 1] +
        words[index + 1];
    c = (c + t1) & _u32;
    g = (t1 +
            ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
            ((h & a) | (b & (h | a)))) &
        _u32;

    rotE = c * 0x100000001;
    rotA = g * 0x100000001;
    t1 = f +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (e ^ (c & (d ^ e))) +
        constants[index + 2] +
        words[index + 2];
    b = (b + t1) & _u32;
    f = (t1 +
            ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
            ((g & h) | (a & (g | h)))) &
        _u32;

    rotE = b * 0x100000001;
    rotA = f * 0x100000001;
    t1 = e +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (d ^ (b & (c ^ d))) +
        constants[index + 3] +
        words[index + 3];
    a = (a + t1) & _u32;
    e = (t1 +
            ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
            ((f & g) | (h & (f | g)))) &
        _u32;

    rotE = a * 0x100000001;
    rotA = e * 0x100000001;
    t1 = d +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (c ^ (a & (b ^ c))) +
        constants[index + 4] +
        words[index + 4];
    h = (h + t1) & _u32;
    d = (t1 +
            ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
            ((e & f) | (g & (e | f)))) &
        _u32;

    rotE = h * 0x100000001;
    rotA = d * 0x100000001;
    t1 = c +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (b ^ (h & (a ^ b))) +
        constants[index + 5] +
        words[index + 5];
    g = (g + t1) & _u32;
    c = (t1 +
            ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
            ((d & e) | (f & (d | e)))) &
        _u32;

    rotE = g * 0x100000001;
    rotA = c * 0x100000001;
    t1 = b +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (a ^ (g & (h ^ a))) +
        constants[index + 6] +
        words[index + 6];
    f = (f + t1) & _u32;
    b = (t1 +
            ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
            ((c & d) | (e & (c | d)))) &
        _u32;

    rotE = f * 0x100000001;
    rotA = b * 0x100000001;
    t1 = a +
        ((rotE >>> 6) ^ (rotE >>> 11) ^ (rotE >>> 25)) +
        (h ^ (f & (g ^ h))) +
        constants[index + 7] +
        words[index + 7];
    e = (e + t1) & _u32;
    a = (t1 +
            ((rotA >>> 2) ^ (rotA >>> 13) ^ (rotA >>> 22)) +
            ((b & c) | (d & (b | c)))) &
        _u32;
  }
  return <int>[a, b, c, d, e, f, g, h];
}

/// 消息扩展：把 words 补到 64 个字（原地去掉 Python 的 append 语义）。
void _expandSha256Schedule(List<int> words, {int firstWord = 16}) {
  for (var index = firstWord; index < 64; index++) {
    final x = words[index - 2], y = words[index - 15];
    final s1 = (x >>> 17) ^ (x << 15) ^ (x >>> 19) ^ (x << 13) ^ (x >>> 10);
    final s0 = (y >>> 7) ^ (y << 25) ^ (y >>> 18) ^ (y << 14) ^ (y >>> 3);
    if (words.length <= index) {
      words.add((s1 + words[index - 7] + s0 + words[index - 16]) & _u32);
    } else {
      words[index] = (s1 + words[index - 7] + s0 + words[index - 16]) & _u32;
    }
  }
}

String? _initCacheKey;
List<int>? _initCacheValue;

/// 首块（57 字节常量前缀 + data 前 7 字节）的 SHA-256 状态，带单条缓存。
List<int> _sha256Init(List<int> data) {
  final key = String.fromCharCodes(data);
  if (_initCacheKey == key && _initCacheValue != null) return _initCacheValue!;

  final words = <int>[
    ...List<int>.filled(14, 0),
    (data[0] << 16) | (data[1] << 8) | data[2],
    (data[3] << 24) | (data[4] << 16) | (data[5] << 8) | data[6],
  ];
  for (var index = 16; index < 30; index++) {
    var value = _sha256Schedule[index - 16];
    if (index - 2 >= 14) {
      value += index == 16
          ? (_sigma1(words[index - 2]) ^ _sha256Sigma1Adjustment)
          : _sigma1(words[index - 2]);
    }
    if (index - 7 >= 14) value += words[index - 7];
    if (index - 15 >= 14) {
      value += index == 29
          ? (_sigma0(words[index - 15]) ^ _sha256Sigma0Adjustment)
          : _sigma0(words[index - 15]);
    }
    words.add(value & _u32);
  }
  words.add((_sigma1(words[28]) +
          words[23] +
          _sigma0(words[15]) +
          words[14] +
          _sha256Adjustment -
          _sha256RoundConstants[14]) &
      _u32);
  _expandSha256Schedule(words, firstWord: 31);
  final working = _sha256Rounds(_sha256State, words, firstRound: 14);
  final state = <int>[
    for (var i = 0; i < 8; i++) (_sha256Initial[i] + working[i]) & _u32
  ];
  _initCacheKey = key;
  _initCacheValue = state;
  return state;
}

/// 魔改 SHA-256 摘要（隐含 57 字节常量前缀，故 length = 57 + len(data)）。
Uint8List _sha256Digest(List<int> data) {
  if (data.length < 7) {
    throw ArgumentError('Token salt must contain at least seven bytes');
  }
  final length = 57 + data.length;
  final padded = <int>[
    ...data.sublist(7),
    0x80,
    ...List<int>.filled((55 - length) % 64, 0),
  ];
  final bitLen = length * 8;
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLen >>> (8 * i)) & 0xFF);
  }
  var state = _sha256Init(data.sublist(0, 7));
  for (var offset = 0; offset < padded.length; offset += 64) {
    final words = <int>[];
    for (var i = 0; i < 16; i++) {
      final o = offset + i * 4;
      words.add((padded[o] << 24) |
          (padded[o + 1] << 16) |
          (padded[o + 2] << 8) |
          padded[o + 3]);
    }
    _expandSha256Schedule(words);
    final working = _sha256Rounds(state, words);
    state = <int>[for (var i = 0; i < 8; i++) (state[i] + working[i]) & _u32];
  }
  final out = Uint8List(32);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < 8; i++) {
    bd.setUint32(i * 4, state[i], Endian.big);
  }
  return out;
}

/// CS64 摘要（以 SHA-256 摘要前 8 字节为密钥），返回两个字。
List<int> _cs64Digest(List<int> data, Uint8List digest) {
  final bd = ByteData.sublistView(digest);
  final keyA = bd.getUint32(0, Endian.little) | 1;
  final keyB = bd.getUint32(4, Endian.little) | 1;
  final factors = <int>[
    (keyA * _cs64Factor) & _u32,
    (keyB * _cs64Factor) & _u32,
  ];
  final terms = <int>[
    for (var i = 0; i < _cs64Coefficients.length; i++)
      (_cs64Coefficients[i][0] * factors[i % 2]) & _u32
  ];
  final offsets = <int>[
    for (final c in _cs64Coefficients) c[1]
  ];
  final wordsIn = _wordsLe4Even(<int>[0, ...data]);
  for (var index = 0; index < wordsIn.length; index++) {
    final word = wordsIn[index];
    var term = word * (index % 2 == 0 ? keyA : keyB);
    var offset = _rol16(word) * (index % 2 == 0 ? 0xEF0569FB : 0xC31713DB);
    if (index == 0) {
      term += _cs64Adjustment0 * factors[0];
      offset += _cs64Adjustment1;
    }
    terms.add(term & _u32);
    offsets.add(offset & _u32);
  }
  var swapAcc = 0, swapLast = 0, state = 0, acc = 0;
  for (var index = 0; index < terms.length; index += 2) {
    final x = terms[index], y = terms[index + 1];
    var t = _rol16((offsets[index] + x) & _u32);
    var q = (t * 0x76F50F34) & _u32;
    swapAcc += ((_rol16(q) * 0xC3EFEA97) & _u32) + q;
    t = _rol16((offsets[index + 1] + y) & _u32);
    q = (t * 0x1881CE3C) & _u32;
    swapLast = ((_rol16(q) * 0x35BD1EC9) & _u32) + q;
    swapAcc = (swapAcc + swapLast) & _u32;

    state = (state * keyA + x) & _u32;
    state = (_rol16(state) * 0xCF98B111) & _u32;
    state = (_rol16(state) * 0x87085B9F) & _u32;
    state = (_rol16(state) * 0x12CEB96D) & _u32;
    state = (_rol16(state) * 0x257E1D83) & _u32;
    acc += state;
    t = (state * keyB + y) & _u32;
    t = (_rol16(t) * 0xA27416F5) & _u32;
    t = (_rol16(t) * 0xD38396FF) & _u32;
    state = (_rol16((_rol16(t) * 0x7C932B89) & _u32) * 0xBFA49F69) & _u32;
    acc = (acc + state) & _u32;
  }
  return <int>[swapLast ^ state, swapAcc ^ acc];
}

String _hex(List<int> bytes) =>
    bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join().toUpperCase();

String? _tokenCacheKey;
String? _tokenCacheValue;

/// 对 `<ticks100ns><trustedClientToken>` 计算 v2 摘要串 `<cs64 16hex>-<sha256 64hex>`。
String tokenHashV2(List<int> strToHash) {
  final key = String.fromCharCodes(strToHash);
  if (_tokenCacheKey == key && _tokenCacheValue != null) return _tokenCacheValue!;
  final digest = _sha256Digest(strToHash);
  final cs64 = _cs64Digest(strToHash, digest);
  final out = ByteData(8);
  out.setUint32(0, cs64[0], Endian.little);
  out.setUint32(4, cs64[1], Endian.little);
  final value =
      '${_hex(Uint8List.sublistView(out, 0, 8))}-${_hex(digest)}';
  _tokenCacheKey = key;
  _tokenCacheValue = value;
  return value;
}

/// 生成 v2 token。[unixSeconds] 传入固定时间戳可做 golden 校验；
/// ticks 计算与 v1 完全一致（Windows epoch + 5 分钟对齐 + 100ns 换算）。
String generateSecMsGecV2(int unixSeconds, String trustedClientToken) {
  var ticks = unixSeconds + 11644473600; // winEpoch
  ticks -= ticks % 300;
  final ticks100ns = ticks * 10000000;
  return tokenHashV2(utf8.encode('$ticks100ns$trustedClientToken'));
}
