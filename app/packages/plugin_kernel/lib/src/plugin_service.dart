/// 编排层：把加载器、fiber、能力注册表、槽账本、配置与追踪拧成一台可用的机器。
///
/// 面板只跟这个类打交道（对齐 DSH 的 `ManagementService`：`ChangeResult{changed, application, ...}`
/// **两个事实分开** —— "值变了没有" 与 "生效了没有" 是两回事；重启才能生效的必须明说）。
library;

import 'package:plugin_sdk/plugin_sdk.dart';

import 'capability_registry.dart';
import 'config_layers.dart';
import 'ctx_impl.dart';
import 'fiber.dart';
import 'loader.dart';
import 'profiles.dart';
import 'trace.dart';

/// 改动生效状态（闭集）。**`changed` 与 `application` 是两个独立事实**。
enum PluginApplication {
  /// 立刻生效。
  applied,

  /// 值已记下，但要**重启 / 重新启用**才生效（面板必须显示成黄条，不能显示"已保存"了事）。
  restartRequired,

  /// 被更高层覆盖（例如方案档锁死了这个参数），改动没落地。
  overridden,

  /// 失败（带 [PluginChangeResult.failure]）。
  failed,

  /// 用户中途取消。
  cancelled,
}

final class PluginChangeResult {
  const PluginChangeResult({
    required this.changed,
    required this.application,
    this.stage,
    this.restartReason,
    this.warnings = const [],
    this.failure,
    this.usedLastGood = false,
  });

  const PluginChangeResult.unchanged()
      : changed = false,
        application = PluginApplication.applied,
        stage = null,
        restartReason = null,
        warnings = const [],
        failure = null,
        usedLastGood = false;

  final bool changed;
  final PluginApplication application;

  /// 这次扫描一个都没解析出来、沿用了上一次好的树（面板必须显式说明，不能装作一切正常）。
  final bool usedLastGood;

  /// 在哪个阶段出问题（面板定位：scan / apply / dispose / save）。
  final String? stage;
  final String? restartReason;
  final List<String> warnings;
  final PluginFailure? failure;

  bool get ok => application != PluginApplication.failed;
}

/// 启用集持久化端口（app 用 `settings_service` 实现；内核不碰磁盘）。
abstract interface class EnabledStore {
  Set<String> read();
  void write(Set<String> enabledIds);
}

/// 内存版启用集：测试、`--check` 冒烟、以及"没接磁盘"的开发环境用它。
/// （app 侧仍用自己的 settings_service 实现，内核不碰磁盘。）
final class MemoryEnabledStore implements EnabledStore {
  MemoryEnabledStore([Set<String>? seed]) : ids = {...?seed};

  final Set<String> ids;
  int writes = 0;

  @override
  Set<String> read() => Set.of(ids);

  @override
  void write(Set<String> enabledIds) {
    ids
      ..clear()
      ..addAll(enabledIds);
    writes++;
  }
}

/// "第一次见到某个插件时，按作者声明的 `enabledByDefault` 打开它" —— **由宿主实现并持久化**，内核不碰磁盘。
///
/// 为什么非得记住"见没见过"：如果每次扫描都按声明播种，用户把它关掉后下一次重扫又被打开 ——
/// **用户明确的决定永远优先于作者的默认值**。所以播种只允许发生在第一次见到这个 id 的时候。
///
/// 为什么这件事在内核做而不在宿主做：`enabledByDefault` 写在 `plugin.json` 里，
/// 而"扫到了哪些插件"只有内核知道。以前 app 只在**扫描之前**按内置件播种，
/// 于是从 `文档/plugins/` 装进来的插件写了 `enabledByDefault: true` 也**永远不生效** ——
/// 一个作者照着文档写了、却什么都没发生的开关。
abstract interface class FirstRunSeeder {
  /// 从 [candidateIds] 里挑出**从没见过的**那些，并把它们记为"已见过"。
  Set<String> firstTimeSeen(Iterable<String> candidateIds);
}

/// 内存版：测试、`--check` 冒烟，以及"没接磁盘"的开发环境（重启即忘，符合它们的定位）。
final class MemoryFirstRunSeeder implements FirstRunSeeder {
  MemoryFirstRunSeeder([Iterable<String>? seen]) : _seen = {...?seen};

  final Set<String> _seen;
  Set<String> get seen => Set.of(_seen);

