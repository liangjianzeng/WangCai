// ============================================================
// Settings Screen — 设置页面（Tab 布局）
//
// Tab 1: 📦 模型管理 - 下载、缓存模型列表
// Tab 2: 🧠 推理引擎 - 模型加载、日志查看
// Tab 3: ℹ️ 关于 - 应用信息
// ============================================================

import 'dart:async';
import 'dart:io';
import '../plugins/panel/plugins_screen.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../tts/edge_tts_service.dart'
    show EdgeTtsService, TtsVoiceInfo, groupTtsVoices, kFallbackVoices;

import '../agent/dev/dev.dart'
    show
        DevSessionController,
        DevStore,
        DevTask,
        DevTaskStatus,
        DevWorkspace,
        SshAuthType,
        SshConfig,
        SshEnvironmentService,
        SshKeyGen,
        SshStatus,
        classifySshFailure,
        newDevTaskId,
        resolveSshSecrets,
        sshTargetKindOf,
        sshUsesPasswordAuth,
        taskBelongsToWorkspace;
import '../providers/project_provider.dart'
    show activeProjectProvider, projectsProvider;
import 'engine_install_dialog.dart';
import 'engine_manager_section.dart' show EngineManagerSection; // WangCai 分叉 #8
import '../agent/adb/adb_client.dart';
import '../agent/adb/adb_targets.dart';
import '../agent/mcp/mcp_client.dart' show McpServerConfig;
import '../voice/voice_model_manager.dart'
    show VoiceModelManager, VoiceModels;
import '../voice/voice_service.dart';
import '../asr/hold_to_talk.dart' show AsrModelGate;
import '../asr/kws_engine.dart' show kwsThresholdFromSensitivity;
import '../asr/default_hotwords.dart'
    show
        HotwordCategory,
        hotwordCategories,
        effectiveCategoryWords,
        diffCategoryWords,
        defaultCategoryWords;

import '../agent/skills/provider.dart'
    show
        loadUserSkills,
        writeUserSkill,
        deleteUserSkill,
        buildSkillMarkdown,
        sanitizeSkillDirName;
import '../agent/skills/skill.dart' show Skill, loadBuiltinSkills;
import '../agent/builtin_tools/memory_tool.dart'
    show readGlobalMemorySnapshot, deleteGlobalMemoryEntry, clearGlobalMemory;
import '../agent/web_search/web_search_provider.dart';
import '../models/model_info.dart';
import '../models/model_catalog.dart';
import '../models/api_model.dart';
import '../agent/llm/thinking_effort.dart';
import '../providers/index.dart';
import '../providers/shared_providers.dart' show openAiServiceProvider;
import '../providers/settings_provider.dart';
import '../platform/local_server_inference.dart';
import '../services/settings_service.dart';
import 'package:file_picker/file_picker.dart';
import '../engine/bundled_manifests.dart' show bundledManifests;
import '../engine/engine_manifest.dart' show Preset;
import '../models/local_model.dart';
import '../platform/wangcai_paths.dart' show WangCaiPaths;
import '../services/model_manager.dart' show ModelManager;
import '../services/model_storage_service.dart'
    show ModelStorageService, modelStorageService;
import 'inference_log_screen.dart';
import '../widgets/wangcai_logo.dart';

/// 模型管理面板 Body（v0.0.3 桌面独立版 · Phase 2 重写，2026-11-04）。
///
/// 旧手机端以「下载目录」为中心（assets/models_catalog.json + 下载/续传/
/// 暂停/校验 + catalog 卡片）；桌面形态的模型不是等下载的东西，而是
/// **磁盘上已存在的 GGUF 文件**。本页三段：
///   ① NPU 预置区 —— bundled wangcai-npu manifest 声明的 preset
///     （lfm3-1.7b / qwen3-4b / spark-x2.6-4b / lfm3-omni-2b），在模型库
///     目录（[WangCaiPaths.modelsRoot]，WANGCAI_MODEL_DIR 可覆盖）按
///     modelGlob 扫描命中即列出；缺文件给指引而非报错；
///   ② 本地模型 —— 用户登记的条目（settings.localModels）：FilePicker 选
///     .gguf，可带视觉塔/草稿/ctx/chunk/gpuLayers/引擎绑定/自定义尾参。
///     engineId 与 customArgs 本阶段**只存不接**（引擎钉选与参数优先级链
///     customArgs > 引擎 defaultConfig > manifest 模板是 Phase 3 地盘）；
///   ③ 存储占用（StorageInfoWidget 原样保留）。
/// 默认模型星标统一走 `settings.defaultModelId`，三种 id 形态并存：
/// catalog id（旧下载链路）、`lm_*`（本地登记）、`npu:<preset>`（预置虚拟
/// 条目），[home_screen] 的 `_initAutoLoadDefaultModel` 三者都认。
class ModelManagementBody extends ConsumerStatefulWidget {
  const ModelManagementBody();

  @override
  ConsumerState<ModelManagementBody> createState() =>
      _ModelManagementBodyState();
}

class _ModelManagementBodyState extends ConsumerState<ModelManagementBody> {
  /// preset.name → 命中的文件绝对路径；未命中的 preset 缺席 = 缺文件。
  Map<String, String> _presetHits = const {};

  /// modelPath → 磁盘是否存在（本地模型区路径存在性，进页批量刷新）。
  Map<String, bool> _pathExists = const {};

  /// 登记项变化后强制重建 StorageInfoWidget（它用 FutureBuilder 只拉一次）。
  int _storageTick = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _rescan());
  }

  /// 扫一次模型库目录：preset glob 命中 + 本地登记路径存在性。
  Future<void> _rescan() async {
    final hits = <String, String>{};
    final exists = <String, bool>{};
    try {
      final dir = WangCaiPaths.modelsRoot();
      final names = <String>[];
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          if (e is File && e.path.toLowerCase().endsWith('.gguf')) {
            names.add(p.basename(e.path));
          }
        }
        names.sort();
      }
      final npu = bundledManifests()['wangcai-npu'];
      for (final preset in npu?.presets ?? const <Preset>[]) {
        final glob = preset.modelGlob;
        if (glob == null || glob.isEmpty) continue;
        final re = presetGlobToRegExp(glob);
        for (final name in names) {
          if (re.hasMatch(name)) {
            hits[preset.name] = p.join(dir.path, name);
            break;
          }
        }
      }
      for (final m in ref.read(settingsProvider).localModels) {
        exists[m.modelPath] = await File(m.modelPath).exists();
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _presetHits = hits;
      _pathExists = exists;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final ms = ref.watch(modelManagerProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader('NPU 预置模型', trailing: [
            _iconAction(Icons.refresh, '重扫模型库目录', _rescan),
          ]),
          _buildPresetZone(settings, ms),
          const SizedBox(height: 10),
          _sectionHeader('本地模型', trailing: [
            _iconAction(Icons.add_circle_outline,
                '添加本地模型（选择 .gguf 文件）', _addLocalModelViaPicker),
          ]),
          _buildLocalZone(settings, ms),
          const SizedBox(height: 10),
          // 存储信息（自带标题行）。tick 作 key：登记增删时强制重建。
          StorageInfoWidget(key: ValueKey(_storageTick)),
        ],
      ),
    );
  }

  // =========================================================================
  // 通用件：小节头 / 图标钮 / 模型行 / chip
  // （沿用 2026-10-28 的 p-card 密度语言：行高 ~40、字号 13/11、图标 18、
  //  卡面 surfaceContainerHigh + outlineVariant 细描边，全走 colorScheme。）
  // =========================================================================

  Widget _sectionHeader(String label, {List<Widget> trailing = const []}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        ...trailing,
      ]),
    );
  }

  Widget _iconAction(
      IconData icon, String tooltip, Future<void> Function() onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => onTap(),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label, style: TextStyle(fontSize: 10.5, color: color)),
      );

  /// 模型行（预置区/本地区共用）。次要信息收在次行，一行装下状态+主操作。
  Widget _modelRow({
    required String title,
    required String subtitle,
    required bool exists,
    required bool isLoadedHere,
    required bool isLoadingHere,
    required bool isDefault,
    List<Widget> chips = const [],
    List<Widget> trailing = const [],
    VoidCallback? onToggleDefault,
    VoidCallback? onLoad,
    VoidCallback? onUnload,
    VoidCallback? onEdit,
    VoidCallback? onDelete,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final IconData leadIcon;
    final Color leadColor;
    if (isLoadedHere) {
      leadIcon = Icons.bolt;
      leadColor = scheme.primary;
    } else if (isLoadingHere) {
      leadIcon = Icons.sync_alt;
      leadColor = scheme.primary;
    } else if (!exists) {
      leadIcon = Icons.help_outline;
      leadColor = scheme.outline;
    } else {
      leadIcon = Icons.check_circle_outline;
      leadColor = Colors.green;
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isLoadedHere
            ? scheme.secondaryContainer.withValues(alpha: 0.55)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLoadedHere
              ? scheme.primary.withValues(alpha: 0.5)
              : scheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(leadIcon, size: 18, color: leadColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (exists && onToggleDefault != null)
                  Tooltip(
                    message: isDefault
                        ? '启动时自动加载（当前默认模型），点按取消'
                        : '设为默认：启动时自动加载',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: onToggleDefault,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Icon(
                          isDefault
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 18,
                          color: isDefault
                              ? Colors.amber.shade700
                              : scheme.outline,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 2),
                if (onLoad != null)
                  _actionButton(
                      label: isLoadingHere ? '加载中' : '加载',
                      tone: true,
                      onPressed: isLoadingHere ? null : onLoad),
                if (isLoadedHere) ...[
                  const SizedBox(width: 4),
                  _actionButton(
                      label: '卸载',
                      foreground: Colors.red.shade600,
                      onPressed: onUnload),
                ],
                // 行尾自定义动作组（如 NPU 预置区的下载按钮/进度条）。
                if (trailing.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  ...trailing,
                ],
                if (onEdit != null)
                  _iconAction(Icons.edit_outlined, '编辑配置', () async => onEdit()),
                if (onDelete != null)
                  _iconAction(
                      Icons.delete_outline, '移除登记（不删文件）', () async => onDelete()),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 4, 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  ...chips,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 紧凑按钮（高 30 / 字号 12 / 圆角 8）：tone=true 为 tonal 主操作。
  Widget _actionButton({
    required String label,
    VoidCallback? onPressed,
    bool tone = false,
    Color? foreground,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = foreground ??
        (tone ? scheme.onSecondaryContainer : scheme.onSurfaceVariant);
    return OutlinedButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 11)),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8))),
        backgroundColor: WidgetStatePropertyAll(
            tone ? scheme.secondaryContainer.withValues(alpha: 0.8) : null),
        foregroundColor: WidgetStatePropertyAll(fg),
        side: WidgetStatePropertyAll(BorderSide(
            color: tone ? Colors.transparent : scheme.outlineVariant)),
      ),
      child: Text(label),
    );
  }

  void _toast(String message, {bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: warn ? Colors.orange : null,
    ));
  }

  // =========================================================================
  // ① NPU 预置区
  // =========================================================================

  Widget _buildPresetZone(InferenceSettings settings, ModelState ms) {
    final npu = bundledManifests()['wangcai-npu'];
    final presets = npu?.presets ?? const <Preset>[];
    if (presets.isEmpty) return const SizedBox.shrink();
    // catalog id = 落盘名（DownloadService 产物命名 `{id}.gguf`）。目录在
    // main.dart 启动期 ModelManager().init() 已预热，这里只读单例内存列表。
    final catalog = ModelManager().allModels;
    final tasks = ref.watch(downloadNotifierProvider);
    final rows = <Widget>[];
    for (final preset in presets) {
      final hit = _presetHits[preset.name];
      final id = '$kNpuPresetIdPrefix${preset.name}';
      final isLoadedHere = ms.modelId == id && ms.isLoaded;
      final isLoadingHere = ms.isLoading && ms.modelId == id;
      final isDefault = settings.defaultModelId == id;
      // 缺文件且 catalog 有对应条目（落盘名命中 modelGlob）→ 给「下载」按钮，
      // 走 tongyilite 下载基建：魔搭/hf-mirror 多镜像 + Range 断点续传 + sha256。
      final entry =
          hit == null ? downloadEntryForNpuGlob(preset.modelGlob, catalog) : null;
      final task = entry == null ? null : tasks[entry.id];
      rows.add(_modelRow(
        title: preset.name,
        subtitle: _presetSubtitle(hit, entry, task),
        exists: hit != null,
        isLoadedHere: isLoadedHere,
        isLoadingHere: isLoadingHere,
        isDefault: isDefault,
        chips: [
          if (preset.device != null) _chip(preset.device!, Colors.teal),
          if (preset.ctx != null) _chip('ctx ${preset.ctx}', Colors.blueGrey),
          if (preset.chunk != null)
            _chip('chunk ${preset.chunk}', Colors.blueGrey),
        ],
        trailing: _presetDownloadTrailing(entry, task),
        onToggleDefault: hit == null
            ? null
            : () => ref
                .read(settingsProvider.notifier)
                .setDefaultModel(isDefault ? null : id),
        onLoad: hit == null
            ? null
            : () {
                final path = hit;
                _runLoad(
                  id: id,
                  name: preset.name,
                  load: () => ref
                      .read(modelManagerProvider.notifier)
                      .loadModelByLocalConfig(LocalModelConfig(
                          id: id, name: preset.name, modelPath: path)),
                );
              },
        onUnload: isLoadedHere
            ? () => unloadModelAndNotify(ref, context, preset.name)
            : null,
      ));
    }
    return Column(children: rows);
  }

  /// 预置行副标题：已入库 = 文件名；缺文件按下载任务状态给实时口径。
  String _presetSubtitle(String? hit, ModelConfig? entry, DownloadTask? task) {
    if (hit != null) return p.basename(hit);
    if (entry == null) {
      return '缺文件 — 把 GGUF 放入模型库目录（${WangCaiPaths.modelsRoot().path}）后点右上重扫，或在下方手动登记';
    }
    switch (task?.state) {
      case DownloadState.downloading:
        return '${task!.stage ?? '下载中'} ${task.downloadedDisplay}/${task.totalDisplay}（${task.progressPercent}）';
      case DownloadState.verifying:
        return '下载完成 — sha256 校验中…';
      case DownloadState.paused:
        return '已暂停 ${task!.downloadedDisplay}/${task.totalDisplay} — 点「继续」断点续传';
      case DownloadState.failed:
        return '下载失败：${task!.errorMessage ?? '未知错误'} — 点「重试」断点续传';
      case DownloadState.completed:
        return '下载完成 — 刷新模型库中…';
      default:
        return '缺文件 — 点「下载」从魔搭/hf-mirror 取 ${entry.sizeMBDisplay}（断点续传 + sha256 校验）；或手动放文件后重扫';
    }
  }

  /// 预置行下载动作组：下载 → 进度条+暂停/取消 → 暂停后继续/取消 → 失败重试。
  /// 完成后 hit 经 [_rescan] 转「已入库」，本组自然消失（completed 分支返回空）。
  List<Widget> _presetDownloadTrailing(ModelConfig? entry, DownloadTask? task) {
    if (entry == null) return const [];
    final n = ref.read(downloadNotifierProvider.notifier);
    Future<void> cancelAndRescan() async {
      await n.cancelDownload(entry.id);
      if (mounted) _rescan();
    }

    switch (task?.state) {
      case DownloadState.downloading:
        return [
          SizedBox(
            width: 64,
            child: LinearProgressIndicator(value: task!.progress, minHeight: 4),
          ),
          const SizedBox(width: 2),
          _iconAction(Icons.pause_rounded, '暂停（保留已下部分）',
              () => n.pauseDownload(entry.id)),
          _iconAction(Icons.close_rounded, '取消（删除已下部分）', cancelAndRescan),
        ];
      case DownloadState.verifying:
      case DownloadState.completed:
        return [
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ];
      case DownloadState.paused:
        return [
          _actionButton(
              label: '继续',
              tone: true,
              onPressed: () => n.resumeDownload(entry.id)),
          _iconAction(Icons.close_rounded, '取消（删除已下部分）', cancelAndRescan),
        ];
      default:
        final retry = task?.state == DownloadState.failed;
        return [
          _actionButton(
              label: retry ? '重试' : '下载',
              tone: true,
              onPressed: () => _startPresetDownload(entry)),
        ];
    }
  }

  /// 发起（或续跑）预置模型下载；传输结束后立刻重扫 —— 预置行不等手动
  /// 「重扫」就翻成已入库形态（DownloadService 完成时已把 .tmp 改名为终名）。
  Future<void> _startPresetDownload(ModelConfig entry) async {
    await ref.read(downloadNotifierProvider.notifier).startDownload(entry);
    if (!mounted) return;
    _rescan();
  }

  // =========================================================================
  // ② 本地模型区
  // =========================================================================

  Widget _buildLocalZone(InferenceSettings settings, ModelState ms) {
    final models = List<LocalModelConfig>.from(settings.localModels)
      ..sort((a, b) {
        final ea = _pathExists[a.modelPath] ?? true;
        final eb = _pathExists[b.modelPath] ?? true;
        if (ea != eb) return ea ? -1 : 1;
        return a.displayName
            .toLowerCase()
            .compareTo(b.displayName.toLowerCase());
      });
    if (models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: Text(
          '还没有登记本地模型 —— 点右上 + 选择磁盘上的 .gguf 文件。',
          style: TextStyle(
              fontSize: 11.5, color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (final m in models) {
      final exists = _pathExists[m.modelPath] ?? true;
      final isLoadedHere = ms.modelId == m.id && ms.isLoaded;
      final isLoadingHere = ms.isLoading && ms.modelId == m.id;
      final isDefault = settings.defaultModelId == m.id;
      rows.add(_modelRow(
        title: m.displayName,
        subtitle: exists ? m.modelPath : '文件不在：${m.modelPath}（移动/改名后请编辑重选文件）',
        exists: exists,
        isLoadedHere: isLoadedHere,
        isLoadingHere: isLoadingHere,
        isDefault: isDefault,
        chips: [
          if (m.hasMmproj) _chip('视觉塔', Colors.purple),
          if (m.hasDraft) _chip('草稿加速', Colors.indigo),
          if (m.hasEngine) _chip('引擎 ${m.engineId}', Colors.teal),
          if (m.ctx != null) _chip('ctx ${m.ctx}', Colors.blueGrey),
          if (m.chunk != null) _chip('chunk ${m.chunk}', Colors.blueGrey),
          if (m.gpuLayers != null)
            _chip('-ngl ${m.gpuLayers}', Colors.blueGrey),
          if (m.customArgsList.isNotEmpty)
            _chip('自定义尾参 ${m.customArgsList.length}', Colors.orange),
        ],
        onToggleDefault: !exists
            ? null
            : () => ref
                .read(settingsProvider.notifier)
                .setDefaultModel(isDefault ? null : m.id),
        onLoad: !exists
            ? null
            : () => _runLoad(
                  id: m.id,
                  name: m.displayName,
                  load: () => ref
                      .read(modelManagerProvider.notifier)
                      .loadModelByLocalConfig(m),
                ),
        onUnload: isLoadedHere
            ? () => unloadModelAndNotify(ref, context, m.displayName)
            : null,
        onEdit: () => _showLocalModelEditor(existing: m),
        onDelete: () => _confirmDeleteLocalModel(m, scheme),
      ));
    }
    return Column(children: rows);
  }

  /// 移除登记 = 只删登记项，不碰磁盘文件（桌面模型文件归用户自管）。
  Future<void> _confirmDeleteLocalModel(
      LocalModelConfig m, ColorScheme scheme) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('移除登记「${m.displayName}」？'),
        content: const Text(
            '仅从列表移除这条登记，**不会删除磁盘上的模型文件**。之后可重新「添加本地模型」。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(settingsProvider.notifier).deleteLocalModel(m.id);
    _toast('已移除登记「${m.displayName}」（文件保留在磁盘）');
  }

  // =========================================================================
  // 添加 / 编辑本地模型
  // =========================================================================

  Future<void> _addLocalModelViaPicker() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 GGUF 模型文件',
      type: FileType.custom,
      allowedExtensions: ['gguf'],
    );
    final path = (picked?.files.isNotEmpty ?? false) ? picked!.files.single.path : null;
    if (path == null) return;
    if (ref.read(settingsProvider).localModels.any((m) => m.modelPath == path)) {
      _toast('这个文件已登记过了', warn: true);
      return;
    }
    _showLocalModelEditor(pickedPath: path);
  }

  Future<void> _showLocalModelEditor({
    String? pickedPath,
    LocalModelConfig? existing,
  }) async {
    final draft = await showDialog<_LocalModelDraft>(
      context: context,
      builder: (_) => _LocalModelEditor(
        pickedPath: pickedPath,
        existing: existing,
      ),
    );
    if (draft == null) return;
    final notifier = ref.read(settingsProvider.notifier);
    if (existing == null) {
      await notifier.addLocalModel(draft.toConfig(newLocalModelId()));
      _toast('已登记「${draft.toConfig(newLocalModelId()).displayName}」');
    } else {
      await notifier.updateLocalModel(draft.toConfig(existing.id));
      _toast('已更新「${draft.toConfig(existing.id).displayName}」');
    }
    setState(() => _storageTick++);
    await _rescan();
  }

  // =========================================================================
  // 加载流（与旧 _handleLoadModel 同骨架：切换确认 → 停生成 → 进度弹窗 →
  // 按结果播报）。catalog 下载链路的 _handleLoadModel 已随 Phase 2 移除。
  // =========================================================================

  Future<void> _runLoad({
    required String id,
    required String name,
    required Future<bool> Function() load,
  }) async {
    final manager = ref.read(modelManagerProvider.notifier);
    if (manager.isBusy) return;

    // 1) 已有别的模型在内存 → 确认后切换。
    if (manager.isLoadedState && manager.modelId != id) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.info_outline, color: Colors.orange),
              SizedBox(width: 8),
              Text('已有模型正在运行'),
            ],
          ),
          content: Text(
            '当前「${manager.currentModelName}」已在内存中。\n\n'
            '切换到「$name」会先卸载当前模型，再加载新模型。确定继续吗？',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('切换模型')),
          ],
        ),
      );
      if (confirm != true) return;
    }

    // 2) 推理中必须先停回合，否则卸载模型会令引擎崩溃。
    if (ref.read(runningTurnsProvider).isNotEmpty) {
      try {
        await ref.read(chatNotifierProvider.notifier).stopGeneration();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (!mounted) return;

    // 3) 进度弹窗 + 后台加载。
    final loadFuture = load();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ModelLoadProgressDialog(modelName: name),
    );
    final ok = await loadFuture;

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (!mounted) return;
    if (ok) {
      ref.read(currentModelIdProvider.notifier).state = id;
      _toast('✅ $name 已加载到内存');
      return;
    }
    // Phase 3c 按需下载闭环：路由报「缺 cuda/vulkan 引擎」→ 弹下载层
    // （官方 release + 镜像兜底 + sha256），装成功后自动重试加载。
    final variant = LocalServerInference.instance.lastInstallSuggestion;
    if (variant != null) {
      final installed = await _showEngineInstallDialog(variant);
      if (!mounted) return;
      if (installed == true) {
        final retry = await load();
        if (!mounted) return;
        if (retry) {
          ref.read(currentModelIdProvider.notifier).state = id;
          _toast('✅ $name 已加载到内存');
          return;
        }
      }
    }
    _toast('❌ $name 加载失败，请查看「推理引擎」页的日志', warn: true);
  }

  /// 「下载引擎」弹层（Phase 3c）：自动开跑官方包下载（进度条），成功
  /// 返回 true；失败/关闭返回 false。目录与镜像取 settings（enginesDir /
  /// engineMirror，未配置走数据区默认 + 官方直连）。
  Future<bool?> _showEngineInstallDialog(String variant) async {
    final s = await ref.read(settingsServiceProvider).load();
    if (!mounted) return null;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EngineInstallDialog(
        variant: variant,
        enginesDir: s.enginesDir,
        mirrors:
            s.engineMirror == null ? const [] : [s.engineMirror!],
        introText: '本地没有可用引擎，需要官方 llama.cpp 运行包'
            '（GitHub Release，sha256 白名单校验）。',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 本地模型 编辑卡（添加/编辑共用）。纯收集表单：提交时组装 _LocalModelDraft
// 弹回调用方，由调用方负责持久化 —— 对话框不做副作用，取消即无痕。
// ---------------------------------------------------------------------------

/// 编辑卡收集到的原始字段（字符串口径，[toConfig] 时统一清洗解析）。
class _LocalModelDraft {
  final String name;
  final String modelPath;
  final String? mmprojPath;
  final String? draftPath;
  final String? engineId;
  final int? ctx;
  final int? chunk;
  final int? gpuLayers;
  final List<String> customArgs;

  const _LocalModelDraft({
    required this.name,
    required this.modelPath,
    this.mmprojPath,
    this.draftPath,
    this.engineId,
    this.ctx,
    this.chunk,
    this.gpuLayers,
    this.customArgs = const [],
  });

  LocalModelConfig toConfig(String id) => LocalModelConfig(
        id: id,
        name: name.trim(),
        modelPath: modelPath,
        engineId: engineId,
        customArgs: customArgs.isEmpty ? null : customArgs,
        mmprojPath: mmprojPath,
        draftPath: draftPath,
        ctx: ctx,
        chunk: chunk,
        gpuLayers: gpuLayers,
      );
}

class _LocalModelEditor extends ConsumerStatefulWidget {
  final String? pickedPath; // 添加模式：FilePicker 已选主文件
  final LocalModelConfig? existing; // 编辑模式

  const _LocalModelEditor({this.pickedPath, this.existing});

  @override
  ConsumerState<_LocalModelEditor> createState() => _LocalModelEditorState();
}

class _LocalModelEditorState extends ConsumerState<_LocalModelEditor> {
  late final TextEditingController _name;
  late String? _modelPath;
  late String? _mmproj;
  late String? _draft;
  late String? _engineId;
  late final TextEditingController _ctx;
  late final TextEditingController _chunk;
  late final TextEditingController _gpuLayers;
  late final TextEditingController _customArgs;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _modelPath = widget.pickedPath ?? e?.modelPath;
    _name = TextEditingController(
        text: e?.name ??
            (_modelPath != null ? p.basenameWithoutExtension(_modelPath!) : ''));
    _mmproj = e?.mmprojPath;
    _draft = e?.draftPath;
    _engineId = (e?.hasEngine ?? false) ? e!.engineId : null;
    _ctx = TextEditingController(text: e?.ctx?.toString() ?? '');
    _chunk = TextEditingController(text: e?.chunk?.toString() ?? '');
    _gpuLayers = TextEditingController(text: e?.gpuLayers?.toString() ?? '');
    _customArgs =
        TextEditingController(text: (e?.customArgsList ?? const []).join('\n'));
  }

  @override
  void dispose() {
    _name.dispose();
    _ctx.dispose();
    _chunk.dispose();
    _gpuLayers.dispose();
    _customArgs.dispose();
    super.dispose();
  }

  Future<String?> _pickGguf() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 GGUF 文件',
      type: FileType.custom,
      allowedExtensions: ['gguf'],
    );
    return (picked?.files.isNotEmpty ?? false) ? picked!.files.single.path : null;
  }

  int? _parseInt(TextEditingController c) =>
      int.tryParse(c.text.trim().isEmpty ? '' : c.text.trim());

  void _submit() {
    final path = _modelPath;
    if (path == null || path.isEmpty) {
      setState(() => _error = '请先选择模型文件（.gguf）');
      return;
    }
    if (!File(path).existsSync()) {
      setState(() => _error = '文件不存在：$path');
      return;
    }
    final draft = _LocalModelDraft(
      name: _name.text,
      modelPath: path,
      mmprojPath: _mmproj,
      draftPath: _draft,
      engineId: _engineId,
      ctx: _parseInt(_ctx),
      chunk: _parseInt(_chunk),
      gpuLayers: _parseInt(_gpuLayers),
      customArgs: _customArgs.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
    );
    Navigator.pop(context, draft);
  }

  Widget _pathField(String label, String? value,
      {required Future<void> Function() onPick, VoidCallback? onClear}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(label,
                style: const TextStyle(fontSize: 12.5, height: 1.2)),
          ),
          Expanded(
            child: Text(
              value ?? '（未选择）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.5,
                  color: value == null ? scheme.outline : null),
            ),
          ),
          TextButton(onPressed: () => onPick(), child: const Text('选择…')),
          if (value != null && onClear != null)
            TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                    foregroundColor: scheme.error,
                    visualDensity: VisualDensity.compact),
                child: const Text('清除')),
        ],
      ),
    );
  }

  Widget _numField(String label, TextEditingController c, String hint) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
              width: 76,
              child: Text(label,
                  style: const TextStyle(fontSize: 12.5, height: 1.2))),
          Expanded(
            child: SizedBox(
              height: 34,
              child: TextField(
                controller: c,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: hint,
                  hintStyle: TextStyle(fontSize: 11),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final engineIds = bundledManifests().values
        .where((m) => m.kind == 'llamaServer')
        .toList(growable: false);
    return AlertDialog(
      title: Text(isEdit ? '编辑本地模型' : '添加本地模型'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _pathField('模型文件', _modelPath, onPick: () async {
                final path = await _pickGguf();
                if (path == null) return;
                setState(() {
                  _modelPath = path;
                  _error = null;
                  if (_name.text.trim().isEmpty) {
                    _name.text = p.basenameWithoutExtension(path);
                  }
                });
              }, onClear: null),
              _pathField('视觉塔 mmproj', _mmproj, onPick: () async {
                final path = await _pickGguf();
                if (path != null) setState(() => _mmproj = path);
              }, onClear: () => setState(() => _mmproj = null)),
              _pathField('草稿 (MTP)', _draft, onPick: () async {
                final path = await _pickGguf();
                if (path != null) setState(() => _draft = path);
              }, onClear: () => setState(() => _draft = null)),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const SizedBox(
                        width: 76,
                        child: Text('引擎',
                            style:
                                TextStyle(fontSize: 12.5, height: 1.2))),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        value: _engineId,
                        isExpanded: true,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('Auto（按模型路由）')),
                          for (final m in engineIds)
                            DropdownMenuItem<String?>(
                                value: m.id, child: Text(m.display)),
                        ],
                        onChanged: (v) => setState(() => _engineId = v),
                      ),
                    ),
                  ],
                ),
              ),
              _numField('ctx', _ctx, '上下文长度（留空 = 引擎/预设默认）'),
              // chunk 是 OpenVINO 专属概念，绑 GPU 引擎时不该出现；
              // -ngl 反之（NPU 线无效）。Auto（未绑定）两者都显示。
              if (_engineId == null || _engineId == 'wangcai-npu')
                _numField('chunk', _chunk, 'NPU prefill chunk（留空=引擎值）'),
              if (_engineId == null ||
                  _engineId == 'llamacpp-cuda' ||
                  _engineId == 'llamacpp-vulkan')
                _numField('gpuLayers', _gpuLayers,
                    '-ngl（GPU 卸载层数，留空=引擎值）'),
              const SizedBox(height: 6),
              TextField(
                controller: _customArgs,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  alignLabelWithHint: true,
                  labelText: '自定义尾参（一行一个，如 -np 1）',
                  helperText: '追加在启动命令末尾；模型级 > 引擎默认 > 出厂模板',
                  hintStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_error!,
                      style: TextStyle(fontSize: 11.5, color: Colors.red)),
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: Text(isEdit ? '保存' : '登记')),
      ],
    );
  }
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    // 6 个 Tab（模型管理/API 接入/推理引擎/智能体/开发者/关于）——
    // length 必须与 TabBar/TabBarView 数量一致。
    _tabController = TabController(length: 7, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 标题字号收敛（默认 20 偏大），标题栏整体压扁，给正文留更多空间。
        title: const Text('设置', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        toolbarHeight: 46,
        bottom: TabBar(
          controller: _tabController,
          // 窄屏可横向滑动，避免「TAB 字未能露出」被裁切。
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          // 小图标 + 小字号，减少标题栏占用的纵向空间。
          indicatorWeight: 2,
          labelStyle:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 12),
          tabs: const [
            Tab(icon: Icon(Icons.storage, size: 18), text: '模型管理'),
            Tab(icon: Icon(Icons.cloud, size: 18), text: 'API 接入'),
            Tab(icon: Icon(Icons.memory, size: 18), text: '推理引擎'),
            Tab(icon: Icon(Icons.smart_toy, size: 18), text: '智能体'),
            // 「能力」独立成 Tab（2026-10-24 用户定案）：插件与技能是**智能体的能力扩展面**，
            // 不该并进「开发者」（那是 Dev Agent/SSH 的地盘）。这里按梯队管三层：
            // 原生能力（默认开）→ 插件 → 技能。
            Tab(icon: Icon(Icons.bolt_outlined, size: 18), text: '能力'),
            Tab(icon: Icon(Icons.construction, size: 18), text: '开发者'),
            Tab(icon: Icon(Icons.info, size: 18), text: '关于'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          const ApiSettingsBody(),
          const InferenceEngineSettingsBody(),
          const AgentSettingsBody(),
          CapabilitySettingsBody(controller: _tabController),
          const DevSettingsBody(),
          const _buildAboutTab(),
        ],
      ),
    );
  }
}

