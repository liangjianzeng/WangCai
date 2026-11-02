import 'package:flutter_test/flutter_test.dart';
import 'package:edge_tts/edge_tts.dart';

void main() {
  test('Communicate validates rate parameter', () {
    expect(
      () => Communicate(text: 'hello', rate: 'bad'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('Communicate validates pitch parameter', () {
    expect(
      () => Communicate(text: 'hello', pitch: 'bad'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('Communicate accepts valid parameters', () {
    final comm = Communicate(
      text: 'Hello world',
      rate: '+50%',
      pitch: '-10Hz',
      volume: '+0%',
    );
    expect(comm.text, 'Hello world');
  });

  test('SubMaker generates SRT from word boundaries', () {
    final sub = SubMaker();
    sub.add(WordBoundaryEvent(offset: 0, duration: 5000000, text: 'Hello'));
    sub.add(WordBoundaryEvent(
        offset: 5000000, duration: 5000000, text: 'world'));

    final srt = sub.generateSrt();
    expect(srt, contains('1'));
    expect(srt, contains('Hello'));
    expect(srt, contains('world'));
    expect(srt, contains('-->'));
  });
}
