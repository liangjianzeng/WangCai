import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'constants.dart';
import 'drm.dart';
import 'http_client.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// Base class for TTS events emitted during synthesis.
sealed class TtsEvent {}

/// A [TtsEvent] containing a chunk of MP3 audio data.
///
/// These events are emitted by [Communicate.stream] as audio is synthesized.
/// Collect all chunks and concatenate them to get the complete MP3 file.
class AudioDataEvent extends TtsEvent {
  /// The raw MP3 audio bytes for this chunk.
  final Uint8List data;

  /// Creates an [AudioDataEvent] with the given MP3 audio [data].
  AudioDataEvent(this.data);
}

/// Word-level timing information.
class WordBoundaryEvent extends TtsEvent {
  /// Offset from the start of audio in 100-nanosecond intervals.
  final int offset;

  /// Duration in 100-nanosecond intervals.
  final int duration;

  /// The word text.
  final String text;

  WordBoundaryEvent({
    required this.offset,
    required this.duration,
    required this.text,
  });
}

/// Sentence-level timing information.
class SentenceBoundaryEvent extends TtsEvent {
  final int offset;
  final int duration;
  final String text;

  SentenceBoundaryEvent({
    required this.offset,
    required this.duration,
    required this.text,
  });
}

// ---------------------------------------------------------------------------
// Communicate
// ---------------------------------------------------------------------------

/// Synthesizes text to speech using Microsoft Edge's neural TTS service.
///
/// This is the main entry point for the package. Create an instance with the
/// text to synthesize and optional voice/prosody parameters, then call
/// [stream], [toBytes], or [save] to produce audio.
///
/// ```dart
/// final comm = Communicate(text: 'Hello world');
/// await for (final event in comm.stream()) {
///   if (event is AudioDataEvent) {
///     // event.data contains MP3 bytes
///   }
/// }
/// ```
class Communicate {
  /// The text to synthesize into speech.
  final String text;

  /// The voice to use for synthesis (e.g. `'en-US-EmmaMultilingualNeural'`).
  ///
  /// Defaults to [defaultVoice]. Use [VoicesManager] to discover available voices.
  final String voice;

  /// Speech rate adjustment, e.g. `'+0%'`, `'+50%'`, or `'-25%'`.
  final String rate;

  /// Pitch adjustment in Hertz, e.g. `'+0Hz'`, `'+10Hz'`, or `'-5Hz'`.
  final String pitch;

  /// Volume adjustment, e.g. `'+0%'`, `'+50%'`, or `'-25%'`.
  final String volume;

  /// Whether to emit [WordBoundaryEvent]s during synthesis.
  final bool wordBoundary;

  /// Whether to emit [SentenceBoundaryEvent]s during synthesis.
  final bool sentenceBoundary;

  /// Optional dialect locale（如 'zh-CN-sichuan'）：文本外包一层 SSML
  /// `<lang>` 元素，供方言能力音色选择口音（XiaoxiaoDialectsNeural）。
  final String? dialectLocale;

  /// Creates a [Communicate] instance for synthesizing [text] to speech.
  ///
  /// All prosody parameters ([rate], [pitch], [volume]) are validated on
  /// construction and will throw an [ArgumentError] if malformed.
  Communicate({
    required this.text,
    this.voice = defaultVoice,
    this.rate = '+0%',
    this.pitch = '+0Hz',
    this.volume = '+0%',
    this.wordBoundary = false,
    this.sentenceBoundary = false,
    this.dialectLocale,
  }) {
    _validateParam(rate, RegExp(r'^[+-]\d+%$'), 'rate');
    _validateParam(pitch, RegExp(r'^[+-]\d+Hz$'), 'pitch');
    _validateParam(volume, RegExp(r'^[+-]\d+%$'), 'volume');
  }

  static void _validateParam(String value, RegExp pattern, String name) {
    if (!pattern.hasMatch(value)) {
      throw ArgumentError('Invalid $name: "$value"');
    }
  }

  /// Streams [TtsEvent]s (audio data + optional boundary metadata).
  Stream<TtsEvent> stream() async* {
    final chunks = _splitText(text);
    int offsetComp = 0;

    for (final chunk in chunks) {
      int lastOffset = 0;
      int lastDuration = 0;

      await for (final event in _synthesizeChunk(chunk, offsetComp)) {
        if (event is WordBoundaryEvent) {
          lastOffset = event.offset;
          lastDuration = event.duration;
        } else if (event is SentenceBoundaryEvent) {
          lastOffset = event.offset;
          lastDuration = event.duration;
        }
        yield event;
      }

      offsetComp = lastOffset + lastDuration + offsetCompensationPadding;
    }
  }