  @override
  Set<String> firstTimeSeen(Iterable<String> candidateIds) {
    final fresh = candidateIds.where((id) => !_seen.contains(id)).toSet();
    _seen.addAll(fresh);
    return fresh;
  }
}

/// 面板列表项（现场读注册表，不留第二份缓存）。
final class PluginView {
  PluginView({
    required this.loaded,
    required this.state,
    required this.lastFailure,
    required this.effectTree,
    required this.slotCount,
  });

  final LoadedPlugin loaded;
  final FiberState? state;
  final PluginFailure? lastFailure;
  final List<Map<String, Object?>> effectTree;
  final int slotCount;

  String get id => loaded.id;
  PluginManifest get manifest => loaded.descriptor.manifest;
  bool get running => state == FiberState.active;
}

class PluginService {
  PluginService({
    required this.loader,
    required this.capabilities,
    required this.slots,
    required this.configStore,
    required this.enabledStore,
    TraceSink? trace,
    TraceIds? traceIds,
    this.profiles,
    this.activeProfile,
    this.firstRun,
    this.hostSlots = kHostSlotContract,
  })  : trace = trace ?? InMemoryTraceSink(),
        traceIds = traceIds ?? TraceIds();

  final PluginLoader loader;
  final CapabilityRegistry capabilities;
  final SlotRegistry slots;
  final ConfigStore configStore;
  final EnabledStore enabledStore;
  final TraceSink trace;
  final TraceIds traceIds;

  /// 宿主在启动时声明的位置（冻结件）。
  final List<SlotDef> hostSlots;

  /// 方案档账本（null = 这个 app 还没做档）。
  final ProfileStore? profiles;

  /// 当前生效的档名（由宿主从设置里读；每次扫描现读，切档后 `reload()` 即生效）。
  final String? Function()? activeProfile;

  /// 首次播种的"见没见过"账本（null = 宿主没接，那就不播种 —— 宁可不动也不瞎开）。
  final FirstRunSeeder? firstRun;

  /// 最近一次扫描实际生效的档结果（**面板预览就读它**：与 runtime 同源，见 [ProfileStore.compose]）。
  ProfileComposition get composition => _composition;
  ProfileComposition _composition = const ProfileComposition.passthrough({});

  /// 上一次见过的插件 id 全集：用来判断"档里写的插件本机到底有没有"（首次扫描为空 = 不下判断，fail-safe）。
  Set<String> _knownIds = const {};

  final Map<String, PluginFiber> _fibers = {};
  LoadResult? _result;
  LoadResult? get result => _result;

  /// 启用态（面板显示开关状态；由最近一次 scan 得出）。
  bool isEnabled(String id) => _result?.byId(id)?.status != PluginLoadStatus.disabled;

  /// 启动：声明宿主槽 → 扫描 → 加载该加载的。
  Future<Outcome<PluginChangeResult>> boot() async {
    for (final d in hostSlots) {
      slots.declare(d); // 幂等：已声明过的由注册表挡回来（同 owner 重复声明是 no-op 级错误）
    }
    return reload();
  }

  /// 这一趟是否播过种（播过就要按新的启用集**再走一遍**，见 [reload]）。
  Set<String> _seededThisReload = const {};

  /// 重扫目录并让 fiber 集与"应启用集"对齐（热重扫入口；坏文件保上次好的树在 loader 里）。
  ///
  /// 可能跑两趟，只多不少：第一趟若"第一次见到某插件并按 `enabledByDefault` 播了种"，
  /// 启用集就已经变了 —— 而启用集的唯一真源是 `EnabledStore`，**不能一半按旧集一半按新集**，
  /// 所以按新集再走一趟（每新装一个插件最多各一次，不是循环）。
  Future<Outcome<PluginChangeResult>> reload() async {
    final first = await _reloadOnce();
    if (_seededThisReload.isEmpty) return first;
    _seededThisReload = const {};
    return _reloadOnce();
  }

