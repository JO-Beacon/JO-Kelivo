import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/conversation_tree.dart';
import '../../../core/models/quick_phrase.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/providers/quick_phrase_provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/tts/tts_text_selection.dart';
import '../../../core/services/haptics.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/platform_utils.dart';
import '../../../utils/assistant_regex.dart';
import '../../chat/models/message_edit_result.dart';
import '../../chat/widgets/chat_message_widget.dart' show ToolUIPart;
import '../../chat/widgets/message_edit_sheet.dart';
import '../../chat/widgets/message_export_sheet.dart';
import '../../../desktop/message_edit_dialog.dart';
import '../../../desktop/hotkeys/chat_action_bus.dart';
import '../../../desktop/hotkeys/sidebar_tab_bus.dart';
import 'chat_controller.dart';
import 'message_render_model.dart';
import 'stream_controller.dart' as stream_ctrl;
import 'generation_controller.dart';
import 'scroll_controller.dart' as scroll_ctrl;
import 'home_view_model.dart';
import '../services/message_builder_service.dart';
import '../services/message_generation_service.dart';
import '../services/ask_user_interaction_service.dart';
import '../services/ocr_service.dart';
import '../services/translation_service.dart';
import '../services/file_upload_service.dart';
import '../utils/chat_layout_constants.dart';
import '../widgets/chat_input_bar.dart';
import '../../model/widgets/model_select_sheet.dart';

enum ChatSelectionMode { share, delete }

/// UI 状态的翻译数据（展开/折叠）。
class TranslationData {
  bool expanded = true; // 添加翻译时默认展开
}

/// 管理 HomePage 所有状态和服务接线的控制器。
///
/// 此控制器从 _HomePageState 中抽取非 UI 逻辑，用于：
/// - 集中管理状态
/// - 使代码更易测试
/// - 支持在不同页面布局（移动端/平板/桌面端）中复用
/// - 降低 State 类的复杂度
///
/// HomePage widget 现在只管理：
/// - 生命周期（initState、dispose）
/// - 布局选择（移动端或平板）
/// - 构建 UI 树
class HomePageController extends ChangeNotifier {
  HomePageController({
    required BuildContext context,
    required TickerProvider vsync,
    required GlobalKey<ScaffoldState> scaffoldKey,
    required GlobalKey inputBarKey,
    required FocusNode inputFocus,
    required TextEditingController inputController,
    required ChatInputBarController mediaController,
    required ScrollController scrollController,
  }) : this._(
         context,
         vsync,
         scaffoldKey,
         inputBarKey,
         inputFocus,
         inputController,
         mediaController,
         scrollController,
       );

  HomePageController._(
    this._context,
    this._vsync,
    this._scaffoldKey,
    this._inputBarKey,
    this._inputFocus,
    this._inputController,
    this._mediaController,
    this._scrollController,
  ) {
    _initialize();
  }

  // ============================================================================
  // 依赖（注入）
  // ============================================================================

  final BuildContext _context;
  final TickerProvider _vsync;
  final GlobalKey<ScaffoldState> _scaffoldKey;
  final GlobalKey _inputBarKey;
  final FocusNode _inputFocus;
  final TextEditingController _inputController;
  final ChatInputBarController _mediaController;
  ScrollController _scrollController;

  // ============================================================================
  // 服务和控制器（内部创建）
  // ============================================================================

  late ChatService _chatService;
  late ChatController _chatController;
  late stream_ctrl.StreamController _streamController;
  late GenerationController _generationController;
  late MessageBuilderService _messageBuilderService;
  late MessageGenerationService _messageGenerationService;
  late HomeViewModel _viewModel;
  late OcrService _ocrService;
  late TranslationService _translationService;
  late FileUploadService _fileUploadService;
  late scroll_ctrl.ChatScrollController _scrollCtrl;

  McpProvider? _mcpProvider;
  StreamSubscription<ChatAction>? _chatActionSub;

  /// 编辑面板关闭后仍会继续执行持久化和分支刷新；同一时间只允许一条
  /// 编辑提交链路，避免重复点击或旧回调并发改写同一棵会话树。
  Future<void>? _editMessageInFlight;

  // ============================================================================
  // 动画控制器
  // ============================================================================

  late AnimationController _convoFadeController;
  late Animation<double> _convoFade;
  late AnimationController _messageJumpTransitionController;
  late Animation<double> _messageJumpOpacity;
  bool _chatControllerReady = false;

  /// 最新动画会话切换的序列号；被取代的切换会检查它，
  /// 以丢弃自己的预提交工作。
  int _switchSerial = 0;

  // 启动预热（缓存方案第 14 项）：初始恢复完成后，
  // 在空闲时间串行预取最近的会话。
  // 任何用户操作都会递增 _warmupSerial，放弃剩余队列。
  static const int startupWarmupConversationCount = 4;
  int _warmupSerial = 0;
  bool _startupWarmupScheduled = false;

  @visibleForTesting
  int get debugWarmupSerial => _warmupSerial;

  @visibleForTesting
  void debugAbandonStartupWarmup() {
    _warmupSerial++;
  }

  @visibleForTesting
  HomeViewModel get debugViewModel => _viewModel;

  // ============================================================================
  // 状态字段
  // ============================================================================

  // 翻译 UI 状态
  final Map<String, TranslationData> _translations =
      <String, TranslationData>{};

  /// 当前正在播放删除动画的时间线槽位。槽位数据只有在动画完成后
  /// 才会删除，这样控件可以淡出并折叠，同时周围消息拼接在一起。
  final Set<String> _removingSlotIds = <String>{};

  // 注意：基于 GlobalKey 的消息导航已替换为索引滚动。

  // 选择模式
  bool _selecting = false;
  ChatSelectionMode _selectionMode = ChatSelectionMode.share;
  final Set<String> _selectedItems = <String>{};

  /// 来自上次全历史选择加载的可选择投影 ID。
  /// 在全选/全切换/反选加载投影前为 null。
  Set<String>? _selectableProjectionIds;

  /// 选择开始、取消、完成或会话切换时递增，
  /// 使进行中的全选/切换/反选结果被忽略。
  int _selectionEpoch = 0;
  bool _showThinkingTools = false;
  bool _showThinkingContent = false;

  // 桌面端拖放
  bool _isDragHovering = false;

  // 应用生命周期（当前未使用，但为将来的通知逻辑保留）
  // ignore: unused_field
  bool _appInForeground = true;

  // 侧边栏状态（平板/桌面端）
  bool _tabletSidebarOpen = true;
  bool _rightSidebarOpen = true;
  double _embeddedSidebarWidth = 300;
  double _rightSidebarWidth = 300;
  bool _desktopUiInited = false;

  // 抽屉状态
  double _lastDrawerValue = 0.0;

  // 桌面端全局搜索模式
  bool _isGlobalSearchMode = false;
  String _globalSearchQuery = '';

  // 选择全局搜索结果后的消息级聚焦目标
  String? _spotlightMessageId;
  int _spotlightToken = 0;

  // 输入栏测量
  double _inputBarHeight = 72;

  // 动画调优
  static const Duration _postSwitchScrollDelay = Duration(milliseconds: 220);
  static const double _sidebarMinWidth = 200;
  static const double _sidebarMaxWidth = 360;

  // ============================================================================
  // Getter - 状态访问
  // ============================================================================

  GlobalKey<ScaffoldState> get scaffoldKey => _scaffoldKey;
  GlobalKey get inputBarKey => _inputBarKey;
  FocusNode get inputFocus => _inputFocus;
  TextEditingController get inputController => _inputController;
  ChatInputBarController get mediaController => _mediaController;
  ScrollController get scrollController => _scrollController;
  Animation<double> get convoFade => _convoFade;
  AnimationController get convoFadeController => _convoFadeController;
  Animation<double> get messageJumpOpacity => _messageJumpOpacity;

  Map<String, TranslationData> get translations => _translations;
  Set<String> get removingSlotIds => _removingSlotIds;
  ChatController get chatController => _chatController;
  bool get selecting => _selecting;
  ChatSelectionMode get selectionMode => _selectionMode;
  Set<String> get selectedItems => _selectedItems;
  int get selectedCount => _selectedItems.length;
  bool get showThinkingTools => _showThinkingTools;
  bool get showThinkingContent => _showThinkingContent;
  bool get isDragHovering => _isDragHovering;
  bool get tabletSidebarOpen => _tabletSidebarOpen;
  bool get rightSidebarOpen => _rightSidebarOpen;
  double get embeddedSidebarWidth => _embeddedSidebarWidth;
  double get rightSidebarWidth => _rightSidebarWidth;
  double get inputBarHeight => _inputBarHeight;
  bool get desktopUiInited => _desktopUiInited;
  bool get isGlobalSearchMode => _isGlobalSearchMode;
  String get globalSearchQuery => _globalSearchQuery;
  String? get spotlightMessageId => _spotlightMessageId;
  int get spotlightToken => _spotlightToken;
  static double get sidebarMinWidth => _sidebarMinWidth;
  static double get sidebarMaxWidth => _sidebarMaxWidth;

  // 委托给 ChatController
  Conversation? get currentConversation => _chatController.currentConversation;
  List<ChatMessage> get messages => _chatController.messages;
  ConversationTree? get conversationTree => _viewModel.conversationTree;
  String? get activeBranchId => _viewModel.activeBranchId;

  /// 废弃：版本选择不再被运行时使用，树是唯一真相。
  @Deprecated('Version selections are no longer used at runtime')
  Map<String, int> get versionSelections => const <String, int>{};

  Set<String> get loadingConversationIds => _viewModel.loadingConversationIds;
  Map<String, StreamSubscription<dynamic>> get conversationStreams =>
      _chatController.conversationStreams;

  List<ChatMessage> get visibleMessages =>
      _filterActivePath(_chatController.messages);

  List<ChatMessage> get visibleCollapsedMessages {
    final tree = _viewModel.conversationTree;
    if (tree == null) {
      return _filterActivePath(_chatController.collapsedMessages);
    }
    // 在树模式下，活动路径就是投影。旧版本组不能折叠掉
    // 当前选中的分支。
    return _filterActivePath(_chatController.messages);
  }

