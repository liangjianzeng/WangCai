// 设置→推理引擎→引擎管理（Windows 专属，设计 §2.3 M1-b；分叉清单 #8）。
// vendored settings_screen 只插一行调用；本文件是 WangCai 新增件。
// 职责：实例列表 / 状态实时 / 停止 / 按上次配置重启 / 日志 tail / 启动命令取证。
// 模型加载入口仍在「模型管理」页（loadModel 会按 manifest 拉起对应实例）。
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/engine_host.dart';
import '../engine/engine_registry.dart';
import '../engine/engine_status.dart';
import '../engine/engine_store.dart';
import '../engine/llama_server_host.dart';
import '../engine/npu_profiles.dart';
import '../platform/local_server_inference.dart';
import '../platform/wangcai_paths.dart';
import '../providers/settings_provider.dart';
import 'engine_install_dialog.dart';

class EngineManagerSection extends ConsumerStatefulWidget {
  const EngineManagerSection({super.key, this.registry});

  /// 注入点（widget 测试用）；默认真网关。
  final Future<EngineRegistry> Function()? registry;

  @override
  ConsumerState<EngineManagerSection> createState() => _EngineManagerSectionState();
}

class _EngineManagerSectionState extends ConsumerState<EngineManagerSection> {
  EngineRegistry? _registry;
  String? _error;
  String _tier = 'auto';
  int _idleMinutes = 0;
  bool _routingLoaded = false;
  final _idleCtl = TextEditingController();

