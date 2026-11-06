/// 语音模型注册表与下载器（ASR&TTS 重构 T1.5）：AsrModelManager 的泛化。
///
/// - **注册表 7 条目**：流式 Zipformer（按住说话现役）、SenseVoice int8（D3 单档）、
///   silero-VAD v5、KWS（M3 唤醒「汪柴」，wenetspeech-3.3M 已定源）、matcha-zh-baker（M2 转正）、
///   vits-zh-aishell3（本机低配兜底）、Kokoro int8（285H 复测候选）。
///   所有 sha256 取自本机 M0 实测台账的已验证 blob（docs/M0-EVIDENCE-VOICE.md）。
/// - **dio 断点续传**：`.part` 文件 + `Range` 头，杀进程/断网重入队从断点继续；
///   替换 background_downloader（仅 Android/iOS，Windows 死代码，pubspec 已移除）。
/// - **sha256 校验拒收**：下载完即验，不匹配删文件报错 —— 损坏的模型绝不进引擎
///   （pub 镜像坏 DLL 教训的制度化，见 M0 台账环境坑 2）。
/// - **目录统一** `%APPDATA%\WangCai\models\voice\<id>`（WangCaiPaths.dataRoot，
///   测试可用 dataRootOverrideForTest 隔离）；旧 `documents/models/asr/<modelId>`
///   首次用到时自动搬迁（复制→按字节校验→旧目录改名 .migrated 备份，沿用
///   v0.0.4 dataRoot 搬迁纪律，任何一步失败都静默、数据不丢）。
/// - **双源**：hf-mirror.com 主源（国内可达）+ huggingface.co 兜底，主源失败自动换源。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/wangcai_paths.dart';

/// 注册表里的一个模型文件。`url == null` 表示**来源待定**（vocoder / KWS / espeak 树），
/// 不参与下载、参与 ready 判定的占位说明。
final class VoiceModelFile {
  const VoiceModelFile(this.path,
      {this.sha256, this.bytes, this.urls = const [], this.note});

  /// 相对条目目录的路径（可带子目录，如 `dict/jieba.dict.utf8`）。
  final String path;

  /// 内容哈希（hex 小写）；null = 只做尺寸/存在校验（dict 等辅助文件）。
  final String? sha256;

  /// 预期字节数（M0 本机实测），用于整体进度加权与下载后快速尺寸校验。
  final int? bytes;

  /// 下载源（按序尝试）：hf-mirror 主源 + huggingface 兜底。
  final List<String> urls;

  final String? note;

  bool get hasSource => urls.isNotEmpty;
}

/// 注册表条目。
final class VoiceModelEntry {
  const VoiceModelEntry(this.id, this.files, {this.note});

  final String id;
  final List<VoiceModelFile> files;

  /// 给设置页/日志看的一句话状态（vocoder 待补、KWS 仓库待定等）。
  final String? note;

  /// 已知来源文件的总字节数（进度加权用）。
  int get sourcedBytes =>
      files.fold(0, (n, f) => n + (f.bytes ?? 0));
}

/// hf-mirror / huggingface 的 resolve-main URL 工厂。
List<String> hfUrls(String repo, String file) => [
      'https://hf-mirror.com/$repo/resolve/main/$file',
      'https://huggingface.co/$repo/resolve/main/$file',
    ];

/// 注册表（M0 实测锁定，勿改哈希：改了就等于换了 blob）。
class VoiceModels {
  VoiceModels._();

  static const streaming = 'streaming-zipformer';
  static const sensevoice = 'sensevoice-int8';
  static const vad = 'vad-silero-v5';
  static const kws = 'kws-zipformer-wenetspeech-3.3M';
  static const matcha = 'matcha-zh-baker';
  static const vits = 'vits-zh-aishell3';
  static const kokoro = 'kokoro-v1.1-int8';

