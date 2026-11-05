/// 项目状态 Provider（v0.0.3 Phase 1；v0.0.4 D1 双真源收编）——
/// 左栏项目选择器、会话过滤与工作区注册表的唯一真源。
///
/// 纪律：
/// - `projectsProvider` 是项目注册表 + 激活态的**唯一**内存镜像
///   （磁盘真源在 ProjectStore；这里只缓存 + 触发副作用）；
/// - **D1（计划书 §5.3）**：`dev/workspaces` 不再是注册表，只是
///   projects.json 的**派生缓存**——`[DevSessionController.replaceWorkspaces]`
///   由本文件独占驱动（列表 = 每个项目派生一个 `ws_<projectId>`，孤儿文件
///   清除）；旧 dev 工作区的孤儿条目启动时一次性迁移为项目（不再双源）。
///   工具层的 remotePath 绝对化回写同样要落回 Project（见 dev_workspace_actions）；
/// - 激活项目 → 切换派生工作区：shell/git/文件工具的 cwd 与项目选择器显示
///   的是**同一真源**（消灭"聊天一个目录、开发一个目录"的双真源漂移）；
/// - `activeProjectIdProvider` 只在 activeId **变化**时通知依赖方
///   （riverpod 值相等去重），改名/刷新不会白白重载会话列表。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/dev/dev.dart'
    show
        DevSessionController,
        DevWorkspace,
        WorkspaceBackend,
        DevStore,
        SshEnvironmentService,
        ensureRemoteProjectDir,
        projectIdOfDevWorkspace;
import '../agent/dev/dev_workspace_actions.dart'
    show defaultRemoteProjectPathPlaceholder;
import '../project/project.dart';
import '../project/project_store.dart';

