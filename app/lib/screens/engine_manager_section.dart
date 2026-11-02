// 设置→推理引擎→引擎管理（Windows 专属，设计 §2.3 M1-b；分叉清单 #8）。
// vendored settings_screen 只插一行调用；本文件是 WangCai 新增件。
// 职责：实例列表 / 状态实时 / 停止 / 按上次配置重启 / 日志 tail / 启动命令取证。
// 模型加载入口仍在「模型管理」页（loadModel 会按 manifest 拉起对应实例）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/engine_host.dart';
import '../engine/engine_registry.dart';
import '../engine/engine_status.dart';
import '../engine/llama_server_host.dart';
import '../platform/local_server_inference.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
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
