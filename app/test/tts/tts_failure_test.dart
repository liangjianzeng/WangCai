import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/tts/edge_tts_service.dart';

/// 播报失败分类（纯函数）。
///
/// 背景：2026-10-10 微软强制 Sec-MS-GEC v2，v1 token 全站 403，而合成失败过去
/// 只 debugPrint → 用户侧只是「点 🔊 没声音」，排查成本极高。故失败要能分类、
/// 能上屏；分类逻辑用单测钉死（真机无法复现服务端故障，只能测分类）。
void main() {
  test('403/401 → denied（token 失效类），文案指向可行动原因', () {
    final f = classifyTtsError(Exception(
        "WebSocketException: was not upgraded to websocket, HTTP status code: 403"));
    expect(f.kind, TtsFailureKind.denied);
    expect(f.message, contains('token'));
  });

  test('超时 → network', () {
    final f = classifyTtsError(TimeoutException('TimeoutException after 0:01:00'));
    expect(f.kind, TtsFailureKind.network);
  });

  test('DNS/连接失败 → network', () {
    final f = classifyTtsError(Exception(
        'SocketException: Failed host lookup: \'speech.platform.bing.com\''));
    expect(f.kind, TtsFailureKind.network);
  });

  test('未知异常 → unknown 且保留原始信息（便于日志排查）', () {
    final f = classifyTtsError(StateError('boom-xyz'));
    expect(f.kind, TtsFailureKind.unknown);
    expect(f.message, contains('boom-xyz'));
  });

  test('空音频（音色与文本语言不匹配）有专属分类与换音色建议', () {
    const f = TtsFailure(TtsFailureKind.empty, '该音色对这段文本没有返回音频');
    expect(f.kind, TtsFailureKind.empty);
    expect(f.toString(), startsWith('empty:'));
  });
}
