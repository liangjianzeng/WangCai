/// Edge 在线 TTS 服务（免费 neural 语音，无需 API key）。
///
/// 协议：`wss://speech.platform.bing.com`（Edge 浏览器"大声朗读"接口），
/// 鉴权 = 本地可算的 Sec-MS-GEC token（vendored edge_tts 包内置，含时钟
/// 偏差自动校正）。合成结果 mp3 落缓存目录，按 (文本+音色+参数) 哈希复用。
///
/// 播放：audioplayers 播本地 mp3；长回复按句分段逐段合成逐段播放
/// （不等整篇合成完才出声）。任一时刻只有一个播报任务：新请求/stop()
/// 会取消当前任务（代次计数防旧任务回写状态）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:edge_tts/edge_tts.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tts_text.dart';

/// 供 UI 直接展示的音色条目（解耦 edge_tts 的 Voice 类）。
class TtsVoiceInfo {
  final String shortName;
  final String localName;
  final String locale;
  final String gender;

  const TtsVoiceInfo({
    required this.shortName,
    required this.localName,
    required this.locale,
    required this.gender,
  });

  String get displayLabel => '$localName（${locale}）';
}

/// 音色保留地区（大陆/港/台/美/英），[order] 决定下拉分区顺序。
class TtsVoiceRegion {
  final int order;
  final String label;
  const TtsVoiceRegion(this.order, this.label);

  /// locale → 保留地区；null = 不保留（其余语言/地区全部过滤）。
  /// zh-CN 含方言变体（liaoning/shaanxi），同属大陆。
  static TtsVoiceRegion? of(String locale) {
    if (locale.startsWith('zh-CN')) return const TtsVoiceRegion(0, '中国大陆');
    if (locale.startsWith('zh-HK')) return const TtsVoiceRegion(1, '中国香港');
    if (locale.startsWith('zh-TW')) return const TtsVoiceRegion(2, '中国台湾');
    if (locale.startsWith('en-US')) return const TtsVoiceRegion(3, '英语（美国）');
    if (locale.startsWith('en-GB')) return const TtsVoiceRegion(4, '英语（英国）');
    return null;
  }
}

/// 下拉分组条目：地区 · 性别 标题 + 该组音色（组内按 shortName 排序）。
class TtsVoiceGroup {
  final String title;
  final List<TtsVoiceInfo> voices;
  const TtsVoiceGroup(this.title, this.voices);
}

/// 只保留 大陆/港/台/美/英 音色，按地区顺序分区、区内男先女后。
List<TtsVoiceGroup> groupTtsVoices(List<TtsVoiceInfo> all) {
  int genderOrder(String g) => g == 'Male' ? 0 : 1;
  final kept = [...all]..removeWhere((v) => TtsVoiceRegion.of(v.locale) == null);
  kept.sort((a, b) {
    final ra = TtsVoiceRegion.of(a.locale)!;
    final rb = TtsVoiceRegion.of(b.locale)!;
    if (ra.order != rb.order) return ra.order - rb.order;
    final ga = genderOrder(a.gender);
    final gb = genderOrder(b.gender);
    if (ga != gb) return ga - gb;
    return a.shortName.compareTo(b.shortName);
  });
  final groups = <TtsVoiceGroup>[];
  for (final v in kept) {
    final region = TtsVoiceRegion.of(v.locale)!;
    final title = '${region.label} · ${v.gender == 'Male' ? '男' : '女'}';
    if (groups.isEmpty || groups.last.title != title) {
      groups.add(TtsVoiceGroup(title, [v]));
    } else {
      groups.last.voices.add(v);
    }
  }
  return groups;
}

