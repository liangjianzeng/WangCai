/// 天气查询工具（wttr.in 免费 API，无需密钥）。
///
/// 返回指定城市的当前天气 + 简短预报。默认不注册（设置开启后挂载）。
library;

import 'package:dio/dio.dart';

import '../tool_definition.dart';

ToolDefinition createGetWeatherTool() {
  return ToolDefinition(
    name: 'get_weather',
    description: '查询指定城市当前天气与简要预报（免费接口，无需密钥）。',
    parameters: {
      'type': 'object',
      'properties': {
        'city': {'type': 'string', 'description': '城市名（中文/英文均可，如 "武汉" / "wuhan"）'},
      },
      'required': ['city'],
    },
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      final city = (args['city'] as String?)?.trim() ?? '';
      if (city.isEmpty) return ToolResult.error('缺少 city 参数');
      try {
        final dio = Dio();
        // 坑（2026-09-29 真机复现定案）：wttr.in 只认路径形态 `/城市`，
        // `/?q=城市` 的查询参数形态会返回 HTTP 500（curl/Dio 一致）。
        // 城市须 URL 编码（中文/空格），放路径里。
        final uri = 'https://wttr.in/${Uri.encodeComponent(city)}';
        final resp = await dio.get<String>(
          uri,
          queryParameters: {
            'format': '当前天气: %c, 温度: %t, 体感: %f, 湿度: %h, 风: %w, 降雨: %p',
            'm': '', // 公制单位
            'lang': 'zh',
          },
          options: Options(receiveTimeout: const Duration(seconds: 10)),
        );
        final text = resp.data?.trim() ?? '';
        if (text.isEmpty || text.contains('Unknown location')) {
          return ToolResult(content: '未查询到「$city」的天气，请确认城市名。');
        }
        return ToolResult(content: '$city：$text');
      } on DioException catch (e) {
        return ToolResult.error('天气查询失败：${e.message ?? e.type}');
      } catch (e) {
        return ToolResult.error('天气查询失败：$e');
      }
    },
  );
}
