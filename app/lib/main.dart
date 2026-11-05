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
    show
        pendingApprovalsProvider,
        sandboxApproverProvider,
        toolPreApproverProvider;
import 'providers/chat_provider.dart' show currentConversationIdProvider;
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
        // v0.0.4：聊天工具式窄窗（用户 2026-11-05：最小宽度要到原来的一半，
        // "太肥大了"）——360 宽 ≈ 手机聊天宽度；几何记忆会记住用户的窄窗尺寸。
        minimumSize: const Size(360, 480),
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

  // 端侧 ASR 预热（sherpa-onnx）：后台 isolate 预读模型文件到页缓存，
  // 首次语音输入加载更快；模型未下载时静默跳过。fire-and-forget。
  unawaited(SherpaStreamingAsr.warmup());

  // 立即渲染启动画面（LOGO + APP 描述），避免初始化期间出现空白加载页。
  // 模型目录 / 原生引擎的初始化改在启动画面内异步进行（见 AppStartupGate）。
  // 注入沙箱升级审批通道（对照 DSH ctx.approval）：用户开启「完整文件访问
  // 授权」后，智能体请求完整文件系统时弹确认框逐次批准。
  await _initDesktopWindow();
  runApp(
    ProviderScope(
      overrides: [
        // v0.0.4 Phase 4b：审批走 composer 接管（pendingApprovalsProvider），
        // 对话区输入框上方渲染 ApprovalCard 就地决议——不再弹全局对话框打断。
        sandboxApproverProvider.overrideWith((ref) {
          return (escalation, toolName) async {
            final settings = ref.read(settingsProvider);
            if (!settings.agentFullFileAccess) return false;
            return ref.read(pendingApprovalsProvider.notifier).enqueue(
                  title: '智能体请求完整文件系统访问',
                  detail: '工具：$toolName\n'
                      '理由：${escalation.justification}\n\n'
                      '沙箱默认只允许工作目录内读写；批准后本次调用可访问'
                      '整台机器的文件系统（含工作目录之外）。仅本次调用生效。',
                  conversationId: ref.read(currentConversationIdProvider),
                  allowLabel: '批准（仅本次）',
                );
          };
        }),
        // Phase 6：流水线 pre-execute `ask` 审批（§12.3）——
        // v0.0.4 Phase 4b：同走 composer 接管。
        toolPreApproverProvider.overrideWith((ref) {
          return (call) async {
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
            return ref.read(pendingApprovalsProvider.notifier).enqueue(
                  title: '智能体请求执行工具「${call.name}」',
                  detail: '参数：$argsText',
                  conversationId: ref.read(currentConversationIdProvider),
                  allowLabel: '允许（仅本次）',
                );
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
        // 全局 UI 缩放（设置「更多 → UI 缩放」）：devicePixelRatio 乘数。
        return MediaQuery(
          data: mq.copyWith(devicePixelRatio: mq.devicePixelRatio * uiScale),
          child: child ?? const SizedBox.shrink(),
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
