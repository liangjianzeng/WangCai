import 'communicate.dart';

/// Collects boundary events and generates SRT subtitles.
class SubMaker {
  final List<_Sub> _subs = [];

  /// Feed a [WordBoundaryEvent] or [SentenceBoundaryEvent] from [Communicate.stream].
  void add(TtsEvent event) {
    if (event is WordBoundaryEvent) {
      _subs.add(_Sub(
        offset: event.offset,
        duration: event.duration,
        text: event.text,
      ));
    } else if (event is SentenceBoundaryEvent) {
      _subs.add(_Sub(
        offset: event.offset,
        duration: event.duration,
        text: event.text,
      ));
    }
  }

  /// Generates an SRT-formatted subtitle string from collected events.
  String generateSrt() {
    if (_subs.isEmpty) return '';

    final buffer = StringBuffer();
    for (var i = 0; i < _subs.length; i++) {
      final sub = _subs[i];
      final start = _formatSrtTime(sub.offset);
      final end = _formatSrtTime(sub.offset + sub.duration);
      buffer.writeln('${i + 1}');
      buffer.writeln('$start --> $end');
      buffer.writeln(sub.text);
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// Formats a duration in 100-nanosecond intervals to SRT time format.
  /// "HH:MM:SS,mmm"
  static String _formatSrtTime(int ticks100ns) {
    // Convert 100-nanosecond intervals to microseconds
    final microseconds = ticks100ns ~/ 10;
    final d = Duration(microseconds: microseconds);

    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (d.inMilliseconds % 1000).toString().padLeft(3, '0');

    return '$hours:$minutes:$seconds,$millis';
  }
}

class _Sub {
  final int offset;
  final int duration;
  final String text;

  _Sub({required this.offset, required this.duration, required this.text});
}