  Future<Outcome<PluginChangeResult>> _reloadOnce() async {
    // **启用集的唯一真源是 [EnabledStore]**：每次扫描前都从它读一遍。
    // 早先只靠调用方记得 `loader.setEnabledIds(...)`，结果 app 冷启动时没人喂 →
    // 用户开过的开关、`enabledByDefault` 播种全被当成"没启用"（治理面板测试当场抓到）。
    // 平台不能把"记得同步"这件事外包给宿主。
    // 档名全集每次现读：boot 之后新增/删掉档文件，下一次扫描就该跟得上（面板"重新扫描"即生效）。
    loader.knownProfiles = {for (final n in (profiles?.names() ?? const <String>[])) n};
    final persisted = enabledStore.read();
    final store = profiles;
    _composition = store == null
        ? ProfileComposition.passthrough(Set.of(persisted))
        : store.compose(active: activeProfile?.call(), persistedEnabled: persisted, allIds: _knownIds);
    for (final e in _composition.config.entries) {
      configStore.replaceProfile(_composition.profile!, e.key, e.value);
    }
    configStore.setActiveProfile(_composition.profile);
    loader.setEnabledIds(_composition.enabled);
    final r = loader.scan();
    if (r.isErr) {
      return Err<PluginChangeResult>(r.failureOrNull!.scoped(step: 'scan'));
    }
    _result = r.valueOrNull;
    // "本机到底有哪些插件"只认**真的从来源里读出来的那些**：
    // `broken.keys` / 档里写的 id 都不能算数，否则档写了一个不存在的插件反而" exists"。
    _knownIds = {..._result!.plugins.map((p) => p.id)};
    // 首次播种：**只有第一次见到的插件**才按声明打开；用户后来关掉就永远不再被打开。
    final seeder = firstRun;
    if (seeder != null) {
      final fresh = seeder.firstTimeSeen(_knownIds);
      final toAdd = <String>{
        for (final p in _result!.plugins)
          if (fresh.contains(p.id) && p.descriptor.manifest.enabledByDefault) p.id,
      };
      if (toAdd.isNotEmpty) {
        enabledStore.write({...enabledStore.read(), ...toAdd});
        _seededThisReload = toAdd;
      }
    }
    final warnings = <String>[..._composition.warnings];
    // "档里写了本机没有的插件"这条只有扫完才知道（首次扫描前没有 id 全集，
    // 那时不能瞎判 —— 宁可少说一条也不许把档里的插件误删）。
    final activeName = _composition.profile;
    final declared = activeName == null ? null : profiles?.profile(activeName);
    if (declared != null && declared.declaresSet) {
      final ghosts = declared.enabled.difference(_knownIds).toList()..sort();
      if (ghosts.isNotEmpty && !warnings.any((w) => w.contains('本机没有'))) {
        warnings.add('方案档「$activeName」里有几个插件本机没有：${ghosts.join('、')}');
      }
    }
    if (_result!.usedLastGood) {
      warnings.add('这次扫描一个插件都没能解析出来，先沿用上一次好的清单');
    }
    for (final e in _result!.broken.entries) {
      warnings.add('${e.key}：${e.value.map((i) => i.message).join('；')}');
    }

    final shouldRun = _result!.byStatus(PluginLoadStatus.active);
    final shouldRunIds = shouldRun.map((p) => p.id).toSet();

    // 该停的停（含被禁用、被门控、被遮蔽掉的）
    for (final entry in _fibers.entries.toList()) {
      if (!shouldRunIds.contains(entry.key)) {
        await entry.value.unload(reason: '已停用或不再满足加载条件');
        _fibers.remove(entry.key);
      }
    }
    var failed = 0;
    for (final p in shouldRun) {
      final fiber = _fibers.putIfAbsent(p.id, () => _makeFiber(p));
      final res = await fiber.ensure();
      if (res.isErr) failed += 1;
    }
    return Ok<PluginChangeResult>(PluginChangeResult(
      changed: true,
      application: failed == 0 ? PluginApplication.applied : PluginApplication.failed,
      stage: failed == 0 ? null : 'apply',
      warnings: warnings,
      usedLastGood: _result!.usedLastGood,
      failure: failed == 0
          ? null
          : Outcome.err<void>(code: PluginFailureKind.runtimeError, message: '$failed 个插件启动失败').failureOrNull,
    ));
  }

  /// 开关一个插件（面板的唯一入口）。
  Future<Outcome<PluginChangeResult>> setEnabled(String id, bool enabled) async {
    final ids = Set<String>.of(enabledStore.read());
    final before = Set<String>.of(ids);
    if (enabled) {
      ids.add(id);
    } else {
      ids.remove(id);
    }
    if (before.length == ids.length && before.contains(id) == enabled) {
      return const Ok<PluginChangeResult>(PluginChangeResult.unchanged());
    }
    enabledStore.write(ids);
    loader.setEnabledIds(ids);
    final r = await reload();
    return r;
  }

