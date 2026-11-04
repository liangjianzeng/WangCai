import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'agent/session/store.dart' show JsonlSessionStore;
import 'project/migration.dart' show migrateLegacySessions;
import 'providers/agent_approval.dart'
    show sandboxApproverProvider, toolPreApproverProvider;
import 'providers/settings_provider.dart' show settingsProvider;
import 'screens/home_screen.dart';
import 'platform/inference_gateway.dart';
import 'platform/wangcai_paths.dart';
import 'platform/window_geometry.dart';
import 'services/model_manager.dart';
import 'services/storage_service.dart' show StorageService;
import 'asr/sherpa_streaming_asr.dart';

/// 全局导航 key：沙箱升级审批确认框经此弹出（ProviderScope 在 MaterialApp 之前，
/// 无法直接使用 BuildContext）。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Android 13+ 通知运行时权限请求（fire-and-forget，失败静默）。
Future<void> _requestNotificationPermission() async {
  try {
    await Permission.notification.request();
  } catch (_) {
    // 非 Android 平台/插件未就绪：静默跳过（通知仅为可见性增强）。
  }
}

/// v0.0.4 Phase 3（计划书 §4.1）：Windows 窗口基本件——真标题、最小尺寸、
/// 几何记忆（尺寸+最大化；位置刻意不记，多显示器陷阱见 window_geometry.dart）。
/// runner main.cpp 另配单实例互斥（第二个进程只前置已有窗口）。
Future<void> _initDesktopWindow() async {
  if (!Platform.isWindows) return;
  try {
    await windowManager.ensureInitialized();
    final geo = WindowGeometry.load();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: '汪柴 WangCai',
        minimumSize: const Size(520, 480),
        size: geo?.size ?? const Size(1280, 800),
      ),
      () async {
        if (geo?.maximized ?? false) await windowManager.maximize();
        await windowManager.show();
        await windowManager.focus();
      },
    );
  } catch (_) {
    // 窗口管理器初始化失败不阻塞启动（runner 默认尺寸兜底）。
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端（Windows/Linux/macOS）：sqflite_common_ffi 必须在任何 DB 使用前
  // 装好全局 databaseFactory，否则 HomeScreen 首帧 getDatabasesPath() 抛
  // 「databaseFactory not initialized」→ _initConversation 挂 → 首页一直转圈。
  // Android 由 sqflite 插件自装工厂，跳过即可。汪柴分叉：桌面条线平台差异。
  if (!Platform.isAndroid && !Platform.isIOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // v0.0.4 数据家统一（DSH ~/.dsh 纪律）：旧家（com.dgxspark\wangcai_app）子目录
  // 一次性搬进 %APPDATA%\WangCai。幂等、失败静默、旧数据不删（.migrated 备份）。
  // 必须在任何 store/goal/skill 初始化之前跑。
  WangCaiPaths.migrateLegacyHome();

  // v0.0.3 项目层级（设计 §12 Phase 1）：会话→项目解析器接线 +
  // 旧平铺会话一次性幂等迁移。迁移失败绝不阻塞启动——读取侧本来就有
  // 旧平铺双路径兜底，迁移只是"把家搬完"，不是功能开关。
  JsonlSessionStore.projectIdResolver =
      (convId) => StorageService().projectOfConversation(convId);
  try {
    await migrateLegacySessions();
  } catch (e) {
    debugPrint('[Project] 启动迁移异常（双路径兜底在，可忽略）: $e');
  }

  // Android 13+ 通知运行时权限（审查 P1：清单已声明 POST_NOTIFICATIONS 但
  // 从未请求——前台推理进度通知对用户不可见）。fire-and-forget：拒绝不阻塞
  // 启动，推理保活通知只是不可见，功能不受影响。
  unawaited(_requestNotificationPermission());

  // Edge-to-edge：应用绘制延伸到状态栏/手势条之下，系统栏透明。
  // 不开这个，窗口底到手势条之间永远是系统画的黑条——composer「铺满底部」
  // 在窗口层面就不可能成立（2026-10-25 底部黑边根因）。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  ));

  // 端侧 ASR 预热（sherpa-onnx，DSH-Phone 方案）：后台 isolate 预读模型文件
  // 到页缓存，首次按住说话时加载更快；模型未下载时静默跳过。fire-and-forget。
  unawaited(SherpaStreamingAsr.warmup());

  // 立即渲染启动画面（LOGO + APP 描述），避免初始化期间出现空白加载页。
  // 模型目录 / 原生引擎的初始化改在启动画面内异步进行（见 AppStartupGate）。
  // 注入沙箱升级审批通道（对照 DSH ctx.approval）：用户开启「完整文件访问
  // 授权」后，智能体请求完整文件系统时弹确认框逐次批准。
  await _initDesktopWindow();
  runApp(
    ProviderScope(
      overrides: [
        sandboxApproverProvider.overrideWith((ref) {
          return (escalation, toolName) async {
            final settings = ref.read(settingsProvider);
            if (!settings.agentFullFileAccess) return false;
            final navigator = appNavigatorKey.currentState;
            if (navigator == null) return false;
            final granted = await showDialog<bool>(
              context: navigator.context,
              barrierDismissible: false,
              builder: (ctx) => AlertDialog(
                title: const Text('智能体请求访问公共目录'),
                content: Text(
                  '工具：$toolName\n'
                  '理由：${escalation.justification}\n\n'
                  '应用已具备访问公共目录（/sdcard 等）的权限；'
                  '系统目录（/data 等）需 root，应用无法授予。'
                  '批准后仅本次调用生效。',
                  style: const TextStyle(fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('拒绝'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('批准'),
                  ),
                ],
              ),
            );
            return granted == true;
          };
        }),
        // Phase 6：流水线 pre-execute `ask` 审批（ApprovalDialog，§12.3）。
        toolPreApproverProvider.overrideWith((ref) {
          return (call) async {
            final navigator = appNavigatorKey.currentState;
            if (navigator == null) return false;
            var argsText = '';
            try {
              argsText =
                  jsonEncode(call.arguments ?? const <String, dynamic>{});
            } catch (_) {
              argsText = call.arguments?.toString() ?? '';
            }
            if (argsText.length > 300) {
              argsText = '${argsText.substring(0, 300)}…';
            }
            final granted = await showDialog<bool>(
              context: navigator.context,
              barrierDismissible: false,
              builder: (ctx) => AlertDialog(
                title: Text('允许调用工具「${call.name}」？'),
                content: Text(
                  '参数：$argsText',
                  style: const TextStyle(fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('拒绝'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('允许'),
                  ),
                ],
              ),
            );
            return granted == true;
          };
        }),
      ],
      child: const WangCaiApp(),
    ),
  );
}

class WangCaiApp extends ConsumerWidget {
  const WangCaiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 全局 UI 缩放（设置「更多 → UI 缩放」）：devicePixelRatio 乘数，
    // 与系统"显示大小"同机制，图标/文字/间距整体等比缩放。
    final settings = ref.watch(settingsProvider);
    final uiScale = settings.uiScale;
    final themeMode = switch (settings.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return MaterialApp(
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        // 系统栏图标明暗跟随主题（2026-10-25 浅色模式状态栏时间看不见根因：
        // main() 里的全局 overlay 只设了透明背景，图标亮度留空 = Android 默认
        // 白图标，浅色条带上白字隐身）。AnnotatedRegion 随主题切换自动更新。
        final barIcons =
            Theme.of(context).brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            statusBarIconBrightness: barIcons,
            systemNavigationBarIconBrightness: barIcons,
          ),
            child: MediaQuery(
              data:
                  mq.copyWith(devicePixelRatio: mq.devicePixelRatio * uiScale),
              child: child ?? const SizedBox.shrink(),
            ),
        );
      },
      title: '汪柴 WangCai',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: themeMode,
      home: const AppStartupGate(),
    );
  }
}

/// 启动门控：运行模型目录与原生引擎初始化，初始化期间直接渲染首页（首页
/// 自带加载态），不再显示启动画面。
class AppStartupGate extends ConsumerStatefulWidget {
  const AppStartupGate({super.key});

  @override
  ConsumerState<AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends ConsumerState<AppStartupGate> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 启动时加载模型下载目录（assets/models_catalog.json，可选远程热更新）。
    // 即便目录解析失败也不要让启动崩溃——降级为空列表，App 仍可运行。
    try {
      await ModelManager().init();
    } catch (e) {
      debugPrint(
          '[Main] Failed to load model catalog, continuing with empty list: $e');
    }

    // 初始化推理引擎（Android=llama_backend_init 幂等；Windows=装配引擎注册表
    // + 账本扫孤儿，见 inference_gateway.dart）。
    try {
      await initInferenceEngine();
      debugPrint('[Main] Inference engine initialized');
    } catch (e) {
      debugPrint('[Main] Failed to initialize native engine: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 直接进首页，初始化期间由首页自身加载态（spinner / 模型状态）承担。
    return const HomeScreen();
  }
}