  /// Collects all audio data and returns the complete MP3 as bytes.
  Future<Uint8List> toBytes() async {
    final builder = BytesBuilder(copy: false);
    await for (final event in stream()) {
      if (event is AudioDataEvent) {
        builder.add(event.data);
      }
    }
    return builder.toBytes();
  }

  /// Synthesizes and saves the audio to a file at [path].
  Future<void> save(String path) async {
    final bytes = await toBytes();
    await File(path).writeAsBytes(bytes);
  }

  // -------------------------------------------------------------------------
  // WebSocket synthesis for a single chunk
  // -------------------------------------------------------------------------

  Stream<TtsEvent> _synthesizeChunk(
    String chunk,
    int offsetComp, {
    int retryCount = 0,
  }) async* {
    // Calibrate clock on first attempt to avoid 403
    if (retryCount == 0) {
      await _calibrateClock();
    }

    final connectionId = generateUuidHex();
    final requestId = generateUuidHex();
    final gec = generateSecMsGec();
    final muid = generateMuid();

    final wsUrlString = '$wssUrl?TrustedClientToken=$trustedClientToken'
        '&ConnectionId=$connectionId'
        '&Sec-MS-GEC=$gec'
        '&Sec-MS-GEC-Version=$secMsGecVersion';

    WebSocket ws;
    try {
      // 自定义 HttpClient：无默认 UA（防 dart:io 追加 "Dart/x.x (dart:io)"），
      // 且 IPv4 优先——IPv6 半死通道 TCP 连得上、TLS 被 RST，而 dart:io 在 TLS
      // 阶段失败不会自动换下一个地址。
      final httpClient = createTtsHttpClient();
      ws = await WebSocket.connect(
        wsUrlString,
        headers: {
          ...wssHeaders,
          'Cookie': 'muid=$muid;',
        },
        compression: CompressionOptions.compressionDefault,
        customClient: httpClient,
      );
    } catch (e) {
      // Possibly a 403 due to clock skew — correct and retry.
      if (retryCount < 3) {
        await _calibrateClock(force: true);
        yield* _synthesizeChunk(chunk, offsetComp, retryCount: retryCount + 1);
        return;
      }
      rethrow;
    }

    // -- Send speech.config --
    final timestamp = generateTimestamp();
    final configMsg = 'X-Timestamp:$timestamp\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n'
        '\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"$sentenceBoundary",'
        '"wordBoundaryEnabled":"$wordBoundary"}'
        ',"outputFormat":"$audioFormat"}}}}';
    ws.add(configMsg);

    // -- Send SSML --
    final ssml = _buildSsml(chunk, voice, rate, pitch, volume,
        dialectLocale: dialectLocale);
    final ssmlMsg = 'X-RequestId:$requestId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${timestamp}Z\r\n'
        'Path:ssml\r\n'
        '\r\n'
        '$ssml';
    ws.add(ssmlMsg);

    // -- Receive responses --
    try {
      await for (final message in ws) {
        if (message is String) {
          final events = _handleTextMessage(message, offsetComp);
          if (events == null) break; // turn.end
          for (final event in events) {
            yield event;
          }
        } else if (message is List<int>) {
          final event = _handleBinaryMessage(Uint8List.fromList(message));
          if (event != null) yield event;
        }
      }
    } finally {
      await ws.close();
    }
  }

  /// Returns null to signal turn.end (stop listening).
  List<TtsEvent>? _handleTextMessage(String message, int offsetComp) {
    final sepIdx = message.indexOf('\r\n\r\n');
    if (sepIdx == -1) return const [];

    final headers = message.substring(0, sepIdx);
    final body = message.substring(sepIdx + 4);

    if (headers.contains('Path:turn.end')) return null;

    if (headers.contains('Path:audio.metadata')) {
      final metadata = json.decode(body) as Map<String, dynamic>;
      final items = metadata['Metadata'] as List<dynamic>;
      final events = <TtsEvent>[];

      for (final item in items) {
        final type = item['Type'] as String;
        final data = item['Data'] as Map<String, dynamic>;

        if (type == 'WordBoundary') {
          events.add(WordBoundaryEvent(
            offset: (data['Offset'] as int) + offsetComp,
            duration: data['Duration'] as int,
            text: (data['text'] as Map<String, dynamic>)['Text'] as String,
          ));
        } else if (type == 'SentenceBoundary') {
          events.add(SentenceBoundaryEvent(
            offset: (data['Offset'] as int) + offsetComp,
            duration: data['Duration'] as int,
            text: (data['text'] as Map<String, dynamic>)['Text'] as String,
          ));
        }
      }
      return events;
    }

    return const [];
  }

