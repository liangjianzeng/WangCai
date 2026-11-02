/// Dev Agent 模块聚合导出。
library;

export 'dev_context.dart'
    show buildDevContext, buildWorkspaceContextSection, buildPlanSection, kDevInstruction;
export 'dev_controller.dart' show DevSessionController;
export 'dev_workspace_actions.dart'
    show
        pickSshConfigForWorkspace,
        connectWorkspace,
        ensureRemoteProjectDir,
        listRemoteDirs,
        createAndActivateWorkspace,
        createWorkspaceOnActiveConnection,
        workspaceBackendLabel;
export 'native_env.dart' show DevNativeEnv, DevNativeInfo;
export 'safety.dart' show checkDangerousCommand, DangerousCommandPolicy;
export 'tools/plan_tools.dart' show newDevTaskId, taskBelongsToWorkspace;
export 'ssh/ssh_credentials.dart' show SshAuthType, SshConfig, SshKeyGen;
export 'ssh/secret_store.dart'
    show resolveSshSecrets, resolveSshSecretsAll, saveSshSecrets, deleteSshSecrets;
export 'ssh/ssh_diagnostics.dart'
    show SshTargetKind, classifySshFailure, sshTargetKindOf, sshUsesPasswordAuth;
export 'ssh/ssh_environment.dart' show SshEnvironmentService, SshStatus;
export 'task.dart' show DevPlan, DevPlanStep, DevTask, DevTaskStatus;
export 'termux_intent.dart' show TermuxIntentService;
export 'workspace.dart' show DevWorkspace, WorkspaceBackend, effectiveWorkspaceOf, kWorkspaceIdArgKey, sanitizeWorkspaceDirName;
export 'workspace_store.dart' show DevStore;
