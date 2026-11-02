import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../asr/hold_to_talk.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

import '../providers/index.dart'
    show
        chatNotifierProvider,
        runningTurnsProvider,
        agentPendingQuestionProvider,
        messagesProvider,
        conversationsProvider,
        currentConversationIdProvider,
        currentModelIdProvider,
        kLocalVisionSupported;
import '../providers/model_provider.dart';
import '../providers/settings_provider.dart' show settingsProvider;
import '../services/attachment_service.dart'
    show kMaxAttachments, kSupportedExtensions;
import '../services/inference_service.dart';
import '../providers/shared_providers.dart';
import '../providers/context_usage_provider.dart' show contextUsageProvider;
import '../models/agent_persona.dart' show AgentPersona, kStandardPersonaId;
import '../agent/goal/goal_store.dart'
    show GoalStore, GoalState, GoalStatus, PlanStepStatus;
import '../agent/dev/dev.dart'
    show
        DevSessionController,
        DevWorkspace,
        WorkspaceBackend,
        SshEnvironmentService,
        SshTargetKind,
        connectWorkspace,
        createWorkspaceOnActiveConnection,
        sshTargetKindOf,
        workspaceBackendLabel;
import '../agent/builtin_tools/todo_tool.dart'
    show readTodoStore, renderTodoCardText;
import '../widgets/todo_card.dart';
import '../models/conversation.dart';
import '../services/settings_service.dart';
import '../services/storage_permission_service.dart';
import '../widgets/agent_workflow.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/image_preview.dart';
import '../widgets/rail/rail_scaffold.dart';
import '../plugins/panel/plugins_screen.dart';
import 'package:uuid/uuid.dart';
import '../providers/agent_state_provider.dart'
    show agentUiStateProvider, AgentUiState, ToolActivityUi;
import '../models/chat_message.dart' show ChatMessage;
import '../widgets/conversation_stats_bar.dart';
import 'settings_screen.dart';
// 插件平台（P2）：宿主在这里只"挖洞"，不认识任何具体插件。
import '../plugins/plugin_host.dart';
import '../plugins/plugin_input_icon.dart';
import '../plugins/slot_outlet.dart';
import 'package:plugin_kernel/plugin_kernel.dart' show SlotRegistry;

