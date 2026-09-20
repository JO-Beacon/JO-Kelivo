import 'dart:async';
import 'dart:collection';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/database/generation_run.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/conversation_tree.dart';
import '../../../core/models/token_usage.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/api/retry_policy.dart';
import '../../../core/services/api/stream/stream_chunk.dart';
import '../../../core/services/backup/data_sync.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/mobile_background.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../../chat/utils/thinking_tag_parser.dart';
import '../services/ask_user_interaction_service.dart';
import '../services/message_generation_service.dart';
import '../services/tool_approval_service.dart';
import 'active_streaming_message_store.dart';
import 'chat_controller.dart';
import 'generation_controller.dart';
import 'home_view_model.dart';
import 'latest_wins_checkpoint_writer.dart';
import 'stream_controller.dart' as stream_ctrl;
import 'streaming_content_notifier.dart' show RetryStatus;

final class UnsupportedAudioAttachmentException implements Exception {
  const UnsupportedAudioAttachmentException();

  @override
  String toString() => 'audio_attachment_unsupported';
}

final class _BarrierStreamSubscription<T> implements StreamSubscription<T> {
  _BarrierStreamSubscription(this._delegate, this._cancelWithBarrier);

  final StreamSubscription<T> _delegate;
  final Future<void> Function() _cancelWithBarrier;

  @override
  Future<void> cancel() => _cancelWithBarrier();

  @override
  void onData(void Function(T data)? handleData) =>
      _delegate.onData(handleData);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture(futureValue);
}

class _StreamingCheckpoint {
  const _StreamingCheckpoint({
    required this.message,
    required this.toolEvents,
    this.generationRunId,
    this.checkpointSeq,
  });

  final ChatMessage message;
  final List<Map<String, dynamic>> toolEvents;
  final String? generationRunId;
  final int? checkpointSeq;
}

class _GenerationCheckpointCursor {
  _GenerationCheckpointCursor({
    required this.runId,
    required this.state,
    required this.stateRevision,
    required this.nextSeq,
  });

  final String runId;
  GenerationRunState state;
  int stateRevision;
  int nextSeq;
}

/// 发送/重新生成操作的结果。
class ChatActionResult {
  final bool success;
  final String? errorMessage;
  final ChatMessage? assistantMessage;
  final String? generationRunId;

  ChatActionResult({
    required this.success,
    this.errorMessage,
    this.assistantMessage,
    this.generationRunId,
  });

  factory ChatActionResult.success(
    ChatMessage assistantMessage, {
    String? generationRunId,
  }) => ChatActionResult(
    success: true,
    assistantMessage: assistantMessage,
    generationRunId: generationRunId,
  );

  factory ChatActionResult.error(String message) =>
      ChatActionResult(success: false, errorMessage: message);

  factory ChatActionResult.noModel() =>
      ChatActionResult(success: false, errorMessage: 'no_model');

  factory ChatActionResult.inFlight() =>
      ChatActionResult(success: false, errorMessage: 'in_flight');
}

/// 聊天操作的 Actions 类（发送、重新生成、取消、流式处理）。
///
/// 此类只包含业务逻辑，不包含 UI 操作。
/// 它操作消息，调用服务/流并返回结果。
/// UI 层负责处理 Snackbar、滚动、动画等。
///
/// 主要职责：
/// - 发送新消息
/// - 重新生成已有消息
/// - 取消流式处理
/// - 处理流式分块（推理、工具、内容）
/// - 管理流式状态
class ChatActions {
  ChatActions({
    required this.chatService,
    required this.chatController,
    required this.streamController,
    required this.generationController,
    required this.messageGenerationService,
    required this.contextProvider,
    required this.viewModel,
    MobileBackgroundCoordinator? backgroundCoordinator,
  }) : _background =
           backgroundCoordinator ?? MobileBackgroundCoordinator.instance {
    _current = this;
    // 恢复备份会就地改写聊天库与设置，完全覆盖模式还会在收尾冷重启时
    // 替换整个数据库文件，两种模式都不能与流式写入并发。DataSync 位于
    // core 层、取不到取消能力，因此由这里注入（注入是幂等的）。
    DataSync.onBeforeRestore = cancelAllActiveGenerations;
  }

  /// 最新的存活实例。位于主页控制器图之外的删除入口
  /// （例如抽屉中的会话删除）通过它访问活动生成状态，
  /// 以维持“删除意味着停止生成”的约束。
  static ChatActions? _current;

  /// 移动端后台执行协调器：把进行中的生成登记给系统，
  /// 让应用退到后台时任务仍能被跟踪和取消。
  final MobileBackgroundCoordinator _background;

  /// 当前是否有任何会话正在生成。
  ///
  /// 供后台维护使用：这类工作宁可等待，也不愿与用户正在观看的回复
  /// 抢磁盘和 CPU。
  static bool get hasAnyActiveGeneration {
    final actions = _current;
    if (actions == null) return false;
    return actions._conversationStreams.isNotEmpty ||
        actions._activeAssistantMessages.isNotEmpty;
  }

  /// 在应用退出前刷新最新的内存生成快照。
  static Future<void> flushActiveGenerationProgress() async {
    final actions = _current;
    if (actions == null) return;
    await actions.flushConversationProgress(
      actions.chatController.currentConversation,
    );
  }

  /// 在 [conversationId] 对应行被删除前停止其进行中的生成，
  /// 使流式检查点不能写入已删除消息。
  static Future<void> cancelActiveGenerationFor(
    String conversationId, {
    String? expectedMessageId,
  }) async {
    final actions = _current;
    if (actions == null || !actions._hasActiveGeneration(conversationId)) {
      return;
    }
    if (expectedMessageId != null &&
        actions.activeStreamingMessageId(conversationId) != expectedMessageId) {
      return;
    }
    await actions.cancelStreamingById(conversationId);
  }

  /// 停止 [assistantId] 拥有的每个会话的进行中生成。
  /// 用于助手删除，该操作会批量删除助手会话，并且必须为每个会话
  /// 维持“删除意味着停止生成”的约束。
  static Future<void> cancelActiveGenerationsForAssistant(
    String assistantId,
  ) async {
    final actions = _current;
    if (actions == null) return;
    final conversationIds = actions.chatService
        .getAllConversations()
        .where((c) => c.assistantId == assistantId)
        .map((c) => c.id)
        .toList();
    for (final id in conversationIds) {
      if (actions._hasActiveGeneration(id)) {
        await actions.cancelStreamingById(id);
      }
    }
  }

  /// 停止所有会话的进行中生成。
  ///
  /// 用于恢复备份：恢复要么就地改写聊天库与设置，要么在收尾冷重启时
  /// 替换整个数据库文件，两者都不能与流式写入并发。
  static Future<void> cancelAllActiveGenerations() async {
    final actions = _current;
    if (actions == null) return;
    final conversationIds = actions.chatService
        .getAllConversations()
        .map((c) => c.id)
        .toList();
    for (final id in conversationIds) {
      if (actions._hasActiveGeneration(id)) {
        await actions.cancelStreamingById(id);
      }
    }
  }

  final HomeViewModel viewModel;
  final ChatService chatService;
  final ChatController chatController;
  final stream_ctrl.StreamController streamController;
  final GenerationController generationController;
  final MessageGenerationService messageGenerationService;
  final BuildContext contextProvider;

  // ============================================================================
  // UI 更新回调（由 HomeViewModel 设置）
  // ============================================================================

  /// 消息列表更新时调用。
  VoidCallback? onMessagesChanged;

  /// 发送成功的一对消息出现在尾部窗口后调用一次。
  VoidCallback? onSendPairAppended;

  /// 会话加载状态变化时调用。
  void Function(String conversationId, bool loading)? onLoadingChanged;

  /// 流式内容更新时调用（用于节流更新）。
  void Function(String messageId, String content, int totalTokens)?
  onContentUpdated;

  /// 流式过程中发生错误时调用。
  void Function(String error)? onStreamError;

  /// 流结束时调用，此时可能需要生成标题。
  void Function(String conversationId)? onMaybeGenerateTitle;

  /// 可能需要生成摘要时调用（每 N 条消息）。
  void Function(String conversationId)? onMaybeGenerateSummary;

  /// 可能需要生成聊天建议时调用。
  void Function(String conversationId)? onMaybeGenerateSuggestions;

  /// 调用以安排行内图片清理。
  void Function(String messageId, String content, {bool immediate})?
  onScheduleImageSanitize;

  /// [conversationId] 的流结束时调用。
  void Function(String conversationId)? onStreamFinished;

  /// 成功的助手回复最终化时调用。落库之后等待下游把后台执行接过去，
  /// 而不是等它整段跑完。
  FutureOr<void> Function(ChatMessage message)? onAssistantMessageFinished;

  /// 文件处理开始时调用，参数为所属助手消息 ID。
  void Function(String messageId)? onFileProcessingStarted;

  /// 文件处理结束时调用，参数为所属助手消息 ID。
  void Function(String? messageId)? onFileProcessingFinished;

  // ============================================================================
  // 私有辅助方法
  // ============================================================================

  AppLocalizations? get _l10n => AppLocalizations.of(contextProvider);

  /// 后台任务的稳定标识：优先用生成运行 id，回退到助手消息 id。
  String _backgroundTaskId(stream_ctrl.GenerationContext ctx) =>
      ctx.generationRunId ?? ctx.assistantMessage.id;

  /// 从助手消息 id 反查后台任务标识，用于取消与收尾路径。
  String _backgroundTaskIdFor(String messageId) =>
      _generationCheckpointCursors[messageId]?.runId ?? messageId;

  Future<void> _startIosBackgroundGeneration(
    stream_ctrl.GenerationContext ctx,
  ) async {
    final l10n = _l10n;
    if (l10n == null) return;
    if (_background.supported) {
      await _background.configureFromSettings(ctx.settings, l10n);
    }
    final conversationId = ctx.assistantMessage.conversationId;
    await _background.start(
      id: _backgroundTaskId(ctx),
      scheduled: ctx.scheduled,
      conversationId: conversationId,
      title:
          chatService.getConversation(conversationId)?.title ?? 'JO-AIClient',
      cancel: () async {
        if (!_activeAssistantMessages.isActive(ctx.assistantMessage)) return;
        if (ctx.generationRunId != null &&
            _generationCheckpointCursors[ctx.assistantMessage.id]?.runId !=
                ctx.generationRunId) {
          return;
        }
        await cancelStreamingById(conversationId);
      },
    );
  }

  void _scheduleIosBackgroundGenerationUpdate(
    stream_ctrl.StreamingState state,
  ) {
    final tools = streamController.toolParts[state.messageId] ?? const [];
    final loadingTools = tools.where((tool) => tool.loading);
    final activeTool = loadingTools.isEmpty ? null : loadingTools.last;
    _background.update(
      _backgroundTaskId(state.ctx),
      phase: state.retryStatus != null
          ? BackgroundTaskPhase.retrying
          : activeTool != null
          ? BackgroundTaskPhase.tool
          : state.fullContentRaw.isEmpty && state.reasoningStartAt != null
          ? BackgroundTaskPhase.thinking
          : BackgroundTaskPhase.generating,
      tokens: state.totalTokens,
      toolName: activeTool?.toolName ?? '',
    );
  }