/// 网络不可达时音色下拉的兜底清单（常用 zh 系；拉取成功后会被覆盖）。
const List<TtsVoiceInfo> kFallbackVoices = [
  TtsVoiceInfo(
      shortName: 'zh-CN-XiaoxiaoNeural',
      localName: '晓晓',
      locale: 'zh-CN',
      gender: 'Female'),
  TtsVoiceInfo(
      shortName: 'zh-CN-XiaoyiNeural',
      localName: '晓伊',
      locale: 'zh-CN',
      gender: 'Female'),
  TtsVoiceInfo(
      shortName: 'zh-CN-YunxiNeural',
      localName: '云希',
      locale: 'zh-CN',
      gender: 'Male'),
  TtsVoiceInfo(
      shortName: 'zh-CN-YunyangNeural',
      localName: '云扬',
      locale: 'zh-CN',
      gender: 'Male'),
  TtsVoiceInfo(
      shortName: 'zh-CN-YunjianNeural',
      localName: '云健',
      locale: 'zh-CN',
      gender: 'Male'),
  TtsVoiceInfo(
      shortName: 'zh-CN-YunxiaNeural',
      localName: '云夏',
      locale: 'zh-CN',
      gender: 'Male'),
  TtsVoiceInfo(
      shortName: 'zh-CN-liaoning-XiaobeiNeural',
      localName: '小北（辽宁）',
      locale: 'zh-CN-liaoning',
      gender: 'Female'),
  TtsVoiceInfo(
      shortName: 'zh-CN-shaanxi-XiaoniNeural',
      localName: '小妮（陕西）',
      locale: 'zh-CN-shaanxi',
      gender: 'Female'),
];

/// 播报失败的分类（供 UI 给一句人话，不再"点了没反应"）。
enum TtsFailureKind {
  /// 服务端拒绝（401/403）：多为 Sec-MS-GEC token 失效——微软 2026-10-10 起
  /// 强制 v2 token，vendored edge_tts 停在 v1 时全站 403。
  denied,

  /// 连不上/超时：网络不通或被墙。
  network,

  /// 服务端返回空音频：常见于「英文音色读中文」这类音色与文本语言不匹配。
  empty,

  /// 本地播放器出错。
  playback,

  /// 其它。
  unknown,
}

/// 一次播报失败：[kind] 分类 + [message] 用户可读文案。
class TtsFailure {
  final TtsFailureKind kind;
  final String message;
  const TtsFailure(this.kind, this.message);

  @override
  String toString() => '${kind.name}: $message';
}

/// 把底层异常分类成用户可读原因（纯函数，单测钉死）。
TtsFailure classifyTtsError(Object error) {
  final s = error.toString();
  if (s.contains('403') || s.contains('401')) {
    return const TtsFailure(TtsFailureKind.denied,
        '语音服务拒绝了请求（鉴权 token 失效，需升级内置 edge_tts）');
  }
  if (error is TimeoutException) {
    return const TtsFailure(TtsFailureKind.network, '语音合成超时，请检查网络后重试');
  }
  if (s.contains('SocketException') ||
      s.contains('Failed host lookup') ||
      s.contains('Connection refused')) {
    return const TtsFailure(TtsFailureKind.network, '连不上语音服务，请检查网络');
  }
  return TtsFailure(TtsFailureKind.unknown, '语音合成失败：$s');
}

class EdgeTtsService {
  EdgeTtsService._();  static final EdgeTtsService instance = EdgeTtsService._();

  final AudioPlayer _player = AudioPlayer();

  /// 代次计数：每次 speak/stop 递增；旧任务的循环发现代次不对即退出。
  int _seq = 0;

  /// 当前正在播报的任务 key（消息 id 或试听标识）；null = 空闲。
  final ValueNotifier<String?> playingKey = ValueNotifier(null);

  /// 正在等 onPlayerComplete 的等待者（stop 时必须当场放掉，见 [stop]）。
  Completer<void>? _playWaiter;

  bool get isPlaying => playingKey.value != null;

  /// 最近一次播报的失败原因（成功/被用户停止 = null）。
  ///
  /// 合成失败过去只 debugPrint，用户侧表现是「点了 🔊 什么也没发生」——
  /// 2026-10 微软强制 Sec-MS-GEC v2 造成全站 403 时，整整哑了两天无人察觉。
  /// 故失败必须留痕并让 UI 可提示（自动播报仍不打断聊天，只在手动点按时提示）。
  TtsFailure? _lastFailure;
  TtsFailure? get lastFailure => _lastFailure;
  String? get lastError => _lastFailure?.message;

  // ---- 音色列表（30 分钟缓存）----

