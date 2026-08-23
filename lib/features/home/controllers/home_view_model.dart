import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/conversation_tree.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/services/memory/memory_pipeline.dart';
import '../../../core/services/memory/memory_trace.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/widgets/chat_message_widget.dart' show ToolUIPart;
import '../services/message_builder_service.dart';
import '../services/message_generation_service.dart';
import '../services/chat_suggestion_service.dart';
import 'chat_actions.dart';
import 'chat_controller.dart';
import 'generation_controller.dart';
import 'stream_controller.dart' as stream_ctrl;

enum CompressContextLimitMode { start, recent, unlimited }

enum BackgroundTaskKind { ocr, title, summary, suggestions, memory }

class CompressContextOptions {
  const CompressContextOptions({required this.mode, this.maxChars});

  static const int defaultMaxChars = 6000;

  final CompressContextLimitMode mode;
  final int? maxChars;
}

String buildCompressContextContent(
  String joined,
  CompressContextOptions options,
) {
  if (options.mode == CompressContextLimitMode.unlimited) return joined;
  final maxChars = options.maxChars ?? CompressContextOptions.defaultMaxChars;
  if (maxChars <= 0 || joined.length <= maxChars) return joined;
  return switch (options.mode) {
    CompressContextLimitMode.start => joined.substring(0, maxChars),
    CompressContextLimitMode.recent => joined.substring(
      joined.length - maxChars,
    ),
    CompressContextLimitMode.unlimited => joined,
  };
}

String buildConversationTextForCompression(List<ChatMessage> messages) {
  return messages
      .where((m) => m.content.trim().isNotEmpty)
      .map(
        (m) => '${m.role == "assistant" ? "Assistant" : "User"}: ${m.content}',
      )
      .join('\n\n');
}

class BatchDeleteGroupPlan {
  const BatchDeleteGroupPlan({
    required this.groupId,
    required this.versionsBefore,
    required this.deletedMessageIds,
    required this.nextVersionSelection,
  });

  final String groupId;
  final List<ChatMessage> versionsBefore;
  final Set<String> deletedMessageIds;
  final int? nextVersionSelection;
}

class BatchDeletePlan {
  const BatchDeletePlan({
    required this.groups,
    required this.nextVersionSelections,
    required this.clearedVersionSelectionGroupIds,
  });

  static const empty = BatchDeletePlan(
    groups: <String, BatchDeleteGroupPlan>{},
    nextVersionSelections: <String, int>{},
    clearedVersionSelectionGroupIds: <String>{},
  );

  final Map<String, BatchDeleteGroupPlan> groups;
  final Map<String, int> nextVersionSelections;
  final Set<String> clearedVersionSelectionGroupIds;

  bool get isEmpty => groups.isEmpty;

  Set<String> get deletedMessageIds => {
    for (final group in groups.values) ...group.deletedMessageIds,
  };
}

/// [HomeViewModel.prepareConversationSwitch] 的结果：
/// 调用方准备好后原子提交会话切换所需的一切。
class PreparedConversationSwitch {
  const PreparedConversationSwitch({
    required this.conversation,
    required this.window,
  });

  final Conversation conversation;
  final FetchedConversationWindow window;
}

/// 主页 ViewModel，组合操作和服务。
///
/// 此 ViewModel：
/// - 保存所有页面状态（会话、消息、加载状态等）
/// - 调用 ChatActions 执行业务操作
/// - 通过 ChangeNotifier 通知 UI 状态变化
/// - 处理会话切换/创建
///
/// UI 层只需要：
/// - 监听此 ViewModel
/// - 调用 sendMessage()、regenerate() 等简单方法
/// - 处理 UI 特定关注点（Snackbar、滚动、动画）
class HomeViewModel extends ChangeNotifier {
  HomeViewModel({
    required this._chatService,
    required this._messageBuilderService,
    required this._messageGenerationService,
    required this._generationController,
    required this._streamController,
    required this._chatController,
    required this._contextProvider,
    required this.getTitleForLocale,
  }) {
    // 初始化 ChatActions
    _chatActions = ChatActions(
      chatService: _chatService,
      chatController: _chatController,
      streamController: _streamController,
      generationController: _generationController,
      messageGenerationService: _messageGenerationService,
      contextProvider: _contextProvider,
      viewModel: this,
    );

    // 连接回调
    _chatActions.onMessagesChanged = _onMessagesChanged;
    _chatActions.onSendPairAppended = () => onScrollToBottom?.call();
    _chatActions.onLoadingChanged = _onLoadingChanged;
    _chatActions.onContentUpdated = _onContentUpdated;
    _chatActions.onStreamError = _onStreamError;
    _chatActions.onMaybeGenerateTitle = _onMaybeGenerateTitle;
    _chatActions.onMaybeGenerateSummary = _onMaybeGenerateSummary;
    _chatActions.onMaybeGenerateSuggestions = _onMaybeGenerateSuggestions;
    _chatActions.onStreamFinished = _onStreamFinished;
    _chatActions.onAssistantMessageFinished = _onAssistantMessageFinished;
    _chatActions.onFileProcessingStarted = _onFileProcessingStarted;
    _chatActions.onFileProcessingFinished = _onFileProcessingFinished;
  }

  // ============================================================================
  // 依赖
  // ============================================================================

  final ChatService _chatService;
  // ignore: unused_field - Reserved for future use (direct message building)
  final MessageBuilderService _messageBuilderService;
  // ignore: unused_field - Reserved for future use (direct generation control)
  final MessageGenerationService _messageGenerationService;
  final GenerationController _generationController;
  final stream_ctrl.StreamController _streamController;
  final ChatController _chatController;
  final BuildContext _contextProvider;
  final ChatSuggestionService _suggestionService =
      const ChatSuggestionService();
  late final ChatActions _chatActions;
  ConversationTree? _conversationTree;
  int _conversationTreeReloadSerial = 0;
  bool _disposed = false;
  QueuedChatInput? _queuedInput;
  bool _isDrainingQueuedInput = false;

  /// 获取本地化标题的函数
  final String Function(BuildContext context) getTitleForLocale;

  // ============================================================================
  // UI 回调（由 HomePage 设置）
  // ============================================================================

  /// 发生错误时调用（UI 应显示 Snackbar）。
  void Function(String error)? onError;

  /// 非阻塞后台模型任务失败时调用。
  void Function(BackgroundTaskKind task, Object error)? onBackgroundTaskError;

  /// 发生警告时调用（UI 应显示 Snackbar）。
  void Function(String warning)? onWarning;

  /// 流结束时调用（UI 可显示通知）。
  void Function(String conversationId)? onStreamFinished;

  /// 成功的助手回复最终化时调用。
  void Function(ChatMessage message)? onAssistantMessageFinished;

  /// 调用以安排行内图片清理。
  void Function(String messageId, String content, {bool immediate})?
  onScheduleImageSanitize;

  /// 需要滚动到底部时调用。
  VoidCallback? onScrollToBottom;