  Future<void> _finishIosBackgroundGeneration(
    String id, {
    required bool success,
    bool resultPersisted = true,
    String? replyPreview,
  }) async {
    await _background.finish(
      id,
      success ? BackgroundTaskOutcome.completed : BackgroundTaskOutcome.failed,
      resultPersisted: resultPersisted,
      replyPreview: replyPreview,
    );
  }

  Future<void> _cancelIosBackgroundGeneration(String id) async {
    await _background.finish(id, BackgroundTaskOutcome.cancelled);
  }

  /// 跟踪进行中的 _finishStreaming Future，使 _handleStreamDone
  /// 可以在移除通知器或触发重建前等待其完成。
  final Map<String, Future<void>> _finishStreamingFutures =
      <String, Future<void>>{};
  final Map<String, LatestWinsCheckpointWriter<_StreamingCheckpoint>>
  _checkpointWriters =
      <String, LatestWinsCheckpointWriter<_StreamingCheckpoint>>{};
  final Map<String, List<Map<String, dynamic>>> _streamingToolEvents =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, stream_ctrl.StreamingState> _streamingStates = {};
  final Map<String, _GenerationCheckpointCursor> _generationCheckpointCursors =
      <String, _GenerationCheckpointCursor>{};
  final ActiveStreamingMessageStore _activeAssistantMessages =
      ActiveStreamingMessageStore();
  final Map<String, Future<void>> _cancelStreamingFutures =
      <String, Future<void>>{};

  /// 每个会话的发送/重新生成占用标记，在首个 await 前同步取得，
  /// 以便重入调用在持久化任何内容前失败。设置加载状态后，
  /// 该标记交给加载守卫；令牌可防止过期的 finally 清除较新的标记。
  final Map<String, int> _sendInFlightClaims = <String, int>{};
  var _sendInFlightClaimSerial = 0;

  /// 当前拥有 [conversationId] 的是发送/重新生成还是取消清理流程。
  bool isSendInFlight(String conversationId) =>
      _sendInFlightClaims.containsKey(conversationId) ||
      isStopping(conversationId);

  bool isStopping(String conversationId) =>
      _cancelStreamingFutures.containsKey(conversationId);

  List<ChatMessage> get _messages => chatController.messages;
  Set<String> get _loadingConversationIds =>
      chatController.loadingConversationIds;
  Map<String, StreamSubscription<dynamic>> get _conversationStreams =>
      chatController.conversationStreams;

  bool _hasActiveGeneration(String conversationId) =>
      _conversationStreams.containsKey(conversationId) ||
      _activeAssistantMessages[conversationId] != null ||
      isStopping(conversationId);

  /// 进行中生成写入检查点的助手消息 ID；
  /// 当 [conversationId] 没有活动生成时为 null。
  String? activeStreamingMessageId(String conversationId) =>
      _activeAssistantMessages[conversationId]?.id;

  /// 更新（或清除）气泡内的自动重试倒计时。
  void _setRetryStatus(
    stream_ctrl.StreamingState state,
    RetryPending? pending,
  ) {
    if (pending == null) {
      state.retryStatus = null;
      streamController.streamingContentNotifier.updateRetryStatus(
        state.messageId,
        null,
      );
      return;
    }
    final status = RetryStatus(
      attempt: pending.attempt,
      maxRetries: pending.maxRetries,
      retryAt: pending.deadlineAt(),
    );
    state.retryStatus = status;
    streamController.streamingContentNotifier.updateRetryStatus(
      state.messageId,
      status,
    );
  }

  static const Duration _streamCancelTimeout = Duration(seconds: 3);

  /// 屏障取消只有在生成器离开当前挂起点后才会完成；死连接甚至
  /// 在 `cancelRequest` 后也可能无限期停滞，因此要限制等待并继续本地清理。
  Future<void> _cancelSubscriptionWithTimeout(
    StreamSubscription<dynamic> subscription,
  ) async {
    try {
      await subscription.cancel().timeout(_streamCancelTimeout);
    } on TimeoutException {
      // 取消过程继续在后台运行。
    } catch (_) {
      // HTTP 请求已中止；本地收尾清理仍必须执行。
    }
  }

  void _setConversationLoading(
    String conversationId,
    bool loading, {
    String? finishedMessageId,
  }) {
    if (!loading) {
      final activeId = _activeAssistantMessages[conversationId]?.id;
      if (activeId != null && activeId != finishedMessageId) return;
    }
    chatController.setConversationLoading(conversationId, loading);
    onLoadingChanged?.call(conversationId, loading);
  }

  List<Map<String, dynamic>> _copyToolEvents(String messageId) {
    return (_streamingToolEvents[messageId] ?? const <Map<String, dynamic>>[])
        .map((event) => Map<String, dynamic>.from(event))
        .toList(growable: false);
  }

  ChatMessage _messageWithCurrentReasoning(ChatMessage message) {
    final messageId = message.id;
    final reasoning = streamController.reasoning[messageId];
    final segments = streamController.reasoningSegments[messageId];
    final splits = streamController.getContentSplitData(messageId);
    final details = streamController.reasoningDetails[messageId];
    final reasoningSegmentsJson =
        segments != null || splits != null || details != null
        ? streamController.serializeReasoningSegmentsWithSplits(
            segments ?? const [],
            contentSplitOffsets: splits?.offsets,
            reasoningCountAtSplit: splits?.reasoningCounts,
            toolCountAtSplit: splits?.toolCounts,
            reasoningDetails: details,
          )
        : message.reasoningSegmentsJson;
    return message.copyWith(
      reasoningText: reasoning?.text,
      reasoningStartAt: reasoning?.startAt,
      reasoningFinishedAt: reasoning?.finishedAt,
      reasoningSegmentsJson: reasoningSegmentsJson,
    );
  }

  /// 自 [start] 起经过的毫秒数；未知或设备时钟回拨导致差值为负时
  /// 为 null（message_rows 的 CHECK 约束会拒绝负持续时间）。
  int? _elapsedMsFrom(DateTime? start) {
    if (start == null) return null;
    final elapsed = DateTime.now().difference(start).inMilliseconds;
    return elapsed < 0 ? null : elapsed;
  }

  ChatMessage _streamingMessageSnapshot(stream_ctrl.StreamingState state) {
    final messageId = state.messageId;
    final index = _messages.indexWhere((message) => message.id == messageId);
    final base = _messageWithCurrentReasoning(
      index < 0 ? state.ctx.assistantMessage : _messages[index],
    );
    return base.copyWith(
      parts: _assistantPartsForState(state),
      totalTokens: state.totalTokens,
      promptTokens: state.usage?.promptTokens,
      completionTokens: state.usage?.completionTokens,
      cachedTokens: state.usage?.cachedTokens,
      // copyWith keeps base.durationMs when this resolves to null.
      durationMs: _elapsedMsFrom(state.streamStartedAt),
    );
  }

  void _scheduleStreamingCheckpoint(stream_ctrl.StreamingState state) {
    final writer = _checkpointWriters[state.messageId];
    if (writer == null || state.finishHandled) return;
    writer.add(() {
      final message = _streamingMessageSnapshot(state);
      _activeAssistantMessages.put(message);
      return _createStreamingCheckpoint(message);
    });
  }

  _StreamingCheckpoint _createStreamingCheckpoint(ChatMessage message) {
    final cursor = _generationCheckpointCursors[message.id];
    // 当运行仍处于 `preparing` 时，检查点 CAS（只匹配
    // requesting/streaming/waiting_tool）会触发冲突，并通过写入器
    // 终止刚启动的生成。因此先持久化不带运行 id/seq 的普通消息快照，
    // 直到运行到达 `requesting`，这与
    // _finalizeStreamingCheckpoint 对 preparing 状态的处理一致。
    if (cursor == null || cursor.state == GenerationRunState.preparing) {
      return _StreamingCheckpoint(
        message: message,
        toolEvents: _copyToolEvents(message.id),
        generationRunId: null,
        checkpointSeq: null,
      );
    }
    final checkpointSeq = cursor.nextSeq;
    cursor.nextSeq += 1;
    return _StreamingCheckpoint(
      message: message,
      toolEvents: _copyToolEvents(message.id),
      generationRunId: cursor.runId,
      checkpointSeq: checkpointSeq,
    );
  }

  void _registerGenerationRun(String messageId, String? runId) {
    if (runId == null) return;
    _generationCheckpointCursors[messageId] = _GenerationCheckpointCursor(
      runId: runId,
      state: GenerationRunState.preparing,
      stateRevision: 0,
      nextSeq: 1,
    );
  }

  Future<void> _finalizeStreamingCheckpoint(
    ChatMessage message, {
    required GenerationRunState terminalState,
    String? errorCode,
  }) async {
    final writer = _checkpointWriters.remove(message.id);
    final cursor = _generationCheckpointCursors[message.id];
    final checkpointSeq =
        cursor == null || cursor.state == GenerationRunState.preparing
        ? null
        : cursor.nextSeq++;
    final toolEvents = _copyToolEvents(message.id);
    Future<void> writeFinal() async {
      await chatService.finalizeGenerationRunSilent(
        message: message,
        toolEvents: toolEvents,
        generationRunId: cursor?.runId,
        expectedState: cursor?.state,
        expectedStateRevision: cursor?.stateRevision,
        terminalState: terminalState,
        checkpointSeq: checkpointSeq,
        errorCode: errorCode,
      );
    }

    var committed = false;
    try {
      if (writer == null) {
        await writeFinal();
      } else {
        await writer.finalize(writeFinal);
      }
      committed = true;
    } finally {
      if (committed) _clearGenerationRuntimeState(message);
    }
  }

  void _clearGenerationRuntimeState(ChatMessage message) {
    _generationCheckpointCursors.remove(message.id);
    _streamingToolEvents.remove(message.id);
    _streamingStates.remove(message.id);
    _activeAssistantMessages.removeIfMatches(message);
  }

  Future<void> _finishPrepareError(
    String conversationId,
    ChatMessage fallback,
    PrepareErrorAction action,
  ) async {
    switch (action) {
      case PrepareErrorAction.skip:
        return;
      case PrepareErrorAction.cancelled:
        await _finishPreparingMessage(
          conversationId,
          fallback,
          terminalState: GenerationRunState.cancelled,
          errorCode: null,
        );
      case PrepareErrorAction.failed:
        await _finishPreparingMessage(conversationId, fallback);
    }
  }