  /// 面板预览：如果切到这个档，会开哪些插件、参数怎么覆盖。
  ///
  /// **与 runtime 走同一个 [ProfileStore.compose]**（compose == preview）：
  /// 面板上写"会开三个"、切完只开两个，是平台最不该有的那种谎言。
  ProfileComposition previewProfile(String? name) => profiles?.compose(
        active: name,
        persistedEnabled: enabledStore.read(),
        allIds: _knownIds,
      ) ??
      ProfileComposition.passthrough(enabledStore.read());

  /// 失败重试（面板"重试"按钮）。
  ///
  /// "没东西可重试"的三种情况必须说清楚，不能退回 `reload()` 让用户以为按下去了：
  /// 清单就没过（改 `plugin.json` 才有用）/ 它是关着的（该去开开关，重试不会替你打开）/ 本机没有这个插件。
  /// 以前这三种都走 `reload()` → 面板回一句「已重试」，用户白等一轮，问题原样留着。
  Future<Outcome<PluginChangeResult>> retry(String id) async {
    final fiber = _fibers[id];
    if (fiber == null) {
      final loaded = _result?.byId(id);
      if (loaded == null || loaded.status == PluginLoadStatus.rejected) {
        return Ok<PluginChangeResult>(PluginChangeResult(
          changed: false,
          application: PluginApplication.failed,
          stage: 'retry',
          failure: Outcome.err<void>(
            code: PluginFailureKind.configInvalid,
            message: '「$id」没有可重试的东西 —— 它连清单都没通过，或本机没有这个插件',
            hint: '照体检里的硬问题改 plugin.json，再按「重新扫描」；列表里没有它就是本机没有',
            pluginId: id,
            step: 'retry',
          ).failureOrNull,
        ));
      }
      if (loaded.status == PluginLoadStatus.disabled) {
        return Ok<PluginChangeResult>(PluginChangeResult(
          changed: false,
          application: PluginApplication.failed,
          stage: 'retry',
          failure: Outcome.err<void>(
            code: PluginFailureKind.runtimeError,
            message: '「$id」是关着的：重试不会替你打开开关',
            hint: '先把条目的开关打开；开不起来时看体检里"为什么跑不起来"那一条',
            pluginId: id,
            step: 'retry',
          ).failureOrNull,
        ));
      }
      // 其它状态（还没建 fiber 的）：真重扫一遍比空转有用。
      return reload();
    }
    final r = await fiber.retry();
    return Ok<PluginChangeResult>(PluginChangeResult(
      changed: true,
      application: r.isOk ? PluginApplication.applied : PluginApplication.failed,
      stage: r.isOk ? null : 'apply',
      failure: r.failureOrNull,
    ));
  }

  /// 「先试试这组值」：只写进**会话层**（不落盘），再照 epoch 决定要不要重载插件。
  ///
  /// 有了这条入口，四层里的 session 层才真的有人能写：面板上那个「本次会话临时」才是实话，
  /// 用户也能先试 8 秒的间隔再决定要不要改设置 —— 不必"先改坏设置，再记得改回来"。
  /// 校验与 `setConfig` 同一条（临时值照样会念给用户听，越界一样拒）。
  Future<Outcome<PluginChangeResult>> trialConfig({
    required String id,
    required Map<String, Object?> patch,
  }) async {
    final loaded = _result?.byId(id);
    if (loaded == null) {
      return Ok<PluginChangeResult>(PluginChangeResult(
        changed: false,
        application: PluginApplication.failed,
        stage: 'lookup',
        failure: Outcome.err<void>(
          code: PluginFailureKind.configInvalid,
          message: '没有这个插件',
          hint: '刷新插件列表再看看',
          pluginId: id,
        ).failureOrNull,
      ));
    }
    final manifest = loaded.descriptor.manifest;
    final before = configStore.stackFor(manifest);
    final r = configStore.trial(manifest: manifest, patch: patch);
    if (r.isErr) return Err<PluginChangeResult>(r.failureOrNull!);
    return _afterConfigChange(id, before, configStore.stackFor(manifest));
  }