  List<TtsVoiceInfo>? _voicesCache;
  DateTime _voicesAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<List<TtsVoiceInfo>> listVoices() async {
    final now = DateTime.now();
    if (_voicesCache != null && now.difference(_voicesAt).inMinutes < 30) {
      return _voicesCache!;
    }
    try {
      final manager = await VoicesManager.create().timeout(const Duration(
          seconds: 15));
      final all = manager.voices
          .map((v) => TtsVoiceInfo(
                shortName: v.shortName,
                localName: _extractLocalName(v.friendlyName, v.shortName),
                locale: v.locale,
                gender: v.gender,
              ))
          .toList();
      // 只留 大陆/港/台/美/英，按地区顺序 + 性别分区（其余语言全部过滤）。
      all.removeWhere((v) => TtsVoiceRegion.of(v.locale) == null);
      all.sort((a, b) {
        final ra = TtsVoiceRegion.of(a.locale)!;
        final rb = TtsVoiceRegion.of(b.locale)!;
        if (ra.order != rb.order) return ra.order - rb.order;
        final ga = a.gender == 'Male' ? 0 : 1;
        final gb = b.gender == 'Male' ? 0 : 1;
        if (ga != gb) return ga - gb;
        return a.shortName.compareTo(b.shortName);
      });
      _voicesCache = all;
      _voicesAt = now;
      return all;
    } catch (e) {
      debugPrint('[EdgeTts] 音色列表拉取失败，用兜底清单: $e');
      return kFallbackVoices;
    }
  }

  static String _extractLocalName(String friendlyName, String shortName) {
    // FriendlyName 形如 "Microsoft Xiaoxiao Online (Natural) - Chinese
    // (Mandarin, Simplified)"；本地名没有直接字段，取 shortName 里
    // Neural 前段（XiaoxiaoNeural → Xiaoxiao）作为展示名。
    final m = RegExp(r'([A-Za-z]+)Neural$').firstMatch(shortName);
    return m?.group(1) ?? shortName;
  }

  // ---- 合成 ----

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'tts_cache'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _cacheKey(String text, String voice, int rate, int pitch,
          int volume) =>
      sha256.convert(utf8.encode('$voice|$rate|$pitch|$volume|$text'))
          .toString();

  /// 合成一段文本到缓存文件；失败返回 null（调用方静默降级）。
  Future<File?> _synthesize(String text,
      {required String voice,
      required int rate,
      required int pitch,
      required int volume}) async {
    try {
      final comm = Communicate(
        text: text,
        voice: voice,
        rate: _signed(rate, '%'),
        pitch: _signed(pitch, 'Hz'),
        volume: _signed(volume, '%'),
      );
      final bytes = await comm.toBytes().timeout(const Duration(seconds: 60));
      if (bytes.isEmpty) {
        _lastFailure = const TtsFailure(TtsFailureKind.empty,
            '该音色对这段文本没有返回音频（英文音色读中文常见，换 Multilingual 或中文音色）');
        debugPrint('[EdgeTts] 合成返回空音频 voice=$voice');
        return null;
      }
      final dir = await _cacheDir();
      final file = File(p.join(
          dir.path,
          '${_cacheKey(text, voice, rate, pitch, volume)}.mp3'));
      await file.writeAsBytes(bytes);
      return file;
    } catch (e) {
      _lastFailure = classifyTtsError(e);
      debugPrint('[EdgeTts] 合成失败: $e');
      return null;
    }
  }

  static String _signed(int v, String unit) =>
      '${v >= 0 ? '+' : ''}$v$unit';

  // ---- 播报 ----

  /// 朗读 [text]（先清洗再分段）。[key] 标识播报来源（消息 id / 'preview'），
  /// UI 通过 [playingKey] 显示播放态并支持再次点按停止。
  /// 返回 true = 完整播完；false = 被停止/取消或合成失败。
  Future<bool> speak(
    String rawText, {
    String key = 'preview',
    required String voice,
    required int rate,
    required int pitch,
    required int volume,
  }) async {
    final text = cleanTextForTts(rawText);
    if (text.isEmpty) return false;
    if (isPlaying && playingKey.value == key) {
      // 同一按钮再点 = 停止。
      await stop();
      return false;
    }
    await stop();
    _lastFailure = null; // 新一轮播报：清掉上一次的失败痕迹
    final seq = ++_seq;
    playingKey.value = key;
    try {
      final segments = segmentForTts(text);
      for (var i = 0; i < segments.length; i++) {
        if (seq != _seq) return false;
        final file = await _synthesize(segments[i],
            voice: voice, rate: rate, pitch: pitch, volume: volume);
        if (seq != _seq) return false;
        if (file == null) return false;
        await _playFile(file, seq);
      }
      return true;
    } finally {
      if (seq == _seq) playingKey.value = null;
    }
  }

