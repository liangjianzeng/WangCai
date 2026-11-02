/// ADB RSA 授权单测。
///
/// 三条真机定案的回归防线（根因都写在各断言的 reason 里）：
/// 1. token 本身就是 SHA-1 摘要，**不许再 hash 一遍**；
/// 2. 签名是**大端** PKCS#1 v1.5（`00 01 FF.. 00 || DigestInfo || token`）；
/// 3. 公钥 blob 是 AOSP `RSA_public_key` 结构（len/n0inv/n[]/rr[]/e，字内小端）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/adb/adb_rsa.dart';
import 'package:tongyi_lite/agent/adb/adb_targets.dart';

/// 固定 2048 位测试私钥（仅单测生成，不属于任何真实设备）。
final String kFixturePem = [
    '-----BEGIN RSA PRIVATE KEY-----',
    'MIIEogIBAAKCAQEAhz/fDzBFwbwmwHxfv2C1gTHqBgNgiQyKMMeEwKqeKLPCHiEq',
    'cjpLrHOUdQ4CWuLFhAt6whAi9h4n0wmXxnL4hOjyb5wgkdnn+8wJAjJ+8FoHDdYb',
    'nLC6l+igO3f86U2vNxioW6T8b1DbuN1UP8ZvLbTfI9aHWOu6CAz+WohaO48vShWi',
    '7j0nFuNCq9ZgZctIoW90phwWwUii/rTiL28j+uoTcjaojBz/ZGQSc+81tG2574+6',
    'EvzSKbxwUn0rzBxTZZEbSl+g6bUZnKJK3rujCPGluM3+VOZgIEvEvBIeI/0ZRObe',
    'hAAKZfugVksBGbtVNawfnAHz0Gmyab+5F8wflwIDAQABAoIBABt4VpbgKBrsWzaX',
    'TF8zhkoCWFT2VKIhYOP9cjIrtUnxEMlL1TI0MvCI3StVOBc7ngBu0HUgD+nLQC11',
    '8lTFP0LHiY4vuNHG335d96pxlSS+NFaUGTGfF5cJEZpiiYTdWWwoXvGWNgtp8ea/',
    'VYBKjoRLC1NdHEpsPnGqKfM7ZJBZ/gghDKJff1yvAnwxGlxaMFoTdgPaIbyRmK1K',
    'YseO8pNcsMwZgsgkO4FtBbyDMkLhyou12+xR6q26W4JjAFtrGKUCoQn4KQWplDuW',
    '/L0rcrATRVpf/0MMx2hpujZM/v8UPZxz9gInIynTSuDEPQVCVSpsjNLUHTvBK0Ue',
    'RvGwzjECgYEAse0QdHaYvKcKKgAk0Y2PN5MJiQuxUhOx/Ky210evvsfDO3dfb75t',
    '2MtJXYzQpCUjUH4/c5y6LhIUoELmfAIDInqdXNjvfNq0pCK37eeT/tomqz55NrSs',
    'QmaSm+00lUxoeNnOkIJmfXuWQDPEwVk8eZZib5eLoqmEkH/Ma7DNL28CgYEAwpjU',
    's5+CEnccVDWxUQr1acT0MtBmKRN0gf4obdY7ep5Y0zvIL0BxSZt1sO5Bf6ctExSR',
    'a/sF+4xRQ2HVwQhdFGAIVzZaVOluAfHwgtmSdbUrTen8lnyWxKNfcsZNk2FCajVo',
    'JeK6s2F5HQ1AWBI02Bt+tL3ECH7CYR/nzN/CflkCgYB5JN5FTdKk8F7dRgfLnkTb',
    'JAQkCZAMQFi5n6dGYQrqLP1i6d5TKSeFqrQjPBN7D8ZBshPl1dp2L91XWPWxjXUw',
    '7qdiZlp5ejfwYas2Eq0TotkdU4YYl1+KPmioPhPFa6beUf5xKjg6TAF7aUQYGXgx',
    'mREgxeBPOniGIl2/HTw3hQKBgHpqwoQtOBp9q+idzmp5RmG/cQ/2Yg49GvIb/Tr7',
    'pndA3ggkd46iL6JqleM0Pyga9xQlwEX5qI3Se9yz01CX/lYvA5A5tSHtpzK6DN+E',
    'F8rMqe1d4XSZ9A7H5+fAMFUivjEqX9ZVh7YI/7Py/iNpcKzyvwbcylG9zHJlK+GK',
    'ckQhAoGACxyFjaFTSyhwmvXMQuRTQO9T80rxA/e/v4Grj94aWWDur5XlcL9duWam',
    'a2Wf3byi9gno+JwQGjymteVkgTuqJFEAYitHFBAou35Fh2ZyHHNKLyMFdlMiYN/g',
    'gktpFIaHQNZqig+08qeZ1VEhCsCgWTSeRGDbglJgmbQVC/xJgUI=',
    '-----END RSA PRIVATE KEY-----',
].join('\n');
const String kFixtureBlob = 'QAAAANmvx6SXH8wXub9psmnQ8wGcH6w1VbsZAUtWoPtlCgCE3uZEGf0jHhK8xEsgYOZU/s24pfEIo7veSqKcGbXpoF9KG5FlUxzMK31ScLwp0vwSuo/vuW20Ne9zEmRk/xyMqDZyE+r6I28v4rT+okjBFhymdG+hSMtlYNarQuMWJz3uohVKL487Woha/gwIuutYh9Yj37Qtb8Y/VN2421Bv/KRbqBg3r03p/Hc7oOiXurCcG9YNB1rwfjICCcz759mRIJxv8uiE+HLGlwnTJx72IhDCeguExeJaAg51lHOsSzpyKiEewrMonqrAhMcwigyJYAMG6jGBtWC/X3zAJrzBRTAP3z+HxUJehcBfi12zed1jAQmbXI+r2DZ8wa51613uKwFd8Gp2j3rEOYPp4DLvOk2y+Hrz9IArpCwYwJRFVibko81cYM4SGa1D52bcljGlPNndp5A8C9VTR/MJGCjxLRFHGLinrUx3YIur1TPfTWTdHlrB1H3DCnCkysE8ILCNd3mKP4IuapKguCn3R+tn0CVzaSYGceCyTEnmeF3Ugdj+ZY7zEtvpak+hD9rTjskwOMbjPrgdE30zhZgCv4pKxIoA1FDYKJiqxc5/ED3yIos2cmYN4MS0EMVpj2A/Bbi14NoOtWm2Pms77EgoFZI8iVSnOoJl0aM6AMCcKjUmp5DwGxKAJAEAAQA=';
const String kFixtureTokenHex = '0b121920272e353c434a51585f666d747b828990';

