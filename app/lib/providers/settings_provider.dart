import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../agent/mcp/mcp_client.dart' show McpServerConfig;
import '../agent/dev/ssh/secret_store.dart'
    show deleteSshSecrets, migrateSshSecrets, saveSshSecrets;

import '../agent/adb/adb_targets.dart';
import '../agent/dev/ssh/ssh_credentials.dart' show SshConfig;
import '../agent/web_search/web_search_provider.dart';
import '../models/agent_persona.dart';
import '../models/api_model.dart';
import '../services/settings_service.dart';

/// 持有推理引擎设置（GPU 开??/ 卸载层数），并在变更时持久化到本地文件??
class SettingsNotifier extends StateNotifier<InferenceSettings> {
  final SettingsService _service;

  SettingsNotifier(this._service) : super(const InferenceSettings()) {
    _load();
  }

  Future<void> _load() async {
    final loaded = await _service.load();
    // P2-D3：SSH 密钥迁移安全存储——settings JSON 里的明文密钥一次性搬走
    // （幂等；安全存储不可用时保留明文，连接不中断）。
    var finalSettings = loaded;
    try {
      final migrated = await migrateSshSecrets(loaded.sshConfigs);
      if (migrated != null) {
        finalSettings = loaded.copyWith(sshConfigs: migrated);
      }
    } on Exception catch (_) {}
    if (mounted) state = finalSettings;
  }

  /// 全局 UI 缩放（0.85–1.30）：main.dart 以 devicePixelRatio 乘数应用。
  Future<void> setUiScale(double value) async {
    final clamped = value.clamp(0.85, 1.30);
    state = state.copyWith(uiScale: clamped);
    await _persist();
  }

  Future<void> setEnableGpu(bool value) async {
    state = state.copyWith(enableGpu: value);
    await _persist();
  }

  Future<void> setGpuLayers(int value) async {
    // 防御性夹紧，避免越界值进入原生层??
    final clamped = value.clamp(0, 999);
    state = state.copyWith(gpuLayers: clamped);
    await _persist();
  }

  /// 设置 GPU 后端??cpu' / 'vulkan' / 'opencl' / 'auto'）??
  Future<void> setGpuBackend(String value) async {
    const allowed = {'cpu', 'vulkan', 'opencl', 'auto'};
    if (!allowed.contains(value)) return;
    state = state.copyWith(gpuBackend: value);
    await _persist();
  }

  /// 设置上下文大小（KV 缓存窗口）。上??65536，下??1??
  Future<void> setContextSize(int value) async {
    // 防御性夹紧，避免越界值进入原生层??
    final clamped = value.clamp(1, 65536);
    state = state.copyWith(contextSize: clamped);
    await _persist();
  }

  /// 设置是否允许 Qwen3 思考模式。默认关闭（直接作答）??
  Future<void> setEnableThinking(bool value) async {
    state = state.copyWith(enableThinking: value);
    await _persist();
  }

  /// 设置某个模型是否启用 MTP（多 token 预测）加速。按模型 id 独立开关，
  /// 互不影响——仅对带 NextN 头的模型生效，用户可在模型列表逐个开启??
  Future<void> setEnableMtp(String modelId, bool value) async {
    final updated = Map<String, bool>.from(state.mtpEnabledByModel);
    updated[modelId] = value;
    state = state.copyWith(mtpEnabledByModel: updated);
    await _persist();
  }

  /// 设置全局 MTP 功能总开关（默认关闭）。关闭时模型卡片不显示各模型 MTP
  /// 开关，加载模型也强制不启用；开启后模型卡片显示支持 MTP 模型的开关，
  /// 用户可逐个配置??
  Future<void> setEnableMtpFeature(bool value) async {
    state = state.copyWith(enableMtpFeature: value);
    await _persist();
  }

  /// 设置某个模型是否启用 dspark 投机加速。按模型 id 独立开关，互不影响
  /// ——仅对目录声明了草稿头（dspark config）且文件已下载完整的模型生效??
  Future<void> setEnableDspark(String modelId, bool value) async {
    final updated = Map<String, bool>.from(state.dsparkEnabledByModel);
    updated[modelId] = value;
    state = state.copyWith(dsparkEnabledByModel: updated);
    await _persist();
  }

  /// 设置全局 dspark 功能总开关（默认关闭）。关闭时模型卡片不显示各模型
  /// dspark 开关，加载模型也强制不启用；开启后模型卡片显示声明了草稿头??
  /// 模型??dspark 开关，用户可逐个配置??
  Future<void> setEnableDsparkFeature(bool value) async {
    state = state.copyWith(enableDsparkFeature: value);
    await _persist();
  }