  // 按需下载偏好（Phase 3c）：安装目录 + 镜像前缀（settings 持久化）。
  String? _enginesDir;
  bool _prefsLoaded = false;
  final _mirrorCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _loadRouting();
    _loadPrefs();
  }

  @override
  void dispose() {
    _idleCtl.dispose();
    _mirrorCtl.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      final s = await ref.read(settingsServiceProvider).load();
      if (mounted) {
        setState(() {
          _enginesDir = s.enginesDir;
          _mirrorCtl.text = s.engineMirror ?? '';
          _prefsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _prefsLoaded = true);
    }
  }

  // ── 获取引擎（v0.0.3 用户反馈：一键下载 + 选目录自动识别）──────────────

  bool _scanning = false;
  String? _scanMsg;

  /// 目录里已有现成引擎 → 扫描认领（按目录名推断 cuda/vulkan），写进
  /// engines.json。保留实例已有 defaultConfig（只补 binaryPath + 启用）。
  Future<void> _scanForEngines() async {
    setState(() {
      _scanning = true;
      _scanMsg = null;
    });
    try {
      final reg =
          await (widget.registry ?? LocalServerInference.instance.registry)();
      final root = (_enginesDir == null || _enginesDir!.isEmpty)
          ? EngineStore(WangCaiPaths.enginePaths()).enginesRoot
          : Directory(_enginesDir!);
      final found = EngineStore.discoverEngineExes(root);
      final notes = <String>[];
      for (final e in found.entries) {
        final instId = 'llamacpp-${e.key}';
        final existing = reg.instance(instId);
        if (existing != null) {
          existing.binaryPath = e.value;
          existing.enabled = true;
        } else {
          reg.upsert(EngineInstance(
              id: instId, manifestId: instId, binaryPath: e.value));
        }
        notes.add('${e.key} → ${e.value}');
      }
      if (found.isNotEmpty) await reg.save();
      await _load();
      if (mounted) {
        setState(() => _scanMsg = found.isEmpty
            ? '未发现 llama-server.exe（扫描目录：${root.path}）'
            : '识别到 ${found.length} 个引擎：${notes.join('；')}');
      }
    } catch (e) {
      if (mounted) setState(() => _scanMsg = '扫描失败：$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 一键下载弹层（共享 EngineInstallDialog）：目录/镜像取当前 UI 值，
  /// 成功后刷新实例列表。
  Future<void> _openInstallDialog(String variant) async {
    final s = await ref.read(settingsServiceProvider).load();
    if (!mounted) return;
    final mirrorUi = _mirrorCtl.text.trim();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EngineInstallDialog(
        variant: variant,
        enginesDir: _enginesDir,
        mirrors: mirrorUi.isNotEmpty
            ? [mirrorUi]
            : (s.engineMirror == null ? const [] : [s.engineMirror!]),
      ),
    );
    if (ok == true && mounted) {
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('✅ llama.cpp $variant 已安装，模型绑定该引擎或留空 Auto 即可用')));
      }
    }
  }

  bool _variantInstalled(EngineRegistry reg, String variant) {
    final p = reg.instance('llamacpp-$variant')?.binaryPath;
    return p != null && p.isNotEmpty && File(p).existsSync();
  }

  Future<void> _load() async {
    try {
      final reg = await (widget.registry ??
          LocalServerInference.instance.registry)();
      if (mounted) setState(() => _registry = reg);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadRouting() async {
    try {
      final r = await LocalServerInference.instance.routingSettings();
      if (mounted) {
        setState(() {
          _tier = r.tier;
          _idleMinutes = r.idleMinutes;
          _idleCtl.text = '${r.idleMinutes}';
          _routingLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _routingLoaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('引擎注册表加载失败：$_error',
              style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
        ),
      );
    }
    final reg = _registry;
    if (reg == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🖥️ 引擎管理（Windows）',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '引擎由「模型管理」页加载模型时自动拉起；这里做状态观察、停止与诊断。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            if (_routingLoaded) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Text('路由档位',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                const SizedBox(width: 12),
                Expanded(
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'auto', label: Text('自动')),
                      ButtonSegment(value: 'npu', label: Text('NPU 优先')),
                      ButtonSegment(value: 'speed', label: Text('速度优先')),
                    ],
                    selected: {_tier},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        textStyle: WidgetStatePropertyAll(
                            TextStyle(fontSize: 11))),
                    onSelectionChanged: (s) async {
                      setState(() => _tier = s.first);
                      await LocalServerInference.instance
                          .setRoutingTier(s.first);
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Text('空闲卸载（分钟，0=不卸）',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 64,
                  child: TextField(
                    controller: _idleCtl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                        isDense: true, border: OutlineInputBorder()),
                    onSubmitted: (v) async {
                      final n = int.tryParse(v.trim()) ?? 0;
                      setState(() => _idleMinutes = n < 0 ? 0 : n);
                      await LocalServerInference.instance
                          .setIdleUnloadMinutes(_idleMinutes);
                    },
                  ),
                ),
              ]),
            ],
            if (_prefsLoaded) ...[
              const SizedBox(height: 6),
              Row(children: [
                Text('引擎安装目录',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _enginesDir ?? '默认（数据区 engines/）',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade500),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final dir = await FilePicker.platform
                        .getDirectoryPath(dialogTitle: '选择引擎安装目录');
                    if (dir == null || !mounted) return;
                    setState(() => _enginesDir = dir);
                    await ref
                        .read(settingsProvider.notifier)
                        .setEnginesDir(dir);
                  },
                  child: const Text('更改', style: TextStyle(fontSize: 12)),
                ),
                if (_enginesDir != null)
                  TextButton(
                    onPressed: () async {
                      setState(() => _enginesDir = null);
                      await ref
                          .read(settingsProvider.notifier)
                          .setEnginesDir(null);
                    },
                    child:
                        const Text('恢复默认', style: TextStyle(fontSize: 12)),
                  ),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                Text('下载镜像前缀',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _mirrorCtl,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: '如 https://ghproxy.net/（留空 = GitHub 直连）',
                      hintStyle: TextStyle(fontSize: 11),
                    ),
                    onSubmitted: (v) async {
                      await ref
                          .read(settingsProvider.notifier)
                          .setEngineMirror(v);
                    },
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 8),

            // ---- 获取引擎卡（v0.0.3 用户反馈）：一键下载官方白名单版本 +
            // 扫描识别自选目录里的现成 llama.cpp ----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Text('⬇️ 获取引擎',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      const Spacer(),
                      TextButton(
                        onPressed: _scanning ? null : _scanForEngines,
                        child: Text(_scanning ? '扫描中…' : '扫描识别',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ]),
                    Text(
                      '一键下载官方白名单版本（sha256 校验）；已有现成 llama.cpp？'
                      '把 llama-server.exe 放进安装目录（目录名含 cuda / vulkan '
                      '即可识别），点「扫描识别」。\n'
                      '装好后三步用起来：模型管理页添加 .gguf → 「引擎」选 '
                      'llama.cpp·CUDA/Vulkan（或留空 Auto）→ 加载即跑。'
                      'GPU 引擎不需要任何 OpenVINO 参数；CUDA 需 N 卡 + 新驱动，'
                      '核显/其他卡选 Vulkan。',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600),
                    ),
                    if (_scanMsg != null) ...[
                      const SizedBox(height: 4),
                      Text(_scanMsg!,
                          style: TextStyle(
                              fontSize: 11, color: Colors.teal.shade700)),
                    ],
                    const SizedBox(height: 4),
                    for (final r in StoreCatalog.verified.releases)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(children: [
                          Text(
                              '${r.variant == 'cuda' ? 'CUDA' : 'Vulkan'}'
                              ' · ${r.version}',
                              style: const TextStyle(fontSize: 12)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _variantInstalled(reg, r.variant)
                                  ? (reg
                                          .instance('llamacpp-${r.variant}')
                                          ?.binaryPath ??
                                      '')
                                  : r.assetName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_variantInstalled(reg, r.variant))
                            Text('已安装',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.teal.shade700))
                          else
                            OutlinedButton(
                              onPressed: () => _openInstallDialog(r.variant),
                              child: const Text('一键下载',
                                  style: TextStyle(fontSize: 12)),
                            ),
                        ]),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),
            for (final inst in reg.instances)
              if (reg.manifestOf(inst.id).kind != 'remote')
                _InstanceRow(key: ValueKey(inst.id), registry: reg, instanceId: inst.id)
              else
                _RemoteRow(key: ValueKey(inst.id), instanceId: inst.id),
          ],
        ),
      ),
    );
  }
}