/// 同一私钥对上述 token 的签名（256 字节，大端）—— 钉死"填充 + 字节序"。
const String kFixtureSigHex = '4ccc85aa4cfce75a03cfa3878a0521ba52f0cf114182e271d850e98ac8cd15e74811435ca7a15b311bcd99c3d39691b3002d9c2f04c8b09e177d7711c61cfaa3b88ac76db5ad0fd16a61a37a3e8625c183ba82fa462aad19afbf7e946c0089ba484b5ac9cf6002889ea4e84c96132d84205a74ba8e1aafc1a0ad3c3171d58dbfda154a255600696c717f6e8834ebbd6b6a50143f2852473dffbfd3069a966fd93e2f184164dd650cb4f46dae58f0ce12fd1cb631f01a94bd8026bc1b2001edf54da2cf9416dea329f7597c27c2a5d1c6d0017df99a4765fc471b5a3680f6f72c3a1888c5338a7a4dd00b85513180e310bb83bdc14586b866050e7eb3bc852c69';

/// SHA-1 的 DigestInfo 前缀（AOSP `signed_data` 里那段）。
const String _kSha1DigestInfo = '3021300906052b0e03021a05000414';

Uint8List _hex(String s) => Uint8List.fromList(
    RegExp(r'..').allMatches(s).map((m) => int.parse(m.group(0)!, radix: 16)).toList());