  /// 设置 split-MoE 热专家 bank 手动覆写（8–64）。传 null = 恢复内存自适应
  /// 自动分档。modelId 用 '*' 表示应用到所有智能 MoE 模型（设置页全局滑条）。
  Future<void> setMoeBankOverride(String modelId, int? bank) async {
    final updated = Map<String, int>.from(state.moeBankOverrideByModel);
    if (bank == null) {
      updated.remove(modelId);
    } else {
      updated[modelId] = bank.clamp(8, 64);
    }
    state = state.copyWith(moeBankOverrideByModel: updated);
    await _persist();
  }

  /// 设置某个视觉模型是否加载 mmproj 视觉塔（2026-10-15，方案 P4）。
  /// 切换需重新加载模型生效（视觉塔在 load 时建立）；关闭省 ~0.9GB 内存，
  /// 释放的预算会回到自动 bank / KV。未配置的模型回退全局 autoLoadMmproj。
  Future<void> setVisionEnabled(String modelId, bool value) async {
    final updated = Map<String, bool>.from(state.visionEnabledByModel);
    updated[modelId] = value;
    state = state.copyWith(visionEnabledByModel: updated);
    await _persist();
  }

  /// 设置「默认加载」模型。传 null 表示取消默认??
  /// 持久化到 inference_settings.json（与 MTP 等其他设置同一文件），
  /// 退??App 不会丢失；启动自动加载逻辑按此 id 加载模型??
  Future<void> setDefaultModel(String? modelId) async {
    if (state.defaultModelId == modelId) return;
    // ??null 表示取消默认：必须显式置 clearDefaultModel=true??
    // 否则 copyWith 里的 `defaultModelId ?? this.defaultModelId` 会吞??null??
    // 导致一旦选过就再也无法反选（旧值被保留）??
    state = state.copyWith(
        defaultModelId: modelId, clearDefaultModel: modelId == null);
    await _persist();
  }

  // ---------------------------------------------------------------
  // OpenAI 兼容远程模型（API 接入??
  // ---------------------------------------------------------------

  /// 新增一??API 模型配置??
  Future<void> addApiModel(ApiModelConfig config) async {
    state = state.copyWith(
      apiModels: [...state.apiModels, config],
    );
    await _persist();
  }

  /// 更新一个已??API 模型配置（按 id 定位；不存在则忽略）??
  Future<void> updateApiModel(ApiModelConfig config) async {
    state = state.copyWith(
      apiModels: [
        for (final m in state.apiModels)
          if (m.id == config.id) config else m,
      ],
    );
    await _persist();
  }

  /// 删除一??API 模型配置；若删除的是当前激活模型，自动停用 API??
  Future<void> deleteApiModel(String id) async {
    final removedActive = state.activeApiModelId == id;
    state = state.copyWith(
      apiModels: state.apiModels.where((m) => m.id != id).toList(),
      activeApiModelId: removedActive ? null : state.activeApiModelId,
      clearActiveApiModel: removedActive,
    );
    await _persist();
  }

  /// 激??停用某个 API 模型。传 null 表示停用（不启用 API 接入）??
  /// 路由策略：本地模型优先，仅当本地不可用时才走激活的 API??
  Future<void> setActiveApiModel(String? modelId) async {
    // 校验：仅允许激活列表内存在??id（或 null 停用）??
    if (modelId != null && !state.apiModels.any((m) => m.id == modelId)) {
      return;
    }
    if (state.activeApiModelId == modelId) return;
    state = state.copyWith(
        activeApiModelId: modelId, clearActiveApiModel: modelId == null);
    await _persist();
  }

  // ---------------------------------------------------------------
  // 智能体（Agent??
  // ---------------------------------------------------------------

  /// 智能体模式总开关??
  Future<void> setAgentEnabled(bool value) async {
    state = state.copyWith(agentEnabled: value);
    await _persist();
  }

  /// 是否启用新智能体模式（Phase 0 重写的事件源 ReactLoopAgent）；
  /// 关闭则回退??runAgent 逻辑（可回退开关）??
  Future<void> setUseNewAgentMode(bool value) async {
    state = state.copyWith(useNewAgentMode: value);
    await _persist();
  }

