/// TongYi-Lite 插件平台契约层（P0 冻结面）。
///
/// **这个包是平台与插件之间唯一的合法接触面。** 三条方向铁律（由 app 侧
/// `test/plugins/direction_rules_test.dart` 机检，不靠自觉）：
/// 1. 本包绝不 `import 'package:tongyi_lite/...'` 或任何 `lib/**`；
/// 2. `lib/plugins/**` 只用本包的类型与 [PluginCtx] 取宿主能力，不得 import `screens/`、`providers/`、`agent/`、`tts/`、`services/`；
/// 3. `lib/plugins/builtin/<a>/**` 不得 import `lib/plugins/builtin/<b>/**`（插件之间只能经注册表协作）。
///
/// 本包**不依赖 Flutter**：槽的渲染载荷是泛型，app 侧塞 widget、契约测试塞哨兵值。
library;

export 'src/capability.dart';
export 'src/ctx.dart';
export 'src/deprecations.dart';
export 'src/extract.dart';
export 'src/flow.dart';
export 'src/hook.dart';
export 'src/manifest.dart';
export 'src/outcome.dart';
export 'src/slot.dart';
export 'src/slot_contract.dart';
export 'src/validate.dart';
