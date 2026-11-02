/// TongYi-Lite 插件平台内核（P1）。
///
/// 纯 Dart：不依赖 Flutter，因此能离线 `dart test`。
/// Flutter 相关的东西（`SlotOutlet`、面板、把宿主服务包成能力）全部留在 app 的 `lib/plugins/**`。
library;

export 'package:plugin_sdk/plugin_sdk.dart';

export 'src/capability_registry.dart';
export 'src/cli.dart';
export 'src/config_layers.dart';
export 'src/ctx_impl.dart' show KernelPluginCtx;
export 'src/flow_runner.dart';
export 'src/fiber.dart';
export 'src/loader.dart';
export 'src/profiles.dart';
export 'src/scaffold.dart';
export 'src/plugin_service.dart';
export 'src/trace.dart';