  /// 指定/取消智能体驱动模型??
  /// - source='local' ??[modelId] 为本地模型目??id??
  /// - source='api' ??[modelId] ??API 模型配置 id??
  /// - ??(null, null) 表示取消指定，跟随默认路由（本地优先，API 兜底）??
  Future<void> setAgentModel(String? source, String? modelId) async {
    if (source == null && modelId == null) {
      // 取消指定：必须显??clearAgentModel=true，否??copyWith 吞掉 null??
      if (state.agentModelId == null) return;
      state = state.copyWith(clearAgentModel: true);
      await _persist();
      return;
    }
    if (source != 'local' && source != 'api') return;
    if (modelId == null || modelId.isEmpty) return;
    // API 模型必须存在于配置列表内，否则拒绝??
    if (source == 'api' && !state.apiModels.any((m) => m.id == modelId)) {
      return;
    }
    if (state.agentModelSource == source && state.agentModelId == modelId) {
      return;
    }
    state = state.copyWith(agentModelSource: source, agentModelId: modelId);
    await _persist();
  }

  /// 智能体模式上下文长度（n_ctx）。夹紧到 1~65536??
  Future<void> setAgentNctx(int value) async {
    final clamped = value.clamp(1, 65536);
    state = state.copyWith(agentNctx: clamped);
    await _persist();
  }

  // ---- 智能体人格（Persona：标准 + 自定义，见 AgentPersona）----

  /// 激活某个人格。仅允许标准人格 id 或列表内存在的自定义 id；
  /// 无效 id 忽略（保持当前激活不变）。
  Future<void> setActivePersona(String personaId) async {
    final valid = personaId == kStandardPersonaId ||
        state.agentPersonas.any((p) => p.id == personaId);
    if (!valid || state.activePersonaId == personaId) return;
    state = state.copyWith(activePersonaId: personaId);
    await _persist();
  }

  /// 新增或更新自定义人格（按 [persona.id] 定位；不存在则追加）。
  Future<void> upsertPersona(AgentPersona persona) async {
    if (persona.id.isEmpty || persona.name.trim().isEmpty) return;
    final trimmed = persona.copyWith(
      name: persona.name.trim(),
      prompt: persona.prompt.trim(),
    );
    final exists = state.agentPersonas.any((p) => p.id == persona.id);
    state = state.copyWith(
      agentPersonas: exists
          ? [
              for (final p in state.agentPersonas)
                if (p.id == persona.id) trimmed else p,
            ]
          : [...state.agentPersonas, trimmed],
    );
    await _persist();
  }

  /// 删除自定义人格；删除的是当前激活人格时回落标准人格。
  Future<void> deletePersona(String personaId) async {
    if (personaId == kStandardPersonaId) return;
    if (!state.agentPersonas.any((p) => p.id == personaId)) return;
    final wasActive = state.activePersonaId == personaId;
    state = state.copyWith(
      agentPersonas:
          state.agentPersonas.where((p) => p.id != personaId).toList(),
      activePersonaId: wasActive ? kStandardPersonaId : null,
    );
    await _persist();
  }

  // ---- 开发模式（Dev Agent）----

  /// 开发模式总开关。开启 = 注册 Dev 工具组 + 注入 DevContext；
  /// 关闭 = 现有行为零回归。
  Future<void> setDevModeEnabled(bool value) async {
    state = state.copyWith(devModeEnabled: value);
    await _persist();
  }

  /// 切换激活工作区 id（持久化到设置；DevSessionController 同步切换）。
  Future<void> setDevWorkspaceId(String value) async {
    if (value.isEmpty) return;
    state = state.copyWith(devWorkspaceId: value);
    await _persist();
  }

  /// 保存/覆盖一条 SSH 配置（按 id 匹配；id 为空则追加）。
  ///
  /// 私钥/登录密码**不落 settings JSON**：先写进安全存储（saveSshSecrets），
  /// state/磁盘只留空槽位；连接前由 resolveSshSecrets 回填。
  /// 安全存储不可用时 fail-open（保留明文，连接照旧可用）。
  Future<void> upsertSshConfig(SshConfig config) async {
    var stored = config;
    try {
      stored = await saveSshSecrets(config);
    } on Exception catch (_) {}
    var list = [...state.sshConfigs];
    final index = list.indexWhere((c) => c.id.isNotEmpty && c.id == config.id);
    if (index >= 0) {
      list[index] = stored;
    } else {
      list.add(stored);
    }
    state = state.copyWith(sshConfigs: list);
    await _persist();
  }

  /// 删除一条 SSH 配置（按 id）；同步清掉安全存储里的凭据。
  Future<void> removeSshConfig(String id) async {
    if (id.isEmpty) return;
    state = state.copyWith(
        sshConfigs: state.sshConfigs.where((c) => c.id != id).toList());
    await _persist();
    await deleteSshSecrets(id);
  }