  Map<String, List<ChatMessage>> get visibleGroupedMessages {
    final tree = _viewModel.conversationTree;
    if (tree == null) {
      final visibleGroupIds = <String>{
        for (final message in visibleCollapsedMessages)
          message.groupId ?? message.id,
      };
      return <String, List<ChatMessage>>{
        for (final entry in _chatController.groupedMessages.entries)
          if (visibleGroupIds.contains(entry.key)) entry.key: entry.value,
      };
    }
    return <String, List<ChatMessage>>{
      for (final message in visibleCollapsedMessages)
        message.groupId ?? message.id: <ChatMessage>[message],
    };
  }

  List<MessageRenderModel> get visibleMessageRenderModels {
    final tree = _viewModel.conversationTree;
    if (tree == null) {
      final visibleIds = <String>{
        for (final message in visibleCollapsedMessages) message.id,
      };
      return _chatController.messageRenderModels
          .where((model) => visibleIds.contains(model.message.id))
          .toList(growable: false);
    }
    final visible = visibleCollapsedMessages;
    final grouped = visibleGroupedMessages;
    return MessageRenderModelProjector.project(
      messages: visible,
      byGroup: grouped,
      versionSelections: const <String, int>{},
      versionCounts: <String, int>{
        for (final entry in grouped.entries) entry.key: 1,
      },
      contextDividerIndex: _treeContextDividerIndex(visible),
    );
  }

  Map<String, List<String>> get siblingBranchIdsByMessageId {
    final tree = _viewModel.conversationTree;
    if (tree == null) return const <String, List<String>>{};
    return tree.siblingBranchIdsByMessageId();
  }

  List<ChatMessage> _filterActivePath(Iterable<ChatMessage> source) {
    final tree = _viewModel.conversationTree;
    if (tree == null) return source.toList(growable: false);
    final activeIds = tree.activePath().toSet();
    return source
        .where((message) => activeIds.contains(message.id))
        .toList(growable: false);
  }

  int _treeContextDividerIndex(List<ChatMessage> visible) {
    final raw = _chatController.loadedWindowTruncateIndex();
    if (raw <= 0 || visible.isEmpty) return -1;
    final visibleIds = visible.map((message) => message.id).toSet();
    final rawMessages = _chatController.messages;
    var visibleIndex = 0;
    final limit = raw.clamp(0, rawMessages.length);
    for (var index = 0; index < limit; index++) {
      if (visibleIds.contains(rawMessages[index].id)) visibleIndex++;
    }
    return visibleIndex - 1;
  }

  /// 从应用启动到初始会话恢复（或草稿创建）完成为 true，
  /// 使空状态不会在启动期间闪现。
  bool _startupConversationPending = true;

  /// 驱动消息列表三态占位符：仅当初始恢复等待中或冷窗口加载进行中
  /// 为 true。快速路径缓存命中会在一帧批次内完成，永远不会显示骨架。
  bool get isLoadingWindow =>
      _startupConversationPending || _chatController.isLoadingWindow;

  // 委托给 StreamController
  Map<String, stream_ctrl.ReasoningData> get reasoning =>
      _streamController.reasoning;
  Map<String, List<stream_ctrl.ReasoningSegmentData>> get reasoningSegments =>
      _streamController.reasoningSegments;
  Map<String, stream_ctrl.ContentSplitData> get contentSplits =>
      _streamController.contentSplits;
  Map<String, List<ToolUIPart>> get toolParts => _streamController.toolParts;

  /// 流式内容更新的轻量通知器。
  /// 在 MessageListView 中与 ValueListenableBuilder 一起使用，避免整页重建。
  stream_ctrl.StreamingContentNotifier get streamingContentNotifier =>
      _streamController.streamingContentNotifier;

  // 委托给滚动控制器
  scroll_ctrl.ChatScrollController get scrollCtrl => _scrollCtrl;

  bool get isDesktopPlatform => PlatformUtils.isDesktopTarget;

  bool get isCurrentConversationLoading =>
      _viewModel.isCurrentConversationLoading;

  QueuedChatInput? get currentQueuedInput => _viewModel.currentQueuedInput;

  ValueNotifier<bool> get isProcessingFiles => _viewModel.isProcessingFiles;

  bool get isTemporaryConversation =>
      _chatService.isTemporaryConversation(currentConversation?.id);

  bool get canToggleTemporaryConversation =>
      currentConversation != null && messages.isEmpty;

  @override
  void notifyListeners() {
    if (_chatControllerReady) {
      _chatController.invalidateCache();
    }
    super.notifyListeners();
  }

  // ============================================================================
  // 初始化
  // ============================================================================

  void _initialize() {
    _initializeAnimations();
    _initializeControllers();
    _initializeScrollController();
    _initializeServices();
    _initializeViewModel();
    _wireViewModelCallbacks();
    _initializeProviders();
    _setupKeyboardListeners();
    _setupDesktopFeatures();
  }