String _hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

BigInt _be(List<int> b) =>
    b.fold(BigInt.zero, (acc, x) => (acc << 8) | BigInt.from(x));

/// 把 PKCS#1 PEM 包成 PKCS#8 —— 新版 `~/.android/adbkey` 就是这个形态。
String _wrapPkcs8(String pkcs1Pem) {
  final der = base64.decode(pkcs1Pem
      .replaceAll(RegExp(r'-----[A-Z ]+-----'), '')
      .replaceAll(RegExp(r'\s'), ''));
  final algo = <int>[
    0x30, 0x0d, // AlgorithmIdentifier
    0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, // rsaEncryption
    0x05, 0x00, // NULL
  ];
  Uint8List tlv(int tag, List<int> body) {
    if (body.length < 128) return Uint8List.fromList([tag, body.length, ...body]);
    final lenBytes = <int>[];
    for (var v = body.length; v > 0; v >>= 8) {
      lenBytes.insert(0, v & 0xff);
    }
    return Uint8List.fromList([tag, 0x80 | lenBytes.length, ...lenBytes, ...body]);
  }

  final inner = tlv(0x30, <int>[0x02, 0x01, 0x00, ...algo, ...tlv(0x04, der)]);
  return '-----BEGIN PRIVATE KEY-----\n'
      '${base64.encode(inner)}\n'
      '-----END PRIVATE KEY-----\n';
}