// =========================================================================
// Tab 2: 推理引擎
// =========================================================================

class InferenceEngineSettingsBody extends ConsumerWidget {
  const InferenceEngineSettingsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modelState = ref.watch(modelManagerProvider);
    final gpuSettings = ref.watch(settingsProvider);
    final gpuNotifier = ref.read(settingsProvider.notifier);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- Windows 引擎管理（WangCai 分叉 #8，见 UPSTREAM.md）----
          if (Platform.isWindows) const EngineManagerSection(),
          const SizedBox(height: 10),

          // ---- 思考模式设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '🧠 思考模式',
                    gpuSettings.enableThinking,
                    (v) {
                      gpuNotifier.setEnableThinking(v);
                      // 立即同步到原生层，无需重新加载模型。
                      ref.read(inferenceServiceProvider).setEnableThinking(v);
                    },
                    subtitle: '先输出推理过程再给结论；直接作答更快（仅思考型模型生效）',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 上下文大小设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧩 上下文大小（Context Size）', context),
                  const SizedBox(height: 4),
                  const Text(
                    '所有本地模型共用的一档：4096 起步已够日常与智能体；'
                    '每刻度 512，最高 16K。上调后重新加载模型生效，'
                    '首载多付一次性编译。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: gpuSettings.contextSize
                              .toDouble()
                              .clamp(InferenceSettings.kContextSizeMin
                                  .toDouble(),
                                  InferenceSettings.kContextSizeMax
                                      .toDouble()),
                          min: InferenceSettings.kContextSizeMin.toDouble(),
                          max: InferenceSettings.kContextSizeMax.toDouble(),
                          // 2026-11-06 拍板：每刻度 512（旧 1k~64k/1k 档退役，
                          // 512 网格下 k 级显示会碎，直接报裸 token 数）。
                          divisions: (InferenceSettings.kContextSizeMax -
                                  InferenceSettings.kContextSizeMin) ~/
                              InferenceSettings.kContextSizeStep,
                          label: '${gpuSettings.contextSize}',
                          onChanged: (v) =>
                              gpuNotifier.setContextSize(v.round()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 92,
                        child: Text(
                          '${gpuSettings.contextSize} token',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 推理引擎扩展设置卡片（视觉投影器 / 资源监控）----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧠 推理引擎扩展', context),
                  const SizedBox(height: 12),
                  _buildToggleTitle(
                    '🖼️ 默认加载视觉投影器',
                    gpuSettings.autoLoadMmproj,
                    gpuNotifier.setAutoLoadMmproj,
                    subtitle: '针对有投影器（mmproj）的视觉模型；关闭后仅文本推理',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 引擎状态卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧠 推理引擎状态', context),
                  const SizedBox(height: 12),

                  // Status row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('当前状态:',
                          style: TextStyle(
                              fontSize: 14, color: Colors.grey.shade700)),
                      _buildLifecycleChipFromState(modelState),
                    ],
                  ),

                  if (modelState.modelName != null &&
                      modelState.modelName!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('当前模型:',
                            style: TextStyle(
                                fontSize: 14, color: Colors.grey.shade700)),
                        Text(modelState.modelName!,
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],

                  if (modelState.errorMessage != null &&
                      modelState.errorMessage!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('错误:',
                            style: TextStyle(fontSize: 14, color: Colors.red)),
                        Expanded(
                          child: Text(
                            modelState.errorMessage!,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.red),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 操作按钮 ----
          _buildSectionHeader('⚡ 快捷操作', context),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const InferenceLogScreen()),
                    );
                  },
                  icon: const Icon(Icons.terminal),
                  label: const Text('查看推理日志'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: modelState.isLoaded
                      ? () => unloadModelAndNotify(
                          ref, context, modelState.modelName ?? '当前模型')
                      : null,
                  icon: const Icon(Icons.close),
                  label: const Text('卸载模型'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),

          if (modelState.isError && modelState.modelId != null) ...[
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () async {
                await ref
                    .read(modelManagerProvider.notifier)
                    .loadModel(modelState.modelId!);
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重试加载'),
            ),
          ],

          const SizedBox(height: 24),

          // ---- 最近日志摘要 ----
          Row(
            children: [
              Expanded(child: _buildSectionHeader('📋 最近日志', context)),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制全部日志',
                onPressed: () => _copyInferenceLogs(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 4),

          RecentLogsWidget(),
        ],
      ),
    );
  }

  Widget _buildLifecycleChipFromState(ModelState modelState) {
    Color color;
    String label;
    switch (modelState.phase) {
      case ModelLifecyclePhase.idle:
        color = Colors.grey;
        label = '未加载';
        break;
      case ModelLifecyclePhase.loading:
        color = Colors.blue;
        label = '加载中...';
        break;
      case ModelLifecyclePhase.loaded:
        color = Colors.green;
        label = '已加载';
        break;
      case ModelLifecyclePhase.unloading:
        color = Colors.orange;
        label = '卸载中...';
        break;
      case ModelLifecyclePhase.error:
        color = Colors.red;
        label = '错误';
        break;
      default:
        color = Colors.grey;
        label = '未知';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 13)),
    );
  }

  /// 一键复制全部推理日志（最近日志摘要与日志页共用语义：全量拼接换行）。
  void _copyInferenceLogs(BuildContext context, WidgetRef ref) {
    final logs = ref.read(modelManagerProvider.notifier).loadingLogs;
    if (logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无日志可复制')),
      );
      return;
    }
    Clipboard.setData(ClipboardData(text: logs.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${logs.length} 条日志')),
    );
  }

}

Widget _buildSectionHeader(String title, BuildContext context) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

/// 标题行内嵌开关：标题 + 右侧 Switch，可选副标题。用于节省卡片纵向空间。
/// 字号紧凑（14/11），开关用 shrinkWrap 减小触点占位。
Widget _buildToggleTitle(
  String title,
  bool value,
  ValueChanged<bool> onChanged, {
  String? subtitle,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 32,
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 2),
        // 副题限高两行 + 省略号：窄面板（内容区约 192dp）里长说明不再折三五行
        // 占满整行；头部信息在前、尾部补充说明超出部分省略（全 8 处 toggle 行共用）。
        Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    ],
  );
}

// =========================================================================
// Tab 4: 智能体（Agent）
// =========================================================================

/// 智能体设置 Tab（v0.2.1 全新引擎对齐）。
///
/// 设计原则：
/// 1. **能力驱动展示**：特性块查询驱动模型的能力快照，不支持则置灰说明；
/// 2. **只保留新引擎真实消费的旋钮**：每项设置都映射到引擎消费点；
/// 3. 旧键不动，新键安全默认，旧配置无损迁移。
class AgentSettingsBody extends ConsumerStatefulWidget {
  const AgentSettingsBody();

  @override
  ConsumerState<AgentSettingsBody> createState() => AgentSettingsBodyState();
}


/// 技能管理 Body（harness 第八轮抽取）：技能库完整管理 = 汇总行 + 展开浏览
/// + 内置查看/另存 + 用户新增（整段粘贴）/编辑/删除/重新扫描。
/// 智能体面板与「能力与实验」面板**共用本 Body**——管理动作就地完成，
/// 不再有「去智能体 Tab 管理技能」的跨面板跳（2026-10-25 用户定案）。
/// 抽取时六处非连续切割，方法块原样搬运（ModelManagementBody 同款纪律）。
class SkillsManagementBody extends StatefulWidget {
  const SkillsManagementBody({super.key});

  @override
  State<SkillsManagementBody> createState() => _SkillsManagementBodyState();
}

class _SkillsManagementBodyState extends State<SkillsManagementBody> {
  /// 用户自定义 skills（null = 扫描中）。
  List<Skill>? _userSkills;

  /// 内置技能清单（常量，取一次避免每次 build 重建）。
  final List<Skill> _builtinSkills = loadBuiltinSkills();

  /// 技能列表展开态：默认**展开**（2026-10-25 用户指令：左栏已有独立面板，
  /// 不许再折叠成一行汇总逼用户多点一次；仍可点标题手动收起）。
  bool _skillsExpanded = true;

  @override
  void initState() {
    super.initState();
    _rescanSkills();
  }