  /// 保存配置（带 revision fencing）。改完若影响生效值 → 重载该插件。
  Future<Outcome<PluginChangeResult>> setConfig({
    required String id,
    required Map<String, Object?> patch,
    int? expectedRevision,
  }) async {
    final loaded = _result?.byId(id);
    if (loaded == null) {
      // 保存类操作统一返回 ChangeResult（面板一个分支就能画完）：失败也是"结果"，不是异常。
      return Ok<PluginChangeResult>(PluginChangeResult(
        changed: false,
        application: PluginApplication.failed,
        stage: 'lookup',
        failure: Outcome.err<void>(
          code: PluginFailureKind.configInvalid,
          message: '没有这个插件',
          hint: '刷新插件列表再看看',
          pluginId: id,
        ).failureOrNull,
      ));
    }
    final manifest = loaded.descriptor.manifest;
    final before = configStore.stackFor(manifest);
    final saved = configStore.patchUser(manifest: manifest, patch: patch, expectedRevision: expectedRevision);
    if (saved.isErr) {
      return Ok<PluginChangeResult>(PluginChangeResult(
        changed: false,
        application: PluginApplication.failed,
        stage: 'save',
        failure: saved.failureOrNull,
      ));
    }
    return _afterConfigChange(loaded.id, before, configStore.stackFor(manifest), ignoreSession: true);
  }

  /// 恢复默认：**只清用户层**（方案档与插件自己声明的默认值都留着），然后像 [setConfig] 一样决定要不要重载。
  ///
  /// 这个出口必须存在并且**在面板上点得到**：四层配置（默认 / 方案档 / 用户 / 本次会话）里
  /// 最容易改坏的就是用户层，而没有"退回默认"就等于把用户关在自己做错的那个值里 ——
  /// 他只能凭记忆把每一条原值手打回去，那是把改错的代价转嫁给用户。
  Future<Outcome<PluginChangeResult>> resetConfig({required String id}) async {
    final loaded = _result?.byId(id);
    if (loaded == null) {
      return Ok<PluginChangeResult>(PluginChangeResult(
        changed: false,
        application: PluginApplication.failed,
        stage: 'lookup',
        failure: Outcome.err<void>(
          code: PluginFailureKind.configInvalid,
          message: '没有这个插件',
          hint: '刷新插件列表再看看',
          pluginId: id,
        ).failureOrNull,
      ));
    }
    final manifest = loaded.descriptor.manifest;
    final before = configStore.stackFor(manifest);
    if (configStore.userOf(id).isEmpty && configStore.sessionOf(id).isEmpty) {
      // 本来就没动过：不空转 revision，也不给用户"我恢复了什么"的错觉。
      return const Ok<PluginChangeResult>(PluginChangeResult(changed: false, application: PluginApplication.applied));
    }
    // 「恢复默认」把**用户层与本次临时试的值一起清**（方案档与插件声明的默认都留着）。
    // 只清一层却报"已恢复默认"，用户下次看到的还是那个试出来的值 —— 又是一句不算数的回执。
    configStore.resetUser(id);
    configStore.clearSessionOverrides(id);
    return _afterConfigChange(id, before, configStore.stackFor(manifest), ignoreSession: true);
  }

  /// 配置变完之后的统一收尾：只动易变值就不重载，否则靠 epoch 让 fiber 自愈。
  Future<Outcome<PluginChangeResult>> _afterConfigChange(
    String id,
    ConfigStack before,
    ConfigStack after,
    {bool ignoreSession = false}
  ) async {
    // 「改了没有」按可持久的那几层判（会话层压在上面时，合并值会一直"没变化"，
    // 于是用户保存成功却被回一句「没有变化」）。试值那条入口反过来：它就该按合并值判。
    if (ignoreSession
        ? before.persistedOnly.sameExceptVolatile(after.persistedOnly)
        : before.sameExceptVolatile(after)) {
      // 只动了易变值（例如记下"上次用的间隔"）：不重载、不提示"配置已改动"。
      return const Ok<PluginChangeResult>(PluginChangeResult(changed: false, application: PluginApplication.applied));
    }
    final fiber = _fibers[id];
    if (fiber == null) {
      return const Ok<PluginChangeResult>(
        PluginChangeResult(changed: true, application: PluginApplication.restartRequired, restartReason: '插件当前未运行，下次启用时生效'),
      );
    }
    final r = await fiber.ensure(); // epoch 含配置指纹 → 自动重载
    return Ok<PluginChangeResult>(PluginChangeResult(
      changed: true,
      application: r.isOk ? PluginApplication.applied : PluginApplication.failed,
      stage: r.isOk ? null : 'apply',
      failure: r.failureOrNull,
    ));
  }