  /// 停止当前播报（若有）：代次递增让后台循环退出 + 停掉播放器。
  ///
  /// 必须**同时释放正在等播放结束的等待者**：audioplayers 被 stop 后不一定再发
  /// onPlayerComplete，`_playFile` 就会一直等到 10 分钟超时——用户按了停止，
  /// 插件那一侧还挂着（听写场景表现为"停了但下一条马上又冒出来"）。
  Future<void> stop() async {
    _seq++;
    if (playingKey.value != null) playingKey.value = null;
    final waiter = _playWaiter;
    _playWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    try {
      await _player.stop();
    } catch (_) {}
  }

  // ---- 通用播放原语（插件平台按条播用；聊天侧的 speak() 仍走上面那条路）----

  /// 开始一场外部驱动的逐条播报，返回本场代次。
  ///
  /// 与 [speak] 的区别：调用方**自己掌握节奏**（逐条合成→播→等间隔），
  /// 但代次、唯一播报位、失败留痕仍然由本服务统一管，界面上因此依然
  /// "同时最多一个 spinner"。
  Future<int> beginPlayback(String key) async {
    await stop();
    _lastFailure = null;
    final seq = ++_seq;
    playingKey.value = key;
    return seq;
  }

  /// 本场是否仍是当前播报（被新的播报或 stop() 顶掉 → false，调用方应立即收工）。
  bool isCurrentPlayback(int seq) => seq == _seq;

  /// 结束一场播报（幂等；代次不符时什么都不做，避免误清新的播报位）。
  void endPlayback(int seq) {
    if (seq == _seq) playingKey.value = null;
  }

  /// 合成一段文本，**先查缓存**：命中就直接给文件，不再联网。
  ///
  /// `_synthesize` 过去只写不读，同一批词被反复听写就反复打微软接口——
  /// 慢（1s+/词）且撞 403 限流，"听写第 3 遍特别慢"是这么来的。
  Future<File?> synthesizeCached(
    String text, {
    required String voice,
    required int rate,
    required int pitch,
    required int volume,
  }) async {
    if (text.trim().isEmpty) return null;
    final dir = await _cacheDir();
    final cached = File(p.join(
        dir.path, '${_cacheKey(text, voice, rate, pitch, volume)}.mp3'));
    try {
      if (cached.existsSync() && cached.lengthSync() > 0) return cached;
    } catch (_) {}
    return _synthesize(text, voice: voice, rate: rate, pitch: pitch, volume: volume);
  }

  /// 播一个已合成好的文件直到结束；被顶掉/停止 → false（不当作失败）。
  Future<bool> playCached(int seq, File file) async {
    if (seq != _seq) return false;
    await _playFile(file, seq);
    return seq == _seq;
  }

  /// 播放一个本地文件直到结束（代次不符 → 立即返回不播）。
  ///
  /// audioplayers 6.x 的播放错误直接从 play() 抛出（await 捕获即可）。
  Future<void> _playFile(File file, int seq) async {
    final completer = Completer<void>();
    _playWaiter = completer; // stop() 靠它把等待中的循环当场放掉
    late final StreamSubscription<void> sub;
    sub = _player.onPlayerComplete.listen((_) {
      sub.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    try {
      if (seq != _seq) return;
      await _player.play(DeviceFileSource(file.path));
      await completer.future.timeout(const Duration(minutes: 10),
          onTimeout: () {});
    } catch (e) {
      // 用户 stop() 引发的播放异常不算失败（seq 已作废）。
      if (seq == _seq) {
        _lastFailure ??= const TtsFailure(TtsFailureKind.playback, '音频播放失败');
      }
      debugPrint('[EdgeTts] play 异常: $e');
    } finally {
      await sub.cancel();
    }
  }

  /// 清空缓存目录（超出龄的 mp3 文件）；返回删除的文件数。
  Future<int> clearCache() async {
    try {
      final dir = await _cacheDir();
      var n = 0;
      await for (final f in dir.list()) {
        if (f is File) {
          await f.delete();
          n++;
        }
      }
      return n;
    } catch (_) {
      return 0;
    }
  }
}