  /// 需要触感反馈时调用。
  VoidCallback? onHapticFeedback;

  /// 会话成功切换后调用（用于动画）。
  VoidCallback? onConversationSwitched;

  // ============================================================================
  // 状态 Getter（委托给 ChatController）
  // ============================================================================

  Conversation? get currentConversation => _chatController.currentConversation;
  ConversationTree? get conversationTree => _conversationTree;
  String? get activeBranchId => _conversationTree?.activeBranchId;
  List<ChatMessage> get messages {
    final raw = _chatController.messages;
    final tree = _conversationTree;
    if (tree == null) return raw;
    final activeIds = tree.activePath().toSet();
    return raw
        .where((message) => activeIds.contains(message.id))
        .toList(growable: false);
  }

  Map<String, int> get versionSelections => _chatController.versionSelections;
  Set<String> get loadingConversationIds => <String>{
    for (final id in _chatController.loadingConversationIds)
      if (!_chatActions.isStopping(id)) id,
  };

  /// 当前拥有 [conversationId] 的是发送/重新生成还是取消清理流程。
  bool isConversationSendInFlight(String conversationId) =>
      _chatActions.isSendInFlight(conversationId);
  Map<String, StreamSubscription<dynamic>> get conversationStreams =>
      _chatController.conversationStreams;

  /// StreamController 状态 Getter
  Map<String, stream_ctrl.ReasoningData> get reasoning =>
      _streamController.reasoning;
  Map<String, List<stream_ctrl.ReasoningSegmentData>> get reasoningSegments =>
      _streamController.reasoningSegments;
  Map<String, stream_ctrl.ContentSplitData> get contentSplits =>
      _streamController.contentSplits;
  Map<String, List<ToolUIPart>> get toolParts => _streamController.toolParts;

  /// 当前会话是否应显示生成中状态。
  bool get isCurrentConversationLoading {
    final cid = currentConversation?.id;
    if (cid == null) return false;
    return _chatController.isConversationLoading(cid) &&
        !_chatActions.isStopping(cid);
  }

  QueuedChatInput? get currentQueuedInput {
    final cid = currentConversation?.id;
    final queued = _queuedInput;
    if (cid == null || queued == null || queued.conversationId != cid) {
      return null;
    }
    return queued;
  }

  final ValueNotifier<bool> isProcessingFiles = ValueNotifier<bool>(false);

  // ============================================================================
  // 内部回调
  // ============================================================================

  void _onMessagesChanged() {
    if (_disposed) return;
    _chatController.invalidateCache();
    notifyListeners();
    final conversationId = currentConversation?.id;
    if (conversationId != null) {
      unawaited(_reloadConversationTree(conversationId));
    }
  }

  void _onLoadingChanged(String conversationId, bool loading) {
    notifyListeners();
    if (!loading) {
      unawaited(_drainQueuedInputIfReady(conversationId));
    }
  }

