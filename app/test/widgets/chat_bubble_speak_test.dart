// 消息 TTS 播放按钮「是否正控这场播报」判定：纯函数 isThisMessagePlaying。
//
// 触发点（2026-10）：自动播报用会话级 key `auto-$conversationId`，而播放按钮
// 自用的 key 是 `content.hashCode`——两者不同。按钮要同时认「精确匹配」与
//「本会话自动播报」，否则自动播报时图标不改停止态、点按反而重播。
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/widgets/chat_bubble.dart';

void main() {
  group('isThisMessagePlaying 按钮正控判定', () {
    const key = '42';
    const conv = 'conv-1';

    test('空闲（playing=null）= 不在播，图标播放态', () {
      expect(isThisMessagePlaying(null, key, conv), isFalse);
    });

    test('精确匹配本按钮 key = 正播本条', () {
      expect(isThisMessagePlaying(key, key, conv), isTrue);
    });

    test('本会话自动播报 key = 正播本条（修复的核心路径）', () {
      expect(isThisMessagePlaying('auto-$conv', key, conv), isTrue);
    });

    test('别的会话自动播报 ≠ 本按钮（不误停别的会话）', () {
      expect(isThisMessagePlaying('auto-other', key, conv), isFalse);
    });

    test('无关手动播报 key ≠ 本按钮', () {
      expect(isThisMessagePlaying('some-other-key', key, conv), isFalse);
    });

    test('无会话 id 时只认精确匹配（自动播报路径不可见）', () {
      expect(isThisMessagePlaying('auto-anything', key, null), isFalse);
      expect(isThisMessagePlaying(key, key, null), isTrue);
    });
  });
}
