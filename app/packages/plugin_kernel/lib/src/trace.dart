/// 追踪与日志：每条都带 `traceId`，接进现成「推理日志」页（§4.16 可观测性）。
library;

enum TraceLevel { debug, info, warn, fail }

final class TraceRecord {
  TraceRecord({
    required this.traceId,
    required this.pluginId,
    required this.level,
    required this.message,
    Object? cause,
    DateTime? at,
  })  : cause = cause,
        at = at ?? DateTime.now();

  final String traceId;
  final String pluginId;
  final TraceLevel level;
  final String message;
  final Object? cause;
  final DateTime at;

  Map<String, Object?> toMap() => {
        'traceId': traceId,
        'plugin': pluginId,
        'level': level.name,
        'message': message,
        'at': at.toIso8601String(),
        if (cause != null) 'cause': '$cause',
      };

  @override
  String toString() => '[$traceId][$pluginId][${level.name}] $message';
}

/// 宿主实现它把日志导到自己的日志页/落盘。
abstract interface class TraceSink {
  void emit(TraceRecord record);
}

/// 内存环形缓冲（测试与面板"最近日志"用；上限防 OOM）。
class InMemoryTraceSink implements TraceSink {
  InMemoryTraceSink({this.capacity = 500});

  final int capacity;
  final List<TraceRecord> _records = [];

  @override
  void emit(TraceRecord r) {
    _records.add(r);
    if (_records.length > capacity) _records.removeRange(0, _records.length - capacity);
  }

  List<TraceRecord> get records => List.unmodifiable(_records);
  List<TraceRecord> forPlugin(String id) => _records.where((r) => r.pluginId == id).toList(growable: false);
  List<TraceRecord> byTrace(String traceId) => _records.where((r) => r.traceId == traceId).toList(growable: false);
  void clear() => _records.clear();
}

/// traceId 生成（一次插件会话一条，贯穿抽词/合成/播放/失败）。
class TraceIds {
  TraceIds({int Function()? random}) : _random = random ?? _defaultRandom;
  final int Function() _random;
  int _n = 0;

  static int _defaultRandom() => DateTime.now().microsecondsSinceEpoch % 100000;

  String next(String pluginId) {
    _n += 1;
    return 'p:${pluginId}:${_random().toString().padLeft(5, '0')}:$_n';
  }
}