  /// 运行一个插件（chip 点击 / slash 命令 / 智能体工具共用同一条路）。
  Future<Outcome<PluginRunResult>> run(String id, PluginInput input) async {
    final loaded = _result?.byId(id);
    if (loaded == null) {
      return Err<PluginRunResult>(Outcome.err<void>(
        code: PluginFailureKind.configInvalid,
        message: '没有「$id」这个插件',
        hint: '刷新插件列表再看看',
        pluginId: id,
      ).failureOrNull!);
    }
    switch (loaded.status) {
      case PluginLoadStatus.disabled:
        return Err<PluginRunResult>(Outcome.err<void>(
          code: PluginFailureKind.configInvalid,
          message: '「${loaded.descriptor.manifest.name}」已被停用',
          hint: '去「插件」页打开它',
          pluginId: id,
        ).failureOrNull!);
      case PluginLoadStatus.gated:
        return Err<PluginRunResult>(Outcome.err<void>(
          code: PluginFailureKind.missingCapability,
          message: '「${loaded.descriptor.manifest.name}」还缺：${loaded.gatedOn.join('、')}',
          hint: '看「插件」页里写明的前置条件',
          pluginId: id,
        ).failureOrNull!);
      case PluginLoadStatus.rejected:
        return Err<PluginRunResult>(Outcome.err<void>(
          code: PluginFailureKind.configInvalid,
          message: '「${loaded.descriptor.manifest.name}」的声明有问题，跑不起来',
          hint: '打开插件详情看具体是哪一条',
          pluginId: id,
        ).failureOrNull!);
      case PluginLoadStatus.active:
        break;
    }
    final fiber = _fibers.putIfAbsent(id, () => _makeFiber(loaded));
    final e = await fiber.ensure();
    if (e.isErr) return Err<PluginRunResult>(e.failureOrNull!.scoped(pluginId: id));
    if (!fiber.isActive || fiber.ctx == null) {
      return Err<PluginRunResult>(Outcome.err<void>(
        code: PluginFailureKind.runtimeError,
        message: '「${loaded.descriptor.manifest.name}」没能启动',
        hint: '看诊断树里的 effect 与日志',
        pluginId: id,
      ).failureOrNull!);
    }
    // **平台必须防住插件 throw**：作者一定会忘（第三方的代码不能假设他守规矩）。
    // 取消当正常终态（Ok + userVisible=false，UI 不打扰），其余异常收进 Err 并留 cause。
    late final Outcome<PluginRunResult> r;
    try {
      r = await fiber.plugin.run(fiber.ctx!, input);
    } catch (e, st) {
      if (isCancelSignal(e)) {
        r = Ok<PluginRunResult>(PluginRunResult(
          summary: '已取消',
          data: {'reason': cancelReasonOf(e)},
          userVisible: false,
        ));
      } else {
        r = Err<PluginRunResult>(PluginFailure(
          code: PluginFailureKind.runtimeError,
          message: '「${loaded.descriptor.manifest.name}」出了点问题',
          hint: '在「插件」页打开它的诊断记录看详情；可先重试一次',
          pluginId: id,
          cause: '$e\n$st',
        ));
      }
    }
    trace.emit(TraceRecord(
      traceId: (fiber.ctx as KernelPluginCtx).traceId,
      pluginId: id,
      level: r.isOk ? TraceLevel.info : TraceLevel.fail,
      message: r.fold((v) => '运行完成：${v.summary}', (f) => '运行失败：${f.message}'),
    ));
    return r;
  }

  /// 面板列表（现场读，无第二份缓存）。
  List<PluginView> view() {
    final res = _result;
    if (res == null) return const [];
    return [
      for (final p in res.plugins)
        PluginView(
          loaded: p,
          state: _fibers[p.id]?.state,
          lastFailure: _fibers[p.id]?.lastFailure,
          effectTree: _fibers[p.id]?.effectTree.map((e) => e.toMap()).toList() ?? const [],
          slotCount: slots.snapshot().where((e) => e['registrant'] == p.id).length,
        ),
    ];
  }

