/// 插件平台在 app 里的装配根（P2）。
///
/// 三件事：**注册宿主能力** → **声明宿主槽** → **扫描并加载插件**。
/// 方向纪律：这里只准 import `plugin_kernel` 与 `lib/plugins/**`，
/// 反过来宿主内部（screens/providers/agent/tts/services）也不许 import 插件细节 ——
/// 全部由 `packages/plugin_kernel/test/architecture_test.dart` 机器钉住。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../main.dart' show appNavigatorKey;
import 'host/host_interact.dart';
import 'host/host_agent.dart';
import 'host/host_export.dart';
import 'host/host_profiles.dart';
import 'host/host_wiring.dart';
import 'builtin/en_dictation/en_dictation_plugin.dart';
import 'builtin/hello/hello_plugin.dart';
import 'host/host_capabilities.dart';
import 'host/plugin_files.dart';
import 'slot_outlet.dart' show PluginDispatcher;

// ——— 同步可用的注册表（UI 立刻能渲染空槽，boot 完成后自动填上）———

final slotRegistryProvider = Provider<SlotRegistry>((ref) => SlotRegistry());

final capabilityRegistryProvider = Provider<CapabilityRegistry>((ref) => CapabilityRegistry());

final configStoreProvider = Provider<ConfigStore>((ref) => ConfigStore());

final _storeFileProvider = Provider<JsonMapFile>((ref) => JsonMapFile('plugin_store.json'));

final _enabledFileProvider = Provider<JsonMapFile>((ref) => JsonMapFile('plugin_enabled.json'));

final enabledStoreProvider = Provider<FileEnabledStore>((ref) => FileEnabledStore(ref.watch(_enabledFileProvider)));

/// 首次播种的"见没见过"账本（与启用集同文件）。有了它，`enabledByDefault` 对
/// **从 `文档/plugins/` 装进来的插件**也才算数 —— 以前只在扫描前按内置件播一次，
/// 第三方声明了却永远不生效（内核 `FirstRunSeeder` 的注释记着这条根因）。
final firstRunSeederProvider =
    Provider<FileFirstRunSeeder>((ref) => FileFirstRunSeeder(ref.watch(_enabledFileProvider)));

/// 方案档（P6）：档目录 `ApplicationSupport/profiles/*.json` + 当前档记在 `plugin_profile.json`。
/// 读盘失败一律返回 null（面板照样能列插件，只是没有档可用），**绝不带崩平台**。
final hostProfilesProvider = FutureProvider<HostProfiles?>((ref) async {
  try {
    final profiles = await HostProfiles.boot();
    profiles.bindRef(ref); // 只有宿主接缝允许拿 provider（面板不碰）
    return profiles;
  } catch (e) {
    debugPrint('[plugin-host] 方案档目录读不动：$e');
    return null;
  }
});

final traceSinkProvider = Provider<InMemoryTraceSink>((ref) => InMemoryTraceSink(capacity: 800));

