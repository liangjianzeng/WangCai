/// 内置工具聚合 —— 注册表可扩展，这里提供对齐 DSH 能力的完整起步集。
///
/// 工具按类别分组：
/// - 核心（默认启用）：get_time / calculator / todo / note / unit_converter / memory
/// - 文件（默认启用）：read_file / write_file / edit_file / list_files / search_text
/// - 网络（默认关，设置开启）：web_search / get_weather
/// - 系统（默认关，设置开启）：shell_exec
///
/// 具体启用由接入层按配置决定（createBuiltinTools 全量创建，接入层过滤）。
library;

export 'calculator.dart' show createCalculatorTool;
export 'export_file_tool.dart' show createExportFileTool, kArtifactExtensions;
export 'file_tools.dart'
    show
        createEditFileTool,
        createListFilesTool,
        createReadFileTool,
        createSearchTextTool,
        createWriteFileTool;
export 'data_api/data_api_tool.dart' show createDataApiTool;
export 'fetch_url_tool.dart' show createFetchUrlTool, kFetchMaxBytes;
export 'get_time.dart' show createGetTimeTool;
export 'memory_tool.dart' show createMemoryGetTool, createMemorySetTool;
export 'note_tool.dart' show createNoteListTool, createNoteTakeTool, resetNoteStore;
export 'python_tool.dart' show createPythonExecTool;
export 'shell_tool.dart' show createShellExecTool;
export 'todo_tool.dart'
    show
        createTodoListTool,
        createTodoWriteTool,
        resetTodoStore,
        debugSeedLegacyTodoFile,
        readTodoStore,
        renderTodoCardText;
export 'unit_converter_tool.dart' show createUnitConverterTool;
export 'weather_tool.dart' show createGetWeatherTool;
export 'web_search_tool.dart' show createWebSearchTool;
// Dev Agent 工具组（开发模式开启后注册）。
export '../dev/tools/git_tools.dart'
    show
        createGitCloneTool,
        createGitCommitTool,
        createGitDiffTool,
        createGitLogTool,
        createGitPushTool,
        createGitStatusTool;
export '../dev/tools/embedded_tools.dart' show createDevShellTool;
export '../dev/tools/plan_tools.dart'
    show
        createPlanCreateTool,
        createPlanListTool,
        createPlanUpdateTool,
        createTaskCreateTool,
        createTaskListTool;
export '../dev/tools/ssh_tools.dart'
    show
        createSshExecTool,
        createSshReadFileTool,
        createSshWriteFileTool;
export '../dev/tools/sync_tools.dart' show createWorkspaceSyncTool;
export '../dev/tools/verify_tool.dart' show createRunTestsTool;
// ADB 远程控制（独立开关，不属于 Dev 组 —— 用户定案：设置里开一下就能用）。
export '../adb/adb_tool.dart' show createAdbTool, kAdbActionNames, AdbAction;
export '../adb/adb_targets.dart' show AdbTarget, AdbSecretStore;

import '../adb/adb_targets.dart' show AdbSecretStore, AdbTarget;
import '../adb/adb_tool.dart';
import '../dev/ssh/ssh_credentials.dart' show SshConfig;
import '../dev/tools/embedded_tools.dart';
import '../dev/tools/git_tools.dart';
import '../dev/tools/plan_tools.dart';
import '../dev/tools/ssh_tools.dart';
import '../dev/tools/sync_tools.dart';
import '../dev/tools/verify_tool.dart';
import '../tool_definition.dart';
import 'calculator.dart';
import 'export_file_tool.dart';
import 'file_tools.dart';
import 'data_api/data_api_tool.dart';
import 'fetch_url_tool.dart';
import 'get_time.dart';
import 'memory_tool.dart';
import 'note_tool.dart';
import 'python_tool.dart';
import 'shell_tool.dart';
import 'todo_tool.dart';
import 'unit_converter_tool.dart';
import 'weather_tool.dart';
import 'web_search_tool.dart';

/// 核心工具名（默认启用；模型侧始终可见）。
const List<String> kCoreToolNames = [
  'get_time',
  'calculator',
  'todo_write',
  'todo_list',
  'note_take',
  'note_list',
  'unit_converter',
  'memory_set',
  'memory_get',
  'read_file',
  'write_file',
  'edit_file',
  'list_files',
  'search_text',
  'export_file',
];