  // final 而非 const：hfUrls() 是运行时调用（URL 拼接），代价一次性。
  static final List<VoiceModelEntry> entries = [
    VoiceModelEntry(streaming, [
      VoiceModelFile('tokens.txt',
          sha256: '6193c7ea1c96d0d9a1e9652789b40d13a8a913b434a5451e93158f5a09fd6652',
          bytes: 20628,
          urls: hfUrls('csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30', 'tokens.txt')),
      VoiceModelFile('decoder.onnx',
          sha256: '06522ad63cec0fdf6809f4e1db9bb4f7d710c34582e3b35db62ac60eccafac7e',
          bytes: 5165083,
          urls: hfUrls('csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30', 'decoder.onnx')),
      VoiceModelFile('joiner.int8.onnx',
          sha256: 'b34584dc6f561089e1d747fedebb3765f2caa72c927ef54d7ca55e5ae40a814b',
          bytes: 1033416,
          urls: hfUrls('csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30', 'joiner.int8.onnx')),
      VoiceModelFile('encoder.int8.onnx',
          sha256: '5ac51e27981bb4dab01bb9be4958453ba50c3b61c063ddda0eab23fd3671aa4f',
          bytes: 161141793,
          urls: hfUrls('csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30', 'encoder.int8.onnx')),
    ]),
    VoiceModelEntry(sensevoice, [
      VoiceModelFile('model.int8.onnx',
          sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
          bytes: 239233841,
          urls: hfUrls('csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17', 'model.int8.onnx')),
      VoiceModelFile('tokens.txt',
          sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
          bytes: 315894,
          urls: hfUrls('csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17', 'tokens.txt')),
    ]),
    VoiceModelEntry(vad, [
      VoiceModelFile('silero_vad.onnx',
          sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
          bytes: 643854,
          urls: hfUrls('R4kSo1997/sherpa-onnx-silero-vad-v5', 'silero_vad.onnx')),
    ]),
    VoiceModelEntry(kws, [
      // M3 唤醒「汪柴」（voice-wakeup-min-spec）：官方 wenetspeech-3.3M 三件套
      // 文件名字义不变；源 = Jeryuk 镜像（github kws-models release 本机不可达，
      // hf 直连 000），blob 与官方逐字节同源、sha256 本机 certutil+Get-FileHash
      // 双工具钉死。E2E 实测：matcha 合成「汪柴」th=0.25 命中（tool/m3_kws_check）。
      VoiceModelFile('tokens.txt',
          sha256: '72316508d9119696145abc6f1f8cdc46287535c34e5ce7e595f845cb1499cf2e',
          bytes: 1627,
          urls: hfUrls('Jeryuk/kws-zipformer-wenetspeech-3.3M-MNN', 'kws-zipformer-wenetspeech-3.3M-MNN/tokens.txt')),
      VoiceModelFile('encoder-epoch-99-avg-1-chunk-16-left-64.onnx',
          sha256: '859cd6decc23f35e6ddb3a6ddb7172a57f6de7b54288728c2433ab94b7635c59',
          bytes: 12152560,
          urls: hfUrls('Jeryuk/kws-zipformer-wenetspeech-3.3M-MNN', 'kws-zipformer-wenetspeech-3.3M-MNN/encoder-epoch-99-avg-1-chunk-16-left-64.onnx')),
      VoiceModelFile('decoder-epoch-99-avg-1-chunk-16-left-64.onnx',
          sha256: 'fb581d6734511676e246e0dff2fea01b31b0913176cb3ca64576dbab0a177774',
          bytes: 675349,
          urls: hfUrls('Jeryuk/kws-zipformer-wenetspeech-3.3M-MNN', 'kws-zipformer-wenetspeech-3.3M-MNN/decoder-epoch-99-avg-1-chunk-16-left-64.onnx')),
      VoiceModelFile('joiner-epoch-99-avg-1-chunk-16-left-64.onnx',
          sha256: 'fcf43a2edf687e2e1bc8a2b2cf53129d3b0d693d90dcc4202e2d53b43db6c43c',
          bytes: 253410,
          urls: hfUrls('Jeryuk/kws-zipformer-wenetspeech-3.3M-MNN', 'kws-zipformer-wenetspeech-3.3M-MNN/joiner-epoch-99-avg-1-chunk-16-left-64.onnx')),
    ], note: 'M3 唤醒「汪柴」：wenetspeech-3.3M 拼音 token（tokens 无汉字，唤醒词行由 pinyin 拼）；Jeryuk 镜像 = 官方 release 同源 blob'),
    VoiceModelEntry(matcha, [
      VoiceModelFile('model-steps-3.onnx',
          sha256: '78a9fd17e9a6c20198dca4e69d18f941303f8ab39ec61dde04cfc7595262ddfd',
          bytes: 75624188,
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'model-steps-3.onnx')),
      VoiceModelFile('tokens.txt',
          sha256: '56209b2bf609d5ac1d66ede6dae7bf5254bd3f8aa24c4a6823713d5b884d87ba',
          bytes: 19591,
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'tokens.txt')),
      VoiceModelFile('lexicon.txt',
          sha256: '38b886d46aefa50da6322a64d72fd595d5f4fae1051adb160d647541b1e0a4a2',
          bytes: 1363705,
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'lexicon.txt')),
      VoiceModelFile('date.fst',
          sha256: 'eb8aa079ae3cb81d8f4404992f39d61a0cb990947512b5b8d1e54d1f6980e718',
          bytes: 59154,
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'date.fst')),
      VoiceModelFile('number.fst',
          sha256: '743f402181fcfebf76cc2f0546b71fa26476e626fbe4e460fb7b4c3a7a8bd5bd',
          bytes: 64482,
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'number.fst')),
      VoiceModelFile('phone.fst',
          sha256: '1ac2b6fa56b1442320c4de7db08353bab8963a2b57f365eebcdd3a2d3562f8d7',
          bytes: 88630,
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'phone.fst')),
      // jieba dict（辅助文件，只做存在校验）
      VoiceModelFile('dict/jieba.dict.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/jieba.dict.utf8')),
      VoiceModelFile('dict/hmm_model.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/hmm_model.utf8')),
      VoiceModelFile('dict/idf.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/idf.utf8')),
      VoiceModelFile('dict/stop_words.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/stop_words.utf8')),
      VoiceModelFile('dict/user.dict.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/user.dict.utf8')),
      VoiceModelFile('dict/pos_dict/char_state_tab.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/pos_dict/char_state_tab.utf8')),
      VoiceModelFile('dict/pos_dict/prob_start.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/pos_dict/prob_start.utf8')),
      VoiceModelFile('dict/pos_dict/prob_trans.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/pos_dict/prob_trans.utf8')),
      VoiceModelFile('dict/pos_dict/prob_emit.utf8',
          urls: hfUrls('csukuangfj/matcha-icefall-zh-baker', 'dict/pos_dict/prob_emit.utf8')),
      // vocoder：官方包与 csukuangfj repo 均不含；M2 复核找到第三方镜像
      // （alexmultiagent，vocos-22khz 与 zh-baker 22050Hz 匹配），sha256 取
      // 本机实测下载的 blob。
      VoiceModelFile('vocos-22khz-univ.onnx',
          sha256: '0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081',
          bytes: 53884024,
          urls: hfUrls('alexmultiagent/sherpa-onnx-matcha-zh-baker',
              'vocos-22khz-univ.onnx')),
    ], note: 'M2 转正默认引擎（本机实测 RTF 0.15-0.19、首声 542ms 达标）'),
    VoiceModelEntry(vits, [
      VoiceModelFile('vits-aishell3.int8.onnx',
          sha256: '5ef667dbbe0795688da93d779828cf38e6ad8ef8e82aa7dc5804873a50556057',
          bytes: 39870124,
          urls: hfUrls('csukuangfj/vits-zh-aishell3', 'vits-aishell3.int8.onnx')),
      VoiceModelFile('tokens.txt',
          sha256: '50b45a7b7de1752fd3c7b4755661c285f1547f59186eca2281089a81307ad953',
          bytes: 1671,
          urls: hfUrls('csukuangfj/vits-zh-aishell3', 'tokens.txt')),
      VoiceModelFile('lexicon.txt',
          sha256: 'ab2e61d357551e7b24ddd965d924aca784c20165ff58c150794e539c6b5e9e35',
          bytes: 2042943,
          urls: hfUrls('csukuangfj/vits-zh-aishell3', 'lexicon.txt')),
      VoiceModelFile('rule.far',
          sha256: 'b090ed05e333fe125b62d8b1de5f1a1d4579fb237c606e7ac0b84707c863a01f',
          bytes: 180717014,
          urls: hfUrls('csukuangfj/vits-zh-aishell3', 'rule.far')),
      VoiceModelFile('date.fst',
          sha256: 'eb8aa079ae3cb81d8f4404992f39d61a0cb990947512b5b8d1e54d1f6980e718',
          bytes: 59154,
          urls: hfUrls('csukuangfj/vits-zh-aishell3', 'date.fst')),
      VoiceModelFile('number.fst',
          sha256: '743f402181fcfebf76cc2f0546b71fa26476e626fbe4e460fb7b4c3a7a8bd5bd',
          bytes: 64482,
          urls: hfUrls('csukuangfj/vits-zh-aishell3', 'number.fst')),
      VoiceModelFile('phone.fst',
          sha256: '1ac2b6fa56b1442320c4de7db08353bab8963a2b57f365eebcdd3a2d3562f8d7',
          bytes: 88630,
          urls: hfUrls('csukuangfj/vits-zh-aishell3', 'phone.fst')),
      VoiceModelFile('new_heteronym.fst',
          sha256: 'ca14b2127e27baa571664e4bb791e143e7425f56a6bc29db08d74f97e6aa4e29',
          bytes: 21974,
          urls: hfUrls('csukuangfj/vits-zh-aishell3', 'new_heteronym.fst')),
    ]),
    VoiceModelEntry(kokoro, [
      VoiceModelFile('model.int8.onnx',
          sha256: '05d793700b0b507f760c183c0e39bdd6a97b43d32fdc7bf7b54a5179f1b11222',
          bytes: 114203914,
          urls: hfUrls('csukuangfj/kokoro-int8-multi-lang-v1_1', 'model.int8.onnx')),
      VoiceModelFile('voices.bin',
          sha256: 'e64a5a581d8c2a350d848f51c3121657cd83aa07ed6109172177345874a7244c',
          bytes: 53790720,
          urls: hfUrls('csukuangfj/kokoro-int8-multi-lang-v1_1', 'voices.bin')),
      VoiceModelFile('tokens.txt',
          sha256: '931ab2df2400cd65d580a22402024c2347ced8ae9ea300e545144b1aacc48e14',
          bytes: 1111,
          urls: hfUrls('csukuangfj/kokoro-int8-multi-lang-v1_1', 'tokens.txt')),
      VoiceModelFile('lexicon-zh.txt',
          sha256: 'fea060803db3e59193987f1a3436f56917bda09f3b3595b6588e46ae60cebf93',
          bytes: 2120131,
          urls: hfUrls('csukuangfj/kokoro-int8-multi-lang-v1_1', 'lexicon-zh.txt')),
      VoiceModelFile('date-zh.fst',
          sha256: 'eb8aa079ae3cb81d8f4404992f39d61a0cb990947512b5b8d1e54d1f6980e718',
          bytes: 59154,
          urls: hfUrls('csukuangfj/kokoro-int8-multi-lang-v1_1', 'date-zh.fst')),
      VoiceModelFile('number-zh.fst',
          sha256: '743f402181fcfebf76cc2f0546b71fa26476e626fbe4e460fb7b4c3a7a8bd5bd',
          bytes: 64482,
          urls: hfUrls('csukuangfj/kokoro-int8-multi-lang-v1_1', 'number-zh.fst')),
      VoiceModelFile('phone-zh.fst',
          sha256: '1ac2b6fa56b1442320c4de7db08353bab8963a2b57f365eebcdd3a2d3562f8d7',
          bytes: 88630,
          urls: hfUrls('csukuangfj/kokoro-int8-multi-lang-v1_1', 'phone-zh.fst')),
      VoiceModelFile('espeak-ng-data/zh_dict',
          note: 'espeak-ng-data 全树（372 文件）M2 走清单批量拉', urls: []),
    ], note: '285H 复测候选（本机 RTF 2.1 否决为默认）；espeak-ng-data 树 M2 补'),
  ];

  static VoiceModelEntry entry(String id) =>
      entries.firstWhere((e) => e.id == id, orElse: () => throw StateError('未知语音模型 id: $id'));
}

