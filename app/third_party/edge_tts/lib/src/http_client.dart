/// Edge TTS 专用 HttpClient：默认 **IPv4 优先**。
///
/// 为什么需要：国内网络常见的 IPv6 半死通道（6rd/6to4/隧道）表现为 **TCP 连得上、
/// TLS 握手被对端 RST**。而 dart:io 只在 *TCP 连接失败* 时才换下一个地址
/// （`_NativeSocket.startConnect` 的 connectNext 循环），TLS 阶段被 RST **不会**
/// 回退到 IPv4 —— 结果就是「换个网络/手机就完全不出声，PC 上一切正常」。
/// 实测：手机 `curl -6 https://speech.platform.bing.com/...` = 000（TLS RST），
/// `curl -4` = 200；PC 两种都 200。
///
/// 策略是「IPv4 优先、IPv6 兜底」而不是「只走 IPv4」，纯 IPv6-only 网络仍可工作。
///
/// ⚠️ 两个 dart:io 的硬坑（都在这台机器上真机复现过，别再踩）：
///  1. **设了 connectionFactory，HttpClient 就不再自己做 TLS 升级**（见
///     `_ConnectionTarget.connect`：直连时把工厂返回的 socket 原样交给
///     `_HttpClientConnection`）。所以 https/wss 必须自己 `SecureSocket.secure`
///     升级后再返回，否则就是明文打 443 → `Connection reset by peer` / 握手卡死。
///     例外：走代理时（proxyHost != null）要返回**明文** socket，dart:io 自己发
///     CONNECT 再升级（http_impl.dart `createProxyTunnel`）。
///  2. **直连时工厂拿到的是 `cf(uri, null, null)`**，而 WebSocket.connect 把
///     `wss://` 改写成 `https://` 时带的是 `port: 0`（wss 不在 Uri 的默认端口表里），
///     `_openUrl` 只在**自己那条路**上做 `port == 0 → 443` 归一化，工厂里必须自己补。
library;

import 'dart:io';

/// 纯函数：IPv4 排前面、其余保持原序跟在后面（单测钉死）。
List<InternetAddress> orderAddressesPreferIPv4(List<InternetAddress> addresses) =>
    <InternetAddress>[
      ...addresses.where((a) => a.type == InternetAddressType.IPv4),
      ...addresses.where((a) => a.type != InternetAddressType.IPv4),
    ];

/// 纯函数：复刻 `_HttpClientConnection._openUrl` 的端口归一化——工厂在直连时拿到
/// 的是 `uri`，而 wss→https 改写后的 `uri.port` 可能是 0。
int effectivePort(Uri uri, {int? proxyPort}) {
  final p = proxyPort ?? uri.port;
  if (p != 0) return p;
  return uri.isScheme('https') ? 443 : 80;
}

/// 建一个 Edge TTS 用的 [HttpClient]：不带默认 UA（防止 dart:io 追加
/// "Dart/x.x (dart:io)" 污染指纹），并按 [preferIPv4] 决定地址族顺序。
HttpClient createTtsHttpClient({bool preferIPv4 = true}) {
  final client = HttpClient()..userAgent = null;
  if (!preferIPv4) return client;

  client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
    final viaProxy = proxyHost != null;
    final connectHost = proxyHost ?? uri.host;
    final port = effectivePort(uri, proxyPort: proxyPort);
    final tlsHost = uri.host;
    // 代理路径必须交回明文 socket（dart:io 自己 CONNECT + 升级）。
    final needTls = uri.isScheme('https') && !viaProxy;

    Future<Socket> upgrade(Socket s) => needTls
        ? SecureSocket.secure(s,
            host: tlsHost, supportedProtocols: const <String>['http/1.1'])
        : Future<Socket>.value(s);

    Object? lastError;
    try {
      for (final a in orderAddressesPreferIPv4(await InternetAddress.lookup(connectHost))) {
        Socket? raw;
        try {
          raw = await Socket.connect(a, port, timeout: const Duration(seconds: 6));
          final s = await upgrade(raw);
          return ConnectionTask.fromSocket(Future<Socket>.value(s), () {
            try {
              s.destroy();
            } catch (_) {}
          });
        } catch (e) {
          lastError = e;
          try {
            raw?.destroy();
          } catch (_) {}
        }
      }
    } catch (e) {
      lastError = e;
    }

    // 全部地址失败 / 解析失败 → 用域名再试一次（等价于没装工厂时的默认行为）。
    try {
      final raw = await Socket.connect(connectHost, port,
          timeout: const Duration(seconds: 10));
      final s = await upgrade(raw);
      return ConnectionTask.fromSocket(Future<Socket>.value(s), () {
        try {
          s.destroy();
        } catch (_) {}
      });
    } catch (e) {
      throw lastError ?? e;
    }
  };
  return client;
}
