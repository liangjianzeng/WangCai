// T1.5 VoiceModelManager 单测：注册表 / dio 断点续传 / sha256 拒收 / 双源回落 /
// 取消 / 旧目录搬迁。下载用假 adapter（按 URL 精确匹配）；"正确字节"直接取本机
// M0 已验证的 silero_vad.onnx（其 sha256 与注册表钉的一致，全链路真校验），
// 本机没有该文件时相应用例 skip。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/platform/wangcai_paths.dart';
import 'package:wangcai/voice/voice_model_manager.dart';

/// 按 URL 精确匹配的假 adapter：支持 Range（206 断点）、404。
final class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.bodies);

  /// url → 完整字节。缺席的 url 返回 404。
  final Map<String, List<int>> bodies;

  /// 收到的请求 URL（含顺序），断言用。
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requests.add(url);
    final body = bodies[url];
    if (body == null) {
      return ResponseBody(const Stream<Uint8List>.empty(), 404,
          headers: {Headers.contentLengthHeader: ['0']}, statusMessage: 'Not Found');
    }
    var payload = body;
    var status = 200;
    final range = options.headers['Range'] as String?;
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (m != null) {
        final start = int.parse(m.group(1)!);
        payload = start >= body.length ? <int>[] : body.sublist(start);
        status = 206;
      }
    }
    // 64KB 分块流式吐出，模拟真实下载。
    final chunks = <Uint8List>[];
    for (var i = 0; i < payload.length; i += 1 << 16) {
      chunks.add(Uint8List.fromList(payload.sublist(i, i + (1 << 16) > payload.length ? payload.length : i + (1 << 16))));
    }
    return ResponseBody(Stream<Uint8List>.fromIterable(chunks), status,
        headers: {Headers.contentLengthHeader: [payload.length.toString()]});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  FakeAdapter? adapter;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('voice_mm');
    WangCaiPaths.dataRootOverrideForTest = () => tmp;
  });

  tearDown(() {
    WangCaiPaths.dataRootOverrideForTest = null;
    VoiceModelManager.dioFactoryForTest = null;
    VoiceModelManager.legacyAsrHomeOverrideForTest = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 用本机已验证的 silero_vad.onnx 作为"服务器上的正确字节"。
  List<int>? vadBytes() {
    const src = r'C:\dev-tools\voice-models\vad\silero_vad.onnx';
    final f = File(src);
    return f.existsSync() ? f.readAsBytesSync() : null;
  }

  void installAdapter(Map<String, List<int>> bodies) {
    adapter = FakeAdapter(bodies);
    VoiceModelManager.dioFactoryForTest =
        () => Dio()..httpClientAdapter = adapter!;
  }

  String vadPrimaryUrl() =>
      VoiceModels.entry(VoiceModels.vad).files.first.urls.first;
  String vadFallbackUrl() =>
      VoiceModels.entry(VoiceModels.vad).files.first.urls.last;

  group('注册表', () {
    test('7 条目齐 + id 常量与 entry() 对上', () {
      expect(VoiceModels.entries.length, 7);
      for (final e in VoiceModels.entries) {
        expect(VoiceModels.entry(e.id).id, e.id);
        expect(e.files, isNotEmpty);
      }
    });

    test('流式条目 4 文件、全部有源且带 sha256', () {
      final e = VoiceModels.entry(VoiceModels.streaming);
      expect(e.files.map((f) => f.path), containsAll([
        'tokens.txt', 'decoder.onnx', 'joiner.int8.onnx', 'encoder.int8.onnx',
      ]));
      for (final f in e.files) {
        expect(f.hasSource, isTrue);
        expect(f.sha256, isNotNull);
        expect(f.urls.length, 2); // hf-mirror 主源 + hf 兜底
      }
    });

    test('KWS M3 已定源（4 文件全带 sha256）；matcha vocos 已补源；espeak 树仍占位', () {
      final kws = VoiceModels.entry(VoiceModels.kws).files;
      expect(kws, hasLength(4));
      for (final f in kws) {
        expect(f.hasSource, isTrue, reason: 'T3：wenetspeech-3.3M 已定源（Jeryuk 镜像）');
        expect(f.sha256, isNotNull);
        expect(f.urls.length, 2);
      }
      expect(kws.map((f) => f.path),
          containsAll(['tokens.txt', 'encoder-epoch-99-avg-1-chunk-16-left-64.onnx',
            'decoder-epoch-99-avg-1-chunk-16-left-64.onnx',
            'joiner-epoch-99-avg-1-chunk-16-left-64.onnx']));
      final vocos = VoiceModels.entry(VoiceModels.matcha).files
          .firstWhere((f) => f.path.contains('vocos'));
      expect(vocos.hasSource, isTrue, reason: 'T2.5：vocoder 已找到镜像源');
      expect(vocos.sha256, isNotNull);
      expect(VoiceModels.entry(VoiceModels.kokoro).files
          .firstWhere((f) => f.path.startsWith('espeak')).hasSource, isFalse);
    });
  });

  group('isReady / missingFiles / deleteModel', () {
    test('空目录：未就绪、missingFiles 报有源缺失、占位不计入', () async {
      expect(await VoiceModelManager.isReady(VoiceModels.vad), isFalse);
      final missing = await VoiceModelManager.missingFiles(VoiceModels.matcha);
      expect(missing, isNot(contains('vocoder-icefall-zh.onnx')));
      expect(missing, contains('model-steps-3.onnx'));
      await VoiceModelManager.deleteModel(VoiceModels.vad); // 幂等不抛
    });

    test('文件齐：就绪', () async {
      final dir = await VoiceModelManager.modelDir(VoiceModels.vad);
      File('$dir\\silero_vad.onnx').writeAsBytesSync([1, 2, 3]);
      expect(await VoiceModelManager.isReady(VoiceModels.vad), isTrue);
    });
  });

  group('download（真字节 + 真 sha256 全链路）', () {
    test('成功：进度回调、.part 清理、isReady 翻真', () async {
      final bytes = vadBytes();
      if (bytes == null) {
        // 本机无 M0 模型：退化为"0 字节异常"路径，不装 adapter。
        installAdapter({});
        expect(() => VoiceModelManager.download(VoiceModels.vad,
                onProgress: (_, __) {}, isCancelled: () => false),
            throwsA(isA<VoiceModelException>()));
        return;
      }
      installAdapter({vadPrimaryUrl(): bytes});
      final progress = <double>[];
      await VoiceModelManager.download(VoiceModels.vad,
          onProgress: (p, file) {
            progress.add(p);
            expect(file, 'silero_vad.onnx');
          },
          isCancelled: () => false);
      expect(progress, isNotEmpty);
      expect(progress.last, closeTo(1.0, 0.01));
      final dir = await VoiceModelManager.modelDir(VoiceModels.vad);
      expect(File('$dir\\silero_vad.onnx').existsSync(), isTrue);
      expect(File('$dir\\silero_vad.onnx.part').existsSync(), isFalse);
      expect(await VoiceModelManager.isReady(VoiceModels.vad), isTrue);
      expect(adapter!.requests.length, 1);
    });

    test('已存在且尺寸对：跳过（不碰网络）', () async {
      final bytes = vadBytes();
      if (bytes == null) return;
      installAdapter({});
      final dir = await VoiceModelManager.modelDir(VoiceModels.vad);
      File('$dir\\silero_vad.onnx').writeAsBytesSync(bytes);
      await VoiceModelManager.download(VoiceModels.vad,
          onProgress: (_, __) {}, isCancelled: () => false);
      expect(adapter!.requests, isEmpty);
    });

    test('断点续传：.part 前缀 + Range 206 → 拼成完整文件', () async {
      final bytes = vadBytes();
      if (bytes == null) return;
      installAdapter({vadPrimaryUrl(): bytes});
      final dir = await VoiceModelManager.modelDir(VoiceModels.vad);
      // 预置前 40% 断点
      final cut = bytes.length * 2 ~/ 5;
      File('$dir\\silero_vad.onnx.part').writeAsBytesSync(bytes.sublist(0, cut));
      await VoiceModelManager.download(VoiceModels.vad,
          onProgress: (_, __) {}, isCancelled: () => false);
      final got = File('$dir\\silero_vad.onnx').readAsBytesSync();
      expect(got.length, bytes.length);
      expect(got.sublist(0, cut), bytes.sublist(0, cut)); // 断点前缀被续用
      expect(adapter!.requests.single.contains('hf-mirror.com'), isTrue);
    });

    test('主源 404 → 兜底源成功', () async {
      final bytes = vadBytes();
      if (bytes == null) return;
      installAdapter({vadFallbackUrl(): bytes}); // 主源缺席 = 404
      await VoiceModelManager.download(VoiceModels.vad,
          onProgress: (_, __) {}, isCancelled: () => false);
      expect(adapter!.requests, [vadPrimaryUrl(), vadFallbackUrl()]);
    });

    test('sha256 拒收：坏字节删文件抛异常、isReady 仍 false', () async {
      final bytes = vadBytes();
      if (bytes == null) return;
      final bad = List<int>.from(bytes)..[0] = bytes[0] ^ 0xff;
      installAdapter({vadPrimaryUrl(): bad, vadFallbackUrl(): bad});
      final dir = await VoiceModelManager.modelDir(VoiceModels.vad);
      await expectLater(
        VoiceModelManager.download(VoiceModels.vad,
            onProgress: (_, __) {}, isCancelled: () => false),
        throwsA(isA<VoiceModelException>()),
      );
      expect(File('$dir\\silero_vad.onnx').existsSync(), isFalse); // 双源都拒后不留坏文件
      expect(await VoiceModelManager.isReady(VoiceModels.vad), isFalse);
    });

    test('isCancelled：中止并抛 VoiceDownloadCancelled', () async {
      installAdapter({});
      await expectLater(
        VoiceModelManager.download(VoiceModels.vad,
            onProgress: (_, __) {}, isCancelled: () => true),
        throwsA(isA<VoiceDownloadCancelled>()),
      );
    });
  });

  group('旧目录搬迁（documents/models/asr → dataRoot/models/voice）', () {
    Directory legacyOf(Directory home) => Directory(
        '${home.path}\\models\\asr\\sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30');

    Directory targetOf() =>
        Directory('${tmp.path}\\models\\voice\\${VoiceModels.streaming}');

    test('复制→校验→旧目录摘牌 .migrated；目标完整', () {
      final home = Directory('${tmp.path}\\home1');
      final legacy = legacyOf(home);
      legacy.createSync(recursive: true);
      final files = VoiceModels.entry(VoiceModels.streaming).files;
      for (final f in files) {
        File('${legacy.path}\\${f.path}').writeAsBytesSync(List.filled(64, f.path.length));
      }
      VoiceModelManager.migrateLegacyDirForTest(legacy, targetOf());
      for (final f in files) {
        expect(File('${targetOf().path}\\${f.path}').existsSync(), isTrue);
      }
      expect(legacy.existsSync(), isFalse);
      expect(Directory('${legacy.path}.migrated').existsSync(), isTrue);
    });

    test('新家已完整：只摘牌旧目录不覆盖新数据', () {
      final home = Directory('${tmp.path}\\home2');
      final legacy = legacyOf(home)..createSync(recursive: true);
      File('${legacy.path}\\tokens.txt').writeAsBytesSync([9, 9]);
      final target = targetOf()..createSync(recursive: true);
      File('${target.path}\\tokens.txt').writeAsBytesSync([1]);
      for (final f in VoiceModels.entry(VoiceModels.streaming).files) {
        File('${target.path}\\${f.path}').writeAsBytesSync([1]); // 新家4文件齐
      }
      VoiceModelManager.migrateLegacyDirForTest(legacy, target);
      expect(File('${target.path}\\tokens.txt').readAsBytesSync(), [1]); // 新数据没被动
      expect(legacy.existsSync(), isFalse);
    });

    test('空旧目录：no-op、不摘牌', () {
      final home = Directory('${tmp.path}\\home3');
      final legacy = legacyOf(home)..createSync(recursive: true);
      VoiceModelManager.migrateLegacyDirForTest(legacy, targetOf());
      expect(legacy.existsSync(), isTrue); // 空目录不值得摘牌
    });

    test('migrateLegacyAsr() 用 legacyAsrHomeOverrideForTest 全链路跑通且幂等', () async {
      final home = Directory('${tmp.path}\\home4');
      final legacy = legacyOf(home)..createSync(recursive: true);
      File('${legacy.path}\\tokens.txt').writeAsBytesSync([7]);
      VoiceModelManager.legacyAsrHomeOverrideForTest = () => home;
      await VoiceModelManager.migrateLegacyAsr();
      await VoiceModelManager.migrateLegacyAsr(); // 幂等
      expect(File('${targetOf().path}\\tokens.txt').existsSync(), isTrue);
      expect(legacy.existsSync(), isFalse);
    });
  });
}