  Future<void> _rescanSkills() async {
    final skills = await loadUserSkills();
    if (!mounted) return;
    setState(() => _userSkills = skills);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.extension, size: 20),
          title: Text(
            // 短形态单行：全角括号长标题在窄面板折行出「0）」孤行（真机截图定案）。
            '技能库 ${_builtinSkills.length} · 我的 ${_userSkills?.length ?? '?'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: const Text(
            '点开浏览/管理；整段粘贴 SKILL.md 即可新增',
            style: TextStyle(fontSize: 12),
          ),
          trailing: Icon(
            _skillsExpanded ? Icons.expand_less : Icons.expand_more,
            size: 20,
            color: Colors.grey,
          ),
          onTap: () => setState(() => _skillsExpanded = !_skillsExpanded),
        ),
        if (_skillsExpanded)
          // 高度自适应：不再按 ~10 条控高（320px）内滚（2026-10-25 用户定案）
          // ——技能面板独立成 Tab 后列表全量铺开，随条目多少自然伸缩，
          // 整页滚动交给宿主 SingleChildScrollView。
          Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in _builtinSkills)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: const Icon(Icons.extension, size: 20),
                      title: Text('内置 · ${s.name}',
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(s.description,
                          style: const TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right,
                          size: 18, color: Colors.grey),
                      onTap: () => _showBuiltinSkillView(s),
                    ),
                  const SizedBox(height: 6),
                  if (_userSkills == null)
                    const Text('正在扫描用户技能…',
                        style: TextStyle(fontSize: 12, color: Colors.grey))
                  else if (_userSkills!.isEmpty)
                    const Text('暂无用户技能',
                        style: TextStyle(fontSize: 12, color: Colors.grey))
                  else
                    for (final s in _userSkills!)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: const Icon(Icons.extension_outlined, size: 20),
                        title: Text('用户 · ${s.name}',
                            style: const TextStyle(fontSize: 14)),
                        subtitle: Text(s.description,
                            style: const TextStyle(fontSize: 12)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: '删除技能',
                          onPressed: () => _confirmDeleteUserSkill(s),
                        ),
                        onTap: () => _showUserSkillDialog(existing: s),
                      ),
                ],
          ),
        Row(
          children: [
            TextButton.icon(
              onPressed: _rescanSkills,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新扫描'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: () => _showUserSkillDialog(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增技能'),
            ),
          ],
        ),
        Text(
          '整段粘贴 SKILL.md 即可新增；同名覆盖内置。',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        ),
      ],
    );
  }

  Future<void> _showBuiltinSkillView(Skill s) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('内置技能：${s.name}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('触发：${s.whenToUse}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 10),
                SelectableText(s.body,
                    style: const TextStyle(fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _showUserSkillDialog(
                  prefillText: buildSkillMarkdown(
                description: s.description,
                whenToUse: s.whenToUse,
                invocation: s.invocation,
                body: s.body,
              ));
            },
            icon: const Icon(Icons.save_as_outlined, size: 16),
            label: const Text('另存为我的技能'),
          ),
        ],
      ),
    );
  }

  /// 新增技能 = **整段粘贴一站式**：一个文本框贴完整 SKILL.md（meta 行 +
  /// `---` + 正文），技能名自动取 `name:` 行、缺省从描述派生——不再逐字段
  /// 手填。[prefillText] 用于"从内置技能另存"。编辑已有技能走字段表单。
  Future<void> _showUserSkillDialog(
      {Skill? existing, String? prefillText}) async {
    if (existing != null) {
      return _showEditSkillDialog(existing);
    }
    final rawCtrl = TextEditingController(text: prefillText ?? '');
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增技能（整段粘贴）'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: TextFormField(
              controller: rawCtrl,
              autofocus: true,
              minLines: 8,
              maxLines: 16,
              decoration: const InputDecoration(
                labelText: '粘贴完整技能文本',
                hintText: 'name: 可选（技能名，缺省从描述取）\n'
                    'description: 一句话描述\n'
                    'whenToUse: 何时触发\n'
                    '---\n'
                    '正文执行指引（步骤/格式/注意）',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请粘贴技能文本' : null,
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final raw = rawCtrl.text;
    // 技能名：`name:` 行优先；缺省从描述派生（去尾标点取前 12 字再 sanitize）。
    final nameMatch =
        RegExp(r'^\s*name\s*:\s*(.+)$', multiLine: true).firstMatch(raw);
    String? name = nameMatch?.group(1)?.trim();
    final Skill parsed;
    try {
      parsed = Skill.parse(raw, name: name ?? '');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('解析失败（格式见输入框提示）：$e')));
      return;
    }
    if (parsed.description.trim().isEmpty || parsed.whenToUse.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少 description / whenToUse 行——'
              '格式：meta 行在前，`---` 分隔正文')));
      return;
    }
    if (name == null || name.isEmpty) {
      final base =
          parsed.description.trim().replaceAll(RegExp(r'[。！？!?.、，,；;：:]'), '');
      final sanitized = sanitizeSkillDirName(base);
      name = (sanitized == null || sanitized.isEmpty)
          ? null
          : (sanitized.length > 12 ? sanitized.substring(0, 12) : sanitized);
    }
    if (name == null || name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法确定技能名：请在文本首行加 `name: 技能名`')));
      return;
    }
    try {
      await writeUserSkill(
        name: name,
        description: parsed.description,
        whenToUse: parsed.whenToUse,
        invocation: parsed.invocation,
        body: parsed.body,
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：${e.message}')));
      return;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    await _rescanSkills();
  }

  /// 编辑已有技能（字段表单；技能名锁定）。
  Future<void> _showEditSkillDialog(Skill existing) async {
    final descCtrl = TextEditingController(text: existing.description);
    final whenCtrl = TextEditingController(text: existing.whenToUse);
    final bodyCtrl = TextEditingController(text: existing.body);
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑技能：${existing.name}'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: '一句话描述',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写描述' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: whenCtrl,
                    decoration: const InputDecoration(
                      labelText: '何时触发（whenToUse）',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写触发条件' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: bodyCtrl,
                    minLines: 5,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: '技能正文（执行指引）',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写正文' : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    try {
      await writeUserSkill(
        name: existing.name,
        previousName: existing.name,
        description: descCtrl.text,
        whenToUse: whenCtrl.text,
        body: bodyCtrl.text,
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：${e.message}')));
      return;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    await _rescanSkills();
  }

  Future<void> _confirmDeleteUserSkill(Skill skill) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除技能：${skill.name}'),
        content: const Text('将从技能目录删除该技能（含其目录下的全部文件），'
            '删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await deleteUserSkill(skill.name);
    await _rescanSkills();
  }
}

class AgentSettingsBodyState extends ConsumerState<AgentSettingsBody> {

  /// 全局记忆条目（null = 加载中；记忆管理卡用）。
  List<MapEntry<String, String>>? _memoryEntries;

  /// 全局 AGENTS.md 路径与字节数（-1 = 不存在）。
  String? _agentsMdPath;
  int _agentsMdLen = -1;

  /// 开发模式状态监听：SSH 连接/工作区激活是异步后台变化，
  /// 必须监听 ChangeNotifier 才能实时刷新（否则"测试连接成功但页面显示未连接"）。
  VoidCallback? _devStateListener;


  @override
  void initState() {
    super.initState();
    _loadAgentsMdInfo();
    _loadMemoryEntries();
    final listener = () {
      if (mounted) setState(() {});
    };
    _devStateListener = listener;
    SshEnvironmentService.instance.addListener(listener);
    DevSessionController.instance.addListener(listener);
  }

  @override
  void dispose() {
    final listener = _devStateListener;
    if (listener != null) {
      SshEnvironmentService.instance.removeListener(listener);
      DevSessionController.instance.removeListener(listener);
    }
    super.dispose();
  }

  // ================= 记忆管理（查看/删除，与 memory.json 同存储） =================

  Future<void> _loadMemoryEntries() async {
    final entries =
        await readGlobalMemorySnapshot(maxEntries: 100, maxValueChars: 200);
    if (!mounted) return;
    setState(() => _memoryEntries = entries);
  }

  Future<void> _confirmDeleteMemoryEntry(String key) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除记忆：$key'),
        content: const Text('删除后智能体将不再记得该条内容，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await deleteGlobalMemoryEntry(key);
    await _loadMemoryEntries();
  }

  Future<void> _confirmClearMemory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部记忆'),
        content: const Text('将删除全部长期记忆条目，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await clearGlobalMemory();
    await _loadMemoryEntries();
  }

  /// 记忆管理列表（嵌在长期记忆开关下方；随开关关闭置灰）。
  Widget _buildMemoryManager(bool enabled) {
    final entries = _memoryEntries;
    if (!enabled) {
      return const Padding(
        padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Text('已关闭；开启后自动注入每回合系统提示',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    if (entries == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Text('暂无记忆。对话里说"记住……"即可写入',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text('${e.key}: ${e.value}',
                        style: const TextStyle(fontSize: 12)),
                  ),
                  InkWell(
                    onTap: () => _confirmDeleteMemoryEntry(e.key),
                    child:
                        const Icon(Icons.close, size: 16, color: Colors.grey),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _confirmClearMemory,
              child: const Text('清空全部', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadAgentsMdInfo() async {
    final file = File(WangCaiPaths.dataDir('AGENTS.md').path);
    if (!mounted) return;
    setState(() {
      _agentsMdPath = file.path;
      _agentsMdLen = file.existsSync() ? file.lengthSync() : -1;
    });
  }

  // ================= ⑤ 用户技能管理（直接落盘 SKILL.md） =================

  /// 查看内置技能内容（只读），可「另存为我的技能」 customized 后覆盖内置。
  /// 编辑自定义热词（多行文本，每行一个；随设置持久化）。
  /// P2-B：添加 MCP server（名称 + 端点 URL）。
  Future<void> _showAddMcpServerDialog(SettingsNotifier notifier) async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加 MCP server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration:
                  const InputDecoration(labelText: '名称（工具前缀 mcp_<名称>_）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                  labelText: '端点 URL（如 http://主机:3000/mcp）'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final url = urlCtrl.text.trim();
    if (name.isEmpty || url.isEmpty) return;
    await notifier.upsertMcpServer(McpServerConfig(
      id: 'mcp_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      url: url,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    // ---- 能力快照（与 chat_provider._engineCapabilitiesFor 同源规则）----
    // api → 原生工具调用 + 并行 5；local/跟随默认 → Prompt-JSON + 并行 2。
    final isApi = settings.agentModelSource == 'api';
    final capsMaxParallel = isApi ? 5 : 2;
    // ---- 双场景档：API 档读写 agentApi* 专键，local 档读写原平铺键 ----
    final profMaxRounds =
        isApi ? settings.agentApiMaxRounds : settings.agentMaxRounds;
    final profTokensPerRound =
        isApi ? settings.agentApiTokensPerRound : settings.agentTokensPerRound;
    final profToolTimeoutMs =
        isApi ? settings.agentApiToolTimeoutMs : settings.agentToolTimeoutMs;
    final profTemperature =
        isApi ? settings.agentApiTemperature : settings.agentTemperature;
    final profAllowParallel = isApi
        ? settings.agentApiAllowParallelTools
        : settings.agentAllowParallelTools;
    final profMaxParallel =
        isApi ? settings.agentApiMaxParallel : settings.agentMaxParallel;
    final profTokensMax = isApi ? 32768 : 16384;
    final effectiveParallel = profAllowParallel ? profMaxParallel : 1;
    final parallelNote = isApi
        ? 'API 路线能力上限 5 路；实际并发 = min(设置值, 能力上限)'
        : '本地路线能力上限 2 路（prompt-JSON 协议）；实际并发 = min(设置值, 2)';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ============ ⓪ 智能体模式总开关（首排） ============
          // 关闭 = 普通聊天：不注入系统提示词/工具定义/AGENTS.md/Skills，
          // prefill 最小，本地小模型友好；打开才走工具循环。
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildToggleTitle(
                '🤖 智能体模式',
                settings.agentEnabled,
                notifier.setAgentEnabled,
                subtitle: settings.agentEnabled
                    ? '开：走智能体循环（注入系统提示词 + 工具定义，可多步调用工具）'
                    : '关：简单聊天直连模型，不注入系统提示词/工具说明，'
                        'prefill 最小；下方所有智能体设置暂不生效',
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ================= ⓪b 对话区文字大小（不受智能体开关门控）=================
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildSliderRow(
                label: '对话文字大小',
                value: (settings.chatTextScale * 100).round(),
                min: 70,
                max: 130,
                divisions: 12,
                display: '${(settings.chatTextScale * 100).round()}%',
                onChanged: (v) => notifier.setChatTextScale(v / 100),
                hint: '对话区文字整体缩放（气泡/思考/工具卡/时间戳），'
                    '默认 100% = 当前字号，可放大缩小前后 30%',
              ),
            ),
          ),

          const SizedBox(height: 10),

          // 关闭总开关时置灰全部子项（不可交互，直观反映"暂不生效"）。
          Opacity(
            opacity: settings.agentEnabled ? 1.0 : 0.45,
            child: IgnorePointer(
              ignoring: !settings.agentEnabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ================= ① 引擎状态（能力总览）=================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          _buildSectionHeader('🤖 驱动模型', context),
                          const Text(
                            '指定智能体由哪个模型驱动；能力徽标随选择实时变化',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          _buildAgentModelSelector(context, ref, settings),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _capChip(isApi ? '场景档：API 档' : '场景档：本地档',
                                  ok: true),
                              _capChip(isApi ? '协议：原生工具调用' : '协议：Prompt-JSON',
                                  ok: true),
                              _capChip('工具调用：支持', ok: true),
                              _capChip('并行上限：$capsMaxParallel 路',
                                  ok: capsMaxParallel > 1),
                              _capChip(
                                  isApi
                                      ? '上下文：由服务端决定'
                                      : '上下文：${settings.agentNctx} tok',
                                  ok: true),
                              _capChip('上下文压缩',
                                  ok: settings.agentCompactEnabled),
                              _capChip('输出溢写', ok: settings.agentSpillEnabled),
                              _capChip('子代理',
                                  ok: settings.agentSubagentEnabled),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildPromptTierRow(settings, notifier, isApi: isApi),
                        ],
                      ),
                    ),
                  ),

                  // ================= ①b 人格 =================
                  // 人格卡已撤（2026-10-25 用户定案）：人格有独立侧栏面板
                  // （切换/新建/编辑/删除都在那里），这里不再重复一份。

                  const SizedBox(height: 10),

                  // ================= ② 核心执行参数 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🔁 执行参数', context),
                          _buildSliderRow(
                            label: '单轮最大步数',
                            value: profMaxRounds,
                            min: 1,
                            max: 100,
                            divisions: 99,
                            display: '$profMaxRounds 步',
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiMaxRounds(v)
                                : notifier.setAgentMaxRounds(v),
                            hint: '一次提问内最多几次模型请求（含工具往返）；'
                                '${isApi ? 'API 档默认 16' : '端侧建议 3–12（默认 12）'}，'
                                '复杂任务可调到 100',
                          ),
                          _buildSliderRow(
                            label: '并发会话槽位',
                            value: settings.agentMaxConcurrentTurns,
                            min: 1,
                            max: 4,
                            divisions: 3,
                            display: '${settings.agentMaxConcurrentTurns} 个',
                            onChanged: (v) =>
                                notifier.setAgentMaxConcurrentTurns(v),
                            hint: '同时允许执行回合的会话数量（默认 1）。'
                                'API 驱动可真正并行；本地模型受引擎限制，'
                                '同一时刻仍只能跑一个会话，其余会提示槽位已满',
                          ),
                          _buildSliderRow(
                            label: '每回合搜索上限',
                            value: settings.agentMaxSearchesPerTurn,
                            min: 1,
                            max: 10,
                            divisions: 9,
                            display: '${settings.agentMaxSearchesPerTurn} 次',
                            onChanged: (v) =>
                                notifier.setAgentMaxSearchesPerTurn(v),
                            hint: 'web_search 每回合最多调用次数（DSH max_uses 语义，默认 5）；'
                                '达到上限拒绝联网、强制基于已有结果回答，杜绝反复搜索',
                          ),
                          _buildSliderRow(
                            label: '每步生成预算',
                            value: profTokensPerRound,
                            min: 128,
                            max: profTokensMax,
                            divisions: (profTokensMax - 128) ~/ 256,
                            display: _formatKValue(profTokensPerRound, 'token'),
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiTokensPerRound(v)
                                : notifier.setAgentTokensPerRound(v),
                            hint: isApi
                                ? 'API 档每步生成 token 上限（默认 8192，云端模型吃满思考）'
                                : '本地档每步生成 token 上限（默认 1024）',
                          ),
                          _buildSliderRow(
                            label: '工具执行超时',
                            value: profToolTimeoutMs,
                            min: 1000,
                            max: 120000,
                            divisions: 119,
                            display: _formatTimeout(profToolTimeoutMs),
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiToolTimeoutMs(v)
                                : notifier.setAgentToolTimeoutMs(v),
                            hint: '单工具超时，防止卡死循环；工具自声明超时优先'
                                '（${isApi ? 'API 档默认 30 秒' : '本地档默认 15 秒'}）',
                          ),
                          _buildDoubleSliderRow(
                            label: '生成温度',
                            value: profTemperature,
                            min: 0.0,
                            max: 2.0,
                            divisions: 20,
                            display: profTemperature.toStringAsFixed(1),
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiTemperature(v)
                                : notifier.setAgentTemperature(v),
                            hint: '工具决策建议 0.3–0.7；创意直答可到 1.0+（默认 0.7）',
                          ),
                          _buildSliderRow(
                            label: '思考失控守卫阈值',
                            value: settings.agentThinkingMaxChars,
                            min: 1000,
                            max: 65536,
                            divisions: 129,
                            display: settings.agentThinkingMaxChars >= 1000
                                ? '${(settings.agentThinkingMaxChars / 1000).toStringAsFixed(1)}k 字'
                                : '${settings.agentThinkingMaxChars} 字',
                            onChanged: (v) =>
                                notifier.setAgentThinkingMaxChars(v),
                            hint: '按**累计**思考字数计（多段思考连写也合计，默认 6000）；'
                                '超限且还没产出答案/工具调用即主动止损。'
                                '确实需要长推理的模型调大此值',
                          ),
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('工具步也允许思考',
                                style: TextStyle(fontSize: 13)),
                            subtitle: Text(
                              '默认关：智能体的工具决策步不思考（只需产出一次工具调用），'
                              '端侧思考失控（动辄几万字独白把预算吃光）几乎都发生在那一步；'
                              '组织最终答案时仍允许思考。打开 = 每步都允许（同旧版行为）',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[600]),
                            ),
                            value: settings.agentThinkingOnToolSteps,
                            onChanged: (v) =>
                                notifier.setAgentThinkingOnToolSteps(v),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ②b API 档专属参数（仅 API 驱动可见）=================
                  // 这些参数只对云端 API 驱动有意义；本地短 KV 模型驱动时整卡
                  // 隐藏，不再让不生效的配置淹没本地用户。
                  if (isApi) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSectionHeader('☁️ API 档专属', context),
                            Text(
                              '仅 API 接入驱动智能体时生效；切回本地模型驱动时'
                              '本卡自动隐藏',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600),
                            ),
                            _buildSliderRow(
                              label: '目标无人值守轮数',
                              value: settings.agentGoalMaxRounds,
                              min: 1,
                              max: 20,
                              divisions: 19,
                              display: '${settings.agentGoalMaxRounds} 轮',
                              onChanged: (v) =>
                                  notifier.setAgentGoalMaxRounds(v),
                              hint: 'goal 未完成时自动续跑的最大回合数'
                                  '（goal_set/exit_plan 生效，默认 8）',
                            ),
                            _buildSliderRow(
                              label: 'API 上下文压缩预算',
                              value: settings.agentApiContextBudget,
                              min: 4096,
                              max: 131072,
                              divisions: 31,
                              display: _formatKValue(
                                  settings.agentApiContextBudget, 'token'),
                              onChanged: (v) =>
                                  notifier.setAgentApiContextBudget(v),
                              hint: '投影历史超此值即自动压缩（默认 32k）；'
                                  '配置了端点窗口时取较小值',
                            ),
                            // 子代理专用模型（P3-2）：重活/子任务可走更便宜的
                            // API 配置，主回答仍走主模型。
                            if (settings.agentSubagentEnabled &&
                                settings.apiModels.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(
                                    left: 4, right: 4, top: 8),
                                child: DropdownButtonFormField<String>(
                                  value: settings.agentSubagentApiModelId,
                                  isDense: true,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '子代理专用模型',
                                    hintText: '跟随主模型',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                        value: '', child: Text('跟随主模型')),
                                    for (final cfg in settings.apiModels)
                                      DropdownMenuItem(
                                          value: cfg.id,
                                          child: Text(cfg.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis)),
                                  ],
                                  onChanged: (v) => notifier
                                      .setAgentSubagentApiModelId(v ?? ''),
                                ),
                              ),
                            // 压缩摘要专用模型（P1-B 按步模型路由）：上下文
                            // 压缩的旧区摘要交给更便宜的模型。
                            if (settings.agentCompactEnabled &&
                                settings.apiModels.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(
                                    left: 4, right: 4, top: 8),
                                child: DropdownButtonFormField<String>(
                                  value: settings.agentCompressionApiModelId,
                                  isDense: true,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '压缩摘要专用模型',
                                    hintText: '跟随子代理模型',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                        value: '', child: Text('跟随子代理模型')),
                                    for (final cfg in settings.apiModels)
                                      DropdownMenuItem(
                                          value: cfg.id,
                                          child: Text(cfg.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis)),
                                  ],
                                  onChanged: (v) => notifier
                                      .setAgentCompressionApiModelId(v ?? ''),
                                ),
                              ),
                            const Divider(height: 20),
                            _buildSectionHeader('🔌 MCP 远程工具', context),
                            if (settings.mcpServers.isEmpty)
                              Text(
                                  '暂未配置。可接入任意 MCP server（Streamable HTTP）'
                                  '扩展工具生态。',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600))
                            else
                              for (final s in settings.mcpServers)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  leading: Icon(s.enabled
                                      ? Icons.lan
                                      : Icons.lan_outlined),
                                  title: Text(s.name,
                                      style: const TextStyle(fontSize: 14)),
                                  subtitle: Text(s.url,
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.grey)),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Switch(
                                        value: s.enabled,
                                        onChanged: (v) =>
                                            notifier.upsertMcpServer(
                                                s.copyWith(enabled: v)),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            size: 18),
                                        onPressed: () =>
                                            notifier.removeMcpServer(s.id),
                                      ),
                                    ],
                                  ),
                                ),
                            TextButton.icon(
                              onPressed: () =>
                                  _showAddMcpServerDialog(notifier),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加 MCP server'),
                            ),
                            Text(
                              '填远程 MCP 端点（如 http://主机:3000/mcp）；'
                              '工具以 mcp_<服务>_<名> 注册，失败自动跳过。',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // ================= ②c 本地档专属参数（仅本地模型驱动可见）=================
                  if (!isApi) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSectionHeader('📱 本地档专属', context),
                            Text(
                              '仅本地模型驱动智能体时生效；这些参数面向端侧短 KV '
                              '上下文，切到 API 驱动时本卡自动隐藏',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600),
                            ),
                            _buildSliderRow(
                              label: '智能体上下文长度',
                              value: settings.agentNctx,
                              min: 1024,
                              max: 65536,
                              divisions: 63,
                              display:
                                  _formatKValue(settings.agentNctx, 'token'),
                              onChanged: (v) => notifier.setAgentNctx(v),
                              hint: '本地引擎 n_ctx，独立于普通聊天；工具历史越多'
                                  '所需越大（默认 8192）。修改后需重载模型生效',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  const SizedBox(height: 10),

                  // ================= ③ 上下文管理 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🗜️ 上下文管理', context),
                          _buildToggleTitle(
                            '超限自动压缩',
                            settings.agentCompactEnabled,
                            notifier.setAgentCompactEnabled,
                            subtitle: '上下文超限时自动裁剪旧轮工具结果（追加摘要 + 影子遮蔽，'
                                '日志永不删原文）。关闭 = 超限直接报错终止',
                          ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '超长工具输出溢写',
                            settings.agentSpillEnabled,
                            notifier.setAgentSpillEnabled,
                            subtitle: '单条工具结果超过约 4k token 时落盘，模型侧只留摘要与文件定位，'
                                '可按需读回；省上下文显著',
                          ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '回合轨迹落盘（排障/评估）',
                            settings.agentTraceExportEnabled,
                            notifier.setAgentTraceExportEnabled,
                            subtitle:
                                '每回合把完整事件流写 ApplicationSupport/traces/*.jsonl，'
                                '供离线回放与质量评估；默认关',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ④ 能力与并行 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧩 能力与并行', context),
                          _buildToggleTitle(
                            '🛠️ 并行工具调用',
                            profAllowParallel,
                            isApi
                                ? notifier.setAgentApiAllowParallelTools
                                : notifier.setAgentAllowParallelTools,
                            subtitle: '模型一次要多个工具时并发执行（$parallelNote）；'
                                '当前生效并发：$effectiveParallel',
                          ),
                          if (profAllowParallel && capsMaxParallel > 2)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _buildSliderRow(
                                label: '并发上限',
                                value: profMaxParallel
                                    .clamp(2, capsMaxParallel)
                                    .toInt(),
                                min: 2,
                                max: capsMaxParallel,
                                divisions: capsMaxParallel - 1,
                                display:
                                    '${profMaxParallel.clamp(2, capsMaxParallel)} 路',
                                onChanged: (v) => isApi
                                    ? notifier.setAgentApiMaxParallel(v)
                                    : notifier.setAgentMaxParallel(v),
                                hint: '同时执行的工具数上限（按驱动模型能力封顶 $capsMaxParallel）',
                              ),
                            )
                          else if (settings.agentAllowParallelTools)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '本地路线并发固定 2 路（能力上限）；换 API 驱动可调更高',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade600),
                              ),
                            ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '🤝 子代理（subagent）',
                            settings.agentSubagentEnabled,
                            notifier.setAgentSubagentEnabled,
                            subtitle: '模型可派生独立子代理执行大任务的子任务（spawn/fork）。'
                                '固定约束：嵌套 ≤ 2 层、子代理内不可申请沙箱升级、每层独立预算',
                          ),
                          // 子代理/压缩摘要专用模型（API 档专属）已移入
                          // 「☁️ API 档专属」卡。
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '🌐 联网搜索',
                            settings.webSearchEnabled,
                            notifier.setWebSearchEnabled,
                            subtitle:
                                '允许调用 web_search/get_weather（实例地址在「API 接入」页配置）',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑤ 指令文件 =================
                  // Skills 管理已独立到「能力」Tab 的技能卡（2026-10-25 用户
                  // 定案：两处重复列表，智能体 Tab 不再放）。
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('📄 指令文件', context),

                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.description_outlined),
                            title: Text(
                              _agentsMdLen < 0
                                  ? 'AGENTS.md 指令文件（未创建）'
                                  : 'AGENTS.md 指令文件（${_agentsMdLen} 字节）',
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: const Text('注入系统提示的全局指令（角色、偏好、约束），点按编辑',
                                style: TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.edit_outlined, size: 18),
                            onTap: _editAgentsMd,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑥ 工具 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧰 工具', context),
                          Text(
                            '核心工具恒可用：时间 / 计算 / 待办 / 便签 / 单位换算 / 文件读写检索。'
                            '以下高级工具按需开启：',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                          ),
                          const SizedBox(height: 4),
                          SwitchListTile(
                            title: const Text('🖥️ Shell 执行（shell_exec）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '设备 shell 命令执行（app 权限内），逐次弹窗审批',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentShellEnabled,
                            onChanged: notifier.setAgentShellEnabled,
                          ),
                          SwitchListTile(
                            title: const Text('🐍 Python 执行（python_exec）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '嵌入式 CPython 跑脚本（计算/数据处理/文件/网络）',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentPythonEnabled,
                            onChanged: notifier.setAgentPythonEnabled,
                          ),
                          SwitchListTile(
                            title: const Text(
                                '🧠 长期记忆（memory_set / memory_get）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '跨会话持久记忆（默认开）：模型可记住偏好/事实，'
                                '并自动注入每回合系统提示',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentMemoryEnabled,
                            onChanged: (v) {
                              notifier.setAgentMemoryEnabled(v);
                              _loadMemoryEntries();
                            },
                          ),
                          _buildMemoryManager(settings.agentMemoryEnabled),
                          SwitchListTile(
                            title: const Text('📂 完整文件访问授权',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '允许经逐次批准访问公共目录/完整文件系统'
                                '（All-Files-Access，默认关）',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentFullFileAccess,
                            onChanged: notifier.setAgentFullFileAccess,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑦ 高级 / 开发者 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧪 高级 / 开发者', context),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: const Text('智能体数据目录',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '会话事件日志(JSONL) / 溢写文件 / 技能 / AGENTS.md',
                                style: TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: _showDataDirs,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '扩展接缝（代码级）：agent/pre-step 可否决单步；tools/result 只读审计；'
                            '流水线 pre/post-execute 可拦截改写。',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),


                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 小部件 ----------------

  /// 能力徽标：绿=支持/开，灰=关或不可用。
  /// 智能体提示词档位（2026-10-27 K90 真机定案）。
  ///
  /// 精简档是给**本地小模型**的：短身份 + 4 条工具纪律 + 核心工具白名单，
  /// 技能目录与 AGENTS.md 不再常驻 prefill。真机（K90/Adreno 830 +
  /// Ling-3.0-tiny Q4_0 OpenCL）实测：完整档系统提示 19507 字符 / 4580 token
  /// 时，tiny 模型整回合不调工具却输出「已查询到当前天气」「文件已保存
  /// /home/user/go.py」——答非所问的根因是提示词体量，不是后端。
  /// API 档恒为完整档（大模型扛得住完整纪律，瘦身反降工具遵循率）。
  Widget _buildPromptTierRow(InferenceSettings settings,
      SettingsNotifier notifier, {required bool isApi}) {
    const labels = {'auto': '自动（推荐）', 'compact': '精简', 'full': '完整'};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('提示词档位', style: TextStyle(fontSize: 13)),
        const SizedBox(height: 2),
        Text(
          isApi
              ? 'API 档恒用完整提示词（11 条工具纪律 + 任务执行纪律 + 全量工具'
                  '清单 + 技能目录），本项不影响 API。'
              : '本地小模型（tiny / 2B 级）建议自动：系统提示只留短身份与 4 条'
                  '工具纪律，工具收进核心白名单，技能目录与 AGENTS.md 不再常驻'
                  '——实测完整档 4.5k token 会把 tiny 逼成「不调工具、编造已执行」。',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final mode in const ['auto', 'compact', 'full'])
              ChoiceChip(
                label: Text(labels[mode]!),
                selected: settings.agentPromptTierMode == mode,
                onSelected: (_) async {
                  await notifier.setAgentPromptTierMode(mode);
                  if (mounted) setState(() {});
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _capChip(String label, {required bool ok}) {
    final color = ok ? Colors.teal : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }

  /// 浮点滑块行（温度）。紧凑排版同 [_buildSliderRow]。
  Widget _buildDoubleSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 12))),
              Text(display,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 12)),
            ],
          ),
          SizedBox(
            height: 34,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: display,
              onChanged: onChanged,
            ),
          ),
          if (hint != null)
            Text(hint,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  // ---------------- 对话框 ----------------

  /// AGENTS.md 编辑对话框（全局文件）。
  Future<void> _editAgentsMd() async {
    final file = File(WangCaiPaths.dataDir('AGENTS.md').path);
    final initial = file.existsSync() ? file.readAsStringSync() : '';
    if (!mounted) return;
    final controller = TextEditingController(text: initial);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('AGENTS.md 指令文件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '作为低权威 workspace guidance 注入系统提示。\n${file.path}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 12,
              minLines: 6,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '例如：回答一律用中文；先列计划再执行…',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    try {
      if (controller.text.trim().isEmpty) {
        if (file.existsSync()) file.deleteSync();
      } else {
        file.writeAsStringSync(controller.text);
      }
    } catch (_) {/* 只读分区等情况：忽略，状态刷新会如实反映 */}
    _loadAgentsMdInfo();
  }

  /// 智能体数据目录对话框（可复制路径）。
  Future<void> _showDataDirs() async {
    if (!mounted) return;
    final dirs = <String, String>{
      '数据根目录': WangCaiPaths.dataRoot().path,
      '会话事件日志（项目树）': WangCaiPaths.dataDir('projects').path,
      '工具输出溢写': WangCaiPaths.dataDir('agent_spill').path,
      '用户技能': WangCaiPaths.dataDir('skills').path,
      'AGENTS.md': _agentsMdPath ?? WangCaiPaths.dataDir('AGENTS.md').path,
      '数据库': WangCaiPaths.dataDir('wangcai.db').path,
    };
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('智能体数据目录'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in dirs.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.key,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text(e.value,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: e.value));
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text('已复制 ${e.key} 路径')),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 驱动模型选择器：显示当前选择，点击弹出选择对话框。
  /// API 模型显示**配置名**（无名称回退模型名）而非内部 id——此前直接显示
  /// agentModelId（ApiModelConfig 的 uuid），用户看到的是一串 key。
  Widget _buildAgentModelSelector(
      BuildContext context, WidgetRef ref, InferenceSettings settings) {
    final String currentLabel;
    if (settings.agentModelSource == null) {
      currentLabel = '跟随默认（本地优先，API 兜底）';
    } else if (settings.agentModelSource == 'local') {
      currentLabel = '本地：${settings.agentModelId}';
    } else {
      String displayName = settings.agentModelId ?? '';
      for (final cfg in settings.apiModels) {
        if (cfg.id == settings.agentModelId) {
          displayName = cfg.name.isEmpty ? cfg.model : cfg.name;
          break;
        }
      }
      currentLabel = 'API：$displayName';
    }

    return InkWell(
      onTap: () => _pickAgentModel(context, ref, settings),
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text(currentLabel, style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  /// 弹出「选择智能体驱动模型」对话框：跟随默认 / 本地模型 / API 模型。
  Future<void> _pickAgentModel(
      BuildContext context, WidgetRef ref, InferenceSettings settings) async {
    final catalog = await loadModelCatalog();
    if (!context.mounted) return;
    final notifier = ref.read(settingsProvider.notifier);
    final apiModels = settings.apiModels;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择智能体驱动模型'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('跟随默认'),
                subtitle: const Text('本地优先，API 兜底'),
                selected: settings.agentModelSource == null,
                onTap: () {
                  Navigator.pop(dialogContext);
                  notifier.setAgentModel(null, null);
                },
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child:
                    Text('本地模型', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              for (final m in catalog)
                ListTile(
                  leading: const Icon(Icons.storage),
                  title: Text(cleanModelName(m.name),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle:
                      Text(m.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: settings.agentModelSource == 'local' &&
                      settings.agentModelId == m.id,
                  onTap: () {
                    Navigator.pop(dialogContext);
                    notifier.setAgentModel('local', m.id);
                  },
                ),
              if (apiModels.isNotEmpty) ...[
                const Divider(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('API 接入模型',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                for (final cfg in apiModels)
                  ListTile(
                    leading: const Icon(Icons.cloud),
                    title: Text(cfg.name.isEmpty ? cfg.model : cfg.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(cfg.id,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: settings.agentModelSource == 'api' &&
                        settings.agentModelId == cfg.id,
                    onTap: () {
                      Navigator.pop(dialogContext);
                      notifier.setAgentModel('api', cfg.id);
                    },
                  ),
              ] else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('暂无 API 模型，请先在「API 接入」配置',
                      style: TextStyle(color: Colors.grey)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
        ],
      ),
    );
  }
}

/// 通用「标签 + 滑块 + 当前值 + 提示」行，用于设置页数值型配置。
/// 紧凑排版：文字 12/11，滑块区压到 34px 高，整体比默认省 ~40% 纵向空间。
Widget _buildSliderRow({
  required String label,
  required int value,
  required int min,
  required int max,
  required int divisions,
  required String display,
  required ValueChanged<int> onChanged,
  String? hint,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Text(display,
                style:
                    const TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
          ],
        ),
        SizedBox(
          height: 34,
          child: Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions,
            // 拖动气泡与行尾一致采用格式化值（k 级），不再裸露原始数值。
            label: display,
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        if (hint != null)
          Text(hint, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    ),
  );
}

/// token 类大数值的 k 级显示：1024→"1k"、1536→"1.5k"、960→"960"。
/// [unit] 如 'token'；注意按 1024 进位（token/字节语义），不用 1000。
String _formatKValue(int v, String unit) {
  if (v >= 1024 && v % 1024 == 0) return '${v ~/ 1024}k $unit';
  if (v > 1024) return '${(v / 1024).toStringAsFixed(1)}k $unit';
  return '$v $unit';
}

/// 毫秒 → 可读时长（如 15000 → "15 秒"）。
String _formatTimeout(int ms) {
  if (ms < 1000) return '$ms 毫秒';
  if (ms % 1000 == 0) return '${ms ~/ 1000} 秒';
  return '${(ms / 1000).toStringAsFixed(1)} 秒';
}

// =========================================================================
// Tab 5: 关于
// =========================================================================

class _buildAboutTab extends StatelessWidget {
  const _buildAboutTab();

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.all(12),
      child: Column(
        children: [
          AboutSettingsCard(),
          SizedBox(height: 10),
          _LicenseCard(),
        ],
      ),
    );
  }
}

// About 页版本号：集中式常量，与 android/app/build.gradle.kts 的
// versionName/versionCode 保持一致。离线沙箱无法下载 package_info_plus 的
// AGP 依赖，故不引插件动态读取，直接用此常量。
const _appVersion = '0.0.5';

/// GitHub 项目主页地址（README 介绍与使用说明）。
const _githubUrl = 'https://github.com/liangjianzeng/WangCai';

/// 通过系统外部浏览器打开 GitHub README 页面。
Future<void> _openGithub(BuildContext context) async {
  final uri = Uri.parse(_githubUrl);
  final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('无法打开浏览器，请手动访问：$_githubUrl')),
    );
  }
}

class AboutSettingsCard extends StatelessWidget {
  const AboutSettingsCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            const WangCaiLogo(size: 64, radius: 14),
            const SizedBox(height: 10),
            const Text(
              '汪柴 WangCai',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Windows 桌面离线 AI 智能体',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 10),
            _AboutRow(label: '版本', value: _appVersion),
            _AboutRow(label: '推理引擎', value: 'llama.cpp b11267'),
            _AboutRow(label: '框架', value: 'Flutter 3.x'),
            _AboutRow(label: '平台', value: 'Android API 33+'),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _openGithub(context),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.open_in_new, size: 18, color: Colors.indigo),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'GitHub 项目主页 · README 介绍与使用说明',
                      style: TextStyle(
                        color: Colors.indigo,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LicenseCard extends StatelessWidget {
  const _LicenseCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('开源许可', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('MIT License'),
            const SizedBox(height: 8),
            const Text('Copyright (c) 2026 TongYi-Lite Contributors'),
            const SizedBox(height: 10),
            const Text(
              '本项目使用 llama.cpp 作为推理引擎，遵循其开源许可协议。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;

  const _AboutRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade700)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// =========================================================================
// 存储信息组件
// =========================================================================

class StorageInfoWidget extends ConsumerStatefulWidget {
  const StorageInfoWidget({super.key});

  @override
  ConsumerState<StorageInfoWidget> createState() => _StorageInfoWidgetState();
}

/// 存储卡（新 UI 形态）：一行摘要「N 个 · 共 X」，明细点开才展开——
/// 模型行自己就带体积，这里再平铺一份模型名/体积是重复信息。
///
/// 明细行带**按行删除**：这一行可能就是模型目录里没有的孤儿文件（换过 id 的
/// 旧模型、手工预置的包），模型管理列表里根本没有它，没有这个按钮就没人能清掉
/// 那几 GB（2026-10-30 换 Spark-X2.5→X2.6 后就留下一个 2.4GB 孤儿）。
class _StorageInfoWidgetState extends ConsumerState<StorageInfoWidget> {
  bool _detail = false;

  /// 扫描结果缓存在 state 里：以前 `future:` 直接写 `_loadStorageInfo()`，
  /// 父级每次重建都重新全盘扫一遍（删完文件想刷新还得靠重建）。
  /// 父级换 key（`_storageTick`）时本 State 重建，扫描自然跟着重来。
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadStorageInfo();
  }

  void _reload() => setState(() => _future = _loadStorageInfo());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final info = snapshot.data!;
        final cachedModels =
            (info['cachedModels'] as List? ?? []).cast<Map<String, dynamic>>();
        final totalBytes = info['totalBytes'] as int? ?? 0;

        return Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: cachedModels.isEmpty
                    ? null
                    : () => setState(() => _detail = !_detail),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                  child: Row(children: [
                    Icon(Icons.storage,
                        size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    const Expanded(
                        child: Text('存储空间',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500))),
                    Text('${cachedModels.length} 个 · ${_formatSize(totalBytes)}',
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                    if (cachedModels.isNotEmpty)
                      Icon(_detail ? Icons.expand_less : Icons.expand_more,
                          size: 16, color: scheme.outline),
                  ]),
                ),
              ),
              if (_detail)
                for (final m in cachedModels)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(36, 0, 6, 6),
                    child: Row(children: [
                      Expanded(
                          child: Text(m['name'] as String,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12))),
                      if (m['orphan'] == true)
                        Tooltip(
                          message: '不在模型目录里（换过 id 的旧模型 / 手工预置包）。\n'
                              '模型管理列表里没有它，只能从这里删。',
                          child: Icon(Icons.help_outline,
                              size: 14, color: scheme.outline),
                        ),
                      Text(_formatSize(m['sizeBytes'] as int),
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant)),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        iconSize: 17,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints:
                            const BoxConstraints(minWidth: 30, minHeight: 26),
                        color: scheme.onSurfaceVariant,
                        tooltip: '删除该模型文件（含投影器/草稿头/专家包）',
                        onPressed: () => _deleteStoredModel(m),
                      ),
                    ]),
                  ),
            ],
          ),
        );
      },
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024)
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
  }

  /// 按行删除一个模型文件：先删它本身，再按 id 清扫附属文件（mmproj 投影器 /
  /// dspark 草稿头 / 拆分专家包 / 残留 .tmp），最后让模型管理列表的「已缓存」
  /// 跟着磁盘真值走。
  ///
  /// 这一行可能是**目录里没有的孤儿文件**（换过 id 的旧模型、手工预置包），
  /// 模型管理列表里没有它 —— 这个按钮是唯一能把那几 GB 清掉的入口。
  Future<void> _deleteStoredModel(Map<String, dynamic> row) async {
    final path = row['path'] as String? ?? '';
    final id = row['id'] as String? ?? '';
    final name = row['name'] as String? ?? id;
    if (path.isEmpty || !mounted) return;

    final ms = ref.read(modelManagerProvider);
    if (id.isNotEmpty && ms.modelId == id && ms.isLoaded) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('该模型正在使用中，请先在模型管理里点「卸载」再删除'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型文件？'),
        content: Text(
          '将移除：\n${p.basename(path)}'
          '（${_formatSize(row['sizeBytes'] as int? ?? 0)}）\n\n'
          '以及它的投影器 / 草稿头 / 专家包等附属文件。之后需要重新下载才能再用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    int removed = 0;
    String? error;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        removed++;
      }
      if (id.isNotEmpty) {
        removed += (await ModelStorageService().deleteModelArtifacts(id)).length;
      }
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;

    // 模型管理列表的「已缓存」跟着磁盘真值走（删的也可能是目录里的正常模型）。
    try {
      await ref
          .read(downloadNotifierProvider.notifier)
          .refreshCacheStatus(await loadModelCatalog());
    } catch (_) {}
    if (!mounted) return;

    _reload();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error != null
          ? '删除失败：$error'
          : '已删除「$name」（$removed 个文件）'),
      backgroundColor: error != null ? Colors.orange : null,
    ));
  }

  Future<Map<String, dynamic>> _loadStorageInfo() async {
    final cachedModels = <Map<String, dynamic>>[];
    int totalBytes = 0;

    try {
      // 目录列表统一由 ModelStorageService 提供（内含 Android 路径别名去重）。
      //
      // 曾经这里自行拼三份目录：主目录 + 硬编码 `/data/data/<pkg>/app_flutter/models`
      // + `getApplicationDocumentsDirectory()/models`。而后者返回的是
      // `/data/user/0/<pkg>/app_flutter/models` —— 与前者是**同一个物理目录**
      // （同一 inode，bind mount 别名），字符串却不同，于是同一个目录被扫两遍：
      // **每个模型列出两遍、总占用翻倍**。去重已在 candidateModelDirs() 内完成。
      final dirs = await modelStorageService.candidateModelDirs();

      final seenFiles = <String>{};
      for (final dir in dirs) {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is! File) continue;
          final isGguf = entity.path.endsWith('.gguf');
          final isMmproj = entity.path.endsWith('.mmproj');
          // 投机草稿头落盘形如 `<模型id>.dspark.gguf`：它是模型的附属文件，
          // 不是独立模型。此前只按扩展名过滤，草稿头会多出一行（看起来像"双份模型"）。
          final isDspark = entity.path.endsWith('.dspark.gguf');
          if (!isGguf && !isMmproj) continue;
          // 兜底：同一物理文件的不同路径写法（别名/软链）只计一次。
          var realPath = entity.path;
          try {
            realPath = await entity.resolveSymbolicLinks();
          } catch (_) {}
          if (!seenFiles.add(ModelStorageService.pathDedupeKey(realPath))) {
            continue;
          }
          final sizeBytes = await entity.length();
          totalBytes += sizeBytes;
          // 投影器 / 草稿头只计入总量，不单列模型行。
          if (!isGguf || isDspark) continue;
          final fileName = p.basenameWithoutExtension(entity.path);

          String displayName = fileName;
          // 「目录里没有」= 孤儿文件（换过 id 的旧模型 / 手工预置包），明细行
          // 给个 ? 角标，说明它为什么在模型管理列表里找不到。
          var orphan = false;
          try {
            final allModels = await loadModelCatalog();
            final match = allModels.where((m) => m.id == fileName).toList();
            if (match.isNotEmpty) {
              displayName = match.first.name;
            } else {
              orphan = true;
            }
          } catch (_) {}

          cachedModels.add({
            'name': displayName,
            'id': fileName,
            'path': entity.path,
            'sizeBytes': sizeBytes,
            'orphan': orphan,
          });
        }
      }
    } catch (e) {
      debugPrint('[Settings] Failed to scan storage: $e');
    }

    return {'cachedModels': cachedModels, 'totalBytes': totalBytes};
  }
}