/// 语音模型管理器（全静态，消费方与旧 AsrModelManager 同构）。
class VoiceModelManager {
  VoiceModelManager._();

  /// 测试注入点：替换 Dio 构造（假 adapter 模拟服务器）。设值即重置缓存
  /// （静态 Dio 缓存会跨用例把旧 adapter 带进新用例——真踩过）。
  static Dio Function()? _dioFactory;
  static Dio? _dio;
  static Dio? _testDio;

  @visibleForTesting
  static set dioFactoryForTest(Dio Function()? f) {
    _dioFactory = f;
    _dio = null;
    _testDio = null;
  }

  @visibleForTesting
  static Dio Function()? get dioFactoryForTest => _dioFactory;

  /// 测试注入点：旧 ASR 模型目录（path_provider 平台通道测试环境不可用）。
  @visibleForTesting
  static Directory? Function()? legacyAsrHomeOverrideForTest;

  static Dio get _client {
    if (_dioFactory != null) return _testDio ??= _dioFactory!();
    return _dio ??= _defaultDio();
  }

  static Dio _defaultDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        // 流式下载按 chunk 到达，读超时只管 chunk 间隔（3.6 不设 total receive 超时）。
        receiveTimeout: const Duration(seconds: 60),
        maxRedirects: 5,
      ));

  static final Map<String, CancelToken> _tokens = {};

  /// 模型目录：`<dataRoot>/models/voice/<id>`。
  static Future<String> modelDir(String id) async {
    if (id == VoiceModels.streaming) await migrateLegacyAsr();
    final dir = p.join(WangCaiPaths.dataRoot().path, 'models', 'voice', id);
    await Directory(dir).create(recursive: true);
    return dir;
  }

  /// 模型是否已就绪（注册表内全部**有源**文件就位；无源的占位文件只看说明）。
  static Future<bool> isReady(String id) async {
    final dir = await modelDir(id);
    for (final f in VoiceModels.entry(id).files) {
      if (!f.hasSource) continue; // vocoder/KWS/espeak 等占位
      if (!File(p.join(dir, f.path)).existsSync()) return false;
    }
    return true;
  }

  /// ready 还差什么（设置页黄条/下载引导文案用）。
  static Future<List<String>> missingFiles(String id) async {
    final dir = await modelDir(id);
    return [
      for (final f in VoiceModels.entry(id).files)
        if (f.hasSource && !File(p.join(dir, f.path)).existsSync()) f.path,
    ];
  }

  /// 下载缺失文件（幂等：已存在且尺寸对得上就跳过）。
  ///
  /// [onProgress]：整体进度 0.0~1.0 与当前文件名（按字节加权）。
  /// [isCancelled]：外部取消轮询，返回 true 即中止并抛 [VoiceDownloadCancelled]。
  /// 任一文件双源都失败抛 [VoiceModelException]；sha256 不匹配删文件抛异常。
  static Future<void> download(
    String id, {
    required void Function(double progress, String currentFile) onProgress,
    required bool Function() isCancelled,
  }) async {
    final entry = VoiceModels.entry(id);
    final dir = await modelDir(id);
    final todo = <VoiceModelFile>[];
    for (final f in entry.files) {
      if (!f.hasSource) continue;
      final target = File(p.join(dir, f.path));
      if (target.existsSync() && (f.bytes == null || target.lengthSync() == f.bytes)) {
        continue;
      }
      // 尺寸不符 = 旧的半截/坏文件，删掉重来（sha 会在下载后再验一遍）。
      if (target.existsSync()) target.deleteSync();
      todo.add(f);
    }
    if (todo.isEmpty) return;

    final totalBytes = todo.fold(0, (n, f) => n + (f.bytes ?? 0));
    var doneBytes = 0;
    for (final f in todo) {
      if (isCancelled()) throw const VoiceDownloadCancelled();
      await _downloadOne(f, dir: dir,
          onFileProgress: (fileDone) =>
              onProgress(totalBytes > 0 ? (doneBytes + fileDone) / totalBytes : 0, f.path));
      doneBytes += f.bytes ?? 0;
      debugPrint('[DSH][voice] downloaded: ${f.path}');
    }
  }

  /// 取消进行中的下载（对话框取消按钮 / 页面销毁）。
  static Future<void> cancelDownloads() async {
    for (final t in _tokens.values) {
      t.cancel('user cancelled');
    }
    _tokens.clear();
  }

  /// 删除模型目录（设置里的「清除模型」入口）。
  static Future<void> deleteModel(String id) async {
    await cancelDownloads();
    final dir = p.join(WangCaiPaths.dataRoot().path, 'models', 'voice', id);
    final d = Directory(dir);
    if (d.existsSync()) await d.delete(recursive: true);
  }

  // ---- 旧目录搬迁（复制→校验→旧目录改名备份；沿用 v0.0.4 搬迁纪律） ----

  static bool _legacyMigrated = false;

  /// 旧 `documents/models/asr/<modelId>` → `<dataRoot>/models/voice/streaming-zipformer`。
  /// 幂等、全程静默失败（新家照常走下载，旧数据原地不丢）。
  static Future<void> migrateLegacyAsr() async {
    if (_legacyMigrated) return;
    _legacyMigrated = true;
    try {
      final Directory? docs;
      if (legacyAsrHomeOverrideForTest != null) {
        docs = legacyAsrHomeOverrideForTest!();
        if (docs == null) return; // 测试注入"无旧家"
      } else {
        docs = await getApplicationDocumentsDirectory();
      }
      final legacy = Directory(p.join(
          docs.path, 'models', 'asr', 'sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30'));
      final target = Directory(
          p.join(WangCaiPaths.dataRoot().path, 'models', 'voice', VoiceModels.streaming));
      _migrateLegacyDir(legacy, target);
    } catch (e) {
      debugPrint('[DSH][voice] legacy migration skipped: $e');
    }
  }

  /// 纯函数搬迁（单测直接打）：复制→按字节校验→旧目录改名 `.migrated`。
  /// 新家已完整（4 文件齐）则直接摘牌旧目录；任何失败静默返回。
  @visibleForTesting
  static void migrateLegacyDirForTest(Directory legacy, Directory target) =>
      _migrateLegacyDir(legacy, target);

  static void _migrateLegacyDir(Directory legacy, Directory target) {
    try {
      if (!legacy.existsSync()) return;
      final files = legacy.listSync().whereType<File>().toList();
      if (files.isEmpty) return;
      final targetExistsComplete = VoiceModels
          .entry(VoiceModels.streaming)
          .files
          .every((f) => File(p.join(target.path, f.path)).existsSync());
      if (targetExistsComplete) {
        legacy.renameSync('${legacy.path}.migrated'); // 新家已就绪：旧数据留备份
        return;
      }
      target.createSync(recursive: true);
      for (final f in files) {
        final t = File(p.join(target.path, p.basename(f.path)));
        final srcLen = f.lengthSync(); // 先记尺寸：rename 后源文件就不在了
        if (t.existsSync() && t.lengthSync() == srcLen) continue;
        // 跨卷可能 rename 失败 → 流式复制兜底；校验字节数一致才继续。
        try {
          f.renameSync(t.path);
        } catch (_) {
          _copyFile(f, t);
        }
        if (t.lengthSync() != srcLen) {
          t.deleteSync();
          return; // 校验失败：不删源，下次启动再试
        }
      }
      legacy.renameSync('${legacy.path}.migrated'); // 删源=摘牌备份，数据不丢
      debugPrint('[DSH][voice] legacy asr model migrated to ${target.path}');
    } catch (e) {
      debugPrint('[DSH][voice] legacy migration skipped: $e');
    }
  }

  static void _copyFile(File from, File to) {
    final raf = from.openSync();
    try {
      final out = to.openSync(mode: FileMode.write);
      try {
        while (true) {
          final chunk = raf.readSync(1 << 20);
          if (chunk.isEmpty) break;
          out.writeFromSync(chunk);
        }
      } finally {
        out.closeSync();
      }
    } finally {
      raf.closeSync();
    }
  }

  // ---- 单文件下载（.part 断点续传 + 双源 + sha256 校验） ----

  static Future<void> _downloadOne(
    VoiceModelFile file, {
    required String dir,
    required void Function(int bytes) onFileProgress,
  }) async {
    Object? lastError;
    for (final url in file.urls) {
      try {
        await _downloadFrom(url, file, dir: dir, onFileProgress: onFileProgress);
        await _verify(file, dir);
        return;
      } on VoiceDownloadCancelled {
        rethrow;
      } catch (e) {
        lastError = e;
        debugPrint('[DSH][voice] ${file.path} ($url) error: $e');
      }
    }
    throw VoiceModelException('${file.path} 下载失败: $lastError');
  }

  static Future<void> _downloadFrom(
    String url,
    VoiceModelFile file, {
    required String dir,
    required void Function(int bytes) onFileProgress,
  }) async {
    final token = CancelToken();
    _tokens[file.path] = token;
    final partPath = p.join(dir, '${p.basename(file.path)}.part');
    final part = File(partPath);
    await Directory(p.dirname(partPath)).create(recursive: true);
    var have = part.existsSync() ? part.lengthSync() : 0;

    final raf = part.openSync(mode: have > 0 ? FileMode.append : FileMode.write);
    try {
      final resp = await _client.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: have > 0 ? {'Range': 'bytes=$have-'} : null,
          // 404/416 也走正常返回（交给换源逻辑），不抛。
          validateStatus: (s) => s != null && s >= 200 && s < 500,
        ),
      );
      final status = resp.statusCode ?? 0;
      if (status == 200) {
        raf.truncateSync(0); // 服务器不支持 Range：整段重下
        have = 0;
      } else if (status == 404) {
        throw VoiceModelException('源上没有这个文件（404）');
      } else if (status != 206) {
        throw VoiceModelException('HTTP $status');
      }
      final stream = resp.data!.stream;
      await for (final chunk in stream) {
        if (token.isCancelled) throw const VoiceDownloadCancelled();
        // chunk 类型 dio 侧声明 List<int>，writeFromSync 直接收（避免无谓转换）。
        raf.writeFromSync(chunk);
        have += chunk.length;
        onFileProgress(have);
      }
      raf.flushSync();
    } finally {
      raf.closeSync();
      _tokens.remove(file.path);
    }
    if (have <= 0) throw VoiceModelException('0 字节（源异常）');
    final target = File(p.join(dir, file.path));
    // 断点文件先落同名目标：目标已在 → rename 失败时直接覆盖写。
    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
  }

  /// 下载完校验：字节数（有则验）→ sha256（有则验）。不过就删文件抛异常，
  /// 外层自动换下一源重试。
  static Future<void> _verify(VoiceModelFile file, String dir) async {
    final target = File(p.join(dir, file.path));
    if (file.bytes != null && target.lengthSync() != file.bytes) {
      target.deleteSync();
      throw VoiceModelException('${file.path} 尺寸不符（${target.lengthSync()} ≠ ${file.bytes}）');
    }
    if (file.sha256 != null) {
      final digest = await crypto.sha256.bind(target.openRead()).first;
      final hex = digest.toString();
      if (hex != file.sha256) {
        target.deleteSync();
        throw VoiceModelException('${file.path} sha256 不符（$hex），文件已删，请重试');
      }
    }
  }
}

/// 下载被用户取消。
class VoiceDownloadCancelled implements Exception {
  const VoiceDownloadCancelled();
}

/// 下载/校验失败（message 面向用户，可直接展示）。
class VoiceModelException implements Exception {
  const VoiceModelException(this.message);
  final String message;

  @override
  String toString() => message;
}
