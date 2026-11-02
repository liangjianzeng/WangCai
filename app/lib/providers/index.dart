// Shared provider exports — avoids circular dependencies between chat_provider,
// model_provider, and download_provider.

export 'shared_providers.dart' show
    inferenceServiceProvider, deviceInfoProvider;
export 'chat_provider.dart' show
    storageServiceProvider,
    currentModelIdProvider,
    conversationsProvider,
    ConversationsNotifier,
    currentConversationIdProvider,
    messagesProvider,
    isGeneratingProvider,
    runningTurnsProvider,
    agentPendingQuestionProvider,
    AgentPendingQuestion,
    chatNotifierProvider,
    kLocalVisionSupported;

export 'model_provider.dart' show
    ModelLifecyclePhase,
    ModelState,
    ModelManagerNotifier,
    modelManagerProvider;

export 'download_provider.dart' show
    DownloadNotifier,
    downloadServiceProvider,
    downloadNotifierProvider,
    downloadTaskProvider;

export 'model_display_provider.dart' show
    ModelDisplayNameNotifier,
    modelDisplayNameProvider,
    modelDisplayNameServiceProvider;