// =========================================================================
// 最近日志组件（在推理引擎 Tab 显示）
// =========================================================================

class RecentLogsWidget extends ConsumerWidget {
  const RecentLogsWidget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(modelManagerProvider.notifier);
    final logs = manager.loadingLogs;

    if (logs.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8)),
        child: const Center(
          child: Column(
            children: [
              Icon(Icons.help_outline, size: 48, color: Colors.grey),
              SizedBox(height: 8),
              Text('暂无日志', style: TextStyle(color: Colors.grey)),
              SizedBox(height: 4),
              Text('点模型列表里的「加载」后开始记录',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final log = logs[index];
          IconData icon;
          Color color;

          if (log.contains('✓') || log.contains('成功')) {
            icon = Icons.check_circle;
            color = Colors.green;
          } else if (log.contains('失败') ||
              log.contains('错误') ||
              log.contains('ERROR')) {
            icon = Icons.error;
            color = Colors.red;
          } else {
            icon = Icons.terminal;
            color = Colors.blueGrey;
          }

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    log,
                    style: TextStyle(
                        fontSize: 12,
                        color: color.withValues(alpha: 0.9),
                        fontFamily: 'monospace'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// =========================================================================
// 自定义模型显示名称输入框（可选）
// =========================================================================

/// 自定义模型显示名称输入框（可选）。
/// 用 StatefulWidget 持有独立的 TextEditingController，
/// 使下载进度频繁重建时不会丢失输入焦点/光标。
/// 模型名内联编辑框（替换原独立「自定义名称」行）。
/// 直接显示在模型卡片标题位置：有自定义名则显示自定义名，否则显示模型配置名
/// 「下载引擎」弹层（Phase 3c 按需下载闭环）：打开即自动下载官方
/// llama.cpp 包（镜像兜底 + sha256 校验 + 解包，全在 EngineStore），
/// 成功 pop(true) → 调用方重试加载；失败给错误文案。下载中途不可取消
/// （EngineStore 无取消语义，假取消会留 .zip.tmp 残骸——如实呈现）。
/// 加载模型时的「加载中」对话框。
/// 监听 [modelManagerProvider]，实时展示原生层推送的最新加载日志，
/// 让用户清楚大模型（数 GB）加载的进展，避免误以为卡死。
class _ModelLoadProgressDialog extends ConsumerWidget {
  final String modelName;
  const _ModelLoadProgressDialog({required this.modelName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ms = ref.watch(modelManagerProvider);
    final log = ms.latestLog;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 10),
              Text('正在加载模型…', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(modelName,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              if (log != null)
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      log,
                      style:
                          TextStyle(fontSize: 12, color: Colors.blue.shade800),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 卸载当前已加载模型，并弹出结果提示（成功/失败）。
/// 顶层函数：设置页（模型卡片 / 推理引擎页）均可调用。
/// 卸载完成后由 modelManagerProvider 状态变化驱动 UI 刷新（模型卡片、引擎状态卡）。
Future<void> unloadModelAndNotify(
  WidgetRef ref,
  BuildContext context,
  String modelName,
) async {
  final manager = ref.read(modelManagerProvider.notifier);
  if (manager.isBusy) return;

  final ok = await manager.unloadModel();
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(ok ? '✅ 已卸载 $modelName，已释放内存' : '❌ 卸载失败，请重试'),
      backgroundColor: ok ? Colors.green : Colors.red,
      duration: const Duration(seconds: 2),
    ),
  );
}

// =========================================================================
// Tab 2: API 接入（OpenAI 兼容远程模型）
// =========================================================================

// =========================================================================
// 「能力」Tab（2026-10-24 用户定案）：插件与技能是**智能体的能力扩展面**，
// 与「智能体 / 上下文压缩 / 人格」这些原生能力放在一起，按梯队管理 ——
// 不再塞进「开发者」（那个 Tab 是 Dev Agent / SSH 的地盘，能力开关藏在那儿没人找得到）。
//
// 三档梯队：
//   ① 原生能力（默认开启）：平台自带的开关，功能"突然没有了"第一个来这儿看；
//   ② 插件：启用 / 参数 / 方案档 / 诊断（启用后图标出现在聊天输入框那一行）；
//   ③ 技能（Skills）：提示词模板，智能体按「何时触发」自己取用。
// =========================================================================
class CapabilitySettingsBody extends ConsumerStatefulWidget {
  const CapabilitySettingsBody({this.controller});

  /// 跳回「智能体」Tab 细调时用（人格表单在那边；技能管理已内联本面板）。
  final TabController? controller;

  @override
  ConsumerState<CapabilitySettingsBody> createState() =>
      CapabilitySettingsBodyState();
}

class CapabilitySettingsBodyState
    extends ConsumerState<CapabilitySettingsBody> {
  void _gotoAgentTab() => widget.controller?.animateTo(3);
  // ================= 语音（T1.6 合并到单一 VoiceSettingsBody）=================
  // 语音播报/输入/热词/模型管理全部收口到 VoiceSettingsBody（主页侧栏「语音」
  // 节唯一挂载），本面板只留一行入口——两份逐行重复的语音卡是 2026-11 事故源
  // （改一份漏一份），T1.6 拍板删除副本。

  Widget _header(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          Text(subtitle,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _card({required List<Widget> children}) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(children: children)),
      );

  Widget _switchRow(String title, bool value,
      Future<void> Function(bool) onChanged, String subtitle) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      value: value,
      onChanged: (v) => onChanged(v),
    );
  }

  Widget _infoRow(
      String title, String value, String subtitle, VoidCallback? onTap) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(fontSize: 12)),
          if (onTap != null) const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header('🟢 原生能力（默认开启）', '平台自带的能力。功能"突然没有了"，第一个来这儿看是不是被谁关了'),
          _card(children: [
            _switchRow('智能体模式', settings.agentEnabled, notifier.setAgentEnabled,
                '关掉就是纯聊天：没有工具、技能与人格'),
            _switchRow('上下文压缩', settings.agentCompactEnabled,
                notifier.setAgentCompactEnabled, '长对话自动压历史，免得一步就顶满上下文'),
            _switchRow('子代理（并行拆解）', settings.agentSubagentEnabled,
                notifier.setAgentSubagentEnabled, '把大任务拆给子代理并行跑'),
            _infoRow('人格（Persona）', '标准 + 自定义', '标准人格开箱即用；增删自定义人格在「智能体」Tab',
                _gotoAgentTab),
          ]),
          // T1.6：语音播报/输入/热词/模型管理收口到 VoiceSettingsBody
          // （主页侧栏「语音」节唯一挂载），本面板留一行入口防迷路。
          _header('🔊 语音（已合并）',
              '播报/听写/热词/模型管理在主页左侧栏「语音」节统一设置'),
          const SizedBox(height: 14),
          _header('🧩 插件（能力扩展）', '启用后图标出现在聊天输入框那一行；参数、方案档、诊断都进这个面板'),
          _card(children: const [
            PluginsEntryTile(pluginsDirHint: '文档/plugins/<插件名>/plugin.json'),
          ]),
          const SizedBox(height: 14),
          _header('⚡ 技能（Skills）',
              '提示词模板；管理动作就地完成，不再跳智能体面板'),
          _card(children: const [SkillsManagementBody()]),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// =========================================================================
// 开发者 Tab：开发模式 + SSH 自动连接向导 + 工作区管理 + 危险命令策略。
// 设计目标（用户反馈）：能自动的绝不手填——密钥自动生成、命令一键复制、
// 连接自动建立、工作区目录自动创建。用户只做"复制粘贴一条命令"。
// =========================================================================
class DevSettingsBody extends ConsumerStatefulWidget {
  const DevSettingsBody();

  @override
  ConsumerState<DevSettingsBody> createState() => DevSettingsBodyState();
}

class DevSettingsBodyState extends ConsumerState<DevSettingsBody> {
  /// SSH 连接/工作区激活是异步后台变化，监听 ChangeNotifier 实时刷新。
  VoidCallback? _devStateListener;

  /// 当前激活工作区下的任务（懒加载；新建/删除后刷新）。
  List<DevTask> _devTasks = const [];
  bool _devTasksLoaded = false;

  @override
  void initState() {
    super.initState();
    final listener = () {
      if (mounted) {
        // 工作区切换会改变任务过滤范围，一并重载。
        _reloadDevTasks();
        setState(() {});
      }
    };
    _devStateListener = listener;
    SshEnvironmentService.instance.addListener(listener);
    DevSessionController.instance.addListener(listener);
    _reloadDevTasks();
  }

  @override
  void dispose() {
    final listener = _devStateListener;
    if (listener != null) {
      SshEnvironmentService.instance.removeListener(listener);
      DevSessionController.instance.removeListener(listener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 插件入口已从「开发者」搬去「能力」Tab（2026-10-24 用户定案：插件/技能是智能体的
          // 能力扩展面，不该混在 Dev Agent/SSH 这堆里）。这里只留一句去路，别让人以为功能没了。
          _buildModeCard(settings, notifier),
          const SizedBox(height: 10),
          _buildConnectionsCard(settings, notifier),
          const SizedBox(height: 10),
          _buildAdbCard(settings, notifier),
          const SizedBox(height: 10),
          _buildWorkspacesCard(settings, notifier),
          const SizedBox(height: 10),
          _buildDevTasksCard(settings, notifier),
          const SizedBox(height: 10),
          _buildSafetyCard(settings, notifier),
        ],
      ),
    );
  }

  // ---------------- ADB 远程控制（另一台手机）----------------

  /// 「远程控制（ADB）」卡：总开关 + 目标机白名单 + 设备授权密钥。
  ///
  /// 放在开发者 Tab 与「连接」卡同区（都是"连别的机器"），但**不受开发模式开关
  /// 约束** —— adb 工具的注册只看 [InferenceSettings.adbEnabled]（用户定案：
  /// 设置里开一下就能用，不做逐次审批）。
  Widget _buildAdbCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '📱 远程控制（ADB）',
              settings.adbEnabled,
              (v) async {
                await notifier.setAdbEnabled(v);
                if (mounted) setState(() {});
              },
              subtitle: settings.adbEnabled
                  ? '开：智能体可用 adb 工具直连下面白名单里的手机（点击/滑动/输入/截屏/装包/日志）'
                  : '关：adb 工具不注册，模型完全看不见（默认）',
            ),
            const SizedBox(height: 4),
            Text(
              'app 内置 ADB 客户端，走 Wi-Fi 直连，无需电脑也无需安装 adb。\n'
              '目标手机需先进入 TCP 模式（电脑上 `adb tcpip 5555`，重启后失效；或开发者选项里'
              '的「无线调试」——注意无线调试端口走 TLS，本版不支持，请用 tcpip 那种）。\n'
              '首次连接时目标机屏幕会弹「允许 USB 调试」，勾选"一律允许"后点确定。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.35),
            ),
            const Divider(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text('目标手机（${settings.adbTargets.length}）',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w600)),
                ),
                TextButton.icon(
                  onPressed: () => _showAdbTargetDialog(notifier, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (settings.adbTargets.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text('还没添加目标机。添加时填 ip:5555（Tailscale 网段可直接 ping 通）。',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ),
            for (final t in settings.adbTargets)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Switch(
                  value: t.enabled,
                  onChanged: (v) =>
                      notifier.upsertAdbTarget(t.copyWith(enabled: v)),
                ),
                title: Text(t.name.isEmpty ? t.serial : t.name,
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                    '${t.serial}${t.port == 5555 ? '' : '  ⚠️ 非常规端口'}',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: '编辑',
                      onPressed: () => _showAdbTargetDialog(notifier, t),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: '删除',
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('删除目标机'),
                            content: Text('删除「${t.name.isEmpty ? t.serial : t.name}」？'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消')),
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('删除')),
                            ],
                          ),
                        );
                        if (ok == true) await notifier.removeAdbTarget(t.id);
                      },
                    ),
                  ],
                ),
              ),
            const Divider(height: 18),
            FutureBuilder<String>(
              // 密钥只在读到时才生成（进设置页不该顺手做 2048 位生成）。
              future: _adbKeyFingerprintFuture,
              builder: (context, snap) {
                return Row(
                  children: [
                    Expanded(
                      child: Text(
                        snap.hasError
                            ? '授权密钥异常：${snap.error}'
                            : (snap.data == null || snap.data!.isEmpty
                                ? '设备授权密钥：尚未生成'
                                : '设备授权密钥：指纹 ${snap.data}'),
                        style: TextStyle(
                            fontSize: 11,
                            color: snap.hasError
                                ? Colors.red.shade700
                                : Colors.grey.shade600),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _showAdbKeyDialog(),
                      child: const Text('公钥/导入', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: () => _regenAdbKey(),
                      child: const Text('重新生成', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                );
              },
            ),
            if (settings.adbEnabled && settings.adbTargets.isNotEmpty) ...[
              const Divider(height: 18),
              TextButton.icon(
                onPressed: _adbSelfTest,
                icon: const Icon(Icons.network_check, size: 16),
                label: const Text('连接自检（逐台握手，验证是否已授权）',
                    style: TextStyle(fontSize: 12)),
              ),
              for (final line in _adbSelfTestLines)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(line,
                      style: TextStyle(
                          fontSize: 11,
                          color: line.startsWith('✓')
                              ? Colors.green.shade700
                              : Colors.red.shade700)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String? _adbKeyFingerprintCache;

  Future<String> get _adbKeyFingerprintFuture async {
    if (_adbKeyFingerprintCache != null) return _adbKeyFingerprintCache!;
    final key = await loadOrCreateAdbKey(FlutterAdbSecretStore());
    return _adbKeyFingerprintCache = adbKeyFingerprint(key);
  }

  Future<void> _regenAdbKey() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新生成授权密钥'),
        content: const Text(
            '所有已授权过的手机都会**掉授权**，需要在每台手机上重新点一次「允许 USB 调试」'
            '（或先在手机上撤销本机的授权记录）。确定要继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重新生成')),
        ],
      ),
    );
    if (ok != true) return;
    final store = FlutterAdbSecretStore();
    await store.delete(kAdbKeySlot);
    _adbKeyFingerprintCache = null;
    await _adbKeyFingerprintFuture;
    if (mounted) setState(() {});
  }

  /// 公钥查看 / 导入已有 `~/.android/adbkey`。
  ///
  /// 导入的价值：那台电脑上早已授权过手机时，用同一把私钥可**免掉重新弹框**。
  Future<void> _showAdbKeyDialog() async {
    final store = FlutterAdbSecretStore();
    final key = await loadOrCreateAdbKey(store);
    if (!mounted) return;
    final pub = adbPublicKeyLine(key);
    final ctrl = TextEditingController();
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备授权密钥'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(pub,
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
              const SizedBox(height: 10),
              Text('粘贴电脑上 ~/.android/adbkey 的内容可导入（导入后这些电脑授权过的手机免重新弹框）：',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              const SizedBox(height: 6),
              TextField(
                controller: ctrl,
                maxLines: 4,
                style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '-----BEGIN RSA PRIVATE KEY-----'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 1),
              child: const Text('复制公钥')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 2),
              child: const Text('导入私钥')),
        ],
      ),
    );
    if (choice == 1) {
      await Clipboard.setData(ClipboardData(text: pub));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('公钥已复制（与 adbkey.pub 首段应完全一致）')));
      }
    } else if (choice == 2) {
      final pem = ctrl.text.trim();
      if (pem.isEmpty) return;
      try {
        await importAdbPrivateKeyPem(store, pem);
        _adbKeyFingerprintCache = null;
        await _adbKeyFingerprintFuture;
        if (mounted) setState(() {});
      } on FormatException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('导入失败：${e.message}')));
        }
      }
    }
  }

  final List<String> _adbSelfTestLines = [];

  /// 逐台握手自检：把"连不上到底是没开 tcpip、没授权，还是 IP 变了"说清。
  Future<void> _adbSelfTest() async {
    setState(() {
      _adbSelfTestLines.clear();
    });
    final store = FlutterAdbSecretStore();
    final key = await loadOrCreateAdbKey(store);
    for (final t in ref.read(settingsProvider).adbTargets.where((e) => e.enabled)) {
      final sw = Stopwatch()..start();
      try {
        final c = await AdbClient.connect(host: t.host, port: t.port, key: key);
        final id = c.identity();
        await c.close();
        _adbSelfTestLines.add('✓ ${t.serial}  ${id.model}  ${sw.elapsedMilliseconds}ms');
      } catch (e) {
        _adbSelfTestLines.add('✗ ${t.serial}  ${e.toString().split('\n').first}');
      }
      if (mounted) setState(() {});
    }
  }

  /// 添加/编辑目标机（名称 + `ip:port` 一行输入，端口可省）。
  Future<void> _showAdbTargetDialog(
      SettingsNotifier notifier, AdbTarget? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final serialCtrl =
        TextEditingController(text: existing == null ? '' : existing.serial);
    var errorText = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? '添加目标手机' : '编辑目标手机'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                    isDense: true, labelText: '名称（如 小米13 主力机）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: serialCtrl,
                autofocus: true,
                decoration: InputDecoration(
                    isDense: true,
                    labelText: '地址（ip:5555，端口可省略）',
                    errorText: errorText.isEmpty ? null : errorText),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(
              onPressed: () {
                final parsed = AdbTarget.parseSerial(serialCtrl.text);
                if (parsed == null) {
                  setDialogState(() => errorText = '填 ip:5555 这种形式');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final parsed = AdbTarget.parseSerial(serialCtrl.text)!;
    await notifier.upsertAdbTarget((existing ??
            const AdbTarget(id: '', name: '', host: '', port: 5555))
        .copyWith(
            name: nameCtrl.text.trim().isEmpty
                ? parsed.host
                : nameCtrl.text.trim(),
            host: parsed.host,
            port: parsed.port));
  }

  // ---------------- 总开关 ----------------

  Widget _buildModeCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '🛠️ 开发模式（Dev Agent）',
              settings.devModeEnabled,
              (v) async {
                await notifier.setDevModeEnabled(v);
                if (mounted) setState(() {});
              },
              subtitle: settings.devModeEnabled
                  ? '开：注册 git/规划/SSH/测试工具，可连远程电脑做 AI 编程'
                  : '关：现有智能体行为完全不变（默认）',
            ),
            const SizedBox(height: 4),
            Text(
              '开启后：对话里的智能体可直接读写远程电脑上的项目，'
              '执行 git 提交、跑测试。连接由下方向导完成：'
              '远程电脑填账号密码即可。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            // P2-D1：Dev 工具逐组开关（默认全开 = 旧行为）。
            if (settings.devModeEnabled) ...[
              const Divider(height: 20),
              Text('工具组开关（默认全开）',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              for (final g in const [
                ('git', 'Git（状态/diff/log/提交/推送）'),
                ('ssh', 'SSH（执行/读写远端文件）'),
                ('sync', '工作区同步（workspace_sync）'),
                ('plan', '计划（plan_create/update/list）'),
                ('task', '任务（task_create/list）'),
                ('verify', '测试验证（run_tests）'),
              ])
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(g.$2, style: const TextStyle(fontSize: 13)),
                  value: settings.devToolGroupEnabled(g.$1),
                  onChanged: (v) => notifier.setDevToolGroupEnabled(g.$1, v),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------- 连接配置（远程电脑） ----------------

  Widget _buildConnectionsCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    final ssh = SshEnvironmentService.instance;
    final sshStatusLabel = switch (ssh.status) {
      SshStatus.idle => '未连接',
      SshStatus.connecting => '连接中…',
      SshStatus.connected => '已连接',
      SshStatus.failed => '失败',
    };
    final sshStatusColor = switch (ssh.status) {
      SshStatus.connected => Colors.green,
      SshStatus.connecting => Colors.orange,
      SshStatus.failed => Colors.red,
      _ => Colors.grey,
    };
    final configs = settings.sshConfigs;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🔌 SSH 连接（自动配置向导）', context),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: sshStatusColor),
                const SizedBox(width: 6),
                Text(sshStatusLabel, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    ssh.isConnected
                        ? '${ssh.activeConfig?.name ?? ''} '
                            '${ssh.activeConfig?.username ?? ''}@'
                            '${ssh.activeConfig?.host ?? ''}:'
                            '${ssh.activeConfig?.port ?? ''}'
                        : (ssh.status == SshStatus.failed &&
                                (ssh.lastError?.isNotEmpty ?? false))
                            ? ssh.lastError!
                            : '未连接（向导自动完成，无需手填密钥）',
                    style: TextStyle(
                        fontSize: 12,
                        color: ssh.status == SshStatus.failed
                            ? Colors.red.shade700
                            : Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 自动向导入口：远程电脑。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _showRemotePcSetupDialog(context, notifier),
                  icon: const Icon(Icons.desktop_windows, size: 16),
                  label: const Text('💻 连接远程电脑'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '远程电脑可用「账号密码」直接连（电脑开好 SSH 服务即可，不必装公钥）；'
              '连接失败会给针对性诊断和修复动作。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            // 配置列表（已保存的连接目标）。
            if (configs.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final cfg in configs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${cfg.name.isEmpty ? '配置' : cfg.name} · '
                          '${cfg.username.isEmpty ? '?' : cfg.username}@'
                          '${cfg.host}:${cfg.port} · ${switch (cfg.authType) {
                            SshAuthType.key => '密钥',
                            SshAuthType.password => '密码',
                            SshAuthType.keyThenPassword => '密钥+密码',
                          }}',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () => _showSshConfigDialog(context, notifier,
                            existing: cfg),
                        child: const Text('编辑'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await notifier.removeSshConfig(cfg.id);
                          if (ssh.activeConfig?.id == cfg.id) {
                            await ssh.disconnect();
                          }
                          if (mounted) setState(() {});
                        },
                        child: const Text('删除'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await _connectTo(cfg);
                          if (mounted) setState(() {});
                        },
                        child: const Text('连接'),
                      ),
                    ],
                  ),
                ),
            ],
            if (ssh.isConnected) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await ssh.disconnect();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('断开'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await ssh.clearHostKeyFingerprints();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.fingerprint, size: 18),
                    label: const Text('清除指纹'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 连接（保持连接；[force] = 用户手点按钮 → 强制重新握手）。
  ///
  /// 注意 1：`SshEnvironmentService.connect` 失败只置内部状态不抛异常，
  /// 必须用 `isConnected` 判定结果，不能依赖 try/catch（否则永远弹"已连接"）。
  /// 注意 2：完整性判定必须在**回填凭据之后**——私钥/密码保存在安全存储里，
  /// settings 里的配置是空槽位，直接判 `isComplete` 会永远提示"配置不完整"。
  Future<bool> _connectTo(SshConfig cfg,
      {bool force = true, bool offerWorkspace = true}) async {
    SshConfig resolved = cfg;
    try {
      resolved = await resolveSshSecrets(cfg);
    } on Exception catch (_) {}
    if (!resolved.isComplete) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(resolved.usesPassword
                ? '配置不完整：请填写「用户名 + 电脑登录密码」后再连接'
                : '配置不完整：请先编辑补全用户名/私钥（或改用密码登录）')));
      }
      return false;
    }
    final ssh = SshEnvironmentService.instance;
    await ssh.connect(resolved, force: force);
    if (!mounted) return false;
    final ok = ssh.isConnected;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '✅ 已连接 ${cfg.name.isEmpty ? cfg.host : cfg.name}'
            : '❌ ${_classifySshError(ssh.lastError, cfg: resolved)}')));
    // 连上 ≠ 能干活：没有激活的远端工作区，智能体收到的上下文仍是本地沙盒。
    // 所以连成功后顺势问一句要不要就地建工作区（已绑定的不再打扰）。
    if (ok && offerWorkspace) await _offerWorkspaceFor(cfg);
    return ok;
  }

  /// 连接成功后的"开工引导"：给这份连接建远端工作区并激活。
  /// 该配置已有绑定的工作区 → 静默跳过（不重复打扰）。
  Future<void> _offerWorkspaceFor(SshConfig cfg) async {
    // D1 双真源收编：绑定判据看**项目**（工作区只是项目的派生缓存）。
    if (ref.read(projectsProvider).projects
        .any((p) => p.isRemote && p.sshConfigId == cfg.id)) {
      return; // 已有绑定这份连接的项目 → 不再打扰。
    }
    if (!mounted) return;
    final what = cfg.name.trim().isEmpty ? cfg.host : cfg.name.trim();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('在「$what」上开工？'),
        content: Text('已连上 $what。\n\n'
            '要不要为它建个工作区（会在电脑上建 ~/projects/<名称> 并设为当前工作区）？'
            '建好后，对话里的智能体就直接在这台电脑上读写代码、跑测试——'
            '否则它仍在本机目录里干活。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('先不用')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('建工作区并切过去')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final ctrl = TextEditingController(text: '我的项目');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('在「$what」上开工'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '项目/工作区名称',
            helperText: '会在电脑上建 ~/projects/<名称> 作为工作区目录',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('创建并切过去')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    // D1：一键开工只产出**项目**（远程项目 = 工作目录唯一真源的远程形态）。
    final r = await ref
        .read(projectsProvider.notifier)
        .createRemoteFromActiveConnection(name);
    if (r.prj == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('❌ ${r.dir}')));
      }
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ 已切到远程项目「${r.prj!.name}」（${r.dir}）：'
            '现在让它「看项目 / 改代码 / 跑测试」都会在这台电脑上执行')));
  }

  /// 远程电脑向导：host/port/用户名 + **认证方式（密码 或 密钥）** + 连接。
  ///
  /// 密码登录是远程电脑最常见也最省事的路径（无需往对端装公钥），设为默认；
  /// 密钥模式仍可「自动生成密钥」并给出装公钥命令，另可选填「密码兜底」
  /// —— 填了就变成密钥优先、失败自动回落密码（[SshAuthType.keyThenPassword]）。
  Future<void> _showRemotePcSetupDialog(
      BuildContext context, SettingsNotifier notifier) async {
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '22');
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    var generated = false;
    String? publicKey;
    String? privateKeyPem;
    var command = '';
    // 默认走密码登录：远程电脑九成 scenario 是"我知道账号密码，不想折腾公钥"。
    var usePasswordLogin = true;
    var showPwd = false;
    var busy = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final pwd = passCtrl.text.trim();
          // 密钥模式下填了密码 = 密钥优先 + 密码兜底。
          final effectiveType = usePasswordLogin
              ? SshAuthType.password
              : (pwd.isNotEmpty
                  ? SshAuthType.keyThenPassword
                  : SshAuthType.key);
          final ready = hostCtrl.text.trim().isNotEmpty &&
              userCtrl.text.trim().isNotEmpty &&
              switch (effectiveType) {
                SshAuthType.password => pwd.isNotEmpty,
                SshAuthType.key => generated,
                SshAuthType.keyThenPassword => generated && pwd.isNotEmpty,
              };
          return AlertDialog(
            title: const Text('💻 连接远程电脑'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: hostCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '电脑地址（必填）',
                        hintText: '局域网 IP 或主机名，如 192.168.1.100',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: TextFormField(
                            controller: portCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '端口',
                              hintText: '22',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(
                            controller: userCtrl,
                            decoration: const InputDecoration(
                              labelText: '电脑用户名（必填）',
                              hintText: '登录电脑用的账号名',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('登录方式',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          avatar: Icon(usePasswordLogin
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                              size: 18),
                          label: const Text('🔑 密码登录（最简单）'),
                          selected: usePasswordLogin,
                          onSelected: (_) => setState(() {
                            usePasswordLogin = true;
                            showPwd = false;
                          }),
                        ),
                        ChoiceChip(
                          avatar: Icon(!usePasswordLogin
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                              size: 18),
                          label: const Text('🗝️ 密钥登录（免密）'),
                          selected: !usePasswordLogin,
                          onSelected: (_) => setState(() {
                            usePasswordLogin = false;
                            showPwd = false;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (usePasswordLogin) ...[
                      TextField(
                        controller: passCtrl,
                        obscureText: !showPwd,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '电脑登录密码（必填）',
                          helperText: '就是你在电脑上输的那个密码；'
                              'Windows 用微软账户登录时填该账户的密码',
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(showPwd
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => showPwd = !showPwd),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '电脑需先开启 SSH 服务：Windows「设置 → 系统 → 可选功能 → OpenSSH 服务器」'
                        '并启动 sshd 服务；Linux `sudo apt install openssh-server`；'
                        'macOS「通用 → 共享 → 远程登录」。连不上多半是防火墙没放行 22 端口。',
                        style: TextStyle(
                            fontSize: 10.5, color: Colors.grey.shade600),
                      ),
                    ] else ...[
                      if (!generated)
                        FilledButton.icon(
                          onPressed: () {
                            final keys = SshKeyGen.generate();
                            if (keys != null) {
                              setState(() {
                                generated = true;
                                publicKey = keys.publicKey;
                                privateKeyPem = keys.privateKeyPem;
                                command =
                                    _buildRemoteInstallCommand(keys.publicKey);
                              });
                            }
                          },
                          icon: const Icon(Icons.key, size: 16),
                          label: const Text('🔑 自动生成密钥'),
                        )
                      else ...[
                        Text('① 在电脑上执行这条命令（把公钥装进 authorized_keys）：',
                            style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 6),
                        _copyableCommand(ctx, command),
                        const SizedBox(height: 4),
                        Text(
                          '公钥：$publicKey',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade600),
                        ),
                      ],
                      const SizedBox(height: 10),
                      TextField(
                        controller: passCtrl,
                        obscureText: !showPwd,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '密码兜底（可选）',
                          helperText: '填了则密钥认证失败时自动改用密码，两条腿走路',
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(showPwd
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => showPwd = !showPwd),
                          ),
                        ),
                      ),
                    ],
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Row(children: [
                          SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('正在连接…', style: TextStyle(fontSize: 12)),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: (busy || !ready)
                    ? null
                    : () async {
                        setState(() => busy = true);
                        final host = hostCtrl.text.trim();
                        final user = userCtrl.text.trim();
                        final cfg = SshConfig.remotePcTemplate.copyWith(
                          name: '远程电脑',
                          host: host,
                          port: int.tryParse(portCtrl.text.trim()) ?? 22,
                          username: user,
                          authType: effectiveType,
                          privateKeyPem:
                              usePasswordLogin ? null : privateKeyPem,
                          password: pwd.isEmpty ? null : pwd,
                        );
                        await notifier.upsertSshConfig(cfg);
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        await _connectTo(cfg);
                      },
                child: Text(busy
                    ? '连接中…'
                    : (ready
                        ? '保存并连接'
                        : (usePasswordLogin ? '填写地址/用户名/密码' : '先生成密钥'))),
              ),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  /// 可复制的命令块（选中即复制）。
  Widget _copyableCommand(BuildContext ctx, String command) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
          IconButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(const SnackBar(content: Text('已复制，去粘贴执行即可')));
              }
            },
            icon: const Icon(Icons.copy, size: 16, color: Colors.white),
          ),
        ],
      ),
    );
  }

  /// SSH 连接失败 → 人话 + 下一步动作（不甩原始异常）。
  ///
  /// 可用性评估实锤：旧版一套话术通吃所有失败——连电脑用户也被教去 Termux 装密钥。
  /// 现按目标类型与认证方式（密钥/密码）分流。
  String _classifySshError(String? raw, {required SshConfig cfg}) {
    return classifySshFailure(
      raw,
      target: sshTargetKindOf(cfg),
      passwordAuth: sshUsesPasswordAuth(cfg),
      keyAuth: cfg.usesKey,
    );
  }

  /// 远程电脑添加公钥命令（追加，不覆盖已有公钥）。
  String _buildRemoteInstallCommand(String publicKey) {
    return 'mkdir -p ~/.ssh && echo "$publicKey" >> ~/.ssh/authorized_keys && '
        'chmod 600 ~/.ssh/authorized_keys && echo ALL_DONE';
  }

  // ---------------- SSH 配置编辑 ----------------

  /// 编辑指定配置（existing 为空则新建）。
  ///
  /// 凭据（私钥/登录密码）平时只存在安全存储里，settings 里是空槽位 ——
  /// 所以打开编辑框前要先 [resolveSshSecrets] 回填，否则"编辑一下主机名再保存
  /// 就把密码清空了"。留空提交 = 保持原凭据不变（不会误删）。
  Future<void> _showSshConfigDialog(
      BuildContext context, SettingsNotifier notifier,
      {SshConfig? existing}) async {
    SshConfig? cfg = existing;
    if (cfg != null) {
      try {
        cfg = await resolveSshSecrets(cfg);
      } on Exception catch (_) {}
      if (!mounted) return; // 异步回填凭据后可能已离开页面。
    }
    final storedPassword = cfg?.password ?? '';
    final storedKeyPem = cfg?.privateKeyPem ?? '';
    final nameCtrl = TextEditingController(text: cfg?.name ?? '');
    final hostCtrl = TextEditingController(text: cfg?.host ?? '127.0.0.1');
    final portCtrl =
        TextEditingController(text: (cfg?.port ?? 8022).toString());
    final userCtrl = TextEditingController(text: cfg?.username ?? '');
    final passCtrl = TextEditingController(text: storedPassword);
    final keyCtrl = TextEditingController(text: storedKeyPem);
    final passPhraseCtrl = TextEditingController(text: cfg?.keyPassphrase ?? '');
    final formKey = GlobalKey<FormState>();
    var authType = cfg?.authType ?? SshAuthType.key;
    var showPwd = false;
    String? generatedPublicKey;
    var genCommand = '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? '新增连接配置' : '编辑连接配置'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '配置名称',
                        hintText: '如：家里电脑 / 工作电脑',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: hostCtrl,
                      decoration: const InputDecoration(
                        labelText: '主机',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请填写主机' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (int.tryParse(v ?? '') ?? 0) <= 0 ? '端口非法' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: userCtrl,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请填写用户名' : null,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('密钥'),
                          selected: authType == SshAuthType.key,
                          onSelected: (_) => setState(() {
                            authType = SshAuthType.key;
                            showPwd = false;
                          }),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('密码'),
                          selected: authType == SshAuthType.password,
                          onSelected: (_) => setState(() {
                            authType = SshAuthType.password;
                            showPwd = false;
                          }),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('密钥+密码兜底'),
                          selected: authType == SshAuthType.keyThenPassword,
                          onSelected: (_) => setState(() {
                            authType = SshAuthType.keyThenPassword;
                            showPwd = false;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (authType != SshAuthType.password) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text('私钥（PEM / OpenSSH）',
                                style: const TextStyle(fontSize: 13)),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              final keys = SshKeyGen.generate();
                              if (keys == null) return;
                              setState(() {
                                generatedPublicKey = keys.publicKey;
                                genCommand =
                                    _buildRemoteInstallCommand(keys.publicKey);
                                keyCtrl.text = keys.privateKeyPem;
                              });
                            },
                            icon: const Icon(Icons.auto_awesome, size: 16),
                            label: const Text('自动生成',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                      TextFormField(
                        controller: keyCtrl,
                        minLines: 3,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? '请填写私钥，或点「自动生成」'
                            : null,
                      ),
                      if (generatedPublicKey != null) ...[
                        const SizedBox(height: 6),
                        Text('把这条命令在目标机器上执行一次（装公钥）：',
                            style: const TextStyle(fontSize: 11)),
                        const SizedBox(height: 4),
                        _copyableCommand(ctx, genCommand),
                      ],
                      const SizedBox(height: 8),
                      TextField(
                        controller: passPhraseCtrl,
                        obscureText: !showPwd,
                        decoration: InputDecoration(
                          labelText: '私钥口令（无则留空）',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(showPwd
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => showPwd = !showPwd),
                          ),
                        ),
                      ),
                    ],
                    if (authType != SshAuthType.key) ...[
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: passCtrl,
                        obscureText: !showPwd,
                        decoration: InputDecoration(
                          labelText: '登录密码',
                          hintText: storedPassword.isEmpty
                              ? '电脑的账号登录密码'
                              : '已保存，留空保持不变',
                          helperText: authType == SshAuthType.keyThenPassword
                              ? '密钥认证失败时自动改用这个密码'
                              : '服务端需允许密码登录（sshd_config：'
                                  'PasswordAuthentication yes）',
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(showPwd
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => showPwd = !showPwd),
                          ),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) &&
                                    storedPassword.isEmpty
                                ? '请填写密码（或改用密钥认证）'
                                : null,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '密码/私钥保存在系统安全存储中，不会明文写进设置文件；'
                      '留空提交表示保持原凭据不变。',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    // 兜底：existing 无稳定 id（旧配置迁移遗漏）→ 分配新 id，避免 upsert 追加。
    final stableId = (cfg?.id.trim().isNotEmpty ?? false)
        ? cfg!.id.trim()
        : 'ssh_${DateTime.now().millisecondsSinceEpoch}';
    final needKey = authType != SshAuthType.password;
    final needPassword = authType != SshAuthType.key;
    final typedPwd = passCtrl.text.trim();
    await notifier.upsertSshConfig(SshConfig(
      id: stableId,
      name: nameCtrl.text.trim(),
      host: hostCtrl.text.trim(),
      port: int.tryParse(portCtrl.text.trim()) ?? 8022,
      username: userCtrl.text.trim(),
      authType: authType,
      privateKeyPem: needKey ? keyCtrl.text.trim() : null,
      keyPassphrase:
          needKey && passPhraseCtrl.text.isNotEmpty ? passPhraseCtrl.text : null,
      // 留空 = 保持安全存储里的原密码（编辑别的字段不该把密码清了）。
      password: needPassword
          ? (typedPwd.isEmpty ? storedPassword : typedPwd)
          : null,
    ));
    if (mounted) setState(() {});
  }

  // ---------------- 工作区（D1 双真源收编后已并入项目） ----------------

  Widget _buildWorkspacesCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    final active = ref.watch(activeProjectProvider);
    final remote = active?.isRemote ?? false;
    final ssh = SshEnvironmentService.instance;
    final bound = (active?.sshConfigId ?? '').trim();
    final connected = !remote ||
        (ssh.isConnected && (bound.isEmpty || ssh.activeConfig?.id == bound));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('📁 工作区（已并入项目）', context),
            Text(
              '双真源收编（v0.0.4）：工作区注册表已降级为项目注册表的派生缓存——'
              '激活哪个项目，智能体就在哪个目录干活；远程项目走 ssh_exec / '
              'ssh_read_file / ssh_write_file 在对方电脑上执行。'
              '新建、切换、连接都在聊天左栏顶部的「项目」面板里。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Icon(
                  remote ? Icons.desktop_windows : Icons.folder_outlined,
                  size: 16,
                  color: remote
                      ? (connected ? Colors.green : Colors.orange)
                      : Colors.grey.shade600),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  active == null
                      ? '正在加载项目…'
                      : '${active.name} · ${active.workspacePath}'
                          '${remote ? (connected ? ' · 已连接' : ' · 未连接') : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ---------------- 任务与规划 ----------------

  /// 任务按激活工作区过滤（默认工作区收编无主任务），新更新的在前。
  Future<void> _reloadDevTasks() async {
    try {
      final dev = DevSessionController.instance;
      await dev.init();
      final all = await DevStore().loadTasks();
      final wsId = dev.activeWorkspaceId;
      all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (!mounted) return;
      setState(() {
        _devTasks = [
          for (final t in all)
            if (taskBelongsToWorkspace(t, wsId)) t,
        ];
        _devTasksLoaded = true;
      });
    } catch (_) {
      if (mounted) _devTasksLoaded = true;
    }
  }

  static const _devTaskStatusLabels = {
    DevTaskStatus.planning: '规划中',
    DevTaskStatus.implementing: '实施中',
    DevTaskStatus.verifying: '验证中',
    DevTaskStatus.done: '已完成',
    DevTaskStatus.blocked: '受阻',
  };

  Widget _buildDevTasksCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    final dev = DevSessionController.instance;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('📋 任务与规划', context),
            Text(
              '规划归属于工作区；点任务行设为当前任务（智能体上下文会注入其计划）。'
              '也可以直接在对话里让智能体 task_create。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            if (!_devTasksLoaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('加载中…', style: TextStyle(fontSize: 12)),
              )
            else if (_devTasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '当前工作区还没有任务',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              )
            else
              for (final t in _devTasks)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (dev.activeTaskId == t.id) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child:
                              const Text('当前', style: TextStyle(fontSize: 10)),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    '${_devTaskStatusLabels[t.status] ?? t.status.name}'
                    '${t.plan != null && t.plan!.steps.isNotEmpty ? ' · 进度 ${t.plan!.steps.where((s) => s.done).length}/${t.plan!.steps.length}' : ''}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '删除任务',
                    onPressed: () => _confirmDeleteDevTask(t),
                  ),
                  onTap: () async {
                    await DevSessionController.instance.setActiveTask(t.id);
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已设为当前任务：${t.title}')));
                    }
                  },
                ),
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: () => _showNewDevTaskDialog(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建规划'),
            ),
          ],
        ),
      ),
    );
  }

  /// 新建规划：标题 + 工作区选择（默认当前激活工作区）。
  Future<void> _showNewDevTaskDialog(BuildContext context) async {
    final dev = DevSessionController.instance;
    final titleCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var workspaceId = dev.activeWorkspaceId;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建规划'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: titleCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '任务标题',
                    hintText: '如：给搜索结果加缓存',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请填写标题' : null,
                ),
                const SizedBox(height: 12),
                const Text('所属工作区',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final ws in dev.workspaces)
                      ChoiceChip(
                        label: Text(ws.name),
                        selected: workspaceId == ws.id,
                        onSelected: (_) => workspaceId = ws.id,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final title = titleCtrl.text.trim();
    if (title.isEmpty) return;
    final task = DevTask(
      id: newDevTaskId(),
      title: title,
      workspaceId: workspaceId == DevWorkspace.kDefaultId ? null : workspaceId,
      status: DevTaskStatus.planning,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await DevStore().saveTask(task);
    await dev.setActiveTask(task.id);
    await _reloadDevTasks();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已创建「$title」并设为当前任务，'
              '对话里可让智能体 plan_create 填步骤')));
    }
  }

  Future<void> _confirmDeleteDevTask(DevTask t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除任务'),
        content: Text('确定删除「${t.title}」？其计划将一并删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await DevStore().deleteTask(t.id);
    if (DevSessionController.instance.activeTaskId == t.id) {
      await DevSessionController.instance.setActiveTask(null);
    }
    await _reloadDevTasks();
  }

  // ---------------- 安全策略 ----------------

  Widget _buildSafetyCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🛡️ 危险命令策略', context),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('拒绝'),
                  selected: settings.dangerousCommandPolicy == 'deny',
                  onSelected: (_) => notifier.setDangerousCommandPolicy('deny'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('每次审批'),
                  selected: settings.dangerousCommandPolicy == 'ask',
                  onSelected: (_) => notifier.setDangerousCommandPolicy('ask'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '拒绝 = 黑名单命令直接拦截（rm -rf /、reboot、git push --force 等）；'
              '每次审批 = 转用户确认。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

class ApiSettingsBody extends ConsumerWidget {
  const ApiSettingsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final apiModels = settings.apiModels;
    final activeId = settings.activeApiModelId;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.cloud_queue,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '本地模型优先：仅当本地模型不可用时，才自动使用下方激活的 API 模型。',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildSectionHeader('已配置的 API 模型', context)),
              FilledButton.icon(
                onPressed: () => _showApiModelDialog(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (apiModels.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child:
                    Text('尚未配置任何 API 模型', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            for (final cfg in apiModels)
              _buildApiModelCard(context, ref, cfg, activeId == cfg.id),
          const SizedBox(height: 20),
          _buildSectionHeader('当前激活', context),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '启用 API 接入',
                    activeId != null,
                    (v) {
                      // 打开时激活当前列表首个可用模型；关闭时停用。
                      ref.read(settingsProvider.notifier).setActiveApiModel(v
                          ? (activeId ??
                              (apiModels.isNotEmpty
                                  ? apiModels.first.id
                                  : null))
                          : null);
                    },
                    subtitle: activeId != null
                        ? '当前激活：${_activeApiName(apiModels, activeId)}'
                        : '未启用 API，聊天仅使用本地模型',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 联网搜索（SearXNG 实例地址等）：与 API 接入同属"外部服务"配置。
          const WebSearchSettingsBody(),
        ],
      ),
    );
  }

  Widget _buildApiModelCard(
      BuildContext context, WidgetRef ref, ApiModelConfig cfg, bool isActive) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud,
                    size: 20, color: isActive ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(cfg.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                if (isActive)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('已激活',
                        style: TextStyle(fontSize: 11, color: Colors.white)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(cfg.baseUrl,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text('模型：${cfg.model}', style: const TextStyle(fontSize: 12)),
            Text(
              'temp=${cfg.effectiveTemperature.toStringAsFixed(2)} · '
              'max_tokens=${cfg.effectiveMaxTokens}'
              '${cfg.contextWindow != null ? ' · 上下文=${cfg.contextWindow}' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: isActive
                      ? OutlinedButton.icon(
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setActiveApiModel(null),
                          icon: const Icon(Icons.power_off, size: 16),
                          label: const Text('停用'),
                        )
                      : FilledButton.icon(
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setActiveApiModel(cfg.id),
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: const Text('激活'),
                        ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  tooltip: '编辑',
                  onPressed: () =>
                      _showApiModelDialog(context, ref, existing: cfg),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '删除',
                  onPressed: () => _confirmDeleteApiModel(context, ref, cfg),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteApiModel(
      BuildContext context, WidgetRef ref, ApiModelConfig cfg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除 API 模型'),
        content: Text('确定删除「${cfg.name}」吗？删除后其密钥一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      ref.read(settingsProvider.notifier).deleteApiModel(cfg.id);
    }
  }

  String? _activeApiName(List<ApiModelConfig> list, String? id) {
    if (id == null) return null;
    for (final cfg in list) {
      if (cfg.id == id) return cfg.name;
    }
    return null;
  }

  void _showApiModelDialog(BuildContext context, WidgetRef ref,
      {ApiModelConfig? existing}) {
    showDialog(
      context: context,
      builder: (_) =>
          _ApiModelDialog(existing: existing, isEditing: existing != null),
    );
  }
}

class _ApiModelDialog extends ConsumerStatefulWidget {
  const _ApiModelDialog({this.existing, required this.isEditing});

  final ApiModelConfig? existing;
  final bool isEditing;

  @override
  ConsumerState<_ApiModelDialog> createState() => _ApiModelDialogState();
}

class _ApiModelDialogState extends ConsumerState<_ApiModelDialog> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _temp;
  late final TextEditingController _maxTokens;
  late final TextEditingController _contextWindow;

  String? _testResult;
  bool _testing = false;
  bool _visionCapable = false;
  // 思考强度（每条 API 配置独立；不干预 = 一个思考字段都不发，与旧版一致）
  ThinkingEffort _thinkingEffort = ThinkingEffort.passthrough;
  // 思考参数族覆盖（null = 按模型名/端点自动探测）
  ThinkingFamily? _thinkingFamily;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _temp =
        TextEditingController(text: e?.temperature?.toStringAsFixed(2) ?? '');
    _maxTokens = TextEditingController(text: e?.maxTokens?.toString() ?? '');
    _contextWindow =
        TextEditingController(text: e?.contextWindow?.toString() ?? '');
    _visionCapable = e?.visionCapable ?? false;
    _thinkingEffort = thinkingEffortFromKey(e?.thinkingEffort);
    _thinkingFamily = thinkingFamilyFromKey(e?.thinkingFamily);
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _temp.dispose();
    _maxTokens.dispose();
    _contextWindow.dispose();
    super.dispose();
  }

  ApiModelConfig? _buildConfig() {
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    if (name.isEmpty || baseUrl.isEmpty || model.isEmpty) return null;
    return ApiModelConfig(
      id: widget.existing?.id ?? Uuid().v4(),
      name: name,
      baseUrl: baseUrl,
      apiKey: _apiKey.text.trim(),
      model: model,
      temperature: double.tryParse(_temp.text.trim()),
      maxTokens: int.tryParse(_maxTokens.text.trim()),
      visionCapable: _visionCapable,
      contextWindow: int.tryParse(_contextWindow.text.trim()),
      thinkingEffort: thinkingEffortToKey(_thinkingEffort),
      thinkingFamily: thinkingFamilyToKey(_thinkingFamily),
    );
  }

  Future<void> _test() async {
    final cfg = _buildConfig();
    if (cfg == null) {
      setState(() => _testResult = '请先填写 名称/baseUrl/模型名');
      return;
    }
    setState(() => _testing = true);
    final err = await ref.read(openAiServiceProvider).testConnection(cfg);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = err == null ? '✅ 连接成功' : '❌ $err';
    });
  }

  Future<void> _save() async {
    final cfg = _buildConfig();
    if (cfg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称 / baseUrl / 模型名 为必填')),
      );
      return;
    }
    final notifier = ref.read(settingsProvider.notifier);
    if (widget.isEditing) {
      await notifier.updateApiModel(cfg);
    } else {
      await notifier.addApiModel(cfg);
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? '编辑 API 模型' : '添加 API 模型'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '显示名称 *')),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: 'Base URL *',
              hintText: 'https://api.openai.com/v1 或 http://127.0.0.1:8080/v1',
            ),
          ),
          TextField(
            controller: _apiKey,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: '可留空（本地服务）',
            ),
            obscureText: true,
          ),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: '模型名 *',
              hintText: 'gpt-4o / qwen2.5-7b-instruct',
            ),
          ),
          TextField(
            controller: _temp,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'temperature（留空=0.7）'),
          ),
          TextField(
            controller: _maxTokens,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'max_tokens（留空=1024）'),
          ),
          TextField(
            controller: _contextWindow,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '上下文窗口（留空=自动探测）',
              hintText: '顶部上下文占用百分比的分母；自动从 /v1/models 读取 n_ctx',
            ),
          ),
          SwitchListTile(
            title: const Text('支持视觉（图片理解）'),
            subtitle: const Text('开启后，带图消息会以 base64 图片发送给该 API'),
            value: _visionCapable,
            onChanged: (v) => setState(() => _visionCapable = v),
          ),
          // ── 思考强度（每条 API 配置独立，避免"全局一个开关配错某些端点"）──
          const SizedBox(height: 4),
          const Text('思考强度（该端点）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          Wrap(
            spacing: 6,
            children: [
              for (final e in ThinkingEffort.values)
                ChoiceChip(
                  label: Text(thinkingEffortLabel(e)),
                  selected: _thinkingEffort == e,
                  onSelected: (_) => setState(() => _thinkingEffort = e),
                ),
            ],
          ),
          Row(
            children: [
              const Text('参数族', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              DropdownButton<ThinkingFamily?>(
                value: _thinkingFamily,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem<ThinkingFamily?>(
                      value: null,
                      child: Text('自动探测', style: TextStyle(fontSize: 12))),
                  for (final f in ThinkingFamily.values)
                    DropdownMenuItem<ThinkingFamily?>(
                      value: f,
                      child: Text(thinkingFamilyLabel(f),
                          style: const TextStyle(fontSize: 12)),
                    ),
                ],
                onChanged: (v) => setState(() => _thinkingFamily = v),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '各家字段不同（reasoning_effort / thinking budget / '
              'chat_template_kwargs…），默认按模型名与端点自动选族；判错时这里手工钉死。'
              '端点不认该字段会自动去掉重发，不会把请求打死。'
              '调「高」= 允许更长思考，请同步把「思考字数上限」调大，否则会被守卫按不思考重试。',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ),
          const SizedBox(height: 12),
          if (_testResult != null)
            Text(
              _testResult!,
              style: TextStyle(
                color: _testResult!.startsWith('✅') ? Colors.green : Colors.red,
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.wifi_tethering, size: 16),
                  label: Text(_testing ? '测试中…' : '测试连接'),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

// =========================================================================
// 联网搜索（SearXNG）配置卡 —— 放在「API 接入」页：与远程 API 同属外部服务配置。
//
// 设计要点：
// - 地址由用户自己的部署决定，App **不预置任何实例**；未填时 web_search 会
//   明确回"未配置地址"的诊断，而不是拿 127.0.0.1 去连手机自己。
// - 「测试连接」用输入框里的**草稿值**直接发一次真实搜索（无需先保存），并把
//   provider 的分类诊断原样显示（HTTP 状态 / 超时 / 实例未开 format=json 等），
//   避免"红条指错方向"。
// =========================================================================

class WebSearchSettingsBody extends ConsumerStatefulWidget {
  const WebSearchSettingsBody();

  @override
  ConsumerState<WebSearchSettingsBody> createState() =>
      WebSearchSettingsBodyState();
}

class WebSearchSettingsBodyState extends ConsumerState<WebSearchSettingsBody> {
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  final _engines = TextEditingController();
  final _language = TextEditingController();
  final _maxResults = TextEditingController();
  final _timeoutSec = TextEditingController();

  /// 各文本框的 FocusNode：用于「离焦即自动保存」，
  /// 解决"填完值没按回车就丢了"的问题。
  final _urlFocus = FocusNode();
  final _apiKeyFocus = FocusNode();
  final _enginesFocus = FocusNode();
  final _languageFocus = FocusNode();
  final _maxResultsFocus = FocusNode();
  final _timeoutSecFocus = FocusNode();

  bool _revealKey = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  /// 提前捕获 notifier（provider 与应用同生命周期）：dispose（离开页面）时
  /// 还要落盘草稿，而那时不能再触碰 ref。
  SettingsNotifier? _liveNotifier;

  @override
  void initState() {
    super.initState();
    _liveNotifier = ref.read(settingsProvider.notifier);
    // 离焦即保存（SDK 3.27 的 TextField 既无 onBlur 也无 onFocusChange，
    // 用 FocusNode 监听实现；仅"由有焦点→失去焦点"时触发一次）。
    final n = _liveNotifier!;
    _saveOnBlur(_urlFocus, () => n.setWebSearchSearXngBaseUrl(_url.text));
    _saveOnBlur(_apiKeyFocus, () => n.setWebSearchSearXngApiKey(_apiKey.text));
    _saveOnBlur(
        _enginesFocus, () => n.setWebSearchSearXngEngines(_engines.text));
    _saveOnBlur(
        _languageFocus, () => n.setWebSearchSearXngLanguage(_language.text));
    _saveOnBlur(_maxResultsFocus, () => _saveMaxResults(_maxResults.text));
    _saveOnBlur(_timeoutSecFocus, () => _saveTimeoutSec(_timeoutSec.text));
  }

  /// 焦点离开 [node] 时执行一次 [save]（不依赖 ref，页面销毁路径也安全）。
  void _saveOnBlur(FocusNode node, void Function() save) {
    var hadFocus = false;
    node.addListener(() {
      if (hadFocus && !node.hasFocus && _liveNotifier != null) save();
      hadFocus = node.hasFocus;
    });
  }

  @override
  void dispose() {
    // 离页兜底保存：离焦保存只覆盖"焦点切换"场景；填完直接返回/切页时
    // 焦点从未离开过输入框，若不在此落盘，值就丢了（"配置不自动保存"的
    // 最后一个口子）。setter 幂等，与离焦保存重复触发无副作用。
    final n = _liveNotifier;
    if (n != null) {
      n.setWebSearchSearXngBaseUrl(_url.text);
      n.setWebSearchSearXngApiKey(_apiKey.text);
      n.setWebSearchSearXngEngines(_engines.text);
      n.setWebSearchSearXngLanguage(_language.text);
      final maxResults = int.tryParse(_maxResults.text.trim());
      if (maxResults != null) n.setWebSearchSearXngMaxResults(maxResults);
      final timeoutSec = int.tryParse(_timeoutSec.text.trim());
      if (timeoutSec != null) {
        n.setWebSearchSearXngTimeoutMs(timeoutSec * 1000);
      }
    }
    _url.dispose();
    _apiKey.dispose();
    _engines.dispose();
    _language.dispose();
    _maxResults.dispose();
    _timeoutSec.dispose();
    _urlFocus.dispose();
    _apiKeyFocus.dispose();
    _enginesFocus.dispose();
    _languageFocus.dispose();
    _maxResultsFocus.dispose();
    _timeoutSecFocus.dispose();
    super.dispose();
  }

  /// 设置是异步加载的：首帧输入框还是空的，等值到位后灌进去一次。
  /// 只灌空字段——绝不覆盖用户正在输入的内容。
  void _seed(TextEditingController c, String value) {
    if (c.text.isEmpty && value.isNotEmpty) c.text = value;
  }

  SettingsNotifier get _notifier => ref.read(settingsProvider.notifier);

  String? get _draftKeyOrNull =>
      _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim();

  /// 用输入框里的当前内容构造一个 provider 并搜索一次"测试"。
  /// 测试前先**保存草稿**（点测试通常代表"我配完了"），避免只点了测试、
  /// 没按回车/没离焦导致值丢失——这正是"配置后不自动保存"的常见场景。
  Future<void> _test() async {
    await _saveAllDrafts();
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final provider = SearXNGSearchProvider(
      baseURL: _url.text.trim(),
      apiKey: _draftKeyOrNull,
      engines: _engines.text.trim().isEmpty ? null : _engines.text.trim(),
      language: _language.text.trim().isEmpty ? null : _language.text.trim(),
      maxResults: int.tryParse(_maxResults.text.trim()) ?? 8,
      timeout: Duration(
          seconds: int.tryParse(_timeoutSec.text.trim()) ??
              (InferenceSettings.kDefaultSearXngTimeoutMs ~/ 1000)),
    );
    final sw = Stopwatch()..start();
    String message;
    bool ok;
    try {
      final result = await provider.search('测试');
      ok = true;
      message = '连接成功：${result.sources.length} 条结果'
          '，用时 ${sw.elapsedMilliseconds} ms'
          '${result.truncated ? '（结果超过上限，已截断）' : ''}';
      if (result.sources.isEmpty) {
        message = '连接成功但 0 条结果（用时 ${sw.elapsedMilliseconds} ms）：'
            '多半是指定的引擎都没结果，清空引擎白名单试试';
      }
    } on WebSearchProviderError catch (e) {
      ok = false;
      message = e.kind == 'WEB_ABORTED'
          ? '${e.message}（已等 ${sw.elapsedMilliseconds} ms）'
          : e.message;
    } catch (e) {
      ok = false;
      message = '搜索失败：$e';
    } finally {
      provider.dispose();
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = ok;
      _testResult = message;
    });
  }

  /// 数字项保存：notifier 会把值夹紧到合法区间，保存后把**真正生效的值**回写输入框，
  /// 避免"填了 300、实际生效 120"这种自己看不出来的偏差。
  Future<void> _saveMaxResults(String v) async {
    final n = _liveNotifier;
    if (n == null) return;
    await n.setWebSearchSearXngMaxResults(
        int.tryParse(v.trim()) ?? n.state.webSearchSearXngMaxResults);
    if (!mounted) return;
    _maxResults.text = '${n.state.webSearchSearXngMaxResults}';
  }

  Future<void> _saveTimeoutSec(String v) async {
    final n = _liveNotifier;
    if (n == null) return;
    final currentSec = n.state.webSearchSearXngTimeoutMs ~/ 1000;
    await n.setWebSearchSearXngTimeoutMs(
        (int.tryParse(v.trim()) ?? currentSec) * 1000);
    if (!mounted) return;
    _timeoutSec.text = '${(n.state.webSearchSearXngTimeoutMs / 1000).round()}';
  }

  /// 顺序保存所有文本框的当前草稿值（测试连接前调用）。
  /// 逐个 await（setter 内部读 state 再写 controller），避免并发竞态。
  /// 每个 setter 都会 _persist（原子写 + 热更新 provider），重复调用幂等。
  Future<void> _saveAllDrafts() async {
    await _notifier.setWebSearchSearXngBaseUrl(_url.text);
    await _notifier.setWebSearchSearXngApiKey(_apiKey.text);
    await _notifier.setWebSearchSearXngEngines(_engines.text);
    await _notifier.setWebSearchSearXngLanguage(_language.text);
    await _saveMaxResults(_maxResults.text);
    await _saveTimeoutSec(_timeoutSec.text);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    _seed(_url, settings.webSearchSearXngBaseUrl);
    _seed(_apiKey, settings.webSearchSearXngApiKey ?? '');
    _seed(_engines, settings.webSearchSearXngEngines ?? '');
    _seed(_language, settings.webSearchSearXngLanguage ?? '');
    _seed(_maxResults, '${settings.webSearchSearXngMaxResults}');
    _seed(
        _timeoutSec, '${(settings.webSearchSearXngTimeoutMs / 1000).round()}');

    final url = _url.text.trim();
    final notConfigured = url.isEmpty;
    // http 明文 + 填了密钥 = Bearer key 明文过网（回环地址除外）。
    final isHttp = url.toLowerCase().startsWith('http://');
    final host = url.isEmpty ? '' : (Uri.tryParse(url)?.host ?? '');
    final isLoopbackHost =
        host == '127.0.0.1' || host == 'localhost' || host == '::1';
    final insecureKey = !notConfigured &&
        isHttp &&
        !isLoopbackHost &&
        _apiKey.text.trim().isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🌐 联网搜索', context),
            const SizedBox(height: 4),
            Text(
              '为智能体提供 web_search 联网搜索。「端侧直连引擎」开关打开时'
              '优先级最高（忽略下方 SearXNG 地址）；关闭后用你的 SearXNG 实例'
              '（需手机能直接访问，局域网 IP 或 Tailscale 地址均可）。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用联网搜索', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                  '开启后模型可用 web_search / get_weather；关闭则这两个工具不可见',
                  style: TextStyle(fontSize: 12)),
              value: settings.webSearchEnabled,
              onChanged: (v) => _notifier.setWebSearchEnabled(v),
            ),
            // ---- SearXNG 实例配置（直连引擎开关打开时优先级更高）----
            const SizedBox(height: 8),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              focusNode: _urlFocus,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'SearXNG 地址',
                hintText: 'http://192.168.1.20:8080',
                helperText: '离焦或按回车自动保存；路径会自动补 /search，只填主机和端口即可',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => _notifier.setWebSearchSearXngBaseUrl(v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKey,
              focusNode: _apiKeyFocus,
              obscureText: !_revealKey,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API Key（可选）',
                helperText: '仅私有实例需要；以 Bearer 发送',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                      _revealKey ? Icons.visibility_off : Icons.visibility,
                      size: 18),
                  onPressed: () => setState(() => _revealKey = !_revealKey),
                ),
              ),
              onSubmitted: (v) => _notifier.setWebSearchSearXngApiKey(v),
            ),
            if (insecureKey) ...[
              const SizedBox(height: 6),
              Text(
                '⚠️ 当前用 http 明文传输，API Key 会明文过网；建议改用 https 或走 Tailscale。',
                style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _engines,
              focusNode: _enginesFocus,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '引擎白名单（可选）',
                hintText: '如 bing,sogou',
                helperText: '留空 = 用实例的全部引擎。实例上若有连不通的引擎，'
                    '搜索会一直等到超时（实测可从 20 秒级降到 2~3 秒）',
                helperMaxLines: 3,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => _notifier.setWebSearchSearXngEngines(v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _language,
              focusNode: _languageFocus,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '搜索语言（可选）',
                hintText: '如 zh-CN，留空 = 不指定',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => _notifier.setWebSearchSearXngLanguage(v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: const Icon(Icons.wifi_tethering, size: 16),
                    label: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                ),
              ],
            ),
            // ---- 条数 / 超时设置 ----
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _maxResults,
                    focusNode: _maxResultsFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '最多条数',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: _saveMaxResults,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _timeoutSec,
                    focusNode: _timeoutSecFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '超时（秒）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: _saveTimeoutSec,
                  ),
                ),
              ],
            ),
            if (notConfigured) ...[
              const SizedBox(height: 6),
              Text(
                '尚未填写地址：联网搜索将使用端侧直连引擎（下方可开关选择）。'
                '填好地址点「测试连接」可改用 SearXNG 实例。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
            if (_testResult != null) ...[
              const SizedBox(height: 8),
              Text(
                '${_testOk ? '✅' : '❌'} $_testResult',
                style: TextStyle(
                  fontSize: 12,
                  color: _testOk ? Colors.green : Colors.red,
                ),
              ),
            ],
            // ---- 端侧直连引擎（SearXNG 地址为空时生效）----
            _buildDirectEngineSection(context, notConfigured, settings),
          ],
        ),
      ),
    );
  }

  /// 端侧直连引擎配置：引擎开关（按风险分档）+ 每 10 分钟窗口请求预算。
  /// 「细水长流」管控：高风险引擎（搜狗/百度/夸克，风控激进）默认每窗口
  /// 发 4 次；预算耗尽自动跳过，窗口到期恢复；引擎被反爬拦截时熔断冷却
  /// 并自动换 Cookie/UA 身份重试（2026-10-02 放宽：次数 2→4、冷却缩短）。
  Widget _buildDirectEngineSection(
      BuildContext context, bool notConfigured, InferenceSettings settings) {
    const engineLabels = {
      'bing_cn': '必应 CN',
      'so360': '360 搜索',
      'chinaso': '中国搜索',
      'sogou': '搜狗（高风险）',
      'baidu': '百度（高风险）',
      'quark': '夸克（高风险）',
    };
    final enabled = settings.webSearchDirectEngines;
    Widget budgetSlider({
      required String label,
      required String hint,
      required int value,
      required int min,
      required int max,
      required ValueChanged<int> onChanged,
    }) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            SizedBox(
              height: 34,
              child: Slider(
                value: value.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: max - min,
                label: '$value 次',
                onChanged: (v) => onChanged(v.round()),
              ),
            ),
            Text(hint,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        );
    final directOn = settings.webSearchDirectEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        _buildSectionHeader('⚡ 端侧直连引擎', context),
        const SizedBox(height: 2),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('端侧直连引擎（优先级最高）', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            directOn ? '已启用：优先用端侧直连，忽略上方 SearXNG 地址' : '已关闭：使用上方配置的 SearXNG 实例',
            style: const TextStyle(fontSize: 12),
          ),
          value: directOn,
          onChanged: (v) => _notifier.setWebSearchDirectEnabled(v),
        ),
        // 总开关关闭时子设置整体置灰不可点（对齐 agentEnabled 的置灰模式）。
        Opacity(
          opacity: directOn ? 1.0 : 0.45,
          child: IgnorePointer(
            ignoring: !directOn,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notConfigured
                      ? '高风险引擎每窗口请求数少、被拦自动冷却换身份，'
                          '保证长期可用。'
                      : '当前被 SearXNG 地址覆盖（直连开关打开才生效）。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 4),
                for (final entry in engineLabels.entries)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title:
                        Text(entry.value, style: const TextStyle(fontSize: 14)),
                    value: enabled.contains(entry.key),
                    onChanged: (v) =>
                        _notifier.setWebSearchDirectEngineEnabled(entry.key, v),
                  ),
                const SizedBox(height: 4),
                budgetSlider(
                  label: '低风险引擎每 10 分钟搜索上限'
                      '（必应/360/中国搜索，当前 ${settings.webSearchDirectLowRiskPerWindow} 次）',
                  hint: '容忍度高，可适当放宽；预算用于控制连续任务的请求节奏',
                  value: settings.webSearchDirectLowRiskPerWindow,
                  min: 1,
                  max: 20,
                  onChanged: (v) =>
                      _notifier.setWebSearchDirectLowRiskPerWindow(v),
                ),
                const SizedBox(height: 4),
                budgetSlider(
                  label: '高风险引擎每 10 分钟搜索上限'
                      '（搜狗/百度/夸克，当前 ${settings.webSearchDirectHighRiskPerWindow} 次）',
                  hint: '风控激进，默认 4 次"细水长流"——偶尔贡献高质量结果，'
                      '避免连续请求被判定机器行为而封禁',
                  value: settings.webSearchDirectHighRiskPerWindow,
                  min: 1,
                  max: 6,
                  onChanged: (v) =>
                      _notifier.setWebSearchDirectHighRiskPerWindow(v),
                ),
                if (enabled.isEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '⚠️ 所有直连引擎均已关闭：端侧直连不可用。',
                    style:
                        TextStyle(fontSize: 12, color: Colors.orange.shade800),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 语音基础配置合体（2026-10-25 从「能力与实验」面板抽出）：
/// 🔊 Edge TTS 播报 + 🎙️ 端侧 ASR 输入。挂在左栏「更多（基础配置）」面板
/// 直陈——这两块是基础配置不是能力扩展，且能力面板里其余小节
/// （原生能力开关=智能体面板、插件/技能=各自面板）全是重复入口，
/// 整个「能力与实验」面板从此不再从左栏可达。
class VoiceSettingsBody extends ConsumerStatefulWidget {
  const VoiceSettingsBody({super.key});

  @override
  ConsumerState<VoiceSettingsBody> createState() => _VoiceSettingsBodyState();
}

class _VoiceSettingsBodyState extends ConsumerState<VoiceSettingsBody> {
  /// Edge TTS 音色列表（null = 拉取中；失败回退内置常用清单）。
  List<TtsVoiceInfo>? _ttsVoices;
  Future<bool>? _asrModelReady;

  @override
  void initState() {
    super.initState();
    _loadTtsVoices();
  }

  Future<void> _loadTtsVoices() async {
    final voices = await EdgeTtsService.instance.listVoices();
    if (!mounted) return;
    setState(() => _ttsVoices = voices);
  }

  static String _signedPct(int v) => '${v >= 0 ? '+' : ''}$v%';
  static String _signedHz(int v) => '${v >= 0 ? '+' : ''}$v Hz';

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // T2.6 失败黄条：任何 TTS 引擎失败留痕（哑火两天无人察觉的事故
        // 制度化防复发）——黄条出现在这里，用户看得见、可排查。
        ValueListenableBuilder<String?>(
          valueListenable: VoiceService.instance.lastSpeakFailure,
          builder: (_, failure, __) => failure == null
              ? const SizedBox.shrink()
              : Material(
                  color: Colors.amber.shade200,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 18, color: Colors.black87),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('朗读失败：$failure',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black87)),
                      ),
                    ]),
                  ),
                ),
        ),
        const SizedBox(height: 6),
        _buildMasterCard(settings, notifier),
        const SizedBox(height: 10),
        _buildTtsCard(settings, notifier),
        const SizedBox(height: 10),
        _buildWakeCard(settings, notifier),
        const SizedBox(height: 10),
        _buildAsrCard(settings, notifier),
      ],
    );
  }

  /// §6 总开关卡：语音交互（关=不占麦不加载零 footprint）+ 引擎选择 +
  /// 自动朗读 + 快速响应。
  Widget _buildMasterCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '🗣️ 语音交互（总开关）',
              settings.voiceEnabled,
              (v) {
                notifier.setVoiceEnabled(v);
                // 总开关关 = 连常驻待命麦也停（产品语义：绝不暗中留麦）
                if (!v) unawaited(VoiceService.instance.stopWakeListening());
              },
              subtitle: '关 = 不占麦克风、不加载模型，零内存占用；'
                  '按住说话 / 唤醒对话 / 自动朗读 / 常驻唤醒全由它门控',
            ),
            const SizedBox(height: 4),
            Opacity(
              opacity: settings.voiceEnabled ? 1.0 : 0.45,
              child: IgnorePointer(
                ignoring: !settings.voiceEnabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // T2.5 引擎选择：离线（matcha/vits，默认）vs 在线 Edge。
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(children: [
                        const Text('朗读引擎',
                            style: TextStyle(fontSize: 13)),
                        const Spacer(),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                                value: 'offline', label: Text('离线')),
                            ButtonSegment(
                                value: 'edge', label: Text('在线 Edge')),
                          ],
                          selected: {settings.voiceTtsEngine},
                          onSelectionChanged: (sel) =>
                              notifier.setVoiceTtsEngine(sel.first),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 2),
                    _buildToggleTitle(
                      '回复后自动朗读',
                      settings.voiceAutoSpeak,
                      notifier.setVoiceAutoSpeak,
                      subtitle: '生成完成自动读出（生效 = 总开关 + 本开关）',
                    ),
                    _buildToggleTitle(
                      '快速响应模式',
                      settings.voiceQuickResponse,
                      notifier.setVoiceQuickResponse,
                      subtitle: '识别/TTS 模型常驻内存预热（约 +400MB 换首次不卡）',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// §6 唤醒对话卡（T2.4）：开关 + D2 自动发送 + 超时时长。
  Widget _buildWakeCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '🔔 唤醒对话',
              settings.voiceWakeEnabled,
              (v) {
                notifier.setVoiceWakeEnabled(v);
                // 关功能 = 绝不留待命麦（KWS 常驻一并停）
                if (!v) unawaited(VoiceService.instance.stopWakeListening());
              },
              subtitle: '说完停顿自动识别上屏（免提对话）；开启下方「语音常驻唤醒」'
                  '后说「汪柴」即可免触发起会话，输入栏 🎙️ 按钮仍可手动',
            ),
            const SizedBox(height: 4),
            Opacity(
              opacity: settings.voiceWakeEnabled ? 1.0 : 0.45,
              child: IgnorePointer(
                ignoring: !settings.voiceWakeEnabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // D2 拍板：自动发送为用户设置项，默认自动。
                    _buildToggleTitle(
                      '定稿后自动发送（3 秒缓冲可取消）',
                      settings.voiceWakeAutoSend,
                      notifier.setVoiceWakeAutoSend,
                      subtitle: '开 = 定稿上屏 3 秒后自动发送；关 = 只上屏，手动发',
                    ),
                    _buildSliderRow(
                      label: '说完停顿多久算说完（毫秒）',
                      value: settings.voiceVadTailSilenceMs,
                      min: 600,
                      max: 1200,
                      divisions: 12,
                      display: '${settings.voiceVadTailSilenceMs} ms',
                      onChanged: notifier.setVoiceVadTailSilenceMs,
                    ),
                    _buildSliderRow(
                      label: '无输入自动结束（秒）',
                      value: settings.voiceWakeNoInputSec,
                      min: 3,
                      max: 30,
                      divisions: 27,
                      display: '${settings.voiceWakeNoInputSec} s',
                      onChanged: notifier.setVoiceWakeNoInputSec,
                    ),
                    _buildSliderRow(
                      label: '单次输入最长（秒）',
                      value: settings.voiceWakeMaxInputSec,
                      min: 5,
                      max: 600,
                      divisions: 119,
                      display: '${settings.voiceWakeMaxInputSec} s',
                      onChanged: notifier.setVoiceWakeMaxInputSec,
                    ),
                    const Divider(height: 20),
                    // M3 常驻唤醒（voice-wakeup-min-spec §4.5 首启向导：
                    // 勾选 → 引导下载 KWS+SenseVoice+VAD → 起待命麦）
                    _buildToggleTitle(
                      '语音常驻唤醒（说「汪柴」免触发起会话）',
                      settings.voiceWakeKws,
                      (v) => _onWakeKwsChanged(notifier, v),
                      subtitle: '开 = 待命麦常驻（实测 CPU ≤5% 单核）；播报/会话期'
                          '自动让麦（防自念自醒）；首次需下载唤醒模型约 12MB',
                    ),
                    Opacity(
                      opacity: settings.voiceWakeKws ? 1.0 : 0.45,
                      child: IgnorePointer(
                        ignoring: !settings.voiceWakeKws,
                        child: _buildSliderRow(
                          label: '唤醒灵敏度',
                          value: (settings.voiceWakeSensitivity * 100).round(),
                          min: 30,
                          max: 90,
                          divisions: 6,
                          display:
                              (settings.voiceWakeSensitivity * 100).round().toString(),
                          hint: '叫不醒调高、误醒调低（松手后自动重载唤醒引擎）',
                          onChanged: (p) {
                            notifier.setVoiceWakeSensitivity(p / 100.0);
                            _restartKwsSoon();
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Timer? _kwsRestartDebounce;

  /// 灵敏度拖动防抖：松手 600ms 后一次性重启待命 KWS（阈值变了才重建 spotter，
  /// 避免拖动过程反复加载模型）。startWakeListening 幂等（内部先停再起）。
  void _restartKwsSoon() {
    _kwsRestartDebounce?.cancel();
    _kwsRestartDebounce = Timer(const Duration(milliseconds: 600), () async {
      final s = ref.read(settingsProvider);
      if (!s.voiceWakeKws) return;
      await VoiceService.instance.startWakeListening(
          threshold: kwsThresholdFromSensitivity(s.voiceWakeSensitivity));
    });
  }

  /// 常驻唤醒开关副作用：开 = 三模型首启向导 + 起待命麦；关 = 停麦。
  Future<void> _onWakeKwsChanged(SettingsNotifier notifier, bool value) async {
    if (!value) {
      await notifier.setVoiceWakeKws(false);
      await VoiceService.instance.stopWakeListening();
      return;
    }
    const _gateIntro = '启用语音常驻唤醒';
    final gates = const [
      (VoiceModels.kws, '首次使用需下载唤醒词检测模型（约 12MB，一次即可）：'),
      (VoiceModels.sensevoice, '唤醒对话还需识别模型（约 240MB，一次即可）：'),
      (VoiceModels.vad, '最后下载语音分段模型（约 1MB）：'),
    ];
    for (final (id, intro) in gates) {
      if (!await AsrModelGate.ensureModelReady(context,
          id: id, title: _gateIntro, intro: intro)) {
        return; // 用户取消/下载失败：不翻开关（幂等，重试无副作用）
      }
    }
    await notifier.setVoiceWakeKws(true);
    final s = ref.read(settingsProvider);
    final ok = await VoiceService.instance.startWakeListening(
        threshold: kwsThresholdFromSensitivity(s.voiceWakeSensitivity));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('常驻唤醒未能启动（麦克风被占或引擎加载失败，详见日志）')));
    }
  }

  Widget _buildTtsCard(InferenceSettings settings, SettingsNotifier notifier) {
    final voices = _ttsVoices;
    final groups = groupTtsVoices(voices ?? kFallbackVoices);
    final tts = EdgeTtsService.instance;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '🔊 语音播报（Edge TTS）',
              settings.edgeTtsEnabled,
              notifier.setEdgeTtsEnabled,
              subtitle: '开 = 回答气泡出现 🔊 播报按钮；需联网（免费在线接口，'
                  '微软侧随时可能调整，失败会静默降级不打断聊天）',
            ),
            const SizedBox(height: 8),
            // 子设置：总开关关闭时置灰。
            Opacity(
              opacity: settings.edgeTtsEnabled ? 1.0 : 0.45,
              child: IgnorePointer(
                ignoring: !settings.edgeTtsEnabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildToggleTitle(
                      '回复后自动播报',
                      settings.edgeTtsAutoSpeak,
                      notifier.setEdgeTtsAutoSpeak,
                    ),
                    const SizedBox(height: 8),
                    // isExpanded=true：方言音色全名很长，不放开会溢出（真机实锤）。
                    DropdownButtonFormField<String>(
                      value: _ttsVoiceInList(voices, settings.edgeTtsVoice),
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: '音色',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: voices == null
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.refresh, size: 18),
                                onPressed: () {
                                  setState(() => _ttsVoices = null);
                                  _loadTtsVoices();
                                },
                              ),
                      ),
                      items: [
                        for (var i = 0; i < groups.length; i++) ...[
                          DropdownMenuItem<String>(
                            enabled: false,
                            value: '◆group$i',
                            child: Text(
                              '── ${groups[i].title} ──',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          for (final v in groups[i].voices)
                            DropdownMenuItem(
                              value: v.shortName,
                              child: Text('${v.localName} · ${v.shortName}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                            ),
                        ],
                      ],
                      onChanged: (v) {
                        if (v != null) notifier.setEdgeTtsVoice(v);
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildSliderRow(
                      label: '语速',
                      value: settings.edgeTtsRate,
                      min: -50,
                      max: 100,
                      divisions: 30,
                      display: _signedPct(settings.edgeTtsRate),
                      onChanged: notifier.setEdgeTtsRate,
                    ),
                    _buildSliderRow(
                      label: '音调',
                      value: settings.edgeTtsPitch,
                      min: -50,
                      max: 50,
                      divisions: 20,
                      display: _signedHz(settings.edgeTtsPitch),
                      onChanged: notifier.setEdgeTtsPitch,
                    ),
                    _buildSliderRow(
                      label: '音量',
                      value: settings.edgeTtsVolume,
                      min: -50,
                      max: 50,
                      divisions: 20,
                      display: _signedPct(settings.edgeTtsVolume),
                      onChanged: notifier.setEdgeTtsVolume,
                    ),
                    const SizedBox(height: 4),
                    // 试听：播报中显示停止。
                    ValueListenableBuilder<String?>(
                      valueListenable: tts.playingKey,
                      builder: (context, playing, _) {
                        final isPreview = playing == 'preview';
                        return OutlinedButton.icon(
                          icon: Icon(
                            isPreview ? Icons.stop : Icons.volume_up,
                            size: 18,
                          ),
                          label: Text(isPreview ? '停止' : '试听'),
                          onPressed: () async {
                            if (isPreview) {
                              await tts.stop();
                              return;
                            }
                            final ok = await tts.speak(
                              // 英文音色读不出中文，试听文本按音色语言选择。
                              settings.edgeTtsVoice.startsWith('en-')
                                  ? 'Hello, this is the TongYi-Lite voice '
                                      'preview. Rate ${_signedPct(settings.edgeTtsRate)}.'
                                  : '你好，这是 TongYi-Lite 的语音播报效果。'
                                      '当前语速${_signedPct(settings.edgeTtsRate)}，'
                                      '音色${settings.edgeTtsVoice}。',
                              key: 'preview',
                              voice: settings.edgeTtsVoice,
                              rate: settings.edgeTtsRate,
                              pitch: settings.edgeTtsPitch,
                              volume: settings.edgeTtsVolume,
                            );
                            if (ok || !mounted) return;
                            final err = tts.lastError;
                            if (err == null) return;
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(SnackBar(
                                content: Text('🔊 试听失败：$err'),
                                duration: const Duration(seconds: 4),
                              ));
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 音色列表里不存在当前设置值（拉取失败/下架）→ 下拉显示空，保存值不动。
  String? _ttsVoiceInList(List<TtsVoiceInfo>? voices, String current) {
    if (voices == null) return current;
    for (final v in voices) {
      if (v.shortName == current) return current;
    }
    return null;
  }

  Widget _buildAsrCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🎙️ 语音输入（端侧识别）', context),
            _buildToggleTitle(
              '增强识别模式',
              settings.asrEnhancedMode,
              notifier.setAsrEnhancedMode,
              subtitle: 'beam search + 热词偏置：识别更准，首字延迟略增'
                  '（默认标准档 = greedy 流式）',
            ),
            const SizedBox(height: 4),
            Text('热词分类（未选 = 全部启用；提升术语识别准确率）',
                style:
                    TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final cat in hotwordCategories)
                  FilterChip(
                    label:
                        Text(cat.name, style: const TextStyle(fontSize: 11)),
                    selected: settings.asrHotwordCategories.isEmpty ||
                        settings.asrHotwordCategories.contains(cat.id),
                    onSelected: (sel) {
                      final current = settings.asrHotwordCategories;
                      // 空 = 全部启用语义：首次取消某个分类时，
                      // 先把其他全部分类写进启用集。
                      List<String> next;
                      if (current.isEmpty) {
                        next = sel
                            ? current
                            : [
                                for (final c in hotwordCategories)
                                  if (c.id != cat.id) c.id
                              ];
                      } else {
                        next = sel
                            ? [...current, cat.id]
                            : current.where((e) => e != cat.id).toList();
                      }
                      notifier.setAsrHotwordCategories(next);
                    },
                  ),
              ],
            ),
            // 词表查看/编辑：逐分类展开看实际热词内容（差量持久化）。
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 4),
              title: Text('热词词表（查看 / 编辑）',
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                  '${hotwordCategories.length} 个分类，共 '
                  '${hotwordCategories.fold<int>(0, (n, c) => n + effectiveCategoryWords(c.id, settings.asrHotwordAdded, settings.asrHotwordRemoved).length)} 个生效词；点分类可增删词',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
              children: [
                for (final cat in hotwordCategories)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title:
                        Text(cat.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                        '${effectiveCategoryWords(cat.id, settings.asrHotwordAdded, settings.asrHotwordRemoved).length} 个词',
                        style: const TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.edit_outlined, size: 16),
                    onTap: () => _editAsrCategoryWords(cat, notifier),
                  ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.edit_note, size: 20),
              title:
                  const Text('自定义热词', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                  settings.asrHotwordCustom.trim().isEmpty
                      ? '每行一个词（人名/产品名等，同音自动校正）'
                      : settings.asrHotwordCustom.trim().split('\n').length
                              .toString() +
                          ' 个词',
                  style: const TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => _editAsrHotwords(notifier),
            ),
            // 模型管理：状态 + 下载/删除
            FutureBuilder<bool>(
              future: _asrModelReady ??= VoiceModelManager.isReady(VoiceModels.streaming),
              builder: (ctx, snap) {
                final ready = snap.data ?? false;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    ready ? Icons.check_circle : Icons.download_outlined,
                    size: 20,
                    color: ready ? Colors.green : Colors.orange,
                  ),
                  title: Text(ready ? '识别模型：已就绪' : '识别模型：未下载',
                      style: const TextStyle(fontSize: 14)),
                  subtitle: const Text(
                      'sherpa-onnx 流式中文模型（约 160MB，'
                      '首次语音时自动下载，支持断点续传）',
                      style: TextStyle(fontSize: 12)),
                  trailing: TextButton(
                    onPressed: () async {
                      if (ready) {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('删除识别模型？'),
                            content: const Text('删除后语音输入不可用，'
                                '再次长按说话会重新下载。'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('删除')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await VoiceModelManager.deleteModel(VoiceModels.streaming);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('识别模型已删除')));
                          }
                        }
                      } else {
                        await AsrModelGate.ensureModelReady(context);
                      }
                      if (context.mounted) {
                        setState(() => _asrModelReady = null);
                      }
                    },
                    child: Text(ready ? '删除' : '下载',
                        style: const TextStyle(fontSize: 12)),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editAsrHotwords(SettingsNotifier notifier) async {
    final ctrl =
        TextEditingController(text: notifier.state.asrHotwordCustom);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义热词'),
        content: TextField(
          controller: ctrl,
          maxLines: 8,
          minLines: 4,
          decoration: const InputDecoration(
            hintText: '每行一个词，例如：\n彤 Yi\nTongYi-Lite\nsherpa',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      await notifier.setAsrHotwordCustom(ctrl.text);
      if (mounted) setState(() {});
    }
  }

  /// 编辑某个热词分类的词表：预填生效词，保存时算差量持久化；「恢复默认」
  /// 清空该分类差量。
  Future<void> _editAsrCategoryWords(
      HotwordCategory cat, SettingsNotifier notifier) async {
    final defaults = defaultCategoryWords(cat.id);
    final effective = effectiveCategoryWords(cat.id,
        notifier.state.asrHotwordAdded, notifier.state.asrHotwordRemoved);
    final ctrl = TextEditingController(text: effective.join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('热词：${cat.name}'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '内置 ${defaults.length} 个词，当前生效 '
                  '${effective.length} 个。一行一个词：新增行 = 加词，'
                  '删掉行 = 从该分类移除。',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 12,
                minLines: 8,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => ctrl.text = defaults.join('\n'),
            child: const Text('恢复默认'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final d = diffCategoryWords(cat.id, ctrl.text.split('\n'));
    await notifier.setAsrHotwordCategoryEdit(cat.id, d.added, d.removed);
    if (mounted) setState(() {});
  }
}