/// App-lifetime guard: 启动自动加载默认模型只执行一次。
/// 放在库作用域，避免首页路由重建时重复触发（与设置页 `_appLaunchScanDone` 同风格）。
bool _autoLoadDefaultDone = false;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();

  /// 左栏面板开合（2026-10-24 harness 改造）：会话/智能体/人格/计划/模型/
  /// 技能/插件/API/更多 全部从左栏进。
  final RailPanelController _railPanel = RailPanelController();

  /// ask_user_question 自由回答输入框（随提问卡片创建/销毁复用）。
  final _questionController = TextEditingController();
  String _currentConversationId = '';

  /// 切换"当前打开的会话"的**唯一入口**：除了本地状态，还镜像进 [currentConversationIdProvider]，
  /// 让插件平台的 `agent_handoff` 知道该交接进哪一串（以前没人写这个 provider，交接只能报"没有对话"）。
  void _setCurrentConversation(String id) {
    _currentConversationId = id;
    ref.read(currentConversationIdProvider.notifier).state =
        id.isEmpty ? null : id;
  }

  bool _initiallyLoaded = false;
  // When true, the view auto-scrolls to the newest message (bottom of the
  // list). Disabled once the user scrolls up to read history.
  bool _followStream = true;

  // Image picker state
  final List<String> _selectedImagePaths = [];

  /// 智能体附件（≤5 个，WP-A）。
  final List<String> _selectedFilePaths = [];
  final ImagePicker _picker = ImagePicker();

  // 语音拾音（按住说话）状态 —— 用 ValueNotifier 而非 setState 驱动，避免
  // 录音中重建 GestureDetector 导致「松手」手势丢失（此前重建会杀掉 onLongPressEnd）。
  // 端侧 ASR（sherpa-onnx，DSH-Phone 方案）：按住说话会话句柄。
  HoldToTalkSession? _voiceSession;
  Offset? _voiceLongPressPos;

  /// 松手后的收声缓冲计时器：松手先等 [_voiceLinger] 再真正停止录音定稿，
  /// 避免用户"手比嘴快"（说完才松手）把句尾截断。
  Timer? _pendingVoiceEnd;

  /// 缓冲期内尚未定稿的会话（供 [_cancelPendingVoiceEnd] 丢弃/收尾）。
  HoldToTalkSession? _pendingVoiceSession;

  // 附件面板的暂存选择（bottom sheet 回调里不能直接 await pick，
  // 先落字段、pop 后统一分发）。
  // 会话批量选择状态
  bool _conversationSelectionMode = false;
  final Set<String> _selectedConversations = {};

  @override
  void initState() {
    super.initState();
    _initStoragePermission();
    _initConversation();
    _initAutoLoadDefaultModel();
    // Dev 工作区胶囊要跟着"激活工作区 / SSH 连接状态"实时变。
    DevSessionController.instance.addListener(_onDevChanged);
    SshEnvironmentService.instance.addListener(_onDevChanged);
  }

  void _onDevChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DevSessionController.instance.removeListener(_onDevChanged);
    SshEnvironmentService.instance.removeListener(_onDevChanged);
    _scrollController.dispose();
    _textController.dispose();
    _conversationSearchCtrl.dispose();
    _questionController.dispose();
    _railPanel.dispose();

    super.dispose();
  }

  /// 滚动焦点仲裁（2026-10-25 用户定案）：**只在用户手指拖动的滚动里**
  /// 判定跟随焦点——拖离底部 = 释放自动跟随（生成中不再每帧拽到底部，
  /// 可自由上翻看历史）；拖回底部（±60px）= 重新截获自动跟随。
  ///
  /// 仲裁信号 = ScrollUpdateNotification.dragDetails（非 null 才是手指
  /// 拖动；跟随态每帧的 animateTo / 惯性 fling 都是程序化滚动，
  /// dragDetails 为 null，一律忽略——否则动画中段位置会把焦点打掉，
  /// 流式跟随随之失效，这正是此前 followSig 门控翻车的根因）。
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      final nearBottom = n.metrics.pixels >= n.metrics.maxScrollExtent - 60;
      if (nearBottom != _followStream) {
        setState(() => _followStream = nearBottom);
      }
    }
    return false;
  }

  Future<void> _initStoragePermission() async {
    // 延迟一点时间显示权限对话框，避免阻塞启动
    Future.delayed(const Duration(milliseconds: 500), () async {
      await StoragePermissionService.checkAndRequestIfNeeded(context);
    });
  }

  Future<void> _initConversation() async {
    final notifier = ref.read(conversationsProvider.notifier);
    // Ensure the list is loaded from storage before deciding whether to seed.
    await notifier.ensureLoaded();
    var conversations = ref.read(conversationsProvider);
    if (conversations.isEmpty) {
      await notifier.create();
      conversations = ref.read(conversationsProvider);
    }
    setState(() {
      _setCurrentConversation(conversations.first.id);
      _initiallyLoaded = true;
    });
    // 占用快照是内存态（重启即丢）：启动时按本地历史估算回填，圈圈立即可见。
    unawaited(ref
        .read(chatNotifierProvider.notifier)
        .refreshUsageEstimate(_currentConversationId));
  }

  /// 启动自动加载「默认模型」：用户已在模型管理页勾选某个已缓存模型为默认，
  /// 每次进入首页时自动把该模型加载进内存。文件缺失/加载失败时静默跳过，
  /// 不影响首页正常使用。每个 APP 进程仅执行一次。
  Future<void> _initAutoLoadDefaultModel() async {
    if (_autoLoadDefaultDone) return;
    _autoLoadDefaultDone = true;

    // 直接读持久化设置，避免 settingsProvider 异步 _load 未完成时读到默认 null。
    final settings = await SettingsService().load();
    final defaultId = settings.defaultModelId;
    if (defaultId == null || defaultId.isEmpty || !mounted) return;

    final manager = ref.read(modelManagerProvider.notifier);
    if (manager.isBusy || manager.isLoadedState) return;

    // 直接进首页后，本页自动加载可能先于启动门控的 InferenceService.initialize()
    // 完成；llama_backend_init 幂等（多次调用无副作用），先确保原生引擎就绪。
    try {
      await InferenceService().initialize();
    } catch (e) {
      debugPrint('[Home] InferenceService init failed, skipping auto-load: $e');
      return;
    }

    final cached = await manager.isModelCached(defaultId);
    if (!cached || !mounted) return;

    final ok = await manager.loadModel(defaultId);
    if (!mounted) return;
    if (ok) {
      // 同步当前模型 id，使聊天默认使用该模型。
      ref.read(currentModelIdProvider.notifier).state = defaultId;
      manager.appendInferenceLog('启动自动加载默认模型: $defaultId');
    }
  }

  /// Pick image from camera or gallery（多图，≤10）。
  /// [source] 为空时弹选择对话框（拍照/相册）；已指定则直接走对应来源。
  Future<void> _pickImage([ImageSource? source]) async {
    source ??= await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择图片来源（最多 10 张）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('相册（可多选）'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    // 相机需要权限（无论从哪个入口进入都先检查）。
    if (source == ImageSource.camera) {
      final hasPermission =
          await StoragePermissionService.requestCameraPermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('相机权限被拒绝，请在设置中授予')),
          );
        }
        return;
      }
    }

    try {
      // 选图 = 用户视角：存**原图**路径（imageQuality 只压体积不改构图，
      // 1280 宽长截图仍是完整一张）。长图切块是发给模型时后端做的
      // （chat_provider._prepareVisionPaths），用户全程只见原图。
      // 注：不要恢复旧的 maxWidth/maxHeight=768——那会把长截图挤成糊图，
      // 模型反馈「分辨率太低无法识别」。
      if (source == ImageSource.gallery) {
        final images = await _picker.pickMultiImage(imageQuality: 90);
        if (images.isEmpty) return;
        setState(() {
          for (final img in images) {
            if (_selectedImagePaths.length >= 10) break;
            _selectedImagePaths.add(img.path);
          }
        });
      } else {
        final XFile? image = await _picker.pickImage(
          source: source,
          imageQuality: 90,
        );
        if (image != null) {
          setState(() {
            if (_selectedImagePaths.length < 10) {
              _selectedImagePaths.add(image.path);
            }
          });
        }
      }
      if (_selectedImagePaths.length == 10 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('最多 10 张，超出的未添加')),
        );
      }
      _warnIfImageDropped();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择图片失败: $e')),
      );
    }
  }

  /// 智能体附件选择（WP-A）：≤5 个，白名单办公/文本格式。
  Future<void> _pickAttachmentFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions:
          kSupportedExtensions.map((e) => e.replaceFirst('.', '')).toList(),
    );
    if (result == null || result.files.isEmpty) return;
    setState(() {
      for (final f in result.files) {
        if (_selectedFilePaths.length >= kMaxAttachments) break;
        final path = f.path;
        if (path != null && !_selectedFilePaths.contains(path)) {
          _selectedFilePaths.add(path);
        }
      }
    });
    if (mounted && result.files.length > kMaxAttachments) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('最多 $kMaxAttachments 个文件，超出的未添加')),
      );
    }
  }

  /// 统一附件入口：图片（拍照/相册）与文件附件（智能体模式）合并为一个
  /// 「+」按钮，点按弹出选择面板——替代此前输入框右侧「图片」+ 前置
  /// 「附件」两个独立按钮，收窄消息发送区。
  ///
  /// ⚠️ 此前实现把 `showModalBottomSheet<void>` 的返回值丢弃、靠一个从未
  /// 赋值的暂存字段分发 → 选完什么都不会发生（"附件/拍照上传全坏"根因）。
  /// 现改为直接消费面板返回的 [_AttachSource]。
  Future<void> _showAttachSheet() async {
    final agentOn = ref.read(settingsProvider).agentEnabled;
    final theme = Theme.of(context);
    final source = await showModalBottomSheet<_AttachSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 拖拽把手 + 标题
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('添加附件',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
                _AttachOption(
                  icon: Icons.photo_camera_outlined,
                  tint: Colors.blue,
                  title: '拍照',
                  subtitle: '拍摄一张照片发送（≤10 张）',
                  onTap: () => Navigator.pop(ctx, _AttachSource.camera),
                ),
                _AttachOption(
                  icon: Icons.photo_library_outlined,
                  tint: Colors.green,
                  title: '从相册选择',
                  subtitle: '可多选图片，一次最多 10 张',
                  onTap: () => Navigator.pop(ctx, _AttachSource.gallery),
                ),
                if (agentOn)
                  _AttachOption(
                    icon: Icons.attach_file,
                    tint: Colors.deepOrange,
                    title: '文件',
                    subtitle:
                        '智能体附件（≤$kMaxAttachments 个）：docx / xlsx / pptx / txt / md / csv 等',
                    onTap: () => Navigator.pop(ctx, _AttachSource.file),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || source == null) return;
    switch (source) {
      case _AttachSource.camera:
        await _pickImage(ImageSource.camera);
        break;
      case _AttachSource.gallery:
        await _pickImage(ImageSource.gallery);
        break;
      case _AttachSource.file:
        await _pickAttachmentFiles();
        break;
      case _AttachSource.none:
        break;
    }
  }

  /// 选图后提示：若当前实际路线不支持视觉，图片仅展示、不会发给模型。
  /// 仅为提示，不阻止发送；真正的强制门禁在 [ChatNotifier.sendMessage]。
  void _warnIfImageDropped() {
    if (!mounted) return;
    final settings = ref.read(settingsProvider);
    final activeApi = settings.activeApiModel();
    final hasLocalLoaded = ref.read(modelManagerProvider).isLoaded;
    final hasDefault = settings.defaultModelId != null;

    // 与 sendMessage 一致的路由判断：无本地意图且激活了 API → 走 API；
    // 否则 local-first（本地当前原生视觉未支持，一律不送图）。
    final useApi = activeApi != null && !hasLocalLoaded && !hasDefault;
    final visionCapable = useApi
        ? activeApi.visionCapable
        : kLocalVisionSupported; // 本地路线：原生视觉未支持 → false

    if (!visionCapable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ 当前模型不支持视觉，图片仅展示、不会发送给模型')),
      );
    }
  }

  // ------------------------------------------------------------------------
  // 语音拾音（按住说话 → 松手自动发送）
  // ------------------------------------------------------------------------

  /// 松手后的收声缓冲：用户往往"手比嘴快"（话说完才松手），松手即停会把句尾
  /// 截断。松手先等 1 秒让 ASR 继续收声定稿，再真正停止录音。
  static const Duration _voiceLinger = Duration(milliseconds: 1000);

  /// 按住麦克风开始拾音。返回是否真正开始（模型支持语音且权限已授予）。
  // ---- 端侧语音接入（sherpa-onnx 流式 ASR，DSH-Phone 方案）----
  // 放弃「录音文件喂 LLM」的语音方案：长按说话 → 端侧实时转写 → 文本直接
  // 发送。模型 ~160MB 首次使用时经 AsrModelGate 下载（hf-mirror 断点续传）。

  Future<void> _onVoiceLongPressStart(BuildContext ctx, Offset pos) async {
    if (_voiceSession != null) return;
    // 若上一段还在松手缓冲期（用户松手后又立刻按住）：先丢弃上一段录音再开新
    // 录音，别让旧引擎麦克风常开 / 两段录音串味。
    await _cancelPendingVoiceEnd();
    try {
      debugPrint('[Voice] long-press: requesting mic permission');
      final hasMic =
          await StoragePermissionService.requestMicrophonePermission();
      if (!hasMic) {
        debugPrint('[Voice] mic permission denied');
        if (mounted) _showMicPermissionDialog();
        return;
      }
      debugPrint('[Voice] mic ok; checking ASR model');
      final ready = await AsrModelGate.ensureModelReady(ctx);
      if (!ready) {
        debugPrint('[Voice] ASR model not ready (用户取消/下载失败)');
        if (mounted) {
          ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(
              content: Text('语音模型未就绪（下载未完成或已取消），'
                  '再次长按可重新下载/继续断点')));
        }
        return;
      }
      debugPrint('[Voice] model ready; starting hold session');
      final session = HoldToTalkSession();
      _voiceSession = session;
      _voiceLongPressPos = pos;
      final ok = await session.start(this.context);
      if (!ok) {
        _voiceSession = null;
        debugPrint('[Voice] session start failed');
        if (mounted) {
          ScaffoldMessenger.of(this.context)
              .showSnackBar(const SnackBar(content: Text('语音引擎启动失败，请重试')));
        }
      }
    } catch (e) {
      _voiceSession = null;
      debugPrint('[Voice] long-press start error: $e');
      if (mounted) {
        ScaffoldMessenger.of(this.context)
            .showSnackBar(SnackBar(content: Text('语音启动异常：$e')));
      }
    }
  }

  void _onVoiceLongPressMoveUpdate(Offset pos) {
    final session = _voiceSession;
    final start = _voiceLongPressPos;
    if (session == null || start == null) return;
    session.cancelMode.value =
        (pos.dy - start.dy) < -HoldToTalkSession.cancelSlop;
  }

  Future<void> _onVoiceLongPressEnd() async {
    final session = _voiceSession;
    if (session == null) return;
    _voiceSession = null;
    _voiceLongPressPos = null;
    final cancelled = session.cancelMode.value;
    // 上滑取消意图明确 = 立即取消，无需缓冲；普通发送才给 1 秒收声缓冲，
    // 免得用户手比嘴快、句尾被截断。
    if (cancelled) {
      await _finalizeVoice(session, cancelled: true);
      return;
    }
    _pendingVoiceSession = session;
    _pendingVoiceEnd = Timer(_voiceLinger, () {
      _pendingVoiceSession = null;
      _pendingVoiceEnd = null;
      unawaited(_finalizeVoice(session, cancelled: false));
    });
  }

  /// 定稿一段录音：停止引擎 → 取终稿 → 空则提示、非空则补进输入框并发送。
  /// end() 触及引擎收尾（引擎往返/录音停止），任何异常都不允许外抛——release
  /// 下未捕获异常会直接杀死 App（语音链路崩溃兜底）。
  Future<void> _finalizeVoice(HoldToTalkSession session,
      {required bool cancelled}) async {
    String text = '';
    try {
      text = await session.end(cancelled: cancelled);
    } catch (e) {
      debugPrint('[Voice] session end error: $e');
      if (mounted) {
        ScaffoldMessenger.of(this.context)
            .showSnackBar(SnackBar(content: Text('语音收尾异常：$e')));
      }
      return;
    }
    if (!mounted) return;
    if (text.isEmpty) {
      if (!cancelled) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未识别到内容，请重试')));
      }
      return;
    }
    // 识别文本直接发送（附加输入框已有文字，语音即完整消息）。
    final existing = _textController.text.trim();
    _textController.text = existing.isEmpty ? text : '$existing $text';
    _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length));
    try {
      await _sendMessage();
    } catch (e) {
      debugPrint('[Voice] send error: $e');
    }
  }

  /// 取消尚未定稿的"松手缓冲"：取消计时器；若缓冲期内又按住开新录音，则立即
  /// 停止并丢弃上一段（cancelled），别让旧引擎麦克风常开 / 录音串味。
  Future<void> _cancelPendingVoiceEnd() async {
    final session = _pendingVoiceSession;
    final timer = _pendingVoiceEnd;
    _pendingVoiceSession = null;
    _pendingVoiceEnd = null;
    if (timer == null) return;
    timer.cancel();
    if (session != null) await _finalizeVoice(session, cancelled: true);
  }

  /// 麦克风权限被拒：引导去系统设置授权（无需重装 APK）。
  void _showMicPermissionDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要麦克风权限'),
        content: const Text(
          '语音输入需要「麦克风」权限。\n\n'
          '不需要重新安装：点击「前往设置」打开本应用权限页，把「麦克风」打开即可。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await openAppSettings();
            },
            icon: const Icon(Icons.settings),
            label: const Text('前往设置'),
          ),
        ],
      ),
    );
  }

  /// Send message with optional images / attachments / audio
  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    final imagePaths = List<String>.from(_selectedImagePaths);
    final attachmentPaths = List<String>.from(_selectedFilePaths);
    if (text.isEmpty && imagePaths.isEmpty) return;

    // 插件接管（chain 槽 `app.composer.takeover`）：先问一圈"这段输入你接不接"。
    // 没有插件填这个槽时 resolveTakeover 返回 null —— 行为与今天逐字一致。
    final takeover = resolveTakeover(
      ref.read(slotRegistryProvider),
      'app.composer.takeover',
      {'text': text, 'imagePaths': imagePaths},
    );
    if (takeover != null) {
      final handler = takeover.value;
      if (handler is ComposerTakeover) {
        final handled = await handler(text, imagePaths);
        if (handled) {
          _textController.clear();
          _selectedImagePaths.clear();
          _selectedFilePaths.clear();
          if (mounted) setState(() {});
          return;
        }
      }
    }

    // Collapse the keyboard immediately when sending so the chat area expands
    // to full screen while the reply streams in (don't wait for the reply).
    FocusScope.of(context).unfocus();

    final notifier = ref.read(chatNotifierProvider.notifier);
    // Turn on "follow the conversation" the instant we send. _sendMessage
    // awaits the full generation, so if we only enabled following afterwards
    // the streamed reply would scroll into view only once it finished. This
    // also covers the case where the user had scrolled up to read history
    // right before hitting send.
    _followStream = true;
    // Clear the input box immediately: the message is already composed in
    // `text` and is about to be dispatched to the model. Keeping the text in
    // the box until the whole reply finishes is confusing — it should empty
    // the moment the message is sent. 语音消息同样清空输入框（文字已随语音发送）。
    _textController.clear();
    _drafts.remove(_currentConversationId);
    setState(() {
      _selectedImagePaths.clear();
      _selectedFilePaths.clear();
    });
    try {
      await notifier.sendMessage(_currentConversationId, text,
          imagePath: imagePaths.isNotEmpty ? imagePaths.first : null,
          imagePaths: imagePaths,
          attachmentPaths: attachmentPaths);
    } catch (e) {
      // The send failed before leaving the client — restore the input so the
      // user can retry. (If it failed mid-generation the message is already
      // persisted and shown in the chat, so no restore needed there.)
      _textController.text = text;
      setState(() {
        _selectedImagePaths
          ..clear()
          ..addAll(imagePaths);
        _selectedFilePaths
          ..clear()
          ..addAll(attachmentPaths);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('发送失败: $e', style: const TextStyle(color: Colors.white))),
      );
      return;
    }

    // Safety-net re-anchor once the reply is fully generated. Following was
    // already active during streaming (set true at send time, pinned while
    // isGenerating). This guarantees the final message is in view even if the
    // last streamed chunk arrived between two 500ms list refreshes.
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Stop the in-flight reply. Native side sets should_stop, the completion
  /// loop returns promptly, the token stream closes and isGenerating flips
  /// back to false (so the button reverts to send mode automatically).
  Future<void> _stopGeneration() async {
    try {
      // 只停当前会话的回合（其他会话的并发回合不受影响）。
      await ref
          .read(chatNotifierProvider.notifier)
          .stopGeneration(conversationId: _currentConversationId);
    } catch (e) {
      debugPrint('[HomeScreen] stopGeneration failed: $e');
    }
  }

  // =========================================================================
  // Dev 工作区（2026-10-27）：聊天顶栏看得见"在哪干活"，点一下就能切。
  //
  // 为什么必须放聊天里：**激活哪个工作区**决定模型收到哪段
  // `<workspace:context>`（远端工作区才会走 ssh_* 工具在电脑上读写/跑命令）。
  // 以前这份选择只存在于设置页深处的一组 ChoiceChip，聊天里完全不可见，
  // 而且激活态不持久化 → 用户"连上了远程电脑，它却还在手机本地瞎忙"。
  // =========================================================================

  /// 工作区图标。
  IconData _workspaceIcon(WorkspaceBackend backend) => switch (backend) {
        WorkspaceBackend.localApp ||
        WorkspaceBackend.embedded =>
          Icons.phone_android,
        WorkspaceBackend.termux => Icons.terminal,
        WorkspaceBackend.remotePc => Icons.desktop_windows,
      };

  /// 远端工作区的连接判据：已连接**且**连的就是它绑定的那份配置
  /// （没绑定 id 时，任一在连的配置都算）。
  bool _workspaceConnected(DevWorkspace ws) {
    if (!ws.isRemote) return true;
    final ssh = SshEnvironmentService.instance;
    if (!ssh.isConnected) return false;
    final bound = ws.sshConfigId?.trim() ?? '';
    return bound.isEmpty || ssh.activeConfig?.id == bound;
  }

  void _devSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  /// 顶栏工作区胶囊（只在开发模式开启时渲染，关掉 = 零变化零回归）。
  Widget _buildDevWorkspaceChip() {
    if (!ref.watch(settingsProvider).devModeEnabled) {
      return const SizedBox.shrink();
    }
    final dev = DevSessionController.instance;
    final ws = dev.workspaces.any((w) => w.id == dev.activeWorkspaceId)
        ? dev.activeWorkspace
        : DevWorkspace.defaultWorkspace;
    final isRemote = ws.isRemote;
    final connected = _workspaceConnected(ws);
    final color = !isRemote
        ? Theme.of(context).colorScheme.primary
        : (connected ? Colors.green : Colors.orange);
    // 连接状态**只用图标颜色**说（绿=已连 / 橙=未连 / 主色=本地）：胶囊里再
    // 挂「· 已连接 / 未连接」是把工作区名字挤没的纯冗余（2026-10-28 用户指令），
    // 状态与后端类型收进 tooltip，点开的切换列表里也各有一行。
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: ActionChip(
        avatar: Icon(_workspaceIcon(ws.backend), size: 15, color: color),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            ws.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        tooltip: '当前工作区：${ws.name}（${workspaceBackendLabel(ws.backend)}'
            '${isRemote ? (connected ? ' · 已连接' : ' · 未连接') : ''}）\n'
            '智能体只在这个工作区里读写文件与执行命令，点按可切换',
        onPressed: _showWorkspaceSheet,
      ),
    );
  }

  /// 工作区切换面板：列全部工作区（含远端连接状态、就地连接）+ 一键开工。
  Future<void> _showWorkspaceSheet() async {
    final dev = DevSessionController.instance;
    await dev.init(
        preferredActiveId: ref.read(settingsProvider).devWorkspaceId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text('在哪个工作区干活',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '智能体按「激活的工作区」读写文件、跑命令：远端工作区走 SSH '
                    '在你电脑上执行，本地工作区只在手机目录里。',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ),
                for (final ws in dev.workspaces) _workspaceTile(ctx, ws, setSheet),
                const Divider(height: 1),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _createWorkspaceFromActiveConnection();
                  },
                  icon: const Icon(Icons.add_link, size: 16),
                  label: Text(SshEnvironmentService.instance.isConnected
                      ? '用当前连接（${SshEnvironmentService.instance.activeConfig?.name}）'
                          '新建工作区'
                      : '用当前连接新建工作区（需先连接）'),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _openRail('dev');
                  },
                  icon: const Icon(Icons.settings, size: 16),
                  label: const Text('管理连接与工作区'),
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _workspaceTile(BuildContext ctx, DevWorkspace ws, StateSetter setSheet) {
    final dev = DevSessionController.instance;
    final active = dev.activeWorkspaceId == ws.id;
    final connected = _workspaceConnected(ws);
    final sub = [
      workspaceBackendLabel(ws.backend),
      if (ws.isRemote && (ws.remotePath ?? '').isNotEmpty) ws.remotePath!,
      if (ws.isRemote) (connected ? '已连接' : '未连接'),
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: Icon(
        _workspaceIcon(ws.backend),
        size: 18,
        color: active ? Theme.of(ctx).colorScheme.primary : null,
      ),
      title: Text(ws.name,
          style: TextStyle(fontWeight: active ? FontWeight.w600 : null)),
      subtitle: Text(
        sub,
        style: TextStyle(
          fontSize: 11,
          color: ws.isRemote && !connected
              ? Colors.orange.shade800
              : Colors.grey.shade600,
        ),
      ),
      trailing: active
          ? Icon(Icons.check_circle,
              size: 18, color: Theme.of(ctx).colorScheme.primary)
          : (ws.isRemote && !connected
              ? TextButton(
                  onPressed: () async {
                    final err = await connectWorkspace(ws,
                        ref.read(settingsProvider).sshConfigs);
                    if (!ctx.mounted) return;
                    setSheet(() {});
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text(
                            err == null ? '✅ 已连接 ${ws.name}' : '❌ $err')));
                  },
                  child: const Text('连接', style: TextStyle(fontSize: 12)),
                )
              : null),
      onTap: () async {
        await dev.switchWorkspace(ws.id);
        await ref.read(settingsProvider.notifier).setDevWorkspaceId(ws.id);
        if (!ctx.mounted) return;
        Navigator.pop(ctx);
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text('已切到工作区「${ws.name}」'
                '（${workspaceBackendLabel(ws.backend)}），直接说需求就行')));
      },
    );
  }

  /// 用当前已连接的电脑/Termux 一键建工作区（自动建 ~/projects/<名> 并切过去）。
  Future<void> _createWorkspaceFromActiveConnection() async {
    final ssh = SshEnvironmentService.instance;
    final cfg = ssh.activeConfig;
    if (cfg == null || !ssh.isConnected) {
      _devSnack('还没有已连接的开发环境：先到 设置 → 开发者 → 远程电脑 点「连接」'
          '（用账号密码就行），再回来建工作区');
      return;
    }
    final kind = sshTargetKindOf(cfg);
    final suggested = cfg.name.trim().isEmpty
        ? (kind == SshTargetKind.termux ? 'Termux 项目' : '远程项目')
        : cfg.name.trim();
    final ctrl = TextEditingController(text: suggested);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('在「${cfg.name.isEmpty ? cfg.host : cfg.name}」上开工'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '项目/工作区名称',
                helperText: '会在电脑上建 ~/projects/<名称> 并作为工作区目录',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('创建并切过去')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    _devSnack('正在电脑上建目录…');
    final r = await createWorkspaceOnActiveConnection(name);
    if (r.ws == null) {
      _devSnack('❌ ${r.dir}');
      return;
    }
    await ref.read(settingsProvider.notifier).setDevWorkspaceId(r.ws!.id);
    _devSnack('✅ 已切到工作区「${r.ws!.name}」（${r.dir}）：现在让它「看项目 / '
        '改代码 / 跑测试」都会在这台电脑上执行');
  }

  @override
  Widget build(BuildContext context) {
    // 生成态按「当前会话」判定：多会话并发时，别的会话在跑不影响本会话
    // 的发送按钮（本会话自己在跑才显示停止键）。
    final isGenerating =
        ref.watch(runningTurnsProvider).containsKey(_currentConversationId);
    final modelState = ref.watch(modelManagerProvider);
    final slots = ref.watch(slotRegistryProvider);

    // harness 布局：左栏（能力/配置入口）+ 主区（AppBar + 消息 + composer）。
    // 面板从左滑入、只盖主区（含 AppBar），rail 恒可见。
    return Scaffold(
      // 设计稿结构：状态栏条带 = 应用底色，左栏/画布从状态栏下开始——
      // 左栏背景不许捅进状态栏（此前 SafeArea 放在栏内部只挪了内容）。
      body: SafeArea(
        bottom: false,
        child: RailPanelHost(
          controller: _railPanel,
          pages: _railPages(),
          rail: _buildRail(slots),
          child: Scaffold(
            appBar: AppBar(
              // 紧凑标题栏：44px（默认 56）。导航默认全在左栏（设计稿无 leading）；
              // 侧边栏折叠态（logo 点击收起）时顶栏左上角显示恢复 Logo。
              // 常驻底部分界线（设计稿 border-bottom）：状态栏条带/顶栏/消息区
              // 同底色，没这条线三者融成一片。
              shape: Border(
                bottom: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
              toolbarHeight: 44,
              leading: _railCollapsed
                  ? Tooltip(
                      message: '展开侧边栏',
                      child: GestureDetector(
                        onTap: () => setState(() => _railCollapsed = false),
                        // Center + 固定尺寸：AppBar leading 默认约束会把
                        // 无对齐的 Container 拉伸变形（2026-10-25 真机截图）。
                        child: Center(
                          child: Container(
                            width: 30,
                            height: 30,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              borderRadius:
                                  BorderRadius.all(Radius.circular(10)),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color(0xFF7C5CFC),
                                  Color(0xFF5B8DEF)
                                ],
                              ),
                            ),
                            child: const Icon(Icons.auto_awesome,
                                size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    )
                  : null,
              title: const Text(
                'TongYi-Lite',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              actions: [
                _buildDevWorkspaceChip(),
                _buildModelStatusChip(modelState, isGenerating),
              ],
            ),
            body: Column(
              children: [
                // ---- Inline model status (only shows loading/unloading/error progress) ----
                _buildInlineProgress(modelState, isGenerating),

                Expanded(
                  child: _initiallyLoaded
                      ? _buildMessagesList()
                      : const Center(child: CircularProgressIndicator()),
                ),

                // 附件预览已并入 composer 卡片（chips 行，可单个删除）。
                _buildInputBar(isGenerating, modelState),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // 左栏 harness（2026-10-24）：rail 条目 + 面板页注册
  // =========================================================================

  /// 打开/收起某面板（再点同图标 = 收起）。打开会话页时失效摘要缓存并
  /// 刷新计划徽标。
  void _openRail(String key) {
    if (key == 'chats') {
      _invalidateSnippets();
      _refreshActivePlanFlag();
    }
    _railPanel.toggle(key);
  }

  /// 关闭所有会话类浮层（面板 + 兼容旧 Drawer 入口）：切换/新建会话后调用。
  void _closeRailSurface() {
    _railPanel.close();
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isDrawerOpen) {
      Navigator.of(context).pop();
    }
  }

  /// 左栏折叠态（2026-10-25 用户需求）：点 rail 的 Logo **完全隐藏**侧边栏
  /// （非窄条），恢复 Logo 出现在顶栏左上角；对话区/输入框铺满全宽。
  bool _railCollapsed = false;

  Widget _buildRail(SlotRegistry registry) {
    final anyRunning = ref.watch(runningTurnsProvider).isNotEmpty;
    if (_railCollapsed) return const SizedBox.shrink();
    return AppRail(
      onLogoTap: () {
        setState(() => _railCollapsed = true);
        _railPanel.close(); // 收起 = 看全宽内容，开着面板会挡住。
      },
      logoTooltip: '收起侧边栏',
      children: [
        RailIconButton(
          item: RailItem(
              icon: Icons.add,
              tooltip: '新建会话',
              onTap: _newConversationFromRail),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'chats',
              icon: Icons.forum_outlined,
              tooltip: '会话',
              onTap: () => _openRail('chats'),
              badge: anyRunning),
        ),
        // 模型管理类入口紧跟会话、在智能体之前（2026-10-25 用户定案：
        // 本地模型优先的产品形态，模型是第一公民，先进模型再谈智能体）。
        RailIconButton(
          item: RailItem(
              panelKey: 'model',
              icon: Icons.memory_outlined,
              tooltip: '模型',
              onTap: () => _openRail('model')),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'engine',
              icon: Icons.tune,
              tooltip: '推理引擎',
              onTap: () => _openRail('engine')),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'api',
              icon: Icons.api_outlined,
              tooltip: 'API 接入',
              onTap: () => _openRail('api')),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'agent',
              icon: Icons.smart_toy_outlined,
              tooltip: '智能体',
              onTap: () => _openRail('agent')),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'persona',
              icon: Icons.theater_comedy,
              tooltip: '人格',
              onTap: () => _openRail('persona')),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'plan',
              icon: Icons.checklist,
              tooltip: '计划',
              onTap: () => _openRail('plan'),
              badge: _hasActivePlan),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'skills',
              icon: Icons.auto_awesome_outlined,
              tooltip: '技能',
              onTap: () => _openRail('skills')),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'plugins',
              icon: Icons.extension_outlined,
              tooltip: '插件',
              onTap: () => _openRail('plugins')),
        ),
        RailIconButton(
          item: RailItem(
              panelKey: 'dev',
              icon: Icons.code,
              tooltip: 'Dev Agent',
              onTap: () => _openRail('dev')),
        ),
        // 插件槽位：插件可向左栏贡献入口图标（无插件时零渲染）。
        SlotOutlet(slotId: 'app.rail', registry: registry),
      ],
      bottomChildren: [
        RailIconButton(
          item: RailItem(
              panelKey: 'more',
              icon: Icons.more_horiz,
              tooltip: '更多',
              onTap: () => _openRail('more')),
        ),
      ],
    );
  }

  /// 新建会话（左栏入口，无 Drawer 可 pop）：直接复用 [_newConversation]。
  Future<void> _newConversationFromRail() async {
    await _newConversation();
  }

  Map<String, RailPageSpec> _railPages() => {
        'chats': RailPageSpec(
            title: '会话', build: (_) => _buildConversationDrawerBody()),
        'agent':
            RailPageSpec(title: '智能体', build: (_) => _buildAgentRailPage()),
        'persona':
            RailPageSpec(title: '人格', build: (_) => _buildPersonaRailPage()),
        'plan': RailPageSpec(title: '计划', build: (_) => _buildPlanRailPage()),
        'model': RailPageSpec(title: '模型', build: (_) => _buildModelRailPage()),
        // 引擎单拆（2026-10-25 用户定案）：推理引擎是大块设置，不再与模型
        // 挤一页双段开关——模型页只管模型，引擎页只管引擎。
        'engine': RailPageSpec(
            title: '引擎', build: (_) => const InferenceEngineSettingsBody()),
        'skills':
            RailPageSpec(title: '技能', build: (_) => _buildSkillsRailPage()),
        'plugins':
            RailPageSpec(title: '插件', build: (_) => _buildPluginsRailPage()),
        'api': RailPageSpec(title: 'API 接入', build: (_) => _buildApiRailPage()),
        'dev':
            RailPageSpec(title: 'Dev Agent', build: (_) => DevSettingsBody()),
        'search':
            RailPageSpec(title: '搜索', build: (_) => WebSearchSettingsBody()),
        'capability': RailPageSpec(
            title: '能力与实验', build: (_) => CapabilitySettingsBody()),
        'storage': RailPageSpec(
            title: '存储 / 日志 / 关于', build: (_) => _buildStorageAboutRailPage()),
        // 关于独立页（2026-10-25 用户定案）：存储/日志已有别处入口，
        // 「更多（基础配置）」的下属入口只留关于。
        'about':
            RailPageSpec(title: '关于', build: (_) => _buildAboutRailPage()),
        'more': RailPageSpec(title: '更多', build: (_) => _buildMoreRailPage()),
      };

  // —— 左栏面板紧凑件（对齐设计稿密度：行高 ~40、字号 13/11、图标 18）——

  /// 小节标题（11px 灰、紧凑上下距）。
  Widget _railSection(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600)),
      );

  /// 通用紧凑行：图标 18 + 标题 13/副题 11 + 尾部（无尾部且可点 = chevron）。
  Widget _railRow({
    IconData? icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                if (subtitle != null)
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (trailing != null)
            trailing
          else if (onTap != null)
            Icon(Icons.chevron_right, size: 16, color: scheme.outline),
        ]),
      ),
    );
  }

  /// 紧凑小开关（30dp 高，shrinkWrap——默认 Switch 触点 48dp 太占行高）。
  Widget _railSwitch(bool value, ValueChanged<bool> onChanged) {
    return SizedBox(
      height: 30,
      child: Switch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// 面板内容卡（surfaceContainerHigh 圆角 12、内距 10——设计稿 p-card）。
  Widget _railCard(Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }


  /// 智能体面板：直接承载设置页「智能体」Tab 全部内容（工具/审批/思考/
  /// MCP/语音播报/热词/记忆/人格/技能/任务规划）——设置封装进新 UI，
  /// 不再跳老设置页。
  Widget _buildAgentRailPage() => AgentSettingsBody();

  /// 人格面板：快速切换器；人格管理在「智能体」面板（面板间跳转，不出新 UI）。
  Widget _buildPersonaRailPage() {
    return Consumer(builder: (context, ref, __) {
      final settings = ref.watch(settingsProvider);
      final notifier = ref.read(settingsProvider.notifier);
      final activeId = settings.activePersonaId;
      final check = Icon(Icons.check,
          size: 16, color: Theme.of(context).colorScheme.primary);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _railRow(
              icon: Icons.person_outline,
              title: '标准',
              onTap: () => notifier.setActivePersona(kStandardPersonaId),
              trailing: activeId == kStandardPersonaId ? check : null,
            ),
            for (final p in settings.agentPersonas)
              _railRow(
                icon: Icons.theater_comedy,
                title: p.name,
                subtitle: p.prompt.isEmpty ? null : p.prompt,
                onTap: () => notifier.setActivePersona(p.id),
                trailing: activeId == p.id ? check : null,
              ),
            const Divider(height: 20),
            _railRow(
                icon: Icons.add,
                title: '新建人格',
                onTap: () => _showPersonaEditor()),
            if (settings.activePersona() != null)
              _railRow(
                  icon: Icons.edit_outlined,
                  title: '编辑当前人格',
                  subtitle: settings.activePersona()!.name,
                  onTap: () =>
                      _showPersonaEditor(existing: settings.activePersona())),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text('切换人格会重置 KV 缓存，下一轮重新理解上下文',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          ],
        ),
      );
    });
  }

  /// 人格新建/编辑对话框（含删除）：管理能力内联在人格面板完成。
  Future<void> _showPersonaEditor({AgentPersona? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final promptCtrl = TextEditingController(text: existing?.prompt ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '新建人格' : '编辑人格'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                  hintText: '人格名称', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: promptCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                  hintText: '人设提示词（注入智能体系统提示词）', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          if (existing != null && existing.id != kStandardPersonaId)
            TextButton(
              onPressed: () async {
                await ref
                    .read(settingsProvider.notifier)
                    .deletePersona(existing.id);
                Navigator.pop(ctx, true);
              },
              child: const Text('删除', style: TextStyle(color: Colors.red)),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    await ref.read(settingsProvider.notifier).upsertPersona(AgentPersona(
          id: existing?.id ?? const Uuid().v4(),
          name: name,
          prompt: promptCtrl.text.trim(),
        ));
  }

  /// 计划面板：复用 _PlanPanelSheet（原 bottom sheet 内容原样内嵌）。
  Widget _buildPlanRailPage() {
    return FutureBuilder<GoalStore>(
      future: _planStore(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        // 全部计划（2026-10-25 用户需求）：跨会话按时间倒序浏览，完成与否
        // 可见；会话已删的计划可单独删除；点行切换到对应会话。
        return Column(
          children: [
            _AllPlansSection(
              store: snap.data!,
              onOpenConversation: (id) {
                _switchConversation(id);
                _railPanel.close();
              },
            ),
            Expanded(
              child: _PlanPanelSheet(
                store: snap.data!,
                conversationId: _currentConversationId,
                onRegenerate: () {
            final text = _textController.text;
            if (!text.startsWith(_planPrefix)) {
              _textController.text = '$_planPrefix${text.trimLeft()}';
              _textController.selection = TextSelection.fromPosition(
                  TextPosition(offset: _textController.text.length));
            }
            FocusScope.of(context).requestFocus(FocusNode());
          },
                onChanged: _refreshActivePlanFlag,
                onClose: _closeRailSurface,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 模型面板：一行紧凑状态条（点按弹状态详情）+ 推理引擎设置主体。
  /// 此前嵌整张状态大卡：①吃掉面板上半的滚动手势（上翻失灵）；
  /// ②「去加载模型」在面板里无处可去（引擎设置/模型列表就在本页下方）——都废除。
  Widget _buildModelRailPage() {
    return Consumer(builder: (context, ref, __) {
      final ms = ref.watch(modelManagerProvider);
      final isGenerating = ref.watch(runningTurnsProvider).isNotEmpty;
      final modelName = ms.modelName ?? (ms.modelId ?? '未加载模型');
      final scheme = Theme.of(context).colorScheme;
      final statusColor = _statusColorFor(ms.phase);
      return Column(
        children: [
          InkWell(
            onTap: () => _showModelStatusPopup(ms, isGenerating),
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(12)),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                border:
                    Border(bottom: BorderSide(color: scheme.outlineVariant)),
              ),
              child: Row(children: [
                Icon(_statusIconFor(ms.phase), size: 18, color: statusColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_statusLabelFor(ms.phase, isGenerating),
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w600)),
                      Text(modelName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (isGenerating)
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right,
                    size: 16, color: scheme.onSurfaceVariant),
              ]),
            ),
          ),
          Expanded(child: const ModelManagementBody()),
        ],
      );
    });
  }

  IconData _statusIconFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return Icons.memory_outlined;
      case ModelLifecyclePhase.loading:
        return Icons.sync_alt;
      case ModelLifecyclePhase.loaded:
        return Icons.check_circle;
      case ModelLifecyclePhase.unloading:
        return Icons.sync_disabled;
      case ModelLifecyclePhase.error:
        return Icons.error_outline;
    }
  }

  Color _statusColorFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return Colors.grey;
      case ModelLifecyclePhase.loading:
        return Colors.blue;
      case ModelLifecyclePhase.loaded:
        return Colors.green;
      case ModelLifecyclePhase.unloading:
        return Colors.orange;
      case ModelLifecyclePhase.error:
        return Colors.red;
    }
  }

  String _statusLabelFor(ModelLifecyclePhase phase, bool isGenerating) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return '未加载';
      case ModelLifecyclePhase.loading:
        return '加载中…';
      case ModelLifecyclePhase.loaded:
        return isGenerating ? '推理中' : '已加载';
      case ModelLifecyclePhase.unloading:
        return '卸载中…';
      case ModelLifecyclePhase.error:
        return '加载失败';
    }
  }

  /// 技能面板：说明 + 管理入口（技能卡全量在「智能体」面板内）。
  Widget _buildSkillsRailPage() {
    // harness 第八轮（2026-10-25 用户定案）：技能面板**就地全量管理**——
    // 新增/编辑/删除/重扫/内置查看全部内联，不再跳「智能体」面板
    // （此前这里是占位跳转，被用户点名批评）。
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 内置数量随发版变，不写死（技能库标题里已有动态计数）。
          _railCard(const Text(
            '技能 = 智能体按需加载的能力包，模型经 load_skill 启用，'
            '技能卡在对话里展示执行过程。点技能库标题可收起列表。',
            style: TextStyle(fontSize: 12, height: 1.5),
          )),
          const SizedBox(height: 8),
          _railCard(const SkillsManagementBody()),
        ],
      ),
    );
  }

  /// 插件面板：插件管理（内嵌形态）直接在面板里完成，不再整屏跳转。
  Widget _buildPluginsRailPage() => const PluginsScreen(embedded: true);

  /// API 面板：设置页「API」Tab 全量（端点/密钥/模型列表/路由）。
  Widget _buildApiRailPage() => ApiSettingsBody();

  /// 更多面板：入口全部指向面板内页（老设置页零跳转）。
  /// 「更多」面板 = **基础配置**（2026-10-25 用户定案）：界面缩放 + 语音
  /// （TTS/ASR）+ 无重复归属的唯一下属入口（搜索/存储日志关于）。
  /// 已撤的重复入口：搜索（API 接入面板有联网搜索配置）、能力与实验
  /// （原生能力开关=智能体面板、TTS/ASR=本页、插件/技能=各自面板）。
  Widget _buildMoreRailPage() {
    return Consumer(builder: (context, ref, __) {
      final scale = ref.watch(settingsProvider).uiScale.clamp(0.85, 1.30);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _railSection('界面'),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: scale,
                    min: 0.85,
                    max: 1.30,
                    divisions: 9,
                    label: '${(scale * 100).toStringAsFixed(0)}%',
                    onChanged: (v) =>
                        ref.read(settingsProvider.notifier).setUiScale(v),
                  ),
                ),
                Text('${(scale * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
            const Text('整体缩放全部 UI（85%–130%）',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 10),
            // 外观（2026-10-25）：浅色/深色/跟随系统，默认跟随系统。
            _railSection('外观'),
            Wrap(
              spacing: 8,
              children: [
                for (final (value, label) in const [
                  ('system', '跟随系统'),
                  ('light', '浅色'),
                  ('dark', '深色'),
                ])
                  ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: ref.watch(settingsProvider).themeMode == value,
                    onSelected: (_) => ref
                        .read(settingsProvider.notifier)
                        .setThemeMode(value),
                  ),
              ],
            ),
            _railSection('快捷设置'),
            // composer 快捷图标带管理（KV 环右侧）：默认全关，
            // 开哪个 composer 就出现哪个图标（agent=直切开关，其余=开面板）。
            _railCard(
              Column(
                children: [
                  for (final (id, _, label) in _quickActionCatalog)
                    _railRow(
                      title: label,
                      subtitle: id == 'agent' ? '点按直切智能体/纯聊天' : '点按打开面板',
                      trailing: _railSwitch(
                        ref.watch(settingsProvider)
                            .composerQuickActions
                            .contains(id),
                        (on) => ref
                            .read(settingsProvider.notifier)
                            .toggleComposerQuickAction(id, on),
                      ),
                    ),
                ],
              ),
            ),
            _railSection('语音'),
            const VoiceSettingsBody(),
            _railSection('更多入口'),
            _railRow(
                icon: Icons.info_outline,
                title: '关于',
                subtitle: '版本 · 说明',
                onTap: () => _railPanel.open('about')),
          ],
        ),
      );
    });
  }

  /// 存储/日志/关于合页（三个卡片式组件纵排）。
  Widget _buildStorageAboutRailPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      children: [
        StorageInfoWidget(),
        const SizedBox(height: 8),
        RecentLogsWidget(),
        const SizedBox(height: 8),
        AboutSettingsCard(),
      ],
    );
  }

  /// 关于独立页：只有版本/说明卡（存储与日志已另有归属）。
  Widget _buildAboutRailPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      children: [AboutSettingsCard()],
    );
  }

  // =========================================================================
  String _fileNameOf(String path) {
    final i = path.lastIndexOf('/');
    return i == -1 ? path : path.substring(i + 1);
  }

  // Model status chip — compact indicator in AppBar leading area (left of title)
  // Tapping opens a bottom sheet with model name, unload / reload actions
  // =========================================================================

  Widget _buildModelStatusChip(ModelState ms, bool isGenerating) {
    final color = _colorFor(ms.phaseColor);

    // Idle + not generating → no chip needed (leading returns null-like empty widget)
    if (ms.phase == ModelLifecyclePhase.idle && !isGenerating) {
      return const SizedBox.shrink();
    }

    Widget label;
    IconData chipIcon;
    switch (ms.phase) {
      case ModelLifecyclePhase.loading:
        chipIcon = Icons.sync_alt;
        label = const Text('加载中…',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
      case ModelLifecyclePhase.loaded:
        chipIcon = isGenerating ? Icons.auto_awesome : Icons.check_circle;
        label = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isGenerating) _buildPulsingDot(),
            const SizedBox(width: 4),
            Text(
              ms.modelName ?? (ms.modelId ?? '模型就绪'),
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: color),
            ),
          ],
        );
        break;
      case ModelLifecyclePhase.unloading:
        chipIcon = Icons.sync_disabled;
        label = const Text('卸载中…',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
      case ModelLifecyclePhase.error:
        chipIcon = Icons.error_outline;
        label = const Text('加载失败',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
      case ModelLifecyclePhase.idle:
        chipIcon = Icons.memory_outlined;
        label = const Text('未加载',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showModelStatusPopup(ms, isGenerating),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(chipIcon, size: 16, color: color),
              const SizedBox(width: 4),
              label,
            ],
          ),
        ),
      ),
    );
  }

  void _showModelStatusPopup(ModelState ms, bool isGenerating) {
    final notifier = ref.read(modelManagerProvider.notifier);
    // Resolve the display name consistently with the chip: loaded modelName
    // (catalog, already cleaned) → modelId → fallback. Avoids "未知模型".
    final modelName = ms.modelName ?? (ms.modelId ?? '未知模型');

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      // Sheet now carries a memory panel + logs + buttons; without
      // isScrollControlled the default 9/16-screen cap clips the content.
      isScrollControlled: true,
      builder: (ctx) => _ModelStatusSheet(
        phase: ms.phase,
        modelName: modelName,
        errorMessage: ms.errorMessage,
        logs: ms.loadingLogs,
        isGenerating: isGenerating,
        ref: ref,
        onUnload: () async {
          Navigator.pop(ctx);
          final ok = await notifier.unloadModel();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ok ? '✅ 已卸载模型，已释放内存' : '❌ 卸载失败，请重试'),
              backgroundColor: ok ? Colors.green : Colors.red,
              duration: const Duration(seconds: 2),
            ),
          );
        },
        onLoad: () async {
          final id = ms.modelId;
          if (id != null) {
            Navigator.pop(ctx);
            // 若正在推理，先停止生成（全部回合，模型即将重载），
            // 避免卸载/重载时原生引擎崩溃（红屏）。
            if (ref.read(runningTurnsProvider).isNotEmpty) {
              try {
                await ref.read(chatNotifierProvider.notifier).stopGeneration();
              } catch (_) {}
              await Future.delayed(const Duration(milliseconds: 300));
            }
            await notifier.loadModel(id);
          }
        },
        onGoToSettings: () {
          Navigator.pop(ctx);
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()));
        },
      ),
    );
  }

  /// Thin progress strip shown below the app bar only during loading / unloading / error.
  /// Hidden when idle and not generating — no space wasted.
  Widget _buildInlineProgress(ModelState ms, bool isGenerating) {
    // Only show during loading / unloading / error — idle and loaded states
    // are handled by the AppBar chip (no space wasted on chat area).
    if (ms.phase == ModelLifecyclePhase.idle ||
        ms.phase == ModelLifecyclePhase.loaded) {
      return const SizedBox.shrink();
    }

    final color = _colorFor(ms.phaseColor);
    final generating = isGenerating ? ' · 思考中…' : '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: color.withValues(alpha: 0.10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (ms.phase == ModelLifecyclePhase.loading ||
                  ms.phase == ModelLifecyclePhase.unloading)
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  ms.modelName != null && ms.modelName!.isNotEmpty
                      ? '${ms.modelName!}$generating'
                      : (isGenerating ? '推理中…' : '模型未加载'),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          // Loading log or error message shown below the status row
          if (ms.phase == ModelLifecyclePhase.loading && ms.latestLog != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                ms.latestLog!,
                style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (ms.phase == ModelLifecyclePhase.error && ms.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      ms.errorMessage!,
                      style:
                          TextStyle(fontSize: 11, color: Colors.red.shade700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: ms.modelId != null
                        ? () => ref
                            .read(modelManagerProvider.notifier)
                            .loadModel(ms.modelId!)
                        : null,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('重试', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 手动压缩确认 + 执行：回合执行中拒绝（与活动回合的会话日志竞争）；
  /// 完成后 SnackBar 反馈（清理条数 0 = 没有可压缩的旧工具记录）。
  Future<void> _confirmManualCompact() async {
    final running =
        ref.read(runningTurnsProvider).containsKey(_currentConversationId);
    if (running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('回合执行中，结束后再压缩')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('手动压缩上下文'),
        content: const Text(
          '把较早轮次的对话与工具结果移出模型上下文（保留最近 3 轮原文与'
          '压缩摘要），聊天记录显示不受影响，下一轮请求立即瘦身。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('压缩'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final (envelopes, chars) = await ref
        .read(chatNotifierProvider.notifier)
        .manualCompact(_currentConversationId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(envelopes == 0
            ? '没有可压缩的旧工具记录'
            : '已压缩：清理 $envelopes 条工具记录，摘要 $chars 字'),
      ),
    );
  }

  /// 上下文 / KV 占用详情面板（输入框占用圈点开）：当前会话占用数字与来源、全部
  /// 会话快照、最近压缩记录（来自推理日志）、阈值图例。
  void _showContextUsageSheet() {
    final usageMap = ref.read(contextUsageProvider);
    final modelState = ref.read(modelManagerProvider);
    final settings = ref.read(settingsProvider);
    final activeApi = settings.activeApiModel();
    final engineName = modelState.isLoaded
        ? (modelState.modelName ?? modelState.modelId ?? '本地模型')
        : (activeApi != null ? activeApi.name : null);

    // 压缩记录：推理日志里带「上下文压缩」前缀的行（chat_provider 落档），
    // 最近 8 条倒序。
    final compactionLines = modelState.loadingLogs
        .where((l) => l.contains('上下文压缩'))
        .toList()
        .reversed
        .take(8)
        .toList();

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final current = usageMap[_currentConversationId];
        final fraction = current?.fraction ?? 0.0;
        final barColor = fraction >= 0.85
            ? const Color(0xFFE53935)
            : fraction >= 0.60
                ? const Color(0xFFFB8C00)
                : const Color(0xFF2196F3);
        final others = usageMap.entries
            .where((e) => e.key != _currentConversationId && e.value.hasData)
            .toList();

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('上下文占用', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  engineName == null ? '当前无激活引擎' : '引擎：$engineName',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                if (current == null || !current.hasData)
                  Text(
                    '当前会话暂无占用数据——发一条消息（或跑一轮智能体）后，'
                    '占用会在每轮响应后更新。',
                    style: theme.textTheme.bodyMedium,
                  )
                else ...[
                  // 大号占用数字 + 进度条。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${(fraction * 100).toStringAsFixed(1)}%',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: barColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_fmtTokens(current.usedTokens)} / '
                          '${_fmtTokens(current.windowTokens)} tokens'
                          '（${current.windowSource}）',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 刻度条 + 自动压缩阈值滑块（默认 80%，可拖动调节，
                  // 2026-10-25 用户需求：拖到哪，占用越线就自动压缩）。
                  _ContextGaugeWithThreshold(fraction: fraction),
                ],
                const SizedBox(height: 12),
                Text(
                  '颜色阈值：蓝 <60% · 橙 ≥60%（留意）· 红 ≥85%（建议压缩或换会话）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                // 手动压缩：存储级清理旧工具轮信封（持久，区别于回合内压缩）。
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.compress, size: 18),
                    label: const Text('手动压缩上下文'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _confirmManualCompact();
                    },
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '把较早轮次的对话与工具结果移出模型上下文（最近 3 轮与压缩'
                  '摘要保留），聊天记录显示不受影响——下一轮请求立即瘦身。'
                  '刻度条上的滑块 = 自动压缩阈值，越过即自动压缩。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('其它会话快照', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  for (final e in others)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '· ${_fmtTokens(e.value.usedTokens)} / '
                        '${_fmtTokens(e.value.windowTokens)}'
                        '（${(e.value.fraction! * 100).toStringAsFixed(0)}%）',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
                if (compactionLines.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('最近压缩记录', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in compactionLines)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Text(
                              line,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// token 数格式化：1234 → 1.2k，1234567 → 1.23M，其余原样。
  static String _fmtTokens(int? tokens) {
    if (tokens == null) return '?';
    if (tokens >= 1000000) {
      return '${(tokens / 1000000).toStringAsFixed(2)}M';
    }
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}k';
    }
    return '$tokens';
  }

  Widget _buildPulsingDot() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, value, _) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: Colors.orange.shade400.withValues(alpha: value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Color _colorFor(String name) {
    switch (name) {
      case 'grey':
        return Colors.grey;
      case 'blue':
        return Colors.blue;
      case 'green':
        return Colors.green;
      case 'orange':
        return Colors.orange;
      case 'red':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  // =========================================================================
  // Chat UI
  // =========================================================================

  Widget _buildMessagesList() {
    // 多会话并发：live 回合 UI 状态按当前会话取自己的快照（事件流不串台）。
    final uiState = ref.watch(agentUiStateProvider)[_currentConversationId] ??
        const AgentUiState();
    // 普通聊天（非智能体回合）也要让最后一组进入 live 态：
    // 空答案气泡才会显示唯一的「思考中…」占位、流式光标才会出现。
    final generating =
        ref.watch(runningTurnsProvider).containsKey(_currentConversationId);
    final messagesAsync = ref.watch(messagesProvider(_currentConversationId));

    return messagesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Center(child: Text('Error: $err')),
      data: (rawMessages) {
        if (rawMessages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.auto_awesome, size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                Text(
                  '你好！我是 TongYi-Lite\n端到端离线的 AI 助手',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                ),
              ],
            ),
          );
        }

        // 跟随滚动：跟随态下每次重建（含流式每帧内容增长）都滚到底。
        // ⚠️ 不做任何签名门控（followSig 已回退）：流式期间末条消息 id 不变、
        // 只是内容变长，按 id/条数做签名会漏掉流式跟随（2026-10-25 真机回归，
        // 用户定案修回）——重建本身就是变化驱动的，无需二次去重。
        final units = groupMessages(rawMessages);
        if (_followStream) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_followStream && _scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
              );
            }
          });
        }

        // 对话区文字整体缩放（设置→智能体→对话文字大小，0.7~1.3）。
        final textScale = ref.watch(settingsProvider).chatTextScale;
        // 提问卡入流（阶段 3）：ask_user_question 挂起时作为列表末项渲染
        // 在提问回合的上下文里，不再悬浮在输入区上方。
        final pendingQuestion =
            ref.watch(agentPendingQuestionProvider)[_currentConversationId];
        // 简单聊天（非智能体回合）的流式思考：生成中且有思考流 → 列表尾
        // 渲染 ThinkingStreamCard（「思考中…」+自动展开，回合结束收起）。
        // 智能体回合的思考已在 AgentTurnBlock 内（不在列表尾重复）。
        final simpleChatThinking =
            generating && !uiState.running && uiState.thinking.isNotEmpty;
        final extraItem =
            (pendingQuestion != null ? 1 : 0) + (simpleChatThinking ? 1 : 0);
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          // 拖拽仲裁（见 _onScrollNotification）：手指拖离底部释放跟随，
          // 拖回底部重截获；程序化滚动不参与仲裁。
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: units.length + extraItem,
            itemBuilder: (context, index) {
              // 末项区：提问卡 / 简单聊天流式思考卡。
              if (index >= units.length) {
                if (simpleChatThinking &&
                    pendingQuestion == null &&
                    index == units.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ThinkingStreamCard(ui: uiState, live: true),
                  );
                }
                return _buildPendingQuestionCard();
              }
              final unit = units[index];
              final isLiveTurn =
                  (uiState.running || generating) && index == units.length - 1;
              return switch (unit) {
                UserUnit(:final message) => ChatBubble(
                    role: message.role.name,
                    content: message.content,
                    timestamp: message.timestamp,
                    isStreaming:
                        message.isStreaming && index == units.length - 1,
                    imagePath: message.imagePath,
                    imagePaths: message.imagePaths,
                    attachments: message.attachments,
                    audioPath: message.audioPath,
                    inferenceStats: message.inferenceStats,
                    conversationId: _currentConversationId,
                  ),
                TurnUnit(:final tools, :final answer, :final thinking,
                        :final trace, :final traceTools) =>
                  AgentTurnBlock(
                    isLive: isLiveTurn,
                    steps: _stepsFor(uiState, tools, isLiveTurn),
                    answer: answer,
                    ui: uiState,
                    thinking: thinking,
                    trace: trace,
                    traceTools: traceTools,
                  ),
              };
            },
          ),
          ),
        );
      },
    );
  }
  /// 回合步骤：live **智能体**回合用事件流实时数据（参数/结果/状态实时更新）；
  /// 其余（历史回合 / 普通聊天生成中）解析存储 🔧 活动消息。
  /// 普通聊天生成中绝不借用事件流——那是上一智能体回合的残留卡片，
  /// 借了就会在简单对话下面凭空多出一排工具卡。
  List<ToolActivityUi> _stepsFor(
      AgentUiState ui, List<ChatMessage> tools, bool isLiveTurn) {
    if (isLiveTurn && ui.running) return ui.tools;
    return parsedToolActivities(tools);
  }

  /// 计划模式文本前缀（P3 模式行「计划」chip 切换；/plan 由 chat_provider 消费）。
  static const String _planPrefix = '/plan ';

  /// 会话草稿（P3）：convId → 未发送文字，切换会话不打字仍在。
  final Map<String, String> _drafts = {};

  /// 计划存储（P1 计划实体化；与 chat_provider 同目录 goals/）。
  GoalStore? _planStoreCache;
  Future<GoalStore> _planStore() async {
    _planStoreCache ??= GoalStore(
        baseDir: '${(await getApplicationSupportDirectory()).path}/goals');
    return _planStoreCache!;
  }

  /// 输入区（标准智能体 composer 形态重构，2026-10-05）：
  ///
  /// [生成中状态细条]
  /// ┌─ composer 卡片（圆角 24）────────────────────┐
  /// │ 附件 chips 行（缩略图/文件名，× 单个删除）        │
  /// │ TextField 多行（hint 随状态变化）               │
  /// │ [+] [🤖智能体][🎭人格][📋计划][模型]   (🎤/➤/⏹) │
  /// └────────────────────────────────────────────┘
  ///
  /// 发送键**位置语义复用**（单键四态，替代双 FAB 并排）：
  /// 空闲空输入=🎤（长按说话）/ 空闲有文字=➤ / 生成中空输入=⏹停止 /
  /// 生成中有文字=➤（插话，不打断）。停止另有状态细条右侧文字按钮兜底。
  Widget _buildInputBar(bool isGenerating, ModelState ms) {
    // 插件平台（P2）：整条输入区包在两个 Scope 里（槽注册表 + 动作入口）。
    // 没插件时每个洞都渲染 SizedBox.shrink()，界面一个像素都不变。
    //
    // 宿主服务的启动不用在这里显式 watch：下面 `pluginDispatcherProvider` 里就 watch 了
    // `pluginHostProvider`（同一个 FutureProvider，全 isolate 只起一次），
    // 输入区一构建就把服务带起来，贡献才会落进 `slotRegistryProvider` 这个注册表。
    final slots = ref.watch(slotRegistryProvider);
    final Widget inputBar = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 计划执行条（2026-10-25 用户需求）：有活跃计划才出现，默认折叠，
        // 点开展开步骤清单（最高 6 项，超出滚动）。
        _buildPlanQuickStrip(),
        // 插件活动条 / 整块停靠区（single：最低 priority 的那个渲染）。
        SlotOutlet(slotId: 'app.input.activity', registry: slots),
        SlotOutlet(
            slotId: 'app.input.dock', axis: Axis.vertical, registry: slots),
        // ask_user_question 提问卡已迁入对话流末项（在提问回合上下文作答）。
        Container(
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            // 设计稿形态：白底 + 细描边（不是灰底实心卡），发消息区要“轻”。
            color: Theme.of(context).colorScheme.surface,
            // DSH 参考形态（2026-10-25）：全圆角浮动卡；卡片之下是会话数据
            // 统计条——原「底部黑边」区域被统计条占满（手势条避让移到条上）。
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 附件 chips 行（选中才出现，单个可删）。
              _buildAttachmentChips(),
              // 插件附件徽章（app.input.attachments）/ 停靠区（app.composer.dock，听写的词卡队列放这）。
              SlotOutlet(slotId: 'app.input.attachments', registry: slots),
              SlotOutlet(
                  slotId: 'app.composer.dock',
                  axis: Axis.vertical,
                  registry: slots),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController,
                builder: (_, value, __) => TextField(
                  controller: _textController,
                  textInputAction: TextInputAction.newline,
                  // 行高压到 1.3：默认行高让「两行」虚高近三行（2026-10-25
                  // 用户定案：自然两行即可，手机打不了那么多字）。
                  style: const TextStyle(fontSize: 14, height: 1.3),
                  decoration: InputDecoration(
                    hintText: _inputHintFor(isGenerating, value.text),
                    hintStyle: const TextStyle(fontSize: 14),
                    border: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  ),
                  onSubmitted: (_) {
                    // 生成中：Enter = 插话转向（steer，不打断执行）。
                    if (isGenerating) {
                      _steerMessage();
                      return;
                    }
                    _sendMessage();
                  },
                  // 两行起显（2026-10-25 用户反馈）：输入框默认两行高，
                  // 打长句不用等换行才看到第二行；超过 8 行内部滚动。
                  minLines: 2,
                  maxLines: 8,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  // 统一附件入口：徽标 = 已选总数（明细在上面的 chips 行）。
                  // 三个样式数值走 `PluginInputIcon` 的常量（**单真源**）：插件图标与功能图标
                  // 必须一个模子，数值抄两份迟早分叉（2026-10-24 用户实测就是分叉后被发现）。
                  IconButton(
                    visualDensity: PluginInputIcon.kDensity,
                    icon: Badge(
                      isLabelVisible: _selectedImagePaths.isNotEmpty ||
                          _selectedFilePaths.isNotEmpty,
                      label: Text(
                          '${_selectedImagePaths.length + _selectedFilePaths.length}'),
                      child: const Icon(Icons.add,
                          size: PluginInputIcon.kIconSize),
                    ),
                    tooltip: '添加图片 / 文件',
                    constraints: const BoxConstraints(
                        minWidth: PluginInputIcon.kBoxSize,
                        minHeight: PluginInputIcon.kBoxSize),
                    padding: EdgeInsets.zero,
                    onPressed: _showAttachSheet,
                  ),
                  const SizedBox(width: 2),
                  // KV 占用环 + 快捷图标带（环右侧；图标集在「更多 →
                  // 快捷设置」里配置，默认全关——2026-10-25 用户定案）。
                  _buildContextUsageRing(),
                  _buildQuickActions(),
                  const Spacer(),
                  if (!isGenerating) _buildMicKey(),
                  _buildSendKey(isGenerating),
                ],
              ),
            ],
          ),
        ),
        // 会话数据统计条（2026-10-25 封装为 ConversationStatsBar，DSH
        // StatsLine 形态：轮/步 | LLM 耗时·tok/s | ≈tok | 上下文%）。
        // 键盘弹出时整条收起（含避让 padding）：输入卡直接贴住键盘顶，
        // 否则统计条 + nav inset 会卡在输入卡与键盘之间成一条死空隙。
        // 用 View.of 读原始 viewInsets——Scaffold(resize) 会把 body 的
        // MediaQuery.viewInsets 清零，从 body 里读恒为 0 检测不到键盘。
        if (View.of(context).viewInsets.bottom <= 0)
          Builder(builder: (_) {
            final msgs = ref.watch(messagesProvider(_currentConversationId))
                    .valueOrNull ??
                const <ChatMessage>[];
            return ConversationStatsBar(
                conversationId: _currentConversationId, messages: msgs);
          }),
      ],
    );
    return PluginDispatcherScope(
      dispatcher: ref.watch(pluginDispatcherProvider),
      child: SlotRegistryScope(registry: slots, child: inputBar),
    );
  }

  /// 输入框左侧的圆形上下文占用圈（传统进度环形态）：
  /// 环 = 占用比例（蓝 <60% / 橙 ≥60% / 红 ≥85% 阈值配色），环心 = 百分比数字；
  /// 无数据时灰环显示「—」。点按 → 上下文详情面板（数字/来源/压缩记录/
  /// 手动压缩）。智能体回合执行中禁用点按（防误触打断注意力）。
  // ---- composer 计划执行条（2026-10-25）：默认折叠一行读数
  // （📋 计划 · done/total · 进行中步骤），点开展开步骤清单（最高 6 项，
  // 超出滚动）；点步骤行切换状态。无活跃计划不渲染。
  Widget _buildPlanQuickStrip() {
    final plan = _activePlan;
    if (plan == null || !plan.isActive) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final steps = plan.steps;
    final done = steps.where((s) => s.status == PlanStepStatus.done).length;
    final running =
        steps.where((s) => s.status == PlanStepStatus.running).toList();
    final current = running.isNotEmpty
        ? running.first.title
        : (steps.any((s) => s.status == PlanStepStatus.pending)
            ? '待继续'
            : '已全部完成');
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _planStripExpanded = !_planStripExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.checklist,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '计划 · $done/${steps.length} · $current',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(
                    _planStripExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_planStripExpanded)
            ConstrainedBox(
              // 最高 ~6 项，超出滚动浏览。
              constraints: const BoxConstraints(maxHeight: 6 * 44),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                children: [
                  for (final s in steps)
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        switch (s.status) {
                          PlanStepStatus.done => Icons.check_circle,
                          PlanStepStatus.running => Icons.play_circle,
                          PlanStepStatus.failed => Icons.error,
                          PlanStepStatus.pending => Icons.radio_button_unchecked,
                        },
                        size: 18,
                        color: switch (s.status) {
                          PlanStepStatus.done => Colors.green.shade600,
                          PlanStepStatus.running => theme.colorScheme.primary,
                          PlanStepStatus.failed => theme.colorScheme.error,
                          PlanStepStatus.pending =>
                            theme.colorScheme.onSurfaceVariant,
                        },
                      ),
                      title: Text(s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              decoration: s.status == PlanStepStatus.done
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: s.status == PlanStepStatus.done
                                  ? theme.colorScheme.onSurfaceVariant
                                  : null)),
                      subtitle: s.detail.isEmpty
                          ? null
                          : Text(s.detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---- composer 快捷图标带（2026-10-25）：KV 环右侧，图标集在
  // 「更多 → 快捷设置」里逐个开启（settings.composerQuickActions，默认全关）。
  // agent = 点按直切智能体模式；其余 = 点按直开对应面板快速查看/设置。
  static const List<(String, IconData, String)> _quickActionCatalog = [
    ('agent', Icons.smart_toy_outlined, '智能体开关'),
    ('model', Icons.memory_outlined, '本地模型'),
    ('persona', Icons.theater_comedy, '人格'),
    ('plan', Icons.checklist, '计划'),
    ('skills', Icons.auto_awesome_outlined, '技能'),
    ('plugins', Icons.extension_outlined, '插件'),
  ];

  Widget _buildQuickActions() {
    final settings = ref.watch(settingsProvider);
    final enabled = settings.composerQuickActions;
    if (enabled.isEmpty) return const SizedBox.shrink();
    final agentOn = settings.agentEnabled;
    final modelLoaded = ref.watch(modelManagerProvider).isLoaded;
    final pluginReady = ref.watch(pluginHostProvider).valueOrNull != null;
    // 每个图标反映各自功能的真实状态：绿 = 开，灰 = 关（2026-10-25 用户定案）。
    bool stateOf(String id) => switch (id) {
          'agent' => agentOn,
          'model' => modelLoaded,
          'persona' => settings.activePersona() != null,
          'plan' => _hasActivePlan,
          'skills' => true, // 技能库恒可用
          'plugins' => pluginReady,
          _ => false,
        };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final (id, icon, label) in _quickActionCatalog)
        if (enabled.contains(id))
          IconButton(
            // 紧凑：负密度 + 30dp 触点（默认 40/48 太占一行，2026-10-25 用户定案）。
            visualDensity: const VisualDensity(horizontal: -4, vertical: -2),
            constraints:
                const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            iconSize: 19,
            tooltip: '$label（${stateOf(id) ? '开' : '关'}）',
            icon: Icon(
              icon,
              color: stateOf(id)
                  ? Colors.green.shade600
                  : Theme.of(context).colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.55),
            ),
            onPressed: () {
              if (id == 'agent') {
                final notifier = ref.read(settingsProvider.notifier);
                notifier.setAgentEnabled(!agentOn);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(agentOn ? '已关闭智能体模式（纯聊天）' : '已开启智能体模式'),
                  duration: const Duration(seconds: 1),
                ));
                return;
              }
              _openRail(id);
            },
          ),
    ]);
  }

  Widget _buildContextUsageRing() {
    final usage = ref.watch(contextUsageProvider)[_currentConversationId];
    final fraction = usage?.fraction;
    final hasData = fraction != null;
    // 环**常显**（KV/上下文占用的固定指示位，2026-10-25 用户定案不许藏）。
    // 无数据的空会话显示 0% 灰环——新会话占用为 0 是事实；
    // 此前的「—」灰圈看着像坏按钮，那才是问题本体。
    final display = hasData ? fraction! : 0.0;
    final color = !hasData
        ? Colors.grey.shade400
        : display >= 0.85
            ? const Color(0xFFE53935)
            : display >= 0.60
                ? const Color(0xFFFB8C00)
                : const Color(0xFF2196F3);
    return Tooltip(
      message: '上下文占用详情 / 手动压缩',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _showContextUsageSheet,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  value: display.clamp(0.0, 1.0),
                  strokeWidth: 2.4,
                  strokeCap: StrokeCap.round,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.18),
                ),
              ),
              Text(
                '${(display * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 9,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入 hint 随状态：计划模式 / 生成中插话 / 普通输入。
  String _inputHintFor(bool isGenerating, String text) {
    if (text.startsWith(_planPrefix)) return '计划模式：先规划后执行…';
    if (isGenerating) return '插话给执行中的智能体…（不打断）';
    return '输入消息…';
  }

  /// 附件 chips 行：图片 = 40px 缩略图、文件 = 文件名 chip，各带 × 删除。
  Widget _buildAttachmentChips() {
    if (_selectedImagePaths.isEmpty && _selectedFilePaths.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(top: 4),
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (var i = 0; i < _selectedImagePaths.length; i++)
            _removableChip(
              child: GestureDetector(
                // 点击缩略图 → 全屏预览原图（× 删除键独立不受影响）。
                onTap: () => showImagePreview(
                  context,
                  imagePaths: _selectedImagePaths,
                  initialIndex: i,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(_selectedImagePaths[i]),
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              onRemove: () => setState(() => _selectedImagePaths.removeAt(i)),
            ),
          for (var i = 0; i < _selectedFilePaths.length; i++)
            _removableChip(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.description, size: 18),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 90),
                      child: Text(
                        _fileNameOf(_selectedFilePaths[i]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              onRemove: () => setState(() => _selectedFilePaths.removeAt(i)),
            ),
        ],
      ),
    );
  }

  /// 可删除 chip 容器：右上角小 ×（44px 基座内 16px 触点扩展到 20）。
  Widget _removableChip(
      {required Widget child, required VoidCallback onRemove}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            top: -4,
            right: -4,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 是否存在活跃计划（打开面板/切会话时刷新；驱动 chip 高亮）。
  bool _hasActivePlan = false;

  /// 当前会话活跃计划体（composer 计划条数据源）。
  GoalState? _activePlan;

  /// composer 计划条展开态（默认折叠，2026-10-25 用户需求）。
  bool _planStripExpanded = false;

  Future<void> _refreshActivePlanFlag() async {
    final plan = await (await _planStore()).load(_currentConversationId);
    if (!mounted) return;
    _activePlan = plan;
    if (_hasActivePlan != (plan != null)) {
      setState(() => _hasActivePlan = plan != null);
    } else {
      setState(() {}); // 步骤进度变化也要刷新计划条。
    }
  }

  /// ask_user_question 待回答卡片：问题 + 候选项 + 自由回答 + 跳过。
  /// 回答经 [ChatNotifier.answerPendingQuestion] 完成挂起的工具调用。
  Widget _buildPendingQuestionCard() {
    final pending =
        ref.watch(agentPendingQuestionProvider)[_currentConversationId];
    if (pending == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline,
                  size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text('智能体提问 · 回合等待中',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 8),
          Text(pending.question, style: const TextStyle(fontSize: 14)),
          if (pending.options.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final option in pending.options)
                  ActionChip(
                    label: Text(option, style: const TextStyle(fontSize: 12)),
                    onPressed: () => ref
                        .read(chatNotifierProvider.notifier)
                        .answerPendingQuestion(_currentConversationId, option),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _questionController,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: '输入你的回答…',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onSubmitted: (value) {
                    if (value.trim().isEmpty) return;
                    ref
                        .read(chatNotifierProvider.notifier)
                        .answerPendingQuestion(_currentConversationId, value);
                    _questionController.clear();
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send, size: 20),
                tooltip: '回答',
                onPressed: () {
                  final value = _questionController.text.trim();
                  if (value.isEmpty) return;
                  ref
                      .read(chatNotifierProvider.notifier)
                      .answerPendingQuestion(_currentConversationId, value);
                  _questionController.clear();
                },
              ),
              TextButton(
                onPressed: () => ref
                    .read(chatNotifierProvider.notifier)
                    .answerPendingQuestion(_currentConversationId, null),
                child: const Text('跳过', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// composer 主键（位置语义复用，单键四态——标准智能体形态）：
  /// - 空闲 + 空输入：🎤 长按说话（短按 = 直接发送语音的替代：点按后录音横幅出现，再点发送）；
  /// - 空闲 + 有文字：➤ 发送（含图片/附件）；
  /// - 生成中 + 空输入：⏹ 停止；
  /// - 生成中 + 有文字：➤ 插话（steer，不打断执行；附件不随插话发送）。
  /// 停止另有生成中状态细条右侧「停止」文字按钮兜底（永远两处可达）。
  /// 发送键（固定最右）：有文字 = 发送；生成中 = 插话/停止；空闲隐藏
  ///（麦克风独立常驻，见 [_buildMicKey]——设计稿形态：发送钮恒在最右）。
  Widget _buildSendKey(bool isGenerating) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _textController,
      builder: (_, value, __) {
        final hasText = value.text.trim().isNotEmpty;
        if (isGenerating) {
          return _roundKey(
            icon: hasText ? Icons.arrow_upward : Icons.stop,
            color: hasText
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
            tooltip: hasText ? '插话发送（不打断执行）' : '停止回复',
            onTap: hasText ? _steerMessage : _stopGeneration,
          );
        }
        if (hasText) {
          return _roundKey(
            icon: Icons.arrow_upward,
            color: Theme.of(context).colorScheme.primary,
            tooltip: '发送',
            onTap: _sendMessage,
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  /// 麦克风键（常驻，独立于发送键）：长按说话，松手即发送，上滑取消。
  /// Tooltip 只包图标本体，不包手势层（Tooltip 的长按识别器会抢手势）。
  Widget _buildMicKey() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (d) =>
          _onVoiceLongPressStart(context, d.globalPosition),
      onLongPressMoveUpdate: (d) =>
          _onVoiceLongPressMoveUpdate(d.globalPosition),
      onLongPressEnd: (_) => _onVoiceLongPressEnd(),
      onLongPressCancel: () => _onVoiceLongPressEnd(),
      // ⚠️ 这里绝不能包 Tooltip：Tooltip 的长按识别器是**内层**识别器，
      // 手势竞技场里内层必胜（子先入 arena），外层的按住说话长按永远被
      // 拒——2026-10-25 真机实锤（长按落在热区但 [Voice] 日志零触发，
      // 自 10-24 composer 加 Tooltip 后语音一直废的根因）。
      // 无障碍文案用 Semantics（零手势识别器）。
      child: Semantics(
        label: '按住说话，松手即发送（上滑取消）',
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            Icons.mic,
            size: 22,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  /// 会赢过外层 GestureDetector 的长按（麦克风长按说话被它抢走的实锤，07:1x）。
  Widget _roundKey({
    required IconData icon,
    required Color color,
    String? tooltip,
    VoidCallback? onTap,
  }) {
    final key = Material(
      color: color,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: onTap,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(icon, size: 19, color: Colors.white),
        ),
      ),
    );
    if (tooltip == null) return key;
    return Tooltip(message: tooltip, child: key);
  }

  /// 回合中插话（steer）：不打断执行，文字注入运行中回合的下一个 step。
  /// 附件/图片不随插话发送——保留在输入区，随下一条正式消息发送。
  Future<void> _steerMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_selectedImagePaths.isNotEmpty || _selectedFilePaths.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('插话仅发送文字；已选附件将随下一条消息发送',
                style: TextStyle(color: Colors.white))));
      }
    }
    _textController.clear();
    FocusScope.of(context).unfocus();
    _followStream = true;
    try {
      await ref
          .read(chatNotifierProvider.notifier)
          .steerTurn(_currentConversationId, text);
    } catch (e) {
      _textController.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('插话失败: $e', style: const TextStyle(color: Colors.white))),
      );
    }
  }

  /// 录音中的横幅：波形动画 + 计时 + 「松手发送」提示。
  // =========================================================================
  // Conversation drawer — compact entry for managing (new / switch / delete)
  // =========================================================================

  // ---- P2 会话抽屉重构：搜索 / 分组 / 摘要 / 状态徽标 / 行内操作 ----

  final TextEditingController _conversationSearchCtrl = TextEditingController();
  String _conversationSearchQuery = '';

  /// 各会话最后一条消息摘要（一次批量 SQL；打开抽屉时失效重取）。
  Future<Map<String, String>>? _snippetsFuture;

  void _invalidateSnippets() => _snippetsFuture = null;

  /// 会话面板主体（原 Drawer 内容，2026-10-24 起由左栏「会话」面板承载）。
  Widget _buildConversationDrawerBody() {
    final conversations = ref.watch(conversationsProvider);
    final settings = ref.watch(settingsProvider);
    final pinned = settings.pinnedConversationIds.toSet();
    return SafeArea(
      right: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(children: [
              // 最常用操作给最大触点：新建 = 主按钮。
              Expanded(
                child: FilledButton.icon(
                  onPressed: _newConversation,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新对话'),
                ),
              ),
              // 批量选择开关：进入多选模式后，点按会话变为勾选而非切换。
              IconButton(
                icon: Icon(
                    _conversationSelectionMode ? Icons.close : Icons.checklist),
                tooltip: _conversationSelectionMode ? '退出批量选择' : '批量选择',
                color: _conversationSelectionMode
                    ? Theme.of(context).colorScheme.primary
                    : null,
                onPressed: () {
                  setState(() {
                    _conversationSelectionMode = !_conversationSelectionMode;
                    if (!_conversationSelectionMode) {
                      _selectedConversations.clear();
                    }
                  });
                },
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _conversationSearchCtrl,
              onChanged: (v) => setState(() => _conversationSearchQuery = v),
              decoration: InputDecoration(
                hintText: '搜索会话…',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          Expanded(
            child: conversations.isEmpty
                ? const Center(
                    child: Text('暂无会话', style: TextStyle(color: Colors.grey)))
                : FutureBuilder<Map<String, String>>(
                    future: _snippetsFuture ??=
                        ref.read(storageServiceProvider).lastMessageSnippets(),
                    builder: (ctx, snap) {
                      final snippets = snap.data ?? const {};
                      return _buildConversationList(
                          conversations, pinned, snippets);
                    },
                  ),
          ),
          // 批量选择底部操作栏
          if (_conversationSelectionMode) ...[
            const Divider(height: 1),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Text('已选 ${_selectedConversations.length} 个'),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: _selectedConversations.isEmpty
                        ? null
                        : _confirmBulkDelete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text('删除选中(${_selectedConversations.length})'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 按查询过滤 + 分组：置顶 / 今天 / 昨天 / 7 天内 / 更早。
  List<MapEntry<String, List<Conversation>>> _groupConversations(
    List<Conversation> conversations,
    Set<String> pinned,
  ) {
    final q = _conversationSearchQuery.trim().toLowerCase();
    final filtered = q.isEmpty
        ? conversations
        : conversations
            .where((c) => c.title.toLowerCase().contains(q))
            .toList();
    final now = DateTime.now();
    final startToday = DateTime(now.year, now.month, now.day);
    final startYesterday = startToday.subtract(const Duration(days: 1));
    final startWeek = startToday.subtract(const Duration(days: 7));
    final groups = <String, List<Conversation>>{
      '置顶': [],
      '今天': [],
      '昨天': [],
      '7 天内': [],
      '更早': [],
    };
    for (final c in filtered) {
      if (pinned.contains(c.id)) {
        groups['置顶']!.add(c);
      } else if (!c.updatedAt.isBefore(startToday)) {
        groups['今天']!.add(c);
      } else if (!c.updatedAt.isBefore(startYesterday)) {
        groups['昨天']!.add(c);
      } else if (!c.updatedAt.isBefore(startWeek)) {
        groups['7 天内']!.add(c);
      } else {
        groups['更早']!.add(c);
      }
    }
    return [
      for (final e in groups.entries)
        if (e.value.isNotEmpty) MapEntry(e.key, e.value),
    ];
  }

  Widget _buildConversationList(
    List<Conversation> conversations,
    Set<String> pinned,
    Map<String, String> snippets,
  ) {
    final groups = _groupConversations(conversations, pinned);
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (ctx, gi) {
        final g = groups[gi];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Text(g.key,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600)),
            ),
            for (final c in g.value)
              _buildConversationTile(c, c.id == _currentConversationId,
                  pinned.contains(c.id), snippets[c.id] ?? ''),
          ],
        );
      },
    );
  }

  Widget _buildConversationTile(
      Conversation c, bool isCurrent, bool isPinned, String snippet) {
    final updated = _formatTime(c.updatedAt);
    // 批量选择模式下：勾选框 + 点按切换选中；隐藏单个操作菜单。
    final selectionMode = _conversationSelectionMode;
    final selected = _selectedConversations.contains(c.id);
    final running = ref.watch(runningTurnsProvider).containsKey(c.id);
    return ListTile(
      dense: true,
      selected: isCurrent && !selectionMode,
      leading: selectionMode
          ? Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
            )
          : running
              ? const Icon(Icons.autorenew, size: 20, color: Colors.orange)
              : Icon(
                  isCurrent ? Icons.chat_bubble : Icons.chat_bubble_outline,
                  size: 20,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
      title: Row(children: [
        if (isPinned) ...[
          Icon(Icons.push_pin, size: 12, color: Colors.grey.shade500),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(c.title.isEmpty ? '新对话' : c.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: isCurrent && !selectionMode
                      ? FontWeight.w600
                      : FontWeight.normal)),
        ),
        if (isCurrent && _hasActivePlan) ...[
          const SizedBox(width: 4),
          const Text('📋', style: TextStyle(fontSize: 11)),
        ],
      ]),
      subtitle: Text(
        snippet.isEmpty ? '$updated · ${c.messageCount} 条' : snippet,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 12,
            color: snippet.isEmpty ? Colors.grey : Colors.grey.shade600),
      ),
      onTap: selectionMode
          ? () {
              setState(() {
                if (!_selectedConversations.remove(c.id)) {
                  _selectedConversations.add(c.id);
                }
              });
            }
          : () => _switchConversation(c.id),
      onLongPress: selectionMode
          ? null
          : () {
              // 长按 = 进入批量选择并选中（保留原批量能力入口）。
              setState(() {
                _conversationSelectionMode = true;
                _selectedConversations.add(c.id);
              });
            },
      trailing: selectionMode
          ? null
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (action) {
                switch (action) {
                  case 'pin':
                    ref
                        .read(settingsProvider.notifier)
                        .togglePinnedConversation(c.id);
                    break;
                  case 'rename':
                    _renameConversation(c);
                    break;
                  case 'delete':
                    _confirmDelete(c);
                    break;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'pin', child: Text(isPinned ? '取消置顶' : '置顶')),
                const PopupMenuItem(value: 'rename', child: Text('重命名')),
                const PopupMenuItem(
                    value: 'delete',
                    child: Text('删除', style: TextStyle(color: Colors.red))),
              ],
            ),
    );
  }

  /// 重命名会话：对话框输入 → 更新存储 + provider（P2 抽屉行内操作）。
  Future<void> _renameConversation(Conversation c) async {
    final ctrl = TextEditingController(text: c.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final title = ctrl.text.trim();
    if (title.isEmpty) return;
    await ref
        .read(storageServiceProvider)
        .updateConversation(id: c.id, title: title);
    if (!mounted) return;
    ref.read(conversationsProvider.notifier).update(Conversation(
          id: c.id,
          title: title,
          modelId: c.modelId,
          messageCount: c.messageCount,
          createdAt: c.createdAt,
          updatedAt: DateTime.now(),
        ));
  }

  /// Create a new conversation and switch to it.
  Future<void> _newConversation() async {
    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.create();
    final convs = ref.read(conversationsProvider);
    if (convs.isNotEmpty) {
      _saveDraft();
      setState(() {
        _setCurrentConversation(convs.first.id);
        _followStream = true;
        _selectedImagePaths.clear();
        _selectedFilePaths.clear();
      });
      _restoreDraft();
    }
    _closeRailSurface();
  }

  /// 会话草稿（P3）：保存当前未发送文字；发送/清空时删除对应草稿。
  void _saveDraft() {
    final t = _textController.text;
    if (t.isEmpty) {
      _drafts.remove(_currentConversationId);
    } else {
      _drafts[_currentConversationId] = t;
    }
  }

  /// 恢复目标会话的草稿（无草稿则清空输入框）。
  void _restoreDraft() {
    _textController.text = _drafts[_currentConversationId] ?? '';
    _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length));
    _refreshActivePlanFlag();
  }

  /// Switch to an existing conversation (no-op if already current).
  void _switchConversation(String id) {
    if (id != _currentConversationId) {
      _saveDraft();
      setState(() {
        _setCurrentConversation(id);
        _followStream = true;
        _selectedImagePaths.clear();
        _selectedFilePaths.clear();
      });
      _restoreDraft();
      // 切会话：该会话无快照（如重启后首次切入）→ 估算回填。
      unawaited(
          ref.read(chatNotifierProvider.notifier).refreshUsageEstimate(id));
    }
    _closeRailSurface();
  }

  Future<void> _confirmDelete(Conversation c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text(
            '确定删除「${c.title.isEmpty ? '新对话' : c.title}」吗？\n该会话的所有消息将被永久删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteConversation(c.id);
  }

  /// 批量删除：先弹确认框，再逐个删除选中的会话。
  Future<void> _confirmBulkDelete() async {
    final n = _selectedConversations.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除选中的 $n 个会话吗？\n每个会话的所有消息将被永久删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final notifier = ref.read(conversationsProvider.notifier);
    for (final id in _selectedConversations.toList()) {
      await notifier.delete(id);
    }
    // 若删到了当前会话，回落到任一剩余会话或新建一个，避免聊天区为空。
    if (_selectedConversations.contains(_currentConversationId)) {
      final convs = ref.read(conversationsProvider);
      if (convs.isEmpty) {
        await notifier.create();
      }
      final list = ref.read(conversationsProvider);
      setState(() {
        _setCurrentConversation(list.isEmpty ? '' : list.first.id);
        _followStream = true;
        _selectedImagePaths.clear();
        _selectedFilePaths.clear();
      });
    }
    setState(() {
      _selectedConversations.clear();
      _conversationSelectionMode = false;
    });
  }

  Future<void> _deleteConversation(String id) async {
    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.delete(id);
    // If we just deleted the active conversation, fall back to another one or
    // create a fresh one so the chat view is never left empty.
    if (id == _currentConversationId) {
      var convs = ref.read(conversationsProvider);
      if (convs.isEmpty) {
        await notifier.create();
        convs = ref.read(conversationsProvider);
      }
      _saveDraft();
      setState(() {
        _setCurrentConversation(convs.isEmpty ? '' : convs.first.id);
        _followStream = true;
        _selectedImagePaths.clear();
        _selectedFilePaths.clear();
      });
      _restoreDraft();
    }
  }

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final hhmm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天 $hhmm';
    if (diff == 1) return '昨天 $hhmm';
    if (t.year == now.year) return '${t.month}/${t.day} $hhmm';
    return '${t.year}/${t.month}/${t.day} $hhmm';
  }
}