  // ---------------------------------------------------------------- ADB 远程控制

  /// ADB 远程控制总开关。
  ///
  /// 用户定案：**放行只看这个开关，不做逐次审批**，所以这里不弹确认框；
  /// 边界由"只能连白名单里的目标机 + 命令黑名单"承担（见 adb_tool.dart）。
  Future<void> setAdbEnabled(bool value) async {
    state = state.copyWith(adbEnabled: value);
    await _persist();
  }

  /// 保存/覆盖一台 ADB 目标机（按 id 匹配，id 为空则追加）。
  ///
  /// 同一 ip:port 只留一条：手滑重复添加会让"默认目标机"（取第一条）变得不可预期。
  Future<void> upsertAdbTarget(AdbTarget target) async {
    var list = [...state.adbTargets];
    final byId = list.indexWhere((t) => t.id.isNotEmpty && t.id == target.id);
    if (byId >= 0) {
      list[byId] = target;
    } else {
      final dup = list.indexWhere((t) => t.serial == target.serial);
      if (dup >= 0) {
        list[dup] = target.copyWith(id: list[dup].id);
      } else {
        list.add(target.id.isEmpty
            ? target.copyWith(id: 'adb-${DateTime.now().millisecondsSinceEpoch}')
            : target);
      }
    }
    state = state.copyWith(adbTargets: list);
    await _persist();
  }

  /// 删除一台 ADB 目标机（只删配置；授权密钥是全局一把，保留）。
  Future<void> removeAdbTarget(String id) async {
    if (id.isEmpty) return;
    state = state.copyWith(
        adbTargets: state.adbTargets.where((t) => t.id != id).toList());
    await _persist();
  }

  /// 清除全部 ADB 目标机（同样保留密钥；密钥重置在设置页单独做）。
  Future<void> clearAdbTargets() async {
    state = state.copyWith(adbTargets: const []);
    await _persist();
  }

  /// 清除全部 SSH 配置（含安全存储里的凭据）。
  Future<void> clearSshConfig() async {
    final ids = state.sshConfigs.map((c) => c.id).toList();
    state = state.copyWith(clearSshConfig: true);
    await _persist();
    for (final id in ids) {
      await deleteSshSecrets(id);
    }
  }

  /// 危险命令策略：'deny'（黑名单直接拒绝）/ 'ask'（转用户审批）。
  Future<void> setDangerousCommandPolicy(String value) async {
    const allowed = {'deny', 'ask'};
    if (!allowed.contains(value)) return;
    state = state.copyWith(dangerousCommandPolicy: value);
    await _persist();
  }

  /// 工具循环轮次上限（1~100，与引擎 AgentConfig assert 对齐；复杂任务可到 100）。
  Future<void> setAgentMaxRounds(int value) async {
    final clamped = value.clamp(1, 100);
    state = state.copyWith(agentMaxRounds: clamped);
    await _persist();
  }

  /// web_search ÿ?غϵ??????ޣ?1~10??DSH max_uses ???壩??
  Future<void> setAgentMaxSearchesPerTurn(int value) async {
    final clamped = value.clamp(1, 10);
    state = state.copyWith(agentMaxSearchesPerTurn: clamped);
    await _persist();
  }

  /// 并发会话槽位（1~4）：同时允许执行回合的会话数量。
  Future<void> setAgentMaxConcurrentTurns(int value) async {
    final clamped = value.clamp(1, 4);
    state = state.copyWith(agentMaxConcurrentTurns: clamped);
    await _persist();
  }

  /// API 档主动压缩预算（token 估算，4096~200000，默认 32768）。
  Future<void> setAgentApiContextBudget(int value) async {
    final clamped = value.clamp(4096, 200000);
    state = state.copyWith(agentApiContextBudget: clamped);
    await _persist();
  }

  /// 每轮生成 token 预算??28~16384??6k 上限按需配置）??
  Future<void> setAgentTokensPerRound(int value) async {
    final clamped = value.clamp(128, 16384);
    state = state.copyWith(agentTokensPerRound: clamped);
    await _persist();
  }

  /// 单工具执行超时（毫秒??s~120s）??
  Future<void> setAgentToolTimeoutMs(int value) async {
    final clamped = value.clamp(1000, 120000);
    state = state.copyWith(agentToolTimeoutMs: clamped);
    await _persist();
  }

  /// 并行工具调用开关??
  Future<void> setAgentAllowParallelTools(bool value) async {
    state = state.copyWith(agentAllowParallelTools: value);
    await _persist();
  }

