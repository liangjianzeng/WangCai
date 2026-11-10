// 设置 → API 接入 → 图像生成（Unsloth Studio）。vendored settings_screen
// 只插一行调用；本文件是 WangCai 新增件（engine_manager_section 同款惯例，
// 大节独立成文件，settings_screen 3000+ 行不再增肥）。
// 职责：启用开关 / 服务地址 / 模型名 / 默认尺寸 / API key（安全存储）/
// 测试连接（health 免鉴权测可达 + /v1/models 测 key，缺一不可——health
// 测不出 401）。生图链路本体见 services/image_gen_service.dart。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_provider.dart';
import '../services/api_key_store.dart' show apiKeyStore;
import '../services/image_gen_service.dart';
import '../services/settings_service.dart' show InferenceSettings;

class ImageGenSection extends ConsumerStatefulWidget {
  const ImageGenSection({super.key});

  @override
  ConsumerState<ImageGenSection> createState() => _ImageGenSectionState();
}

class _ImageGenSectionState extends ConsumerState<ImageGenSection> {
  final _urlCtl = TextEditingController();
  final _modelCtl = TextEditingController();
  final _keyCtl = TextEditingController();
  bool _loadedKey = false;
  bool _testing = false;
  ImageGenHealth? _health;
  Timer? _debounce;

  /// 「测试连接」拉到的服务端模型 id（模型名下拉数据源）。
  List<String> _models = const [];

  InferenceSettings get _settings => ref.read(settingsProvider);
  SettingsNotifier get _notifier => ref.read(settingsProvider.notifier);

  @override
  void dispose() {
    _urlCtl.dispose();
    _modelCtl.dispose();
    _keyCtl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadKeyIfNeeded() async {
    if (_loadedKey) return;
    _loadedKey = true;
    try {
      final k = await apiKeyStore.read(kImageGenApiKeyId);
      if (mounted && k != null && k.isNotEmpty) {
        setState(() => _keyCtl.text = k);
      }
    } catch (_) {
      // 安全存储不可用（fail-open 口径）：留空，用户重填即可。
    }
  }

  void _saveUrlDebounced(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _notifier.setImageGenBaseUrl(v);
    });
  }

  Future<void> _saveKey() async {
    final k = _keyCtl.text.trim();
    try {
      if (k.isEmpty) {
        await apiKeyStore.delete(kImageGenApiKeyId);
      } else {
        await apiKeyStore.write(kImageGenApiKeyId, k);
      }
    } catch (_) {
      // fail-open：安全存储不可用时不阻塞 UI（连接照旧可用口径）。
    }
  }

  Future<void> _testConnection() async {
    final cfg = _config();
    setState(() {
      _testing = true;
      _health = null;
    });
    final h = await ImageGenService.instance.checkHealth(cfg);
    if (mounted) {
      setState(() {
        _testing = false;
        _health = h;
        if (h.models.isNotEmpty) _models = h.models;
      });
    }
  }

  ImageGenConfig _config() {
    final s = _settings;
    return ImageGenConfig(
      enabled: s.imageGenEnabled,
      baseUrl: s.imageGenBaseUrl,
      model: s.imageGenModel,
      defaultSize: s.imageGenDefaultSize,
      apiKey: _keyCtl.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    _loadKeyIfNeeded();
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final health = _health;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🎨 图像生成', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '接 Unsloth Studio（Qwen-Image-2.1-Turbo，OpenAI 兼容接口）。'
              '开启后聊天区可用 🎨 或「/图 提示词」直接出图；智能体模式获得'
              ' generate_image 工具。Windows 默认连本机 127.0.0.1:8888；'
              '其他设备手填局域网地址（服务端需开启 LAN + 防火墙放行 8888）。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用图像生成', style: TextStyle(fontSize: 14)),
              subtitle: const Text('关闭后入口隐藏、工具不注册（模型看不见）',
                  style: TextStyle(fontSize: 12)),
              value: settings.imageGenEnabled,
              onChanged: (v) => _notifier.setImageGenEnabled(v),
            ),
            TextField(
              controller: _urlCtl
                ..text = settings.imageGenBaseUrl,
              decoration: const InputDecoration(
                labelText: '服务地址',
                hintText:
                    '本机 http://127.0.0.1:8888 · 局域网 http://192.168.x.x:8888 · '
                    '远程 http://<主机>.tailnet.ts.net:8888（tailnet 内走 http 即加密）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: _saveUrlDebounced,
            ),
            const SizedBox(height: 8),
            // 模型名（2026-11-10 用户点单）：测试连接成功后是下拉选项（含
            // 「服务端缺省」空选），不要求人手填服务端注册名；没测过连接
            // 才退回手填（并注明可留空）。
            if (_models.isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey('imgmodel_${_models.join("|")}'),
                value: (_settings.imageGenModel.isEmpty ||
                        _models.contains(_settings.imageGenModel))
                    ? _settings.imageGenModel
                    : '',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '模型',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                      value: '',
                      child: Text('（服务端缺省模型）',
                          style: TextStyle(fontSize: 13))),
                  for (final m in _models)
                    DropdownMenuItem(
                        value: m,
                        child: Text(m,
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => _notifier.setImageGenModel(v ?? ''),
              )
            else
              TextField(
                controller: _modelCtl..text = _settings.imageGenModel,
                decoration: const InputDecoration(
                  labelText: '模型名（可留空 = 服务端缺省；点「测试连接」可拉列表选）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (v) => _notifier.setImageGenModel(v),
              ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: kImageGenSizes.contains(settings.imageGenDefaultSize)
                  ? settings.imageGenDefaultSize
                  : '1024x1024',
              decoration: const InputDecoration(
                labelText: '默认尺寸',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final s in kImageGenSizes)
                  DropdownMenuItem(
                      value: s, child: Text(s, style: const TextStyle(fontSize: 13))),
              ],
              onChanged: (v) {
                if (v != null) _notifier.setImageGenDefaultSize(v);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _keyCtl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API key（存安全存储，不落设置文件）',
                hintText: 'sk-unsloth-…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
              onSubmitted: (_) => _saveKey(),
              onChanged: (_) => _saveKey(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.network_check, size: 18),
                  label: const Text('测试连接'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _statusText(health),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: health == null
                          ? Colors.grey.shade600
                          : (health.ok
                              ? Colors.green.shade700
                              : theme.colorScheme.error),
                    ),
                  ),
                ),
              ],
            ),
            if (settings.imageGenEnabled &&
                health != null &&
                health.reachable &&
                !health.authorized)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '⚠️ 服务可达但密钥无效：生图会报 401。请核对 Unsloth 侧 key'
                  '（服务端 api-key.json）。',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _statusText(ImageGenHealth? h) {
    if (_testing) return '正在测试…';
    if (h == null) return '未测试';
    return h.message;
  }
}
