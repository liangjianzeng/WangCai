/// 项目状态 Provider（v0.0.3 Phase 1）—— 左栏项目选择器与会话过滤的真源。
///
/// 纪律：
/// - `projectsProvider` 是项目注册表 + 激活态的**唯一**内存镜像
///   （磁盘真源在 ProjectStore；这里只缓存 + 触发副作用）；
/// - 激活项目 → 派生 DevWorkspace（`ws_<projectId>`，localMirror=工作目录）
///   并切换之：shell/git/文件工具的 cwd 与 Dev 工作区胶囊显示的是**同一真源**
///   （消灭"聊天一个目录、开发一个目录"的双真源漂移）；
/// - `activeProjectIdProvider` 只在 activeId **变化**时通知依赖方
///   （riverpod 值相等去重），改名/刷新不会白白重载会话列表。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/dev/dev.dart'
    show DevSessionController, DevWorkspace, WorkspaceBackend;
import '../agent/dev/workspace_store.dart';
import '../project/project.dart';
import '../project/project_store.dart';

final projectStoreProvider =
    Provider<ProjectStore>((ref) => ProjectStore.resolve());

final projectsProvider =
    StateNotifierProvider<ProjectsNotifier, ProjectsState>(
        (ref) => ProjectsNotifier(ref.watch(projectStoreProvider)));

/// 项目列表 + 激活态快照（loaded=false = 首次加载未归，UI 别当空列表渲染）。
class ProjectsState {
  final List<Project> projects;
  final String activeId;
  final bool loaded;

  const ProjectsState({
    required this.projects,
    required this.activeId,
    this.loaded = false,
  });

  Project? get active => projects.where((p) => p.id == activeId).firstOrNull;

  ProjectsState copyWith({
    List<Project>? projects,
    String? activeId,
    bool? loaded,
  }) =>
      ProjectsState(
        projects: projects ?? this.projects,
        activeId: activeId ?? this.activeId,
        loaded: loaded ?? this.loaded,
      );
}

class ProjectsNotifier extends StateNotifier<ProjectsState> {
  ProjectsNotifier(this._store)
      : super(const ProjectsState(projects: [], activeId: Project.kDefaultId)) {
    _load();
  }

  final ProjectStore _store;

  List<Project> _sorted(List<Project> list) {
    list.sort((a, b) {
      final ao = a.lastOpenedAt ?? a.createdAt;
      final bo = b.lastOpenedAt ?? b.createdAt;
      return bo.compareTo(ao);
    });
    return list;
  }

  Future<void> _load() async {
    try {
      final ws = await DevStore().defaultWorkspaceDir();
      await _store.ensureDefault(ws);
      final list = _sorted(await _store.loadProjects());
      var active = await _store.loadActiveProjectId();
      if (active == null || !list.any((x) => x.id == active)) {
        active = Project.kDefaultId;
      }
      state = ProjectsState(projects: list, activeId: active, loaded: true);
      await _syncDevWorkspace(state.active);
    } catch (e) {
      debugPrint('[Project] 项目列表加载失败: $e');
      state = state.copyWith(loaded: true);
    }
  }

  Future<void> refresh() => _load();

  /// 新建项目（file_picker 选好的文件夹进来即成项目）；默认直接激活。
  Future<Project> create({
    required String name,
    required String workspacePath,
    String? sshConfigId,
    bool activate = true,
  }) async {
    final prj = await _store.create(
        name: name, workspacePath: workspacePath, sshConfigId: sshConfigId);
    if (activate) {
      await setActive(prj.id);
    } else {
      state = state.copyWith(projects: _sorted(await _store.loadProjects()));
    }
    return prj;
  }

  Future<void> rename(String id, String name) async {
    final prj = await _store.projectById(id);
    if (prj == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == prj.name) return;
    await _store.upsert(prj.copyWith(name: trimmed));
    state = state.copyWith(projects: _sorted(await _store.loadProjects()));
    if (state.activeId == id) {
      await _syncDevWorkspace(await _store.projectById(id));
    }
  }

  /// 移除项目记录（**不删会话数据目录**；默认项目拒绝）。
  Future<bool> remove(String id) async {
    final ok = await _store.remove(id);
    if (!ok) return false;
    final active =
        await _store.loadActiveProjectId() ?? Project.kDefaultId;
    state = state.copyWith(
      projects: _sorted(await _store.loadProjects()),
      activeId: active,
    );
    await _syncDevWorkspace(
        state.projects.where((p) => p.id == active).firstOrNull);
    return true;
  }

  Future<void> setActive(String id) async {
    final prj = await _store.projectById(id);
    if (prj == null) return;
    await _store.setActiveProjectId(id);
    state = state.copyWith(
        activeId: id, projects: _sorted(await _store.loadProjects()));
    await _syncDevWorkspace(prj);
  }

  /// 激活项目 → DevWorkspace 合一同步（见文件头纪律）。失败只记日志：
  /// 聊天不受影响，最多工具层落在旧目录。
  Future<void> _syncDevWorkspace(Project? prj) async {
    if (prj == null) return;
    try {
      final dev = DevSessionController.instance;
      final wsId = 'ws_${prj.id}';
      await dev.upsertWorkspace(DevWorkspace(
        id: wsId,
        name: prj.name,
        backend:
            prj.isRemote ? WorkspaceBackend.remotePc : WorkspaceBackend.localApp,
        localMirror: prj.isRemote ? null : prj.workspacePath,
        remotePath: prj.isRemote ? prj.workspacePath : null,
        sshConfigId: prj.isRemote ? prj.sshConfigId : null,
      ));
      await dev.switchWorkspace(wsId);
    } catch (e) {
      debugPrint('[Project] Dev 工作区同步失败（不影响聊天）: $e');
    }
  }
}

/// 当前激活项目 id（未加载完 = null，此时会话列表按"不过滤"处理避免闪空）。
final activeProjectIdProvider = Provider<String?>((ref) {
  final s = ref.watch(projectsProvider);
  return s.loaded ? s.activeId : null;
});

/// 当前激活项目实体（未加载/幽灵 id = null）。
final activeProjectProvider =
    Provider<Project?>((ref) => ref.watch(projectsProvider).active);
