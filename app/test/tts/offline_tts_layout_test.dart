// T1.3 OfflineTts 布局多引擎识别 + supports 语种门 + worker 化后的服务行为回归。
// 布局判定对照 docs/M0-EVIDENCE-VOICE.md 三档实测模型目录形态。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/tts/offline_tts_service.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('tts_layout'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 按名建文件/目录，返回模型目录路径。
  String mk(String name, Map<String, Object> entries) {
    final d = '${tmp.path}\\$name';
    Directory(d).createSync(recursive: true);
    for (final e in entries.entries) {
      final v = e.value;
      if (v is Directory) {
        Directory('$d\\${e.key}').createSync();
      } else if (v is List<int>) {
        File('$d\\${e.key}').writeAsBytesSync(v);
      } else {
        File('$d\\${e.key}').writeAsStringSync(v.toString());
      }
    }
    return d;
  }

  group('OfflineTtsLayout.detect 家族判定', () {
    test('英文 piper：model.onnx + tokens.txt + espeak-ng-data → vits、不接中文', () {
      final d = mk('vits-en', {
        'model.onnx': [0],
        'tokens.txt': 'a\nb\n',
        'espeak-ng-data': Directory(''),
      });
      final l = OfflineTtsLayout.detect(d);
      expect(l.kind, OfflineTtsKind.vits);
      expect(l.complete, isTrue);
      expect(l.chineseCapable, isFalse);
      expect(l.dataDir, isNotNull);
    });

    test('中文 vits（aishell3）：带 lexicon.txt → vits、接中文、fst/rule.far 收进 spec', () {
      final d = mk('vits-zh', {
        'vits-aishell3.int8.onnx': [0, 0],
        'tokens.txt': 'a\nb\n',
        'lexicon.txt': '汪 0\n',
        'date.fst': 'x',
        'number.fst': 'x',
        'rule.far': 'x',
      });
      final l = OfflineTtsLayout.detect(d);
      expect(l.kind, OfflineTtsKind.vits);
      expect(l.complete, isTrue);
      expect(l.chineseCapable, isTrue);
      expect(l.lexicon, isNotNull);
      expect(l.ruleFsts, contains('date.fst'));
      expect(l.ruleFsts, contains('number.fst'));
      expect(l.ruleFars, isNotNull);
    });

    test('matcha：主模型 + vocoder*.onnx + dict/ → matcha；缺 vocoder → complete=false', () {
      final full = mk('matcha', {
        'model-steps-3.onnx': [0],
        'vocoder-icefall-zh.onnx': [0],
        'tokens.txt': 'a\n',
        'dict': Directory(''),
      });
      final lf = OfflineTtsLayout.detect(full);
      expect(lf.kind, OfflineTtsKind.matcha);
      expect(lf.complete, isTrue);
      expect(lf.chineseCapable, isTrue);
      expect(lf.vocoder, isNotNull);
      expect(lf.dictDir, isNotNull);
      expect(lf.model, contains('model-steps-3.onnx'));

      final broken = mk('matcha-novoc', {
        'model-steps-3.onnx': [0],
        'tokens.txt': 'a\n',
      });
      final lb = OfflineTtsLayout.detect(broken);
      expect(lb.kind, OfflineTtsKind.vits); // 退回 vits 判定
      expect(lb.complete, isTrue); // vits 口径文件齐
    });

    test('kokoro：model*.onnx + voices.bin + espeak-ng-data → kokoro', () {
      final d = mk('kokoro', {
        'model.int8.onnx': [0],
        'voices.bin': [0],
        'tokens.txt': 'a\n',
        'lexicon-zh.txt': '汪 0\n',
        'espeak-ng-data': Directory(''),
      });
      final l = OfflineTtsLayout.detect(d);
      expect(l.kind, OfflineTtsKind.kokoro);
      expect(l.complete, isTrue);
      expect(l.chineseCapable, isTrue);
      expect(l.lexicon, isNotNull);
    });

    test('空/缺目录：complete=false', () {
      expect(OfflineTtsLayout.detect('${tmp.path}\\nope').complete, isFalse);
      final d = mk('half', {'model.onnx': [0]});
      expect(OfflineTtsLayout.detect(d).complete, isFalse);
    });
  });

  group('OfflineTtsService.supports 语种门', () {
    OfflineTtsService svc(String d) => OfflineTtsService(
          modelDir: d,
          // 引擎工厂不参与 supports 判定；测试里不触原生。
          engineFactory: (l) => throw StateError('layout 不该触引擎'),
        );

    test('英文 piper：英文接、中文拒、纯符号拒（老口径回归）', () {
      final s = svc(mk('s-en', {
        'model.onnx': [0],
        'tokens.txt': 'a\n',
        'espeak-ng-data': Directory(''),
      }));
      expect(s.supports('hello world'), isTrue);
      expect(s.supports('你好世界'), isFalse);
      expect(s.supports('hello 你好'), isFalse);
      expect(s.supports('。！？'), isFalse);
      expect(s.supports(''), isFalse);
    });

    test('中文引擎（vits-zh 带词表）：中文接、英文接', () {
      final s = svc(mk('s-zh', {
        'vits-aishell3.int8.onnx': [0],
        'tokens.txt': 'a\n',
        'lexicon.txt': '汪 0\n',
      }));
      expect(s.supports('汪柴你好'), isTrue);
      expect(s.supports('hello'), isTrue);
      expect(s.supports('。'), isFalse);
    });
  });

  group('服务行为回归（worker 化不改变对外口径）', () {
    test('缺模型：modelPresent=false、synthesizeToFile 返回 null 且记账、不抛', () async {
      final s = OfflineTtsService(
        modelDir: mk('half2', {'model.onnx': [0]}),
        engineFactory: (l) => throw StateError('不该触引擎'),
      );
      expect(s.modelPresent, isFalse);
      expect(s.notReadyReason, isNotNull);
      final f = await s.synthesizeToFile('hi', voice: 'v', rate: 0);
      expect(f, isNull);
      expect(s.lastFailureMessage, isNotNull);
    });

    test('prewarm 失败不抛、只记账；成功路径由 host_speak_offline_test 的 fake 覆盖', () async {
      final s = OfflineTtsService(
        modelDir: mk('s-load', {
          'model.onnx': [0],
          'tokens.txt': 'a\n',
        }),
        engineFactory: (l) => _BoomEngine(),
      );
      await s.prewarm();
      expect(s.lastFailureMessage, isNotNull);
    });

    test('wavFromPcm16 头部口径（16k 单声道 PCM16）', () {
      final wav = wavFromPcm16(Uint8List.fromList([1, 2, 3, 4]), sampleRate: 16000);
      expect(wav.length, 48);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(24, Endian.little), 16000);
      expect(bd.getUint16(34, Endian.little), 16);
    });

    test('speedFromRate 满量程 0.5–2.0 对齐', () {
      expect(speedFromRate(0), 1.0);
      expect(speedFromRate(100), 2.0);
      expect(speedFromRate(-100), 0.5);
      expect(speedFromRate(200), 2.0);
    });
  });
}

/// load 必炸的假引擎（prewarm 记账路径用）。
final class _BoomEngine implements OfflineTtsEngine {
  @override
  Future<void> load() async => throw Exception('模型文件坏了');

  @override
  Future<OfflinePcm> pcm16(String text, {required int speakerId, required double speed}) async =>
      throw Exception('不该走到');

  @override
  Future<void> dispose() async {}
}