  AudioDataEvent? _handleBinaryMessage(Uint8List data) {
    if (data.length < 2) return null;

    final headerLength = (data[0] << 8) | data[1];
    final headerBytes = data.sublist(2, 2 + headerLength);
    final headerText = utf8.decode(headerBytes);

    // Termination signal: Path:audio present but no Content-Type
    if (!headerText.contains('Content-Type:audio/mpeg')) return null;

    final audioStart = 2 + headerLength;
    if (audioStart >= data.length) return null;

    return AudioDataEvent(data.sublist(audioStart));
  }

  static bool _clockCalibrated = false;

  /// Fetches the server time via a GET request to calibrate the clock.
  /// This ensures the Sec-MS-GEC token is valid before WebSocket connection.
  Future<void> _calibrateClock({bool force = false}) async {
    if (_clockCalibrated && !force) return;

    final client = createTtsHttpClient();
    try {
      // Use the voice list endpoint — we know it responds
      final gec = generateSecMsGec();
      final url = Uri.parse(
        '$voiceListUrl?trustedclienttoken=$trustedClientToken'
        '&Sec-MS-GEC=$gec'
        '&Sec-MS-GEC-Version=$secMsGecVersion',
      );
      final request = await client.getUrl(url);
      voiceHeaders.forEach((key, value) {
        request.headers.set(key, value);
      });
      request.headers.set('Cookie', 'muid=${generateMuid()};');

      final response = await request.close();
      final serverDate = response.headers.value('date');
      if (serverDate != null) {
        updateClockSkew(serverDate);
      }
      await response.drain<void>();
      _clockCalibrated = true;
    } catch (_) {
      // Best-effort clock correction
    } finally {
      client.close();
    }
  }

  // -------------------------------------------------------------------------
  // Text processing
  // -------------------------------------------------------------------------

  /// Splits text into chunks of at most [maxChunkSize] bytes.
  static List<String> _splitText(String text) {
    // Remove incompatible control characters
    text = text.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), ' ');

    if (utf8.encode(text).length <= maxChunkSize) return [text];

    final chunks = <String>[];
    var remaining = text;

    while (remaining.isNotEmpty) {
      if (utf8.encode(remaining).length <= maxChunkSize) {
        chunks.add(remaining);
        break;
      }

      // Find the best split point within maxChunkSize bytes
      var splitAt = _findSplitPoint(remaining);
      chunks.add(remaining.substring(0, splitAt));
      remaining = remaining.substring(splitAt);
    }

    return chunks;
  }

  /// Finds the best split point in [text] such that the resulting byte length
  /// is ≤ [maxChunkSize]. Prefers newlines, then spaces.
  static int _findSplitPoint(String text) {
    // Binary search for the character index whose UTF-8 encoding fits
    int lo = 0, hi = text.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (utf8.encode(text.substring(0, mid)).length <= maxChunkSize) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    // lo is the max number of characters that fit

    final candidate = text.substring(0, lo);

    // Prefer splitting at newline
    final lastNewline = candidate.lastIndexOf('\n');
    if (lastNewline > 0) return lastNewline + 1;

    // Prefer splitting at space
    final lastSpace = candidate.lastIndexOf(' ');
    if (lastSpace > 0) return lastSpace + 1;

    // No good boundary — split at character limit
    return lo;
  }

  // -------------------------------------------------------------------------
  // SSML
  // -------------------------------------------------------------------------

  static String _buildSsml(
    String text,
    String voice,
    String rate,
    String pitch,
    String volume, {
    String? dialectLocale,
  }) {
    final longName = _voiceShortToLong(voice);
    final escaped = _xmlEscape(text);
    // 方言音色：文本包 <lang> 元素选择口音（Azure XiaoxiaoDialectsNeural）。
    final body = dialectLocale == null || dialectLocale.isEmpty
        ? escaped
        : "<lang xml:lang='$dialectLocale'>$escaped</lang>";
    return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='en-US'>"
        "<voice name='$longName'>"
        "<prosody pitch='$pitch' rate='$rate' volume='$volume'>"
        '$body'
        '</prosody></voice></speak>';
  }

  static String _voiceShortToLong(String shortName) {
    // 区域变体音色（zh-CN-liaoning-XiaobeiNeural 等）的 locale 是多段的，
    // 不能按前两段切分——否则服务端不认 voice 名、返回空音频。规范：
    // 末段 = voice 名，其余整体 = locale。
    if (shortName.endsWith('Neural')) {
      final idx = shortName.lastIndexOf('-');
      if (idx > 0) {
        return 'Microsoft Server Speech Text to Speech Voice '
            '(${shortName.substring(0, idx)}, ${shortName.substring(idx + 1)})';
      }
    }
    return shortName;
  }

  static String _xmlEscape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