void main() {
  final key = AdbRsaKeyPair.fromPem(kFixturePem);
  final token = _hex(kFixtureTokenHex);

  group('签名（真机定案的字节序）', () {
    test('token 必须是 20 字节（adbd 给的就是 SHA-1 摘要）', () {
      expect(() => key.signToken(List.filled(19, 0)), throwsA(isA<ArgumentError>()));
      expect(() => key.signToken(List.filled(32, 0)), throwsA(isA<ArgumentError>()),
          reason: '当 SHA-256 处理会静默产出错签名 → 手机永远不弹「允许调试」');
    });

    test('签名 256 字节且与固定向量逐字节相同', () {
      final s = key.signToken(token);
      expect(s.length, 256);
      expect(_hexOf(s), kFixtureSigHex);
    });

    test('公钥反推 EMSA = 00 01 FF.. 00 | DigestInfo | token 原文（不再 hash）', () {
      final s = _be(_hex(kFixtureSigHex));
      final em = s.modPow(key.e, key.n).toRadixString(16).padLeft(512, '0');
      expect(em.substring(0, 4), '0001', reason: 'PKCS#1 v1.5 头；字节序反了这里第一个就崩');
      final zeroIdx = em.indexOf('00', 4);
      expect(em.substring(4, zeroIdx), 'ff' * (zeroIdx ~/ 2 - 2));
      const di = _kSha1DigestInfo;
      expect(em.substring(zeroIdx + 2, zeroIdx + 2 + di.length), di);
      expect(em.endsWith(kFixtureTokenHex), isTrue,
          reason: 'token 原文直接拼在尾部——再 hash 一次这里就对不上');
    });

    test('PKCS#8（新版 adbkey 形态）解出同一把私钥', () {
      final k8 = AdbRsaKeyPair.fromPem(_wrapPkcs8(kFixturePem));
      expect(k8.n, key.n);
      expect(k8.d, key.d);
      expect(_hexOf(k8.signToken(token)), kFixtureSigHex);
    });

    test('adbkey 里 PRIVATE + PUBLIC 两块并存时取私钥块（真机踩过）', () {
      final adbkey = '$kFixturePem\n'
          '-----BEGIN PUBLIC KEY-----\n'
          'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAhz/fDzBFwbwmwHxfv2C1\n'
          '-----END PUBLIC KEY-----\n';
      final k = AdbRsaKeyPair.fromPem(adbkey);
      expect(k.n, key.n, reason: '正则必须锚定 PRIVATE KEY，否则会拿公钥块当私钥');
    });

    test('垃圾输入抛 FormatException（不许静默"当没密钥"再生成一把）', () {
      expect(() => AdbRsaKeyPair.fromPem('hello'), throwsA(isA<FormatException>()));
      expect(
          () => AdbRsaKeyPair.fromPem(
              '-----BEGIN RSA PRIVATE KEY-----\n@@@not-base64@@@\n-----END RSA PRIVATE KEY-----\n'),
          throwsA(isA<FormatException>()));
    });
  });

  group('公钥 blob（AOSP RSA_public_key 结构）', () {
    test('524 字节 = len|n0inv|n[64]|rr[64]|e，且与固定向量一致', () {
      final blob = base64.decode(key.publicKeyBase64());
      expect(blob.length, 524);
      expect(base64.encode(blob), kFixtureBlob);
      final bd = ByteData.sublistView(Uint8List.fromList(blob));
      expect(bd.getUint32(0, Endian.little), 64, reason: 'words = 2048/32');
      expect(bd.getUint32(520, Endian.little), 65537);

      final n0 = bd.getUint32(8, Endian.little);
      final n0inv = bd.getUint32(4, Endian.little);
      expect(
          (BigInt.from(n0) * BigInt.from(n0inv) + BigInt.one) %
              BigInt.from(4294967296),
          BigInt.zero,
          reason: 'Montgomery：n0 * n0inv ≡ -1 (mod 2^32)');

      var n = BigInt.zero;
      for (var i = 63; i >= 0; i--) {
        n = (n << 32) | BigInt.from(bd.getUint32(8 + 4 * i, Endian.little));
      }
      expect(n, key.n, reason: 'n 按"字内小端"排布，字序错 adbd 判密钥无效');
      var rr = BigInt.zero;
      for (var i = 63; i >= 0; i--) {
        rr = (rr << 32) | BigInt.from(bd.getUint32(8 + 256 + 4 * i, Endian.little));
      }
      final r = BigInt.one << 2048;
      expect(rr, (r * r) % n);
    });
  });

  group('密钥托管（adb_targets）', () {
    test('loadOrCreateAdbKey 只生成一次并复用', () async {
      final store = InMemoryAdbSecretStore();
      final a = await loadOrCreateAdbKey(store, bits: 1024);
      final b = await loadOrCreateAdbKey(store, bits: 1024);
      expect(a.n, b.n, reason: '每次连接换钥匙 → 手机每次都弹授权框');
      expect(await store.read(kAdbKeySlot), isNotNull);
    });

    test('存了坏数据要抛出来，不许静默换钥匙', () async {
      final store = InMemoryAdbSecretStore()..write(kAdbKeySlot, 'garbage');
      await expectLater(loadOrCreateAdbKey(store), throwsA(isA<FormatException>()));
      expect(await store.read(kAdbKeySlot), 'garbage',
          reason: '坏数据不许被悄悄覆盖（用户可能只是贴错一次，原钥匙还得留着排查）');
    });

    test('导入的私钥与自生成的公钥串同构（adbkey.pub 首段）', () async {
      final store = InMemoryAdbSecretStore();
      await importAdbPrivateKeyPem(store, kFixturePem);
      final k = await loadOrCreateAdbKey(store);
      expect(adbPublicKeyLine(k).split(' ').first, kFixtureBlob);
      expect(adbKeyFingerprint(k),
          _hexOf(base64.decode(kFixtureBlob).sublist(0, 8)));
    });
  });
}
