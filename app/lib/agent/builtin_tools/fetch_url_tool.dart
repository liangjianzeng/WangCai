/// 通用网页抓取工具（fetch_url）—— 爬虫地基，web_search 之外按 URL 直取页面。
///
/// 设计要点：
/// - HTML → 结构化文本：先剥 script/style/注释，再**保留表格结构**（<tr> 一行、
///   <td> 用 " | " 连接）——财经数据大都在表格里，平铺去标签会把整张表揉成一坨。
/// - 编码：默认 UTF-8；Content-Type / <meta charset> 声明 GBK 系时用 fast_gbk
///   解码（新浪/腾讯老接口与部分财经站仍是 GBK，UTF-8 硬解会全乱码）。
/// - 注入缝：[httpGet] 可注入测试桩（websearch 模块同款做法）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart' as gbk;

import '../tool_definition.dart';

/// 一次 HTTP GET 的抽象响应（测试桩可直接构造）。
class FetchHttpResponse {
  final int statusCode;
  final String? contentType;
  final String? location;
  final List<int> bytes;

  const FetchHttpResponse({
    required this.statusCode,
    this.contentType,
    this.location,
    this.bytes = const [],
  });
}

/// 注入缝：给定 URL 与请求头，返回响应。默认实现见 [dioFetch]。
typedef FetchHttp = Future<FetchHttpResponse> Function(
    String url, Map<String, String> headers);

/// PC Chrome UA（与 websearch 实测可用的池同款；爬站用固定 PC UA 最稳）。
const String kFetchUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 响应体上限（字节）。超限截断——1.5MB 的 PC 大页也够提取正文了。
const int kFetchMaxBytes = 512 * 1024;

Future<FetchHttpResponse> dioFetch(String url, Map<String, String> headers) async {
  final dio = Dio(BaseOptions(
    responseType: ResponseType.bytes,
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
    followRedirects: true,
    maxRedirects: 5,
    validateStatus: (_) => true,
  ));
  final resp = await dio.get<List<int>>(
    url,
    options: Options(headers: headers, responseType: ResponseType.bytes),
  );
  return FetchHttpResponse(
    statusCode: resp.statusCode ?? 0,
    contentType: resp.headers.value('content-type'),
    location: resp.headers.value('location'),
    bytes: resp.data ?? const [],
  );
}

ToolDefinition createFetchUrlTool({FetchHttp? httpGet}) {
  final get = httpGet ?? dioFetch;
  return ToolDefinition(
    name: 'fetch_url',
    description: '抓取指定 URL 的网页内容并转为纯文本（保留表格结构，自动识别 '
        'GBK 编码，JSON 原样返回）。用于读取搜索结果之外的固定页面/数据接口。',
    parameters: {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': '完整 URL（含 https://；中文路径自行 URL 编码）',
        },
        'max_chars': {
          'type': 'integer',
          'description': '返回文本上限（默认 8000，最大 30000）',
        },
      },
      'required': ['url'],
    },
    timeout: const Duration(seconds: 25),
    execute: (args) async {
      final url = (args['url'] as String?)?.trim() ?? '';
      if (url.isEmpty) return ToolResult.error('缺少 url 参数');
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return ToolResult.error('url 必须是 http(s) 完整地址');
      }
      final maxChars = _clampInt(args['max_chars'], 200, 30000, 8000);

      final FetchHttpResponse resp;
      try {
        resp = await get(url, {
          'User-Agent': kFetchUserAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        });
      } catch (e) {
        return ToolResult.error('抓取失败：$e');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 400) {
        return ToolResult.error('HTTP ${resp.statusCode}（$url）');
      }
      final bytes = resp.bytes.length > kFetchMaxBytes
          ? resp.bytes.sublist(0, kFetchMaxBytes)
          : resp.bytes;

      final ct = (resp.contentType ?? '').toLowerCase();
      final body = _decodeBytes(bytes, ct);
      final isJson = ct.contains('json') ||
          body.trimLeft().startsWith('{') ||
          body.trimLeft().startsWith('[');
      final text = isJson ? body : htmlToStructuredText(body);
      if (text.trim().isEmpty) {
        return ToolResult.error('页面无可提取文本（可能整页 JS 渲染，换数据接口或其它站点）');
      }
      final clipped = text.length > maxChars
          ? '${text.substring(0, maxChars)}\n…[已截断，原文 ${text.length} 字符]'
          : text;
      return ToolResult(content: '[HTTP ${resp.statusCode}] $url\n$clipped');
    },
  );
}

int _clampInt(Object? v, int min, int max, int dflt) {
  final n = v is int ? v : int.tryParse('$v');
  if (n == null) return dflt;
  return n < min ? min : (n > max ? max : n);
}

/// 按优先级解码：显式 charset → meta 嗅探 → UTF-8（容错）。
String _decodeBytes(List<int> bytes, String contentType) {
  final explicit = RegExp(r'charset=([\w-]+)', caseSensitive: false)
      .firstMatch(contentType)
      ?.group(1);
  final head = latin1.decode(bytes.take(2048).toList(), allowInvalid: true);
  final meta = RegExp(r"""charset=["']?([\w-]+)""", caseSensitive: false)
      .firstMatch(head)
      ?.group(1);
  final cs = (explicit ?? meta ?? '').toLowerCase().replaceAll('-', '');
  if (cs == 'gbk' || cs == 'gb2312' || cs == 'gb18030') {
    return gbk.gbk.decode(bytes);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// HTML → 结构化文本：剥脚本/样式/注释，保留表格行列（td 用 " | " 连接、
/// tr/p/div/h/li/br 换行），解实体，压缩空白与连续空行。
String htmlToStructuredText(String html) {
  var s = html
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceAll(RegExp(r'<(script|style|noscript)\b[^>]*>.*?</\1>',
          dotAll: true, caseSensitive: false), '')
      .replaceAll(RegExp(r'<(br|/p|/div|/h[1-6]|/li|/tr)\s*/?>',
          caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<t[dh]\b[^>]*>', caseSensitive: false), ' | ');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  final lines = s.split('\n').map((l) {
    var t = l.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ').trim();
    // 行首/行尾与连续的分隔符清一下。
    t = t.replaceAll(RegExp(r'^(\s*\|\s*)+'), '').replaceAll(RegExp(r'(\s*\|\s*)+$'), '');
    t = t.replaceAll(RegExp(r'(\s*\|\s*){2,}'), ' | ');
    return t;
  }).where((l) => l.isNotEmpty).toList();
  // 连续重复行去重（模板注释/导航重复块）。
  final out = <String>[];
  for (final l in lines) {
    if (out.isNotEmpty && out.last == l && l.length < 40) continue;
    out.add(l);
  }
  return decodeEntities(out.join('\n'));
}

/// 常见命名实体 + 数字实体（与 websearch html_text 同口径的精简版）。
String decodeEntities(String s) {
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&ensp;', ' ')
      .replaceAll('&emsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&mdash;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll('&hellip;', '…')
      .replaceAll('&middot;', '·');
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final v = int.tryParse(m.group(1)!);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  return out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final v = int.tryParse(m.group(1)!, radix: 16);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
}
