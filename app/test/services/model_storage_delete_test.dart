import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/services/model_storage_service.dart';

/// 模型删除的落盘清扫（2026-10-30 反馈「删除点了没反应，再进列表还在」）。
///
/// 两根因各由一处防线守着：
/// ① 旧 `deleteModel` 只删主目录，而「是否已缓存」是多目录判据 → 现在统一走
///    [ModelStorageService.deleteModelArtifacts] 的多目录清扫（真机侧验证）；
/// ② 旧删除清单只有 4 个后缀，**漏了 dspark 草稿头** `{id}.dspark.gguf` →
///    现在由 [ModelStorageService.modelArtifactFileNames] 一处定义，本文件钉住。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tyl_models_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> put(String name, {String content = 'x'}) async {
    final f = File('${root.path}/$name');
    await f.create(recursive: true);
    await f.writeAsString(content);
  }

  group('模型产物删除清单', () {
    test('清单覆盖 主 gguf / mmproj / dspark 草稿头 与各自的 .tmp 残留', () {
      expect(ModelStorageService.modelArtifactFileNames('m1'), containsAll([
        'm1.gguf',
        'm1.gguf.tmp',
        'm1.mmproj',
        'm1.mmproj.tmp',
        'm1.dspark.gguf', // 旧删除清单漏掉的那一个
        'm1.dspark.gguf.tmp',
      ]));
      expect(ModelStorageService.modelExpertsDirName('m1'), 'm1.experts');
    });

    test('单目录清扫：本模型产物删净，别人与前缀相似的文件一个不碰', () async {
      final names = ModelStorageService.modelArtifactFileNames('m1');
      for (final n in names) {
        await put(n);
      }
      // 拆分 MoE 专家包目录（manifest + 分片）。
      final experts = Directory('${root.path}/m1.experts');
      await experts.create();
      await File('${experts.path}/manifest.json').writeAsString('{}');
      await File('${experts.path}/layer_000.bin').writeAsString('bin');
      // 必须幸存：前缀相似的另一个模型 / 别人的模型 / 无关文件。
      await put('m11.gguf');
      await put('m2.gguf');
      await put('README.md');

      final removed = await ModelStorageService.deleteArtifactsIn(root, 'm1');

      expect(removed.length, names.length + 1, reason: '6 个文件 + 1 个专家包目录');
      for (final n in names) {
        expect(File('${root.path}/$n').existsSync(), isFalse,
            reason: '$n 应已删除');
      }
      expect(experts.existsSync(), isFalse, reason: '专家包目录应整体删除');
      for (final keep in ['m11.gguf', 'm2.gguf', 'README.md']) {
        expect(File('${root.path}/$keep').existsSync(), isTrue,
            reason: '$keep 不该被误删');
      }
    });

    test('目录里没有该模型时返回空列表且不抛（幂等，可重复删）', () async {
      await put('other.gguf');
      expect(await ModelStorageService.deleteArtifactsIn(root, 'ghost'), isEmpty);
      // 第一次删掉它，第二次再删同一 id 只剩空列表 —— 不抛异常，UI 可安全重试。
      expect(
          await ModelStorageService.deleteArtifactsIn(root, 'other'), isNotEmpty);
      expect(await ModelStorageService.deleteArtifactsIn(root, 'other'), isEmpty);
    });
  });
}
