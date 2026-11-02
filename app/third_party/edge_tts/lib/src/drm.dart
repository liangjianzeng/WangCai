import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'constants.dart';
import 'gec_v2.dart';

int _clockSkew = 0;

int _nowSeconds() =>
    DateTime.now().millisecondsSinceEpoch ~/ 1000 + _clockSkew;

/// Generates the Sec-MS-GEC token required for authentication.
///
/// 2026-10-10 起服务端只接受 **v2** token（`<16hex>-<64hex>`，魔改 SHA-256 +
/// CS64，见 gec_v2.dart）；v1 纯 SHA-256 一律 403。[secMsGecVersion] 前缀
/// 必须同步为 `2-`。
String generateSecMsGec() =>
    generateSecMsGecV2(_nowSeconds(), trustedClientToken);

/// 旧版 v1 token（纯 SHA-256，64 hex）。服务端已拒收，仅留作对照/回归用。
String generateSecMsGecV1() {
  int nowSeconds = _nowSeconds();

  int ticks = nowSeconds + winEpoch;
  ticks -= ticks % 300; // round to nearest 5 minutes
  final ticks100ns = ticks * 10000000;

  final strToHash = '$ticks100ns$trustedClientToken';
  final hash = sha256.convert(utf8.encode(strToHash));
  return hash.toString().toUpperCase();
}

/// Updates the clock skew based on the server's Date header.
/// Called when a 403 response is received.
void updateClockSkew(String serverDate) {
  try {
    final serverTime = HttpDate.parse(serverDate);
    final localTime = DateTime.now();
    _clockSkew = serverTime.difference(localTime).inSeconds;
  } catch (_) {
    // Ignore parse errors
  }
}

/// Generates a random 32-character uppercase hex string for the MUID cookie.
String generateMuid() {
  final random = Random.secure();
  return List.generate(32, (_) => random.nextInt(16).toRadixString(16))
      .join()
      .toUpperCase();
}

/// Generates a random UUID v4 hex string (no dashes).
String generateUuidHex() {
  final random = Random.secure();
  return List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
}

/// Generates a JavaScript-style timestamp string.
/// Format: "Thu Mar 15 2026 12:34:56 GMT+0000 (Coordinated Universal Time)"
String generateTimestamp() {
  final now = DateTime.now().toUtc();
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  final wd = weekdays[now.weekday - 1];
  final mo = months[now.month - 1];
  final d = now.day.toString().padLeft(2, '0');
  final h = now.hour.toString().padLeft(2, '0');
  final mi = now.minute.toString().padLeft(2, '0');
  final s = now.second.toString().padLeft(2, '0');

  return '$wd $mo $d ${now.year} $h:$mi:$s GMT+0000 (Coordinated Universal Time)';
}