  /// 并行工具并发上限??~8；运行期再按模型能力夹紧）??
  Future<void> setAgentMaxParallel(int value) async {
    final clamped = value.clamp(2, 8);
    state = state.copyWith(agentMaxParallel: clamped);
    await _persist();
  }

  /// 智能体生成温度（0~2）??
  Future<void> setAgentTemperature(double value) async {
    state = state.copyWith(agentTemperature: value.clamp(0.0, 2.0));
    await _persist();
  }

  // ---- API 档智能体参数（双场景档分流；local 档用上面的平铺 setter）----

  /// API 档轮次上限（1~100，与引擎 AgentConfig assert 对齐）。
  Future<void> setAgentApiMaxRounds(int value) async {
    state = state.copyWith(agentApiMaxRounds: value.clamp(1, 100));
    await _persist();
  }

  /// API 档每步生成预算（1024~32768）。
  Future<void> setAgentApiTokensPerRound(int value) async {
    state = state.copyWith(agentApiTokensPerRound: value.clamp(1024, 32768));
    await _persist();
  }

  /// API 档温度（0~2）。
  Future<void> setAgentApiTemperature(double value) async {
    state = state.copyWith(agentApiTemperature: value.clamp(0.0, 2.0));
    await _persist();
  }

  /// API 档单工具超时（1s~120s）。
  Future<void> setAgentApiToolTimeoutMs(int value) async {
    state = state.copyWith(agentApiToolTimeoutMs: value.clamp(1000, 120000));
    await _persist();
  }

  /// API 档并行工具开关。
  Future<void> setAgentApiAllowParallelTools(bool value) async {
    state = state.copyWith(agentApiAllowParallelTools: value);
    await _persist();
  }

  /// API 档并行上限（2~8）。
  Future<void> setAgentApiMaxParallel(int value) async {
    state = state.copyWith(agentApiMaxParallel: value.clamp(2, 8));
    await _persist();
  }

  /// 思考失控守卫阈值（1000~65536 字符；默认 6000）。
  Future<void> setAgentThinkingMaxChars(int value) async {
    state = state.copyWith(agentThinkingMaxChars: value.clamp(1000, 65536));
    await _persist();
  }

  /// 智能体工具决策步是否允许思考（默认关：端侧思考失控治理）。
  Future<void> setAgentThinkingOnToolSteps(bool value) async {
    state = state.copyWith(agentThinkingOnToolSteps: value);
    await _persist();
  }

  /// 对话区文字整体缩放（0.7~1.3，1.0 = 默认字号）。
  Future<void> setChatTextScale(double value) async {
    state = state.copyWith(chatTextScale: value.clamp(0.7, 1.3));
    await _persist();
  }

  /// composer 快捷图标白名单（更多 → 快捷设置；默认空 = 全关）。
  Future<void> setComposerQuickActions(List<String> ids) async {
    state = state.copyWith(composerQuickActions: ids);
    await _persist();
  }

  /// 自动压缩阈值（占用详情面板刻度条滑块，0.5–0.95）。
  Future<void> setAutoCompactThreshold(double value) async {
    state =
        state.copyWith(autoCompactThreshold: value.clamp(0.5, 0.95));
    await _persist();
  }

  /// 应用外观：system / light / dark（更多 → 外观）。
  Future<void> setThemeMode(String value) async {
    const known = {'system', 'light', 'dark'};
    if (!known.contains(value)) return;
    state = state.copyWith(themeMode: value);
    await _persist();
  }

  /// 开/关单个快捷图标。
  Future<void> toggleComposerQuickAction(String id, bool on) async {
    final cur = [...state.composerQuickActions];
    if (on) {
      if (!cur.contains(id)) cur.add(id);
    } else {
      cur.remove(id);
    }
    await setComposerQuickActions(cur);
  }

  /// 子代理工具注册开关??
  Future<void> setAgentSubagentEnabled(bool value) async {
    state = state.copyWith(agentSubagentEnabled: value);
    await _persist();
  }

  /// 子代理专用 API 模型（'' = 跟随主模型；仅 API 档生效）??
  Future<void> setAgentSubagentApiModelId(String value) async {
    state = state.copyWith(agentSubagentApiModelId: value);
    await _persist();
  }

  /// 压缩摘要专用 API 模型（'' = 跟随子代理模型；P1-B 按步模型路由）。
  Future<void> setAgentCompressionApiModelId(String value) async {
    state = state.copyWith(agentCompressionApiModelId: value);
    await _persist();
  }

