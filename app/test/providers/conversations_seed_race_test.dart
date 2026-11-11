import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:wangcai/providers/chat_provider.dart';
import 'package:wangcai/providers/project_provider.dart';
import 'package:wangcai/services/storage_service.dart';

// ---------------------------------------------------------------------------
// 首启播种竞态（2026-11-11 Linux/WSLg 全新数据首启实案）
//
// 现场：conversationsProvider watch(activeProjectIdProvider)；首启时激活项目
// 从 null（未加载）→ p_default（「已创建默认项目」日志），provider 被重建。
// HomeScreen._initConversation 的 ensureLoaded 等的是旧实例 A，create() 写进
// A；await 期间项目上线触发重建，裸 read 拿到新实例 B 的**初始空态**，
// `conversations.first` 抛 Bad state → _initiallyLoaded 卡 false → 聊天区
// 全屏转圈永不结束（home_screen.dart:298 崩溃栈）。
//
// 修复锚两层：①重建后必须对**当前实例**再 ensureLoaded 才能读到落库会话
// （裸 read = 空 = 当年翻车形状）；②同实例路径 create 直接可见（回归基线）。
// ---------------------------------------------------------------------------

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_seed_race_');
    StorageService.dbPathOverrideForTest = '${tmp.path}/test.db';
  });

  tearDown(() async {
    StorageService.dbPathOverrideForTest = null;
    await StorageService.closeForTest();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(String? Function() activeId) {
    return ProviderContainer(overrides: [
      storageServiceProvider.overrideWith((ref) => StorageService()),
      activeProjectIdProvider.overrideWith((ref) => activeId()),
    ]);
  }

  test('跨重建播种：裸 read 是重建后的空态，对当前实例再等加载才见新会话', () async {
    String? active;
    final container = makeContainer(() => active);
    addTearDown(container.dispose);

    // 启动窗口：项目未加载（active=null）→ 实例 A 按「不过滤」全量加载。
    final a = container.read(conversationsProvider.notifier);
    await a.ensureLoaded();
    expect(container.read(conversationsProvider), isEmpty);

    // 全新环境播种：create() 入口 resolver 取到 null（pid=NULL=默认项目语义），
    // 落库 await 期间 projectsProvider 上线（null → p_default）并失效本 provider
    // ——时序对应 WSLg 实案日志「[Project] 已创建默认项目」。
    // 旧实例被销毁后 debug 在 state 写入处抛（release 断言关闭静默 no-op）——
    // home_screen 修复层对此 try/catch，本锚同样容错，聚焦钉重读不变量。
    final creating = a.create();
    active = 'p_default';
    container.invalidate(activeProjectIdProvider);
    try {
      await creating;
    } catch (_) {}

    // 复现点：裸 read = 新实例 B 的初始空态（当年 `.first` 就是在这里抛的）。
    expect(container.read(conversationsProvider), isEmpty,
        reason: '裸 read 必须复现重建空态，否则本锚失去复现价值');

    // 修复不变量：对当前实例（B）再等加载完成，落库会话必须可见
    // （NULL-pid 归 p_default 可见，storage getAllConversations 的兜底分支）。
    await container.read(conversationsProvider.notifier).ensureLoaded();
    final list = container.read(conversationsProvider);
    expect(list, hasLength(1));
    expect(list.single.title, '新对话');
  });

  test('同实例播种（项目先就绪）：create 后裸 read 直接可见，无需二次等待', () async {
    final container = makeContainer(() => 'p_default');
    addTearDown(container.dispose);

    final n = container.read(conversationsProvider.notifier);
    await n.ensureLoaded();
    expect(container.read(conversationsProvider), isEmpty);

    await n.create();
    expect(container.read(conversationsProvider), hasLength(1));
  });
}
