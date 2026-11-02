// ignore_for_file: avoid_print

import 'dart:io';

import 'package:edge_tts/edge_tts.dart';

/// Demonstrates the main features of the edge_tts package.
void main() async {
  // -----------------------------------------------------------------------
  // 1. Basic text-to-speech — save directly to an MP3 file
  // -----------------------------------------------------------------------
  print('=== Basic TTS ===');
  final tts = Communicate(text: 'Hello! This is a text-to-speech example.');
  await tts.save('basic_output.mp3');
  print('Saved basic_output.mp3');

  // -----------------------------------------------------------------------
  // 2. Customize voice, rate, pitch, and volume
  // -----------------------------------------------------------------------
  print('\n=== Custom voice & prosody ===');
  final custom = Communicate(
    text: 'This is spoken with a custom voice and adjusted pitch.',
    voice: 'en-US-GuyNeural',
    rate: '+10%',
    pitch: '+5Hz',
    volume: '+0%',
  );
  await custom.save('custom_output.mp3');
  print('Saved custom_output.mp3');

  // -----------------------------------------------------------------------
  // 3. Streaming — process audio chunks as they arrive
  // -----------------------------------------------------------------------
  print('\n=== Streaming audio ===');
  final streamer = Communicate(
    text: 'Streaming audio is useful for real-time playback.',
    wordBoundary: true,
  );

  final sink = File('streamed_output.mp3').openWrite();
  await for (final event in streamer.stream()) {
    if (event is AudioDataEvent) {
      sink.add(event.data);
    } else if (event is WordBoundaryEvent) {
      print('  Word: "${event.text}" at offset ${event.offset}');
    }
  }
  await sink.close();
  print('Saved streamed_output.mp3');

  // -----------------------------------------------------------------------
  // 4. Generate SRT subtitles
  // -----------------------------------------------------------------------
  print('\n=== SRT subtitle generation ===');
  final subTts = Communicate(
    text: 'Subtitles can be generated alongside the audio.',
    wordBoundary: true,
  );
  final subMaker = SubMaker();

  await for (final event in subTts.stream()) {
    subMaker.add(event);
  }
  final srt = subMaker.generateSrt();
  print('Generated SRT:\n$srt');

  // -----------------------------------------------------------------------
  // 5. List and filter available voices
  // -----------------------------------------------------------------------
  print('=== Voice listing ===');
  final manager = await VoicesManager.create();
  final englishVoices = manager.find(language: 'en');
  print('Found ${englishVoices.length} English voices. First 5:');
  for (final voice in englishVoices.take(5)) {
    print('  ${voice.shortName} (${voice.gender}, ${voice.locale})');
  }
}
