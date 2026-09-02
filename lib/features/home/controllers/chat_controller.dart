import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../../../core/database/chat_database_repository.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/screen_wakelock.dart';
import 'message_render_model.dart';

/// 会话切换的初始窗口，由
/// [ChatController.fetchConversationWindow] 加载，
/// 并由 [ChatController.commitConversationWindow] 原子安装。
class FetchedConversationWindow {
  const FetchedConversationWindow({
    required this.conversation,
    required this.page,
    required this.lazyHistoryEnabled,
  });

  final Conversation conversation;
  final LoadedTimelinePage? page;
  final bool lazyHistoryEnabled;
}

/// 管理主页会话状态的控制器。
///
/// 此控制器负责：
/// - 当前会话和消息列表管理
/// - 消息组的版本选择
/// - 会话加载状态（用于流式处理）
/// - 会话流订阅
/// - 消息分组和折叠逻辑
class ChatController extends ChangeNotifier {
  factory ChatController({
    required ChatService chatService,
    bool lazyHistoryEnabled = true,
  }) {
    return ChatController._(chatService, lazyHistoryEnabled);
  }

  ChatController._(this._chatService, this._lazyHistoryEnabled) {
    _chatService.addListener(_syncCurrentConversationWithService);
  }

  final ChatService _chatService;

  // ============================================================================
  // 状态字段
  // ============================================================================

  /// 当前活动会话。
  Conversation? _currentConversation;
  Conversation? get currentConversation => _currentConversation;

  /// 当前会话中的消息。
  List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => _messages;

  /// [_messages] 在持久化会话中的起始索引。
  int _loadedStartIndex = 0;
  int get loadedStartIndex => _loadedStartIndex;

  /// 当前会话的持久化消息总数。
  int _totalMessageCount = 0;
  int get totalMessageCount => _totalMessageCount;

  bool get hasMoreBefore => _loadedStartIndex > 0;
  bool get hasMoreAfter =>
      _loadedStartIndex + _messages.length < _totalMessageCount;

  /// 初始窗口或围绕消息的窗口加载是否正在进行。
  bool _isLoadingWindow = false;
  bool get isLoadingWindow => _isLoadingWindow;

  /// 最新窗口加载的序列号；只有它可以清除 [_isLoadingWindow]。
  int _windowLoadSerial = 0;

  bool _lazyHistoryEnabled;
  bool get lazyHistoryEnabled => _lazyHistoryEnabled;

  /// 空闲缓存回填的槽位预算：当前会话的缓存上限
  /// 是其完整历史或此阈值中较小者。
  @visibleForTesting
  static const int idleCacheBackfillSlotLimit = 5000;

  /// 缓存的折叠消息（在 notifyListeners 时失效）。
  Map<String, List<ChatMessage>>? _groupCache;
  List<MessageRenderModel>? _renderModelsCache;

  /// 当前正在生成（流式处理）的会话 ID。
  final Set<String> _loadingConversationIds = <String>{};
  Set<String> get loadingConversationIds => _loadingConversationIds;
  bool _screenWakelockAcquired = false;

  /// 每个会话的活动流订阅。
  final Map<String, StreamSubscription<dynamic>> _conversationStreams =
      <String, StreamSubscription<dynamic>>{};
  Map<String, StreamSubscription<dynamic>> get conversationStreams =>
      _conversationStreams;

  // ============================================================================
  // 获取器
  // ============================================================================

  /// 当前会话是否正在生成。
  bool get isCurrentConversationLoading {
    final cid = _currentConversation?.id;
    if (cid == null) return false;
    return _loadingConversationIds.contains(cid);
  }

  /// 获取 ChatService 实例。
  ChatService get chatService => _chatService;

  void _syncCurrentConversationWithService() {
    final conversation = _currentConversation;
    if (conversation == null) return;
    if (_chatService.getConversation(conversation.id) != null) return;
    _clearCurrentConversationState();
    notifyListeners();
  }

  // ============================================================================
  // 会话管理
  // ============================================================================

  /// 设置新建的空草稿，而不打开持久化窗口。
  void setDraftConversation(Conversation conversation) {
    // 未知数量（-1）不等于“有消息”；仅在已知非零时才拒绝。
    if (_chatService.isMessageCountKnown(conversation.id) &&
        _chatService.getMessageCount(conversation.id) != 0) {
      throw StateError('persisted_conversation_requires_async_open');
    }
    _currentConversation = conversation;
    _messages = [];
    _loadedStartIndex = 0;
    _totalMessageCount = 0;
    notifyListeners();
  }

  Future<void> setCurrentConversationAndLoad(Conversation? conversation) async {
    _currentConversation = conversation;
    _messages = [];
    _loadedStartIndex = 0;
    _totalMessageCount = 0;
    if (conversation != null) {
      await _loadInitialMessageWindow(conversation.id);
      if (_currentConversation?.id != conversation.id) return;
    }
    notifyListeners();
  }