  void _initializeAnimations() {
    _convoFadeController = AnimationController(
      vsync: _vsync,
      duration: const Duration(milliseconds: 180),
    );
    _convoFade = CurvedAnimation(
      parent: _convoFadeController,
      curve: Curves.easeOutCubic,
    );
    _convoFadeController.value = 1.0;

    _messageJumpTransitionController = AnimationController(
      vsync: _vsync,
      duration: const Duration(milliseconds: 180),
    );
    final messageJumpCurve = CurvedAnimation(
      parent: _messageJumpTransitionController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _messageJumpOpacity = messageJumpCurve;
    _messageJumpTransitionController.value = 1.0;
  }

  void _initializeControllers() {
    _chatService = _context.read<ChatService>();
    _chatController = ChatController(chatService: _chatService);
    _chatControllerReady = true;
    _streamController = stream_ctrl.StreamController(
      chatService: _chatService,
      onStateChanged: () => notifyListeners(),
      getSettingsProvider: () => _context.read<SettingsProvider>(),
      getCurrentConversationId: () => currentConversation?.id,
      onStreamTick: () => _scrollCtrl.autoScrollToBottomIfNeeded(),
    );
  }

  void _initializeServices() {
    _ocrService = OcrService(
      resolveContentHashes: (paths) =>
          _chatService.resolveImageContentHashes(paths),
      loadArtifacts: (revisionIds) =>
          _chatService.getImageOcrArtifacts(revisionIds),
      persistArtifact: (revisionId, items) =>
          _chatService.upsertImageOcrArtifactItems(revisionId, items),
      onError: (error) =>
          _showBackgroundTaskFailure(BackgroundTaskKind.ocr, error),
    );
    _translationService = TranslationService(
      chatService: _chatService,
      getContext: () => _scaffoldKey.currentContext ?? _context,
    );
    _fileUploadService = FileUploadService(
      getContext: () => _context,
      mediaController: _mediaController,
      isImageCropperEnabled: () =>
          _context.read<SettingsProvider>().imageCropperEnabled,
      getImageCompressConfig: () =>
          _context.read<SettingsProvider>().resolveImageCompressConfig(),
    );
    _messageBuilderService = MessageBuilderService(
      chatService: _chatService,
      contextProvider: _context,
      ocrHandler: (imagePaths, {revisionId, session}) =>
          _ocrService.getOcrTextForImages(
            imagePaths,
            _context,
            revisionId: revisionId,
            session: session,
          ),
      ocrPrefetch: ({required revisionIds, required imagePaths}) =>
          _ocrService.prefetchPersistedOcr(
            revisionIds: revisionIds,
            imagePaths: imagePaths,
          ),
      geminiThoughtSignatureHandler: _appendGeminiThoughtSignatureForApi,
    );
    _messageBuilderService.ocrTextWrapper = _ocrService.wrapOcrBlock;
    _generationController = GenerationController(
      chatService: _chatService,
      chatController: _chatController,
      streamController: _streamController,
      messageBuilderService: _messageBuilderService,
      contextProvider: _context,
      onStateChanged: () => notifyListeners(),
      getTitleForLocale: _titleForLocale,
    );
    _messageGenerationService = MessageGenerationService(
      chatService: _chatService,
      messageBuilderService: _messageBuilderService,
      generationController: _generationController,
      streamController: _streamController,
      contextProvider: _context,
    );
  }

  void _initializeViewModel() {
    _viewModel = HomeViewModel(
      chatService: _chatService,
      messageBuilderService: _messageBuilderService,
      messageGenerationService: _messageGenerationService,
      generationController: _generationController,
      streamController: _streamController,
      chatController: _chatController,
      contextProvider: _context,
      getTitleForLocale: _titleForLocale,
    );
    _viewModel.onBackgroundTaskError = _showBackgroundTaskFailure;
    _viewModel.addListener(notifyListeners);
  }

  void _showBackgroundTaskFailure(BackgroundTaskKind task, Object error) {
    if (!_context.mounted) return;
    final l10n = AppLocalizations.of(_context)!;
    final taskName = switch (task) {
      BackgroundTaskKind.ocr => l10n.defaultModelPageOcrModelTitle,
      BackgroundTaskKind.title => l10n.defaultModelPageTitleModelTitle,
      BackgroundTaskKind.summary => l10n.defaultModelPageSummaryModelTitle,
      BackgroundTaskKind.suggestions =>
        l10n.defaultModelPageSuggestionModelTitle,
      BackgroundTaskKind.memory => l10n.memorySettingsPageTitle,
    };
    showAppSnackBar(
      _context,
      message: l10n.backgroundTaskFailed(taskName, error.toString()),
      type: NotificationType.error,
    );
  }

  void _wireViewModelCallbacks() {
    _viewModel.onError = (error) {
      final l10n = AppLocalizations.of(_context)!;
      showAppSnackBar(
        _context,
        message: _localizeGenerationError(l10n, error),
        type: NotificationType.error,
      );
    };
    _viewModel.onWarning = (warning) {
      final l10n = AppLocalizations.of(_context)!;
      if (warning == 'no_model') {
        showAppSnackBar(
          _context,
          message: l10n.homePagePleaseSelectModel,
          type: NotificationType.warning,
        );
      }
    };
    _viewModel.onScrollToBottom = () {
      _scrollCtrl.resetUserScrolling();
      _scrollCtrl.scrollToBottom(
        animate: !_chatController.isCurrentConversationLoading,
      );
    };
    _viewModel.onHapticFeedback = () {
      try {
        final settings = _context.read<SettingsProvider>();
        if (settings.hapticsOnGenerate) Haptics.light();
      } catch (_) {}
    };
    _viewModel.onScheduleImageSanitize =
        (messageId, content, {bool immediate = false}) {
          _scheduleInlineImageSanitize(
            messageId,
            latestContent: content,
            immediate: immediate,
          );
        };
    _viewModel.onConversationSwitched = () {
      _restoreMessageUiState();
      _scrollCtrl.positionAtBottomOnNextLayout();
    };
    _viewModel.onStreamFinished = (conversationId) {
      // 流结束时触发 UI 更新
      notifyListeners();
      if (currentConversation?.id == conversationId) {
        _scrollCtrl.stickToBottomAfterGeneration();
      }
    };
    _viewModel.onAssistantMessageFinished = _handleAssistantMessageFinished;
  }

  String _localizeGenerationError(AppLocalizations l10n, String error) {
    switch (error) {
      case 'audio_attachment_unsupported':
        return l10n.homePageAudioAttachmentUnsupported;
      default:
        return '${l10n.generationInterrupted}: $error';
    }
  }

  void _initializeScrollController() {
    _scrollCtrl = scroll_ctrl.ChatScrollController(
      scrollController: _scrollController,
      onStateChanged: () => notifyListeners(),
      getAutoScrollEnabled: () =>
          _context.read<SettingsProvider>().autoScrollEnabled,
      getAutoScrollIdleSeconds: () =>
          _context.read<SettingsProvider>().autoScrollIdleSeconds,
      getTopRevealInset: () =>
          kToolbarHeight + MediaQuery.paddingOf(_context).top,
      isGenerating: () => _chatController.isCurrentConversationLoading,
    );
  }

  /// 为新打开的会话提供自己的滚动状态，
  /// 与 RikkaHub 每个 ChatPage 的 `rememberLazyListState` 生命周期一致。
  void replaceScrollController(ScrollController controller) {
    if (identical(_scrollController, controller)) return;
    _scrollCtrl.dispose();
    _scrollController = controller;
    _initializeScrollController();
    _scrollCtrl.positionAtBottomOnNextLayout();
  }

  void _initializeProviders() {
    try {
      final quickPhraseProvider = _context.read<QuickPhraseProvider>();
      Future.microtask(() async {
        try {
          await quickPhraseProvider.initialize();
        } catch (_) {}
      });
    } catch (_) {}
    try {
      final instructionProvider = _context.read<InstructionInjectionProvider>();
      Future.microtask(() async {
        try {
          await instructionProvider.initialize();
        } catch (_) {}
      });
    } catch (_) {}
    try {
      final memoryProvider = _context.read<MemoryProvider>();
      Future.microtask(() async {
        try {
          await memoryProvider.initialize();
        } catch (_) {}
      });
    } catch (_) {}
    try {
      _mcpProvider = _context.read<McpProvider>();
      _mcpProvider!.addListener(_onMcpChanged);
    } catch (_) {}
  }

  void _setupKeyboardListeners() {}

  void _setupDesktopFeatures() {
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inputFocus.requestFocus();
      });
    }
    _chatActionSub = ChatActionBus.instance.stream.listen((action) {
      final ctx = _context;
      if (!ctx.mounted) return;
      final settingsProvider = ctx.read<SettingsProvider>();
      switch (action) {
        case ChatAction.newTopic:
          unawaited(createNewConversationAnimated());
          break;
        case ChatAction.toggleLeftPanelTopics:
        case ChatAction.toggleLeftPanelAssistants:
          if (settingsProvider.desktopTopicPosition !=
              DesktopTopicPosition.left) {
            return;
          }
          final wantAssistants =
              (action == ChatAction.toggleLeftPanelAssistants);
          if (!_tabletSidebarOpen) {
            _tabletSidebarOpen = true;
            notifyListeners();
            try {
              settingsProvider.setDesktopSidebarOpen(true);
            } catch (_) {}
          }
          if (wantAssistants) {
            DesktopSidebarTabBus.instance.switchToAssistants();
          } else {
            DesktopSidebarTabBus.instance.switchToTopics();
          }
          break;
        case ChatAction.focusInput:
          if (isDesktopPlatform) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _inputFocus.requestFocus();
            });
          }
          break;
        case ChatAction.switchModel:
          unawaited(showModelSelectSheet(ctx));
          break;
        case ChatAction.enterGlobalSearch:
          enterGlobalSearchMode(preserveQuery: true);
          break;
        case ChatAction.exitGlobalSearch:
          exitGlobalSearchMode(clearQuery: true);
          break;
      }
    });
  }

  void enterGlobalSearchMode({bool preserveQuery = true}) {
    _isGlobalSearchMode = true;
    if (!preserveQuery) _globalSearchQuery = '';
    notifyListeners();
  }

  void exitGlobalSearchMode({bool clearQuery = true}) {
    _isGlobalSearchMode = false;
    if (clearQuery) _globalSearchQuery = '';
    notifyListeners();
  }

  void setGlobalSearchQuery(String value) {
    if (_globalSearchQuery == value) return;
    _globalSearchQuery = value;
    notifyListeners();
  }

  Future<void> openGlobalSearchResult({
    required String conversationId,
    required String messageId,
  }) async {
    await switchConversationAnimated(conversationId);
    // 多等待一帧，让新会话的索引消息列表在解析目标前完成挂载。
    try {
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}
    if (messageId.isNotEmpty) {
      await scrollToMessageId(messageId);
      _spotlightMessageId = messageId;
      _spotlightToken++;
      notifyListeners();
    }
  }

  Future<void> initChat() async {
    final prefs = _context.read<SettingsProvider>();
    final assistantProvider = _context.read<AssistantProvider>();
    try {
      // 这两个启动流程彼此独立。
      await Future.wait([assistantProvider.loaded, _chatService.init()]);
      if (prefs.newChatOnLaunch) {
        await _createNewConversation();
      } else {
        final conversations = _chatService.getAllConversations();
        if (conversations.isNotEmpty) {
          final recent = conversations.first;
          _chatService.setCurrentConversation(recent.id);
          // 助手恢复和窗口加载彼此独立；消息列表已经能够容忍
          // 一帧的缺少助手回退。
          final restoreAssistant = Future<void>(() async {
            if ((recent.assistantId ?? '').isNotEmpty) {
              try {
                await assistantProvider.setCurrentAssistant(
                  recent.assistantId!,
                );
              } catch (_) {}
            }
          });
          final loadWindow = _chatController.setCurrentConversationAndLoad(
            recent,
          );
          // 在窗口加载进行中重建，使冷加载显示骨架屏而不是空白列表。
          notifyListeners();
          await Future.wait([restoreAssistant, loadWindow]);
          await _viewModel.ensureConversationTreeForCurrentConversation();
          _streamController.clearGeminiThoughtSigs();
          _restoreMessageUiState();
          _scrollCtrl.positionAtBottomOnNextLayout();
          notifyListeners();
          _scheduleStartupWarmup();
        } else {
          // 没有会话存在时创建一个新的空会话，使 UI 正确显示
          // 临时聊天开关按钮，而不是回退到“新建会话”按钮。
          await _createNewConversation();
        }
      }
    } finally {
      _startupConversationPending = false;
      notifyListeners();
    }
  }

  /// 初始恢复后在空闲时间排队预热最近会话（缓存方案第 14 项）。
  /// 每次启动只运行一次。
  void _scheduleStartupWarmup() {
    if (_startupWarmupScheduled) return;
    _startupWarmupScheduled = true;
    final serial = _warmupSerial;
    final currentId = _chatService.currentConversationId;
    final ids = _chatService
        .getAllConversations()
        .take(startupWarmupConversationCount)
        .map((c) => c.id)
        .where(
          (id) => id != currentId && !_chatService.isTemporaryConversation(id),
        )
        .toList(growable: false);
    if (ids.isEmpty) return;
    final Future<void> task;
    try {
      task = SchedulerBinding.instance.scheduleTask(
        () => warmUpRecentConversations(ids, serial),
        Priority.idle,
        debugLabel: 'home.startupWarmup',
      );
    } catch (_) {
      // 没有调度器绑定（纯单元测试）：预热是可选的。
      return;
    }
    unawaited(task.catchError((Object _) {}));
  }

  /// 仅缓存预热：填充服务消息缓存（计入常规缓存预算），
  /// 且不通知监听器。当 [serial] 不再匹配当前预热序列号时
  /// （即任何用户操作后），剩余队列会被放弃。
  @visibleForTesting
  Future<void> warmUpRecentConversations(
    List<String> conversationIds,
    int serial,
  ) async {
    for (final id in conversationIds) {
      if (serial != _warmupSerial || !_context.mounted) return;
      // 流式会话拥有单一连接队列。
      if (_chatController.loadingConversationIds.contains(id)) continue;
      try {
        await _chatService.loadTimelinePage(
          id,
          limit: ChatService.defaultTimelineInitialSlots,
        );
      } catch (_) {
        // 预热失败不会造成用户可见损失。
      }
    }
  }

  void initDesktopUi() {
    if (PlatformUtils.isDesktopTarget && !_desktopUiInited) {
      _desktopUiInited = true;
      try {
        final sp = _context.read<SettingsProvider>();
        _embeddedSidebarWidth = sp.desktopSidebarWidth.clamp(
          _sidebarMinWidth,
          _sidebarMaxWidth,
        );
        _tabletSidebarOpen = sp.desktopSidebarOpen;
        _rightSidebarOpen = sp.desktopRightSidebarOpen;
        _rightSidebarWidth = sp.desktopRightSidebarWidth.clamp(
          _sidebarMinWidth,
          _sidebarMaxWidth,
        );
      } catch (_) {}
    }
  }

  // ============================================================================
  // 公共方法 - 消息操作
  // ============================================================================

  Future<ChatInputSubmissionResult> sendMessage(ChatInputData input) async {
    final content = input.text.trim();
    if (content.isEmpty &&
        input.imagePaths.isEmpty &&
        input.documents.isEmpty) {
      return ChatInputSubmissionResult.rejected;
    }
    _warmupSerial++;
    if (currentConversation == null) {
      await _createNewConversation();
    }

    final result = await _viewModel.sendMessage(input);
    if (result != ChatInputSubmissionResult.rejected) {
      notifyListeners();
    }
    return result;
  }

  Future<void> sendSuggestion(String suggestion) async {
    final text = suggestion.trim();
    if (text.isEmpty) return;
    final settings = _context.read<SettingsProvider>();
    if (settings.insertSuggestionOnTapOnly) {
      _replaceInputWithSuggestion(text);
      return;
    }
    // 落在预加载竞态窗口内的点击是重复操作：
    // 第一次发送已被占用，但尚未设置加载守卫。
    final conversationId = currentConversation?.id;
    if (conversationId != null &&
        _viewModel.isConversationSendInFlight(conversationId)) {
      return;
    }
    await sendMessage(ChatInputData(text: text));
  }

  void _replaceInputWithSuggestion(String text) {
    _inputController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_context.mounted) return;
      _inputFocus.requestFocus();
    });
    notifyListeners();
  }

  Future<void> toggleTemporaryConversation() async {
    await _viewModel.toggleTemporaryConversation();
  }

  void cancelQueuedMessage() {
    final restored = _viewModel.cancelCurrentQueuedInput();
    if (restored == null) return;

    _inputController.value = TextEditingValue(
      text: restored.text,
      selection: TextSelection.collapsed(offset: restored.text.length),
      composing: TextRange.empty,
    );
    _mediaController.restoreInput(restored);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_context.mounted) return;
      _inputFocus.requestFocus();
    });
    notifyListeners();
  }

  Future<void> regenerateAtMessage(
    ChatMessage message, {
    bool assistantAsNewReply = false,
    String? existingBranchId,
  }) async {
    if (currentConversation == null) return;
    _warmupSerial++;

    final success = await _viewModel.regenerateAtMessage(
      message,
      assistantAsNewReply: assistantAsNewReply,
      existingBranchId: existingBranchId,
      allowImagesApiRouting: _mediaController.allowImagesApiRouting,
    );
    if (success) {
      notifyListeners();
    }
  }

  Future<void> submitRecoveredAskUserAnswer(
    ChatMessage message,
    ToolUIPart part,
    AskUserResult result,
  ) async {
    final conversation = currentConversation;
    if (conversation == null ||
        _viewModel.isConversationSendInFlight(conversation.id)) {
      return;
    }

    final content = result.toJsonString();
    await _chatService.upsertToolEvent(
      message.id,
      id: part.id,
      name: part.toolName,
      arguments: part.arguments,
      content: content,
    );

    final parts = List<ToolUIPart>.of(
      _streamController.getToolParts(message.id) ?? const <ToolUIPart>[],
    );
    final idx = parts.indexWhere(
      (candidate) =>
          candidate.id == part.id ||
          (candidate.id.isEmpty && candidate.toolName == part.toolName),
    );
    final answeredPart = ToolUIPart(
      id: part.id,
      toolName: part.toolName,
      arguments: part.arguments,
      content: content,
      loading: false,
    );
    if (idx >= 0) {
      parts[idx] = answeredPart;
    } else {
      parts.add(answeredPart);
    }
    _streamController.setToolParts(message.id, parts);
    notifyListeners();

    await _viewModel.continueAssistantMessageAfterToolAnswer(
      message,
      allowImagesApiRouting: _mediaController.allowImagesApiRouting,
    );
  }

  Future<void> cancelStreaming() async {
    await _viewModel.cancelStreaming();
    notifyListeners();
  }

  // ============================================================================
  // 公共方法 - 会话管理
  // ============================================================================

  Future<void> switchConversationAnimated(String id) async {
    final serial = ++_switchSerial;
    _warmupSerial++;
    if (currentConversation?.id == id) {
      // 已在目标会话上：上面的串行递增会取消任何进行中的切换；
      // 再次显示当前列表，以防淡出正在等待或进行中。
      // 当列表完全可见时，forward() 是无操作。
      if (!isDesktopPlatform) {
        unawaited(_forwardConvoFade());
      }
      return;
    }
    // 使先前聊天的进行中全选/切换/反选失效。
    _selectionEpoch++;
    if (!isDesktopPlatform) {
      // 先获取后提交：淡出、进度刷新和数据库获取并发运行，
      // 但获取到的窗口只有在淡出完成后才提交，
      // 避免在透明度不为 0 时闪现新数据。
      final fadeFuture = _reverseConvoFade();
      final flushFuture = _flushProgressSilently();
      final PreparedConversationSwitch? prepared;
      try {
        prepared = await _viewModel.prepareConversationSwitch(id);
      } catch (_) {
        if (serial == _switchSerial) await _forwardConvoFade();
        rethrow;
      }
      if (serial != _switchSerial) return;
      await Future.wait([fadeFuture, flushFuture]);
      if (serial != _switchSerial) return;
      if (prepared == null) {
        // 目标已消失；再次显示当前列表。
        await _forwardConvoFade();
        return;
      }
      _viewModel.commitConversationSwitch(prepared);
      _clearSelectionState();
      notifyListeners();

      try {
        await WidgetsBinding.instance.endOfFrame;
        if (serial != _switchSerial || currentConversation?.id != id) return;
        // 在新会话仍然透明时解析真正的最后一项。
        // 它的首个 maxScrollExtent 可能包含惰性估算。
        final activeScrollController = _scrollCtrl;
        await activeScrollController.settleAtBottomBeforeReveal();
        if (serial != _switchSerial ||
            currentConversation?.id != id ||
            !identical(_scrollCtrl, activeScrollController)) {
          return;
        }
        await _convoFadeController.forward();
      } catch (_) {}
    } else {
      // 桌面端使用与移动端相同的准备/提交原子性，但不使用淡出：
      // 当前会话/选择在提交前保持不变。
      await _flushProgressSilently();
      try {
        _convoFadeController.stop();
        _convoFadeController.value = 1.0;
      } catch (_) {}
      if (serial != _switchSerial) return;
      final prepared = await _viewModel.prepareConversationSwitch(id);
      if (serial != _switchSerial) return;
      if (prepared == null) return;
      _viewModel.commitConversationSwitch(prepared);
      _clearSelectionState();
      notifyListeners();
    }

    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inputFocus.requestFocus();
      });
    }
  }

  Future<void> _reverseConvoFade() async {
    try {
      await _convoFadeController.reverse();
    } catch (_) {}
  }

  Future<void> _forwardConvoFade() async {
    try {
      await _convoFadeController.forward();
    } catch (_) {}
  }

  Future<void> _flushProgressSilently() async {
    try {
      await _viewModel.flushCurrentConversationProgress();
    } catch (_) {}
  }

  Future<void> createNewConversationAnimated() async {
    // 取消任何进行中的会话切换获取。
    _switchSerial++;
    _warmupSerial++;
    _selectionEpoch++;
    try {
      await _viewModel.flushCurrentConversationProgress();
    } catch (_) {}
    if (!isDesktopPlatform) {
      try {
        await _convoFadeController.reverse();
      } catch (_) {}
    }
    await _createNewConversation();
    if (!isDesktopPlatform) {
      try {
        await WidgetsBinding.instance.endOfFrame;
        await _convoFadeController.forward();
      } catch (_) {}
    }
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inputFocus.requestFocus();
      });
    }
  }

  Future<void> _createNewConversation() async {
    _translations.clear();
    final previousId = currentConversation?.id;
    await _viewModel.createNewConversation();
    if (currentConversation?.id != null &&
        currentConversation!.id != previousId) {
      _clearSelectionState();
    }
    notifyListeners();
    _scrollToBottomSoon(animate: false);
  }

  /// 在不通知的情况下清除选择界面。
  ///
  /// 递增选择纪元，使进行中的全选/切换/反选结果
  /// 不能写入下一个会话。
  void _clearSelectionState() {
    _selectionEpoch++;
    _selecting = false;
    _selectionMode = ChatSelectionMode.share;
    _selectedItems.clear();
    _selectableProjectionIds = null;
  }

  Future<void> clearContext() async {
    await _viewModel.clearContext();
    notifyListeners();
  }

  /// 压缩上下文：通过 LLM 生成摘要，创建新会话。
  /// 成功返回 null，失败返回错误字符串。
  Future<String?> compressContext({
    required CompressContextOptions options,
  }) async {
    final result = await _viewModel.compressContext(options: options);
    if (result == null) {
      // 成功 - 已切换到新会话
      _translations.clear();
      notifyListeners();
      _scrollToBottomSoon(animate: false);
    }
    return result;
  }

  // ============================================================================
  // 公共方法 - 消息操作
  // ============================================================================

  Future<void> deleteMessage({
    required ChatMessage message,
    required Map<String, List<ChatMessage>> byGroup,
  }) async {
    final keepAtBottom = _scrollCtrl.isNearBottom();
    final gid = (message.groupId ?? message.id);
    // 删除唯一版本会移除整个槽位；删除多个版本中的一个会在原位替换内容，
    // 这样在不使用移除动画时阅读体验更好。
    final slotDisappears = (byGroup[gid] ?? const <ChatMessage>[]).length <= 1;
    int? preserveRequest;
    if (slotDisappears && _shouldAnimateSlotRemoval(message)) {
      preserveRequest = await _playSlotRemovalAnimation(
        gid,
        keepAtBottom: keepAtBottom,
      );
    }
    _translations.remove(message.id);
    try {
      await _viewModel.deleteMessage(message: message, byGroup: byGroup);
    } finally {
      _settleAfterSlotRemoval(
        gid,
        conversationId: message.conversationId,
        keepAtBottom: keepAtBottom,
        preserveRequest: preserveRequest,
      );
    }
  }

  Future<void> deleteAllMessageVersions({
    required ChatMessage message,
    required Map<String, List<ChatMessage>> byGroup,
  }) async {
    final keepAtBottom = _scrollCtrl.isNearBottom();
    final gid = (message.groupId ?? message.id);
    int? preserveRequest;
    if (_shouldAnimateSlotRemoval(message)) {
      preserveRequest = await _playSlotRemovalAnimation(
        gid,
        keepAtBottom: keepAtBottom,
      );
    }
    for (final version in byGroup[gid] ?? const <ChatMessage>[]) {
      _translations.remove(version.id);
    }
    try {
      await _viewModel.deleteAllMessageVersions(
        message: message,
        byGroup: byGroup,
      );
    } finally {
      _settleAfterSlotRemoval(
        gid,
        conversationId: message.conversationId,
        keepAtBottom: keepAtBottom,
        preserveRequest: preserveRequest,
      );
    }
  }

  Future<void> deleteAllBranchSiblings(ChatMessage message) async {
    final keepAtBottom = _scrollCtrl.isNearBottom();
    final gid = (message.groupId ?? message.id);
    int? preserveRequest;
    if (_shouldAnimateSlotRemoval(message)) {
      preserveRequest = await _playSlotRemovalAnimation(
        gid,
        keepAtBottom: keepAtBottom,
      );
    }
    try {
      final deletedIds = await _viewModel.deleteBranchSiblings(message);
      for (final id in deletedIds) {
        _translations.remove(id);
      }
    } finally {
      _settleAfterSlotRemoval(
        gid,
        conversationId: message.conversationId,
        keepAtBottom: keepAtBottom,
        preserveRequest: preserveRequest,
      );
    }
  }

  /// 清除 [gid] 的移除动画状态并稳定滚动位置。
  ///
  /// 从 `finally` 运行：当删除本身失败时，槽位不能继续折叠在
  /// [_removingSlotIds] 中，且已武装的距离保持请求必须释放，
  /// 否则列表会不断弹回保留的偏移。当用户在删除中途
  /// 离开 [conversationId] 时，会跳过滚动调整，
  /// 因为此时调整会错误作用于新打开会话的列表。
  void _settleAfterSlotRemoval(
    String gid, {
    required String conversationId,
    required bool keepAtBottom,
    required int? preserveRequest,
  }) {
    _removingSlotIds.remove(gid);
    if (currentConversation?.id == conversationId) {
      if (keepAtBottom && preserveRequest == null) {
        _scrollCtrl.positionAtBottomOnNextLayout();
      }
      _finishPreserveDistanceAfterFrame(preserveRequest);
    }
    notifyListeners();
  }

  /// 移除 [message] 的槽位时是否应播放淡出折叠动画。
  ///
  /// 当平台要求减少动画时跳过；对于高于视口的槽位也跳过：
  /// 折叠铺满屏幕的消息会显得像剧烈滚动而不是拼接，
  /// 因此这些槽位会被立即移除，锚点恢复会让周围内容保持不动。
  bool _shouldAnimateSlotRemoval(ChatMessage message) {
    if (_removalAnimationsDisabled) return false;
    final index = _chatController.indexOfCollapsedMessageId(message.id);
    if (index < 0) return false;
    final listController = _scrollCtrl.messageListController;
    if (!listController.isAttached ||
        index >= listController.numberOfItems ||
        !_scrollController.hasClients) {
      return false;
    }
    final extent = listController.extentForIndex(index).$1;
    return extent <= _scrollController.position.viewportDimension;
  }

  /// 将 [slotId] 标记为正在移出并等待动画完成。
  ///
  /// 当时间线靠近底部时，折叠否则会逐帧把内容从尾部拖离，
  /// 因此整个动画期间滚动位置会与末尾保持距离；
  /// 删除应用后必须通过 [_finishPreserveDistanceAfterFrame]
  /// 释放返回的请求。
  Future<int?> _playSlotRemovalAnimation(
    String slotId, {
    required bool keepAtBottom,
  }) async {
    int? preserveRequest;
    final scrollController = _scrollController;
    if (keepAtBottom &&
        scrollController is scroll_ctrl.ChatAutoFollowScrollController) {
      preserveRequest = scrollController
          .requestPreserveDistanceFromEndDuringLayout();
    }
    _removingSlotIds.add(slotId);
    notifyListeners();
    // 额外留一帧余量，让折叠在槽位数据被移除前完成绘制。
    await Future.delayed(
      ChatLayoutConstants.slotRemovalAnimationDuration +
          const Duration(milliseconds: 16),
    );
    return preserveRequest;
  }

  void _finishPreserveDistanceAfterFrame(int? request) {
    if (request == null) return;
    final scrollController = _scrollController;
    if (scrollController is! scroll_ctrl.ChatAutoFollowScrollController) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scrollController.finishPreserveDistanceFromEndDuringLayout(request);
    });
  }

  bool get _removalAnimationsDisabled {
    final context = _context;
    if (!context.mounted) return true;
    return MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  Future<void> deleteSelectedMessages({required bool deleteAllVersions}) async {
    final selectedMessageIds = Set<String>.of(_selectedItems);
    if (selectedMessageIds.isEmpty) return;

    final keepAtBottom = _scrollCtrl.isNearBottom();
    // 在等待删除工作前使进行中的全选失效。
    _selectionEpoch++;
    final deletedMessageIds = await _selectedMessageIdsForDeletion(
      selectedMessageIds,
      deleteAllVersions: deleteAllVersions,
    );
    for (final id in deletedMessageIds) {
      _translations.remove(id);
    }
    await _viewModel.deleteMessages(
      messageIds: deleteAllVersions ? deletedMessageIds : selectedMessageIds,
      deleteAllVersions: deleteAllVersions,
    );
    _selecting = false;
    _selectedItems.clear();
    _selectableProjectionIds = null;
    if (keepAtBottom) _scrollCtrl.positionAtBottomOnNextLayout();
    notifyListeners();
  }

  Future<Set<String>> _selectedMessageIdsForDeletion(
    Set<String> selectedMessageIds, {
    required bool deleteAllVersions,
  }) async {
    if (!deleteAllVersions) return selectedMessageIds;

    final tree = _viewModel.conversationTree;
    if (tree == null) {
      // 仅兼容尚未加载树的旧导入/测试服务；正常会话始终走树路径。
      final conversation = currentConversation;
      if (conversation == null) return selectedMessageIds;
      final selected = await _chatService.loadMessagesByIds(
        selectedMessageIds.toList(growable: false),
      );
      final groupIds = selected
          .map((message) => message.groupId ?? message.id)
          .toSet();
      if (groupIds.isEmpty) return selectedMessageIds;
      return _chatService.loadMessageIdsForGroups(conversation.id, groupIds);
    }
    final result = <String>{};
    for (final messageId in selectedMessageIds) {
      final edge = tree.edges[messageId];
      if (edge == null) {
        result.add(messageId);
        continue;
      }
      result.addAll(tree.childrenOf(edge.parentMessageId));
    }
    return result.isEmpty ? selectedMessageIds : result;
  }

  Future<void> createMessageFork(ChatMessage message) async {
    if (currentConversation == null) return;
    if (!isDesktopPlatform) {
      await _convoFadeController.reverse();
    }

    await _viewModel.createMessageFork(message);
    notifyListeners();
    try {
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}
    _scrollToBottom(animate: false);
    if (!isDesktopPlatform) {
      await _convoFadeController.forward();
    }
  }

  Future<void> switchConversationBranch(String branchId) {
    return _viewModel.switchConversationBranch(branchId);
  }

  Future<List<ChatMessage>> loadAllConversationMessages() {
    final conversation = currentConversation;
    if (conversation == null) return Future.value(const <ChatMessage>[]);
    return _chatService.loadAllConversationMessages(conversation.id);
  }

  Future<void> ensureConversationTreeForCurrentConversation() {
    return _viewModel.ensureConversationTreeForCurrentConversation();
  }

  Future<void> editMessage(ChatMessage message) async {
    final inFlight = _editMessageInFlight;
    if (inFlight != null) return inFlight;

    late final Future<void> operation;
    operation = _editMessageInternal(message)
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            // 编辑入口由消息菜单以 VoidCallback 触发，不能把异步持久化异常
            // 留给 Flutter 根区处理，否则 Android release 可能直接退出。
            debugPrint('Message edit save failed: $error\n$stackTrace');
            if (_context.mounted) {
              final l10n = AppLocalizations.of(_context)!;
              showAppSnackBar(
                _context,
                message: l10n.backgroundTaskFailed(
                  l10n.messageEditPageTitle,
                  error.toString(),
                ),
                type: NotificationType.error,
              );
            }
          },
        )
        .whenComplete(() {
          if (identical(_editMessageInFlight, operation)) {
            _editMessageInFlight = null;
          }
        });
    _editMessageInFlight = operation;
    return operation;
  }

  Future<void> _editMessageInternal(ChatMessage message) async {
    final ctx = _context;
    if (!ctx.mounted) return;
    final isDesktop = isDesktopPlatform;
    final Future<MessageEditResult?> future = isDesktop
        ? showMessageEditDesktopDialog(ctx, message: message)
        : showMessageEditSheet(ctx, message: message);
    final MessageEditResult? result = await future;
    if (result == null) return;

    // 编辑正在生成中的会话时先完成取消和 checkpoint，避免编辑分支与
    // 流式终结同时写入会话树和消息部件。
    if (_chatController.isCurrentConversationLoading && ctx.mounted) {
      await _viewModel.cancelStreaming();
    }

    if (!ctx.mounted || currentConversation?.id != message.conversationId) {
      return;
    }

    if (currentConversation != null) {
      await _chatService.clearConversationSuggestions(currentConversation!.id);
      _viewModel.updateCurrentConversation(
        _chatService.getConversation(currentConversation!.id),
      );
    }

    final newMsg = await _chatService.appendMessageVersion(
      messageId: message.id,
      parts: result.parts,
    );
    if (newMsg == null) return;

    await _viewModel.refreshConversationTree(newMsg.conversationId);

    if (await _chatController.openAroundPersistedMessage(newMsg)) {
      _viewModel.restoreMessageUiState();
    }
    final existingBranchId = _viewModel.activeBranchId;
    notifyListeners();

    if (!result.shouldSend) return;
    if (message.role == 'assistant') {
      await regenerateAtMessage(
        newMsg,
        assistantAsNewReply: true,
        existingBranchId: existingBranchId,
      );
    } else if (message.role == 'user') {
      await regenerateAtMessage(newMsg, existingBranchId: existingBranchId);
    }
  }

  Future<void> switchMessageRole(ChatMessage message, String role) async {
    if (!await _chatService.switchMessageRole(message.id, role)) return;
    await _chatController.refreshTimelineAfterMutation();
    notifyListeners();
  }

  Future<void> translateMessage(ChatMessage message) async {
    final ctx = _scaffoldKey.currentContext ?? _context;
    final l10n = AppLocalizations.of(ctx)!;

    final result = await _translationService.translateMessage(
      message: message,
      onTranslationStarted: () {
        final loadingMessage = message.copyWith(
          translation: l10n.homePageTranslating,
        );
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = loadingMessage;
        }
        // 消息在外部被修改；使 ChatController 缓存失效，
        // 让折叠/分组视图立即反映更新。
        _chatController.invalidateCache();
        _translations[message.id] = TranslationData();
        notifyListeners();
      },
      onTranslationUpdate: (translation) {
        final updatingMessage = message.copyWith(translation: translation);
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = updatingMessage;
        }
        _chatController.invalidateCache();
        notifyListeners();
      },
      onTranslationCleared: () {
        final clearedMessage = message.copyWith(translation: '');
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = clearedMessage;
        }
        _chatController.invalidateCache();
        _translations.remove(message.id);
        notifyListeners();
      },
    );

    if (result.isCancelled) return;
    if (!ctx.mounted) return;

    if (result.type == TranslationResultType.noModelConfigured) {
      showAppSnackBar(
        ctx,
        message: l10n.homePagePleaseSetupTranslateModel,
        type: NotificationType.warning,
      );
      return;
    }

    if (result.type == TranslationResultType.error) {
      showAppSnackBar(
        ctx,
        message: l10n.homePageTranslateFailed(result.errorMessage ?? ''),
        type: NotificationType.error,
      );
    }
  }

  void _handleAssistantMessageFinished(ChatMessage message) {
    if (!_context.mounted || message.role != 'assistant') return;
    final settings = _context.read<SettingsProvider>();
    if (!settings.ttsAutoPlayAssistantReplies) return;
    unawaited(_speakAssistantMessage(message, autoPlay: true));
  }

  Future<void> speakMessage(ChatMessage message) async {
    await _speakAssistantMessage(message, autoPlay: false);
  }

  Future<void> _speakAssistantMessage(
    ChatMessage message, {
    required bool autoPlay,
  }) async {
    final tts = _context.read<TtsProvider>();
    if (!autoPlay && tts.playbackState.isActive) {
      await tts.stop();
      return;
    }

    if (PlatformUtils.isDesktopTarget) {
      final sp = _context.read<SettingsProvider>();
      final hasNetworkTts = sp.selectedTtsService != null;
      if (!hasNetworkTts && !tts.isAvailable) {
        showAppSnackBar(
          _context,
          message: AppLocalizations.of(_context)!.desktopTtsPleaseAddProvider,
          type: NotificationType.warning,
        );
        return;
      }
    }

    final sp = _context.read<SettingsProvider>();
    final text = TtsTextSelection.apply(
      message.content,
      mode: sp.ttsTextSelectionMode,
    );
    if (text.trim().isEmpty) return;
    await tts.speak(text);
  }

  void shareMessage(int messageIndex, List<ChatMessage> messageList) {
    startMessageSelection(
      messageIndex: messageIndex,
      messageList: messageList,
      mode: ChatSelectionMode.share,
    );
  }

  void startMessageSelection({
    required int messageIndex,
    required List<ChatMessage> messageList,
    required ChatSelectionMode mode,
  }) {
    dismissKeyboard();
    _selectionEpoch++;
    _selecting = true;
    _selectionMode = mode;
    _selectedItems.clear();
    _selectableProjectionIds = null;
    _showThinkingTools = false;
    _showThinkingContent = false;

    if (messageIndex < 0 || messageIndex >= messageList.length) {
      notifyListeners();
      return;
    }

    final anchor = messageList[messageIndex];
    const userRole = 'user';
    const assistantRole = 'assistant';

    int? findPrevRoleIndex(int start, String role) {
      for (int i = start; i >= 0; i--) {
        if (messageList[i].role == role) return i;
      }
      return null;
    }

    int? findNextRoleIndex(int start, String role) {
      for (int i = start; i < messageList.length; i++) {
        if (messageList[i].role == role) return i;
      }
      return null;
    }

    void addIfSelectable(int? index) {
      if (index == null) return;
      final m = messageList[index];
      if (m.role == userRole || m.role == assistantRole) {
        _selectedItems.add(m.id);
      }
    }

    if (anchor.role == assistantRole) {
      addIfSelectable(messageIndex);
      addIfSelectable(findPrevRoleIndex(messageIndex - 1, userRole));
    } else if (anchor.role == userRole) {
      addIfSelectable(messageIndex);
      addIfSelectable(findNextRoleIndex(messageIndex + 1, assistantRole));
    } else {
      addIfSelectable(findPrevRoleIndex(messageIndex, userRole));
      addIfSelectable(findNextRoleIndex(messageIndex, assistantRole));
    }

    if (_selectedItems.isEmpty &&
        (anchor.role == userRole || anchor.role == assistantRole)) {
      _selectedItems.add(anchor.id);
    }
    notifyListeners();
  }

  /// 当每个已知可选择的投影 ID 都被选中时为 true。
  ///
  /// 使用异步全投影选择操作填充的缓存。在该缓存存在前，
  /// 仅回退到已加载窗口。
  bool get allSelectableMessagesSelected {
    final cached = _selectableProjectionIds;
    if (cached != null) {
      return cached.isNotEmpty && cached.every(_selectedItems.contains);
    }
    final selectable = _chatController
        .allCollapsedMessagesForCurrentConversation()
        .where((m) => m.role == 'user' || m.role == 'assistant');
    return selectable.isNotEmpty &&
        selectable.every((m) => _selectedItems.contains(m.id));
  }

  /// 当所选组可能具有多个版本时为 true。
  ///
  /// 使用已加载的折叠窗口和 [ChatService.getMessagesForGroups]
  /// （由可见组预加载填充）。绝不会仅为渲染删除操作栏而遍历
  /// 完整会话顺序或 [getMessagesRange]。当组预加载不完整/未知时，
  /// 包括所选 ID 在已加载窗口之外，都会保守地返回 true，
  /// 使两个删除选项保持可用；最终删除仍使用异步数据库路径。
  bool get selectedMessagesIncludeMultipleVersions {
    final conversation = currentConversation;
    if (conversation == null || _selectedItems.isEmpty) return false;
    final groupIds = _selectedSelectionGroupIds();
    if (groupIds.isEmpty) return false;

    final loaded = _chatService.getMessagesForGroups(conversation.id, groupIds);
    final counts = <String, int>{};
    for (final message in loaded) {
      final groupId = message.groupId ?? message.id;
      counts.update(groupId, (value) => value + 1, ifAbsent: () => 1);
    }

    for (final groupId in groupIds) {
      final known = counts[groupId] ?? 0;
      if (known > 1) return true;
      // 预加载不完整：不要将未知状态视为单版本。
      if (known == 0) return true;
      for (final message in _chatController.collapsedMessages) {
        if ((message.groupId ?? message.id) != groupId) continue;
        if (message.version > 0 ||
            _chatController.versionSelections.containsKey(groupId)) {
          return true;
        }
      }
    }
    return false;
  }

  Set<String> _selectedSelectionGroupIds() {
    if (_selectedItems.isEmpty) return const <String>{};
    final windowMessages = _chatController
        .allCollapsedMessagesForCurrentConversation();
    final windowIds = {for (final message in windowMessages) message.id};
    // 窗口外的选择对版本化来说是未知的，因此给出合成组键，
    // 使调用方将其视为潜在的多版本。
    final groupIds = <String>{
      for (final message in windowMessages)
        if (_selectedItems.contains(message.id)) message.groupId ?? message.id,
    };
    for (final id in _selectedItems) {
      if (!windowIds.contains(id)) {
        groupIds.add(id);
      }
    }
    return groupIds;
  }

  void selectAll() {
    unawaited(_selectAllProjected());
  }

  Future<void> _selectAllProjected() async {
    final epoch = _selectionEpoch;
    final conversationId = currentConversation?.id;
    if (conversationId == null) return;
    final collapsed = await _chatController
        .loadAllCollapsedMessagesForCurrentConversation();
    if (!_selectionWriteStillValid(epoch, conversationId)) return;
    final selectable = <String>{};
    for (final m in collapsed) {
      if (m.role == 'user' || m.role == 'assistant') {
        selectable.add(m.id);
        _selectedItems.add(m.id);
      }
    }
    _selectableProjectionIds = selectable;
    notifyListeners();
  }

  void toggleSelectAll() {
    unawaited(_toggleSelectAllProjected());
  }

  Future<void> _toggleSelectAllProjected() async {
    final epoch = _selectionEpoch;
    final conversationId = currentConversation?.id;
    if (conversationId == null) return;
    final collapsed = await _chatController
        .loadAllCollapsedMessagesForCurrentConversation();
    if (!_selectionWriteStillValid(epoch, conversationId)) return;
    final selectable = collapsed
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .toList();
    if (selectable.isEmpty) return;

    _selectableProjectionIds = {for (final m in selectable) m.id};
    final allSelected = selectable.every((m) => _selectedItems.contains(m.id));
    if (allSelected) {
      for (final m in selectable) {
        _selectedItems.remove(m.id);
      }
    } else {
      for (final m in selectable) {
        _selectedItems.add(m.id);
      }
    }
    notifyListeners();
  }

  void invertSelection() {
    unawaited(_invertProjectedSelection());
  }

  Future<void> _invertProjectedSelection() async {
    final epoch = _selectionEpoch;
    final conversationId = currentConversation?.id;
    if (conversationId == null) return;
    final collapsed = await _chatController
        .loadAllCollapsedMessagesForCurrentConversation();
    if (!_selectionWriteStillValid(epoch, conversationId)) return;
    final selectable = <String>{};
    for (final m in collapsed) {
      if (m.role != 'user' && m.role != 'assistant') continue;
      selectable.add(m.id);
      if (_selectedItems.contains(m.id)) {
        _selectedItems.remove(m.id);
      } else {
        _selectedItems.add(m.id);
      }
    }
    _selectableProjectionIds = selectable;
    notifyListeners();
  }

  bool _selectionWriteStillValid(int epoch, String conversationId) {
    return _selecting &&
        epoch == _selectionEpoch &&
        currentConversation?.id == conversationId;
  }

  void toggleThinkingTools() {
    _showThinkingTools = !_showThinkingTools;
    if (!_showThinkingTools) _showThinkingContent = false;
    notifyListeners();
  }

  void toggleThinkingContent() {
    if (!_showThinkingTools) return;
    _showThinkingContent = !_showThinkingContent;
    notifyListeners();
  }

  Future<List<ChatMessage>> _selectedCollapsedMessages() async {
    final convo = currentConversation;
    if (convo == null) return const <ChatMessage>[];
    final projections = await _chatController
        .loadAllCollapsedMessagesForCurrentConversation();
    final ids = [
      for (final message in projections)
        if (_selectedItems.contains(message.id)) message.id,
    ];
    final storedMessages = await _chatService.loadMessagesByIds(ids);
    final storedById = {
      for (final message in storedMessages) message.id: message,
    };
    return [
      for (final id in ids)
        if (storedById[id] != null) storedById[id]!,
    ];
  }

  Future<void> exportSelectedAsMarkdown() async {
    final convo = currentConversation;
    if (convo == null) return;
    final context = _context;

    final selected = await _selectedCollapsedMessages();
    if (!context.mounted) return;
    if (selected.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.homePageSelectMessagesToShare,
        type: NotificationType.info,
      );
      return;
    }

    final showThinkingTools = _showThinkingTools;
    final showThinkingContent = _showThinkingContent;
    cancelSelection();
    await exportChatMessagesMarkdown(
      context,
      conversation: convo,
      messages: selected,
      showThinkingAndToolCards: showThinkingTools,
      expandThinkingContent: showThinkingContent,
    );
  }

  Future<void> exportSelectedAsTxt() async {
    final convo = currentConversation;
    if (convo == null) return;
    final context = _context;

    final selected = await _selectedCollapsedMessages();
    if (!context.mounted) return;
    if (selected.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.homePageSelectMessagesToShare,
        type: NotificationType.info,
      );
      return;
    }

    final showThinkingTools = _showThinkingTools;
    final showThinkingContent = _showThinkingContent;
    cancelSelection();
    await exportChatMessagesTxt(
      context,
      conversation: convo,
      messages: selected,
      showThinkingAndToolCards: showThinkingTools,
      expandThinkingContent: showThinkingContent,
    );
  }

  Future<void> exportSelectedAsImage() async {
    final convo = currentConversation;
    if (convo == null) return;
    final context = _context;

    final selected = await _selectedCollapsedMessages();
    if (!context.mounted) return;
    if (selected.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.homePageSelectMessagesToShare,
        type: NotificationType.info,
      );
      return;
    }

    final showThinkingTools = _showThinkingTools;
    final showThinkingContent = _showThinkingContent;
    cancelSelection();
    await exportChatMessagesImage(
      context,
      conversation: convo,
      messages: selected,
      showThinkingAndToolCards: showThinkingTools,
      expandThinkingContent: showThinkingContent,
    );
  }

  Future<void> confirmSelection() async {
    final convo = currentConversation;
    if (convo == null) return;
    final context = _context;
    final selected = await _selectedCollapsedMessages();
    if (!context.mounted) return;
    if (selected.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.homePageSelectMessagesToShare,
        type: NotificationType.info,
      );
      return;
    }
    _selectionEpoch++;
    _selecting = false;
    notifyListeners();
    await showChatExportSheet(
      context,
      conversation: convo,
      selectedMessages: selected,
    );
    _selectedItems.clear();
    _selectableProjectionIds = null;
    notifyListeners();
  }

  void cancelSelection() {
    _selectionEpoch++;
    _selecting = false;
    _selectionMode = ChatSelectionMode.share;
    _selectedItems.clear();
    _selectableProjectionIds = null;
    notifyListeners();
  }

  void toggleSelection(String messageId, bool selected) {
    if (selected) {
      _selectedItems.add(messageId);
    } else {
      _selectedItems.remove(messageId);
    }
    notifyListeners();
  }

  // ============================================================================
  // 公共方法 - 版本管理
  // ============================================================================

  Future<void> setSelectedVersion(String groupId, int version) async {
    await _chatController.setSelectedVersion(groupId, version);
    for (final message in _chatController.collapsedMessages) {
      if ((message.groupId ?? message.id) == groupId) {
        _restoreAssistantMessageUiState(message);
        break;
      }
    }
    notifyListeners();
  }

  List<ChatMessage> collapseVersions(List<ChatMessage> items) {
    return _chatController.collapseVersions(items);
  }

  // ============================================================================
  // 公共方法 - UI 状态
  // ============================================================================

  void toggleReasoning(String messageId) {
    final r = reasoning[messageId];
    if (r != null) {
      r.expanded = !r.expanded;
      // 检查推理是否仍在加载（finishedAt == null 表示流式处理中）
      // 这是 O(1) 操作，不需要遍历列表
      final isStillStreaming = r.finishedAt == null && r.text.isNotEmpty;
      if (isStillStreaming && streamingContentNotifier.hasNotifier(messageId)) {
        // 对正在流式处理的消息，使用轻量通知器更新
        streamingContentNotifier.forceRebuild(messageId);
      } else {
        // 对非流式消息，触发整页重建
        notifyListeners();
      }
    }
  }

  void toggleTranslation(String messageId) {
    final t = _translations[messageId];
    if (t != null) {
      t.expanded = !t.expanded;
      notifyListeners();
    }
  }

  void toggleReasoningSegment(String messageId, int segmentIndex) {
    final segments = reasoningSegments[messageId];
    if (segments != null && segmentIndex < segments.length) {
      final seg = segments[segmentIndex];
      seg.expanded = !seg.expanded;
      // 检查此片段是否仍在加载（finishedAt == null 表示流式处理中）
      // 这是 O(1) 操作，不需要遍历列表
      final isStillStreaming = seg.finishedAt == null && seg.text.isNotEmpty;
      if (isStillStreaming && streamingContentNotifier.hasNotifier(messageId)) {
        // 对正在流式处理的消息，使用轻量通知器更新
        streamingContentNotifier.forceRebuild(messageId);
      } else {
        // 对非流式消息，触发整页重建
        notifyListeners();
      }
    }
  }

  void setDragHovering(bool hovering) {
    _isDragHovering = hovering;
    notifyListeners();
  }

  // ============================================================================
  // 公共方法 - 侧边栏管理
  // ============================================================================

  void toggleTabletSidebar() {
    dismissKeyboard();
    try {
      if (_context.read<SettingsProvider>().hapticsOnDrawer) {
        Haptics.drawerPulse();
      }
    } catch (_) {}
    _tabletSidebarOpen = !_tabletSidebarOpen;
    notifyListeners();
    try {
      _context.read<SettingsProvider>().setDesktopSidebarOpen(
        _tabletSidebarOpen,
      );
    } catch (_) {}
  }

  void toggleRightSidebar() {
    dismissKeyboard();
    try {
      if (_context.read<SettingsProvider>().hapticsOnDrawer) {
        Haptics.drawerPulse();
      }
    } catch (_) {}
    _rightSidebarOpen = !_rightSidebarOpen;
    notifyListeners();
    try {
      _context.read<SettingsProvider>().setDesktopRightSidebarOpen(
        _rightSidebarOpen,
      );
    } catch (_) {}
  }

  void updateSidebarWidth(double dx) {
    _embeddedSidebarWidth = (_embeddedSidebarWidth + dx).clamp(
      _sidebarMinWidth,
      _sidebarMaxWidth,
    );
    notifyListeners();
  }

  void saveSidebarWidth() {
    try {
      _context.read<SettingsProvider>().setDesktopSidebarWidth(
        _embeddedSidebarWidth,
      );
    } catch (_) {}
  }

  void updateRightSidebarWidth(double dx) {
    _rightSidebarWidth = (_rightSidebarWidth - dx).clamp(
      _sidebarMinWidth,
      _sidebarMaxWidth,
    );
    notifyListeners();
  }

  void saveRightSidebarWidth() {
    try {
      _context.read<SettingsProvider>().setDesktopRightSidebarWidth(
        _rightSidebarWidth,
      );
    } catch (_) {}
  }

  // ============================================================================
  // 公共方法 - 抽屉
  // ============================================================================

  void onDrawerValueChanged(double value) {
    if (_lastDrawerValue <= 0.01 && value > 0.01) {
      dismissKeyboard();
    }
    if (_lastDrawerValue < 0.95 && value >= 0.95) {
      try {
        if (_context.read<SettingsProvider>().hapticsOnDrawer) {
          Haptics.drawerPulse();
        }
      } catch (_) {}
    }
    if (_lastDrawerValue > 0.05 && value <= 0.05) {
      try {
        if (_context.read<SettingsProvider>().hapticsOnDrawer) {
          Haptics.drawerPulse();
        }
      } catch (_) {}
    }
    _lastDrawerValue = value;
  }

  // ============================================================================
  // 公共方法 - 输入
  // ============================================================================

  void dismissKeyboard() {
    _inputFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
  }

  void measureInputBar() {
    try {
      final ctx = _inputBarKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) return;
      final h = box.size.height;
      if ((_inputBarHeight - h).abs() > 1.0) {
        _inputBarHeight = h;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ============================================================================
  // 公共方法 - 快捷短语
  // ============================================================================

  Future<void> handleQuickPhraseSelection(QuickPhrase? selected) async {
    if (selected == null) return;
    final text = _inputController.text;
    final selection = _inputController.selection;
    final start = (selection.start >= 0 && selection.start <= text.length)
        ? selection.start
        : text.length;
    final end =
        (selection.end >= 0 &&
            selection.end <= text.length &&
            selection.end >= start)
        ? selection.end
        : start;

    final newText = text.replaceRange(start, end, selected.content);
    _inputController.value = _inputController.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(
        offset: start + selected.content.length,
      ),
      composing: TextRange.empty,
    );
    notifyListeners();
  }

  // ============================================================================
  // 公共方法 - 文件上传
  // ============================================================================

  Future<void> onPickPhotos() => _fileUploadService.onPickPhotos();
  Future<void> onPickCamera() => _fileUploadService.onPickCamera(_context);
  Future<void> onPickFiles() => _fileUploadService.onPickFiles();
  Future<void> onFilesDroppedDesktop(List<XFile> files) =>
      _fileUploadService.onFilesDroppedDesktop(files);

  // ============================================================================
  // 公共方法 - 滚动
  // ============================================================================

  void scrollToBottom({bool animate = true}) =>
      _scrollToBottom(animate: animate);
  void forceScrollToBottomSoon({bool animate = true}) =>
      _scrollCtrl.forceScrollToBottomSoon(
        animate: animate,
        postSwitchDelay: _postSwitchScrollDelay,
      );

  Future<bool> loadMoreBefore() {
    _warmupSerial++;
    return _viewModel.loadMoreBefore();
  }

  Future<bool> loadMoreAfter() {
    _warmupSerial++;
    return _viewModel.loadMoreAfter();
  }

  List<ChatMessage> allCollapsedMessagesForCurrentConversation() =>
      _chatController.allCollapsedMessagesForCurrentConversation();

  Future<List<ChatMessage>> loadAllCollapsedMessagesForCurrentConversation() =>
      _chatController.loadAllCollapsedMessagesForCurrentConversation();

  // 问题 7 审计：仅通过折叠索引 + loadUntilMessageVisible 跳转。
  // 不调用 ChatService.getMessageIndex，因此在 loadTimelinePage
  // 回填期间缺少 message-order 骨架也不需要在此处保护。
  Future<void> scrollToMessageId(
    String targetId, {
    bool useRikkaTransition = false,
  }) async {
    _warmupSerial++;
    if (useRikkaTransition) {
      try {
        await _messageJumpTransitionController.reverse();
      } catch (_) {}
    }

    try {
      if (_chatController.indexOfCollapsedMessageId(targetId) < 0) {
        final loaded = await _viewModel.loadUntilMessageVisible(targetId);
        if (!loaded) return;
        try {
          await WidgetsBinding.instance.endOfFrame;
        } catch (_) {}
      }
      final index = _chatController.indexOfCollapsedMessageId(targetId);
      if (index < 0) return;
      await _scrollCtrl.scrollToMessageId(
        targetId: targetId,
        targetIndex: index,
      );
    } finally {
      if (useRikkaTransition) {
        try {
          await _messageJumpTransitionController.forward();
        } catch (_) {}
      }
    }
  }

  Future<void> jumpToPreviousQuestion() =>
      _jumpToAdjacentMessage(previous: true);

  Future<void> jumpToNextQuestion() => _jumpToAdjacentMessage(previous: false);

  Future<void> _jumpToAdjacentMessage({required bool previous}) async {
    final moved = await (previous
        ? _scrollCtrl.jumpToPreviousQuestion(
            messages: _chatController.collapsedMessages,
            indexOfId: (id) => _chatController.indexOfCollapsedMessageId(id),
          )
        : _scrollCtrl.jumpToNextQuestion(
            messages: _chatController.collapsedMessages,
            indexOfId: (id) => _chatController.indexOfCollapsedMessageId(id),
          ));
    if (!moved) {
      await _jumpToAdjacentMessageOutsideWindow(previous: previous);
    }
  }

  Future<void> _jumpToAdjacentMessageOutsideWindow({
    required bool previous,
  }) async {
    final window = _chatController.collapsedMessages;
    if (window.isEmpty) return;
    final boundaryId = previous ? window.first.id : window.last.id;
    final loaded = previous ? await loadMoreBefore() : await loadMoreAfter();
    if (!loaded) {
      if (previous) {
        await scrollToTop();
      } else {
        await forceScrollToBottom();
      }
      return;
    }
    try {
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}
    final updatedWindow = _chatController.collapsedMessages;
    final boundary = updatedWindow.indexWhere(
      (message) => message.id == boundaryId,
    );
    if (boundary < 0) return;
    final step = previous ? -1 : 1;
    final target = boundary + step;
    if (target >= 0 && target < updatedWindow.length) {
      await (previous
          ? _scrollCtrl.jumpToPreviousQuestion(
              messages: updatedWindow,
              indexOfId: (id) => _chatController.indexOfCollapsedMessageId(id),
            )
          : _scrollCtrl.jumpToNextQuestion(
              messages: updatedWindow,
              indexOfId: (id) => _chatController.indexOfCollapsedMessageId(id),
            ));
      return;
    }
    if (previous) {
      await scrollToTop();
    } else {
      await forceScrollToBottom();
    }
  }

  Future<void> scrollToTop({bool animate = true}) async {
    if (_chatController.hasMoreBefore) {
      final loaded = await _chatController.loadStartWindow();
      if (loaded) {
        _viewModel.restoreMessageUiState();
      }
    }
    _scrollCtrl.scrollToTop(animate: animate);
  }

  Future<void> forceScrollToBottom({bool animate = true}) async {
    final useJumpTransition = animate && _chatController.hasMoreAfter;
    if (useJumpTransition) {
      try {
        await _messageJumpTransitionController.reverse();
      } catch (_) {}
    }

    try {
      if (_chatController.hasMoreAfter) {
        final loaded = await _chatController.loadEndWindow();
        if (loaded) {
          _viewModel.restoreMessageUiState();
        }
      }
      if (useJumpTransition) {
        try {
          await WidgetsBinding.instance.endOfFrame;
        } catch (_) {}
        await _scrollCtrl.settleAtBottomBeforeReveal();
      } else {
        _scrollCtrl.forceScrollToBottom(animate: animate);
      }
    } finally {
      if (useJumpTransition) {
        try {
          await _messageJumpTransitionController.forward();
        } catch (_) {}
      }
    }
  }

  // ============================================================================
  // 公共方法 - 模型检查
  // ============================================================================

  bool isReasoningModel(String providerKey, String modelId) {
    return _generationController.isReasoningModel(providerKey, modelId);
  }

  bool isToolModel(String providerKey, String modelId) {
    return _generationController.isToolModel(providerKey, modelId);
  }

  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true;
    if (budget == -1) return true;
    return budget >= 1024;
  }

  // ============================================================================
  // 公共方法 - 辅助方法
  // ============================================================================

  String titleForLocale() => _titleForLocale(_context);

  String clearContextLabel() {
    final l10n = AppLocalizations.of(_context)!;
    return _viewModel.isContextMasked
        ? l10n.contextManagementRestoreContext
        : l10n.contextManagementMaskContext;
  }

  String? currentStreamingMessageId() {
    for (int i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == 'assistant' && m.isStreaming) return m.id;
    }
    return null;
  }

  bool shouldPinStreamingIndicator(String? messageId) {
    if (messageId == null) return false;
    if (_scrollCtrl.isUserScrolling) return false;
    if (!_scrollCtrl.hasEnoughContentToScroll(56.0)) return false;
    if (!_scrollCtrl.isNearBottom(48)) return false;
    return true;
  }

  /// 使用助手正则表达式转换原始内容。
  String transformAssistantContent(
    stream_ctrl.StreamingState state, [
    String? raw,
  ]) {
    return applyAssistantRegexes(
      raw ?? state.fullContentRaw,
      assistant: state.ctx.assistant,
      scope: AssistantRegexScope.assistant,
      target: AssistantRegexTransformTarget.persist,
    );
  }

  // ============================================================================
  // 生命周期管理
  // ============================================================================

  void onAppLifecycleStateChanged(AppLifecycleState state) {
    _appInForeground = (state == AppLifecycleState.resumed);
  }

  void onDidPopNext() {
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _inputFocus.requestFocus();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => dismissKeyboard());
    }
  }

  void onDidPushNext() {
    dismissKeyboard();
  }

  // ============================================================================
  // 私有方法
  // ============================================================================

  String _titleForLocale(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return l10n.titleForLocale;
  }

  void _scrollToBottom({bool animate = true}) =>
      _scrollCtrl.scrollToBottom(animate: animate);
  void _scrollToBottomSoon({bool animate = true}) =>
      _scrollCtrl.scrollToBottomSoon(animate: animate);

  // _getViewportBounds 已移除：索引列表会暴露其可见范围。

  void _restoreMessageUiState() {
    for (int i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == 'assistant') {
        _restoreAssistantMessageUiState(m);

        final cleanedContent = _streamController.captureGeminiThoughtSignature(
          m.content,
          m.id,
        );
        if (cleanedContent != m.content) {
          final updated = m.copyWith(content: cleanedContent);
          messages[i] = updated;
          unawaited(_chatService.updateMessage(m.id, content: cleanedContent));
        }

        _scheduleInlineImageSanitize(
          m.id,
          latestContent: messages[i].content,
          immediate: true,
        );
      }

      if (m.translation != null && m.translation!.isNotEmpty) {
        final td = TranslationData();
        td.expanded = false;
        _translations[m.id] = td;
      }
    }
  }

  void _restoreAssistantMessageUiState(ChatMessage message) {
    _streamController.restoreMessageUiState(
      message,
      getToolEventsFromDb: (id) => _chatService.getToolEvents(id),
      getGeminiThoughtSigFromDb: (id) =>
          _chatService.getGeminiThoughtSignature(id),
    );
  }

  void _scheduleInlineImageSanitize(
    String messageId, {
    String? latestContent,
    bool immediate = false,
  }) {
    final snapshot =
        latestContent ??
        (() {
          final idx = messages.indexWhere((m) => m.id == messageId);
          return idx == -1 ? '' : messages[idx].content;
        })();
    if (snapshot.isEmpty ||
        !snapshot.contains('data:image') ||
        !snapshot.contains('base64,')) {
      return;
    }

    _streamController.scheduleInlineImageSanitize(
      messageId,
      latestContent: snapshot,
      immediate: immediate,
      onSanitized: (id, sanitized) async {
        await _chatService.updateMessage(id, content: sanitized);
        final i = messages.indexWhere((m) => m.id == id);
        if (i != -1) {
          messages[i] = messages[i].copyWith(content: sanitized);
        }
        notifyListeners();
      },
    );
  }

  String _appendGeminiThoughtSignatureForApi(
    ChatMessage message,
    String content,
  ) {
    return _streamController.appendGeminiThoughtSignatureForApi(
      message,
      content,
    );
  }

  Future<void> _onMcpChanged() async {
    // 为可能的将来使用保留
  }

  // ============================================================================
  // 释放
  // ============================================================================

  @override
  void dispose() {
    _viewModel.onBackgroundTaskError = null;
    _ocrService.onError = null;
    _convoFadeController.dispose();
    _messageJumpTransitionController.dispose();
    _mcpProvider?.removeListener(_onMcpChanged);
    _scrollCtrl.dispose();
    _viewModel.dispose();
    try {
      _chatActionSub?.cancel();
    } catch (_) {}
    _chatController.dispose();
    _streamController.dispose();
    super.dispose();
  }
}
