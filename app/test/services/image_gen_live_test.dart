// ImageGenService 真机联调（本机 Win 端，Unsloth Studio :8888）。
//
// 门控（真机测试三重门纪律，同 m2_dod/app_npu_flow）：服务不可达或 key
// 文件缺失 → 跳过（CI/无服务环境全绿不假败）。打到的是**真实生产代码**
// （ImageGenService.generate 全链路：配置→队列→HTTP→b64 解码→落盘），
// 仅 path_provider 经 docsDirOverride 落到临时目录（不污染用户文档区）。
//
// 跑法：flutter test test/services/image_gen_live_test.dart
// （Unsloth 应用开着才有意义；512² 实测 ~10-30s。）
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/services/image_gen_service.dart';

const String kLiveBaseUrl = 'http://127.0.0.1:8888';
const String kLiveKeyFile = r'E:\Unsloth\api-key.json';

Future<String?> _loadLiveKey() async {
  final f = File(kLiveKeyFile);
  if (!f.existsSync()) return null;
  try {
    final dynamic j = jsonDecode(f.readAsStringSync().replaceFirst('\uFEFF', ''));
    final k = j is Map ? j['key'] : null;
    return k is String && k.isNotEmpty ? k : null;
  } catch (_) {
    return null;
  }
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('imggen_live');
    ImageGenService.docsDirOverride = () async => tmp;
  });
  tearDownAll(() async {
    ImageGenService.docsDirOverride = null;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('[真机] health + /v1/models 全绿', () async {
    final key = await _loadLiveKey();
    if (key == null) {
      // ignore: avoid_print
      print('SKIP: $kLiveKeyFile 不存在（Unsloth 未部署/未配 key）');
      return;
    }
    const cfg = ImageGenConfig(
        enabled: true,
        baseUrl: kLiveBaseUrl,
        model: 'E:/Unsloth/models',
        apiKey: 'placeholder');
    final health = await ImageGenService.instance
        .checkHealth(ImageGenConfig(
            enabled: true,
            baseUrl: kLiveBaseUrl,
            model: 'E:/Unsloth/models',
            apiKey: key));
    if (!health.ok) {
      // ignore: avoid_print
      print('SKIP: 服务不可达/鉴权失败：${health.message}');
      return;
    }
    expect(health.reachable, isTrue);
    expect(health.authorized, isTrue);
    expect(cfg.effectiveBaseUrl, kLiveBaseUrl);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('[真机] generate 512² 真实出图（PNG 落盘 + genMeta 契约）', () async {
    final key = await _loadLiveKey();
    if (key == null) {
      // ignore: avoid_print
      print('SKIP: $kLiveKeyFile 不存在');
      return;
    }
    final cfg = ImageGenConfig(
        enabled: true,
        baseUrl: kLiveBaseUrl,
        model: 'E:/Unsloth/models',
        defaultSize: '512x512',
        apiKey: key);
    // 先探服务：不可达就跳过（不假败）。
    final health = await ImageGenService.instance.checkHealth(cfg);
    if (!health.ok) {
      // ignore: avoid_print
      print('SKIP: ${health.message}');
      return;
    }

    const prompt = 'a shiba inu wearing a red scarf, watercolor style';
    final sw = Stopwatch()..start();
    final r = await ImageGenService.instance.generate(
        config: cfg, prompt: prompt, seed: 20261110);
    sw.stop();

    // 落盘断言（真实字节，PNG 魔数）。
    expect(r.paths, hasLength(1));
    final f = File(r.paths.first);
    expect(f.existsSync(), isTrue);
    final bytes = f.readAsBytesSync();
    expect(bytes.length, greaterThan(10000), reason: '512² PNG 不该只有几个字节');
    // PNG magic: 89 50 4E 47 0D 0A 1A 0A
    expect(bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    // 落盘布局：imagegen/YYYYMMDD/img-<ts>-<seed>_1.png。
    expect(r.paths.first.replaceAll('\\', '/'), contains('imagegen/'));
    expect(r.paths.first, contains('20261110'));
    // 溯源契约（genMeta 单真源）。
    final meta = r.metaJson(prompt, cfg.model);
    expect(meta['seed'], 20261110);
    expect(meta['size'], '512x512');
    expect(meta['model'], 'E:/Unsloth/models');
    // ignore: avoid_print
    print('LIVE OK: ${r.paths.first} '
        '(${r.size}, seed ${r.seed}, ${(r.ms / 1000).toStringAsFixed(1)}s, '
        '${bytes.length} bytes, wall=${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)');
  }, timeout: const Timeout(Duration(seconds: 150)));
}