  /// 会话切换的获取阶段：为 [conversation] 加载初始窗口，
  /// 但不修改任何当前状态。使用 [commitConversationWindow]
  /// 安装结果。
  Future<FetchedConversationWindow> fetchConversationWindow(
    Conversation conversation,
  ) async {
    final lazyHistoryEnabled = _lazyHistoryEnabled;
    final page = lazyHistoryEnabled
        ? await _chatService.loadTimelinePage(
            conversation.id,
            limit: ChatService.defaultTimelineInitialSlots,
          )
        : await _fetchCompleteTimeline(conversation.id);
    return FetchedConversationWindow(
      conversation: conversation,
      page: page,
      lazyHistoryEnabled: lazyHistoryEnabled,
    );
  }

  /// 会话切换的提交阶段：安装此前由 [fetchConversationWindow]
  /// 获取的窗口。它会取代任何进行中的窗口加载，
  /// 因此迟到的分页和加载标志清除都会失效。
  void commitConversationWindow(FetchedConversationWindow fetched) {
    _windowLoadSerial++;
    _isLoadingWindow = false;
    _currentConversation = fetched.conversation;
    _replaceWindow(fetched.page);
    notifyListeners();
    _scheduleIdleCacheBackfill(fetched.conversation.id);
    if (fetched.lazyHistoryEnabled != _lazyHistoryEnabled) {
      unawaited(
        setLazyHistoryEnabled(
          _lazyHistoryEnabled,
          forceReload: true,
        ).catchError((Object error, StackTrace stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              context: ErrorDescription(
                'while reconciling a prefetched chat history window',
              ),
            ),
          );
        }),
      );
    }
  }

  /// 更新当前会话引用（例如标题变化后）。
  void updateCurrentConversation(Conversation? conversation) {
    _currentConversation = conversation;
    notifyListeners();
  }

  /// 创建新会话并将其设为当前会话。
  Future<Conversation> createNewConversation({
    required String title,
    String? assistantId,
  }) async {
    final conversation = await _chatService.createDraftConversation(
      title: title,
      assistantId: assistantId,
    );
    _currentConversation = conversation;
    _messages = [];
    _loadedStartIndex = 0;
    _totalMessageCount = 0;
    notifyListeners();
    return conversation;
  }

  /// 清除当前会话状态。
  void clearCurrentConversation() {
    _clearCurrentConversationState();
    notifyListeners();
  }

  void _clearCurrentConversationState() {
    _currentConversation = null;
    _messages = [];
    _loadedStartIndex = 0;
    _totalMessageCount = 0;
  }

  Future<void> _loadInitialMessageWindow(String conversationId) async {
    final serial = ++_windowLoadSerial;
    final lazyHistoryEnabled = _lazyHistoryEnabled;
    _isLoadingWindow = true;
    try {
      final page = lazyHistoryEnabled
          ? await _chatService.loadTimelinePage(
              conversationId,
              limit: ChatService.defaultTimelineInitialSlots,
            )
          : await _fetchCompleteTimeline(conversationId);
      // 如果加载期间会话发生变化，则丢弃该页。
      if (serial != _windowLoadSerial ||
          _currentConversation?.id != conversationId ||
          _lazyHistoryEnabled != lazyHistoryEnabled) {
        return;
      }
      _replaceWindow(page);
    } finally {
      if (serial == _windowLoadSerial) _isLoadingWindow = false;
    }
    invalidateCache();
    _scheduleIdleCacheBackfill(conversationId);
  }

  Future<void> setLazyHistoryEnabled(
    bool enabled, {
    bool forceReload = false,
  }) async {
    if (_lazyHistoryEnabled == enabled && !forceReload) return;
    final previousEnabled = _lazyHistoryEnabled;
    _lazyHistoryEnabled = enabled;
    final conversation = _currentConversation;
    if (conversation == null) {
      notifyListeners();
      return;
    }

    final serial = ++_windowLoadSerial;
    _isLoadingWindow = true;
    notifyListeners();
    try {
      final page = enabled
          ? await _chatService.loadTimelinePage(
              conversation.id,
              limit: ChatService.defaultLoadedWindowMax,
            )
          : await _fetchCompleteTimeline(conversation.id);
      if (serial != _windowLoadSerial ||
          _currentConversation?.id != conversation.id ||
          _lazyHistoryEnabled != enabled) {
        return;
      }
      _replaceWindow(page);
      if (serial != _windowLoadSerial ||
          _currentConversation?.id != conversation.id ||
          _lazyHistoryEnabled != enabled) {
        return;
      }
      notifyListeners();
    } catch (_) {
      if (serial == _windowLoadSerial && _lazyHistoryEnabled == enabled) {
        _lazyHistoryEnabled = previousEnabled;
      }
      rethrow;
    } finally {
      if (serial == _windowLoadSerial) {
        _isLoadingWindow = false;
        notifyListeners();
      }
    }
  }

  Future<LoadedTimelinePage?> _fetchCompleteTimeline(
    String conversationId,
  ) async {
    const pageSize = ChatService.defaultLoadedWindowMax;
    final first = await _chatService.loadTimelinePage(
      conversationId,
      fromStart: true,
      limit: pageSize,
    );
    if (first == null || !first.hasMoreAfter) return first;

    final slots = <LoadedTimelineSlot>[...first.slots];
    var page = first;
    while (page.hasMoreAfter) {
      if (page.slots.isEmpty) {
        throw StateError('complete_history_empty_page:$conversationId');
      }
      final next = await _chatService.loadTimelinePage(
        conversationId,
        afterRevisionId: page.slots.last.message.id,
        limit: pageSize,
      );
      if (next == null || next.slots.isEmpty) {
        throw StateError('complete_history_incomplete:$conversationId');
      }
      if (next.stateRevision != first.stateRevision ||
          next.totalSlotCount != first.totalSlotCount) {
        throw StateError('complete_history_changed:$conversationId');
      }
      slots.addAll(next.slots);
      page = next;
    }
    if (slots.length != first.totalSlotCount) {
      throw StateError('complete_history_count:$conversationId');
    }
    return LoadedTimelinePage(
      conversationId: first.conversationId,
      stateRevision: first.stateRevision,
      contextStartRevisionId: first.contextStartRevisionId,
      slots: slots,
      hasMoreBefore: false,
      hasMoreAfter: false,
      totalSlotCount: first.totalSlotCount,
    );
  }

  /// 排队对 [conversationId] 的静默完整缓存回填，
  /// 在 UI 空闲后运行（即新打开窗口首帧之后）。
  void _scheduleIdleCacheBackfill(String conversationId) {
    final Future<void> task;
    try {
      task = SchedulerBinding.instance.scheduleTask(
        () => backfillCurrentConversationCache(conversationId),
        Priority.idle,
        debugLabel: 'chat.idleCacheBackfill',
      );
    } catch (_) {
      // 没有调度器绑定（纯单元测试）：预热是可选的。
      return;
    }
    unawaited(task.catchError((Object _) {}));
  }

  /// 静默预热当前会话的完整消息缓存。
  ///
  /// 仅缓存预热：不通知监听器，任何保护条件失败都会跳过加载。
  /// 保护条件：会话必须仍是当前会话，其槽位数量必须不超过
  /// [idleCacheBackfillSlotLimit]，且不能正在生成
  /// （流式写入拥有单一连接队列）。当前会话免受缓存驱逐；
  /// 如果回填使缓存超出预算，尾部截断（缓存方案第 13 项）
  /// 会保留最新条目。
  @visibleForTesting
  Future<void> backfillCurrentConversationCache(String conversationId) async {
    if (_currentConversation?.id != conversationId) return;
    if (_totalMessageCount > idleCacheBackfillSlotLimit) return;
    if (isConversationLoading(conversationId)) return;
    if (_chatService.isConversationFullyCached(conversationId)) return;
    try {
      await _chatService.loadMessages(conversationId);
    } catch (_) {
      // 预热失败不会造成用户可见损失。
    }
  }

  void _replaceWindow(LoadedTimelinePage? page) {
    if (page == null) {
      _messages = <ChatMessage>[];
      _loadedStartIndex = 0;
      _totalMessageCount = 0;
      return;
    }
    _messages = page.slots.map((slot) => slot.message).toList(growable: true);
    _loadedStartIndex = page.slots.isEmpty
        ? 0
        : page.slots.first.identity.logicalIndex;
    _totalMessageCount = page.totalSlotCount;
    invalidateCache();
  }

  Future<bool> loadMoreBefore({
    int limit = ChatService.defaultHistoryPageSize,
  }) async {
    if (limit <= 0) return false;
    final conversation = _currentConversation;
    if (conversation == null || _messages.isEmpty || !hasMoreBefore) {
      return false;
    }
    final page = await _chatService.loadTimelinePage(
      conversation.id,
      beforeRevisionId: _messages.first.id,
      limit: limit,
    );
    if (_currentConversation?.id != conversation.id) return false;
    if (page == null || page.slots.isEmpty) return false;
    final existing = {for (final message in _messages) message.id};
    _messages.insertAll(0, [
      for (final slot in page.slots)
        if (existing.add(slot.message.id)) slot.message,
    ]);
    _loadedStartIndex = page.slots.first.identity.logicalIndex;
    _totalMessageCount = page.totalSlotCount;
    if (_lazyHistoryEnabled &&
        _messages.length > ChatService.defaultLoadedWindowMax) {
      _messages.removeRange(
        ChatService.defaultLoadedWindowMax,
        _messages.length,
      );
    }
    invalidateCache();
    notifyListeners();
    return true;
  }

  Future<bool> loadMoreAfter({
    int limit = ChatService.defaultHistoryPageSize,
  }) async {
    if (limit <= 0) return false;
    final conversation = _currentConversation;
    if (conversation == null || _messages.isEmpty || !hasMoreAfter) {
      return false;
    }
    final page = await _chatService.loadTimelinePage(
      conversation.id,
      afterRevisionId: _messages.last.id,
      limit: limit,
    );
    if (_currentConversation?.id != conversation.id) return false;
    if (page == null || page.slots.isEmpty) return false;
    final existing = {for (final message in _messages) message.id};
    _messages.addAll([
      for (final slot in page.slots)
        if (existing.add(slot.message.id)) slot.message,
    ]);
    _totalMessageCount = page.totalSlotCount;
    if (_lazyHistoryEnabled &&
        _messages.length > ChatService.defaultLoadedWindowMax) {
      final removeCount = _messages.length - ChatService.defaultLoadedWindowMax;
      _messages.removeRange(0, removeCount);
      _loadedStartIndex += removeCount;
    }
    invalidateCache();
    notifyListeners();
    return true;
  }

  Future<bool> loadStartWindow() async {
    final conversation = _currentConversation;
    if (conversation == null) return false;
    if (!_lazyHistoryEnabled) return _messages.isNotEmpty;
    final page = await _chatService.loadTimelinePage(
      conversation.id,
      fromStart: true,
      limit: ChatService.defaultLoadedWindowMax,
    );
    // 如果加载期间会话发生变化，则丢弃该页。
    if (_currentConversation?.id != conversation.id) return false;
    _replaceWindow(page);
    notifyListeners();
    return _messages.isNotEmpty;
  }

  Future<bool> loadEndWindow() async {
    final conversation = _currentConversation;
    if (conversation == null) return false;
    if (!_lazyHistoryEnabled) return _messages.isNotEmpty;
    final page = await _chatService.loadTimelinePage(
      conversation.id,
      limit: ChatService.defaultLoadedWindowMax,
    );
    // 如果加载期间会话发生变化，则丢弃该页。
    if (_currentConversation?.id != conversation.id) return false;
    _replaceWindow(page);
    notifyListeners();
    return _messages.isNotEmpty;
  }

  Future<bool> loadUntilMessageVisible(
    String messageId, {
    int pageSize = ChatService.defaultHistoryPageSize,
    int maxPages = 256,
  }) async {
    if (_messages.any((message) => message.id == messageId)) return true;

    final loaded = await loadWindowAroundMessage(
      messageId,
      leadingContext: pageSize,
    );
    return loaded && _messages.any((message) => message.id == messageId);
  }

  Future<bool> loadWindowAroundMessage(
    String messageId, {
    int leadingContext = ChatService.defaultHistoryPageSize,
  }) async {
    final conversation = _currentConversation;
    if (conversation == null) return false;
    if (!_lazyHistoryEnabled) {
      await setLazyHistoryEnabled(false, forceReload: true);
      return _messages.any((message) => message.id == messageId);
    }
    final requested = leadingContext * 2 + 1;
    final limit = requested
        .clamp(
          ChatService.defaultTimelineInitialSlots,
          ChatService.defaultLoadedWindowMax,
        )
        .toInt();
    final serial = ++_windowLoadSerial;
    _isLoadingWindow = true;
    try {
      final page = await _chatService.loadTimelinePage(
        conversation.id,
        aroundRevisionId: messageId,
        limit: limit,
      );
      // 如果加载期间会话发生变化，则丢弃该页。
      if (_currentConversation?.id != conversation.id) return false;
      if (page == null || page.slots.isEmpty) return false;
      _replaceWindow(page);
    } finally {
      if (serial == _windowLoadSerial) _isLoadingWindow = false;
    }
    notifyListeners();
    return _messages.any((message) => message.id == messageId);
  }

  Future<bool> refreshTimelineAfterMutation({
    Set<String> removedRevisionIds = const <String>{},
    List<String>? activePathIds,
  }) async {
    final conversation = _currentConversation;
    if (conversation == null) return false;
    if (activePathIds != null &&
        _removeMessagesFromWindow(removedRevisionIds, activePathIds)) {
      if (_currentConversation?.id != conversation.id) return false;
      notifyListeners();
      return true;
    }
    String? anchorId;
    if (hasMoreAfter) {
      for (final message in _messages) {
        if (removedRevisionIds.contains(message.id)) continue;
        anchorId = message.id;
        break;
      }
    }
    final previousSlotIds = <String>{
      for (final message in _messages) message.id,
    };
    final page = _lazyHistoryEnabled
        ? await _chatService.loadTimelinePage(
            conversation.id,
            aroundRevisionId: anchorId,
            limit: ChatService.defaultLoadedWindowMax,
          )
        : await _fetchCompleteTimeline(conversation.id);
    if (_currentConversation?.id != conversation.id) return false;
    _replaceWindow(_withoutBackfilledHead(page, previousSlotIds));
    notifyListeners();
    return page != null;
  }

  /// 直接在已加载窗口内应用可证明的消息删除，而不是重新加载整个窗口。
  ///
  /// 完整重载会围绕数据库锚点重建窗口，可能重塑窗口
  /// （回填头部、索引偏移）；随后列表控件会失去对幸存行的跟踪，
  /// 必须丢弃所有已测量的行高，在重新测量所有内容时视口会漂移。
  /// 直接从已加载窗口中移除被删除消息可以让每个幸存槽位身份保持稳定，
  /// 因此列表只会看到“这些槽位消失了”。
  ///
  /// 只有删除集合全部位于当前窗口时才能原地编辑；隐藏分支或窗口外
  /// 消息无法由窗口证明，必须回退到活动路径重载。
  bool _removeMessagesFromWindow(
    Set<String> removedRevisionIds,
    List<String> activePathIds,
  ) {
    if (removedRevisionIds.isEmpty || _messages.isEmpty) return false;
    final next = _messages
        .where((message) => !removedRevisionIds.contains(message.id))
        .toList(growable: true);
    if (next.isEmpty) return false;

    final firstIndex = activePathIds.indexOf(next.first.id);
    final lastIndex = activePathIds.indexOf(next.last.id);
    if (firstIndex < 0 || lastIndex < firstIndex) return false;
    final expectedStart = hasMoreBefore ? firstIndex : 0;
    final expectedEnd = hasMoreAfter ? lastIndex + 1 : activePathIds.length;
    final expectedWindow = activePathIds.sublist(expectedStart, expectedEnd);
    if (!listEquals(
      expectedWindow,
      next.map((message) => message.id).toList(growable: false),
    )) {
      return false;
    }

    _messages = next;
    _loadedStartIndex = expectedStart;
    _totalMessageCount = math.max(
      _loadedStartIndex + next.length,
      _totalMessageCount - removedRevisionIds.length,
    );
    invalidateCache();
    return true;
  }

  /// 丢弃以尾部为锚点的重载在旧窗口前回填的槽位。
  ///
  /// 没有锚点的重载总是填充完整大小的窗口，因此删除最后一条消息
  /// 会在头部多拉入一条更早的消息。刷新后的列表长度与之前相同，
  /// 但每个槽位偏移一位；SuperSliverList 会在新索引下复用子项，
  /// 并保留过期的布局偏移，导致视口停在真实底部之上且无法向下滚回。
  /// 截断回填头部会使新窗口成为旧窗口的前缀，
  /// 因此列表只是失去尾部子项。被丢弃的历史由 [loadMoreBefore]
  /// 重新分页加载。
  LoadedTimelinePage? _withoutBackfilledHead(
    LoadedTimelinePage? page,
    Set<String> previousSlotIds,
  ) {
    if (page == null || page.hasMoreAfter || previousSlotIds.isEmpty) {
      return page;
    }
    var cut = 0;
    while (cut < page.slots.length &&
        !previousSlotIds.contains(page.slots[cut].message.id)) {
      cut++;
    }
    // cut == 0：没有回填内容。cut == length：窗口已完全移离旧窗口，
    // 因此没有可保留的共享头部。
    if (cut == 0 || cut >= page.slots.length) return page;
    // 批量删除后，重新加载的窗口中只剩少量旧槽位；如果缩减到这些槽位，
    // 会显示一个近乎空白的列表，只有用户滚动时才会重新填充。
    // 为此复用子项并不值得，所以当幸存槽位不足一屏时保留完整窗口。
    final remaining = page.slots.length - cut;
    if (remaining <
        math.min(
          ChatService.defaultTimelineInitialSlots,
          previousSlotIds.length,
        )) {
      return page;
    }
    return LoadedTimelinePage(
      conversationId: page.conversationId,
      stateRevision: page.stateRevision,
      contextStartRevisionId: page.contextStartRevisionId,
      slots: page.slots.sublist(cut),
      hasMoreBefore: true,
      hasMoreAfter: page.hasMoreAfter,
      totalSlotCount: page.totalSlotCount,
    );
  }

  int loadedWindowTruncateIndex() {
    final raw = _currentConversation?.truncateIndex ?? -1;
    if (raw < 0) return -1;
    if (raw <= _loadedStartIndex) return -1;

    final loadedEnd = _loadedStartIndex + _messages.length;
    if (raw >= loadedEnd) return _messages.length;
    return raw - _loadedStartIndex;
  }

  Conversation conversationForLoadedWindow(Conversation conversation) {
    if (_currentConversation?.id != conversation.id) return conversation;
    final localTruncateIndex = loadedWindowTruncateIndex();
    return conversation.copyWith(truncateIndex: localTruncateIndex);
  }

  /// 仅使用当前已加载窗口的折叠投影，绝不通过
  /// [ChatService.getMessagesRange] / 完整顺序骨架遍历整个会话。
  List<ChatMessage> allCollapsedMessagesForCurrentConversation() {
    if (_currentConversation == null) return const <ChatMessage>[];
    return collapsedMessages;
  }

  Future<List<ChatMessage>>
  loadAllCollapsedMessagesForCurrentConversation() async {
    final conversation = _currentConversation;
    if (conversation == null) return const <ChatMessage>[];
    return _chatService.loadSelectedMessageProjections(conversation.id);
  }

  Future<List<MiniMapSearchHit>> searchMiniMapMatches(String query) {
    final conversation = _currentConversation;
    if (conversation == null) {
      return Future<List<MiniMapSearchHit>>.value(const <MiniMapSearchHit>[]);
    }
    return _chatService.searchMiniMapMatches(conversation.id, query);
  }

  Future<List<ChatMessage>> allMessagesForCurrentConversationContext() async {
    final conversation = _currentConversation;
    if (conversation == null) return const <ChatMessage>[];
    return messagesForCompleteHistoryContext(conversation);
  }

  Future<List<ChatMessage>> messagesForCompleteHistoryContext(
    Conversation conversation,
  ) => _chatService.loadActiveTimelineMessages(conversation.id);

  Future<List<ChatMessage>> messagesForGenerationContext(
    Conversation conversation, {
    required int maxMessages,
    String? throughRevisionId,
    bool includeFollowingAssistant = false,
  }) {
    return _chatService.loadSelectedContextMessages(
      conversation.id,
      truncateIndex: conversation.truncateIndex,
      limit: maxMessages,
      throughRevisionId: throughRevisionId,
      includeFollowingAssistant: includeFollowingAssistant,
    );
  }

  Conversation conversationForCompleteHistoryContext(
    Conversation conversation,
  ) {
    final current =
        _chatService.getConversation(conversation.id) ?? conversation;
    return current;
  }

  // ============================================================================
  // 消息管理
  // ============================================================================

  Future<ChatMessage> addMessage({
    required String role,
    required String content,
    String? modelId,
    String? providerId,
    bool isStreaming = false,
    String? groupId,
    int? version,
  }) async {
    final conversation = _currentConversation;
    if (conversation == null ||
        _chatService.getConversation(conversation.id) == null) {
      _clearCurrentConversationState();
      notifyListeners();
      throw StateError('No current conversation');
    }
    final message = await _chatService.addMessage(
      conversationId: conversation.id,
      role: role,
      content: content,
      modelId: modelId,
      providerId: providerId,
      isStreaming: isStreaming,
      groupId: groupId,
      version: version,
    );
    await appendPersistedTailMessage(message);
    return message;
  }

  /// 将已持久化的尾部消息添加到已加载窗口。
  ///
  /// ChatService 会在调用方更新 UI 状态前将新消息版本和流式占位项
  /// 追加到持久化会话。此方法使 [_messages] 保持真实连续的持久化范围，
  /// 而不是把尾部消息混入较旧的已加载窗口。
  Future<bool> appendPersistedTailMessage(ChatMessage message) async {
    return appendPersistedTailMessages([message]);
  }

  /// 围绕已持久化的消息变更打开逻辑窗口。
  ///
  /// 覆盖编辑保留消息 ID，可直接替换当前窗口快照；新分支使用新 ID，
  /// 必须从活动时间线重新定位，不能按旧 groupId/version 猜测槽位。
  Future<bool> openAroundPersistedMessage(
    ChatMessage message, {
    bool truncateFollowingSlots = false,
  }) async {
    final conversation = _currentConversation;
    if (conversation == null || message.conversationId != conversation.id) {
      return false;
    }

    final visibleIndex = _messages.indexWhere(
      (candidate) => candidate.id == message.id,
    );
    if (visibleIndex >= 0) {
      _messages[visibleIndex] = message;
      if (truncateFollowingSlots) {
        _messages.removeRange(visibleIndex + 1, _messages.length);
        _totalMessageCount = _loadedStartIndex + _messages.length;
      }
      invalidateCache();
      if (_currentConversation?.id != conversation.id) return false;
      notifyListeners();
      return true;
    }

    final opened = await loadWindowAroundMessage(
      message.id,
      leadingContext: ChatService.defaultHistoryPageSize,
    );
    return opened;
  }

  /// 将一次原子持久化结果作为一次 UI 变更发布到已加载尾部。
  /// 一次发送以用户/助手消息对开始，因此在这两条消息之间刷新持久化数量
  /// 会短暂制造错误间隙并触发不必要的窗口重载。
  ///
  /// 正常路径直接将已持久化消息追加到已加载窗口而不查询时间线；
  /// 只有检测到数量间隙时才回退到完整窗口重载。
  Future<bool> appendPersistedTailMessages(List<ChatMessage> messages) async {
    if (messages.isEmpty) return false;
    final conversation = _currentConversation;
    if (conversation == null ||
        messages.any((message) => message.conversationId != conversation.id)) {
      return false;
    }

    if (_tryAppendPersistedTail(conversation.id, messages)) {
      invalidateCache();
      notifyListeners();
      return true;
    }

    // 回退：当前窗口不能证明覆盖持久化尾部，因此重新加载整个尾部窗口，
    // 而不是盲目追加。
    final page = _lazyHistoryEnabled
        ? await _chatService.loadTimelinePage(
            conversation.id,
            limit: ChatService.defaultLoadedWindowMax,
          )
        : await _fetchCompleteTimeline(conversation.id);
    if (_currentConversation?.id != conversation.id) return false;
    _replaceWindow(page);
    notifyListeners();
    return true;
  }

  /// 将持久化尾部消息折叠进已加载窗口而不查询时间线。
  /// 当连续性无法证明时返回 false，调用方会回退到完整窗口重载。
  bool _tryAppendPersistedTail(
    String conversationId,
    List<ChatMessage> messages,
  ) {
    // 已加载窗口当前必须到达持久化尾部。
    if (_loadedStartIndex + _messages.length != _totalMessageCount) {
      return false;
    }

    // 每条传入消息都必须是尚未加载的新消息 ID。
    final knownMessageIds = <String>{for (final loaded in _messages) loaded.id};
    final batchMessageIds = <String>{};
    for (final message in messages) {
      if (knownMessageIds.contains(message.id) ||
          !batchMessageIds.add(message.id)) {
        return false;
      }
    }

    // 间隙检测比较持久化消息索引。该批次必须紧接在已加载尾部
    // 之后占据最后几行；否则意味着中间出现了未见过的变更。
    // 未知数量（-1）会使 `rowCount < messages.length` 失败，
    // 并保守地跳过快速追加路径（回退到完整重载）。
    final rowCount = _chatService.getMessageCount(conversationId);
    if (rowCount < messages.length) return false;
    final firstRowIndex = _chatService.getMessageIndex(
      conversationId,
      messages.first.id,
    );
    final lastRowIndex = _chatService.getMessageIndex(
      conversationId,
      messages.last.id,
    );
    if (firstRowIndex != rowCount - messages.length ||
        lastRowIndex != rowCount - 1) {
      return false;
    }
    if (_messages.isNotEmpty) {
      final tailRowIndex = _chatService.getMessageIndex(
        conversationId,
        _messages.last.id,
      );
      if (tailRowIndex != firstRowIndex - 1) return false;
    } else if (firstRowIndex != 0) {
      return false;
    }

    _messages.addAll(messages);
    _totalMessageCount += messages.length;
    if (_lazyHistoryEnabled &&
        _messages.length > ChatService.defaultLoadedWindowMax) {
      final removeCount = _messages.length - ChatService.defaultLoadedWindowMax;
      _messages.removeRange(0, removeCount);
      _loadedStartIndex += removeCount;
    }
    return true;
  }

  /// 更新列表中的消息。
  void updateMessageInList(String messageId, ChatMessage updatedMessage) {
    if (!replaceMessageSnapshot(updatedMessage)) return;
    publishGenerationState(
      updatedMessage.conversationId,
      isGenerating: updatedMessage.isStreaming,
    );
    notifyListeners();
  }

  /// 将内存消息快照镜像到时间线窗口，而不发布全窗口变更。
  /// 流式 UI 有自己的窄范围通知器。
  bool replaceMessageSnapshot(ChatMessage updatedMessage) {
    if (_currentConversation?.id != updatedMessage.conversationId) {
      return false;
    }
    final index = _messages.indexWhere(
      (message) => message.id == updatedMessage.id,
    );
    if (index < 0) return false;
    _messages[index] = updatedMessage;
    invalidateCache();
    return true;
  }

  bool publishGenerationStarted(ChatMessage message) {
    final streamingMessage = message.isStreaming
        ? message
        : message.copyWith(isStreaming: true);
    final replaced = replaceMessageSnapshot(streamingMessage);
    publishGenerationState(message.conversationId, isGenerating: true);
    return replaced;
  }

  bool publishGenerationState(
    String conversationId, {
    required bool isGenerating,
  }) {
    return _currentConversation?.id == conversationId;
  }

  /// 发布最终生成快照，并始终结束时间线的生成生命周期，
  /// 即使消息在已加载窗口之外。
  bool publishTerminalMessage(ChatMessage message) {
    final terminalMessage = message.isStreaming
        ? message.copyWith(isStreaming: false)
        : message;
    final replaced = replaceMessageSnapshot(terminalMessage);
    publishGenerationState(message.conversationId, isGenerating: false);
    return replaced;
  }

  /// 按 ID 使用可选的新值更新消息。
  Future<void> updateMessage(
    String messageId, {
    String? content,
    int? totalTokens,
    bool? isStreaming,
  }) async {
    await _chatService.updateMessage(
      messageId,
      content: content,
      totalTokens: totalTokens,
      isStreaming: isStreaming,
    );

    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      final updatedMessage = _messages[index].copyWith(
        content: content ?? _messages[index].content,
        totalTokens: totalTokens ?? _messages[index].totalTokens,
        isStreaming: isStreaming ?? _messages[index].isStreaming,
      );
      replaceMessageSnapshot(updatedMessage);
      publishGenerationState(
        updatedMessage.conversationId,
        isGenerating: updatedMessage.isStreaming,
      );
      notifyListeners();
    }
  }

  // ============================================================================
  // 加载状态管理
  // ============================================================================

  /// 检查指定会话是否正在加载。
  bool isConversationLoading(String conversationId) {
    return _loadingConversationIds.contains(conversationId);
  }

  /// 设置会话的加载状态。
  void setConversationLoading(String conversationId, bool loading) {
    final prev = _loadingConversationIds.contains(conversationId);
    if (loading) {
      _loadingConversationIds.add(conversationId);
    } else {
      _loadingConversationIds.remove(conversationId);
    }
    if (prev != loading) {
      notifyListeners();
      if (loading && !_screenWakelockAcquired) {
        _screenWakelockAcquired = true;
        ScreenWakelock.acquire();
      } else if (!loading &&
          _loadingConversationIds.isEmpty &&
          _screenWakelockAcquired) {
        _screenWakelockAcquired = false;
        ScreenWakelock.release();
      }
      if (!loading &&
          _currentConversation?.id == conversationId &&
          !_chatService.isConversationFullyCached(conversationId)) {
        // 恢复因生成而暂停的空闲回填。
        _scheduleIdleCacheBackfill(conversationId);
      }
    }
  }

  // ============================================================================
  // 流订阅管理
  // ============================================================================

  /// 获取会话的流订阅。
  StreamSubscription<dynamic>? getStreamSubscription(String conversationId) {
    return _conversationStreams[conversationId];
  }

  /// 设置会话的流订阅。
  void setStreamSubscription(
    String conversationId,
    StreamSubscription<dynamic> subscription,
  ) {
    _conversationStreams[conversationId] = subscription;
  }

  /// 取消并移除流订阅。
  Future<void> cancelStreamSubscription(String conversationId) async {
    final sub = _conversationStreams.remove(conversationId);
    await sub?.cancel();
  }

  /// 取消所有流订阅。
  Future<void> cancelAllStreams() async {
    for (final sub in _conversationStreams.values) {
      await sub.cancel();
    }
    _conversationStreams.clear();
  }

  // ============================================================================
  // 版本折叠逻辑
  // ============================================================================

  /// 废弃：版本折叠不再需要，树模式下活动路径就是投影。
  @Deprecated('Version collapsing is no longer used with tree mode')
  List<ChatMessage> get collapsedMessages {
    return _messages;
  }

  /// 废弃：版本折叠不再需要，树模式下活动路径就是投影。
  @Deprecated('Version collapsing is no longer used with tree mode')
  List<ChatMessage> _messagesWithVisibleGroups() {
    return _messages;
  }

  /// 废弃：折叠消息缓存已废弃，树模式下直接使用活动路径。
  @Deprecated('Use active path from ConversationTree instead')
  int indexOfCollapsedMessageId(String id) {
    return _messages.indexWhere((m) => m.id == id);
  }

  static List<ChatMessage> selectedCollapsedMessagesForExport({
    required Iterable<ChatMessage> collapsedMessages,
    required Set<String> selectedIds,
    required Iterable<ChatMessage> storedMessages,
  }) {
    if (selectedIds.isEmpty) return const <ChatMessage>[];

    final storedById = <String, ChatMessage>{
      for (final message in storedMessages) message.id: message,
    };

    return [
      for (final message in collapsedMessages)
        if (selectedIds.contains(message.id)) storedById[message.id] ?? message,
    ];
  }

  /// 获取按 groupId 分组的消息（缓存）。
  Map<String, List<ChatMessage>> get groupedMessages {
    return _groupCache ??= groupMessagesByGroup();
  }

  /// 当前有界时间线窗口的完整渲染投影。
  /// 每个消息快照只计算一次，绝不按每个可见行计算。
  List<MessageRenderModel> get messageRenderModels {
    return _renderModelsCache ??= MessageRenderModelProjector.project(
      messages: collapsedMessages,
      contextDividerIndex: _collapsedContextDividerIndex(),
    );
  }

  int _collapsedContextDividerIndex() {
    final raw = loadedWindowTruncateIndex();
    if (raw <= 0) return -1;
    final limit = raw.clamp(0, _messages.length);
    return limit - 1;
  }

  /// 兼容旧调用方的消息索引；运行时每条消息都是独立槽位。
  Map<String, List<ChatMessage>> groupMessagesByGroup() {
    return <String, List<ChatMessage>>{
      for (final message in _messagesWithVisibleGroups())
        message.id: <ChatMessage>[message],
    };
  }

  // ============================================================================
  // 缓存失效
  // ============================================================================

  /// 在不触发监听器的情况下使折叠/分组缓存失效。
  ///
  /// 当 _messages 被外部修改（例如由 ChatActions）且调用方会自行
  /// 触发 notifyListeners() 时调用此方法。
  void invalidateCache() {
    _groupCache = null;
    _renderModelsCache = null;
  }

  @override
  void notifyListeners() {
    invalidateCache();
    super.notifyListeners();
  }

  // ============================================================================
  // 清理
  // ============================================================================

  @override
  void dispose() {
    _chatService.removeListener(_syncCurrentConversationWithService);
    cancelAllStreams();
    if (_screenWakelockAcquired) {
      _screenWakelockAcquired = false;
      ScreenWakelock.release();
    }
    super.dispose();
  }
}
