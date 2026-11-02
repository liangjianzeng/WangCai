import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

void main() {
  ToolDefinition tool(String name) => ToolDefinition(
        name: name,
        description: 'tool $name',
        parameters: const {'type': 'object'},
        execute: (args) async => ToolResult(content: 'ok'),
      );

  group('tool registry', () {
    test('注册/注销/重复注册', () {
      final registry = ToolRegistry();
      registry.register(tool('a'));
      registry.register(tool('b'));
      expect(registry.all.map((t) => t.name), ['a', 'b']);

      registry.unregister('a');
      expect(registry.lookup('a'), isNull);

      // 重复注册同名工具 → 抛异常。
      registry.register(tool('c'));
      expect(() => registry.register(tool('c')), throwsArgumentError);
    });

    test('默认全模型可见', () {
      final registry = ToolRegistry();
      registry.register(tool('a'));
      registry.register(tool('b'));
      expect(registry.visibleFor('any-model').length, 2);
    });

    test('模型层 allow 过滤：只保留指定工具', () {
      final registry = ToolRegistry();
      registry.register(tool('a'));
      registry.register(tool('b'));
      registry.register(tool('c'));
      registry.restrictModel('m1', allow: {'a', 'c'});

      final visible = registry.visibleFor('m1');
      expect(visible.map((t) => t.name), ['a', 'c']);
      // 其他模型不受影响。
      expect(registry.visibleFor('m2').length, 3);
    });

    test('模型层 deny 过滤：移除指定工具', () {
      final registry = ToolRegistry();
      registry.register(tool('a'));
      registry.register(tool('b'));
      registry.restrictModel('m1', deny: {'a'});

      expect(registry.visibleFor('m1').map((t) => t.name), ['b']);
    });

    test('用户层遮蔽模型层：近层过滤叠加', () {
      final registry = ToolRegistry();
      registry.register(tool('a'));
      registry.register(tool('b'));
      registry.register(tool('c'));
      registry.restrictModel('m1', allow: {'a', 'b', 'c'});
      registry.restrictUser(deny: {'b'});

      // 用户 deny 移除 b，即使模型层允许。
      expect(registry.visibleFor('m1').map((t) => t.name), ['a', 'c']);
    });

    test('lookup 校验模型可见性：不可见返回 null', () {
      final registry = ToolRegistry();
      registry.register(tool('a'));
      registry.restrictModel('m1', allow: {});

      // 模型上下文下不可见。
      expect(registry.lookup('a', modelId: 'm1'), isNull);
      // 无模型上下文仍可见。
      expect(registry.lookup('a'), isNotNull);
      // 不存在的工具。
      expect(registry.lookup('nope'), isNull);
    });

    test('清空限制恢复默认', () {
      final registry = ToolRegistry();
      registry.register(tool('a'));
      registry.register(tool('b'));
      registry.restrictModel('m1', allow: {'a'});
      expect(registry.visibleFor('m1').length, 1);

      registry.restrictModel('m1'); // 传 null 清除
      expect(registry.visibleFor('m1').length, 2);
    });
  });
}
