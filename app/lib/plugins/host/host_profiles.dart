/// 宿主接缝：方案档（Profile）的落盘与"一键换场景"。
///
/// 档文件放 `ApplicationSupport/profiles/<档名>.json`，当前生效的档名记在
/// `文档/plugin_profile.json`（与 `plugin_enabled.json` 同一套原子写法）。
///
/// 内核已经定了语义（`ProfileStore.compose` 是**唯一**真相，预览与 runtime 同一个纯函数），
/// 这一层只做三件宿主才该做的事：
/// 1. **读盘**：档目录一次扫一遍，单个文件读崩只标坏它自己（内核会把坏档标出来给面板看）；
/// 2. **持久化当前档**：重启后还是那个档；
/// 3. **换场景的副作用**：档里写的人格 / 模型落到设置，并且**改了环境就 resetContext**
///    ——KV 缓存按会话复用，档换了提示词前缀却不重置，下一轮就是"新档跑旧人格"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../../services/settings_service.dart' show InferenceSettings;
import '../../providers/settings_provider.dart';
import '../../providers/shared_providers.dart';
import 'plugin_files.dart';

/// 切档的结果（面板照着播一句话就行）。
final class ProfileSwitchResult {
  const ProfileSwitchResult({
    required this.profile,
    required this.enabled,
    required this.notes,
    required this.resetKv,
  });

  /// 生效的档名（null = 已取消档）。
  final String? profile;

  /// 切完之后实际会开着哪些插件。
  final Set<String> enabled;

  /// 提醒（档里有插件本机没有 / 人格没落上……）。
  final List<String> notes;

  /// 是否重置过 KV（面板可以说明白"下一轮会重新理解上下文"）。
  final bool resetKv;
}

/// 设置侧的落地器（实现内核的 [ProfileSettingsSink]）。
///
/// **档没表态（null）就一项都不碰**：这条是内核测试钉着的，这里照做即可。
final class SettingsProfileSink implements ProfileSettingsSink {
  /// 面板传 [WidgetRef]、装配根传 [Ref]：两个类型没有共同接口，只能各接一个。
  // 箭头函数当初始化器要用括号包住：否则那个逗号会被当成箭头体的一部分，解析当场歪掉。
  SettingsProfileSink.fromWidgetRef(WidgetRef ref)
      : _read = (() => ref.read(settingsProvider)),
        _readNotifier = (() => ref.read(settingsProvider.notifier));

  SettingsProfileSink.fromRef(Ref ref)
      : _read = (() => ref.read(settingsProvider)),
        _readNotifier = (() => ref.read(settingsProvider.notifier));

  final InferenceSettings Function() _read;
  final SettingsNotifier Function() _readNotifier;

  InferenceSettings get _s => _read();

  @override
  String? get personaId => _s.activePersonaId;

  @override
  String? get defaultModelId => _s.defaultModelId;

  @override
  String? get activeApiModelId => _s.activeApiModelId;

  @override
  Future<void> usePersona(String? id) async {
    if (id == null) return;
    await _readNotifier().setActivePersona(id);
  }

  @override
  Future<void> useDefaultModel(String? id) async {
    if (id == null) return;
    await _readNotifier().setDefaultModel(id);
  }

  @override
  Future<void> useApiModel(String? id) async {
    if (id == null) return;
    await _readNotifier().setActiveApiModel(id);
  }
}

/// 「当前用哪个档」存哪儿（宿主实现；面板与测试可以换成内存版）。
abstract interface class ActiveProfileStore {
  String? read();
  Future<void> write(String? name);
}

/// 内存版（测试用；也让"预览切档"不必先落盘）。
final class MemoryActiveProfileStore implements ActiveProfileStore {
  MemoryActiveProfileStore([this._name]);
  String? _name;
  int writes = 0;

  @override
  String? read() => _name;

  @override
  Future<void> write(String? name) async {
    _name = name;
    writes++;
  }
}

/// 用 `文档/plugin_profile.json` 记当前档（与开关文件同一套原子写法，重启还在）。
final class FileActiveProfileStore implements ActiveProfileStore {
  FileActiveProfileStore(this._file, {String? seed}) : _name = seed;

  static const String activeKey = 'active';
  final JsonMapFile _file;
  String? _name;

  @override
  String? read() => _name;

  @override
  Future<void> write(String? name) async {
    _name = name;
    await _file.mutate((data) {
      if (name == null) {
        data.remove(activeKey);
      } else {
        data[activeKey] = name;
      }
    });
  }
}

/// 方案档账本（宿主侧）。
class HostProfiles {
  HostProfiles({required this.dirPath, required ActiveProfileStore activeStore, String? active})
      : _activeStore = activeStore,
        active = active ?? activeStore.read();

  final String dirPath;
  final ActiveProfileStore _activeStore;

  /// 当前生效的档名（null = 不用档，全凭逐个开关）。
  String? active;

  /// 交给内核的账本（`source` 每次现读：作者改完文件点"重新扫描"就该跟上）。
  ProfileStore store() => ProfileStore(source: _readAll);

