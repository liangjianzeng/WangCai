/// A Dart package for text-to-speech synthesis using Microsoft Edge's free
/// neural TTS voices.
///
/// No API key is required. Supports 400+ neural voices across 100+ languages,
/// streaming MP3 audio, word/sentence boundary events, and SRT subtitle
/// generation.
///
/// ## Quick start
///
/// ```dart
/// import 'package:edge_tts/edge_tts.dart';
///
/// final tts = Communicate(text: 'Hello, world!');
/// await tts.save('output.mp3');
/// ```
///
/// See [Communicate] for the main entry point, [VoicesManager] for listing
/// available voices, and [SubMaker] for generating subtitles.
library;

export 'src/communicate.dart';
export 'src/http_client.dart';
export 'src/submaker.dart';
export 'src/voices.dart';