  void _onContentUpdated(String messageId, String content, int totalTokens) {
    final rawMessages = _chatController.messages;
    final index = rawMessages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      _chatController.replaceMessageSnapshot(
        rawMessages[index].copyWith(content: content, totalTokens: totalTokens),
      );
      // 注意：此处不要调用 notifyListeners()！
      // 流式内容更新现在由 StreamingContentNotifier 通过
      // ValueListenableBuilder 处理，只重建流式消息控件。
      // 在此调用 notifyListeners() 会触发整页重建并导致卡顿。
    }
  }

  void _onStreamError(String error) {
    onError?.call(error);
  }

  void _onMaybeGenerateTitle(String conversationId) {
    _runBackgroundTask(
      BackgroundTaskKind.title,
      _maybeGenerateTitleFor(conversationId),
    );
  }

  void _onMaybeGenerateSummary(String conversationId) {
    _runBackgroundTask(
      BackgroundTaskKind.summary,
      _maybeGenerateSummaryFor(conversationId),
    );
  }

  void _onMaybeGenerateSuggestions(String conversationId) {
    _runBackgroundTask(
      BackgroundTaskKind.suggestions,
      _maybeGenerateSuggestionsFor(conversationId),
    );
  }

  void _runBackgroundTask(BackgroundTaskKind task, Future<void> future) {
    unawaited(
      future.onError((error, stackTrace) {
        final reportedError = error ?? 'unknown error';
        FlutterLogger.log(
          '[BackgroundTask:$task] failed: $reportedError\n$stackTrace',
          tag: 'HomeViewModel',
        );
        onBackgroundTaskError?.call(task, reportedError);
      }),
    );
  }

  void _onStreamFinished(String conversationId) {
    onStreamFinished?.call(conversationId);
  }

  void _onAssistantMessageFinished(ChatMessage message) {
    onAssistantMessageFinished?.call(message);
    _onMaybeOrganizeMemory(message.conversationId);
  }

  /// 成功最终化后安排后台记忆整理（§12.1）。
  /// 从不等待；失败不得表现为聊天错误。
  void _onMaybeOrganizeMemory(String conversationId) {
    try {
      final settings = _contextProvider.read<SettingsProvider>();
      if (settings.legacyMemoryMode) return;
      final convo = _chatService.getConversation(conversationId);
      if (convo == null) return;
      final assistantProvider = _contextProvider.read<AssistantProvider>();
      final assistant = convo.assistantId != null
          ? assistantProvider.getById(convo.assistantId!)
          : assistantProvider.currentAssistant;
      if (assistant == null || !assistant.enableMemory) return;
      if (!assistant.autoOrganizeMemory) return;
      final pipeline = _contextProvider.read<MemoryPipelineService>();
      pipeline.scheduleIfNeeded(
        conversationId: conversationId,
        assistantId: assistant.id,
        onError: (error) =>
            onBackgroundTaskError?.call(BackgroundTaskKind.memory, error),
      );
    } catch (e, st) {
      FlutterLogger.log(
        '[MemoryPipeline] schedule failed: $e\n$st',
        tag: 'HomeViewModel',
      );
    }
  }

  void _onFileProcessingStarted() {
    isProcessingFiles.value = true;
  }

  void _onFileProcessingFinished() {
    isProcessingFiles.value = false;
  }

  // ============================================================================
  // 公共方法 - 消息操作
  // ============================================================================

  /// 发送新消息；如果当前会话忙则将其排队。
  Future<ChatInputSubmissionResult> sendMessage(ChatInputData input) async {
    final content = input.text.trim();
    if (content.isEmpty &&
        input.imagePaths.isEmpty &&
        input.documents.isEmpty) {
      return ChatInputSubmissionResult.rejected;
    }

    final conversation = currentConversation;
    if (conversation == null) {
      // 首先创建新会话
      await createNewConversation();
    }

    if (currentConversation == null) {
      onError?.call('no_conversation');
      return ChatInputSubmissionResult.rejected;
    }

    final activeConversation = currentConversation!;
    if (_chatController.isConversationLoading(activeConversation.id)) {
      if (_queuedInput != null) {
        return ChatInputSubmissionResult.rejected;
      }
      _queuedInput = QueuedChatInput(
        conversationId: activeConversation.id,
        input: _cloneInput(input),
      );
      notifyListeners();
      return ChatInputSubmissionResult.queued;
    }

    final success = await _sendMessageToConversation(input, activeConversation);
    return success
        ? ChatInputSubmissionResult.sent
        : ChatInputSubmissionResult.rejected;
  }

  ChatInputData? cancelCurrentQueuedInput() {
    final queued = currentQueuedInput;
    if (queued == null || _isDrainingQueuedInput) return null;
    _queuedInput = null;
    notifyListeners();
    return _cloneInput(queued.input);
  }

  Future<bool> _sendMessageToConversation(
    ChatInputData input,
    Conversation conversation,
  ) async {
    final content = input.text.trim();
    if (content.isEmpty &&
        input.imagePaths.isEmpty &&
        input.documents.isEmpty) {
      return false;
    }

    _chatActions.onScheduleImageSanitize = onScheduleImageSanitize;

    await _clearSuggestionsFor(conversation.id);

    if (input.documents.isNotEmpty) {
      isProcessingFiles.value = true;
    }

    onHapticFeedback?.call();

    final result = await _chatActions.sendMessage(
      input: input,
      conversation: conversation,
    );

    if (!result.success) {
      // 在任何提前返回前清除本次调用设置的标志；并发胜者只会在自己
      // 拥有文件时清除指示器，因此携带文档的失败方否则会泄漏它。
      if (input.documents.isNotEmpty) {
        isProcessingFiles.value = false;
      }
      // 并发发送已拥有此会话；它也拥有 UI 状态，
      // 因此失败方静默退出。
      if (result.errorMessage == 'in_flight') return false;
      if (result.errorMessage == 'no_model') {
        onWarning?.call('no_model');
      } else if (result.errorMessage != 'empty_input') {
        onError?.call(result.errorMessage ?? 'unknown_error');
      }
      return false;
    }

    return true;
  }

  ChatInputData _cloneInput(ChatInputData input) {
    return ChatInputData(
      text: input.text,
      imagePaths: List<String>.of(input.imagePaths),
      documents: List<DocumentAttachment>.of(input.documents),
      allowImagesApiRouting: input.allowImagesApiRouting,
    );
  }

  Future<void> _drainQueuedInputIfReady(String conversationId) async {
    if (_isDrainingQueuedInput) return;
    final queued = _queuedInput;
    final conversation = currentConversation;
    if (queued == null || conversation == null) return;
    if (queued.conversationId != conversationId ||
        conversation.id != conversationId) {
      return;
    }
    if (_chatController.isConversationLoading(conversationId)) return;

    _isDrainingQueuedInput = true;
    _queuedInput = null;
    notifyListeners();

    final input = queued.input;
    final success = await _sendMessageToConversation(input, conversation);
    if (!success) {
      _queuedInput = queued;
    }

    _isDrainingQueuedInput = false;
    notifyListeners();
  }

  /// 在指定消息处重新生成回复。
  Future<bool> regenerateAtMessage(
    ChatMessage message, {
    bool assistantAsNewReply = false,
    String? existingBranchId,
    bool allowImagesApiRouting = true,
  }) async {
    final conversation = currentConversation;
    if (conversation == null) {
      return false;
    }

    // 在重新生成前设置图片清理回调
    _chatActions.onScheduleImageSanitize = onScheduleImageSanitize;

    onHapticFeedback?.call();
    await _clearSuggestionsFor(conversation.id);

    final result = await _chatActions.regenerateAtMessage(
      message: message,
      conversation: conversation,
      assistantAsNewReply: assistantAsNewReply,
      existingBranchId: existingBranchId,
      allowImagesApiRouting: allowImagesApiRouting,
    );

    if (!result.success) {
      // 并发发送/重新生成已拥有此会话。
      if (result.errorMessage == 'in_flight') return false;
      if (result.errorMessage == 'no_model') {
        onWarning?.call('no_model');
      } else {
        onError?.call(result.errorMessage ?? 'unknown_error');
      }
      return false;
    }

    return true;
  }

  Future<bool> continueAssistantMessageAfterToolAnswer(
    ChatMessage message, {
    bool allowImagesApiRouting = true,
  }) async {
    final conversation = currentConversation;
    if (conversation == null) {
      return false;
    }

    _chatActions.onScheduleImageSanitize = onScheduleImageSanitize;
    await _clearSuggestionsFor(conversation.id);

    final result = await _chatActions.continueAssistantMessageAfterToolAnswer(
      message: message,
      conversation: conversation,
      allowImagesApiRouting: allowImagesApiRouting,
    );

    if (!result.success) {
      if (result.errorMessage == 'in_flight') return false;
      if (result.errorMessage == 'no_model') {
        onWarning?.call('no_model');
      } else {
        onError?.call(result.errorMessage ?? 'unknown_error');
      }
      return false;
    }

    return true;
  }

  /// 取消活动流式处理。
  Future<void> cancelStreaming() async {
    await _chatActions.cancelStreaming(currentConversation);
  }

  /// 删除消息并调整版本选择。
  ///
  /// 返回需要清理 UI 状态的消息 ID 列表。
  /// UI 层应在调用此方法前处理确认对话框。
  Future<void> deleteMessage({
    required ChatMessage message,
    required Map<String, List<ChatMessage>> byGroup,
  }) async {
    await deleteMessages(messageIds: {message.id});
  }

  Future<void> deleteAllMessageVersions({
    required ChatMessage message,
    required Map<String, List<ChatMessage>> byGroup,
  }) async {
    await deleteBranchSiblings(message);
  }

  Future<Set<String>> deleteBranchSiblings(ChatMessage message) async {
    final targetConversationId = message.conversationId;
    final streamingMessageId = _chatActions.activeStreamingMessageId(
      targetConversationId,
    );
    if (streamingMessageId != null) {
      await _chatActions.cancelStreaming(
        _chatService.getConversation(targetConversationId),
      );
    }
    final deletedIds = await _chatService.deleteBranchSiblings(
      conversationId: targetConversationId,
      messageId: message.id,
    );
    for (final id in deletedIds) {
      _streamController.clearMessageState(id);
    }

    if (targetConversationId == currentConversation?.id) {
      _conversationTreeReloadSerial++;
      _conversationTree = await _chatService.loadConversationTree(
        targetConversationId,
      );
      _chatController.updateCurrentConversation(
        _chatService.getConversation(targetConversationId),
      );
      await _chatController.refreshTimelineAfterMutation(
        removedRevisionIds: deletedIds,
        survivingVersionsByGroup: const <String, List<ChatMessage>>{},
      );
    }
    notifyListeners();
    return deletedIds;
  }

  @visibleForTesting
  static int? computeNextVersionSelection({
    required List<ChatMessage> versionsBefore,
    required Set<String> deletedMessageIds,
    required int? oldSelection,
  }) {
    final sorted = List<ChatMessage>.of(versionsBefore)
      ..sort((a, b) => a.version.compareTo(b.version));
    if (sorted.isEmpty) return null;

    final remainingVersions =
        sorted
            .where((message) => !deletedMessageIds.contains(message.id))
            .map((message) => message.version)
            .toSet()
            .toList()
          ..sort();
    if (remainingVersions.isEmpty) return null;

    final newSelection = oldSelection ?? sorted.last.version;
    final selectedVersionWasDeleted = sorted.any(
      (message) =>
          deletedMessageIds.contains(message.id) &&
          message.version == newSelection,
    );
    if (!selectedVersionWasDeleted) return newSelection;

    for (final version in remainingVersions.reversed) {
      if (version < newSelection) return version;
    }
    return remainingVersions.first;
  }

  @visibleForTesting
  static BatchDeletePlan buildBatchDeletePlan({
    required List<ChatMessage> messages,
    required Set<String> selectedMessageIds,
    required Map<String, int> versionSelections,
    bool deleteAllVersions = false,
  }) {
    if (selectedMessageIds.isEmpty || messages.isEmpty) {
      return BatchDeletePlan.empty;
    }

    final byGroup = <String, List<ChatMessage>>{};
    final deletedByGroup = <String, Set<String>>{};
    for (final message in messages) {
      final groupId = message.groupId ?? message.id;
      byGroup.putIfAbsent(groupId, () => <ChatMessage>[]).add(message);
      if (selectedMessageIds.contains(message.id)) {
        deletedByGroup.putIfAbsent(groupId, () => <String>{});
        if (!deleteAllVersions) {
          deletedByGroup[groupId]!.add(message.id);
        }
      }
    }

    if (deletedByGroup.isEmpty) return BatchDeletePlan.empty;

    final groups = <String, BatchDeleteGroupPlan>{};
    final nextVersionSelections = <String, int>{};
    final clearedVersionSelectionGroupIds = <String>{};

    for (final entry in deletedByGroup.entries) {
      final groupId = entry.key;
      final versionsBefore = List<ChatMessage>.of(
        byGroup[groupId] ?? const <ChatMessage>[],
      )..sort((a, b) => a.version.compareTo(b.version));
      final deletedMessageIds = deleteAllVersions
          ? versionsBefore.map((message) => message.id).toSet()
          : Set<String>.of(entry.value);
      final oldSelection =
          versionSelections[groupId] ??
          (versionsBefore.isNotEmpty ? versionsBefore.last.version : 0);
      final nextVersionSelection = computeNextVersionSelection(
        versionsBefore: versionsBefore,
        deletedMessageIds: deletedMessageIds,
        oldSelection: oldSelection,
      );

      groups[groupId] = BatchDeleteGroupPlan(
        groupId: groupId,
        versionsBefore: versionsBefore,
        deletedMessageIds: deletedMessageIds,
        nextVersionSelection: nextVersionSelection,
      );

      if (nextVersionSelection == null) {
        clearedVersionSelectionGroupIds.add(groupId);
      } else {
        nextVersionSelections[groupId] = nextVersionSelection;
      }
    }

    return BatchDeletePlan(
      groups: groups,
      nextVersionSelections: nextVersionSelections,
      clearedVersionSelectionGroupIds: clearedVersionSelectionGroupIds,
    );
  }

  Future<void> deleteMessages({
    required Set<String> messageIds,
    bool deleteAllVersions = false,
  }) async {
    if (messageIds.isEmpty) return;

    final selected = await _chatService.loadMessagesByIds(
      messageIds.toList(growable: false),
    );
    if (selected.isEmpty) return;
    // 确认对话框和投影加载在此之前运行，因此用户在选择后
    // 可能已切换会话。已加载修订知道自己属于哪个会话；
    // 对当前会话执行删除会静默地不生效。
    final conversationId = selected.first.conversationId;
    bool isCurrentConversation() => currentConversation?.id == conversationId;
    final deletedCandidates = messageIds;

    // 删除活动生成写入检查点的行会使下一次流式写入命中
    // 已删除消息上的外键；因此先停止生成。
    final streamingMessageId = _chatActions.activeStreamingMessageId(
      conversationId,
    );
    if (streamingMessageId != null &&
        deletedCandidates.contains(streamingMessageId)) {
      await _chatActions.cancelStreaming(
        _chatService.getConversation(conversationId),
      );
    }

    final deletedMessageIds = await _chatService.deleteMessages(
      conversationId: conversationId,
      messageIds: deletedCandidates,
      versionSelectionChanges: const <String, int?>{},
    );
    for (final id in deletedMessageIds) {
      _streamController.clearMessageState(id);
    }
    if (isCurrentConversation()) {
      _chatController.loadVersionSelections();
      _chatController.updateCurrentConversation(
        _chatService.getConversation(conversationId),
      );
      _conversationTreeReloadSerial++;
      _conversationTree = await _chatService.loadConversationTree(
        conversationId,
      );

      await _chatController.refreshTimelineAfterMutation(
        removedRevisionIds: deletedMessageIds,
      );
    }
    notifyListeners();
  }

  // ============================================================================
  // 公共方法 - 会话管理
  // ============================================================================

  /// 切换到已有会话。
  ///
  /// 调用方在调用此方法前会刷新当前会话进度；
  /// 此处不要再次刷新。
  Future<void> switchConversation(String id) async {
    final assistantProvider = _contextProvider.read<AssistantProvider>();

    // 切换时重置处理状态
    isProcessingFiles.value = false;

    if (currentConversation?.id == id) return;

    _chatService.setCurrentConversation(id);
    final convo = _chatService.getConversation(id);
    if (convo != null) {
      // 助手偏好持久化与窗口加载并发运行；
      // setCurrentAssistant 会在磁盘写入完成前通知。
      final assistantSwitch = _assistantSwitchFor(
        assistantProvider,
        convo.assistantId,
      );
      await Future.wait([
        _chatController.setCurrentConversationAndLoad(convo),
        if (assistantSwitch != null) assistantSwitch,
      ]);
      _conversationTreeReloadSerial++;
      _conversationTree = null;
      await _reloadConversationTree(id);
      _streamController.clearGeminiThoughtSigs();
      // 在监听器用上一个会话的滚动偏移绘制前，
      // 预先设定新列表的初始位置。
      onConversationSwitched?.call();
      notifyListeners();
      unawaited(_drainQueuedInputIfReady(id));
    }
  }

  /// 动画会话切换的获取阶段：加载目标会话的初始窗口，
  /// 但不提交任何状态，使调用方可以保持先前列表被覆盖，
  /// 直到准备通过 [commitConversationSwitch] 提交。
  /// 当切换为无操作或会话已不存在时返回 null。
  Future<PreparedConversationSwitch?> prepareConversationSwitch(
    String id,
  ) async {
    // 切换时重置处理状态
    isProcessingFiles.value = false;

    if (currentConversation?.id == id) return null;

    final convo = _chatService.getConversation(id);
    if (convo == null) return null;

    // 助手切换被延迟到 commitConversationSwitch：它会通知监听器
    // 并重写全局 currentAssistantId，因此在此运行会在准备被取代
    // 并在提交前丢弃时泄漏副作用。
    final window = await _chatController.fetchConversationWindow(convo);
    return PreparedConversationSwitch(conversation: convo, window: window);
  }

  /// 动画会话切换的提交阶段：安装此前由
  /// [prepareConversationSwitch] 获取的快照。
  void commitConversationSwitch(PreparedConversationSwitch prepared) {
    final id = prepared.conversation.id;
    _chatService.setCurrentConversation(id);
    _chatController.commitConversationWindow(
      prepared.window,
      onDeferredGroupDataLoaded: notifyListeners,
    );
    // 与 switchConversation 相同的并发情况：助手变化会在其磁盘写入
    // 完成前通知。
    final assistantProvider = _contextProvider.read<AssistantProvider>();
    final assistantSwitch = _assistantSwitchFor(
      assistantProvider,
      prepared.conversation.assistantId,
    );
    if (assistantSwitch != null) unawaited(assistantSwitch);
    _streamController.clearGeminiThoughtSigs();
    _conversationTreeReloadSerial++;
    _conversationTree = null;
    unawaited(_reloadConversationTree(id));
    // 在监听器用上一个会话的滚动偏移绘制前，
    // 预先设定新列表的初始位置。
    onConversationSwitched?.call();
    notifyListeners();
    unawaited(_drainQueuedInputIfReady(id));
  }

  Future<void> _reloadConversationTree(String conversationId) async {
    if (_disposed) return;
    final serial = ++_conversationTreeReloadSerial;
    try {
      await _chatService.ensureConversationTree(conversationId);
      final tree = await _chatService.loadConversationTree(conversationId);
      if (_disposed ||
          serial != _conversationTreeReloadSerial ||
          currentConversation?.id != conversationId) {
        return;
      }
      _conversationTree = tree;
      notifyListeners();
    } catch (error, stackTrace) {
      if (_disposed) return;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void installConversationTree(ConversationTree tree) {
    if (currentConversation?.id != tree.conversationId) return;
    _conversationTreeReloadSerial++;
    _conversationTree = tree;
    _chatController.invalidateCache();
    notifyListeners();
  }

  Future<void> refreshConversationTree(String conversationId) async {
    if (_disposed) return;
    final tree = await _chatService.loadConversationTree(conversationId);
    if (tree != null) installConversationTree(tree);
  }

  Future<void> ensureConversationTreeForCurrentConversation() async {
    if (_disposed) return;
    final conversation = currentConversation;
    if (conversation == null) return;
    await _chatService.ensureConversationTree(conversation.id);
    final tree = await _chatService.loadConversationTree(conversation.id);
    if (tree != null) installConversationTree(tree);
  }

  /// 开始持久化切换所需的助手偏好；当助手不变时为 null。
  Future<void>? _assistantSwitchFor(
    AssistantProvider assistantProvider,
    String? convoAssistantId,
  ) {
    if (convoAssistantId == null ||
        assistantProvider.currentAssistantId == convoAssistantId ||
        assistantProvider.getById(convoAssistantId) == null) {
      return null;
    }
    return assistantProvider.setCurrentAssistant(convoAssistantId);
  }

  /// 创建新会话。
  Future<void> createNewConversation() async {
    // 创建新会话前刷新当前会话进度
    await _chatActions.flushConversationProgress(currentConversation);
    if (!_contextProvider.mounted) return;

    // 创建时重置处理状态
    isProcessingFiles.value = false;

    final ap = _contextProvider.read<AssistantProvider>();
    try {
      await ap.loaded;
    } catch (e) {
      onError?.call(e.toString());
      return;
    }
    if (!_contextProvider.mounted) return;
    final assistantId = ap.currentAssistantId;
    final a = ap.currentAssistant;

    final conversation = await _chatService.createDraftConversation(
      title: getTitleForLocale(_contextProvider),
      assistantId: assistantId,
    );

    _chatController.setDraftConversation(conversation);
    _streamController.clearAllState();
    notifyListeners();

    // 将助手预设消息注入新会话（按顺序）
    try {
      final presets = ap.getPresetMessagesForAssistant(a?.id);
      if (presets.isNotEmpty && currentConversation != null) {
        final injected = <ChatMessage>[];
        for (final pm in presets) {
          final role = (pm['role'] == 'assistant') ? 'assistant' : 'user';
          final content = (pm['content'] ?? '').trim();
          if (content.isEmpty) continue;
          injected.add(
            await _chatService.addMessage(
              conversationId: currentConversation!.id,
              role: role,
              content: content,
            ),
          );
        }
        // 一次批量追加会以单次 notify 发布整个预设块，
        // 而不是逐条消息通知。
        if (injected.isNotEmpty) {
          await _chatController.appendPersistedTailMessages(injected);
        }
      }
    } catch (_) {}

    onScrollToBottom?.call();
  }

  Future<void> toggleTemporaryConversation() async {
    final convo = currentConversation;
    if (convo == null || messages.isNotEmpty) return;

    await _chatActions.flushConversationProgress(currentConversation);
    if (!_contextProvider.mounted) return;

    isProcessingFiles.value = false;

    if (_chatService.isTemporaryConversation(convo.id)) {
      await createNewConversation();
      return;
    }

    final ap = _contextProvider.read<AssistantProvider>();
    try {
      await ap.loaded;
    } catch (e) {
      onError?.call(e.toString());
      return;
    }
    if (!_contextProvider.mounted) return;
    final conversation = await _chatService.createDraftConversation(
      title: AppLocalizations.of(_contextProvider)!.temporaryChatTitle,
      assistantId: ap.currentAssistantId,
      temporary: true,
    );

    _chatController.setDraftConversation(conversation);
    _streamController.clearAllState();
    notifyListeners();
    onScrollToBottom?.call();
  }

  /// 在当前会话树中从指定消息创建消息分支。
  Future<void> createMessageFork(ChatMessage message) async {
    final sourceConversation = currentConversation;
    if (sourceConversation == null) return;
    final tree = await _chatService.createMessageBranch(
      conversationId: sourceConversation.id,
      fromMessageId: message.id,
    );
    _conversationTreeReloadSerial++;
    _conversationTree = tree;
    _chatController.invalidateCache();
    notifyListeners();
    onScrollToBottom?.call();
  }

  Future<void> switchConversationBranch(String branchId) async {
    final sourceConversation = currentConversation;
    if (sourceConversation == null) return;
    final tree = await _chatService.switchConversationBranch(
      conversationId: sourceConversation.id,
      branchId: branchId,
    );
    if (tree == null) return;
    _conversationTreeReloadSerial++;
    _conversationTree = tree;
    _chatController.invalidateCache();
    final branch = tree.branches[branchId];
    final tipMessageId = branch?.tipMessageId;
    if (tipMessageId != null) {
      await _chatController.loadWindowAroundMessage(tipMessageId);
    } else {
      await _chatController.loadStartWindow();
    }
    if (currentConversation?.id != sourceConversation.id) return;
    notifyListeners();
    onScrollToBottom?.call();
  }

  /// 清除上下文（在尾部切换截断）。
  Future<void> clearContext() async {
    final convo = currentConversation;
    if (convo == null) return;

    final defaultTitle = getTitleForLocale(_contextProvider);
    await _clearSuggestionsFor(convo.id);
    final updated = await _chatService.toggleTruncateAtTail(
      convo.id,
      defaultTitle: defaultTitle,
    );
    if (updated != null) {
      _chatController.updateCurrentConversation(updated);
      notifyListeners();
    }
  }

  /// 压缩上下文：通过 LLM 摘要消息，并使用摘要创建新会话。
  /// 成功返回 null，失败返回错误键字符串。
  Future<String?> compressContext({
    required CompressContextOptions options,
  }) async {
    final convo = currentConversation;
    if (convo == null) return 'no_conversation';

    final locale = Localizations.localeOf(_contextProvider).toLanguageTag();
    final settings = _contextProvider.read<SettingsProvider>();
    final ap = _contextProvider.read<AssistantProvider>();
    final assistant = convo.assistantId != null
        ? ap.getById(convo.assistantId!)
        : ap.currentAssistant;

    // 当前上下文由消息树活动路径定义。
    final activeMessages = await _chatController
        .allMessagesForCurrentConversationContext();
    if (activeMessages.isEmpty) return 'no_messages';

    // 构建用于压缩的会话文本
    final joined = buildConversationTextForCompression(activeMessages);
    if (joined.trim().isEmpty) return 'no_messages';

    final content = buildCompressContextContent(joined, options);
    // 解析模型：压缩模型 → 摘要模型 → 标题模型 → 助手模型 → 全局默认
    final provKey =
        settings.compressModelProvider ??
        settings.summaryModelProvider ??
        settings.titleModelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider;
    final mdlId =
        settings.compressModelId ??
        settings.summaryModelId ??
        settings.titleModelId ??
        assistant?.chatModelId ??
        settings.currentModelId;
    if (provKey == null || mdlId == null) return 'no_model';

    final cfg = settings.getProviderConfig(provKey);
    final budget = settings.compressGenerationThinkingBudgetFor(
      assistant?.thinkingBudget,
    );

    // 根据设置模板构建压缩提示词
    final prompt = settings.compressPrompt
        .replaceAll('{content}', content)
        .replaceAll('{locale}', locale);

    try {
      final summary = (await ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: budget,
      )).trim();

      if (summary.isEmpty) return 'empty_summary';

      // 以摘要作为第一条用户消息创建新会话
      final newConvo = await _chatService.createDraftConversation(
        title: convo.title,
        assistantId: convo.assistantId,
      );

      await _chatService.addMessage(
        conversationId: newConvo.id,
        role: 'user',
        content: summary,
      );

      // 切换到新会话
      _chatService.setCurrentConversation(newConvo.id);
      await _chatController.setCurrentConversationAndLoad(
        _chatService.getConversation(newConvo.id) ?? newConvo,
      );
      _streamController.clearAllState();
      onConversationSwitched?.call();
      notifyListeners();
      onScrollToBottom?.call();

      return null; // 成功
    } catch (e) {
      return e.toString();
    }
  }

  /// 更新当前会话引用。
  void updateCurrentConversation(Conversation? conversation) {
    _chatController.updateCurrentConversation(conversation);
    notifyListeners();
  }

  Future<bool> loadMoreBefore() async {
    final loaded = await _chatController.loadMoreBefore();
    if (!loaded) return false;
    _restoreMessageUiState();
    notifyListeners();
    return true;
  }

  Future<bool> loadMoreAfter() async {
    final loaded = await _chatController.loadMoreAfter();
    if (!loaded) return false;
    _restoreMessageUiState();
    notifyListeners();
    return true;
  }

  Future<bool> loadUntilMessageVisible(String messageId) async {
    final loaded = await _chatController.loadUntilMessageVisible(messageId);
    if (!loaded) return false;
    _restoreMessageUiState();
    notifyListeners();
    return true;
  }

  /// 设置消息组的已选版本。
  Future<void> setSelectedVersion(String groupId, int version) async {
    final cid = currentConversation?.id;
    if (cid != null) {
      await _clearSuggestionsFor(cid);
    }
    await _chatController.setSelectedVersion(groupId, version);
    notifyListeners();
  }

  // ============================================================================
  // 公共方法 - UI 状态
  // ============================================================================

  /// 切换会话后恢复逐消息 UI 状态。
  void restoreMessageUiState() {
    _restoreMessageUiState();
    notifyListeners();
  }

  void _restoreMessageUiState() {
    for (int i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == 'assistant') {
        _streamController.restoreMessageUiState(
          m,
          getToolEventsFromDb: (id) => _chatService.getToolEvents(id),
          getGeminiThoughtSigFromDb: (id) =>
              _chatService.getGeminiThoughtSignature(id),
        );

        // 从 Gemini 思考签名中清理内容
        final cleanedContent = _streamController.captureGeminiThoughtSignature(
          m.content,
          m.id,
        );
        if (cleanedContent != m.content) {
          final updated = m.copyWith(content: cleanedContent);
          _chatController.replaceMessageSnapshot(updated);
          unawaited(_chatService.updateMessage(m.id, content: cleanedContent));
        }

        // 清理此前运行中持久化的所有行内 base64 图片
        onScheduleImageSanitize?.call(
          m.id,
          messages[i].content,
          immediate: true,
        );
      }
    }
  }

  /// 将推理片段序列化为 JSON 字符串。
  String serializeReasoningSegments(
    List<stream_ctrl.ReasoningSegmentData> segments,
  ) {
    return _streamController.serializeReasoningSegments(segments);
  }

  /// 折叠消息版本，每组只显示已选版本。
  List<ChatMessage> collapseVersions(List<ChatMessage> items) {
    return _chatController.collapseVersions(items);
  }

  /// 按 groupId 对消息分组。
  Map<String, List<ChatMessage>> groupMessagesByGroup() {
    return _chatController.groupMessagesByGroup();
  }

  /// 根据当前状态获取清除上下文标签。
  String getClearContextLabel(
    String Function(String, String) withCountFormatter,
    String defaultLabel,
  ) {
    final assistant = _contextProvider
        .read<AssistantProvider>()
        .currentAssistant;
    final configured = (assistant?.limitContextMessages ?? false)
        ? (assistant?.contextMessageSize ?? 0)
        : 0;
    // 时间线总数和 truncateIndex 都使用逻辑消息槽位。
    final remaining = computeClearContextRemainingMessageCount(
      totalMessages: _chatController.totalMessageCount,
      truncateIndex: currentConversation == null
          ? -1
          : _chatService.getContextStartIndex(currentConversation!.id),
    );
    if (configured > 0) {
      final actual = remaining > configured ? configured : remaining;
      return withCountFormatter(actual.toString(), configured.toString());
    }
    return defaultLabel;
  }

  bool get isContextMasked {
    final conversationId = currentConversation?.id;
    if (conversationId == null) return false;
    return _chatService.getContextStartIndex(conversationId) >= 0;
  }

  /// [_maybeGenerateSummaryFor] 的测试入口。
  @visibleForTesting
  Future<void> debugMaybeGenerateSummaryFor(String conversationId) =>
      _maybeGenerateSummaryFor(conversationId);

  @visibleForTesting
  static int computeClearContextRemainingMessageCount({
    required int totalMessages,
    required int truncateIndex,
  }) {
    final safeTruncateIndex =
        (truncateIndex < 0 || truncateIndex > totalMessages)
        ? 0
        : truncateIndex;
    return totalMessages - safeTruncateIndex;
  }

  // ============================================================================
  // 标题生成
  // ============================================================================

  /// 需要时为会话生成标题。
  Future<void> _maybeGenerateTitleFor(
    String conversationId, {
    bool force = false,
  }) async {
    final convo = _chatService.getConversation(conversationId);
    if (convo == null) return;
    if (!force &&
        convo.title.isNotEmpty &&
        convo.title != getTitleForLocale(_contextProvider)) {
      return;
    }

    final settings = _contextProvider.read<SettingsProvider>();
    final assistantProvider = _contextProvider.read<AssistantProvider>();

    // 获取此会话的助手
    final assistant = convo.assistantId != null
        ? assistantProvider.getById(convo.assistantId!)
        : assistantProvider.currentAssistant;

    // 决定模型：优先标题模型，否则回退到助手模型，再到全局默认
    final provKey =
        settings.titleModelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider;
    final mdlId =
        settings.titleModelId ??
        assistant?.chatModelId ??
        settings.currentModelId;
    if (provKey == null || mdlId == null) return;
    final cfg = settings.getProviderConfig(provKey);
    final budget = settings.titleGenerationThinkingBudgetFor(
      assistant?.thinkingBudget,
    );
    final locale = Localizations.localeOf(_contextProvider).toLanguageTag();

    // 从消息构建内容（与侧边抽屉标题路径共享；
    // 缓存和分页路径都收集相同的约 3000 字符尾部窗口）
    final content = await _chatService.generateTitleSource(convo.id);

    String prompt = settings.titlePrompt
        .replaceAll('{locale}', locale)
        .replaceAll('{content}', content);

    try {
      final title = (await ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: budget,
      )).trim();
      if (title.isNotEmpty) {
        await _chatService.renameConversation(convo.id, title);
        if (currentConversation?.id == convo.id) {
          _chatController.updateCurrentConversation(
            _chatService.getConversation(convo.id),
          );
          notifyListeners();
        }
      } else {
        onBackgroundTaskError?.call(BackgroundTaskKind.title, 'empty_response');
      }
    } catch (e) {
      FlutterLogger.log(
        '[TitleGen] Generation failed: $e',
        tag: 'HomeViewModel',
      );
      onBackgroundTaskError?.call(BackgroundTaskKind.title, e);
    }
  }

  /// 强制为当前会话生成标题。
  Future<void> generateTitle({bool force = false}) async {
    final cid = currentConversation?.id;
    if (cid != null) {
      await _maybeGenerateTitleFor(cid, force: force);
    }
  }

  // ============================================================================
  // 摘要生成
  // ============================================================================

  /// 满足条件时为会话生成摘要。
  /// 自上次摘要以来的新消息达到配置数量后触发。
  Future<void> _maybeGenerateSummaryFor(String conversationId) async {
    final convo = _chatService.getConversation(conversationId);
    if (convo == null) return;
    // 摘要仅用于历史会话搜索；临时聊天永远不会被搜索。
    if (_chatService.isTemporaryConversation(convo.id)) return;

    final settings = _contextProvider.read<SettingsProvider>();
    if (!_chatService.isMessageCountKnown(conversationId)) return;
    final msgCount = _chatService.getMessageCount(conversationId);
    final assistantProvider = _contextProvider.read<AssistantProvider>();

    // 获取此会话的助手
    final assistant = convo.assistantId != null
        ? assistantProvider.getById(convo.assistantId!)
        : assistantProvider.currentAssistant;

    final budget = settings.summaryGenerationThinkingBudgetFor(
      assistant?.thinkingBudget,
    );

    final legacy = settings.legacyMemoryMode;
    if (legacy) {
      if (assistant?.allowPastConversationRecall != true) return;
    } else if (!MemoryPipelineService.shouldGenerateConversationSummary(
      allowPastConversationRecall:
          assistant?.allowPastConversationRecall == true,
      generateConversationSummary:
          assistant?.generateConversationSummary == true,
    )) {
      return;
    }

    final triggerMessageCount =
        assistant?.recentChatsSummaryMessageCount ??
        Assistant.defaultRecentChatsSummaryMessageCount;
    if (msgCount == 0 ||
        msgCount - convo.lastSummarizedMessageCount < triggerMessageCount) {
      return;
    }

    // 如果配置了摘要模型则使用，否则回退到标题模型，再到当前模型
    final provKey =
        settings.summaryModelProvider ??
        settings.titleModelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider;
    final mdlId =
        settings.summaryModelId ??
        settings.titleModelId ??
        assistant?.chatModelId ??
        settings.currentModelId;
    if (provKey == null || mdlId == null) return;

    final cfg = settings.getProviderConfig(provKey);

    // 获取所有消息并筛选用户消息
    final msgs = await _chatService.loadActiveTimelineMessages(convo.id);
    final allUserMsgs = msgs
        .where((m) => m.role == 'user' && m.content.trim().isNotEmpty)
        .toList();

    if (allUserMsgs.isEmpty) return;

    // 获取上次摘要（首次为空字符串）
    final previousSummary = (convo.summary ?? '').trim();

    // 仅获取上次摘要以来的近期用户消息
    // 计算上次摘要状态中有多少条用户消息
    final lastSummarizedMsgCount = (convo.lastSummarizedMessageCount < 0)
        ? 0
        : convo.lastSummarizedMessageCount;
    final msgsAtLastSummary = msgs.take(lastSummarizedMsgCount).toList();
    final userMsgsAtLastSummary = msgsAtLastSummary
        .where((m) => m.role == 'user' && m.content.trim().isNotEmpty)
        .length;

    // 获取上次摘要以来的新用户消息
    final newUserMsgs = allUserMsgs.skip(userMsgsAtLastSummary).toList();
    if (newUserMsgs.isEmpty) return;

    final recentMessages = newUserMsgs
        .map((m) => m.content.trim())
        .join('\n\n');

    // 过长则截断
    final content = recentMessages.length > 2000
        ? recentMessages.substring(0, 2000)
        : recentMessages;

    final prompt = settings.summaryPrompt
        .replaceAll('{previous_summary}', previousSummary)
        .replaceAll('{user_messages}', content);

    final traceHandle = legacy ? null : _beginSummaryTrace(convo, assistant);
    final traceStep = traceHandle?.beginStep(
      MemoryTraceStepKind.conversationSummary,
    );
    traceStep?.appendPrompt(prompt);

    try {
      final summary = (await ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: budget,
      )).trim();
      traceStep?.appendResponse(summary);

      if (summary.isNotEmpty) {
        await _chatService.updateConversationSummary(
          convo.id,
          summary,
          msgCount,
        );
        traceStep?.addMutation(
          MemoryTraceMutation(
            kind: MemoryTraceMutationKind.conversationSummaryWritten,
            targetId: convo.id,
            before: previousSummary.isEmpty ? null : previousSummary,
            after: summary,
          ),
        );
      }
      traceStep?.finish(MemoryTraceStepStatus.success);
      traceHandle?.commit(advanced: summary.isNotEmpty);
      if (summary.isNotEmpty) {
        if (currentConversation?.id == convo.id) {
          _chatController.updateCurrentConversation(
            _chatService.getConversation(convo.id),
          );
          notifyListeners();
        }
      } else {
        onBackgroundTaskError?.call(
          BackgroundTaskKind.summary,
          'empty_response',
        );
      }
    } catch (e) {
      // 后台生成失败时保留旧摘要。
      traceStep?.finish(MemoryTraceStepStatus.failed, error: e.toString());
      traceHandle?.commit(error: e.toString());
      onBackgroundTaskError?.call(BackgroundTaskKind.summary, e);
    }
  }

  /// 为后台摘要生成打开跟踪（用于历史会话召回）。
  /// 从不抛出异常。
  MemoryTraceHandle? _beginSummaryTrace(
    Conversation convo,
    Assistant? assistant,
  ) {
    // 临时聊天在退出时被丢弃；不让其痕迹进入 UI。
    if (_chatService.isTemporaryConversation(convo.id)) {
      return null;
    }
    try {
      return MemoryTraceRecorder.instance.begin(
        trigger: MemoryTraceTrigger.conversationSummary,
        scope: assistant == null
            ? MemoryTraceScope.global
            : memoryTraceScopeOf(assistant.memoryWriteScope),
        conversationId: convo.id,
        conversationTitle: convo.title,
        assistantId: assistant?.id,
        assistantName: assistant?.name,
      );
    } catch (_) {
      return null;
    }
  }

  // ============================================================================
  // 聊天建议
  // ============================================================================

  Future<void> _clearSuggestionsFor(String conversationId) async {
    final convo = _chatService.getConversation(conversationId);
    if (convo == null || convo.chatSuggestions.isEmpty) return;
    await _chatService.clearConversationSuggestions(conversationId);
    if (currentConversation?.id == conversationId) {
      _chatController.updateCurrentConversation(
        _chatService.getConversation(conversationId),
      );
      notifyListeners();
    }
  }

  Future<void> _maybeGenerateSuggestionsFor(String conversationId) async {
    final convo = _chatService.getConversation(conversationId);
    if (convo == null) return;

    final settings = _contextProvider.read<SettingsProvider>();
    final provKey = settings.suggestionModelProvider;
    final mdlId = settings.suggestionModelId;
    if (provKey == null || mdlId == null) return;

    // 在下方异步间隙前读取与上下文相关的输入。
    final assistantProvider = _contextProvider.read<AssistantProvider>();
    final assistant = convo.assistantId != null
        ? assistantProvider.getById(convo.assistantId!)
        : assistantProvider.currentAssistant;
    final locale = Localizations.localeOf(_contextProvider).toLanguageTag();
    final budget = settings.suggestionGenerationThinkingBudgetFor(
      assistant?.thinkingBudget,
    );

    final loadedMessages = await _chatService.loadActiveTimelineMessages(
      convo.id,
    );
    // 用于生成后新鲜度检查的原始修订计数快照：
    // getMessageCount 统计每个修订，而折叠列表不是。
    final loadedMessageCount = loadedMessages.length;
    final msgs = loadedMessages;
    final lastAssistant = msgs.cast<ChatMessage?>().lastWhere(
      (m) =>
          m != null &&
          m.role == 'assistant' &&
          !m.isStreaming &&
          m.content.trim().isNotEmpty,
      orElse: () => null,
    );
    if (lastAssistant == null) return;

    try {
      await _chatService.clearConversationSuggestions(conversationId);
      final suggestions = await _suggestionService.generate(
        settings: settings,
        providerKey: provKey,
        modelId: mdlId,
        messages: msgs,
        truncateIndex: _chatService.getContextStartIndex(conversationId),
        locale: locale,
        thinkingBudget: budget,
      );
      if (suggestions.isEmpty) {
        onBackgroundTaskError?.call(
          BackgroundTaskKind.suggestions,
          'empty_response',
        );
        return;
      }

      final latest = _chatService.getConversation(conversationId);
      // 上方 loadMessages 会填充数量；未知值（-1）不等于已加载长度，
      // 因此正确中止发布过期建议。
      if (latest == null ||
          _chatService.getMessageCount(latest.id) != loadedMessageCount) {
        return;
      }

      await _chatService.updateConversationSuggestions(
        conversationId,
        suggestions,
      );
      if (currentConversation?.id == conversationId) {
        _chatController.updateCurrentConversation(
          _chatService.getConversation(conversationId),
        );
        notifyListeners();
      }
    } catch (e) {
      FlutterLogger.log(
        '[SuggestionGen] Generation failed: $e',
        tag: 'HomeViewModel',
      );
      onBackgroundTaskError?.call(BackgroundTaskKind.suggestions, e);
    }
  }

  // ============================================================================
  // 模型能力检查
  // ============================================================================

  bool isReasoningModel(String providerKey, String modelId) {
    return _generationController.isReasoningModel(providerKey, modelId);
  }

  bool isToolModel(String providerKey, String modelId) {
    return _generationController.isToolModel(providerKey, modelId);
  }

  bool isReasoningEnabled(int? budget) {
    return _generationController.isReasoningEnabled(budget);
  }

  // ============================================================================
  // 清理
  // ============================================================================

  /// 刷新当前会话进度（用于切换/创建）。
  Future<void> flushCurrentConversationProgress() async {
    await _chatActions.flushConversationProgress(currentConversation);
  }

  /// 清理已移除消息的状态（推理、工具等）。
  void cleanupMessageState(List<String> messageIds) {
    for (final id in messageIds) {
      _streamController.clearMessageState(id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _conversationTreeReloadSerial++;
    isProcessingFiles.dispose();
    super.dispose();
  }
}
