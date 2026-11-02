/// data_api —— 通用多源数据 API 工具（provider 注册表框架）。
///
/// 设计（用户定案 2026-10-25）：**工具本体通用，业务是实例**。
/// - 每个数据域注册一个 provider（股票行情是第一个：stockProvider()），
///   以后汇率/宏观/天气 API 等同形态扩展，模型侧始终只见 `data_api` 一个工具；
/// - provider 自带参数 schema 碎片，工具 description 动态列出可用 source
///   与各自参数（`dataApiSourcesText()`），模型不用猜；
/// - provider 内部自行实现"多源热备合并"等策略（股票源见 stock_source.dart）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../tool_definition.dart';
import '../fetch_url_tool.dart' show FetchHttpResponse;
import 'stock_source.dart' show StockHttp, fetchStockData;

/// 一次 HTTP GET 的抽象响应（与 fetch_url 同款，测试桩可直接构造）。
// FetchHttpResponse 复用 fetch_url_tool.dart 的定义。

/// 注入缝：给定 URL 与请求头，返回响应。
typedef ApiHttp = Future<FetchHttpResponse> Function(
    Uri url, Map<String, String> headers);

/// 默认实现：dio 直连（15s 超时，跟随重定向）。
Future<FetchHttpResponse> defaultApiHttp(
    Uri url, Map<String, String> headers) async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
    followRedirects: true,
    maxRedirects: 5,
    validateStatus: (_) => true,
  ));
  final resp = await dio.get<List<int>>(url.toString(),
      options: Options(headers: headers, responseType: ResponseType.bytes));
  return FetchHttpResponse(
    statusCode: resp.statusCode ?? 0,
    contentType: resp.headers.value('content-type'),
    location: resp.headers.value('location'),
    bytes: resp.data ?? const [],
  );
}

/// 一个数据域 provider：id 即 data_api 的 `source` 参数值。
class DataApiProvider {
  final String id;
  final String description;

  /// 该 provider 的参数 schema 碎片（拼进工具 parameters 的 properties）。
  final Map<String, dynamic> params;

  final Future<ToolResult> Function(Map<String, dynamic> args) execute;

  const DataApiProvider({
    required this.id,
    required this.description,
    required this.params,
    required this.execute,
  });
}

/// 全部已注册 provider（股票行情 = 第一个实例；后续数据域追加到这里）。
final List<DataApiProvider> kDataApiProviders = [stockProvider()];

/// 供工具 description 用：列出可用 source 与参数。
String dataApiSourcesText() =>
    kDataApiProviders.map((p) => '- ${p.id}：${p.description}').join('\n');

/// 股票行情 provider —— 三源热备（腾讯/东财/新浪），K线不足自动并源合并。
///
/// [http] 为注入缝（测试桩）；生产传 null 用 dio 直连。
DataApiProvider stockProvider({ApiHttp? http}) {
  final StockHttp get = http ?? defaultApiHttp;
  return DataApiProvider(
    id: 'stock',
    description: '股票行情（A股/港股/美股）：K线（日/周/月，腾讯/东财/新浪三源'
        '热备合并）与实时快照（价/涨跌/PE/PB/市值/营收利润同比）',
    params: {
      'action': {
        'type': 'string',
        'enum': ['kline', 'quote', 'both'],
        'description': 'kline=K线（默认）/ quote=实时快照 / both=两者',
      },
      'symbol': {
        'type': 'string',
        'description':
            '股票代码：000157 / 000157.SZ / sz000157 / 600519.SH / hk00700 / usAAPL',
      },
      'period': {
        'type': 'string',
        'enum': ['day', 'week', 'month'],
        'description': 'K线周期（默认 day）',
      },
      'count': {
        'type': 'integer',
        'description': 'K线条数（默认 320，上限 800）',
      },
      'adjust': {
        'type': 'string',
        'enum': ['qfq', 'hfq', 'none'],
        'description': '复权（默认 qfq 前复权）',
      },
    },
    execute: (args) async {
      final symbol = args['symbol']?.toString().trim() ?? '';
      if (symbol.isEmpty) {
        return ToolResult.error('缺少 symbol 参数（如 000157 / 600519.SH / hk00700）');
      }
      try {
        final data = await fetchStockData(
          get,
          symbol: symbol,
          action: args['action']?.toString() ?? 'kline',
          period: args['period']?.toString() ?? 'day',
          count: args['count'] is int
              ? args['count'] as int
              : int.tryParse('${args['count'] ?? ''}') ?? 320,
          adjust: args['adjust']?.toString() ?? 'qfq',
        );
        return ToolResult(content: _encode(data));
      } catch (e) {
        return ToolResult.error('$e');
      }
    },
  );
}

/// data_api 工具本体：按 `source` 分发到 provider。
ToolDefinition createDataApiTool() {
  final props = <String, dynamic>{
    'source': {
      'type': 'string',
      'description': '数据源 id，可选值：\n${dataApiSourcesText()}',
    },
    for (final p in kDataApiProviders) ...p.params,
  };
  return ToolDefinition(
    name: 'data_api',
    description: '调用内置多源数据 API（行情/财务等结构化数据，多源热备合并）。'
        '先用 source 指定数据域，再按该域的参数传值。',
    parameters: {
      'type': 'object',
      'properties': props,
      'required': ['source', 'symbol'],
    },
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final source = args['source']?.toString().trim() ?? '';
      if (source.isEmpty) {
        return ToolResult.error(
            '缺少 source 参数。可用：\n${dataApiSourcesText()}');
      }
      final provider = kDataApiProviders
          .cast<DataApiProvider?>()
          .firstWhere((p) => p!.id == source, orElse: () => null);
      if (provider == null) {
        return ToolResult.error(
            '未知 source「$source」。可用：\n${dataApiSourcesText()}');
      }
      return provider.execute(args);
    },
  );
}

/// 紧凑输出：bars 每根一行（date,open,close,high,low,volume），其余键 JSON。
String _encode(Map<String, dynamic> data) {
  final bars = data['bars'];
  if (bars is List && bars.isNotEmpty) {
    final rest = Map<String, dynamic>.from(data)..remove('bars');
    return '${jsonEncode(rest)}\n'
        'bars(date,open,close,high,low,volume):\n'
        '${[for (final b in bars.cast<List<dynamic>>()) b.join(',')].join('\n')}';
  }
  return jsonEncode(data);
}
