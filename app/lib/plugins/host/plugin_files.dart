/// 插件平台的宿主落盘（P2）：两个原子 JSON 文件装下「启用集」与「插件 KV」。
///
/// 为什么不塞进 `inference_settings.json`：那是个单一大 blob，改插件开关会惊动整个设置页的
/// revision；插件数据混进去还会让设置导出里塞满听写词表。各自一个文件，坏了互不影响。
///
/// 写法照抄 `SettingsService.save`：**先写 `.tmp` 再 rename**（同目录 rename 是原子操作，
/// 断电/崩溃的损坏面收敛为「完整旧文件或完整新文件」，不会留下半截 JSON）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:path_provider/path_provider.dart';

/// 一个 `Map<String, Object?>` 的 JSON 文件（内存缓存 + 串行原子写）。
///
/// **对象是轻把手，真正的状态（缓存 + 写队列）按"解析后的路径"共享**：
/// 同一份 JSON 被两个 `JsonMapFile` 各持一份缓存/队列时，两次"读-改-写"会各自从旧快照出发，
/// 后落盘的那个把自己那份整包刷回磁盘，**先写的键就这么被洗掉**。
/// 这不是假想病：启用集（`plugin.enabled`）与首次播种账本（`plugin.seen`）同住
/// `plugin_enabled.json`，两个宿主对象同时写它就复现了。文件才是真相，缓存与队列都该跟着文件走。
class JsonMapFile {
  JsonMapFile(this.fileName);

  final String fileName;

  static final Map<String, _JsonFileState> _states = {};

  Future<String> _path() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, fileName);
  }

  Future<_JsonFileState> _state() async {
    final path = await _path();
    return _states.putIfAbsent(path, () => _JsonFileState(path));
  }

  Future<Map<String, Object?>> read() async => (await _state()).read();

  /// 改一份数据并落盘。读-改-写整体排在**该文件的写队列**里，所以两个写者不会互相覆盖。
  Future<void> mutate(FutureOr<void> Function(Map<String, Object?> data) change) async =>
      (await _state()).mutate(change);

  /// 等排队的写真的落盘（测试与"退出前收尾"用；`write()` 这类同步 API 是 fire-and-forget 的）。
  Future<void> flush() async => (await _state()).flush();

  Future<void> invalidate() async => (await _state()).invalidate();
}

/// 单个文件的真实状态：一份缓存 + 一条串行写队列。
final class _JsonFileState {
  _JsonFileState(this.path);

  final String path;
  Map<String, Object?>? _cache;
  Future<void> _tail = Future<void>.value();

  Future<Map<String, Object?>> read() async {
    final hit = _cache;
    if (hit != null) return hit;
    try {
      final file = File(path);
      if (!await file.exists()) return _cache = <String, Object?>{};
      final text = await file.readAsString();
      if (text.trim().isEmpty) return _cache = <String, Object?>{};
      final decoded = jsonDecode(text);
      if (decoded is! Map) return _cache = <String, Object?>{};
      return _cache = Map<String, Object?>.from(decoded);
    } catch (_) {
      // 坏文件当空的用（能自愈），但下一次写会覆盖它 —— 所以读侧绝不让异常冒到 UI。
      return _cache = <String, Object?>{};
    }
  }

  Future<void> mutate(FutureOr<void> Function(Map<String, Object?> data) change) {
    final next = _tail.then((_) async {
      // **在队列里才取快照**：排在后面的人看得见前面人的结果。
      final data = Map<String, Object?>.of(await read());
      await change(data);
      _cache = data;
      final tmp = File('$path.tmp');
      await tmp.writeAsString(jsonEncode(data));
      await tmp.rename(path);
    });
    _tail = next.catchError((_) {}); // 队列不被单次失败卡死
    return next;
  }

  Future<void> flush() => _tail;

  void invalidate() => _cache = null;
}

/// `app.store` 的宿主实现。
///
/// 键的 `plugin:<id>:` 前缀由**平台**在 `ctx.capabilities.require` 时加
/// （内核 `_NamespacedStore`）—— 作者只写 `'words'`，落盘是 `'plugin:english-dictation:words'`，
/// 忘拼前缀也读不到别人的数据。
final class FileStore with CapabilityBase implements Store {
  FileStore(this._file);

  final JsonMapFile _file;

  @override
  final ServiceKey key = const ServiceKey<Store>('app.store');

  @override
  bool get available => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<Outcome<String?>> read(String key) => Outcome.guard<String?>(() async {
        final v = (await _file.read())[key];
        if (v == null) return null;
        return v is String ? v : jsonEncode(v);
      });

  @override
  Future<Outcome<void>> write(String key, String value) => Outcome.guard<void>(() async {
        await _file.mutate((data) => data[key] = value);
      });

  @override
  Future<Outcome<void>> remove(String key) => Outcome.guard<void>(() async {
        await _file.mutate((data) => data.remove(key));
      });

  @override
  Future<Outcome<List<String>>> keys() => Outcome.guard<List<String>>(() async {
        return (await _file.read()).keys.toList()..sort();
      });
}

/// "第一次见到某个插件"的账本，落在 `plugin_enabled.json` 的 `plugin.seen` 里
/// —— **与启用集同一个文件**：一次读盘办两件事，也避免多出一个 JSON 真相源。
///
/// 内核靠它决定要不要按 `plugin.json` 里的 `enabledByDefault` 把插件打开：
/// 只有**第一次见到**的 id 才播，用户后来关掉就再也不被打开（用户的决定优先于作者的默认值）。
final class FileFirstRunSeeder implements FirstRunSeeder {
  FileFirstRunSeeder(this._file);

  static const _key = 'plugin.seen';
  final JsonMapFile _file;
  Set<String>? _cached;

  /// 与 [FileEnabledStore.warm] 同理：内核那边是同步调用，boot 前必须先 warm。
  Future<void> warm() async {
    final m = await _file.read();
    final list = m[_key];
    _cached = list is List ? list.whereType<String>().toSet() : <String>{};
  }

  @override
  Set<String> firstTimeSeen(Iterable<String> candidateIds) {
    final seen = _cached ?? <String>{};
    final fresh = candidateIds.where((id) => !seen.contains(id)).toSet();
    if (fresh.isEmpty) return const {};
    _cached = {...seen, ...fresh};
    final snapshot = _cached!;
    unawaited(_file.mutate((data) => data[_key] = snapshot.toList()));
    return fresh;
  }
}

/// 启用集持久化（内核只认集合，落盘在宿主）。
///
/// `EnabledStore.read()` 是同步接口（内核在扫描里就要用），所以 boot 前必须先 [warm]；
/// 没 warm 就 read 会得到空集 = 全部未启用，比读到半截文件安全。
final class FileEnabledStore implements EnabledStore {
  FileEnabledStore(this._file);

  static const _key = 'plugin.enabled';
  final JsonMapFile _file;
  Set<String>? _cached;

  Future<void> warm() async {
    final m = await _file.read();
    final list = m[_key];
    _cached = list is List ? list.whereType<String>().toSet() : <String>{};
  }

  @override
  Set<String> read() => Set.of(_cached ?? const <String>{});

  @override
  void write(Set<String> enabledIds) {
    _cached = Set.of(enabledIds);
    unawaited(_file.mutate((data) => data[_key] = enabledIds.toList()));
  }
}