  /// 诊断快照：effect 树 + 槽账本 + 最近日志（面板详情页三块）。
  Map<String, Object?> diagnostics(String id) {
    final fiber = _fibers[id];
    final tid = fiber != null && fiber.ctx is KernelPluginCtx ? (fiber.ctx as KernelPluginCtx).traceId : null;
    final sink = trace is InMemoryTraceSink ? trace as InMemoryTraceSink : null;
    return {
      'plugin': id,
      'state': fiber?.state.name,
      'effectTree': fiber?.effectTree.map((e) => e.toMap()).toList() ?? const [],
      'slots': slots.snapshot().where((e) => e['registrant'] == id).toList(),
      'logs': (trace is InMemoryTraceSink ? (trace as InMemoryTraceSink).forPlugin(id) : const <TraceRecord>[]).map((r) => r.toMap()).toList(),
      // 出过错的那几条**单独列一份**：面板的"最近日志"只显示 30 条，
      // 环形缓冲里一条插件刷屏就能把真正的失败挤出可见区 —— 最该看见的恰恰最先看不见。
      'logFailures': (trace is InMemoryTraceSink
              ? (trace as InMemoryTraceSink).forPlugin(id)
              : const <TraceRecord>[])
          .where((r) => r.level == TraceLevel.fail || r.level == TraceLevel.warn)
          .map((r) => r.toMap())
          .toList(),
      'disposeFailures': fiber?.disposeFailures ?? const [],
      // **这一次运行**干了什么：traceId 每次重载都换（`TraceIds.next`）。
      // 只有按它筛，才分得清"当前这个实例干的"与"被它顶掉的旧实例干的" ——
      // 否则插件重载三次，日志混成一锅，指错方向是迟早的事。
      'traceId': tid,
      'runLog': (sink == null || tid == null)
          ? const []
          : sink.byTrace(tid).map((r) => r.toMap()).toList(),
    };
  }

  /// 低优先级预热所有**可用**能力。
  ///
  /// `CapabilityRegistry.warmUpAll` 的注释本来写着"内核在启动后低优先级调用"，
  /// 但整条链**没有任何调用者** —— 能力实现写的 `warmUp()`（建连、准备资源）永远不会被执行，
  /// 首次使用才现编现连。宿主在 boot 之后调它；重活（模型加载）不该放在 `warmUp` 里，
  /// 那是 `prewarm` 的活（见 `Speak.prewarm`）。
  Future<void> warmUpCapabilities() => capabilities.warmUpAll();

  /// 全部卸载（切方案档 / 退出登录 / 测试收尾）。
  Future<void> shutdown() async {
    for (final f in _fibers.values) {
      await f.unload(reason: '平台关闭');
    }
    _fibers.clear();
  }

  PluginFiber _makeFiber(LoadedPlugin p) {
    final factory = p.descriptor.factory!;
    return PluginFiber(
      plugin: factory(),
      epochOf: (f) => _epochOf(p.descriptor.manifest),
      ctxFactory: (f) => KernelPluginCtx(
        fiber: f,
        manifest: p.descriptor.manifest,
        capabilities: capabilities,
        slots: slots,
        config: configStore.stackFor(p.descriptor.manifest),
        // 会话层的真源是 ConfigStore：ctx 写临时值必须落到那儿，面板与内核才看得见。
        sessionStore: configStore,
        trace: trace,
        traceId: traceIds.next(p.id),
      ),
      onStateChange: (fiber, state) => trace.emit(TraceRecord(
        traceId: fiber.ctx is KernelPluginCtx ? (fiber.ctx as KernelPluginCtx).traceId : '-',
        pluginId: p.id,
        level: state == FiberState.failed ? TraceLevel.fail : TraceLevel.debug,
        message: 'fiber → ${state.name}',
      )),
    );
  }

  /// 依赖指纹 = 能力实现版本 + 生效配置（易变值除外）。
  String _epochOf(PluginManifest manifest) {
    final caps = manifest.inject.map((c) => '$c@${capabilities.revisionOf(c)}').join(',');
    final stack = configStore.stackFor(manifest);
    final resolved = stack.resolveAll();
    final volatile = {for (final p in manifest.params) if (p.volatile) p.name};
    final cfg = (resolved.values.keys.toList()..sort())
        .where((k) => !volatile.contains(k))
        .map((k) => '$k=${resolved[k]}')
        .join(',');
    return 'caps[$caps]|cfg[$cfg]';
  }
}
