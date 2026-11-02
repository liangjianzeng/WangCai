# edge_tts

A Flutter/Dart package for using Microsoft Edge's free neural text-to-speech voices. No API key required. Works on Android and iOS.

## Features

- 100+ high-quality neural voices across many languages
- Streaming MP3 audio via WebSocket
- Rate, pitch, and volume control
- Word and sentence boundary timing events
- SRT subtitle generation
- Automatic text chunking for long texts

## Getting started

Add to your `pubspec.yaml`:

```yaml
dependencies:
  edge_tts: ^0.1.0
```

## Usage

### List available voices

```dart
import 'package:edge_tts/edge_tts.dart';

final voices = await listVoices();
for (final voice in voices) {
  print('${voice.shortName} (${voice.gender}, ${voice.locale})');
}
```

### Filter voices

```dart
final manager = await VoicesManager.create();
final hindiVoices = manager.find(locale: 'hi-IN', gender: 'Female');
```

### Synthesize speech (streaming)

```dart
final tts = Communicate(
  text: 'Hello, world!',
  voice: 'en-US-EmmaMultilingualNeural',
  rate: '+0%',
  pitch: '+0Hz',
  volume: '+0%',
);

await for (final event in tts.stream()) {
  if (event is AudioDataEvent) {
    // event.data contains MP3 bytes
  }
}
```

### Save to file

```dart
await tts.save('/path/to/output.mp3');
```

### Get all audio bytes

```dart
final bytes = await tts.toBytes();
```

### Generate subtitles

```dart
final tts = Communicate(
  text: 'Hello, world!',
  wordBoundary: true,
);

final sub = SubMaker();
await for (final event in tts.stream()) {
  sub.add(event);
}
print(sub.generateSrt());
```

## Additional information

- [GitHub Repository](https://github.com/iam-kanav/edge-tts-flutter)
- Based on the Python [edge-tts](https://github.com/rany2/edge-tts) package
- File issues on [GitHub Issues](https://github.com/iam-kanav/edge-tts-flutter/issues)