/// 项目 → 派生 DevWorkspace（工具层执行身份）。id 纪律 `ws_<projectId>`：
/// 这个前缀形态就是"派生项"的身份证，孤儿迁移据此甄别。
DevWorkspace devWorkspaceFor(Project prj) => DevWorkspace(
      id: 'ws_${prj.id}',
      name: prj.name,
      backend:
          prj.isRemote ? WorkspaceBackend.remotePc : WorkspaceBackend.localApp,
      localMirror: prj.isRemote ? null : prj.workspacePath,
      remotePath: prj.isRemote ? prj.workspacePath : null,
      sshConfigId: prj.isRemote ? prj.sshConfigId : null,
    );

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
      final ws = await DevStore.resolve().defaultWorkspaceDir();
      await _store.ensureDefault(ws);
      var list = _sorted(await _store.loadProjects());
      // D1：旧 dev 注册表里不属于任何项目的孤儿工作区 → 一次性迁移为项目
      //（迁移后 dev/workspaces 目录里不再存在孤儿文件，重入安全）。
      if (await _adoptLegacyDevWorkspaces()) {
        list = _sorted(await _store.loadProjects());
      }
      var active = await _store.loadActiveProjectId();
      if (active == null || !list.any((x) => x.id == active)) {
        active = Project.kDefaultId;
      }
      state = ProjectsState(projects: list, activeId: active, loaded: true);
      await _publishRegistry();
      await _syncDevWorkspace(state.active);
    } catch (e) {
      debugPrint('[Project] 项目列表加载失败: $e');
      state = state.copyWith(loaded: true);
    }
  }

  Future<void> refresh() => _load();

  /// 把 projects.json 全量投影到 dev/workspaces 派生缓存（孤儿文件清除）。
  /// 一切项目变更后必须调用——缓存与真源的收敛只走这一个入口。
  Future<void> _publishRegistry() async {
    try {
      await DevSessionController.instance
          .replaceWorkspaces(state.projects.map(devWorkspaceFor).toList());
    } catch (e) {
      debugPrint('[Project] 工作区派生缓存刷新失败（不影响聊天）: $e');
    }
  }

  /// 孤儿迁移（幂等）：dev/workspaces 里 id 不是 `ws_<现有项目>` 的条目，
  /// 收编为项目（local→localMirror/镜像目录；remote→remotePath，缺省
  /// `~/projects/<名>` 占位，首用时工具层会绝对化并回写）。
  /// 返回是否发生了迁移。失败只记日志不阻塞（下次启动还会再试）。
  Future<bool> _adoptLegacyDevWorkspaces() async {
    var migrated = false;
    try {
      final store = DevStore.resolve();
      final current = {for (final p in await _store.loadProjects()) 'ws_${p.id}'};
      for (final ws in await store.loadWorkspaces()) {
        if (ws.isDefault || current.contains(ws.id)) continue;
        final pid = projectIdOfDevWorkspace(ws.id) ?? 'p_mig_${ws.id}';
        if (await _store.projectById(pid) != null) {
          // 项目已在（缓存滞后于注册表）→ 只是陈旧文件，删。
          await store.deleteWorkspace(ws.id);
          migrated = true;
          continue;
        }
        String? path;
        if (ws.isRemote) {
          path = (ws.remotePath ?? '').trim().isNotEmpty
              ? ws.remotePath!.trim()
              : defaultRemoteProjectPathPlaceholder(ws.name);
        } else {
          path = (ws.localMirror ?? '').trim();
          if (path.isEmpty) path = await store.workspaceLocalMirror(ws.id);
        }
        await _store.upsert(Project(
          id: pid,
          name: ws.name,
          workspacePath: path,
          sshConfigId: ws.isRemote ? ws.sshConfigId : null,
          createdAt: DateTime.now(),
        ));
        await store.deleteWorkspace(ws.id);
        migrated = true;
        debugPrint('[Project] 旧工作区「${ws.name}」(${ws.id}) 已收编为项目 $pid');
      }
    } catch (e) {
      debugPrint('[Project] 旧工作区收编失败（下次启动重试）: $e');
    }
    return migrated;
  }

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
      await _publishRegistry();
    }
    return prj;
  }

  /// 「在已连接的电脑上开工」：远端建 `~/projects/<名>` → 建远程项目并激活。
  /// 取代旧的裸工作区创建（createWorkspaceOnActiveConnection）——远程开工
  /// 从此只产出项目，不再产生注册表之外的孤儿工作区。
  Future<({Project? prj, String dir})> createRemoteFromActiveConnection(
      String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return (prj: null, dir: '请填项目名称');
    final ssh = SshEnvironmentService.instance;
    final cfg = ssh.activeConfig;
    if (cfg == null || !ssh.isConnected) {
      return (
        prj: null,
        dir: '还没有已连接的开发环境：先到 设置 → 开发者 → 远程电脑 连上'
            '远程电脑/Termux（用账号密码就能连）'
      );
    }
    final dir = await ensureRemoteProjectDir(trimmed);
    if (dir == null) {
      return (prj: null, dir: '建目录失败：远端连接可能已断开，重连后再试');
    }
    final prj =
        await create(name: trimmed, workspacePath: dir, sshConfigId: cfg.id);
    return (prj: prj, dir: dir);
  }

  Future<void> rename(String id, String name) async {
    final prj = await _store.projectById(id);
    if (prj == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == prj.name) return;
    await _store.upsert(prj.copyWith(name: trimmed));
    state = state.copyWith(projects: _sorted(await _store.loadProjects()));
    await _publishRegistry();
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
    await _publishRegistry();
    await _syncDevWorkspace(state.projects.where((p) => p.id == active).firstOrNull);
    return true;
  }

  Future<void> setActive(String id) async {
    final prj = await _store.projectById(id);
    if (prj == null) return;
    await _store.setActiveProjectId(id);
    state = state.copyWith(
        activeId: id, projects: _sorted(await _store.loadProjects()));
    await _publishRegistry();
    await _syncDevWorkspace(prj);
  }

  /// 激活项目 → 切到其派生工作区（见文件头纪律）。失败只记日志：
  /// 聊天不受影响，最多工具层落在旧目录。
  Future<void> _syncDevWorkspace(Project? prj) async {
    if (prj == null) return;
    try {
      await DevSessionController.instance.switchWorkspace('ws_${prj.id}');
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
