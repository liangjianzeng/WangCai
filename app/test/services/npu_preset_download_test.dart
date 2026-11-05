import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/engine/bundled_manifests.dart';
import 'package:wangcai/models/local_model.dart';
import 'package:wangcai/models/model_info.dart';

// ---------------------------------------------------------------------------
// NPU 预置下载链路守门（2026-11-05）：模型管理页 NPU 预置区的「下载」按钮
// 由 catalog 条目映射而来 —— catalog id 直接决定 DownloadService 的落盘名
// `{id}.gguf`，命名/镜像/哈希一漂移就会出现「下完扫不到」「校验永不过」。
// 本测试是 assets/models_catalog.json ↔ bundled wangcai-npu manifest 的
// 对齐契约，改任一侧都必须先过这里。地址均为 2026-11-05 实弹验证过的
// 魔搭（resolve/master）与 hf-mirror（resolve/main）双镜像。
// ---------------------------------------------------------------------------

List<ModelConfig> _catalogFromAsset() {
  final f = File('assets/models_catalog.json'); // flutter test cwd = app/
  if (!f.existsSync()) {
    throw StateError('找不到 ${f.absolute.path} —— 须在 app/ 目录下跑 flutter test');
  }
  final data =
      jsonDecode(f.readAsStringSync(encoding: utf8)) as Map<String, dynamic>;
  return ((data['models'] as List).cast<Map<String, dynamic>>())
      .map(ModelConfig.fromJson)
      .toList();
}

void main() {
  final catalog = _catalogFromAsset();
  final npu = bundledManifests()['wangcai-npu']!;

  ModelConfig? entryOf(String presetName) => downloadEntryForNpuGlob(
      npu.presetByName(presetName)?.modelGlob, catalog);

  test('NPU 主打预置都有映射下载条目（id/大小与磁盘实况对齐）', () {
    final lfm3 = entryOf('lfm3-1.7b');
    expect(lfm3, isNotNull);
    expect(lfm3!.id, 'LFM3-1.7B-Q4_K_M');
    // ModelScope API 回报的精确字节数（也是本机已下文件的大小）。
    expect(lfm3.sizeBytes, 1099627808);
    // deep 预设共用同一份 gguf（同 glob），映射必须落到同一条目。
    expect(entryOf('lfm3-1.7b-deep')?.id, lfm3.id);

    final minicpm = entryOf('minicpm5-2b');
    expect(minicpm?.id, 'minicpm5-2b-q4_k_m'); // 双档取最小（非 q8_0）
    expect(minicpm!.sizeBytes, 1561318368);

    expect(entryOf('spark-x2.6-4b')?.id, 'spark-x2.6-4b-q4_k_m');

    final omni = entryOf('lfm3-omni-2b');
    expect(omni?.id, 'LFM3-Omni-2B-Q4_0');
    expect(omni!.mmproj, isNotNull); // 视觉塔两文件形态
    expect(omni.mmproj!.sizeBytes, 270576544);

    // catalog 无条目的预置（qwen3-4b）→ null，UI 保留手动放文件指引。
    expect(entryOf('qwen3-4b'), isNull);
  });

  test('映射条目满足下载契约：落盘名命中 glob + 三镜像 + 真 sha256', () {
    for (final name in ['lfm3-1.7b', 'lfm3-1.7b-deep', 'minicpm5-2b',
        'spark-x2.6-4b', 'lfm3-omni-2b']) {
      final preset = npu.presetByName(name)!;
      final e = entryOf(name)!;
      // 落盘名 = DownloadService 命名规则 `{id}.gguf`，必须能被预置扫到。
      expect(presetGlobToRegExp(preset.modelGlob!).hasMatch('${e.id}.gguf'),
          isTrue,
          reason: '$name：{${e.id}.gguf} 不在 glob ${preset.modelGlob} 射程内');
      expect(e.mirrors.length, greaterThanOrEqualTo(2),
          reason: '$name：镜像不足');
      expect(e.mirrors.first.source, 'modelscope',
          reason: '$name：首选镜像应是魔搭（网络现实）');
      for (final m in e.mirrors) {
        expect(m.url, startsWith('https://'));
        // 魔搭分支用 master，hf 系分支用 main —— 写错就是 404。
        expect(
            m.url,
            contains(m.source == 'modelscope'
                ? '/resolve/master/'
                : '/resolve/main/'),
            reason: '${m.url}');
      }
      expect(e.sha256Hash, isNotNull, reason: '$name：sha256 缺失 = 裸下载');
      expect(e.sha256Hash!.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(e.sha256Hash!), isTrue);
      expect(e.sizeBytes, greaterThan(0));
    }
  });
}