  /// goal 无人值守续跑轮数上限（1~20）。
  Future<void> setAgentGoalMaxRounds(int value) async {
    state = state.copyWith(agentGoalMaxRounds: value.clamp(1, 20));
    await _persist();
  }

  /// 新增/更新 MCP server（按 id 覆盖；P2-B）。
  Future<void> upsertMcpServer(McpServerConfig server) async {
    final list = [...state.mcpServers];
    final idx = list.indexWhere((s) => s.id == server.id);
    if (idx >= 0) {
      list[idx] = server;
    } else {
      list.add(server);
    }
    state = state.copyWith(mcpServers: list);
    await _persist();
  }

  /// 删除 MCP server。
  Future<void> removeMcpServer(String id) async {
    final list = state.mcpServers.where((s) => s.id != id).toList();
    if (list.length == state.mcpServers.length) return;
    state = state.copyWith(mcpServers: list);
    await _persist();
  }

  /// 端侧 ASR：增强档 / 热词分类 / 自定义热词（语音设置卡）。
  Future<void> setAsrEnhancedMode(bool value) async {
    state = state.copyWith(asrEnhancedMode: value);
    await _persist();
  }

  Future<void> setAsrHotwordCategories(List<String> ids) async {
    state = state.copyWith(asrHotwordCategories: ids);
    await _persist();
  }

  Future<void> setAsrHotwordCustom(String words) async {
    state = state.copyWith(asrHotwordCustom: words);
    await _persist();
  }

  /// 保存某个热词分类的用户差量编辑（增词/删词；空表 = 清除该分类覆盖，
  /// 恢复内置词表）。
  Future<void> setAsrHotwordCategoryEdit(
      String catId, List<String> added, List<String> removed) async {
    final nextAdded = {...state.asrHotwordAdded};
    final nextRemoved = {...state.asrHotwordRemoved};
    if (added.isEmpty) {
      nextAdded.remove(catId);
    } else {
      nextAdded[catId] = added;
    }
    if (removed.isEmpty) {
      nextRemoved.remove(catId);
    } else {
      nextRemoved[catId] = removed;
    }
    state = state.copyWith(
        asrHotwordAdded: nextAdded, asrHotwordRemoved: nextRemoved);
    await _persist();
  }

  /// 置顶/取消置顶会话（P2 抽屉重构）。
  Future<void> togglePinnedConversation(String id) async {
    final list = [...state.pinnedConversationIds];
    if (!list.remove(id)) list.add(id);
    state = state.copyWith(pinnedConversationIds: list);
    await _persist();
  }

  /// Dev 工具逐组开关（P2-D1）。
  Future<void> setDevToolGroupEnabled(String group, bool value) async {
    state =
        state.copyWith(devToolToggles: {...state.devToolToggles, group: value});
    await _persist();
  }

  /// 上下文超限自动压缩开关??
  /// 智能体提示词档位（auto/compact/full）：auto = API 恒完整、本地按模型
  /// id/大小自动判精简档（2026-10-27 K90 真机定案，见 agent_tier.dart）。
  Future<void> setAgentPromptTierMode(String value) async {
    state = state.copyWith(
        agentPromptTierMode:
            const ['auto', 'compact', 'full'].contains(value) ? value : 'auto');
    await _persist();
  }

  Future<void> setAgentCompactEnabled(bool value) async {
    state = state.copyWith(agentCompactEnabled: value);
    await _persist();
  }

  /// 超长工具输出溢写开关??
  Future<void> setAgentSpillEnabled(bool value) async {
    state = state.copyWith(agentSpillEnabled: value);
    await _persist();
  }

  // ---- 语音播报（Edge TTS）----

  /// Edge TTS 总开关。
  Future<void> setEdgeTtsEnabled(bool value) async {
    state = state.copyWith(edgeTtsEnabled: value);
    await _persist();
  }

  /// 自动播报开关。
  Future<void> setEdgeTtsAutoSpeak(bool value) async {
    state = state.copyWith(edgeTtsAutoSpeak: value);
    await _persist();
  }

  /// 音色（ShortName）。
  Future<void> setEdgeTtsVoice(String value) async {
    state = state.copyWith(edgeTtsVoice: value);
    await _persist();
  }

  /// 语速（-50 ~ +100）。
  Future<void> setEdgeTtsRate(int value) async {
    state = state.copyWith(edgeTtsRate: value.clamp(-50, 100));
    await _persist();
  }

  /// 音调（-50 ~ +50 Hz）。
  Future<void> setEdgeTtsPitch(int value) async {
    state = state.copyWith(edgeTtsPitch: value.clamp(-50, 50));
    await _persist();
  }