class _InstanceRow extends StatefulWidget {
  const _InstanceRow({super.key, required this.registry, required this.instanceId});
  final EngineRegistry registry;
  final String instanceId;

  @override
  State<_InstanceRow> createState() => _InstanceRowState();
}

class _InstanceRowState extends State<_InstanceRow> {
  EngineStatus _status = const EngineStatus(EnginePhase.stopped);
  StreamSubscription<EngineStatus>? _sub;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _sub?.cancel();
    final host = widget.registry.hostOf(widget.instanceId);
    _status = host.status;
    _sub = host.onStatus.listen((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _confirm(EngineHost host, {required bool restart}) async {
    final cfg = (host is LlamaServerHost) ? host.lastConfig : null;
    if (restart && cfg == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该引擎还没有成功加载过配置，先在模型管理页加载模型')),
        );
      }
      return;
    }
    await host.stop();
    if (restart && cfg != null) await host.start(cfg);
  }

  @override
  Widget build(BuildContext context) {
    final manifest = widget.registry.manifestOf(widget.instanceId);
    final inst = widget.registry.instance(widget.instanceId)!;
    final host = widget.registry.hostOf(widget.instanceId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${manifest.display}${inst.enabled ? '' : '（未启用）'}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              _PhaseChip(status: _status),
            ],
          ),
          if (_status.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(_status.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.red.shade600)),
            ),
          if (host.baseUrl != null)
            Text(host.baseUrl!,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          _NpuInfoLine(inst: inst, host: host),
          Row(
            children: [
              TextButton(
                onPressed: _status.isUsable || _status.isStarting
                    ? () => _confirm(host, restart: false)
                    : null,
                child: const Text('停止', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: _status.phase == EnginePhase.stopped ||
                        _status.phase == EnginePhase.error
                    ? () => _confirm(host, restart: true)
                    : null,
                child: const Text('按上次配置重启', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: () => _showLogs(context, host),
                child: const Text('日志', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                // 默认启动参数（Phase 3 参数体系中间档）：模型不配
                // customArgs 时，本配置赢过 manifest 出厂 preset。
                onPressed: () => _showDefaults(context, inst),
                child: Text(
                  inst.defaultConfig == null
                      ? '默认参数'
                      : '默认参数 ✓',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (host is LlamaServerHost)
                TextButton(
                  onPressed: () => _showLaunchCmd(context, host),
                  child: const Text('启动命令', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const Divider(height: 16),
        ],
      ),
    );
  }

  void _showLogs(BuildContext context, EngineHost host) {
    showDialog<void>(
      context: context,
      builder: (_) => _LogDialog(host: host),
    );
  }

  /// 「默认启动参数」编辑卡（Phase 3）：保存进 engines.json 的
  /// EngineInstance.defaultConfig。空字段 = 未表态，让位 manifest 出厂 preset；
  /// 模型级 customArgs/ctx/chunk/gpuLayers 仍压过这里（优先级链顶层）。
  void _showDefaults(BuildContext context, EngineInstance inst) {
    showDialog<void>(
      context: context,
      builder: (_) => _EngineDefaultsDialog(registry: widget.registry, instance: inst),
    ).then((_) {
      if (mounted) setState(() {}); // 刷新「默认参数 ✓」标记
    });
  }

  void _showLaunchCmd(BuildContext context, LlamaServerHost host) {
    final args = host.lastSpawnArgs;
    final env = host.lastSpawnEnv;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('启动命令', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 560,
          child: SelectableText(
            args == null
                ? '(本次会话尚未启动过)\n可执行文件: ${host.binaryPath}'
                : '${host.binaryPath} ${args.join(' ')}\n\n'
                    'GGML env:\n${(env?.entries.where((e) => e.key.toUpperCase().startsWith('GGML_')) ?? <MapEntry<String, String>>[]).map((e) => '${e.key}=${e.value}').join('\n')}',
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }
}

/// NPU 世代行（世代自适应 2026-11-05）：探测到的 NPU 型号/世代/`-dev` 档位/
/// 驱动版本。数据优先取 engines.json 持久化摘要（重启后仍在），回落 host
/// 进程内探测缓存；无数据（非 NPU 引擎/从未探测成功）不占位。
class _NpuInfoLine extends StatelessWidget {
  const _NpuInfoLine({required this.inst, required this.host});
  final EngineInstance inst;
  final EngineHost host;

  static const _shortGen = <NpuGeneration, String>{
    NpuGeneration.ultra1: '一代',
    NpuGeneration.ultra2: '二代',
    NpuGeneration.ultra3: '三代',
    NpuGeneration.unknown: '未识别 · 按一代保守基线',
  };

  @override
  Widget build(BuildContext context) {
    final h = host; // 局部提升：public final 字段不做类型促升
    // 复查 2026-11-06：只在实例最近配置**指向 NPU** 时展示 —— lastNpuInfo
    // 没有清除时点，切 CPU/GPU 加载后旧行会误导排障（NPU 意图 = 显式 'NPU'
    // 或直写 'OPENVINO3'；'OPENVINO0/1/2' 与 CPU/GPU 一律算非 NPU 指向）。
    final dev = inst.lastConfig?.device?.toUpperCase();
    final nonNpu = dev == 'CPU' ||
        dev == 'GPU' ||
        (dev?.startsWith('GPU.') ?? false) ||
        dev == 'OPENVINO0' ||
        dev == 'OPENVINO1' ||
        dev == 'OPENVINO2';
    if (nonNpu) return const SizedBox.shrink();
    final summary = inst.lastNpuInfo ??
        (h is LlamaServerHost ? h.lastNpuInfo?.toSummary() : null);
    if (summary == null) return const SizedBox.shrink();
    final gen = NpuGeneration.values.firstWhere(
      (g) => g.name == summary['generation'],
      orElse: () => NpuGeneration.unknown,
    );
    final parts = <String>[
      'NPU: ${summary['name'] ?? '未识别设备'}',
      _shortGen[gen]!,
      '-dev ${summary['devArg'] ?? '?'}',
      if (summary['driver'] != null) '驱动 ${summary['driver']}',
    ];
    final note = profileFor(gen).driverNote;
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        parts.join(' · ') + (note != null ? '\n$note' : ''),
        style: TextStyle(
            fontSize: 11,
            color: gen == NpuGeneration.ultra3
                ? Colors.orange.shade700
                : Colors.grey.shade500),
      ),
    );
  }
}

class _RemoteRow extends StatelessWidget {
  const _RemoteRow({super.key, required this.instanceId});
  final String instanceId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text('$instanceId（远端 OpenAI · M2 接入配置界面）',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
    );
  }
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.status});
  final EngineStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status.phase) {
      EnginePhase.ready => ('运行中', Colors.green),
      EnginePhase.launching => ('启动中', Colors.orange),
      EnginePhase.compiling => ('编译图…', Colors.deepOrange),
      EnginePhase.warming => ('预热中', Colors.orange),
      EnginePhase.draining => ('停止中', Colors.blueGrey),
      EnginePhase.error => ('异常', Colors.red),
      EnginePhase.stopped => ('已停止', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
    );
  }
}

/// 引擎默认启动参数编辑卡（v0.0.3 Phase 3 参数体系）。
/// 落盘目标 = EngineInstance.defaultConfig（engines.json）；参与路由/加载的
/// 优先级链：**模型 customArgs/覆盖项 > 本卡 > manifest preset**。
/// 空字段 = 未表态（让位 preset），与「填 0」区分开。
class _EngineDefaultsDialog extends StatefulWidget {
  const _EngineDefaultsDialog({required this.registry, required this.instance});
  final EngineRegistry registry;
  final EngineInstance instance;

  @override
  State<_EngineDefaultsDialog> createState() => _EngineDefaultsDialogState();
}

class _EngineDefaultsDialogState extends State<_EngineDefaultsDialog> {
  late final TextEditingController _ctx;
  late final TextEditingController _chunk;
  late final TextEditingController _gpuLayers;
  late final TextEditingController _device;
  late final TextEditingController _env;
  late final TextEditingController _args;
  String? _error;

  @override
  void initState() {
    super.initState();
    final d = widget.instance.defaultConfig;
    String? n(int? v) => v == null ? '' : '$v';
    _ctx = TextEditingController(text: n(d?.ctx));
    _chunk = TextEditingController(text: n(d?.chunk));
    _gpuLayers = TextEditingController(text: n(d?.gpuLayers));
    _device = TextEditingController(text: d?.device ?? '');
    _env = TextEditingController(
        text: (d?.extraEnv ?? const <String, String>{})
            .entries
            .map((e) => '${e.key}=${e.value}')
            .join('\n'));
    _args = TextEditingController(text: (d?.args ?? const <String>[]).join(' '));
  }

  @override
  void dispose() {
    for (final c in [_ctx, _chunk, _gpuLayers, _device, _env, _args]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _parseInt(TextEditingController c, String label) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    final v = int.tryParse(t);
    if (v == null || v <= 0) {
      setState(() => _error = '$label 需为正整数（留空 = 跟随出厂预设）');
      throw const _DefaultsInputError();
    }
    return v;
  }

  Future<void> _save() async {
    try {
      final ctx = _parseInt(_ctx, 'ctx');
      final chunk = _parseInt(_chunk, 'chunk');
      final gpuLayers = _parseInt(_gpuLayers, '-ngl');
      final env = <String, String>{};
      for (final line in _env.text.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final i = t.indexOf('=');
        if (i <= 0) {
          setState(() => _error = '附加环境变量需 KEY=VALUE 每行一条：「$t」');
          throw const _DefaultsInputError();
        }
        env[t.substring(0, i).trim()] = t.substring(i + 1).trim();
      }
      final args = _args.text
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
      final d = EngineDefaults(
        ctx: ctx,
        chunk: chunk,
        gpuLayers: gpuLayers,
        device: _device.text.trim().isEmpty ? null : _device.text.trim(),
        extraEnv: env,
        args: args,
      );
      widget.instance.defaultConfig = d.isEmpty ? null : d;
      await widget.registry.save();
      if (mounted) Navigator.pop(context);
    } on _DefaultsInputError {
      // 错误文案已进 _error，留在弹层里
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = widget.registry.manifestOf(widget.instance.id);
    final presetHint = manifest.presets.isEmpty
        ? '无出厂 preset（全走 argsTemplate 模板）'
        : '出厂 preset：${manifest.presets.map((p) => p.name).join(' / ')}';
    Widget field(TextEditingController c, String label, String hint,
        {bool numeric = false, int maxLines = 1}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: c,
          keyboardType: numeric ? TextInputType.number : null,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: label,
            hintText: hint,
            labelStyle: const TextStyle(fontSize: 12),
            hintStyle: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
          ),
        ),
      );
    }

    return AlertDialog(
      title: Text('${manifest.display} · 默认启动参数',
          style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '未配置模型自定义参数时，这里赢过出厂预设（$presetHint）。'
                '留空 = 跟随预设；模型管理页的模型级参数再压过这里。',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 10),
              // chunk/device 是 OpenVINO 引擎专属，-ngl 是 llama.cpp GPU 专属；
              // 给错引擎显示对方的概念就是"配置看不懂"的来源（v0.0.3 反馈）。
              Row(children: [
                Expanded(child: field(_ctx, '上下文 -c', '跟随预设', numeric: true)),
                if (manifest.id == 'wangcai-npu') ...[
                  const SizedBox(width: 8),
                  Expanded(child: field(_chunk, 'chunk', '跟随预设', numeric: true)),
                ],
                if (manifest.id.startsWith('llamacpp-')) ...[
                  const SizedBox(width: 8),
                  Expanded(child: field(_gpuLayers, 'GPU 层数 -ngl', '跟随预设', numeric: true)),
                ],
              ]),
              if (manifest.id == 'wangcai-npu')
                field(_device, '设备 device', 'NPU / CPU / GPU / OPENVINO{n}（OV 引擎）'),
              field(_env, '附加环境变量', '每行 KEY=VALUE（如 GGML_OPENVINO_PREFILL_CHUNK_SIZE=128）',
                  maxLines: 3),
              field(_args, '自定义尾参', '追加在模板之后，如 --flash_attn 1（后者覆盖前者）',
                  maxLines: 2),
              if (_error != null)
                Text(_error!, style: TextStyle(fontSize: 11, color: Colors.red.shade600)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
              textStyle: const TextStyle(fontSize: 12),
              visualDensity: VisualDensity.compact),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _DefaultsInputError implements Exception {
  const _DefaultsInputError();
}

/// 实时引擎日志对话框：历史 tail + 订阅增量（关闭即取消订阅）。
class _LogDialog extends StatefulWidget {
  const _LogDialog({required this.host});
  final EngineHost host;

  @override
  State<_LogDialog> createState() => _LogDialogState();
}

class _LogDialogState extends State<_LogDialog> {
  late final List<String> _lines;
  StreamSubscription<EngineLogLine>? _sub;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final hist = widget.host is LlamaServerHost
        ? (widget.host as LlamaServerHost)
            .logHistory
            .map((l) => l.text)
            .toList(growable: true)
        : <String>[];
    _lines = hist.isEmpty ? <String>['(暂无日志)'] : hist;
    _sub = widget.host.logs.listen((l) {
      if (!mounted) return;
      setState(() {
        if (_lines.length == 1 && _lines.first == '(暂无日志)') {
          _lines[0] = l.text;
        } else {
          _lines.add(l.text);
          if (_lines.length > 2000) _lines.removeAt(0);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('引擎日志', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 640,
        height: 420,
        child: SelectionArea(
          child: ListView.builder(
            controller: _scroll,
            itemCount: _lines.length,
            itemBuilder: (_, i) => Text(
              _lines[i],
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}