  Future<void> _finishPreparingMessage(
    String conversationId,
    ChatMessage fallback, {
    GenerationRunState terminalState = GenerationRunState.failed,
    String? errorCode = 'preparation_failed',
  }) async {
    final active = _activeAssistantMessages[conversationId];
    final message = _messageWithCurrentReasoning(
      active?.id == fallback.id ? active! : fallback,
    ).copyWith(isStreaming: false);
    streamController.markStreamingEnded(message.id);
    streamController.cleanupTimers(message.id);
    streamController.removeStreamingNotifier(message.id);
    try {
      await _finalizeStreamingCheckpoint(
        message,
        terminalState: terminalState,
        errorCode: errorCode,
      );
    } finally {
      _clearGenerationRuntimeState(message);
      if (chatController.publishTerminalMessage(message)) {
        onMessagesChanged?.call();
      }
      _setConversationLoading(
        conversationId,
        false,
        finishedMessageId: message.id,
      );
    }
  }

  void _upsertStreamingToolEvent(
    String messageId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    Map<String, dynamic>? metadata,
  }) {
    final events = _streamingToolEvents.putIfAbsent(
      messageId,
      () => <Map<String, dynamic>>[],
    );
    var index = id.isEmpty
        ? -1
        : events.indexWhere((event) => '${event['id'] ?? ''}' == id);
    if (index < 0) {
      index = events.indexWhere(
        (event) =>
            '${event['name'] ?? ''}' == name &&
            (event['content'] == null || '${event['content']}'.isEmpty),
      );
    }
    final record = <String, dynamic>{
      'id': id,
      'name': name,
      'arguments': arguments,
      'content': content,
      if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
    };
    if (index < 0) {
      events.add(record);
    } else {
      events[index] = mergeStreamingToolEventRecord(events[index], record);
    }
  }

  static Map<String, dynamic> mergeStreamingToolEventRecord(
    Map<String, dynamic> existing,
    Map<String, dynamic> incoming,
  ) {
    final merged = Map<String, dynamic>.from(existing);
    for (final entry in incoming.entries) {
      if (entry.key == 'metadata') continue;
      if (_isEmptyToolOverlay(entry.value) &&
          !_isEmptyToolOverlay(merged[entry.key])) {
        continue;
      }
      merged[entry.key] = entry.value;
    }
    if (existing['server'] == true && incoming['server'] != false) {
      merged['server'] = true;
    }
    final incomingMetadata = incoming['metadata'];
    if (incomingMetadata is Map && incomingMetadata.isNotEmpty) {
      final existingMetadata = merged['metadata'];
      merged['metadata'] = <String, dynamic>{
        if (existingMetadata is Map)
          ...Map<String, dynamic>.from(existingMetadata),
        ...Map<String, dynamic>.from(incomingMetadata),
      };
    } else if (!merged.containsKey('metadata')) {
      final existingMetadata = existing['metadata'];
      if (existingMetadata is Map) {
        merged['metadata'] = Map<String, dynamic>.from(existingMetadata);
      }
    }
    return merged;
  }

  static bool _isEmptyToolOverlay(Object? value) {
    if (value == null) return true;
    if (value is String) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    if (value is List) return value.isEmpty;
    return false;
  }

  static List<MessagePart> assistantPartsForVisibleText({
    required List<MessagePart> parts,
    required String visibleText,
  }) {
    if (parts.isEmpty) return <MessagePart>[TextPart(visibleText)];
    var remaining = visibleText.length;
    final out = <MessagePart>[];
    for (final part in parts) {
      if (part is! TextPart) {
        out.add(part);
        continue;
      }
      if (remaining <= 0) continue;
      if (part.text.length <= remaining) {
        out.add(part);
        remaining -= part.text.length;
      } else {
        out.add(TextPart(part.text.substring(0, remaining)));
        remaining = 0;
      }
    }
    return out;
  }

  static List<MessagePart> assistantPartsForStreamError({
    required List<MessagePart> parts,
    required String partialContent,
    required String errorText,
  }) {
    final displayContent = resolveStreamErrorContent(
      partialContent: partialContent,
      errorText: errorText,
    );
    if (partialContent.isEmpty) {
      if (parts.any((part) => part is TextPart)) {
        return ChatMessage.partsWithReplacedText(parts, displayContent);
      }
      return [...parts, TextPart(displayContent)];
    }
    return List<MessagePart>.of(parts);
  }

  List<MessagePart> _assistantPartsForState(
    stream_ctrl.StreamingState state, {
    String? visibleText,
  }) {
    final parts = state.partsHandler.parts;
    if (parts.isEmpty) {
      return <MessagePart>[
        TextPart(visibleText ?? _transformAssistantContent(state)),
      ];
    }
    final transformed = [
      for (final part in parts)
        if (part is TextPart)
          TextPart(_transformAssistantContent(state, part.text))
        else if (part is! ImagePart || !isBlankImageUri(part.uri))
          part,
    ];
    if (visibleText == null) return transformed;
    return assistantPartsForVisibleText(
      parts: transformed,
      visibleText: visibleText,
    );
  }

  Future<List<MessagePart>> _sanitizeAssistantImageParts(
    List<MessagePart> parts,
  ) async {
    final out = <MessagePart>[];
    for (final part in parts) {
      if (part is TextPart && part.text.contains('data:image')) {
        // 保留已有 Markdown 图片落盘行为，但不能合并跨工具卡片的文字部件。
        out.add(
          TextPart(
            await MarkdownMediaSanitizer.replaceInlineBase64Images(part.text),
          ),
        );
        continue;
      }
      if (part is! ImagePart || !part.uri.startsWith('data:')) {
        out.add(part);
        continue;
      }
      final comma = part.uri.indexOf(',');
      if (comma < 0) {
        out.add(part);
        continue;
      }
      final header = part.uri.substring(5, comma);
      final semi = header.indexOf(';');
      final mime = semi < 0 ? header : header.substring(0, semi);
      final saved = await AppDirectories.saveBase64Image(
        mime.isEmpty ? 'image/png' : mime,
        part.uri.substring(comma + 1),
      );
      if (saved == null || saved.isEmpty) {
        out.add(part);
        continue;
      }
      out.add(
        ImagePart(
          uri: SandboxPathResolver.canonicalize(saved),
          mime: part.mime ?? (mime.isEmpty ? 'image/png' : mime),
          assetId: part.assetId,
          id: part.id,
          unavailable: part.unavailable,
        ),
      );
    }
    return out;
  }

  bool _isReasoningModel(String providerKey, String modelId) {
    return generationController.isReasoningModel(providerKey, modelId);
  }

  bool _isReasoningEnabled(int? budget) {
    return messageGenerationService.isReasoningEnabled(budget);
  }

  Conversation _conversationForMessageContext(
    Conversation conversation,
    List<ChatMessage> messages, {
    int? maxRawTruncateIndex,
  }) {
    final completeConversation = chatController
        .conversationForCompleteHistoryContext(conversation);
    return conversationForMessageContext(
      conversation: completeConversation,
      messages: messages,
      maxRawTruncateIndex: maxRawTruncateIndex,
    );
  }

  @visibleForTesting
  static Conversation conversationForMessageContext({
    required Conversation conversation,
    required List<ChatMessage> messages,
    int? maxRawTruncateIndex,
  }) {
    final rawTruncateIndex = conversation.truncateIndex;
    if (maxRawTruncateIndex != null && rawTruncateIndex > maxRawTruncateIndex) {
      return conversation.copyWith(truncateIndex: -1);
    }
    if (rawTruncateIndex < 0 || rawTruncateIndex <= messages.length) {
      return conversation;
    }
    return conversation.copyWith(truncateIndex: -1);
  }

  @visibleForTesting
  static String resolveStreamErrorContent({
    required String partialContent,
    required String errorText,
  }) => partialContent.isEmpty ? errorText : partialContent;

  @visibleForTesting
  Future<void> debugFinishStreaming(stream_ctrl.StreamingState state) =>
      _finishStreaming(state);

  @visibleForTesting
  Future<void> debugHandleStreamError(
    Object error,
    stream_ctrl.StreamingState state,
  ) => _handleStreamError(error, state);

  @visibleForTesting
  static StreamSubscription<T> listenSequentiallyToStream<T>({
    required Stream<T> stream,
    required Future<void> Function(T chunk) onData,
    required Future<void> Function(Object error, StackTrace stackTrace) onError,
    required Future<void> Function() onDone,
  }) {
    final events =
        Queue<({T? data, Object? error, StackTrace? stackTrace, bool done})>();
    late final StreamSubscription<T> sourceSubscription;
    Future<void>? drainFuture;
    var terminalQueued = false;

    Future<void> reportError(Object error, StackTrace stackTrace) async {
      try {
        await onError(error, stackTrace);
      } catch (secondaryError, secondaryStackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: secondaryError,
            stack: secondaryStackTrace,
            context: ErrorDescription(
              'while handling a sequential stream terminal error',
            ),
          ),
        );
      }
    }

    Future<void> drain() async {
      try {
        while (events.isNotEmpty) {
          final event = events.removeFirst();
          final error = event.error;
          if (error != null) {
            await reportError(error, event.stackTrace ?? StackTrace.current);
            await sourceSubscription.cancel();
            events.clear();
            return;
          }
          if (event.done) {
            await onDone();
            return;
          }
          await onData(event.data as T);
        }
      } catch (error, stackTrace) {
        terminalQueued = true;
        events.clear();
        await reportError(error, stackTrace);
        await sourceSubscription.cancel();
      }
    }

    late final void Function() scheduleDrain;
    scheduleDrain = () {
      drainFuture ??= drain().whenComplete(() {
        drainFuture = null;
        if (events.isNotEmpty) scheduleDrain();
      });
    };

    void enqueue(
      ({T? data, Object? error, StackTrace? stackTrace, bool done}) event,
    ) {
      events.add(event);
      scheduleDrain();
    }

    sourceSubscription = stream.listen(
      (chunk) {
        if (terminalQueued) return;
        enqueue((data: chunk, error: null, stackTrace: null, done: false));
      },
      onError: (Object error, StackTrace stackTrace) {
        if (terminalQueued) return;
        terminalQueued = true;
        enqueue((
          data: null,
          error: error,
          stackTrace: stackTrace,
          done: false,
        ));
      },
      onDone: () {
        if (terminalQueued) return;
        terminalQueued = true;
        enqueue((data: null, error: null, stackTrace: null, done: true));
      },
      cancelOnError: true,
    );
    return _BarrierStreamSubscription<T>(sourceSubscription, () async {
      terminalQueued = true;
      events.clear();
      try {
        await sourceSubscription.cancel();
      } finally {
        await drainFuture;
      }
    });
  }

  bool _supportsAudioAttachmentsForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    return messageGenerationService.supportsAudioAttachmentsForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );
  }

  bool _hasUnsupportedAudioAttachments({
    required List<ChatMessage> messages,
    required Conversation conversation,
    required SettingsProvider settings,
    required String providerKey,
    required String modelId,
    ChatInputData? pendingInput,
    int? maxRawTruncateIndex,
  }) {
    if (_supportsAudioAttachmentsForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    )) {
      return false;
    }

    if (pendingInput != null &&
        messageGenerationService.inputContainsAudioAttachments(pendingInput)) {
      return true;
    }

    final apiMessages = messageGenerationService.messageBuilderService
        .buildApiMessages(
          messages: messages,
          currentConversation: _conversationForMessageContext(
            conversation,
            messages,
            maxRawTruncateIndex: maxRawTruncateIndex,
          ),
        );
    return messageGenerationService.apiMessagesContainAudioAttachments(
      apiMessages,
    );
  }

  /// 使用助手正则表达式转换原始内容。
  String _transformAssistantContent(
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
  // 发送消息
  // ============================================================================

  /// 发送新消息并开始生成助手回复。
  ///
  /// 返回包含成功状态和助手消息的 [ChatActionResult]。
  /// UI 负责：
  /// - 将消息（用户消息和助手消息）添加到列表
  /// - 出错时显示 Snackbar
  /// - 滚动一次到新追加的尾部
  /// - 触感反馈
  Future<ChatActionResult> sendMessage({
    required ChatInputData input,
    required Conversation conversation,
    Assistant? assistantOverride,
    bool scheduled = false,
    ({String providerKey, String modelId})? modelOverride,
    ValueChanged<String>? onGenerationStarted,
  }) async {
    final claimToken = ++_sendInFlightClaimSerial;
    if (isSendInFlight(conversation.id)) {
      return ChatActionResult.inFlight();
    }
    _sendInFlightClaims[conversation.id] = claimToken;
    try {
      return await _sendMessageClaimed(
        input: input,
        conversation: conversation,
        assistantOverride: assistantOverride,
        scheduled: scheduled,
        modelOverride: modelOverride,
        onGenerationStarted: onGenerationStarted,
      );
    } finally {
      if (_sendInFlightClaims[conversation.id] == claimToken) {
        _sendInFlightClaims.remove(conversation.id);
      }
    }
  }

  Future<ChatActionResult> _sendMessageClaimed({
    required ChatInputData input,
    required Conversation conversation,
    Assistant? assistantOverride,
    bool scheduled = false,
    ({String providerKey, String modelId})? modelOverride,
    ValueChanged<String>? onGenerationStarted,
  }) async {
    final content = input.text.trim();
    if (content.isEmpty &&
        input.imagePaths.isEmpty &&
        input.documents.isEmpty) {
      return ChatActionResult.error('empty_input');
    }

    final settings = contextProvider.read<SettingsProvider>();
    final assistantProvider = contextProvider.read<AssistantProvider>();
    // 在异步间隙前捕获审批服务引用
    ToolApprovalService? approvalService;
    AskUserInteractionService? askUserService;
    try {
      approvalService = contextProvider.read<ToolApprovalService>();
    } catch (_) {}
    try {
      askUserService = contextProvider.read<AskUserInteractionService>();
    } catch (_) {}
    try {
      await assistantProvider.loaded;
    } catch (e) {
      return ChatActionResult.error(e.toString());
    }
    final assistant = assistantOverride ?? assistantProvider.currentAssistant;
    final assistantId = assistant?.id;
    final modelConfig =
        modelOverride ??
        messageGenerationService.getModelConfig(
          settings,
          assistant,
          conversation,
        );

    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return ChatActionResult.noModel();
    }
    final providerKey = modelConfig.providerKey!;
    final modelId = modelConfig.modelId!;

    // 定时发送的目标会话可能不是当前显示的会话，
    // 只有同一会话时才调整已加载窗口。
    if (chatController.currentConversation?.id == conversation.id &&
        chatController.hasMoreAfter) {
      final loaded = await chatController.loadEndWindow();
      if (loaded) {
        viewModel.restoreMessageUiState();
      }
    }

    // 当前输入无需读取数据库即可检查；历史消息的检查移到后台生成阶段，
    // 让消息对先落库并显示。
    if (!_supportsAudioAttachmentsForProvider(
          settings,
          providerKey: providerKey,
          modelId: modelId,
        ) &&
        messageGenerationService.inputContainsAudioAttachments(input)) {
      return ChatActionResult.error('audio_attachment_unsupported');
    }

    late final ChatMessage userMessage;
    late final ChatMessage assistantMessage;
    String? generationRunId;
    try {
      final begin = await messageGenerationService.beginSendGeneration(
        conversationId: conversation.id,
        input: input,
        assistant: assistant,
        modelId: modelId,
        providerKey: providerKey,
      );
      userMessage = begin.userMessage;
      assistantMessage = begin.assistantMessage;
      generationRunId = begin.runId;
      _registerGenerationRun(assistantMessage.id, generationRunId);
    } catch (e) {
      return ChatActionResult.error(e.toString());
    }
    _activeAssistantMessages.put(assistantMessage);
    _setConversationLoading(conversation.id, true);
    // 此时加载守卫拥有此会话的重入排除。
    _sendInFlightClaims.remove(conversation.id);
    onGenerationStarted?.call(assistantMessage.id);

    // 在将消息加入列表前预先创建流式通知器，
    // 使 MessageListView 在首次渲染时就能识别到流式状态。
    streamController.markStreamingStarted(assistantMessage.id);

    if (await chatController.appendPersistedTailMessages([
      userMessage,
      assistantMessage,
    ])) {
      viewModel.restoreMessageUiState();
    }
    onMessagesChanged?.call();
    if (chatController.currentConversation?.id == conversation.id) {
      onSendPairAppended?.call();
    }

    // 消息对已可见；准备上下文和生成在后台继续，输入框无需等待整段回复。
    unawaited(
      _runSendGeneration(
        input: input,
        conversation: conversation,
        settings: settings,
        assistant: assistant,
        assistantId: assistantId,
        providerKey: providerKey,
        modelId: modelId,
        userMessage: userMessage,
        assistantMessage: assistantMessage,
        generationRunId: generationRunId,
        scheduled: scheduled,
        approvalService: approvalService,
        askUserService: askUserService,
      ),
    );
    return ChatActionResult.success(
      assistantMessage,
      generationRunId: generationRunId,
    );
  }

  Future<void> _runSendGeneration({
    required ChatInputData input,
    required Conversation conversation,
    required SettingsProvider settings,
    required Assistant? assistant,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    required ChatMessage userMessage,
    required ChatMessage assistantMessage,
    required String? generationRunId,
    required bool scheduled,
    required ToolApprovalService? approvalService,
    required AskUserInteractionService? askUserService,
  }) async {
    try {
      final contextLimit = await _contextReadLimit(assistant, conversation);
      final persistedContext = await chatController
          .messagesForGenerationContext(
            conversation,
            maxMessages: contextLimit + 2,
          );
      final existingContextMessages = <ChatMessage>[
        for (final message in persistedContext)
          if (message.id != userMessage.id && message.id != assistantMessage.id)
            message,
      ];
      if (_hasUnsupportedAudioAttachments(
        messages: existingContextMessages,
        conversation: conversation,
        settings: settings,
        providerKey: providerKey,
        modelId: modelId,
        maxRawTruncateIndex: null,
      )) {
        throw const UnsupportedAudioAttachmentException();
      }

      streamController.toolParts.remove(assistantMessage.id);
      final supportsReasoning = _isReasoningModel(providerKey, modelId);
      final enableReasoning =
          supportsReasoning &&
          _isReasoningEnabled(
            assistant?.thinkingBudget ?? settings.thinkingBudget,
          );
      _bindFileProcessingCallbacks();
      await messageGenerationService.initializeReasoningState(
        messageId: assistantMessage.id,
        enableReasoning: enableReasoning,
      );
      final apiContextMessages = <ChatMessage>[
        ...existingContextMessages,
        userMessage,
        assistantMessage,
      ];
      final prepared = await messageGenerationService
          .prepareApiMessagesWithInjections(
            messages: apiContextMessages,
            currentConversation: conversation.copyWith(truncateIndex: -1),
            settings: settings,
            assistant: assistant,
            assistantId: assistantId,
            providerKey: providerKey,
            modelId: modelId,
            approvalService: approvalService,
            askUserService: askUserService,
            processingMessageId: assistantMessage.id,
            requiredAttachmentMessageId: userMessage.id,
          );
      final userImagePaths = messageGenerationService.buildUserImagePaths(
        input: input,
        lastUserImagePaths: prepared.lastUserImagePaths,
        settings: settings,
        providerKey: providerKey,
        modelId: modelId,
      );
      final ctx = messageGenerationService.buildGenerationContext(
        assistantMessage: assistantMessage,
        prepared: prepared,
        userImagePaths: userImagePaths,
        allowImagesApiRouting: input.allowImagesApiRouting,
        providerKey: providerKey,
        modelId: modelId,
        assistant: assistant,
        settings: settings,
        supportsReasoning: supportsReasoning,
        enableReasoning: enableReasoning,
        generateTitleOnFinish: true,
        generationRunId: generationRunId,
        scheduled: scheduled,
      );
      if (!_activeAssistantMessages.isActive(assistantMessage)) return;
      await _executeGeneration(ctx);
    } catch (error) {
      await handleSendGenerationFailure(
        error: error,
        conversationId: conversation.id,
        assistantMessage: assistantMessage,
      );
    }
  }

  @visibleForTesting
  Future<void> handleSendGenerationFailure({
    required Object error,
    required String conversationId,
    required ChatMessage assistantMessage,
  }) async {
    // 仅清理当前消息的文件处理指示器。
    onFileProcessingFinished?.call(assistantMessage.id);
    final action = prepareErrorAction(
      error,
      requestCancelled: isStopping(conversationId),
    );
    try {
      await _finishPrepareError(conversationId, assistantMessage, action);
    } catch (cleanupError, stackTrace) {
      FlutterLogger.log(
        '[ChatActions] finishPreparingMessage failed after send error: '
        '$cleanupError\n$stackTrace',
        tag: 'ChatActions',
      );
    }
    if (action != PrepareErrorAction.failed) return;
    onStreamError?.call(error.toString());
  }

  void _bindFileProcessingCallbacks() {
    messageGenerationService.onFileProcessingStarted = onFileProcessingStarted;
    messageGenerationService.onFileProcessingFinished =
        onFileProcessingFinished;
  }

  Future<int> _contextReadLimit(
    Assistant? assistant,
    Conversation conversation,
  ) {
    return resolveContextReadLimit(
      assistant: assistant,
      resolvePersistedCount: () =>
          chatService.resolveMessageCount(conversation.id),
    );
  }

  /// 解析生成上下文窗口大小。
  ///
  /// 当助手限制上下文时，不会调用 [resolvePersistedCount]。
  /// 否则会等待真实持久化数量，避免未知值（-1）被静默
  /// 限制为 [Assistant.maxContextMessageSize]。
  @visibleForTesting
  static Future<int> resolveContextReadLimit({
    required Assistant? assistant,
    required Future<int> Function() resolvePersistedCount,
  }) async {
    if ((assistant?.limitContextMessages ?? false) &&
        (assistant?.contextMessageSize ?? 0) > 0) {
      return contextReadLimit(assistant: assistant, persistedMessageCount: 0);
    }
    final count = await resolvePersistedCount();
    return contextReadLimit(assistant: assistant, persistedMessageCount: count);
  }

  @visibleForTesting
  static int contextReadLimit({
    required Assistant? assistant,
    required int persistedMessageCount,
  }) {
    assert(
      persistedMessageCount >= 0,
      'contextReadLimit requires a known message count; got '
      '$persistedMessageCount',
    );
    if ((assistant?.limitContextMessages ?? false) &&
        (assistant?.contextMessageSize ?? 0) > 0) {
      return assistant!.contextMessageSize.clamp(
        Assistant.minContextMessageSize,
        Assistant.maxContextMessageSize,
      );
    }
    return persistedMessageCount > 0
        ? persistedMessageCount
        : Assistant.maxContextMessageSize;
  }

  // ============================================================================
  // 重新生成消息
  // ============================================================================

  /// 在指定消息处重新生成回复。
  ///
  /// 返回包含成功状态和新助手消息的 [ChatActionResult]。
  /// UI 负责：
  /// - 添加新的助手占位消息
  /// - 出错时显示 Snackbar
  /// - 触感反馈
  Future<ChatActionResult> regenerateAtMessage({
    required ChatMessage message,
    required Conversation conversation,
    bool assistantAsNewReply = false,
    String? existingBranchId,
    bool allowImagesApiRouting = true,
    Assistant? assistantOverride,
    bool scheduled = false,
    ({String providerKey, String modelId})? modelOverride,
    ValueChanged<String>? onGenerationStarted,
  }) async {
    final claimToken = ++_sendInFlightClaimSerial;
    if (isSendInFlight(conversation.id)) {
      return ChatActionResult.inFlight();
    }
    _sendInFlightClaims[conversation.id] = claimToken;
    try {
      return await _regenerateAtMessageClaimed(
        message: message,
        conversation: conversation,
        assistantAsNewReply: assistantAsNewReply,
        existingBranchId: existingBranchId,
        allowImagesApiRouting: allowImagesApiRouting,
        assistantOverride: assistantOverride,
        scheduled: scheduled,
        modelOverride: modelOverride,
        onGenerationStarted: onGenerationStarted,
      );
    } finally {
      if (_sendInFlightClaims[conversation.id] == claimToken) {
        _sendInFlightClaims.remove(conversation.id);
      }
    }
  }

  Future<ChatActionResult> _regenerateAtMessageClaimed({
    required ChatMessage message,
    required Conversation conversation,
    bool assistantAsNewReply = false,
    String? existingBranchId,
    bool allowImagesApiRouting = true,
    Assistant? assistantOverride,
    bool scheduled = false,
    ({String providerKey, String modelId})? modelOverride,
    ValueChanged<String>? onGenerationStarted,
  }) async {
    // 避免跨异步间隙使用 BuildContext（此类持有 BuildContext）。
    final settings = contextProvider.read<SettingsProvider>();
    const truncateFuture = false;
    final assistantProvider = contextProvider.read<AssistantProvider>();
    // 在异步间隙前捕获审批服务引用
    ToolApprovalService? regenApprovalService;
    AskUserInteractionService? regenAskUserService;
    try {
      regenApprovalService = contextProvider.read<ToolApprovalService>();
    } catch (_) {}
    try {
      regenAskUserService = contextProvider.read<AskUserInteractionService>();
    } catch (_) {}
    try {
      await assistantProvider.loaded;
    } catch (e) {
      return ChatActionResult.error(e.toString());
    }
    final assistant = assistantOverride ?? assistantProvider.currentAssistant;

    await cancelStreaming(conversation);

    final isTemporaryConversation = chatService.isTemporaryConversation(
      conversation.id,
    );
    await chatService.ensureConversationTree(conversation.id);
    final tree = await chatService.loadConversationTree(conversation.id);
    final edge = tree?.edges[message.id];
    if (tree == null || edge == null) {
      return ChatActionResult.error('message_not_found');
    }
    final contextTargetId = message.role == 'assistant' && !assistantAsNewReply
        ? edge.parentMessageId
        : message.id;
    final completeMessages = contextTargetId == null
        ? const <ChatMessage>[]
        : await chatController.messagesForGenerationContext(
            conversation,
            maxMessages: await _contextReadLimit(assistant, conversation),
            throughRevisionId: contextTargetId,
          );
    if (contextTargetId != null &&
        completeMessages.every(
          (candidate) => candidate.id != contextTargetId,
        )) {
      return ChatActionResult.error('message_not_found');
    }

    // 获取模型配置
    final assistantId = assistant?.id;
    final modelConfig =
        modelOverride ??
        messageGenerationService.getModelConfig(
          settings,
          assistant,
          conversation,
        );

    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return ChatActionResult.noModel();
    }
    final providerKey = modelConfig.providerKey!;
    final modelId = modelConfig.modelId!;

    if (_hasUnsupportedAudioAttachments(
      messages: completeMessages,
      conversation: conversation.copyWith(truncateIndex: -1),
      settings: settings,
      providerKey: providerKey,
      modelId: modelId,
      maxRawTruncateIndex: -1,
    )) {
      return ChatActionResult.error('audio_attachment_unsupported');
    }

    final String? fromMessageId;
    final String? parentMessageId;
    if (message.role == 'assistant' && !assistantAsNewReply) {
      fromMessageId = edge.parentMessageId;
      parentMessageId = edge.parentMessageId;
    } else {
      fromMessageId = message.id;
      parentMessageId = message.id;
    }
    final ConversationTree createdTree;
    if (existingBranchId != null) {
      final existingBranch = tree.branches[existingBranchId];
      if (existingBranch == null) {
        return ChatActionResult.error('existing_branch_not_found');
      }
      if (existingBranch.tipMessageId != message.id) {
        return ChatActionResult.error('existing_branch_tip_mismatch');
      }
      createdTree = tree;
    } else {
      createdTree = await chatService.createMessageContinuationBranch(
        conversationId: conversation.id,
        fromMessageId: fromMessageId,
      );
    }
    viewModel.installConversationTree(createdTree);
    final begin = await messageGenerationService.beginAssistantGeneration(
      conversationId: conversation.id,
      modelId: modelId,
      providerKey: providerKey,
      truncateFuture: truncateFuture,
      parentMessageId: parentMessageId,
      branchId: createdTree.activeBranchId,
    );
    final assistantMessage = begin.assistantMessage;
    _registerGenerationRun(assistantMessage.id, begin.runId);
    _activeAssistantMessages.put(assistantMessage);

    // 在将消息加入列表前预先创建流式通知器，
    // 使 MessageListView 在首次渲染时就能识别到流式状态。
    streamController.markStreamingStarted(assistantMessage.id);

    final regenerationMessages = <ChatMessage>[
      ...completeMessages,
      assistantMessage,
    ];

    // 将已加载窗口保持在持久化生成消息附近，而不是用会话尾部
    // 替换较远的阅读位置（长会话中这可能会排除此流式版本）。
    if (chatController.currentConversation?.id == conversation.id &&
        await chatController.openAroundPersistedMessage(
          assistantMessage,
          truncateFollowingSlots: !isTemporaryConversation && truncateFuture,
        )) {
      viewModel.restoreMessageUiState();
    }
    onMessagesChanged?.call();

    _setConversationLoading(conversation.id, true);
    // 此时加载守卫拥有此会话的重入排除。
    _sendInFlightClaims.remove(conversation.id);

    onGenerationStarted?.call(assistantMessage.id);

    Future<ChatActionResult> generate() async {
      // 初始化推理
      final supportsReasoning = _isReasoningModel(providerKey, modelId);
      final enableReasoning =
          supportsReasoning &&
          _isReasoningEnabled(
            assistant?.thinkingBudget ?? settings.thinkingBudget,
          );
      _bindFileProcessingCallbacks();
      try {
        await messageGenerationService.initializeReasoningState(
          messageId: assistantMessage.id,
          enableReasoning: enableReasoning,
        );

        // 准备 API 消息
        final prepared = await messageGenerationService
            .prepareApiMessagesWithInjections(
              messages: regenerationMessages,
              currentConversation: conversation.copyWith(truncateIndex: -1),
              settings: settings,
              assistant: assistant,
              assistantId: assistantId,
              providerKey: providerKey,
              modelId: modelId,
              approvalService: regenApprovalService,
              askUserService: regenAskUserService,
              processingMessageId: assistantMessage.id,
            );

        // 构建用户图片路径
        final userImagePaths = messageGenerationService.buildUserImagePaths(
          input: null,
          lastUserImagePaths: prepared.lastUserImagePaths,
          settings: settings,
          providerKey: providerKey,
          modelId: modelId,
        );

        // 执行生成
        final ctx = messageGenerationService.buildGenerationContext(
          assistantMessage: assistantMessage,
          prepared: prepared,
          userImagePaths: userImagePaths,
          allowImagesApiRouting: allowImagesApiRouting,
          providerKey: providerKey,
          modelId: modelId,
          assistant: assistant,
          settings: settings,
          supportsReasoning: supportsReasoning,
          enableReasoning: enableReasoning,
          scheduled: scheduled,
          generateTitleOnFinish: false,
          generationRunId: begin.runId,
        );

        if (!_activeAssistantMessages.isActive(assistantMessage)) {
          return ChatActionResult.success(
            assistantMessage,
            generationRunId: begin.runId,
          );
        }
        await _executeGeneration(ctx);
        return ChatActionResult.success(
          assistantMessage,
          generationRunId: begin.runId,
        );
      } catch (e) {
        final action = prepareErrorAction(
          e,
          requestCancelled: isStopping(conversation.id),
        );
        await _finishPrepareError(conversation.id, assistantMessage, action);
        if (action != PrepareErrorAction.failed) {
          return ChatActionResult.success(
            assistantMessage,
            generationRunId: begin.runId,
          );
        }
        return ChatActionResult.error(e.toString());
      }
    }

    if (scheduled) {
      // 执行器必须能在准备阶段或非流式工具轮次等待输入时继续监视审批与取消，
      // 因此定时任务不等待生成结束。
      unawaited(generate());
      return ChatActionResult.success(
        assistantMessage,
        generationRunId: begin.runId,
      );
    }
    return generate();
  }

  Future<ChatActionResult> continueAssistantMessageAfterToolAnswer({
    required ChatMessage message,
    required Conversation conversation,
    bool allowImagesApiRouting = true,
  }) async {
    if (isSendInFlight(conversation.id)) {
      return ChatActionResult.inFlight();
    }

    final settings = contextProvider.read<SettingsProvider>();
    final assistantProvider = contextProvider.read<AssistantProvider>();
    ToolApprovalService? approvalService;
    AskUserInteractionService? askUserService;
    try {
      approvalService = contextProvider.read<ToolApprovalService>();
    } catch (_) {}
    try {
      askUserService = contextProvider.read<AskUserInteractionService>();
    } catch (_) {}
    try {
      await assistantProvider.loaded;
    } catch (e) {
      return ChatActionResult.error(e.toString());
    }
    final assistant = assistantProvider.currentAssistant;

    final visibleIndex = _messages.indexWhere(
      (candidate) => candidate.id == message.id,
    );
    if (visibleIndex < 0 || message.role != 'assistant') {
      return ChatActionResult.error('message_not_found');
    }
    final completeMessages = await chatController.messagesForGenerationContext(
      conversation,
      maxMessages: await _contextReadLimit(assistant, conversation),
      throughRevisionId: message.id,
    );
    final contextIndex = completeMessages.indexWhere(
      (candidate) => candidate.id == message.id,
    );
    if (contextIndex < 0) {
      return ChatActionResult.error('message_not_found');
    }

    final modelConfig = messageGenerationService.getModelConfig(
      settings,
      assistant,
      conversation,
    );
    if (modelConfig.providerKey == null || modelConfig.modelId == null) {
      return ChatActionResult.noModel();
    }
    final providerKey = modelConfig.providerKey!;
    final modelId = modelConfig.modelId!;

    final streamingMessage = _messages[visibleIndex].copyWith(
      isStreaming: true,
    );
    _activeAssistantMessages.put(streamingMessage);
    chatController.publishGenerationStarted(streamingMessage);
    await chatService.updateMessage(streamingMessage.id, isStreaming: true);
    onMessagesChanged?.call();
    _setConversationLoading(conversation.id, true);

    final supportsReasoning = _isReasoningModel(providerKey, modelId);
    final enableReasoning =
        supportsReasoning &&
        _isReasoningEnabled(
          assistant?.thinkingBudget ?? settings.thinkingBudget,
        );

    _bindFileProcessingCallbacks();
    try {
      final apiContextMessages = List<ChatMessage>.of(completeMessages);
      apiContextMessages[contextIndex] = streamingMessage.copyWith(content: '');
      final prepared = await messageGenerationService
          .prepareApiMessagesWithInjections(
            messages: apiContextMessages,
            currentConversation: conversation.copyWith(truncateIndex: -1),
            settings: settings,
            assistant: assistant,
            assistantId: assistant?.id,
            providerKey: providerKey,
            modelId: modelId,
            approvalService: approvalService,
            askUserService: askUserService,
            processingMessageId: streamingMessage.id,
          );

      final userImagePaths = messageGenerationService.buildUserImagePaths(
        input: null,
        lastUserImagePaths: prepared.lastUserImagePaths,
        settings: settings,
        providerKey: providerKey,
        modelId: modelId,
      );

      final ctx = messageGenerationService.buildGenerationContext(
        assistantMessage: streamingMessage,
        prepared: prepared,
        userImagePaths: userImagePaths,
        allowImagesApiRouting: allowImagesApiRouting,
        providerKey: providerKey,
        modelId: modelId,
        assistant: assistant,
        settings: settings,
        supportsReasoning: supportsReasoning,
        enableReasoning: enableReasoning,
        generateTitleOnFinish: false,
      );

      if (!_activeAssistantMessages.isActive(streamingMessage)) {
        return ChatActionResult.success(streamingMessage);
      }
      await _executeGeneration(ctx);
      return ChatActionResult.success(streamingMessage);
    } catch (e) {
      final action = prepareErrorAction(
        e,
        requestCancelled: isStopping(conversation.id),
      );
      await _finishPrepareError(conversation.id, streamingMessage, action);
      if (action != PrepareErrorAction.failed) {
        return ChatActionResult.success(streamingMessage);
      }
      return ChatActionResult.error(e.toString());
    }
  }

  // ============================================================================
  // 取消流式处理
  // ============================================================================

  /// 取消当前会话的活动流式处理。
  Future<void> cancelStreaming(Conversation? conversation) async {
    final cid = conversation?.id;
    if (cid == null) return;
    await cancelStreamingById(cid);
  }

  /// 取消 ID 为 [cid] 的会话的活动流式处理。
  Future<void> cancelStreamingById(String cid) {
    final existing = _cancelStreamingFutures[cid];
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = Future<void>.microtask(() => _cancelStreamingByIdOnce(cid))
        .whenComplete(() {
          if (identical(_cancelStreamingFutures[cid], operation)) {
            _cancelStreamingFutures.remove(cid);
            _setConversationLoading(cid, false);
          }
        });
    _cancelStreamingFutures[cid] = operation;
    return operation;
  }

  Future<void> _cancelStreamingByIdOnce(String cid) async {
    // 取消该会话的待处理工具审批请求以防止死锁。
    // 作用域按会话 ID 限定：静态删除入口
    // （cancelActiveGenerationFor / cancelActiveGenerationsForAssistant）
    // 可能取消后台会话，而另一个会话仍在流式处理；
    // 全局 cancelAll 会拒绝另一个会话的待处理审批。
    try {
      contextProvider.read<ToolApprovalService>().cancelForConversation(cid);
    } catch (_) {
      // ToolApprovalService 可能尚未注册
    }
    try {
      contextProvider.read<AskUserInteractionService>().cancelForConversation(
        cid,
      );
    } catch (_) {
      // AskUserInteractionService 可能尚未注册
    }

    // 取消时只清理本会话当前生成消息的处理指示器。
    final cancelIndicatorTarget = _activeAssistantMessages.cancellationTarget(
      cid,
      _messages,
    );
    if (cancelIndicatorTarget != null) {
      onFileProcessingFinished?.call(cancelIndicatorTarget.id);
    }

    // 在等待订阅前中止 HTTP 请求：屏障取消只有在生成器
    // 离开网络 await 后才完成；停滞连接否则会无限期阻塞。
    ChatApiService.cancelRequest(cid);

    // 仅取消当前会话的活动流
    final sub = _conversationStreams.remove(cid);

    // 立即结束可见的流式状态。会话在清理结束前会通过
    // [_cancelStreamingFutures] 保持内部忙碌。
    final visibleStreaming = _activeAssistantMessages.cancellationTarget(
      cid,
      _messages,
    );
    if (visibleStreaming != null) {
      streamController.markStreamingEnded(visibleStreaming.id);
      streamController.cleanupTimers(visibleStreaming.id);
      // 取消时清除自动重试倒计时。
      streamController.streamingContentNotifier.updateRetryStatus(
        visibleStreaming.id,
        null,
      );
      final index = _messages.indexWhere((m) => m.id == visibleStreaming.id);
      final visibleMessage = index == -1 ? visibleStreaming : _messages[index];
      if (chatController.publishTerminalMessage(visibleMessage)) {
        onMessagesChanged?.call();
      }
      streamController.removeStreamingNotifier(visibleStreaming.id);
    } else {
      chatController.publishGenerationState(cid, isGenerating: false);
    }
    onLoadingChanged?.call(cid, false);

    if (sub != null) {
      await _cancelSubscriptionWithTimeout(sub);
    }

    // 活动身份独立于当前已加载窗口。
    final streaming = _activeAssistantMessages.cancellationTarget(
      cid,
      _messages,
    );
    if (streaming != null) {
      // 标记流式结束，以允许 UI 再次重建
      streamController.markStreamingEnded(streaming.id);
      streamController.cleanupTimers(streaming.id);

      final idx = _messages.indexWhere((m) => m.id == streaming.id);
      var latestStreaming = idx == -1 ? streaming : _messages[idx];
      if (idx == -1) {
        final writer = _checkpointWriters[streaming.id];
        if (writer != null) {
          await writer.barrier();
          latestStreaming = _activeAssistantMessages[cid] ?? latestStreaming;
        }
      }

      streamController.finishReasoningIfNeeded(streaming.id);
      final state = _streamingStates[streaming.id];
      final parts = await _sanitizeAssistantImageParts(
        state == null ? latestStreaming.parts : _assistantPartsForState(state),
      );
      final finalizedMessage =
          (state == null
                  ? _messageWithCurrentReasoning(latestStreaming)
                  : _streamingMessageSnapshot(state))
              .copyWith(parts: parts, isStreaming: false);
      final backgroundTaskId = _backgroundTaskIdFor(streaming.id);
      var cancellationPersisted = false;
      try {
        await _finalizeStreamingCheckpoint(
          finalizedMessage,
          terminalState: _background.wasInterrupted(backgroundTaskId)
              ? GenerationRunState.interrupted
              : GenerationRunState.cancelled,
          errorCode: _background.wasInterrupted(backgroundTaskId)
              ? 'background_interrupted'
              : null,
        );
        cancellationPersisted = true;
      } finally {
        _clearGenerationRuntimeState(finalizedMessage);
        if (chatController.publishTerminalMessage(finalizedMessage)) {
          onMessagesChanged?.call();
        }
        streamController.removeStreamingNotifier(streaming.id);
        // 取消写入失败也必须释放后台任务，但不能通知为已持久化成功。
        await _background.finish(
          backgroundTaskId,
          BackgroundTaskOutcome.cancelled,
          resultPersisted: cancellationPersisted,
        );
      }

      // 如果流式输出包含行内 base64 图片，即使手动取消也要清理它们
      onScheduleImageSanitize?.call(
        streaming.id,
        latestStreaming.content,
        immediate: true,
      );
    } else {
      chatController.publishGenerationState(cid, isGenerating: false);
    }
  }

  // ============================================================================
  // 流式执行
  // ============================================================================

  /// 使用给定上下文执行生成。
  Future<void> _executeGeneration(stream_ctrl.GenerationContext ctx) async {
    final state = stream_ctrl.StreamingState(ctx);
    _streamingStates[state.messageId] = state;
    final assistant = ctx.assistant;
    final conversationId = state.conversationId;
    final existingSplit = streamController.getContentSplitData(state.messageId);
    if (existingSplit != null) {
      state.contentSplitOffsets = List<int>.of(existingSplit.offsets);
      state.reasoningCountAtSplit = List<int>.of(existingSplit.reasoningCounts);
      state.toolCountAtSplit = List<int>.of(existingSplit.toolCounts);
    }

    // 将此消息标记为正在流式处理，以抑制 UI 重建
    streamController.markStreamingStarted(state.messageId);
    _activeAssistantMessages.put(state.ctx.assistantMessage);
    _streamingToolEvents[state.messageId] = chatService
        .getToolEvents(state.messageId)
        .map((event) => Map<String, dynamic>.from(event))
        .toList();
    _checkpointWriters[state.messageId] =
        LatestWinsCheckpointWriter<_StreamingCheckpoint>(
          write: (checkpoint) => chatService.updateStreamingCheckpointSilent(
            checkpoint.message,
            checkpoint.toolEvents,
            generationRunId: checkpoint.generationRunId,
            checkpointSeq: checkpoint.checkpointSeq,
          ),
          onError: (error, stackTrace) {
            debugPrint('[StreamingCheckpoint] write failed: $error');
            debugPrint('$stackTrace');
          },
        );

    try {
      await _startIosBackgroundGeneration(ctx);
      if (!_activeAssistantMessages.isActive(ctx.assistantMessage)) {
        await _cancelIosBackgroundGeneration(_backgroundTaskId(ctx));
        return;
      }
      final runId = ctx.generationRunId;
      if (runId != null) {
        final cursor = _generationCheckpointCursors[state.messageId];
        if (cursor == null) {
          throw StateError('generation_run_cursor_missing');
        }
        final run = await chatService.transitionGenerationRun(
          id: runId,
          expectedState: cursor.state,
          expectedStateRevision: cursor.stateRevision,
          nextState: GenerationRunState.requesting,
        );
        state.generationStateRevision = run.stateRevision;
        cursor
          ..state = run.state
          ..stateRevision = run.stateRevision
          ..nextSeq = run.checkpointSeq + 1;
      }
      final stream = ChatApiService.sendMessageStream(
        config: ctx.config,
        modelId: ctx.modelId,
        messages: ctx.apiMessages,
        userImagePaths: ctx.userImagePaths,
        thinkingBudget:
            assistant?.thinkingBudget ?? ctx.settings.thinkingBudget,
        temperature: assistant?.temperature,
        topP: assistant?.topP,
        maxTokens: assistant?.maxTokens,
        tools: ctx.toolDefs.isEmpty ? null : ctx.toolDefs,
        onToolCall: ctx.onToolCall,
        extraHeaders: ctx.extraHeaders,
        extraBody: ctx.extraBody,
        stream: ctx.streamOutput,
        requestId: conversationId,
        conversationId: conversationId,
        allowImagesApiRouting: ctx.allowImagesApiRouting,
        ocrActive: ctx.ocrActive,
        parseMarkdownImageLinks: ctx.settings.sendMarkdownImageLinksAsImages,
      );

      // 替换先前的流：新请求尚未注册其取消令牌（这发生在监听时），
      // 因此 cancelRequest 仍指向旧流。先打断其网络等待，
      // 防止下方屏障取消在死连接上停滞。
      final previousSub = _conversationStreams.remove(conversationId);
      if (previousSub != null) {
        ChatApiService.cancelRequest(conversationId);
        await _cancelSubscriptionWithTimeout(previousSub);
      }
      final sub = listenSequentiallyToStream<StreamChunk>(
        stream: stream,
        onData: (chunk) => _handleStreamChunk(chunk, state),
        onError: (error, stackTrace) => _handleStreamError(error, state),
        onDone: () => _handleStreamDone(state),
      );
      _conversationStreams[conversationId] = sub;
    } catch (e) {
      await _handleStreamError(e, state);
    }
  }

  // ============================================================================
  // 流式分块处理器
  // ============================================================================

  /// 将统一事件投影到现有流式 UI，同时由 StreamChunkHandler 保留结构化结果。
  Future<void> _handleStreamChunk(
    StreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    if (chunk is RetryPending) {
      _setRetryStatus(state, chunk);
    } else {
      _setRetryStatus(state, null);
    }
    if (chunk is! RetryPending && chunk is! RetryAttemptStart) {
      await _markGenerationStreaming(state);
    }
    state.partsHandler.handle(chunk);
    switch (chunk) {
      case RetryPending() || RetryAttemptStart():
        break;
      case TextDelta(:final text):
        await _handleContentChunk(state, text);
        _scheduleStreamingCheckpoint(state);
      case ReasoningDelta(:final text, :final details):
        if (details != null) {
          streamController.setReasoningDetails(state.messageId, details);
        }
        if (text.isNotEmpty && state.ctx.supportsReasoning) {
          await _handleReasoningChunk(text, state);
        }
        _scheduleStreamingCheckpoint(state);
      case ToolCallStart(:final id, :final toolName):
        if (toolName.isNotEmpty) state.pendingToolNames[id] = toolName;
        await _handleToolCallsChunk(chunk, state);
        _scheduleStreamingCheckpoint(state);
      case ToolCallDelta(:final id, :final toolNameDelta):
        if (toolNameDelta.isNotEmpty) {
          state.pendingToolNames[id] =
              '${state.pendingToolNames[id] ?? ''}$toolNameDelta';
        }
      case ToolCallEnd():
        await _handleToolCallsChunk(chunk, state);
        _scheduleStreamingCheckpoint(state);
      case ServerToolStart(:final id, :final toolName):
        if (toolName.isNotEmpty) state.pendingToolNames[id] = toolName;
        await _handleToolCallsChunk(chunk, state);
        _scheduleStreamingCheckpoint(state);
      case ServerToolEnd() || ToolCallResult() || Annotations():
        await _handleToolResultsChunk(chunk, state);
        _scheduleStreamingCheckpoint(state);
      case Usage(:final usage):
        _applyUsage(state, usage);
      case ProviderArtifact(:final kind, :final payload):
        await chatService.setProviderArtifact(state.messageId, kind, payload);
      case Finish():
        await _handleStreamFinish(state);
      case ImageStart() ||
          ImageDelta() ||
          ImageSnapshot() ||
          ImageEnd() ||
          GeneratedFile():
        _publishAssistantParts(state);
        _scheduleStreamingCheckpoint(state);
      case TextStart() ||
          TextEnd() ||
          ReasoningStart() ||
          ReasoningEnd() ||
          ServerToolInputDelta() ||
          ServerToolInputEnd():
        break;
    }
  }

  void _applyUsage(stream_ctrl.StreamingState state, TokenUsage usage) {
    state.usage = (state.usage ?? const TokenUsage()).merge(usage);
    state.totalTokens = state.usage!.totalTokens;
  }

  Future<void> _markGenerationStreaming(
    stream_ctrl.StreamingState state,
  ) async {
    final runId = state.ctx.generationRunId;
    final expectedRevision = state.generationStateRevision;
    if (runId == null ||
        expectedRevision == null ||
        state.generationStreamingStarted) {
      return;
    }
    final run = await chatService.transitionGenerationRun(
      id: runId,
      expectedState: GenerationRunState.requesting,
      expectedStateRevision: expectedRevision,
      nextState: GenerationRunState.streaming,
    );
    state
      ..generationStateRevision = run.stateRevision
      ..generationStreamingStarted = true;
    final cursor = _generationCheckpointCursors[state.messageId];
    if (cursor != null) {
      cursor
        ..state = run.state
        ..stateRevision = run.stateRevision;
    }
  }

  /// 处理流中的推理分块。
  Future<void> _handleReasoningChunk(
    String reasoning,
    stream_ctrl.StreamingState state,
  ) async {
    await streamController.handleReasoningChunk(reasoning, state);
    _publishAssistantParts(state);
  }

  /// Handle tool calls chunk from stream.
  Future<void> _handleToolCallsChunk(
    StreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    await streamController.handleToolCallsChunk(
      chunk,
      state,
      updateReasoningSegmentsInDb: (String messageId, String json) async {
        // 本分块之后合并完整的思考快照。
      },
      setToolEventsInDb:
          (String messageId, List<Map<String, dynamic>> events) async {
            _streamingToolEvents[messageId] = events
                .map((event) => Map<String, dynamic>.from(event))
                .toList();
          },
      getToolEventsFromDb: _copyToolEvents,
    );
    _publishAssistantParts(state);
  }

  /// Handle tool results chunk from stream.
  Future<void> _handleToolResultsChunk(
    StreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    await streamController.handleToolResultsChunk(
      chunk,
      state,
      upsertToolEventInDb:
          (
            String messageId, {
            required String id,
            required String name,
            required Map<String, dynamic> arguments,
            String? content,
            Map<String, dynamic>? metadata,
          }) async {
            _upsertStreamingToolEvent(
              messageId,
              id: id,
              name: name,
              arguments: arguments,
              content: content,
              metadata: metadata,
            );
          },
    );
    _publishAssistantParts(state);
  }

  void _publishAssistantParts(stream_ctrl.StreamingState state) {
    if (!state.ctx.streamOutput || state.finishHandled) return;
    streamController.streamingContentNotifier.getNotifier(state.messageId);
    streamController.streamingContentNotifier.updateContent(
      state.messageId,
      _transformAssistantContent(state),
      state.totalTokens,
      parts: _assistantPartsForState(state),
    );
  }

  /// 处理尚未结束的文字增量。
  Future<void> _handleContentChunk(
    stream_ctrl.StreamingState state,
    String chunkContent,
  ) async {
    // 完成收尾后不再修改本轮状态。
    if (state.finishHandled) return;

    final messageId = state.messageId;
    final conversationId = state.conversationId;

    _recordContent(state, chunkContent);
    state.streamStartedAt ??= DateTime.now();

    // 正文开始时结束当前思考片段。
    if (state.ctx.streamOutput && chunkContent.isNotEmpty) {
      await _finishReasoningOnContent(state);
    }

    _scheduleIosBackgroundGenerationUpdate(state);

    // 异步处理期间可能已完成；不能再创建计时器，用旧片段覆盖终态。
    if (state.finishHandled) return;

    // 通过流控制器按可见文字进度发布部件。
    if (state.ctx.streamOutput) {
      streamController.scheduleThrottledUpdate(
        messageId,
        conversationId,
        () => _transformAssistantContent(state),
        partsBuilder: (visibleText) =>
            _assistantPartsForState(state, visibleText: visibleText),
        totalTokens: state.totalTokens,
        promptTokens: state.usage?.promptTokens,
        completionTokens: state.usage?.completionTokens,
        cachedTokens: state.usage?.cachedTokens,
        durationMs: _elapsedMsFrom(state.streamStartedAt),
        updateMessageInList: (id, content, tokens) {
          onContentUpdated?.call(id, content, tokens);
        },
      );
    }
  }

  /// 正文到达时完成思考片段。
  void _recordContent(stream_ctrl.StreamingState state, String chunkContent) {
    if (chunkContent.isNotEmpty) {
      state.fullContentRaw += chunkContent;
    }
  }

  Future<void> _finishReasoningOnContent(
    stream_ctrl.StreamingState state,
  ) async {
    await streamController.finishReasoningAndPersist(
      state.messageId,
      updateReasoningInDb:
          (
            String messageId, {
            String? reasoningText,
            DateTime? reasoningFinishedAt,
            String? reasoningSegmentsJson,
          }) async {
            // 完整推理快照在此分块后合并。
          },
    );
  }

  /// 处理流完成（isDone == true）。
  Future<void> _handleStreamFinish(stream_ctrl.StreamingState state) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;
    final autoCollapseThinking =
        (!state.ctx.streamOutput && state.bufferedReasoning.isNotEmpty)
        ? contextProvider.read<SettingsProvider>().autoCollapseThinking
        : null;

    // 工具仍在执行时不能结束本轮。
    final hasLoadingTool =
        (streamController.toolParts[messageId]?.any((p) => p.loading) ?? false);
    if (hasLoadingTool) {
      return;
    }

    // 最终检查点前补齐非流式的思考内容。
    if (!state.ctx.streamOutput && state.bufferedReasoning.isNotEmpty) {
      final now = DateTime.now();
      final startAt = state.reasoningStartAt ?? now;
      streamController.reasoning[messageId] = stream_ctrl.ReasoningData()
        ..text = state.bufferedReasoning
        ..startAt = startAt
        ..finishedAt = now
        ..expanded = !(autoCollapseThinking ?? false);
    }

    // Track the _finishStreaming future so _handleStreamDone can await it
    // if it fires concurrently (stream.onDone can fire while we're still
    // awaiting async work inside _finishStreaming).
    final finishFuture = _finishStreaming(state);
    _finishStreamingFutures[messageId] = finishFuture;
    await finishFuture;
    _finishStreamingFutures.remove(messageId);

    // 必要时通知后台生成已结束。
    if (!state.finishHandled) {
      onStreamFinished?.call(conversationId);
    }

    // This finish handler runs inside the sequential drain, so awaiting the
    // barrier cancel here would wait on this very drain and never complete.
    // The source stream is finishing on its own (a done chunk arrived);
    // onDone performs the remaining cleanup, so only drop the map entry.
    _conversationStreams.remove(conversationId);
  }

  /// 结束流式处理并持久化最终状态。
  Future<void> _finishStreaming(
    stream_ctrl.StreamingState state, {
    bool generateTitle = true,
  }) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;

    // 标记流式结束，以允许 UI 再次重建
    streamController.markStreamingEnded(messageId);

    // 先让平滑缓冲按正常节奏追上，避免 cleanup 在结束帧一次性倾倒尾部。
    await streamController.drainSmoothStream(messageId);

    // 清理流式节流计时器并刷新最终内容
    streamController.cleanupTimers(messageId);

    final shouldGenerateTitle =
        generateTitle && state.ctx.generateTitleOnFinish && !state.titleQueued;
    if (state.finishHandled) {
      if (shouldGenerateTitle) {
        state.titleQueued = true;
        onMaybeGenerateTitle?.call(conversationId);
      }
      return;
    }
    state.finishHandled = true;
    if (shouldGenerateTitle) {
      state.titleQueued = true;
    }
    streamController.finishReasoningIfNeeded(messageId);

    // 将超长行内 base64 图片替换为本地文件，避免卡顿
    final processedContent = _transformAssistantContent(state);

    // 计算最终持续时间
    final finalDurationMs = _elapsedMsFrom(state.streamStartedAt);
    final finalPromptTokens = state.usage?.promptTokens;
    final finalCompletionTokens = state.usage?.completionTokens;
    final finalCachedTokens = state.usage?.cachedTokens;

    // 在异步操作前将最终内容刷新到流式通知器。
    // 这样任何中间重建（例如 isProcessingFiles 变化或
    // onDone 并发触发）仍能通过基于通知器的流式路径显示正确内容。
    streamController.streamingContentNotifier.updateContent(
      messageId,
      processedContent,
      state.totalTokens,
      parts: _assistantPartsForState(state),
      contentSplitOffsets: state.contentSplitOffsets,
      reasoningCountAtSplit: state.reasoningCountAtSplit,
      toolCountAtSplit: state.toolCountAtSplit,
      promptTokens: finalPromptTokens,
      completionTokens: finalCompletionTokens,
      cachedTokens: finalCachedTokens,
      durationMs: finalDurationMs,
    );

    final sanitizedParts = await _sanitizeAssistantImageParts(
      _assistantPartsForState(state),
    );
    final finalizedMessage = _streamingMessageSnapshot(state).copyWith(
      parts: sanitizedParts,
      totalTokens: state.totalTokens,
      isStreaming: false,
      promptTokens: finalPromptTokens,
      completionTokens: finalCompletionTokens,
      cachedTokens: finalCachedTokens,
      durationMs: finalDurationMs,
    );
    try {
      await _finalizeStreamingCheckpoint(
        finalizedMessage,
        terminalState: GenerationRunState.completed,
      );
      state.terminalPersisted = true;

      // 等下游把后台执行接过去再释放本次生成的资源，
      // 而不是等它整段跑完。
      await onAssistantMessageFinished?.call(finalizedMessage);

      if (shouldGenerateTitle) {
        onMaybeGenerateTitle?.call(conversationId);
      }

      // 触发摘要生成检查（实际逻辑在 HomeViewModel 中）
      onMaybeGenerateSummary?.call(conversationId);

      // 最终助手回复存储后触发后续建议。
      onMaybeGenerateSuggestions?.call(conversationId);
    } finally {
      // 完成写入失败会紧接着走 _handleStreamError；
      // 在那次失败结果也落盘前先保留后台任务。
      if (state.terminalPersisted) {
        await _finishIosBackgroundGeneration(
          _backgroundTaskId(state.ctx),
          success: true,
          replyPreview: ThinkingTagParser.parseWithRanges(
            finalizedMessage.content,
          ).visibleContent,
        );
      }
      // UI 生命周期清理独立于最终持久化是否成功。
      if (chatController.publishTerminalMessage(finalizedMessage)) {
        onMessagesChanged?.call();
      }
      streamController.removeStreamingNotifier(messageId);
      _setConversationLoading(
        conversationId,
        false,
        finishedMessageId: messageId,
      );
      // 最终控件通常比流式控件更高；在 isGenerating 变为 false 后
      // 再固定一次，使布局阶段的跟随不会错过高度变化。
      onStreamFinished?.call(conversationId);
    }
  }

  /// 处理流错误。
  Future<void> _handleStreamError(
    dynamic e,
    stream_ctrl.StreamingState state,
  ) async {
    final messageId = state.messageId;
    final conversationId = state.conversationId;
    // 重试等待期间取消/结束：清掉倒计时 UI，且用户取消不算生成失败。
    _setRetryStatus(state, null);
    if (isCancelledGenerationError(
      e,
      requestCancelled: isStopping(conversationId),
    )) {
      return;
    }
    final errorText = e.toString();

    // 出错时只清理当前助手消息的处理指示器。
    onFileProcessingFinished?.call(messageId);

    // 标记流式结束，以允许 UI 再次重建
    streamController.markStreamingEnded(messageId);

    streamController.cleanupTimers(messageId);
    streamController.finishReasoningIfNeeded(messageId);
    final partialContent = state.fullContentRaw.isEmpty
        ? ''
        : _transformAssistantContent(state, state.fullContentRaw);
    final errorParts = assistantPartsForStreamError(
      parts: _assistantPartsForState(state),
      partialContent: partialContent,
      errorText: errorText,
    );
    final errorMessage = _streamingMessageSnapshot(state).copyWith(
      parts: errorParts,
      totalTokens: state.totalTokens,
      isStreaming: false,
    );
    try {
      await _finalizeStreamingCheckpoint(
        errorMessage,
        terminalState: GenerationRunState.failed,
        errorCode: 'generation_failed',
      );
      state.terminalPersisted = true;
    } finally {
      _clearGenerationRuntimeState(errorMessage);
      if (chatController.publishTerminalMessage(errorMessage)) {
        onMessagesChanged?.call();
      }
      streamController.removeStreamingNotifier(messageId);
      _setConversationLoading(
        conversationId,
        false,
        finishedMessageId: messageId,
      );
      // 此错误处理器返回后，顺序流排空逻辑拥有源流取消。
      // 此处再次进入其屏障取消会等待当前处理器本身，
      // 并阻止下方 UI 错误回调触发。
      _conversationStreams.remove(conversationId);
      onStreamError?.call(errorText);
      onStreamFinished?.call(conversationId);
      await _finishIosBackgroundGeneration(
        _backgroundTaskId(state.ctx),
        success: false,
        resultPersisted: state.terminalPersisted,
      );
    }
  }

  /// 处理流完成回调。
  Future<void> _handleStreamDone(stream_ctrl.StreamingState state) async {
    final conversationId = state.conversationId;
    final messageId = state.messageId;

    // 完成时只清理当前助手消息的处理指示器（以防准备阶段未收尾）。
    onFileProcessingFinished?.call(messageId);

    // 确保流式状态被标记为已结束
    streamController.markStreamingEnded(messageId);

    // 如果 onDone 直接接管完成流程，也先排空平滑缓冲。
    await streamController.drainSmoothStream(messageId);
    streamController.cleanupTimers(messageId);

    // 如果 _finishStreaming 已在执行中（由 _handleStreamFinish 启动），
    // 在移除通知器或触发重建前等待其完成。
    // 这可以防止在 _finishStreaming 尚未更新 _messages[index] 时，
    // 通知器已被移除且重建已被触发的竞态。
    final inFlight = _finishStreamingFutures[messageId];
    if (inFlight != null) {
      await inFlight;
    } else if (_loadingConversationIds.contains(conversationId)) {
      await _finishStreaming(
        state,
        generateTitle: state.ctx.generateTitleOnFinish,
      );
    }
    // 幂等操作：即使跳过了 _finishStreaming，也确保移除通知器
    streamController.removeStreamingNotifier(messageId);
    onStreamFinished?.call(conversationId);
    // 源流已经完成，且此处理器运行在顺序排空逻辑内；
    // 在此等待屏障取消会等待当前排空流程本身，永远无法完成，
    // 所以只移除映射条目。
    _conversationStreams.remove(conversationId);
  }

  // ============================================================================
  // 刷新进度（用于切换会话）
  // ============================================================================

  /// 持久化最新进行中的助手消息内容和推理。
  Future<void> flushConversationProgress(Conversation? conversation) async {
    final cid = conversation?.id;
    if (cid == null || _messages.isEmpty) return;

    // 在当前会话中查找最新的流式助手消息
    ChatMessage? streaming;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role == 'assistant' && m.isStreaming && m.conversationId == cid) {
        streaming = m;
        break;
      }
    }
    if (streaming == null) return;

    // 优先使用完整累积流文本，而不是可能仍停留在内存消息控件上的
    // 打字机前缀。
    final latestContent =
        streamController.getPendingStreamContent(streaming.id) ??
        streaming.content;
    // 如果内存中跟踪了推理进度，也一并捕获
    final r = streamController.reasoning[streaming.id];
    final segs = streamController.reasoningSegments[streaming.id];

    final splits = streamController.getContentSplitData(streaming.id);
    final details = streamController.reasoningDetails[streaming.id];
    final reasoningSegmentsJson =
        segs != null || splits != null || details != null
        ? streamController.serializeReasoningSegmentsWithSplits(
            segs ?? const [],
            contentSplitOffsets: splits?.offsets,
            reasoningCountAtSplit: splits?.reasoningCounts,
            toolCountAtSplit: splits?.toolCounts,
            reasoningDetails: details,
          )
        : streaming.reasoningSegmentsJson;
    final state = _streamingStates[streaming.id];
    // 列表快照可能只包含打字进度，刷新时必须取流的最新完整部件。
    final snapshot = state != null
        ? _streamingMessageSnapshot(state)
        : streaming.copyWith(
            content: latestContent,
            reasoningText: r?.text,
            reasoningStartAt: r?.startAt,
            reasoningFinishedAt: r?.finishedAt,
            reasoningSegmentsJson: reasoningSegmentsJson,
          );
    final writer = _checkpointWriters[streaming.id];
    if (writer == null) {
      await chatService.updateStreamingCheckpointSilent(
        snapshot,
        _copyToolEvents(streaming.id),
      );
    } else {
      writer.add(() => _createStreamingCheckpoint(snapshot));
      await writer.barrier();
    }
    // 即使用户在流式过程中离开，也确保转换所有行内 data URL
    onScheduleImageSanitize?.call(streaming.id, latestContent, immediate: true);
  }
}
