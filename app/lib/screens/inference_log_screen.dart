// ============================================================
// Inference Log Screen — 推理引擎日志查看页面
// 
// 显示 LLaMA.cpp 的加载进度、运行状态和错误信息
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/model_provider.dart';

class InferenceLogScreen extends ConsumerWidget {
  const InferenceLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modelState = ref.watch(modelManagerProvider);
    final logs = modelState.loadingLogs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('推理引擎日志'),
        centerTitle: true,
        actions: [
          // 一键复制：全量日志拼接换行入剪贴板（排障时贴给开发者/模型）。
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: logs.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: logs.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已复制 ${logs.length} 条日志')),
                    );
                  },
            tooltip: '复制全部日志',
          ),
          // 清空日志：只清展示层列表。此前是空实现按钮；也不要用
          // ref.invalidate(modelManagerProvider) 充当"刷新"——那会把 notifier
          // 重建复位为 idle，让已加载的模型在 UI 上显示成"未加载"。
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => ref.read(modelManagerProvider.notifier).clearLogs(),
            tooltip: '清空日志',
          ),
        ],
      ),
      body: Column(
        children: [
          // ---- Status Bar ----
          _buildStatusBar(modelState),

          const Divider(height: 1),

          // ---- Log List ----
          Expanded(
            child: logs.isEmpty
                ? _buildEmptyState(ref)
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      return _buildLogEntry(logs[index], index);
                    },
                  ),
          ),

          // ---- Quick Actions ----
          if (modelState.phase != ModelLifecyclePhase.loaded && !modelState.isError)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: modelState.modelId != null && !modelState.isLoading
                          ? () async {
                              await ref.read(modelManagerProvider.notifier).loadModel(modelState.modelId!);
                            }
                          : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('重新加载模型'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.terminal, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Text(
            '暂无日志',
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            '点击模型列表里的「加载」后开始显示日志',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Consumer(
            builder: (context, ref, _) {
              final manager = ref.read(modelManagerProvider.notifier);
              return ElevatedButton.icon(
                onPressed: manager.modelId != null && !manager.isLoading
                    ? () async {
                        await manager.loadModel(manager.modelId!);
                      }
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: Text('加载 ${manager.modelName ?? "模型"}'),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(ModelState ms) {
    Color bgColor;
    String statusText;
    
    switch (ms.phase) {
      case ModelLifecyclePhase.idle:
        bgColor = Colors.grey.shade100;
        statusText = '⚪ 未加载';
        break;
      case ModelLifecyclePhase.loading:
        bgColor = Colors.blue.shade50;
        statusText = '🔄 加载中...';
        break;
      case ModelLifecyclePhase.loaded:
        bgColor = Colors.green.shade50;
        statusText = '✅ 已加载';
        break;
      case ModelLifecyclePhase.unloading:
        bgColor = Colors.orange.shade50;
        statusText = '⏳ 卸载中...';
        break;
      case ModelLifecyclePhase.error:
        bgColor = Colors.red.shade50;
        statusText = '❌ 错误';
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: bgColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                statusText,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              if (ms.phase == ModelLifecyclePhase.loading) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (ms.modelName != null && ms.modelName!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '模型: ${ms.modelName}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ],
          if (ms.errorMessage != null && ms.errorMessage!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '错误: ${ms.errorMessage}',
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLogEntry(String log, int index) {
    IconData icon;
    Color color;
    
    if (log.contains('✓') || log.contains('成功')) {
      icon = Icons.check_circle;
      color = Colors.green;
    } else if (log.contains('失败') || log.contains('错误') || log.contains('ERROR')) {
      icon = Icons.error;
      color = Colors.red;
    } else if (log.contains('警告') || log.contains('WARN')) {
      icon = Icons.warning;
      color = Colors.orange;
    } else {
      icon = Icons.terminal;
      color = Colors.blueGrey;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              log,
              style: TextStyle(
                fontSize: 13,
                color: color.withValues(alpha: 0.9),
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