  /// 读整个档目录。**一个坏文件只标坏它自己**：坏档由内核标成 broken 给面板显示，
  /// 但绝不能连累别的档，更不能让平台起不来。
  Map<String, String> _readAll() {
    final out = <String, String>{};
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return out;
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.json')) continue;
        final name = p.basenameWithoutExtension(f.path);
        if (name.isEmpty || name.startsWith('.')) continue;
        try {
          out[name] = f.readAsStringSync();
        } catch (_) {
          out[name] = '{坏文件'; // 交给内核标 broken，别在这里替用户决定删掉它
        }
      }
    } catch (_) {
      // 整个目录读不动：当"没有档"，当前档由 compose 的 fail-safe 退回原开关。
      return const {};
    }
    return out;
  }

  /// 建/改一个档（作者也可以用文件管理器直接改，这里只是给面板留条路）。
  Future<void> save(String name, Map<String, Object?> data) async {
    final file = File(p.join(dirPath, '$name.json'));
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await tmp.rename(file.path);
  }

  /// 面板「新建方案档」走的这条路。
  ///
  /// 三条纪律：
  /// * 档名由内核判（[profileNameProblem]），宿主不另编一套话术；
  /// * **已有同名档一律拒绝**：作者可能正用文件管理器手写那份，面板不许顺手覆盖它；
  /// * 只写文件，**不切过去** —— 建好就偷偷生效，等于用户没点过的东西自己动了。
  Future<Outcome<void>> create(String name, Set<String> enabled, {String? note}) async {
    if (profileNameProblem(name) case final problem?) {
      return Outcome.err<void>(
        code: PluginFailureKind.badContent,
        message: '这个档名不能用',
        hint: problem,
        pluginId: 'app',
      );
    }
    final trimmed = name.trim();
    if (_readAll().containsKey(trimmed)) {
      return Outcome.err<void>(
        code: PluginFailureKind.badContent,
        message: '已经有叫「$trimmed」的方案档了',
        hint: '换个名字；要改那份就直接在 ${p.join(dirPath, '$trimmed.json')} 里改，改完点「重新扫描」',
        pluginId: 'app',
      );
    }
    try {
      await save(trimmed, profileDraftJson(enabled: enabled, note: note));
    } catch (e) {
      return Outcome.err<void>(
        code: PluginFailureKind.runtimeError,
        message: '方案档没建成',
        hint: '看看存储是否可写（档目录：$dirPath），或换个档名再试',
        pluginId: 'app',
        cause: e,
      );
    }
    return const Ok<void>(null);
  }

  Future<bool> delete(String name) async {
    final file = File(p.join(dirPath, '$name.json'));
    if (!await file.exists()) return false;
    await file.delete();
    if (active == name) await setActive(null);
    return true;
  }

  /// 记住当前档（重启还在）。
  Future<void> setActive(String? name) async {
    active = name;
    await _activeStore.write(name);
  }

  /// **一键换场景**：记档 → 重新扫描加载 → 档里的人格/模型落设置 → 环境变了就归零 KV。
  ///
  /// 顺序是有讲究的：先让插件集就位（用户最关心"有哪些功能"），再动环境项；
  /// 环境项没落上也只是提醒，不许让整次切换失败。
  Future<ProfileSwitchResult> switchTo(
    PluginService service,
    String? name, {
    ProfileSettingsSink? sink,
  }) async {
    await setActive(name);
    final r = await service.reload();
    final notes = <String>[...(r.valueOrNull?.warnings ?? const <String>[])];

    var resetKv = false;
    if (sink != null) {
      final c = service.composition;
      final touched = c.personaId != null || c.modelId != null || c.apiModelId != null;
      final before = (sink.personaId, sink.defaultModelId, sink.activeApiModelId);
      notes.addAll(await applyProfileSettings(sink, c));
      final after = (sink.personaId, sink.defaultModelId, sink.activeApiModelId);
      if (touched && before != after) {
        // 档换了提示词前缀（人格）或换了模型：KV 里还是旧前缀，下一轮就会"新档跑旧人格"。
        await _ref?.read(inferenceServiceProvider).resetContext();
        resetKv = true;
      }
    }
    return ProfileSwitchResult(
      profile: service.composition.profile,
      enabled: service.composition.enabled,
      notes: notes,
      resetKv: resetKv,
    );
  }

  Ref? _ref;

  /// 装配根把 [Ref] 注进来（宿主接缝才允许拿 provider；面板不碰这个）。
  void bindRef(Ref ref) => _ref = ref;

  /// 开机时读一次盘，拿到档目录与当前档。
  static Future<HostProfiles> boot() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'profiles'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = JsonMapFile('plugin_profile.json');
    final data = await file.read();
    final active = data[FileActiveProfileStore.activeKey];
    return HostProfiles(
      dirPath: dir.path,
      activeStore: FileActiveProfileStore(file, seed: active == null ? null : '$active'),
    );
  }
}
