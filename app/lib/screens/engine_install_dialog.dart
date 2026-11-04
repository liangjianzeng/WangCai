// 「下载引擎」共享弹层（Phase 3c 按需下载 → v0.0.3 用户反馈抽出复用）。
// 两个入口共用：① 模型加载失败后自动弹出（settings_screen）；② 引擎管理页
// 「获取引擎」卡的一键下载按钮（engine_manager_section）。自动开跑官方
// llama.cpp release 下载（进度条 + 镜像兜底 + sha256 白名单校验），成功
// pop(true)，失败给出 重试/放弃。安装目录与镜像由调用方传入（settings）。
import 'package:flutter/material.dart';

import '../platform/local_server_inference.dart';

class EngineInstallDialog extends StatefulWidget {
  const EngineInstallDialog({
    super.key,
    required this.variant,
    this.enginesDir,
    this.mirrors = const [],
    this.introText,
  });

  /// 引擎变体：'cuda' | 'vulkan'（对应 StoreCatalog 白名单）。
  final String variant;
  final String? enginesDir;
  final List<String> mirrors;

  /// 首行说明文案；缺省 = 主动一键下载语境。
  final String? introText;

  @override
  State<EngineInstallDialog> createState() => _EngineInstallDialogState();
}

class _EngineInstallDialogState extends State<EngineInstallDialog> {
  int _received = 0;
  int _total = 0;
  String? _error;
  bool _running = false;

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    setState(() {
      _running = true;
      _error = null;
    });
    final err = await LocalServerInference.instance.installEngine(
      widget.variant,
      enginesDir: widget.enginesDir,
      mirrors: widget.mirrors,
      onProgress: (r, t) {
        if (mounted) setState(() {
          _received = r;
          _total = t;
        });
      },
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _running = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.variant == 'cuda'
        ? 'CUDA（RTX 快速通道）'
        : 'Vulkan（核显/N 卡通用）';
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('下载引擎 · llama.cpp ${widget.variant}',
            style: const TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.introText ??
                  '一键下载官方 llama.cpp $label 运行包（GitHub Release，'
                  'sha256 白名单校验），装好后模型即可绑定或走 Auto 路由。',
                  style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              Text(
                '安装目录：${widget.enginesDir == null || widget.enginesDir!.isEmpty ? '默认（数据区 engines/，可在 设置→推理引擎 更改）' : widget.enginesDir}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Text(_error!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700))
              else ...[
                LinearProgressIndicator(
                  value: _total > 0 ? _received / _total : null,
                  minHeight: 6,
                ),
                const SizedBox(height: 6),
                Text(
                  _total > 0
                      ? '${_mb(_received)} MB / ${_mb(_total)} MB'
                      : (_running ? '连接下载源…' : '准备中…'),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (_error != null) ...[
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('放弃')),
            OutlinedButton(
                onPressed: _running ? null : _start, child: const Text('重试')),
          ] else
            TextButton(
              onPressed: null,
              child: const Text('下载中，请勿关闭…', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