  /// 音量（-50 ~ +50）。
  Future<void> setEdgeTtsVolume(int value) async {
    state = state.copyWith(edgeTtsVolume: value.clamp(-50, 50));
    await _persist();
  }

  /// 回合轨迹自动落盘开关（P0 轨迹导出）。
  Future<void> setAgentTraceExportEnabled(bool value) async {
    state = state.copyWith(agentTraceExportEnabled: value);
    await _persist();
  }

  /// 联网搜索工具总开关??
  Future<void> setWebSearchEnabled(bool value) async {
    state = state.copyWith(webSearchEnabled: value);
    await _persist();
    _reapplyWebSearchProvider();
  }

  // ---- 联网搜索（SearXNG）实例配??----
  // 每项保存后立即热更新 WebSearchSeam 里的 provider（配置未变则复用实例），
  // 改地址无需重启应用??

  /// SearXNG 实例地址，如 `http://192.168.1.20:8080`；空 = 未配置??
  Future<void> setWebSearchSearXngBaseUrl(String value) async {
    state = state.copyWith(webSearchSearXngBaseUrl: value.trim());
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// SearXNG API key（私有实例才需要；??= 无密钥）??
  Future<void> setWebSearchSearXngApiKey(String value) async {
    state = state.copyWith(
        webSearchSearXngApiKey: value.trim().isEmpty ? null : value.trim());
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 引擎白名单（逗号分隔，如 `bing,sogou`）；??= 由实例决定全部引擎??
  /// 实例上存在不可达引擎时，只填可达引擎可把搜索从二十秒级降到秒级??
  Future<void> setWebSearchSearXngEngines(String value) async {
    state = state.copyWith(
        webSearchSearXngEngines: value.trim().isEmpty ? null : value.trim());
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 端侧直连引擎总开关（打开时优先级最高，忽略 SearXNG 地址）。
  Future<void> setWebSearchDirectEnabled(bool value) async {
    state = state.copyWith(webSearchDirectEnabled: value);
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 直连引擎开关（SearXNG 地址为空时生效）。
  Future<void> setWebSearchDirectEngineEnabled(
      String engineId, bool enabled) async {
    final current = List<String>.of(state.webSearchDirectEngines);
    if (enabled) {
      if (!current.contains(engineId)) current.add(engineId);
    } else {
      current.remove(engineId);
    }
    state = state.copyWith(webSearchDirectEngines: current);
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 低风险引擎每 10 分钟窗口请求预算（1~20）。
  Future<void> setWebSearchDirectLowRiskPerWindow(int value) async {
    state = state.copyWith(webSearchDirectLowRiskPerWindow: value.clamp(1, 20));
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 高风险引擎每 10 分钟窗口请求预算（1~6）。
  Future<void> setWebSearchDirectHighRiskPerWindow(int value) async {
    state = state.copyWith(webSearchDirectHighRiskPerWindow: value.clamp(1, 6));
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 搜索语言（如 `zh-CN`）；??= 不指定??
  Future<void> setWebSearchSearXngLanguage(String value) async {
    state = state.copyWith(
        webSearchSearXngLanguage: value.trim().isEmpty ? null : value.trim());
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 单次搜索最多返回条数（1~20）??
  Future<void> setWebSearchSearXngMaxResults(int value) async {
    state = state.copyWith(webSearchSearXngMaxResults: value.clamp(1, 20));
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 单次搜索超时（毫秒，3s~120s）??
  Future<void> setWebSearchSearXngTimeoutMs(int value) async {
    state =
        state.copyWith(webSearchSearXngTimeoutMs: value.clamp(3000, 120000));
    await _persist();
    _reapplyWebSearchProvider();
  }

  /// 按当前设置重建联网搜??provider（内容未变时复用现有实例，不会打断连接池）??
  /// 内部按 `webSearchDirectEnabled` 总开关分流：打开=端侧直连（最高优先级），
  /// 关闭=SearXNG（或未配置诊断）。
  void _reapplyWebSearchProvider() {
    try {
      applySearXNGProviderFromSettings(state);
    } catch (_) {
      // 热更新失败不影响设置本身的保存：下一轮对话构建注册表时会再试一次??
    }
  }

  /// shell 执行工具开关??
  Future<void> setAgentShellEnabled(bool value) async {
    state = state.copyWith(agentShellEnabled: value);
    await _persist();
  }

  /// python_exec 工具开关??
  Future<void> setAgentPythonEnabled(bool value) async {
    state = state.copyWith(agentPythonEnabled: value);
    await _persist();
  }

  /// 沙箱完整文件访问授权（danger-full-access 前置）??
  Future<void> setAgentFullFileAccess(bool value) async {
    state = state.copyWith(agentFullFileAccess: value);
    await _persist();
  }

  /// 长期记忆开关（默认关闭：跨会话记忆可能积累偶发错误）??
  Future<void> setAgentMemoryEnabled(bool value) async {
    state = state.copyWith(agentMemoryEnabled: value);
    await _persist();
  }

  /// 是否默认加载视觉投影器（mmproj）??
  Future<void> setAutoLoadMmproj(bool value) async {
    state = state.copyWith(autoLoadMmproj: value);
    await _persist();
  }

  /// GPU/CPU 占用率监控呈现开关??
  Future<void> setShowResourceMonitor(bool value) async {
    state = state.copyWith(showResourceMonitor: value);
    await _persist();
  }

  /// OOM 内存守卫总开关。关闭 = 加载前不再拒绝超大模型（有整机死机风险）。
  Future<void> setOomGuardEnabled(bool value) async {
    state = state.copyWith(oomGuardEnabled: value);
    await _persist();
  }

  /// KV 缓存精度：'q4_0'（默认）/ 'q8_0'。仅量化 K，V 恒 F16（见 settings_service
  /// 注释）。重新加载模型后生效。
  Future<void> setKvCacheType(String value) async {
    final v = (value == 'q8_0') ? 'q8_0' : 'q4_0';
    if (v == state.kvCacheType) return;
    state = state.copyWith(kvCacheType: v);
    await _persist();
  }

  /// [dspark 2026-10-14] P1: flash attention 开关。默认关。重新加载模型后生效。
  Future<void> setFlashAttn(bool value) async {
    if (value == state.flashAttn) return;
    state = state.copyWith(flashAttn: value);
    await _persist();
  }

  /// GPU 推理时限制刷新率（防闪纹）。关 = 推理期间不干预屏幕刷新率。
  Future<void> setInferenceLimitRefreshRate(bool value) async {
    state = state.copyWith(inferenceLimitRefreshRate: value);
    await _persist();
  }

  /// prefill 宽度 n_ubatch。0 = 自动（统一 512，split-MoE 按 bank 自动收敛）；
  /// 32~512 = 拆小（GPU fault 缓解等场景）。改后重新加载模型生效。
  /// 2026-10-16 起对任意后端生效（CPU 档 ubatch=16 强制已证伪废除）。
  Future<void> setGpuNUbatch(int value) async {
    state = state.copyWith(gpuNUbatch: value < 32 ? 0 : value.clamp(32, 512));
    await _persist();
  }

  /// Vulkan 禁用 subgroup（GGML_VK_NO_SUBGROUP）。重启 app 后生效。
  Future<void> setVkNoSubgroup(bool value) async {
    state = state.copyWith(vkNoSubgroup: value);
    await _persist();
  }

  /// 智能 MoE 加载（超大 MoE 统一架构）。改后重新加载模型生效。
  Future<void> setSmartMoeEnabled(bool value) async {
    state = state.copyWith(smartMoeEnabled: value);
    await _persist();
  }

  /// OOM 预检余量（MB??~4096）。加载前 MemAvailable 扣除该余量后与模型体??
  /// 比较；调小更容易放过极限大模型，调大更保守??
  Future<void> setOomPreHeadroomMb(int value) async {
    state = state.copyWith(oomPreHeadroomMb: value.clamp(0, 4096));
    await _persist();
  }

  /// OOM 加载后余量（MB??~4096）。KV cache / 图计算缓冲预??=
  /// MemAvailable - 该余量；调小??KV 更大空间，调大更保守??
  Future<void> setOomPostHeadroomMb(int value) async {
    state = state.copyWith(oomPostHeadroomMb: value.clamp(0, 4096));
    await _persist();
  }

  /// 占用率采样周期（秒，0~30?? = 仅推理时采样）??
  Future<void> setResourceSampleIntervalSec(int value) async {
    final clamped = value.clamp(0, 30);
    state = state.copyWith(resourceSampleIntervalSec: clamped);
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _service.save(state);
    } catch (e) {
      // 持久化失败不应阻??UI 交互；内存状态已更新??
      // 记录日志便于定位（此前完全静默，失败时用户无感知）??
      debugPrint('[Settings] persist failed: $e');
    }
  }
}

final settingsServiceProvider =
    Provider<SettingsService>((ref) => SettingsService());

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, InferenceSettings>((ref) {
  final service = ref.watch(settingsServiceProvider);
  return SettingsNotifier(service);
});