/// 统一附件面板的选项（拍照 / 相册 / 文件）。
enum _AttachSource { none, camera, gallery, file }

/// 附件面板的单行选项：着色圆角图标 + 标题 + 副标题，整行水波纹点按。
class _AttachOption extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AttachOption({
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 22, color: tint),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 1),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// Model status bottom sheet widget (outside the State class)
// =========================================================================

/// Reusable bottom-sheet widget for model status details.
/// 模型面板子页切换：模型列表（下载/加载/默认）与引擎设置同面板承载，
/// 模型列表为默认——用户下载和使用本地模型的主路径不许被藏起来。
/// （embedded 形态已死：从未传过 true，2026-10-25 评审清除。）
class _ModelStatusSheet extends StatelessWidget {
  final ModelLifecyclePhase phase;
  final String modelName;
  final String? errorMessage;
  final List<String> logs;
  final bool isGenerating;
  final VoidCallback onUnload;
  final VoidCallback onLoad;
  final VoidCallback onGoToSettings;
  final WidgetRef ref;

  const _ModelStatusSheet({
    required this.phase,
    required this.modelName,
    this.errorMessage,
    this.logs = const [],
    required this.isGenerating,
    required this.onUnload,
    required this.onLoad,
    required this.onGoToSettings,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    final color = _sheetColorFor(phase);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar（弹层把手）
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2)),
              ),
              // Title + icon
              Row(
                children: [
                  Icon(_sheetIconFor(phase), size: 28, color: color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          phase == ModelLifecyclePhase.loaded
                              ? '模型已就绪'
                              : _phaseLabelFor(phase),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        if (phase == ModelLifecyclePhase.loaded ||
                            phase == ModelLifecyclePhase.error)
                          Text(
                            modelName,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (isGenerating) _buildPulsingDotLarge(),
                ],
              ),
              _MemoryPanel(ref: ref),
              const SizedBox(height: 12),
              // Inference / loading logs (scrollable, latest entries at bottom)
              if (logs.isNotEmpty)
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (ctx, i) => Text(
                      logs[i],
                      style:
                          TextStyle(fontSize: 12, color: Colors.blue.shade800),
                    ),
                  ),
                ),
              if (logs.isNotEmpty) const SizedBox(height: 12),
              // Error message
              if (errorMessage != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(errorMessage!,
                      style:
                          TextStyle(fontSize: 12, color: Colors.red.shade800)),
                ),
              if (errorMessage != null) const SizedBox(height: 12),
              // Actions
              if (phase == ModelLifecyclePhase.loaded && !isGenerating) ...[
                _sheetButton(context,
                    label: '卸载模型',
                    icon: Icons.close,
                    color: Colors.red,
                    onTap: onUnload),
                const SizedBox(height: 8),
              ],
              if (phase == ModelLifecyclePhase.error) ...[
                _sheetButton(context,
                    label: '重试加载',
                    icon: Icons.refresh,
                    color: Colors.blue,
                    onTap: onLoad),
                const SizedBox(height: 8),
              ],
              if (phase == ModelLifecyclePhase.idle) ...[
                _sheetButton(context,
                    label: '去加载模型',
                    icon: Icons.download,
                    color: Colors.green,
                    onTap: onGoToSettings),
                const SizedBox(height: 8),
              ],
              _sheetButton(context,
                  label: '关闭',
                  icon: null,
                  color: null,
                  onTap: () => Navigator.pop(context),
                  isDefault: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetButton(
    BuildContext context, {
    required String label,
    IconData? icon,
    Color? color,
    required VoidCallback onTap,
    bool isDefault = false,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor:
              color ?? Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: color == null ? null : Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        icon: icon != null ? Icon(icon, size: 18) : null,
        label: Text(label),
      ),
    );
  }

  IconData _sheetIconFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return Icons.memory_outlined;
      case ModelLifecyclePhase.loading:
        return Icons.sync_alt;
      case ModelLifecyclePhase.loaded:
        return Icons.check_circle;
      case ModelLifecyclePhase.unloading:
        return Icons.sync_disabled;
      case ModelLifecyclePhase.error:
        return Icons.error_outline;
    }
  }

  String _phaseLabelFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return '未加载';
      case ModelLifecyclePhase.loading:
        return '加载中…';
      case ModelLifecyclePhase.loaded:
        return '已加载';
      case ModelLifecyclePhase.unloading:
        return '卸载中…';
      case ModelLifecyclePhase.error:
        return '加载失败';
    }
  }

  Color _sheetColorFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return Colors.grey;
      case ModelLifecyclePhase.loading:
        return Colors.blue;
      case ModelLifecyclePhase.loaded:
        return Colors.green;
      case ModelLifecyclePhase.unloading:
        return Colors.orange;
      case ModelLifecyclePhase.error:
        return Colors.red;
    }
  }

  Widget _buildPulsingDotLarge() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, value, _) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: Colors.orange.shade400.withValues(alpha: value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Live memory-usage panel shown inside the model-status sheet.
///
/// Polls [InferenceService.getMemoryInfo] every 2s so the user can watch
/// system RAM pressure and llama.cpp (in-process) memory while generating.
/// Colors: green = comfortable, orange = tight, red = critical.
class _MemoryPanel extends StatefulWidget {
  final WidgetRef ref;
  const _MemoryPanel({required this.ref});

  @override
  State<_MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<_MemoryPanel> {
  Map<String, int>? _mem;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final m = await widget.ref.read(inferenceServiceProvider).getMemoryInfo();
      if (!mounted) return;
      setState(() {
        _mem = m;
        _error = m.isEmpty ? '原生端未返回内存数据' : null;
      });
    } catch (e) {
      // Surface the failure instead of spinning forever — a silent catch here
      // is exactly what hid the earlier type-cast bug.
      if (mounted && _mem == null) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 内存卡主题化（原写死浅灰，暗色下刺眼）：全部走 M3 令牌。
    final theme = Theme.of(context);
    if (_mem == null || _mem!.isEmpty) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _error == null ? '读取内存信息…' : '内存信息不可用：$_error',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    final sysTotal = _mem!['sysTotalMB'] ?? 0;
    final sysAvail = _mem!['sysAvailMB'] ?? 0;
    final sysUsed = _mem!['sysUsedMB'] ?? 0;
    final procRss = _mem!['procRssMB'] ?? 0;
    final modelMB = _mem!['modelMB'] ?? 0;
    final kvCache = _mem!['kvCacheMB'] ?? 0;
    final sysAvailPct = sysTotal > 0 ? sysAvail / sysTotal : 0.0;
    final procPct = sysTotal > 0 ? procRss / sysTotal : 0.0;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory, size: 16),
              const SizedBox(width: 6),
              Text('内存占用',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface)),
              const Spacer(),
              Text('可用 ${_gb(sysAvail)} GB',
                  style: TextStyle(
                      fontSize: 12, color: _pressureColor(sysAvailPct))),
            ],
          ),
          const SizedBox(height: 10),
          _memBar(
            context: context,
            label: '系统内存',
            usedMB: sysUsed,
            totalMB: sysTotal,
            pct: sysTotal > 0 ? sysUsed / sysTotal : 0,
            color: _pressureColor(sysAvailPct),
          ),
          const SizedBox(height: 8),
          _memBar(
            context: context,
            label: 'App (llama.cpp)',
            usedMB: procRss,
            totalMB: sysTotal,
            pct: procPct,
            color: _pressureColor(1 - procPct),
          ),
          const SizedBox(height: 10),
          // llama.cpp 自身的内存构成：模型权重 + KV 缓存
          Row(
            children: [
              Expanded(
                child: _memStat(
                  '模型权重',
                  modelMB > 0 ? '${_gb(modelMB)} GB' : '—',
                  modelMB > 0 ? Colors.indigo : Colors.grey,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _memStat(
                  'KV 缓存',
                  kvCache > 0 ? '${_gb(kvCache)} GB' : '—',
                  kvCache > 0 ? Colors.teal : Colors.grey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Wrap 而非 Row+spaceBetween：左栏面板约 300dp 宽，两段文字
          // 同行放不下会 RenderFlex overflow（真机 4.7px 实锤）。
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              Text(
                'llama.cpp 合计: ${_gb(modelMB + kvCache)} GB',
                style: TextStyle(
                  fontSize: 12,
                  color: _pressureColor(
                      sysTotal > 0 ? 1 - (modelMB + kvCache) / sysTotal : 1),
                ),
              ),
              Text('进程 RSS: ${_gb(procRss)} GB',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurface)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _memStat(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 11, color: color.withValues(alpha: 0.9))),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Color _pressureColor(double availPct) {
    if (availPct >= 0.3) return Colors.green;
    if (availPct >= 0.1) return Colors.orange;
    return Colors.red;
  }

  String _gb(int mb) => (mb / 1024.0).toStringAsFixed(1);

  Widget _memBar({
    required BuildContext context,
    required String label,
    required int usedMB,
    required int totalMB,
    required double pct,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            Text('${_gb(usedMB)} / ${_gb(totalMB)} GB',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct.clamp(0.0, 1.0),
            minHeight: 9,
            valueColor: AlwaysStoppedAnimation(color),
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

/// 全部计划列表（2026-10-25 用户需求）：跨会话按更新时间倒序，
/// 完成与否/进度可见；点行切到对应会话看执行；会话已删的可单独删除
/// （计划按会话管理，会话删除时已自动随删，这里兜底手动清）。
class _AllPlansSection extends ConsumerStatefulWidget {
  final GoalStore store;
  final void Function(String conversationId) onOpenConversation;

  const _AllPlansSection({required this.store, required this.onOpenConversation});

  @override
  ConsumerState<_AllPlansSection> createState() => _AllPlansSectionState();
}

class _AllPlansSectionState extends ConsumerState<_AllPlansSection> {
  List<(String, GoalState)>? _plans;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final plans = await widget.store.listAll();
    if (!mounted) return;
    setState(() => _plans = plans);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conversations = ref.watch(conversationsProvider);
    final titles = {
      for (final c in conversations) c.id: c.title,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('全部计划（按时间倒序）',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
        if (_plans == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_plans!.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('还没有任何计划',
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final (convId, plan) in _plans!)
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: Icon(
                      switch (plan.status) {
                        GoalStatus.active => Icons.play_circle,
                        GoalStatus.done => Icons.check_circle,
                        GoalStatus.cancelled => Icons.cancel,
                        GoalStatus.expired => Icons.schedule,
                      },
                      size: 20,
                      color: switch (plan.status) {
                        GoalStatus.active => theme.colorScheme.primary,
                        GoalStatus.done => Colors.green.shade600,
                        GoalStatus.cancelled => Colors.grey,
                        GoalStatus.expired => Colors.orange,
                      },
                    ),
                    title: Text(plan.title.isEmpty ? plan.goal : plan.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '${titles[convId] ?? '会话已删除'} · '
                      '${plan.steps.where((s) => s.status == PlanStepStatus.done).length}'
                      '/${plan.steps.length} 步'
                      '${plan.isActive ? ' · 执行中' : plan.status == GoalStatus.done ? ' · 已完成' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline, size: 17),
                      tooltip: '删除该计划',
                      onPressed: () async {
                        await widget.store.deletePlan(convId);
                        await _reload();
                      },
                    ),
                    onTap: () => widget.onOpenConversation(convId),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

class _PlanPanelSheet extends StatefulWidget {
  final GoalStore store;
  final String conversationId;
  final VoidCallback onRegenerate;
  final VoidCallback onChanged;

  /// 关闭面板：面板是左栏内联 Stack（非路由），**Navigator.pop 会把主路由
  /// pop 掉 = 整屏黑屏**（2026-10-25 真机定案）——必须走 RailPanelController。
  final VoidCallback onClose;

  const _PlanPanelSheet({
    required this.store,
    required this.conversationId,
    required this.onRegenerate,
    required this.onChanged,
    required this.onClose,
  });

  @override
  State<_PlanPanelSheet> createState() => _PlanPanelSheetState();
}

class _PlanPanelSheetState extends State<_PlanPanelSheet> {
  GoalState? _plan;
  List<Map<String, String>> _todos = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant _PlanPanelSheet old) {
    super.didUpdateWidget(old);
    // 切会话：面板 State 不重建（同类型 widget 原位更新），必须显式重载，
    // 否则显示的是上一个会话的计划/清单（计划与清单都按会话隔离）。
    if (old.conversationId != widget.conversationId) _reload();
  }

  Future<void> _reload() async {
    final plan = await widget.store.load(widget.conversationId);
    // 任务清单（todo_write 按会话落盘）：只看**当前会话**的清单（todo v3
    // 按会话隔离——旧全局单文件会在任何会话显示同一份清单，已废弃）。
    List<Map<String, String>> todos = const [];
    try {
      todos = await readTodoStore(widget.conversationId);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _todos = todos;
      _loaded = true;
    });
  }

  Future<void> _setStep(int index, PlanStepStatus status) async {
    final err = await widget.store
        .updateStep(widget.conversationId, stepIndex: index, status: status);
    if (err == null) {
      widget.onChanged();
      await _reload();
    }
  }

  Future<void> _finishPlan(GoalStatus status) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(status == GoalStatus.cancelled ? '放弃计划？' : '重新规划？'),
        content: const Text('当前计划将被清除，执行中的无人值守续跑随之停止。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.finish(widget.conversationId, status);
    widget.onChanged();
    if (!mounted) return;
    // 左栏内联面板非路由：Navigator.pop 会黑屏（见 onClose 注释）。
    widget.onClose();
    if (status == GoalStatus.cancelled) widget.onRegenerate();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return SafeArea(
      child: Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        padding: const EdgeInsets.all(16),
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : plan == null
                ? _buildEmpty(context)
                : _buildPlan(context, plan),
      ),
    );
  }

  /// 任务清单区（todo_write 的全局清单；空则不显示）。与对话内活卡同组件。
  Widget _buildTodosSection(BuildContext context) {
    if (_todos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TodoChecklistCard(content: renderTodoCardText(_todos)),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 不再重复「📋 计划」标题（面板标题栏已有，2026-10-25 真机截图定案）。
        const Text(
            '当前会话没有活跃计划。发送「/plan <任务>」，智能体调研后提交计划，'
            '你批准后自动执行，进度在这里回看。',
            style: TextStyle(fontSize: 13, height: 1.5)),
        _buildTodosSection(context),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () {
              // 先关面板再回填 /plan（面板内联非路由，不许 Navigator.pop）。
              widget.onClose();
              widget.onRegenerate();
            },
            icon: const Icon(Icons.auto_fix_high, size: 18),
            label: const Text('生成计划（填入 /plan 到输入框）'),
          ),
        ),
      ],
    );
  }

  Widget _buildPlan(BuildContext context, GoalState plan) {
    final statusText = switch (plan.status) {
      GoalStatus.active => '执行中（续跑 ${plan.rounds}/${plan.maxRounds} 轮）',
      GoalStatus.done => '已完成',
      GoalStatus.cancelled => '已取消',
      GoalStatus.expired => '轮数耗尽',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('📋 计划',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(plan.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14)),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: plan.status == GoalStatus.active
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(statusText, style: const TextStyle(fontSize: 11)),
          ),
        ]),
        const SizedBox(height: 8),
        if (plan.steps.isEmpty) ...[
          Text(plan.goal,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, height: 1.4)),
          const SizedBox(height: 6),
          const Text('（纯文本目标：无结构化步骤；重新规划可生成带步骤的计划）',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ] else ...[
          Text('目标：${plan.goal}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 6),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < plan.steps.length; i++)
                  _stepTile(context, plan, i),
              ],
            ),
          ),
          Text('已完成 ${plan.doneCount}/${plan.steps.length} · 点按改状态',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
        _buildTodosSection(context),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _finishPlan(GoalStatus.cancelled),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('放弃计划'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () => _finishPlan(GoalStatus.expired),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新规划'),
            ),
          ),
        ]),
      ],
    );
  }

  /// 步骤行：点按循环 pending→running→done→pending；菜单可指定/置失败。
  Widget _stepTile(BuildContext context, GoalState plan, int i) {
    final step = plan.steps[i];
    final isCurrent = plan.currentStepIndex == i;
    final (icon, color) = switch (step.status) {
      PlanStepStatus.pending => (Icons.radio_button_unchecked, Colors.grey),
      PlanStepStatus.running => (Icons.autorenew, Colors.orange),
      PlanStepStatus.done => (Icons.check_circle, Colors.green),
      PlanStepStatus.failed => (Icons.cancel, Colors.red),
    };
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      tileColor: isCurrent
          ? Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: 0.4)
          : null,
      leading: Icon(icon, size: 20, color: color),
      title: Text('${i + 1}. ${step.title}',
          style: TextStyle(
              fontSize: 13,
              decoration: step.status == PlanStepStatus.done
                  ? TextDecoration.lineThrough
                  : null)),
      subtitle: step.detail.isEmpty
          ? null
          : Text(step.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11)),
      trailing: PopupMenuButton<PlanStepStatus>(
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (s) => _setStep(i + 1, s),
        itemBuilder: (_) => const [
          PopupMenuItem(value: PlanStepStatus.pending, child: Text('置为待做')),
          PopupMenuItem(value: PlanStepStatus.running, child: Text('置为执行中')),
          PopupMenuItem(value: PlanStepStatus.done, child: Text('置为完成')),
          PopupMenuItem(value: PlanStepStatus.failed, child: Text('标记失败')),
        ],
      ),
      onTap: () {
        // 循环：pending → running → done → pending
        final next = switch (step.status) {
          PlanStepStatus.pending => PlanStepStatus.running,
          PlanStepStatus.running => PlanStepStatus.done,
          _ => PlanStepStatus.pending,
        };
        _setStep(i + 1, next);
      },
    );
  }
}