/// 装配完成的平台服务；boot 失败/未就绪时为 null（UI 要能照常显示，不能白屏）。
final pluginHostProvider = FutureProvider<PluginService?>((ref) async {
  final capabilities = ref.watch(capabilityRegistryProvider);
  final slots = ref.watch(slotRegistryProvider);
  final config = ref.watch(configStoreProvider);
  final enabled = ref.watch(enabledStoreProvider);
  final trace = ref.watch(traceSinkProvider);

  try {
    await enabled.warm();
    await ref.watch(firstRunSeederProvider).warm(); // 内核同步读它，boot 前必须先 warm

    // ① 宿主能力（P2 先接这两个就够跑通示例；其余按分期补）。
    // 注册走 `registerHostCapability`：被拒（同 id 同 priority 撞车）要留下声音，
    // 不能"我注册了"却没人知道它没进去。
    registerHostCapability(capabilities, FileStore(ref.watch(_storeFileProvider)), ownerPluginId: 'app');
    registerHostCapability(
      capabilities,
      HostInteract(navigatorKey: appNavigatorKey, log: (m) => trace.emit(TraceRecord(
            traceId: 'host:interact',
            pluginId: 'app',
            level: TraceLevel.debug,
            message: m,
          ))),
      ownerPluginId: 'app',
    );
    registerHostSpeak(capabilities, ref);
    // 离线朗读（P7）：找到模型才多注册一份 priority -1 的 app.speak；找不到就只留 Edge TTS。
    // 插件侧不知道也不该知道有这件事 —— 这正是"能力可替换"要证明的东西。
    await registerHostSpeakOffline(capabilities, ref);
    registerHostCapture(capabilities);
    registerHostLlm(capabilities, ref); // app.speak（Edge-TTS，逐条播 + 间隔 + 取消 + 缓存复用）
    // P4：llm.complete / llm.vision（走既有聊天 Provider 的一次性补全）

    final builtin = BuiltinSourceReader();
    builtin.register(HelloBuiltinPlugin.manifestDef, HelloBuiltinPlugin.new);
    builtin.register(EnglishDictationPlugin.manifestDef, EnglishDictationPlugin.new);

    // 首次播种（`enabledByDefault`）统一交给内核的 `FirstRunSeeder` 通道：
    // 它看得见**所有**来源的插件（内置 + 磁盘），而这里以前只看得见内置的那几个。

    final userDir = await _userPluginsDir();
    final reader = DeclarationDirSourceReader(() => _readUserPlugins(userDir));
    final profiles = await ref.watch(hostProfilesProvider.future);

    final service = PluginService(
      loader: PluginLoader(
        capabilities: capabilities,
        builtin: builtin,
        userSources: [reader],
        appVersion: kPluginHostAppVersion,
        // P5：零 Dart 插件的实现体由 flow 引擎代填（作者只写 plugin.json + prompt.md）。
        // 两个宿主原语都接上了：`export` 真的落到 Download/TongYi-Lite/ 才算交付；
        // `agent_handoff` **交接进当前会话**（定案理由与三条纪律见 host_agent.dart 顶部注释）。
        // 受理前的失败（没打开对话 / 正在回答 / 智能体没开）一律如实报错并给出路。
        declarativeFactory: (d) => () => DeclarativePlugin(
              d,
              runner: FlowRunner(
                host: FlowHost(
                  renderExport: hostRenderExport,
                  startAgent: (ctx, prompt, context) =>
                      hostStartAgent(ChatAgentHandoffPort(ref), ctx, prompt, context),
                ),
              ),
            ),
      ),
      capabilities: capabilities,
      slots: slots,
      configStore: config,
      enabledStore: enabled,
      firstRun: ref.watch(firstRunSeederProvider),
      // 方案档：语义在内核（compose 是唯一真相），这里只把"档文件从哪读、当前档是哪个"接上。
      profiles: profiles?.store(),
      activeProfile: () => profiles?.active,
      trace: trace,
    );
    final r = await service.boot();
    if (r.isErr) {
      debugPrint('[plugin-host] boot 失败：${r.failureOrNull?.message}');
    } else if ((r.valueOrNull?.warnings ?? const []).isNotEmpty) {
      for (final w in r.valueOrNull!.warnings) {
        debugPrint('[plugin-host] $w');
      }
    }
    // 预热所有可用能力（内核文档写着"启动后低优先级调用"，以前没人调用过）。
    // 不 await：预热只该影响首字快慢，不许拖插件平台就绪；实现里出错由内核吞掉。
    unawaited(service.warmUpCapabilities());
    // 平台被丢弃（重扫重建、页面 dispose）时必须把 fiber 全卸了。
    // `PluginService.shutdown` 以前**零调用者**：插件的 Timer、订阅、`provide` 出去的能力
    // 就这么一直挂着 —— 重扫一次多一份，跑得越久漏得越多，而且全程没有任何症状。
    ref.onDispose(() => unawaited(service.shutdown()));
    return service;
  } catch (e, st) {
    // 平台起不来绝不能带崩聊天页：返回 null，槽空着，聊天照常用。
    debugPrint('[plugin-host] 装配异常：$e\n$st');
    return null;
  }
});

/// 插件动作入口（供 `PluginDispatcherScope` 注入 widget 树）。
final pluginDispatcherProvider = Provider<PluginDispatcher?>(
  (ref) => _Dispatcher(ref.watch(pluginHostProvider).valueOrNull),
);

final class _Dispatcher implements PluginDispatcher {
  _Dispatcher(this._service);
  final PluginService? _service;

  @override
  Future<Outcome<PluginRunResult>> run(String pluginId, PluginInput input) async {
    final s = _service;
    if (s == null) {
      return Outcome.err<PluginRunResult>(
        code: PluginFailureKind.runtimeError,
        message: '插件平台还没就绪',
        hint: '稍等片刻再试，或重启 app',
        pluginId: pluginId,
      );
    }
    return s.run(pluginId, input);
  }

  @override
  Future<String?> readPluginValue(String pluginId, String key) async {
    final s = _service;
    if (s == null) return null;
    final caps = s.capabilities;
    final store = caps.resolve<Store>(ServiceKeys.store, consumerPluginId: pluginId);
    if (store.isErr) return null;
    final r = await store.valueOrNull!.read('plugin:$pluginId:$key');
    return r.valueOrNull;
  }
}

/// 面板/入口用的一句话摘要（boot 完成后有值）。
final pluginSummaryProvider = Provider<String>((ref) {
  final service = ref.watch(pluginHostProvider).valueOrNull;
  if (service == null) return '插件平台未就绪';
  final views = service.view();
  final on = views.where((v) => v.running).length;
  final gated = views.where((v) => v.loaded.status == PluginLoadStatus.gated).length;
  return '已启用 $on/${views.length}${gated > 0 ? '，另有 $gated 个在等功能' : ''}';
});

// ——— 用户插件目录（手机上的 `文档/plugins/<目录>/plugin.json`）———

Future<String> _userPluginsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'plugins'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir.path;
}

/// 读目录快照给内核（**内核不碰 dart:io**，读文件是宿主的活）。
///
/// 单个目录读失败只跳过它：一个写坏的 `plugin.json` 不许让别的插件消失。
Map<String, ({String json, String? prompt})> _readUserPlugins(String root) {
  final out = <String, ({String json, String? prompt})>{};
  try {
    final entries = Directory(root).listSync().whereType<Directory>();
    for (final d in entries) {
      try {
        final manifest = File(p.join(d.path, 'plugin.json'));
        if (!manifest.existsSync()) continue;
        final promptFile = File(p.join(d.path, 'prompt.md'));
        out[p.basename(d.path)] = (
          json: manifest.readAsStringSync(),
          prompt: promptFile.existsSync() ? promptFile.readAsStringSync() : null,
        );
      } catch (_) {
        continue;
      }
    }
  } catch (_) {
    // 整个目录读不了（权限/正在被改）：交给 loader 的"沿用上次好树"兜底。
  }
  return out;
}
