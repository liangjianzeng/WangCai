import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';
import 'package:tongyi_lite/agent/web_search/web_search_seam.dart';

/// 记录查询并返回固定结果的假 provider（并发多关键词用）。
class _FakeSearchProvider implements WebSearchProvider {
  final List<String> called = [];
  final Map<String, List<WebSearchSource>> byQuery;

  _FakeSearchProvider(this.byQuery);

  @override
  String get id => 'fake';
  @override
  String get name => 'fake';
  @override
  String? available() => null;
  @override
  void dispose() {}
  @override
  Future<WebSearchResult> search(String query, {Duration? timeout}) async {
    called.add(query);
    return WebSearchResult(sources: byQuery[query] ?? const []);
  }
}

void main() {
  setUp(() {
    resetTodoStore();
  });

  group('todo 清单按会话隔离（todo v3）', () {
    test('不同会话清单互不可见', () async {
      await createTodoWriteTool(conversationId: 'convA').execute({
        'todos': [
          {'content': 'A会话任务'},
        ],
      });
      // 会话 B 读不到 A 的清单。
      final b = await createTodoListTool(conversationId: 'convB').execute(const {});
      expect(b.content, contains('没有待办'));
      expect(b.content, isNot(contains('A会话任务')));
      // A 自己可见。
      final a = await createTodoListTool(conversationId: 'convA').execute(const {});
      expect(a.content, contains('A会话任务'));
    });

    test('v2 全局文件一次性迁移到首个读取的会话（迁移即删，不再全局可见）', () async {
      debugSeedLegacyTodoFile('[{"content": "遗留任务", "status": "todo"}]');
      final first = await readTodoStore('convX');
      expect(first, hasLength(1));
      expect(first.first['content'], '遗留任务');
      // 全局文件已被删除：另一个会话读不到遗留内容。
      final other = await readTodoStore('convY');
      expect(other, isEmpty);
    });
  });

  group('todo_write 工具', () {
    test('写入清单并返回完整清单', () async {
      final tool = createTodoWriteTool(conversationId: 'c1');
      final result = await tool.execute({
        'todos': [
          {'content': '下载模型', 'status': 'done'},
          {'content': '验证推理'},
        ],
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('待办清单已更新'));
      expect(result.content, contains('1. [done] 下载模型'));
      expect(result.content, contains('2. [todo] 验证推理'));
    });

    test('单活跃强制（P2-A3）：两项 in_progress 被拒绝且原清单不变', () async {
      // 预置一条旧清单，验证拒绝后不被污染。
      await createTodoWriteTool(conversationId: 'c1').execute({
        'todos': [
          {'content': '旧任务', 'status': 'todo'},
        ],
      });
      final result = await createTodoWriteTool(conversationId: 'c1').execute({
        'todos': [
          {'content': '任务A', 'status': 'in_progress'},
          {'content': '任务B', 'status': 'in_progress'},
        ],
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('in_progress'));
      expect(result.content, contains('只能有一项进行中'));
      // 原清单保持不变
      final list = await createTodoListTool(conversationId: 'c1').execute(const {});
      expect(list.content, contains('旧任务'));
      expect(list.content, isNot(contains('任务A')));
    });

    test('单活跃强制：doing 是 in_progress 别名，同样计入', () async {
      final result = await createTodoWriteTool(conversationId: 'c1').execute({
        'todos': [
          {'content': '任务A', 'status': 'in_progress'},
          {'content': '任务B', 'status': 'doing'},
        ],
      });
      expect(result.isError, isTrue);
    });

    test('计数回显（P2-A3）：更新结果带待办/进行中/已完成计数', () async {
      final result = await createTodoWriteTool(conversationId: 'c1').execute({
        'todos': [
          {'content': '已完成的事', 'status': 'done'},
          {'content': '正在做的事', 'status': 'in_progress'},
          {'content': '还没做的事'},
        ],
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('待办 1 · 进行中 1 · 已完成 1'));
      expect(result.content, contains('待办清单已更新'));
    });

    test('todo_list 可读取当前清单', () async {
      await createTodoWriteTool(conversationId: 'c1').execute({
        'todos': [
          {'content': '写代码'},
        ],
      });
      final result = await createTodoListTool(conversationId: 'c1').execute(const {});
      expect(result.isError, isFalse);
      expect(result.content, contains('1. [todo] 写代码'));
    });

    test('空清单 todo_list 提示无任务', () async {
      final result = await createTodoListTool(conversationId: 'c1').execute(const {});
      expect(result.isError, isFalse);
      expect(result.content, contains('没有待办'));
    });

    test('缺少 todos 参数 → 错误', () async {
      final result = await createTodoWriteTool(conversationId: 'c1').execute(const {});
      expect(result.isError, isTrue);
      expect(result.content, contains('todos'));
    });

    test('空数组 → 错误', () async {
      final result = await createTodoWriteTool(conversationId: 'c1').execute({'todos': []});
      expect(result.isError, isTrue);
      expect(result.content, contains('为空'));
    });

    test('空任务内容 → 错误', () async {
      final result = await createTodoWriteTool(conversationId: 'c1').execute({
        'todos': [
          {'content': '  '},
        ],
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('不能为空'));
    });

    test('todos 为 JSON 字符串（XML 协议形态）→ 同样可写入', () async {
      final result = await createTodoWriteTool(conversationId: 'c1').execute({
        'todos': '[{"content": "明天开会", "status": "todo"}]',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('1. [todo] 明天开会'));
    });

    test('todos 为非法 JSON 字符串 → 错误', () async {
      final result = await createTodoWriteTool(conversationId: 'c1').execute({
        'todos': '不是合法数组',
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('todos'));
    });
  });

  group('web_search 工具', () {
    test('缺少 query → 错误', () async {
      final result = await createWebSearchTool().execute(const {});
      expect(result.isError, isTrue);
      expect(result.content, contains('query'));
    });

    test('空 query → 错误', () async {
      final result = await createWebSearchTool().execute({'query': '   '});
      expect(result.isError, isTrue);
      expect(result.content, contains('query'));
    });

    test('additional_queries：一次调用并发搜索多个关键词并合并返回', () async {
      final provider = _FakeSearchProvider({
        '国庆 武汉 活动 2026': [
          const WebSearchSource(url: 'http://a', title: '国庆活动清单', snippet: '武汉国庆活动'),
        ],
        '武汉 天气 2026': [
          const WebSearchSource(url: 'http://b', title: '武汉天气', snippet: '晴转多云'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({
          'query': '国庆 武汉 活动',
          'additional_queries': ['武汉 天气'],
        });
        // 两个关键词都被搜索（年份补全后）。
        expect(provider.called, contains('国庆 武汉 活动 2026'));
        expect(provider.called, contains('武汉 天气 2026'));
        // 合并结果带关键词小节归属，两个角度都可见。
        expect(result.isError, isFalse);
        expect(result.content, contains('[搜索：国庆 武汉 活动 2026]'));
        expect(result.content, contains('[搜索：武汉 天气 2026]'));
        expect(result.content, contains('国庆活动清单'));
        expect(result.content, contains('武汉天气'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('additional_queries 截断：最多 4 个关键词，空串忽略', () async {
      final provider = _FakeSearchProvider({});
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({
          'query': 'q',
          'additional_queries': ['a', 'b', 'c', 'd', 'e', '  '],
        });
        // query + 最多 3 个附加 = 4 次搜索；空串被过滤。
        expect(provider.called.length, 4);
        expect(provider.called, isNot(contains('  ')));
        expect(result.isError, isFalse);
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('重复关键词：同回合再次搜索相同内容 → 直接回缓存结果，不重复联网', () async {
      final provider = _FakeSearchProvider({
        '华为开发者大会 2026': [
          const WebSearchSource(url: 'http://a', title: '华为大会', snippet: '开发者大会'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final tool = createWebSearchTool();
        final first = await tool.execute({'query': '华为开发者大会'});
        expect(first.isError, isFalse);
        expect(first.content, contains('华为大会'));
        // 同回合再次以相同关键词调用：命中缓存，不再触发 provider.search。
        final second = await tool.execute({'query': '华为开发者大会'});
        expect(provider.called.length, 1);
        expect(second.isError, isFalse);
        expect(second.content, contains('已搜索过'));
        expect(second.content, contains('华为大会'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('预算上限：超过每回合搜索次数 → 拒绝联网并返回收敛指令', () async {
      final provider = _FakeSearchProvider({});
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final tool = createWebSearchTool(maxSearchesPerTurn: 2);
        await tool.execute({'query': 'q1'});
        await tool.execute({'query': 'q2'});
        // 第 3 次：预算耗尽 → 不联网，返回收敛指令（isError=true）。
        final third = await tool.execute({'query': 'q3'});
        expect(provider.called.length, 2);
        expect(third.isError, isTrue);
        expect(third.content, contains('已达上限'));
        expect(third.content, contains('不要再调用 web_search'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('预算含重复调用：重复也消耗预算，尽快逼模型收敛', () async {
      final provider = _FakeSearchProvider({
        'q 2026': [
          const WebSearchSource(url: 'http://a', title: '标题A', snippet: '摘要A'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final tool = createWebSearchTool(maxSearchesPerTurn: 2);
        await tool.execute({'query': 'q'});
        await tool.execute({'query': 'q'}); // 去重命中，但仍消耗预算
        // 预算已满（2/2）→ 新的关键词直接返回收敛指令，不再联网。
        final third = await tool.execute({'query': '新关键词'});
        expect(provider.called.length, 1);
        expect(third.isError, isTrue);
        expect(third.content, contains('已达上限'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });
  });
}