/// 占用刻度条 + 自动压缩阈值滑块（2026-10-25）：
/// 底层 = 占用进度条（蓝/橙/红随 fraction），上层 = 阈值竖线 + 把手，
/// 横向拖动（或点按任意位置）即改 autoCompactThreshold（0.5–0.95，持久化）。
class _ContextGaugeWithThreshold extends ConsumerWidget {
  final double fraction;
  const _ContextGaugeWithThreshold({required this.fraction});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threshold = ref.watch(settingsProvider).autoCompactThreshold;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      void update(DragUpdateDetails d) {
        final v = (d.localPosition.dx / w).clamp(0.5, 0.95);
        ref.read(settingsProvider.notifier).setAutoCompactThreshold(v);
      }

      final thumbX = (threshold * w).clamp(14.0, w - 14.0);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: update,
        onTapUp: (d) {
          final v = (d.localPosition.dx / w).clamp(0.5, 0.95);
          ref.read(settingsProvider.notifier).setAutoCompactThreshold(v);
        },
        child: SizedBox(
          height: 34,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // 刻度条（占用）
              Positioned(
                left: 0,
                right: 0,
                top: 13,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 8,
                    child: LinearProgressIndicator(
                      value: fraction,
                      backgroundColor:
                          scheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(
                        fraction >= 0.85
                            ? const Color(0xFFE53935)
                            : fraction >= 0.60
                                ? const Color(0xFFFB8C00)
                                : const Color(0xFF2196F3),
                      ),
                    ),
                  ),
                ),
              ),
              // 阈值竖线 + 把手 + 百分比标签
              Positioned(
                left: thumbX - 9,
                top: 0,
                child: Column(
                  children: [
                    Text('${(threshold * 100).round()}%',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary)),
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.compress,
                          size: 10, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
