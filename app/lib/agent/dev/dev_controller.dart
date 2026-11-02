/// 开发会话控制器（Dev Agent）—— 全局激活状态（工作区/任务），UI 与
/// 接入层共享，ChangeNotifier 驱动界面刷新。
///
/// 工具层不依赖本类：文件/ssh 工具只消费执行参数里的 `_workspaceId`
/// （由 ToolExecutor 的 workspaceResolver 注入），路径解析纯函数可测。
library;

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;

import 'workspace.dart';
import 'workspace_store.dart';

final class DevSessionController extends ChangeNotifier {
  DevSessionController._();

  /// 全局单例（接入层注入点：chat_provider / settings_screen）。
  static final DevSessionController instance = DevSessionController._();

  /// 测试注入的持久化 store（生产恒 null = 真实 path_provider 路径）。
  @visibleForTesting
  static DevStore? testStore;

  DevStore get _store => DevStore.resolve(testStore);

  List<DevWorkspace> _workspaces = [DevWorkspace.defaultWorkspace];
  String _activeWorkspaceId = DevWorkspace.kDefaultId;
  String? _activeTaskId;
  bool _loaded = false;

  /// 是否已完成初始化加载。
  bool get loaded => _loaded;

  /// 测试用：回到未加载态（单例只加载一次，用例之间需要重新 init）。
  @visibleForTesting
  void debugReset() {
    _loaded = false;
    _workspaces = [DevWorkspace.defaultWorkspace];
    _activeWorkspaceId = DevWorkspace.kDefaultId;
    _activeTaskId = null;
  }

  List<DevWorkspace> get workspaces => List.unmodifiable(_workspaces);

  String get activeWorkspaceId => _activeWorkspaceId;

  /// 激活工作区（未知 id 时回落默认）。
  DevWorkspace get activeWorkspace =>
      _workspaces.firstWhere((w) => w.id == _activeWorkspaceId,
          orElse: () => DevWorkspace.defaultWorkspace);

  /// 激活任务 id（Phase C；null = 无任务上下文）。
  String? get activeTaskId => _activeTaskId;

  /// 启动加载持久化工作区（幂等）。
  ///
  /// [preferredActiveId] = `InferenceSettings.devWorkspaceId`（老存放位，历史上
  /// 只写不读），仅作**首次**恢复的兜底种子；正常以 DevStore 落盘值为准。
  Future<void> init({String? preferredActiveId}) async {
    if (_loaded) return;
    try {
      final saved = await _store.loadWorkspaces();
      _workspaces = [DevWorkspace.defaultWorkspace, ...saved];
      // 激活态恢复优先级：DevStore 落盘值 > 设置里的 devWorkspaceId > 默认。
      final wanted = await _store.loadActiveWorkspaceId() ?? preferredActiveId;
      _activeWorkspaceId = _workspaces.any((w) => w.id == wanted)
          ? wanted!
          : DevWorkspace.kDefaultId;
      _loaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[Dev] init failed: $e');
      _loaded = true;
    }
  }

  /// 切换激活工作区**并持久化**；不存在则忽略。
  ///
  /// 必须落盘：激活态只存内存时，杀 App 重开会悄悄回落「默认工作区」，
  /// 远程工作区等于白配（模型收到的 `<workspace:context>` 变回本地沙盒，
  /// 表现就是"连上了远程电脑，它却不肯在电脑上干活"）。
  Future<void> switchWorkspace(String id) async {
    await init();
    if (!_workspaces.any((w) => w.id == id)) return;
    if (_activeWorkspaceId == id) return;
    _activeWorkspaceId = id;
    notifyListeners();
    await _store.saveActiveWorkspaceId(id);
  }

  /// 新增/更新工作区并持久化。
  Future<void> upsertWorkspace(DevWorkspace ws) async {
    await init();
    if (ws.isDefault) return;
    final idx = _workspaces.indexWhere((w) => w.id == ws.id);
    if (idx >= 0) {
      _workspaces[idx] = ws;
    } else {
      _workspaces.add(ws);
    }
    try {
      await _store.saveWorkspace(ws);
    } catch (e) {
      debugPrint('[Dev] save workspace failed: $e');
    }
    notifyListeners();
  }

  /// 删除工作区；删除激活的 → 回落默认。
  Future<void> deleteWorkspace(String id) async {
    await init();
    if (id == DevWorkspace.kDefaultId) return;
    _workspaces.removeWhere((w) => w.id == id);
    final wasActive = _activeWorkspaceId == id;
    if (wasActive) {
      _activeWorkspaceId = DevWorkspace.kDefaultId;
    }
    try {
      await _store.deleteWorkspace(id);
      // 删的正是激活项 → 激活标记也要清，否则下次启动恢复出一个幽灵 id
      // （靠校验回落默认虽不会崩，但会把设置里那份种子又捡回来）。
      if (wasActive) await _store.clearActiveWorkspaceId();
    } catch (e) {
      debugPrint('[Dev] delete workspace failed: $e');
    }
    notifyListeners();
  }

  Future<void> setActiveTask(String? taskId) async {
    _activeTaskId = taskId;
    notifyListeners();
  }

  /// 供接入层（chat_provider）注入 ToolExecutor.workspaceResolver：
  /// 返回当前激活 workspaceId（开发模式关闭时由接入层返回 null → 零回归）。
  Future<String?> resolveActiveWorkspaceId() async {
    await init();
    return _activeWorkspaceId;
  }
}