/// 网络/系统工具名（默认关闭；设置开启后可见）。
const List<String> kOptionalToolNames = [
  'web_search',
  'fetch_url',
  'data_api',
  'get_weather',
  'shell_exec',
  'python_exec',
];

/// Dev 开发工具名（开发模式开启后可见；默认关闭）。
const List<String> kDevToolNames = [
  'dev_shell',
  'git_status',
  'git_diff',
  'git_log',
  'git_commit',
  'git_push',
  'task_create',
  'task_list',
  'git_clone',
  'plan_create',
  'plan_update',
  'plan_list',
  'ssh_exec',
  'ssh_read_file',
  'ssh_write_file',
  'workspace_sync',
  'run_tests',
];

/// 创建全部内置工具（全量；接入层按配置过滤启用集）。
///
/// [webSearchMaxSearchesPerTurn]：web_search 每回合调用上限（DSH max_uses
/// 语义，默认 5），接入层按设置传入。
/// [includeDevTools]：Dev Agent 工具组（开发模式开启时 true）。
/// [adbEnabled] / [adbTargets] / [adbKeyStore]：ADB 远程控制（独立开关，
/// 与 Dev 模式无关；目标机白名单 + 授权密钥托管见 lib/agent/adb/adb_targets.dart）。
/// [devSshConfigs]：SSH 连接配置快照（回合级），Dev 工具据此自动连接。
/// [onTodosChanged]：todo_write 成功后的 UI 通知（对话内任务清单活卡 upsert）。
/// [conversationId]：todo 清单按会话隔离的存储键（todo_v3；null 回退
/// 'default' 键，现网唯一调用方 chat_provider 恒传真实会话 id）。
List<ToolDefinition> createBuiltinTools({
    int webSearchMaxSearchesPerTurn = 5,
    bool includeDevTools = false,
    List<SshConfig> devSshConfigs = const [],
    bool adbEnabled = false,
    List<AdbTarget> adbTargets = const [],
    AdbSecretStore? adbKeyStore,
    String? conversationId,
    void Function(List<Map<String, String>> items)? onTodosChanged}) => [
      createGetTimeTool(),
      createCalculatorTool(),
      createTodoWriteTool(
          conversationId: conversationId ?? 'default',
          onTodosChanged: onTodosChanged),
      createTodoListTool(conversationId: conversationId ?? 'default'),
      createNoteTakeTool(),
      createNoteListTool(),
      createUnitConverterTool(),
      createMemorySetTool(),
      createMemoryGetTool(),
      createReadFileTool(),
      createWriteFileTool(),
      createEditFileTool(),
      createListFilesTool(),
      createSearchTextTool(),
      createExportFileTool(),
      createWebSearchTool(
          maxSearchesPerTurn: webSearchMaxSearchesPerTurn),
      createDataApiTool(),
      createFetchUrlTool(),
      createGetWeatherTool(),
      createShellExecTool(),
      createPythonExecTool(),
      // Dev Agent 工具组（开发模式开启后由接入层过滤启用）。
      if (includeDevTools) ...[
        createDevShellTool(),
        createGitStatusTool(sshConfigs: devSshConfigs),
        createGitDiffTool(sshConfigs: devSshConfigs),
        createGitLogTool(sshConfigs: devSshConfigs),
        createGitCommitTool(sshConfigs: devSshConfigs),
        createGitPushTool(sshConfigs: devSshConfigs),
        createTaskCreateTool(),
        createTaskListTool(),
        createGitCloneTool(sshConfigs: devSshConfigs),
        createPlanCreateTool(),
        createPlanUpdateTool(),
        createPlanListTool(),
        createSshExecTool(sshConfigs: devSshConfigs),
        createSshReadFileTool(sshConfigs: devSshConfigs),
        createSshWriteFileTool(sshConfigs: devSshConfigs),
        createRunTestsTool(sshConfigs: devSshConfigs),
        createWorkspaceSyncTool(sshConfigs: devSshConfigs),
      ],
      // ADB 远程控制：独立于 Dev 模式，只看「设置 → 智能体 → 远程控制（ADB）」
      // 这一个开关（用户定案：不做逐次审批）。关掉即完全不注册，模型看不见；
      // 工具体内还有同样的门禁，防的是"注册表被别处复用"时的漏网。
      if (adbEnabled)
        createAdbTool(
            targets: adbTargets, keyStore: adbKeyStore, adbEnabled: adbEnabled),
    ];
