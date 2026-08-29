import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../database/app_database.dart';
import '../../database/business_data.dart';
import '../../database/business_repository.dart';
import '../../database/chat_database_gateway.dart';
import '../../database/chat_database_repository.dart';
import '../../database/generation_run.dart';
import '../../models/chat_message.dart';
import '../../models/message_part.dart';
import '../../models/conversation.dart';
import '../../models/conversation_tree.dart';
import '../../models/backup_task_progress.dart';
import '../../models/progress_update.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/app_directories.dart';
import '../backup/backup_isolate_runner.dart';

final class LoadedTimelineSlot {
  const LoadedTimelineSlot({required this.identity, required this.message});

  final ActiveTimelineSlot identity;
  final ChatMessage message;
}

final class LoadedTimelinePage {
  LoadedTimelinePage({
    required this.conversationId,
    required this.stateRevision,
    required this.contextStartRevisionId,
    required List<LoadedTimelineSlot> slots,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
    required this.totalSlotCount,
  }) : slots = List.unmodifiable(slots);

  final String conversationId;
  final int stateRevision;
  final String? contextStartRevisionId;
  final List<LoadedTimelineSlot> slots;
  final bool hasMoreBefore;
  final bool hasMoreAfter;
  final int totalSlotCount;

  String? get beforeRevisionId => hasMoreBefore && slots.isNotEmpty
      ? slots.first.identity.revisionId
      : null;
  String? get afterRevisionId =>
      hasMoreAfter && slots.isNotEmpty ? slots.last.identity.revisionId : null;
}

typedef AssetContentHash = Future<String> Function(File file);

enum ConversationForkMode { preserveBranches, activeBranchOnly }

final class ConversationBatchMoveResult {
  const ConversationBatchMoveResult({
    required this.moved,
    required this.skippedBusy,
  });

  final int moved;
  final int skippedBusy;
}

enum _MoveConversationResult { moved, unchanged, busy, missing }

class ChatService extends ChangeNotifier {
  ChatService({
    ChatDatabaseGateway? databaseGateway,
    ChatDatabaseRepository? existingRepository,
    AssetContentHash? assetContentHash,
  }) : _databaseGateway = databaseGateway ?? ChatDatabaseGateway.instance,
       // 公共注入名称有意省略私有字段前缀。
       // ignore: prefer_initializing_formals
       _existingRepository = existingRepository,
       _assetContentHash = assetContentHash ?? _hashAssetFile;

  static const int defaultInitialMessageMin = 2;
  static const int defaultInitialMessageMax = 240;
  static const int defaultTimelineInitialSlots = 40;
  static const int defaultInitialTextBudget = 20000;
  static const int defaultHistoryPageSize = 20;
  static const int defaultLoadedWindowMax = 360;
  static const int _messageCacheMaxEntries = 720;
  static const int _messageCacheMaxBytes = 8 * 1024 * 1024;

  // loadTimelinePage 内存快速路径的总开关；设为 false 会
  // 强制所有场景走数据库路径。
  static bool timelineCacheFastPathEnabled = true;
  static const int _assetReferenceBackfillVersion = 2;
  static const Duration _assetGcDelay = Duration(days: 7);
  static const int _imageContentHashCacheMaxEntries = 256;

  late ChatDatabaseRepository _repo;
  late File _databaseFile;
  final ChatDatabaseGateway _databaseGateway;
  final ChatDatabaseRepository? _existingRepository;
  final AssetContentHash _assetContentHash;
  ChatDatabaseLease? _databaseLease;
  Future<void>? _assetReferenceMaintenanceFuture;
  Future<void>? _postStartupAssetMaintenanceFuture;

  String? _currentConversationId;
  final Map<String, List<ChatMessage>> _messagesCache = {};
  // 为组导向操作加载的正文可能包含隐藏的兄弟分支。
  // 它们不得污染活动时间线投影。
  final Map<String, List<ChatMessage>> _groupMessagesCache = {};
  final Map<String, Conversation> _conversationsCache = {};
  final Map<String, Conversation> _draftConversations = {};
  final Set<String> _temporaryConversationIds = <String>{};
  final Map<String, ConversationTree> _temporaryConversationTrees =
      <String, ConversationTree>{};
  // 逐出这些 id 可能会重新引入与后台工作的持久化竞争。
  final Set<String> _discardedTemporaryConversationIds = <String>{};
  final Set<String> _discardedTemporaryMessageIds = <String>{};
  final Map<String, List<Map<String, dynamic>>> _temporaryToolEvents =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, String> _temporaryGeminiThoughtSigs = <String, String>{};
  final Map<String, List<Map<String, dynamic>>> _toolEventsCache = {};
  final Map<String, String> _geminiThoughtSigsCache = {};
  final Map<String, Map<String, int>> _firstGroupIndicesCache = {};
  final Map<String, int> _messageCounts = {};
  // 不变量：键要么不存在，要么保存完整的权威
  // 消息 ID 顺序。绝不存储部分或半填充的骨架。
  final Map<String, List<String>> _messageOrderIds = {};

  // OCR 身份记忆：避免每次发送时重新读取图片字节。通过长度 + mtime 验证，
  // 因此替换后的文件会重新计算哈希；asset 注册表的 path→hash 行始终保持不受信任
  // （同一路径在内容替换后可能指向不同的历史资产）。
  final Map<String, ({int length, int mtimeMs, String hash})>
  _imageContentHashCache = {};

  int _timelineFastPathHitCount = 0;

  @visibleForTesting
  int get debugTimelineFastPathHitCount => _timelineFastPathHitCount;

  /// 是否已经存在完整的消息顺序骨架条目。
  @visibleForTesting
  bool debugHasMessageOrderSkeleton(String conversationId) =>
      _messageOrderIds.containsKey(conversationId);

  /// 缓存的顺序骨架的长度；不存在时为 null。
  @visibleForTesting
  int? debugMessageOrderSkeletonLength(String conversationId) =>
      _messageOrderIds[conversationId]?.length;

  /// 仅测试用：无需访问私有字段即可预填充消息缓存 / 计数 / 顺序。
  @visibleForTesting
  void debugPrimeMessageCountState(
    String conversationId, {
    List<ChatMessage>? cachedMessages,
    int? messageCount,
    List<String>? orderIds,
    bool clearCounts = false,
  }) {
    if (cachedMessages != null) {
      _messagesCache[conversationId] = List<ChatMessage>.of(cachedMessages);
    }
    if (clearCounts) {
      _messageCounts.remove(conversationId);
      _messageOrderIds.remove(conversationId);
    }
    if (messageCount != null) {
      _messageCounts[conversationId] = messageCount;
    }
    if (orderIds != null) {
      _messageOrderIds[conversationId] = List<String>.of(orderIds);
    }
  }

  // 新会话的本地化默认标题；由 UI 在启动时设置。
  String _defaultConversationTitle = 'New Chat';
  void setDefaultConversationTitle(String title) {
    if (title.trim().isEmpty) return;
    _defaultConversationTitle = title.trim();
  }

  bool _initialized = false;
  Future<void>? _initFuture;
  bool get initialized => _initialized;

  /// 就绪后的底层类型化仓库（在 [init] 之后，或初始化前注入的
  /// [existingRepository]）。未初始化的服务为 null。
  ChatDatabaseRepository? get chatRepositoryOrNull {
    if (_initialized) return _repo;
    return _existingRepository;
  }

  int _statisticsRevision = 0;
  int get statisticsRevision => _statisticsRevision;

  // 仅在侧边栏列表语义变化时递增（会话添加/移除、
  // 重命名、置顶、按 updatedAt 排序、assistant/MCP 关联）。消息
  // 内容和流式更新不得递增它。
  int _conversationListRevision = 0;
  int get conversationListRevision => _conversationListRevision;

  List<Conversation>? _sortedConversationsCache;
  int _sortedConversationsCacheRevision = -1;

  void _bumpConversationListRevision() {
    _conversationListRevision++;
  }

  String? get currentConversationId => _currentConversationId;

  bool isTemporaryConversation(String? id) {
    return id != null &&
        (_temporaryConversationIds.contains(id) ||
            _discardedTemporaryConversationIds.contains(id));
  }

  Future<void> init() {
    if (_initialized) return Future<void>.value();
    final inFlight = _initFuture;
    if (inFlight != null) return inFlight;
    final initialization = _initialize();
    _initFuture = initialization;
    return initialization.whenComplete(() {
      if (identical(_initFuture, initialization)) _initFuture = null;
    });
  }

  Future<void> _initialize() async {
    final appDataDir = await AppDirectories.getAppDataDirectory();
    if (!await appDataDir.exists()) {
      await appDataDir.create(recursive: true);
    }
    _databaseFile = File(p.join(appDataDir.path, AppDatabase.databaseFileName));
    final existingRepository = _existingRepository;
    final ChatDatabaseLease? lease;
    if (existingRepository == null) {
      lease = await _databaseGateway.acquire(_databaseFile);
      _databaseLease = lease;
      _repo = lease.repository;
    } else {
      lease = null;
      _repo = existingRepository;
    }
    try {
      // 带版本控制且事务化：正常启动会在扫描行之前返回。
      await _migrateSandboxPaths();
      await _loadConversationsCache();

      // 重置上一次应用崩溃或强制退出后遗留的过期 isStreaming 标志。
      // 全新启动后，不可能有消息仍在主动流式传输。
      await _resetStaleStreamingFlags();

      _initialized = true;
      notifyListeners();
      late final Future<void> postStartupMaintenance;
      postStartupMaintenance = _runAssetReferenceMaintenance(appDataDir)
          .then((_) => runAssetMaintenance())
          .catchError((Object error) {
            debugPrint('Post-startup asset maintenance failed: $error');
          })
          .whenComplete(() {
            if (identical(
              _postStartupAssetMaintenanceFuture,
              postStartupMaintenance,
            )) {
              _postStartupAssetMaintenanceFuture = null;
            }
          });
      _postStartupAssetMaintenanceFuture = postStartupMaintenance;
      unawaited(postStartupMaintenance);
    } catch (_) {
      _databaseLease = null;
      await lease?.release();
      rethrow;
    }
  }

  Future<void> close() async {
    final initialization = _initFuture;
    if (initialization != null) {
      try {
        await initialization;
      } catch (_) {
        return;
      }
    }
    if (!_initialized) return;
    final postStartupMaintenance = _postStartupAssetMaintenanceFuture;
    if (postStartupMaintenance != null) {
      try {
        await postStartupMaintenance;
      } catch (_) {}
    }
    final assetMaintenance = _assetReferenceMaintenanceFuture;
    if (assetMaintenance != null) {
      try {
        await assetMaintenance;
      } catch (_) {}
    }
    _initialized = false;
    final lease = _databaseLease;
    _databaseLease = null;
    await lease?.release();
  }

  @override
  void dispose() {
    if (_initialized || _initFuture != null) {
      unawaited(close());
    }
    super.dispose();
  }

  void _clearPersistedMessageCache() {
    _messagesCache.removeWhere(
      (conversationId, _) =>
          !_temporaryConversationIds.contains(conversationId),
    );
  }

  Future<void> _loadConversationsCache() async {
    final conversations = await _repo.getAllConversationSummaries();
    _toolEventsCache.clear();
    _geminiThoughtSigsCache.clear();
    _messageOrderIds.clear();
    _firstGroupIndicesCache.clear();
    // 重新加载时丢弃过期计数；不要通过全库聚合重新填充。
    // 计数在需要它们的读/写路径上按需解析。
    _messageCounts.clear();
    _conversationsCache
      ..clear()
      ..addEntries(
        conversations.map(
          (conversation) => MapEntry(conversation.id, conversation),
        ),
      );
    _bumpConversationListRevision();
  }

  /// 返回已知的内存计数，或者通过按会话索引解析一次并缓存。
  /// 绝不返回未知哨兵值 (-1)。
  ///
  /// 临时/草稿会话使用内存中的消息长度，不会访问数据库。持久化的未知会话只按该 id 查询
  /// [_repo.getMessageCount]，绝不使用 [ChatDatabaseRepository.getMessageCountsByConversation]。
  Future<int> resolveMessageCount(String conversationId) async {
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      return _messagesCache[conversationId]?.length ?? 0;
    }
    final cached = getMessageCount(conversationId);
    if (cached >= 0) return cached;
    final tree = await _loadOrCreateConversationTree(conversationId);
    final count = tree.activePath().length;
    _messageCounts[conversationId] = count;
    return count;
  }

  Future<int> _resolveMessageCount(String conversationId) =>
      resolveMessageCount(conversationId);

  Future<List<String>> _loadMessageOrder(String conversationId) async {
    final cached = _messageOrderIds[conversationId];
    if (cached != null) return cached;
    final tree = await _loadOrCreateConversationTree(conversationId);
    final ids = tree.activePath().toList(growable: true);
    // 存在意味着完整且权威。并发写入方可能在 getMessageIds
    // 进行中已安装完整骨架（并追加了更新的 id），
    // 绝不用可能过期的快照覆盖它。
    final raced = _messageOrderIds[conversationId];
    if (raced != null) return raced;
    _messageOrderIds[conversationId] = ids;
    _messageCounts[conversationId] = ids.length;
    return ids;
  }

  Future<List<ChatMessage>> loadActiveTimelineMessages(
    String conversationId,
  ) async {
    if (!_initialized) return const <ChatMessage>[];
    if (_temporaryConversationIds.contains(conversationId)) {
      final tree = await _loadOrCreateConversationTree(conversationId);
      final byId = <String, ChatMessage>{
        for (final message
            in _messagesCache[conversationId] ?? const <ChatMessage>[])
          message.id: message,
      };
      return [
        for (final id in tree.activePath())
          if (byId[id] != null) byId[id]!,
      ];
    }
    final tree = await _loadOrCreateConversationTree(conversationId);
    final revisionIds = tree.activePath();
    if (revisionIds.isEmpty) return const <ChatMessage>[];
    final messages = await _repo.getMessagesByIds(revisionIds);
    final byId = {for (final message in messages) message.id: message};
    final activeMessages = <ChatMessage>[];
    for (final revisionId in revisionIds) {
      final message = byId[revisionId];
      if (message == null) {
        throw StateError('active_timeline_message_missing');
      }
      activeMessages.add(message);
    }
    return List<ChatMessage>.unmodifiable(activeMessages);
  }

  Future<LoadedTimelinePage?> loadTimelinePage(
    String conversationId, {
    String? beforeRevisionId,
    String? afterRevisionId,
    String? aroundRevisionId,
    bool fromStart = false,
    int limit = 40,
  }) async {
    if (!_initialized || limit <= 0) return null;
    if (_temporaryConversationIds.contains(conversationId)) {
      return _loadTemporaryTimelinePage(
        conversationId,
        beforeRevisionId: beforeRevisionId,
        afterRevisionId: afterRevisionId,
        aroundRevisionId: aroundRevisionId,
        fromStart: fromStart,
        limit: limit,
      );
    }
    final conversationTree = await _loadOrCreateConversationTree(
      conversationId,
    );
    final activePath = conversationTree.activePath();
    _messageOrderIds[conversationId] = List<String>.of(activePath);
    _messageCounts[conversationId] = activePath.length;
    if (timelineCacheFastPathEnabled &&
        !fromStart &&
        beforeRevisionId == null &&
        afterRevisionId == null &&
        aroundRevisionId == null) {
      final cachedPage = _tryLoadCachedTreeTailPage(
        conversationId,
        tree: conversationTree,
        limit: limit,
      );
      if (cachedPage != null) {
        _timelineFastPathHitCount += 1;
        return cachedPage;
      }
    }
    final page = await _loadTreeTimelinePage(
      conversationId,
      conversationTree,
      beforeRevisionId: beforeRevisionId,
      afterRevisionId: afterRevisionId,
      aroundRevisionId: aroundRevisionId,
      fromStart: fromStart,
      limit: limit,
    );
    if (page == null) return null;
    final messages = page.slots
        .map((slot) => slot.message)
        .toList(growable: false);
    _cacheLoadedMessages(conversationId, messages);
    await _cacheMessageArtifacts(messages);
    return page;
  }

  Future<LoadedTimelinePage?> _loadTreeTimelinePage(
    String conversationId,
    ConversationTree tree, {
    String? beforeRevisionId,
    String? afterRevisionId,
    String? aroundRevisionId,
    required bool fromStart,
    required int limit,
  }) async {
    final cursorCount = <String?>[
      beforeRevisionId,
      afterRevisionId,
      aroundRevisionId,
    ].whereType<String>().length;
    if (cursorCount > 1 || (fromStart && cursorCount != 0)) {
      throw ArgumentError('Only one tree timeline cursor may be supplied.');
    }

    final path = tree.activePath();
    var start = 0;
    var end = path.length;
    if (fromStart) {
      end = limit.clamp(0, path.length).toInt();
    } else if (aroundRevisionId != null) {
      final targetIndex = path.indexOf(aroundRevisionId);
      if (targetIndex < 0) return null;
      start = (targetIndex - (limit ~/ 2)).clamp(0, path.length).toInt();
      end = (start + limit).clamp(start, path.length).toInt();
      start = (end - limit).clamp(0, end).toInt();
    } else if (beforeRevisionId != null) {
      final targetIndex = path.indexOf(beforeRevisionId);
      if (targetIndex < 0) return null;
      end = targetIndex;
      start = (end - limit).clamp(0, end).toInt();
    } else if (afterRevisionId != null) {
      final targetIndex = path.indexOf(afterRevisionId);
      if (targetIndex < 0) return null;
      start = targetIndex + 1;
      end = (start + limit).clamp(start, path.length).toInt();
    } else {
      start = (path.length - limit).clamp(0, path.length).toInt();
    }

    final revisionIds = path.sublist(start, end);
    final messages = await _repo.getMessagesByIds(revisionIds);
    final byId = <String, ChatMessage>{
      for (final message in messages) message.id: message,
    };
    String? parentRevisionId = start == 0 ? null : path[start - 1];
    final loadedSlots = <LoadedTimelineSlot>[];
    for (var index = 0; index < revisionIds.length; index++) {
      final message = byId[revisionIds[index]];
      if (message == null) {
        throw StateError('timeline_selected_revision_shadow_missing');
      }
      loadedSlots.add(
        LoadedTimelineSlot(
          identity: ActiveTimelineSlot(
            slotId: message.id,
            revisionId: message.id,
            parentRevisionId: parentRevisionId,
            role: message.role,
            createdAt: message.timestamp,
            updatedAt: message.timestamp,
            finalizedAt: message.isStreaming ? null : message.timestamp,
            versionCount: 1,
            logicalIndex: start + index,
          ),
          message: message,
        ),
      );
      parentRevisionId = message.id;
    }
    return LoadedTimelinePage(
      conversationId: conversationId,
      stateRevision:
          _conversationsCache[conversationId]
              ?.updatedAt
              .microsecondsSinceEpoch ??
          0,
      contextStartRevisionId: null,
      slots: loadedSlots,
      hasMoreBefore: start > 0,
      hasMoreAfter: end < path.length,
      totalSlotCount: path.length,
    );
  }

  LoadedTimelinePage? _loadTemporaryTimelinePage(
    String conversationId, {
    String? beforeRevisionId,
    String? afterRevisionId,
    String? aroundRevisionId,
    required bool fromStart,
    required int limit,
  }) {
    final cursorCount = <String?>[
      beforeRevisionId,
      afterRevisionId,
      aroundRevisionId,
    ].where((cursor) => cursor != null).length;
    if (cursorCount > 1 || (fromStart && cursorCount != 0)) {
      throw ArgumentError('Only one timeline cursor may be supplied.');
    }
    final conversation = _draftConversations[conversationId];
    if (conversation == null) return null;
    final allMessages = _messagesCache[conversationId] ?? const <ChatMessage>[];
    final tree =
        _temporaryConversationTrees[conversationId] ??
        ConversationTree.linear(
          conversationId: conversationId,
          messageIds: [for (final message in allMessages) message.id],
          activeBranchId: 'root-$conversationId',
        );
    _temporaryConversationTrees[conversationId] = tree;
    final byId = <String, ChatMessage>{
      for (final message in allMessages) message.id: message,
    };
    final activeMessages = <ChatMessage>[];
    final versionCounts = <String, int>{};
    for (final id in tree.activePath()) {
      final message = byId[id];
      if (message != null) {
        activeMessages.add(message);
        final groupId = message.groupId ?? message.id;
        versionCounts[groupId] = allMessages
            .where(
              (candidate) => (candidate.groupId ?? candidate.id) == groupId,
            )
            .length;
      }
    }

    var start = 0;
    var end = activeMessages.length;
    if (fromStart) {
      end = limit.clamp(0, activeMessages.length).toInt();
    } else if (aroundRevisionId != null) {
      final targetIndex = activeMessages.indexWhere(
        (message) => message.id == aroundRevisionId,
      );
      if (targetIndex < 0) return null;
      start = (targetIndex - (limit ~/ 2))
          .clamp(0, activeMessages.length)
          .toInt();
      end = (start + limit).clamp(start, activeMessages.length).toInt();
      start = (end - limit).clamp(0, end).toInt();
    } else if (beforeRevisionId != null) {
      end = activeMessages.indexWhere(
        (message) => message.id == beforeRevisionId,
      );
      if (end < 0) return null;
      start = (end - limit).clamp(0, end).toInt();
    } else if (afterRevisionId != null) {
      final cursorIndex = activeMessages.indexWhere(
        (message) => message.id == afterRevisionId,
      );
      if (cursorIndex < 0) return null;
      start = cursorIndex + 1;
      end = (start + limit).clamp(start, activeMessages.length).toInt();
    } else {
      start = (activeMessages.length - limit)
          .clamp(0, activeMessages.length)
          .toInt();
    }

    String? parentRevisionId = start == 0 ? null : activeMessages[start - 1].id;
    final slots = <LoadedTimelineSlot>[];
    for (var index = start; index < end; index++) {
      final message = activeMessages[index];
      slots.add(
        LoadedTimelineSlot(
          identity: ActiveTimelineSlot(
            slotId: message.groupId ?? message.id,
            revisionId: message.id,
            parentRevisionId: parentRevisionId,
            role: message.role,
            createdAt: message.timestamp,
            updatedAt: message.timestamp,
            finalizedAt: message.isStreaming ? null : message.timestamp,
            versionCount: versionCounts[message.groupId ?? message.id] ?? 1,
            logicalIndex: index,
          ),
          message: message,
        ),
      );
      parentRevisionId = message.id;
    }
    return LoadedTimelinePage(
      conversationId: conversationId,
      stateRevision: conversation.updatedAt.microsecondsSinceEpoch,
      contextStartRevisionId: null,
      slots: slots,
      hasMoreBefore: start > 0,
      hasMoreAfter: end < activeMessages.length,
      totalSlotCount: activeMessages.length,
    );
  }

  LoadedTimelinePage? _tryLoadCachedTreeTailPage(
    String conversationId, {
    required ConversationTree tree,
    required int limit,
  }) {
    final conversation = _conversationsCache[conversationId];
    final cached = _messagesCache[conversationId];
    if (conversation == null || cached == null) return null;
    final path = tree.activePath();
    final byId = <String, ChatMessage>{
      for (final message in cached) message.id: message,
    };
    if (path.any((id) => byId[id] == null)) return null;
    final start = (path.length - limit).clamp(0, path.length).toInt();
    String? parentRevisionId = start == 0 ? null : path[start - 1];
    final slots = <LoadedTimelineSlot>[];
    for (var index = start; index < path.length; index++) {
      final message = byId[path[index]]!;
      slots.add(
        LoadedTimelineSlot(
          identity: ActiveTimelineSlot(
            slotId: message.id,
            revisionId: message.id,
            parentRevisionId: parentRevisionId,
            role: message.role,
            createdAt: message.timestamp,
            updatedAt: message.timestamp,
            finalizedAt: message.isStreaming ? null : message.timestamp,
            versionCount: 1,
            logicalIndex: index,
          ),
          message: message,
        ),
      );
      parentRevisionId = message.id;
    }
    return LoadedTimelinePage(
      conversationId: conversationId,
      stateRevision: conversation.updatedAt.microsecondsSinceEpoch,
      contextStartRevisionId: null,
      slots: slots,
      hasMoreBefore: start > 0,
      hasMoreAfter: false,
      totalSlotCount: path.length,
    );
  }

  int getContextStartIndex(String conversationId) =>
      _conversationsCache[conversationId]?.truncateIndex ?? -1;

  Future<void> _syncContextBoundaryToActivePath(
    String conversationId,
    ConversationTree tree,
  ) async {
    final conversation = _conversationsCache[conversationId];
    if (conversation == null || conversation.truncateIndex < 0) return;

    final activePathLength = tree.activePath().length;
    final nextTruncateIndex = activePathLength == 0 ? -1 : activePathLength;
    if (conversation.truncateIndex == nextTruncateIndex) return;

    conversation.truncateIndex = nextTruncateIndex;
    conversation.updatedAt = DateTime.now();
    await _saveConversation(conversation);
  }

  Future<void> _cacheMessageArtifacts(Iterable<ChatMessage> messages) async {
    final ids = messages.map((message) => message.id).toSet();
    if (ids.isEmpty) return;
    final results = await Future.wait([
      _repo.getToolEventsForMessages(ids),
      _repo.getGeminiThoughtSignaturesForMessages(ids),
    ]);
    for (final id in ids) {
      _toolEventsCache.remove(id);
      _geminiThoughtSigsCache.remove(id);
    }
    _toolEventsCache.addAll(
      results[0] as Map<String, List<Map<String, dynamic>>>,
    );
    _geminiThoughtSigsCache.addAll(results[1] as Map<String, String>);
  }

  void _cacheLoadedMessages(
    String conversationId,
    Iterable<ChatMessage> messages,
  ) {
    if (_conversationForMessages(conversationId) == null) return;
    final byId = <String, ChatMessage>{
      for (final message in _messagesCache[conversationId] ?? const [])
        message.id: message,
      for (final message in messages) message.id: message,
    };
    // 没有顺序骨架时，交集会丢弃刚加载的所有消息；
    // 应保留合并后的插入顺序，而不是过滤成空。
    final order = _messageOrderIds[conversationId];
    _messagesCache[conversationId] = order == null
        ? byId.values.toList(growable: true)
        : [
            for (final id in order)
              if (byId[id] != null) byId[id]!,
          ];
    _touchMessageCache(conversationId);
    _enforceMessageCacheLimits();
  }

  void _touchMessageCache(String conversationId) {
    final messages = _messagesCache.remove(conversationId);
    if (messages != null) _messagesCache[conversationId] = messages;
  }

  int _estimateCachedMessageBytes(ChatMessage message) {
    var bytes =
        message.content.length * 2 +
        (message.reasoningText?.length ?? 0) * 2 +
        (message.translation?.length ?? 0) * 2 +
        (message.reasoningSegmentsJson?.length ?? 0) * 2;
    final toolEvents = _toolEventsCache[message.id];
    if (toolEvents != null) {
      for (final event in toolEvents) {
        bytes += jsonEncode(event).length * 2;
      }
    }
    return bytes;
  }

  void _enforceMessageCacheLimits() {
    bool isExempt(String conversationId) =>
        conversationId == _currentConversationId ||
        _temporaryConversationIds.contains(conversationId);

    // 当前会话免于逐出：其缓存上限
    // 是整个会话或空闲回填计数阈值。
    //
    // 单独一个会话超过预算时，会对其尾部进行裁剪（保留最近的消息），
    // 而不是连锁驱逐所有其他已缓存的会话。
    for (final conversationId in _messagesCache.keys.toList()) {
      if (isExempt(conversationId)) continue;
      final messages = _messagesCache[conversationId]!;
      var entries = messages.length;
      var bytes = 0;
      for (final message in messages) {
        bytes += _estimateCachedMessageBytes(message);
      }
      if (entries <= _messageCacheMaxEntries &&
          bytes <= _messageCacheMaxBytes) {
        continue;
      }
      var drop = 0;
      while (drop < messages.length &&
          (entries > _messageCacheMaxEntries ||
              bytes > _messageCacheMaxBytes)) {
        entries--;
        bytes -= _estimateCachedMessageBytes(messages[drop]);
        drop++;
      }
      for (final message in messages.sublist(0, drop)) {
        _toolEventsCache.remove(message.id);
        _geminiThoughtSigsCache.remove(message.id);
      }
      if (drop >= messages.length) {
        _messagesCache.remove(conversationId);
      } else {
        _messagesCache[conversationId] = messages.sublist(drop);
      }
    }

    var entries = 0;
    var bytes = 0;
    for (final entry in _messagesCache.entries) {
      if (isExempt(entry.key)) continue;
      entries += entry.value.length;
      bytes += entry.value.fold<int>(
        0,
        (sum, message) => sum + _estimateCachedMessageBytes(message),
      );
    }
    while ((entries > _messageCacheMaxEntries ||
            bytes > _messageCacheMaxBytes) &&
        _messagesCache.isNotEmpty) {
      final candidate = _messagesCache.entries.firstWhere(
        (entry) => !isExempt(entry.key),
        orElse: () => const MapEntry('', <ChatMessage>[]),
      );
      if (candidate.key.isEmpty) break;
      _messagesCache.remove(candidate.key);
      entries -= candidate.value.length;
      bytes -= candidate.value.fold<int>(
        0,
        (sum, message) => sum + _estimateCachedMessageBytes(message),
      );
      for (final message in candidate.value) {
        _toolEventsCache.remove(message.id);
        _geminiThoughtSigsCache.remove(message.id);
      }
    }
  }

  List<Conversation> getAllConversations() {
    if (!_initialized) return [];
    final cached = _sortedConversationsCache;
    if (cached != null &&
        _sortedConversationsCacheRevision == _conversationListRevision) {
      return List<Conversation>.of(cached);
    }
    final conversations = _conversationsCache.values.toList();
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _sortedConversationsCache = conversations;
    _sortedConversationsCacheRevision = _conversationListRevision;
    return List<Conversation>.of(conversations);
  }

  List<Conversation> getAllCompleteConversations() {
    return getAllConversations();
  }

  List<Conversation> getPinnedConversations() {
    return getAllConversations().where((c) => c.isPinned).toList();
  }

  Conversation? getConversation(String id) {
    if (!_initialized) return null;
    return _conversationsCache[id] ?? _draftConversations[id];
  }

  Conversation? getCompleteConversation(String id) {
    if (!_initialized) return null;
    final draft = _draftConversations[id];
    if (draft != null) return draft;
    return _conversationsCache[id];
  }

  Conversation? _conversationForMessages(String conversationId) {
    if (!_initialized) return _draftConversations[conversationId];
    return _conversationsCache[conversationId] ??
        _draftConversations[conversationId];
  }

  int getMessageCount(String conversationId) {
    if (_temporaryConversationIds.contains(conversationId)) {
      return _messageOrderIds[conversationId]?.length ??
          (_messagesCache[conversationId]?.length ?? 0);
    }
    if (!_initialized) return 0;
    final count = _messageCounts[conversationId];
    if (count != null) return count;
    final orderLen = _messageOrderIds[conversationId]?.length;
    if (orderLen != null) return orderLen;
    return -1;
  }

  bool isMessageCountKnown(String conversationId) {
    return _messageCounts.containsKey(conversationId) ||
        _messageOrderIds.containsKey(conversationId);
  }

  /// 仅返回 id，并按消息顺序排列；绝不将消息水合到 LRU 缓存中
  /// （导入合并查重使用此方法，以避免刷新缓存）。
  Future<List<String>> getMessageIds(String conversationId) async {
    if (_temporaryConversationIds.contains(conversationId)) {
      return [
        for (final message
            in _messagesCache[conversationId] ?? const <ChatMessage>[])
          message.id,
      ];
    }
    if (!_initialized) return const <String>[];
    final cachedOrder = _messageOrderIds[conversationId];
    if (cachedOrder != null) return List<String>.of(cachedOrder);
    return _repo.getMessageIds(conversationId);
  }

  int getMessageIndex(String conversationId, String messageId) {
    if (_temporaryConversationIds.contains(conversationId)) {
      final order = _messageOrderIds[conversationId];
      if (order != null) return order.indexOf(messageId);
      final messages = _messagesCache[conversationId];
      if (messages == null) return -1;
      return messages.indexWhere((message) => message.id == messageId);
    }
    return _messageOrderIds[conversationId]?.indexOf(messageId) ?? -1;
  }

  Map<String, int> getFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) {
    if (!_initialized) return const <String, int>{};
    final ids = groupIds.toSet();
    if (ids.isEmpty) return const <String, int>{};
    final cached = _firstGroupIndicesCache[conversationId] ?? const {};
    return {
      for (final id in ids)
        if (cached[id] != null) id: cached[id]!,
    };
  }

  Future<Map<String, int>> loadFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async {
    final ids = groupIds.toSet();
    if (ids.isEmpty) return const {};
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      final result = <String, int>{};
      final messages = _messagesCache[conversationId] ?? const <ChatMessage>[];
      for (var i = 0; i < messages.length; i++) {
        final groupId = messages[i].groupId ?? messages[i].id;
        if (ids.contains(groupId)) result.putIfAbsent(groupId, () => i);
      }
      return result;
    }
    final loaded = await _repo.getFirstMessageIndicesForGroups(
      conversationId,
      ids,
    );
    _firstGroupIndicesCache
        .putIfAbsent(conversationId, () => {})
        .addAll(loaded);
    return loaded;
  }

  List<ChatMessage> getMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) {
    if (!_initialized) return const <ChatMessage>[];
    final ids = groupIds.toSet();
    if (ids.isEmpty) return const <ChatMessage>[];
    final byId = <String, ChatMessage>{
      for (final message
          in _messagesCache[conversationId] ?? const <ChatMessage>[])
        message.id: message,
      for (final message
          in _groupMessagesCache[conversationId] ?? const <ChatMessage>[])
        message.id: message,
    };
    return byId.values
        .where((message) => ids.contains(message.groupId ?? message.id))
        .toList(growable: false);
  }

  Future<List<ChatMessage>> loadMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async {
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      return getMessagesForGroups(conversationId, groupIds);
    }
    // 面向分组的预加载不得等待或安装完整的顺序骨架。`_cacheLoadedMessages` 只在顺序缺失时合并正文，
    // 绝不从部分分组加载中创建不完整的 `_messageOrderIds` 或写入 `_messageCounts`
    // （存在即完整）。
    final messages = await _repo.getMessagesForGroups(conversationId, groupIds);
    final cached = _groupMessagesCache.putIfAbsent(
      conversationId,
      () => <ChatMessage>[],
    );
    final byId = <String, ChatMessage>{
      for (final message in cached) message.id: message,
      for (final message in messages) message.id: message,
    };
    cached
      ..clear()
      ..addAll(byId.values);
    await _cacheMessageArtifacts(messages);
    return messages;
  }

  /// 仅加载 [conversationId] 已持久化的修订 id。合并去重检查不得将完整消息水合到缓存中，
  /// 因此这里通过 id 顺序骨架处理，而不是 [loadMessages]。
  Future<Set<String>> loadPersistedMessageIds(String conversationId) async {
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      return (_messagesCache[conversationId] ?? const <ChatMessage>[])
          .map((message) => message.id)
          .toSet();
    }
    if (!_initialized) return const <String>{};
    // 合并/去重必须检查每个持久化修订，包括隐藏的
    // 兄弟分支。这刻意独立于聊天界面使用的活动
    // 时间线缓存。
    return (await _repo.getMessageIds(conversationId)).toSet();
  }

  Future<List<ConversationSearchMatch>> searchConversationMatches({
    required List<String> tokens,
    int limit = 200,
    bool includeAllRevisions = false,
    String? conversationId,
    String? excludeConversationId,
    String? assistantId,
  }) async {
    if (!_initialized) return const <ConversationSearchMatch>[];
    return _repo.searchConversationMatches(
      tokens: tokens,
      limit: limit,
      includeAllRevisions: includeAllRevisions,
      conversationId: conversationId,
      excludeConversationId: excludeConversationId,
      assistantId: assistantId,
    );
  }

  Future<List<MiniMapSearchHit>> searchMiniMapMatches(
    String conversationId,
    String query, {
    int snippetRadius = 40,
    int snippetLength = 120,
  }) async {
    if (!_initialized) return const <MiniMapSearchHit>[];
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      return _miniMapHitsFromCachedMessages(
        conversationId,
        query,
        snippetRadius: snippetRadius,
        snippetLength: snippetLength,
      );
    }
    return _repo.searchMiniMapMatches(
      conversationId,
      query,
      snippetRadius: snippetRadius,
      snippetLength: snippetLength,
    );
  }

  List<MiniMapSearchHit> _miniMapHitsFromCachedMessages(
    String conversationId,
    String query, {
    required int snippetRadius,
    required int snippetLength,
  }) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const <MiniMapSearchHit>[];
    final radius = snippetRadius < 0 ? 0 : snippetRadius;
    final length = miniMapSnippetLength(
      needleLength: needle.length,
      snippetRadius: snippetRadius,
      snippetLength: snippetLength,
    );
    final messages = _messagesCache[conversationId] ?? const <ChatMessage>[];
    final groups = <String, List<ChatMessage>>{};
    final order = <String>[];
    for (final message in messages) {
      final groupId = message.groupId ?? message.id;
      if (!groups.containsKey(groupId)) order.add(groupId);
      groups.putIfAbsent(groupId, () => <ChatMessage>[]).add(message);
    }
    final selections = getVersionSelections(conversationId);
    final hits = <MiniMapSearchHit>[];
    for (final groupId in order) {
      final versions = groups[groupId]!
        ..sort((a, b) => a.version.compareTo(b.version));
      final selected =
          versions.cast<ChatMessage?>().firstWhere(
            (message) => message!.version == selections[groupId],
            orElse: () => null,
          ) ??
          versions.last;
      if (selected.role != 'user' && selected.role != 'assistant') continue;
      final text = selected.content;
      final lower = text.toLowerCase();
      final first = lower.indexOf(needle);
      if (first < 0) continue;
      var matchCount = 0;
      var position = 0;
      while (true) {
        final index = lower.indexOf(needle, position);
        if (index < 0) break;
        matchCount++;
        position = index + needle.length;
      }
      final snippetStart = first < radius ? 0 : first - radius;
      final snippetEnd = snippetStart + length > text.length
          ? text.length
          : snippetStart + length;
      hits.add(
        MiniMapSearchHit(
          messageId: selected.id,
          matchCount: matchCount,
          snippet: text.substring(snippetStart, snippetEnd),
          snippetStart: snippetStart,
        ),
      );
    }
    return hits;
  }

  Future<ChatStatsAggregate> loadStatsAggregate({
    required DateTime? rangeStart,
    required DateTime? rangeEndExclusive,
    required DateTime heatmapStart,
    required DateTime trendStart,
    required DateTime trendEndExclusive,
  }) async {
    if (!_initialized) await init();
    return _repo.queryStatsAggregate(
      rangeStart: rangeStart,
      rangeEndExclusive: rangeEndExclusive,
      heatmapStart: heatmapStart,
      trendStart: trendStart,
      trendEndExclusive: trendEndExclusive,
    );
  }

  List<ChatMessage> getMessages(String conversationId) {
    if (!_initialized) return const [];
    return _messagesCache[conversationId] ?? const [];
  }

  // 与 loadMessages 缓存命中分支使用相同的完整性判断。
  bool isConversationFullyCached(String conversationId) {
    if (!_initialized) return false;
    final cached = _messagesCache[conversationId];
    if (cached == null) return false;
    final known =
        _messageCounts[conversationId] ??
        _messageOrderIds[conversationId]?.length;
    return known != null && cached.length == known;
  }

  static const int _titleSourceMaxChars = 3000;

  /// 构建用于 LLM 标题生成的源文本。
  ///
  /// 以两种路径完全相同的方式收集会话尾部（最近的约 3000 个内容字符，并遵循会话的逻辑 truncateIndex）：
  /// 会话完全缓存时从缓存提供，否则从选定的逻辑时间线分页获取。
  Future<String> generateTitleSource(String conversationId) async {
    if (!_initialized) return '';
    if (_conversationForMessages(conversationId) == null) return '';
    final truncateIndex = getContextStartIndex(conversationId);

    final List<ChatMessage> source;
    if (isConversationFullyCached(conversationId)) {
      final selected = _collapseTitleVersions(
        _messagesCache[conversationId]!,
        getVersionSelections(conversationId),
      );
      final start = (truncateIndex >= 0 && truncateIndex <= selected.length)
          ? truncateIndex
          : 0;
      source = _titleSourceTailWindow(selected, start);
    } else {
      source = await _loadTitleSourceTail(
        conversationId,
        truncateIndex: truncateIndex,
      );
    }

    final joined = source
        .where((message) => message.content.isNotEmpty)
        .map(
          (message) =>
              '${message.role == 'assistant' ? 'Assistant' : 'User'}: '
              '${message.content}',
        )
        .join('\n\n');
    return joined.length > _titleSourceMaxChars
        ? joined.substring(0, _titleSourceMaxChars)
        : joined;
  }

  Future<List<ChatMessage>> _loadTitleSourceTail(
    String conversationId, {
    required int truncateIndex,
  }) async {
    final selected = <ChatMessage>[];
    var chars = 0;
    String? beforeRevisionId;
    int? start;
    while (chars < _titleSourceMaxChars) {
      final page = await loadTimelinePage(
        conversationId,
        beforeRevisionId: beforeRevisionId,
        limit: defaultHistoryPageSize,
      );
      if (page == null || page.slots.isEmpty) break;
      start ??= (truncateIndex >= 0 && truncateIndex <= page.totalSlotCount)
          ? truncateIndex
          : 0;
      for (var i = page.slots.length - 1; i >= 0; i--) {
        final slot = page.slots[i];
        if (slot.identity.logicalIndex < start) break;
        selected.insert(0, slot.message);
        chars += slot.message.content.length;
        if (chars >= _titleSourceMaxChars) break;
      }
      if (chars >= _titleSourceMaxChars ||
          !page.hasMoreBefore ||
          page.slots.first.identity.logicalIndex <= start) {
        break;
      }
      beforeRevisionId = page.beforeRevisionId;
      if (beforeRevisionId == null) break;
    }
    return selected;
  }

  /// [_loadTitleSourceTail] 的内存等价实现：从尾部遍历完全缓存的消息列表，
  /// 保留内容合计至少达到 [_titleSourceMaxChars] 个字符的最近消息，
  /// 因此两条 `generateTitleSource` 路径都会向模型提供相同的窗口。
  List<ChatMessage> _titleSourceTailWindow(
    List<ChatMessage> messages,
    int start,
  ) {
    final selected = <ChatMessage>[];
    var chars = 0;
    for (var i = messages.length - 1; i >= start; i--) {
      final message = messages[i];
      selected.insert(0, message);
      chars += message.content.length;
      if (chars >= _titleSourceMaxChars) break;
    }
    return selected;
  }

  List<ChatMessage> _collapseTitleVersions(
    List<ChatMessage> messages,
    Map<String, int> selections,
  ) {
    final byGroup = <String, List<ChatMessage>>{};
    final order = <String>[];
    for (final message in messages) {
      final groupId = message.groupId ?? message.id;
      byGroup
          .putIfAbsent(groupId, () {
            order.add(groupId);
            return <ChatMessage>[];
          })
          .add(message);
    }
    return [
      for (final groupId in order)
        _selectedTitleVersion(byGroup[groupId]!, selections[groupId]),
    ];
  }

  ChatMessage _selectedTitleVersion(
    List<ChatMessage> versions,
    int? selection,
  ) {
    versions.sort((a, b) => a.version.compareTo(b.version));
    if (selection != null) {
      for (final candidate in versions) {
        if (candidate.version == selection) return candidate;
      }
    }
    return versions.last;
  }

  Future<List<ChatMessage>> loadMessages(String conversationId) async {
    if (!_initialized) return const [];
    // 要求已知计数：未知值 (-1) 不得作为缓存命中短路。
    if (isConversationFullyCached(conversationId)) {
      return _messagesCache[conversationId]!;
    }
    final conversation =
        _conversationsCache[conversationId] ??
        _draftConversations[conversationId];
    if (conversation == null) return [];

    if (_temporaryConversationIds.contains(conversationId)) {
      return _messagesCache[conversationId] ?? const <ChatMessage>[];
    }

    await reloadActiveTimelineCache(conversationId);
    return _messagesCache[conversationId] ?? const <ChatMessage>[];
  }

  /// 加载所有持久化消息修订版本，包括隐藏树分支。
  Future<List<ChatMessage>> loadAllConversationMessages(
    String conversationId,
  ) async {
    if (!_initialized) return const <ChatMessage>[];
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      return _messagesCache[conversationId] ?? const <ChatMessage>[];
    }
    final ids = await _repo.getMessageIds(conversationId);
    final messages = await _repo.getMessagesByIds(ids);
    await _cacheMessageArtifacts(messages);
    return List<ChatMessage>.unmodifiable(messages);
  }

  Future<List<ChatMessage>> loadSelectedContextMessages(
    String conversationId, {
    required int truncateIndex,
    required int limit,
    String? throughRevisionId,
    bool includeFollowingAssistant = false,
  }) async {
    if (!_initialized || limit <= 0) return const <ChatMessage>[];
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      final tree = await _loadOrCreateConversationTree(conversationId);
      final byId = <String, ChatMessage>{
        for (final message
            in _messagesCache[conversationId] ?? const <ChatMessage>[])
          message.id: message,
      };
      final selected = <ChatMessage>[
        for (final id in tree.activePath())
          if (byId[id] != null) byId[id]!,
      ];
      var end = selected.length;
      if (throughRevisionId != null) {
        final target = selected.indexWhere(
          (message) => message.id == throughRevisionId,
        );
        if (target < 0) return const <ChatMessage>[];
        end = target + 1;
        if (includeFollowingAssistant && selected[target].role == 'user') {
          final assistant = selected.indexWhere(
            (message) => message.role == 'assistant',
            target + 1,
          );
          if (assistant >= 0) end = assistant + 1;
        }
      }
      final start = truncateIndex >= 0 && truncateIndex <= end
          ? truncateIndex
          : 0;
      final available = end - start;
      final boundedStart = start + (available - limit).clamp(0, available);
      return selected.sublist(boundedStart, end);
    }
    final tree = await _loadOrCreateConversationTree(conversationId);
    final path = tree.activePath();
    var end = path.length;
    if (throughRevisionId != null) {
      final target = path.indexOf(throughRevisionId);
      if (target < 0) return const <ChatMessage>[];
      end = target + 1;
      if (includeFollowingAssistant) {
        final pathMessages = await _repo.getMessagesByIds(path);
        final byId = <String, ChatMessage>{
          for (final message in pathMessages) message.id: message,
        };
        if (byId[throughRevisionId]?.role == 'user') {
          for (var index = target + 1; index < path.length; index++) {
            if (byId[path[index]]?.role == 'assistant') {
              end = index + 1;
              break;
            }
          }
        }
      }
    }
    final start = truncateIndex >= 0 && truncateIndex <= end
        ? truncateIndex
        : 0;
    final available = end - start;
    final boundedStart = start + (available - limit).clamp(0, available);
    final selectedIds = path.sublist(boundedStart, end);
    final loaded = await _repo.getMessagesByIds(selectedIds);
    final byId = <String, ChatMessage>{
      for (final message in loaded) message.id: message,
    };
    final messages = <ChatMessage>[
      for (final id in selectedIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (messages.length != selectedIds.length) {
      throw StateError('context_active_path_message_missing');
    }
    await _cacheMessageArtifacts(messages);
    return List<ChatMessage>.unmodifiable(messages);
  }

  Future<int> getMaxMessageVersionForGroup(
    String conversationId,
    String groupId,
  ) {
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      final versions = (_messagesCache[conversationId] ?? const <ChatMessage>[])
          .where((message) => (message.groupId ?? message.id) == groupId)
          .map((message) => message.version);
      return Future<int>.value(
        versions.isEmpty ? -1 : versions.reduce((a, b) => a > b ? a : b),
      );
    }
    return _repo.getMaxMessageVersionForGroup(conversationId, groupId);
  }

  Future<List<ChatMessage>> loadSelectedMessageProjections(
    String conversationId,
  ) async {
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      return loadSelectedContextMessages(
        conversationId,
        truncateIndex: -1,
        limit: _messagesCache[conversationId]?.length ?? 0,
      );
    }
    return loadActiveTimelineMessages(conversationId);
  }

  Future<List<ChatMessage>> loadMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return const <ChatMessage>[];
    final temporaryById = <String, ChatMessage>{
      for (final conversationId in _temporaryConversationIds)
        for (final message
            in _messagesCache[conversationId] ?? const <ChatMessage>[])
          message.id: message,
    };
    if (ids.every(temporaryById.containsKey)) {
      return [for (final id in ids) temporaryById[id]!];
    }
    final messages = await _repo.getMessagesByIds(ids);
    await _cacheMessageArtifacts(messages);
    return messages;
  }

  Future<Set<String>> loadMessageIdsForGroups(
    String conversationId,
    Set<String> groupIds,
  ) {
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      return Future<Set<String>>.value({
        for (final message
            in _messagesCache[conversationId] ?? const <ChatMessage>[])
          if (groupIds.contains(message.groupId ?? message.id)) message.id,
      });
    }
    return _repo.getMessageIdsForGroups(conversationId, groupIds);
  }

  List<ChatMessage> getMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) {
    if (!_initialized || limit <= 0) return const [];
    if (_temporaryConversationIds.contains(conversationId)) {
      final messages = _messagesCache[conversationId] ?? const <ChatMessage>[];
      final safeStart = start.clamp(0, messages.length).toInt();
      final end = (safeStart + limit).clamp(safeStart, messages.length).toInt();
      return messages.sublist(safeStart, end);
    }
    if (_conversationForMessages(conversationId) == null) return const [];
    final ids = _messageOrderIds[conversationId] ?? const <String>[];
    final safeStart = start.clamp(0, ids.length).toInt();
    final end = (safeStart + limit).clamp(safeStart, ids.length).toInt();
    final byId = {
      for (final message in _messagesCache[conversationId] ?? const [])
        message.id: message,
    };
    return [
      for (final id in ids.sublist(safeStart, end))
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<List<ChatMessage>> loadMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) async {
    if (!_initialized || limit <= 0) return const <ChatMessage>[];

    if (_temporaryConversationIds.contains(conversationId)) {
      final messages = _messagesCache[conversationId] ?? const <ChatMessage>[];
      final safeStart = start.clamp(0, messages.length).toInt();
      final end = (safeStart + limit).clamp(safeStart, messages.length).toInt();
      return safeStart >= end
          ? const <ChatMessage>[]
          : messages.sublist(safeStart, end);
    }

    final conversation = _conversationForMessages(conversationId);
    if (conversation == null) {
      return const <ChatMessage>[];
    }

    final tree = await _loadOrCreateConversationTree(conversationId);
    final ids = tree.activePath();
    _messageOrderIds[conversationId] = List<String>.of(ids);
    _messageCounts[conversationId] = ids.length;
    final safeStart = start.clamp(0, ids.length).toInt();
    final safeEnd = (safeStart + limit).clamp(safeStart, ids.length).toInt();
    if (safeStart >= safeEnd) return const <ChatMessage>[];
    final loaded = await _repo.getMessagesByIds(
      ids.sublist(safeStart, safeEnd),
    );
    final byId = <String, ChatMessage>{
      for (final message in loaded) message.id: message,
    };
    final messages = <ChatMessage>[];
    for (final id in ids.sublist(safeStart, safeEnd)) {
      final message = byId[id];
      if (message == null) {
        throw StateError('active_timeline_message_missing');
      }
      messages.add(message);
    }
    _cacheLoadedMessages(conversationId, messages);
    await _cacheMessageArtifacts(messages);
    return messages;
  }

  List<ChatMessage> getRecentMessages(
    String conversationId, {
    int minMessages = defaultInitialMessageMin,
    int textBudget = defaultInitialTextBudget,
    int maxMessages = defaultInitialMessageMax,
  }) {
    final cached = _messagesCache[conversationId] ?? const <ChatMessage>[];
    if (cached.length <= maxMessages) return List.of(cached);
    return cached.sublist(cached.length - maxMessages);
  }

  Future<List<ChatMessage>> loadRecentMessages(
    String conversationId, {
    int minMessages = defaultInitialMessageMin,
    int textBudget = defaultInitialTextBudget,
    int maxMessages = defaultInitialMessageMax,
  }) async {
    if (!_initialized) return const <ChatMessage>[];

    final conversation = _conversationForMessages(conversationId);
    if (conversation == null) {
      return const <ChatMessage>[];
    }

    // 在空短路/截断之前先解析未知值 (-1)；-1 绝不能
    // 复用 total == 0 分支或成为截断上界。
    final total = await _resolveMessageCount(conversationId);
    if (total == 0) return const <ChatMessage>[];
    final minCount = minMessages.clamp(1, total).toInt();
    final maxCount = maxMessages < minCount ? minCount : maxMessages;
    final budget = textBudget <= 0 ? defaultInitialTextBudget : textBudget;

    var start = total;
    var loaded = 0;
    var weight = 0;
    final selected = <ChatMessage>[];
    while (start > 0 && loaded < maxCount) {
      final batchStart = (start - defaultHistoryPageSize)
          .clamp(0, start)
          .toInt();
      final batch = await loadMessagesRange(
        conversationId,
        start: batchStart,
        limit: start - batchStart,
      );
      for (var i = batch.length - 1; i >= 0 && loaded < maxCount; i--) {
        final message = batch[i];
        selected.insert(0, message);
        loaded++;
        weight += _estimateInitialLoadWeight(message);
        if (loaded >= minCount && weight >= budget) break;
      }
      start = batchStart;
      if (loaded >= minCount && weight >= budget) break;
    }

    if (selected.isNotEmpty && selected.length.isOdd && start > 0) {
      final previous = await loadMessagesRange(
        conversationId,
        start: start - 1,
        limit: 1,
      );
      if (previous.isNotEmpty) {
        selected.insert(0, previous.first);
        start--;
      }
    }

    return selected;
  }

  int _estimateInitialLoadWeight(ChatMessage message) {
    final len = message.content.length;
    if (message.role == 'user') return len < 200 ? 200 : len;
    if (message.role == 'assistant') return (len * 0.8).round();
    return len;
  }

  Future<Conversation> createConversation({
    String? title,
    String? assistantId,
  }) async {
    if (!_initialized) await init();
    _discardTemporaryConversation(_currentConversationId);

    final conversation = Conversation(
      title: title ?? _defaultConversationTitle,
      assistantId: assistantId,
    );

    await _saveConversation(conversation);
    _currentConversationId = conversation.id;
    _enforceMessageCacheLimits();
    _bumpConversationListRevision();
    notifyListeners();
    return conversation;
  }

  Future<void> _saveConversation(Conversation conversation) async {
    if (_temporaryConversationIds.contains(conversation.id)) {
      _draftConversations[conversation.id] = conversation;
      return;
    }
    await _repo.putConversation(conversation);
    _conversationsCache[conversation.id] = conversation;
  }

  Future<void> _refreshConversation(String conversationId) async {
    if (_temporaryConversationIds.contains(conversationId)) return;
    final conversation = await _repo.getConversation(conversationId);
    if (conversation == null) {
      _conversationsCache.remove(conversationId);
    } else {
      _conversationsCache[conversationId] = conversation;
    }
  }

  // 创建一个草稿对话，在首条消息到达前不会持久化。
  Future<Conversation> createDraftConversation({
    String? title,
    String? assistantId,
    bool temporary = false,
  }) async {
    if (!_initialized) await init();
    _discardTemporaryConversation(_currentConversationId);
    final conversation = Conversation(
      title: title ?? _defaultConversationTitle,
      assistantId: assistantId,
    );
    _draftConversations[conversation.id] = conversation;
    if (temporary) {
      _temporaryConversationIds.add(conversation.id);
      _messagesCache[conversation.id] = <ChatMessage>[];
      _temporaryConversationTrees[conversation.id] = ConversationTree.linear(
        conversationId: conversation.id,
        messageIds: const <String>[],
        activeBranchId: 'root-${conversation.id}',
      );
    }
    _currentConversationId = conversation.id;
    _enforceMessageCacheLimits();
    notifyListeners();
    return conversation;
  }

  void _rememberDiscardedTemporaryConversation(String id) {
    _discardedTemporaryConversationIds.add(id);
    final messages = _messagesCache[id] ?? const <ChatMessage>[];
    _discardedTemporaryMessageIds.addAll(messages.map((message) => message.id));
  }

  void _discardTemporaryConversation(String? id) {
    if (id == null || !_temporaryConversationIds.remove(id)) return;
    _rememberDiscardedTemporaryConversation(id);
    final messages = _messagesCache[id] ?? const <ChatMessage>[];
    for (final message in messages) {
      _temporaryToolEvents.remove(message.id);
      _temporaryGeminiThoughtSigs.remove(message.id);
    }
    _draftConversations.remove(id);
    _messagesCache.remove(id);
    _temporaryConversationTrees.remove(id);
    _groupMessagesCache.remove(id);
    if (_currentConversationId == id) {
      _currentConversationId = null;
    }
  }

  Future<void> deleteConversation(String id) async {
    if (!_initialized) return;

    final deleted =
        await _deleteDraftConversation(id) ||
        await _deletePersistedConversation(id);
    if (!deleted) return;

    // 删除孤立文件（未被任何剩余对话引用）
    await _cleanupOrphanUploads();

    notifyListeners();
  }

  Future<Conversation?> duplicateConversation(String id) async {
    if (!_initialized) await init();
    final duplicate = await _repo.duplicateConversation(id);
    if (duplicate == null) return null;

    _conversationsCache[duplicate.id] = duplicate;
    _messageOrderIds[duplicate.id] = List<String>.of(duplicate.messageIds);
    _messageCounts[duplicate.id] = duplicate.messageIds.length;
    _bumpConversationListRevision();
    notifyListeners();
    return duplicate;
  }

  Future<bool> _deleteDraftConversation(String id) async {
    if (!_draftConversations.containsKey(id)) return false;

    _draftConversations.remove(id);
    if (_temporaryConversationIds.remove(id)) {
      _rememberDiscardedTemporaryConversation(id);
    }
    final messages = _messagesCache[id] ?? const <ChatMessage>[];
    for (final message in messages) {
      _temporaryToolEvents.remove(message.id);
      _temporaryGeminiThoughtSigs.remove(message.id);
    }
    _messagesCache.remove(id);
    _temporaryConversationTrees.remove(id);
    _groupMessagesCache.remove(id);
    if (_currentConversationId == id) {
      _currentConversationId = null;
    }
    return true;
  }

  Future<bool> _deletePersistedConversation(
    String id, {
    bool bumpRevision = true,
  }) async {
    final conversation = _conversationsCache[id];
    if (conversation == null) return false;

    await _repo.deleteConversation(id);
    _conversationsCache.remove(id);
    final removedMessages = _messagesCache.remove(id);
    final removedGroupMessages = _groupMessagesCache.remove(id);
    final removedOrder = _messageOrderIds.remove(id);
    _messageCounts.remove(id);
    _firstGroupIndicesCache.remove(id);
    final artifactMessageIds = <String>{
      if (removedMessages != null)
        for (final message in removedMessages) message.id,
      if (removedGroupMessages != null)
        for (final message in removedGroupMessages) message.id,
      ...?removedOrder,
    };
    for (final messageId in artifactMessageIds) {
      _toolEventsCache.remove(messageId);
      _geminiThoughtSigsCache.remove(messageId);
    }

    if (_currentConversationId == id) {
      _currentConversationId = null;
    }
    if (bumpRevision) {
      _bumpConversationListRevision();
    }
    return true;
  }

  Future<void> deleteConversationsForAssistant(String assistantId) async {
    if (!_initialized) await init();

    final targetId = assistantId.trim();
    if (targetId.isEmpty) return;

    final persistedConversationIds = _conversationsCache.values
        .where((conversation) => conversation.assistantId == targetId)
        .map((conversation) => conversation.id)
        .toList(growable: false);
    final draftConversationIds = _draftConversations.values
        .where((conversation) => conversation.assistantId == targetId)
        .map((conversation) => conversation.id)
        .toList(growable: false);

    var deleted = false;
    for (final conversationId in draftConversationIds) {
      deleted = await _deleteDraftConversation(conversationId) || deleted;
    }
    for (final conversationId in persistedConversationIds) {
      deleted =
          await _deletePersistedConversation(
            conversationId,
            bumpRevision: false,
          ) ||
          deleted;
    }

    if (!deleted) return;
    await _cleanupOrphanUploads();
    _bumpConversationListRevision();
    notifyListeners();
  }

  /// 删除每个非空 ID 一次，并且整批最多刷新和通知一次。
  Future<int> deleteConversations(Iterable<String> ids) async {
    if (!_initialized) await init();

    var deleted = 0;
    final seen = <String>{};
    for (final id in ids) {
      if (id.isEmpty || !seen.add(id)) continue;
      if (await _deleteDraftConversation(id) ||
          await _deletePersistedConversation(id, bumpRevision: false)) {
        deleted++;
      }
    }
    if (deleted == 0) return 0;
    await _cleanupOrphanUploads();
    _bumpConversationListRevision();
    notifyListeners();
    return deleted;
  }

  List<({String path, String kind})> _extractLocalAttachmentsFromMessage(
    ChatMessage message,
  ) {
    final fromParts = <String, ({String path, String kind})>{};
    for (final part in message.parts) {
      if (part is ImagePart) {
        // 不可用的占位符保留在历史记录中供 UI 使用，但不得进入
        // 资产同步——否则缺失文件会一直产生脏数据或抛出异常。
        if (part.unavailable) continue;
        final uri = part.uri.trim();
        if (uri.isEmpty || uri.startsWith('http') || uri.startsWith('data:')) {
          continue;
        }
        final fixed = SandboxPathResolver.resolveForIo(uri);
        if (fixed == null) continue;
        fromParts['image:$fixed'] = (path: fixed, kind: 'image');
      } else if (part is FilePart) {
        if (part.unavailable) continue;
        final uri = part.uri.trim();
        if (uri.isEmpty || uri.startsWith('http') || uri.startsWith('data:')) {
          continue;
        }
        final fixed = SandboxPathResolver.resolveForIo(uri);
        if (fixed == null) continue;
        fromParts['file:$fixed'] = (path: fixed, kind: 'file');
      }
    }
    return List.unmodifiable(fromParts.values);
  }

  /// 可用于 OCR 身份识别的图像来源：本地文件和 data URLs。
  ///
  /// 仅支持 Parts——content-marker 回退有意不受支持。
  List<String> _extractOcrImageSourcesFromMessage(ChatMessage message) {
    final fromParts = <String>[];
    for (final part in message.parts) {
      if (part is! ImagePart) continue;
      final path = part.uri.trim();
      if (path.isEmpty || path.startsWith('http')) continue;
      if (path.startsWith('data:')) {
        fromParts.add(path);
      } else {
        final resolved = SandboxPathResolver.resolveForIo(path);
        if (resolved != null) fromParts.add(resolved);
      }
    }
    return fromParts;
  }

  bool _messageCanOwnAssets(ChatMessage message) => message.parts.any(
    (part) =>
        part is ImagePart ||
        part is FilePart ||
        (part is MalformedPart && part.isAttachmentKind),
  );

  Future<void> _backfillAssetReferences(Directory appDataDir) async {
    final targetRoot = p.normalize(appDataDir.absolute.path);
    final includeLegacyCandidates = await _repo.needsAssetReferenceBackfill(
      version: _assetReferenceBackfillVersion,
      targetRoot: targetRoot,
    );
    if (!includeLegacyCandidates &&
        !await _repo.hasPendingAssetReferenceSync()) {
      return;
    }
    var cursor = '';
    var loggedMalformedAttachment = false;
    while (true) {
      final messages = await _repo.getMessagesForAssetReferenceBackfill(
        afterMessageId: cursor,
        includeLegacyCandidates: includeLegacyCandidates,
      );
      if (messages.isEmpty) break;
      for (final message in messages) {
        cursor = message.id;
        try {
          final synchronized = await _synchronizeMessageAssets(message);
          if (!synchronized && !loggedMalformedAttachment) {
            debugPrint(
              'Asset reference backfill left malformed attachment revisions '
              'dirty; they will be retried on the next maintenance pass.',
            );
            loggedMalformedAttachment = true;
          }
        } catch (error) {
          debugPrint('Asset reference backfill skipped ${message.id}: $error');
        }
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (includeLegacyCandidates) {
      await _repo.markAssetReferenceBackfillComplete(
        version: _assetReferenceBackfillVersion,
        targetRoot: targetRoot,
      );
    }
  }

  Future<void> runAssetReferenceMaintenance() async {
    if (!_initialized) await init();
    return _runAssetReferenceMaintenance(
      await AppDirectories.getAppDataDirectory(),
    );
  }

  Future<void> _runAssetReferenceMaintenance(Directory appDataDir) {
    final inFlight = _assetReferenceMaintenanceFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> tracked;
    tracked = _backfillAssetReferences(appDataDir).whenComplete(() {
      if (identical(_assetReferenceMaintenanceFuture, tracked)) {
        _assetReferenceMaintenanceFuture = null;
      }
    });
    _assetReferenceMaintenanceFuture = tracked;
    return tracked;
  }

  Future<void> _backfillAssetReferencesForCurrentRoot() async {
    await runAssetReferenceMaintenance();
  }

  Future<bool> _synchronizeMessageAssets(ChatMessage message) async {
    if (isTemporaryConversation(message.conversationId)) return true;
    if (message.parts.any(
      (part) => part is MalformedPart && part.isAttachmentKind,
    )) {
      // 仅凭解析不足以构建权威的替换集合。
      // 保留现有 message_asset_rows，并让该修订保持可重试。
      await _repo.markMessageAssetReferencesDirty(message.id);
      return false;
    }
    final appDataDir = await AppDirectories.getAppDataDirectory();
    final allowedRoots = [
      p.normalize(p.join(appDataDir.absolute.path, 'upload')),
      p.normalize(p.join(appDataDir.absolute.path, 'images')),
    ];
    final registrations = <MessageAssetRegistration>[];
    for (final attachment in _extractLocalAttachmentsFromMessage(message)) {
      final normalizedPath = p.normalize(File(attachment.path).absolute.path);
      if (!allowedRoots.any((root) => p.isWithin(root, normalizedPath))) {
        continue;
      }
      final file = File(normalizedPath);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        await _repo.markMessageAssetReferencesDirty(message.id);
        throw StateError('asset_file_unavailable');
      }
      final contentHash = await _assetContentHash(file);
      registrations.add(
        MessageAssetRegistration(
          assetId: 'asset_$contentHash',
          contentHash: contentHash,
          path: SandboxPathResolver.canonicalize(normalizedPath),
          byteSize: await file.length(),
          kind: attachment.kind,
        ),
      );
    }
    await _repo.replaceMessageAssetReferences(
      conversationId: message.conversationId,
      revisionId: message.id,
      assets: registrations,
    );
    return true;
  }

  static Future<String> _hashAssetFile(File file) {
    final path = file.path;
    return Isolate.run(
      () async => (await sha256.bind(File(path).openRead()).first).toString(),
    );
  }

  Future<void> _synchronizeMessageAssetsBestEffort(ChatMessage message) async {
    try {
      await _synchronizeMessageAssets(message);
    } catch (error) {
      // 消息持久化是权威来源。消息事务会先排队
      // 相关修订，因此资产索引更新失败会由
      // 有界启动回填重试，而不是导致发送失败。
      debugPrint('Message asset synchronization failed: $error');
    }
  }

  Future<void> _migrateSandboxPaths() async {
    if (SandboxPathResolver.docsDir == null) {
      await SandboxPathResolver.init();
    }
    final targetRoot = SandboxPathResolver.docsDir;
    if (targetRoot == null || targetRoot.isEmpty) {
      throw StateError('sandbox_path_resolver_not_ready');
    }
    final result = await _repo.migrateSandboxPaths(
      targetVersion: 1,
      targetRoot: targetRoot,
      rewriteUri: SandboxPathResolver.canonicalize,
    );
    if (result.skippedParts > 0) {
      debugPrint(
        'Sandbox path migration completed with '
        '${result.skippedParts} malformed attachment parts unchanged.',
      );
    }
  }

  /// 重置因上次应用崩溃或强制退出而残留的过期 isStreaming 标记。全新启动后，
  /// 不会有消息正在流式传输，因此任何持久化的 `isStreaming: true` 都已过期，
  /// 必须清除，以避免加载指示器卡住。
  ///
  Future<void> _resetStaleStreamingFlags() async {
    await _repo.resetStaleStreamingState();
  }

  Future<void> runAssetMaintenance({DateTime? now}) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    try {
      await _repo.scheduleUnreferencedAssetGc(
        notBefore: effectiveNow.add(_assetGcDelay),
      );
      final candidates = await _repo.claimAssetGc(now: effectiveNow);
      final appDataDir = await AppDirectories.getAppDataDirectory();
      final allowedRoots = [
        p.normalize(p.join(appDataDir.absolute.path, 'upload')),
        p.normalize(p.join(appDataDir.absolute.path, 'images')),
      ];
      for (final candidate in candidates) {
        final paths = [
          candidate.path,
          candidate.thumbnailPath,
        ].whereType<String>();
        final regularFiles = <File>[];
        var safe = true;
        for (final candidatePath in paths) {
          final resolved = SandboxPathResolver.resolveForIo(candidatePath);
          if (resolved == null) {
            safe = false;
            break;
          }
          final normalized = p.normalize(File(resolved).absolute.path);
          if (!allowedRoots.any((root) => p.isWithin(root, normalized))) {
            safe = false;
            break;
          }
          final type = await FileSystemEntity.type(
            normalized,
            followLinks: false,
          );
          if (type == FileSystemEntityType.file) {
            regularFiles.add(File(normalized));
          } else if (type != FileSystemEntityType.notFound) {
            safe = false;
            break;
          }
        }
        if (!safe) continue;
        if (!await _repo.isAssetGcClaimStillValid(candidate)) continue;
        final quarantined = <({File original, File quarantine})>[];
        try {
          for (final file in regularFiles) {
            final quarantine = File(
              '${file.path}.kelivo-gc-${candidate.assetId}-'
              '${candidate.generation}',
            );
            if (await quarantine.exists()) {
              safe = false;
              break;
            }
            await file.rename(quarantine.path);
            quarantined.add((original: file, quarantine: quarantine));
          }
          if (!safe) continue;
          final completed = await _repo.completeAssetGc(
            assetId: candidate.assetId,
            expectedGeneration: candidate.generation,
            path: candidate.path,
          );
          if (!completed) continue;
          for (final moved in quarantined) {
            await moved.quarantine.delete();
          }
          quarantined.clear();
        } finally {
          for (final moved in quarantined.reversed) {
            if (!await moved.original.exists() &&
                await moved.quarantine.exists()) {
              await moved.quarantine.rename(moved.original.path);
            }
          }
        }
      }
    } catch (error) {
      debugPrint('Asset maintenance failed: $error');
    }
  }

  Future<void> _cleanupOrphanUploads() => runAssetMaintenance();

  Future<void> restoreConversation(
    Conversation conversation,
    List<ChatMessage> messages, {

    /// Used by structured imports and debug fixtures that already know the
    /// message-level tree. Omitted callers retain legacy linear projection.
    ConversationTree? conversationTree,
  }) async {
    if (!_initialized) await init();
    // 确保 messageIds 保持相同的顺序
    final ids = messages.map((m) => m.id).toList();
    final restored = Conversation(
      id: conversation.id,
      title: conversation.title,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      messageIds: ids,
      isPinned: conversation.isPinned,
      mcpServerIds: List.of(conversation.mcpServerIds),
      truncateIndex: conversation.truncateIndex,
      assistantId: conversation.assistantId,
      versionSelections: Map<String, int>.from(conversation.versionSelections),
      summary: conversation.summary,
      lastSummarizedMessageCount: conversation.lastSummarizedMessageCount,
      chatSuggestions: List<String>.of(conversation.chatSuggestions),
    );
    await _repo.putMigrationBatch(
      conversations: [restored],
      messages: [
        for (final (index, message) in messages.indexed)
          (message: message, messageOrder: index),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
      conversationTree: conversationTree,
    );
    await _backfillAssetReferencesForCurrentRoot();
    await _refreshConversation(restored.id);

    // 更新缓存
    _messagesCache[restored.id] = List.of(messages);
    _messageOrderIds[restored.id] = messages
        .map((message) => message.id)
        .toList(growable: true);
    _messageCounts[restored.id] = messages.length;
    _bumpConversationListRevision();
    notifyListeners();
  }

  /// 发布完全解析后的外部导入。聊天行和关联的业务补丁在一个事务中提交；
  /// 缓存和文件仅在该事务成功之后才变更。
  Future<void> commitParsedImport({
    required BusinessRepository businessRepository,
    required bool overwrite,
    required List<ParsedChatImportBatch> conversationBatches,
    required Map<String, List<ChatMessage>> messagesToAppend,
    required BusinessSnapshot Function(BusinessSnapshot current)
    transformBusiness,
  }) async {
    if (!_initialized) await init();
    await _repo.commitParsedImport(
      businessRepository: businessRepository,
      overwrite: overwrite,
      conversationBatches: conversationBatches,
      messagesToAppend: messagesToAppend,
      transformBusiness: transformBusiness,
    );

    if (overwrite) {
      await _resetAfterOverwriteRestore();
      await _deleteUploadDirectory();
      return;
    }
    _clearPersistedMessageCache();
    await _backfillAssetReferencesForCurrentRoot();
    await _loadConversationsCache();
    notifyListeners();
  }

  Future<void> replaceAllDataFromBackup({
    required List<Conversation> conversations,
    required List<ChatMessage> messages,
    required Map<String, List<Map<String, dynamic>>> toolEventsByMessageId,
    required Map<String, String> geminiSignaturesByMessageId,
  }) async {
    if (!_initialized) await init();

    final nextOrderByConversation = <String, int>{};
    final orderedMessages = <({ChatMessage message, int messageOrder})>[];
    for (final message in messages) {
      final messageOrder = nextOrderByConversation.update(
        message.conversationId,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      orderedMessages.add((message: message, messageOrder: messageOrder));
    }

    await _repo.replaceBackupData(
      conversations: conversations,
      messages: orderedMessages,
      toolEventsByMessageId: toolEventsByMessageId,
      geminiSignaturesByMessageId: geminiSignaturesByMessageId,
    );

    await _resetAfterOverwriteRestore();
  }

  Future<ChatDatabaseSnapshotInfo> createBackupDatabaseSnapshot(
    File destinationFile, {
    ProgressCallback? onProgress,
    BackupCancelToken? cancelToken,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (!_initialized) await init();
    final sourcePath = _databaseFile.path;
    final destinationPath = destinationFile.path;
    try {
      return await runBackupIsolate<ChatDatabaseSnapshotInfo, List<String>>(
        body: _createBackupSnapshotInIsolate,
        payload: [sourcePath, destinationPath],
        cancelToken: cancelToken,
        onProgress: onProgress,
        timeout: timeout,
      );
    } catch (error) {
      Future<void> deleteDestination() async {
        try {
          if (await destinationFile.exists()) await destinationFile.delete();
        } catch (_) {}
      }

      if (error is BackupCancelledException && !error.isolateExited) {
        final exit = error.isolateExit;
        if (exit != null) unawaited(exit.then((_) => deleteDestination()));
      } else {
        await deleteDestination();
      }
      rethrow;
    }
  }

  static Future<ChatDatabaseSnapshotInfo> _createBackupSnapshotInIsolate(
    BackupIsolateContext context,
    List<String> paths,
  ) {
    context.throwIfCancelled();
    return ChatDatabaseRepository.createConsistentSnapshot(
      sourceFile: File(paths[0]),
      destinationFile: File(paths[1]),
      registerSourceHandle: context.registerSqliteHandle,
      waitForSourceCloseAck: context.waitForSqliteClose,
    );
  }

  Future<BackupMergeReport> mergeDatabaseSnapshot(File snapshotFile) async {
    if (!_initialized) await init();
    final report = await _repo.mergeBackupSnapshot(snapshotFile);
    _clearPersistedMessageCache();
    await _backfillAssetReferencesForCurrentRoot();
    await _loadConversationsCache();
    notifyListeners();
    return report;
  }

  /// 仅针对已导入对话的 Chats 合并/恢复后续处理。
  Future<int> recomputeImportedAttachmentAvailability({
    required Iterable<String> conversationIds,
    required bool filesRestored,
  }) async {
    if (!_initialized) await init();
    final updated = await _repo.recomputeAttachmentAvailabilityForConversations(
      conversationIds: conversationIds,
      filesRestored: filesRestored,
    );
    if (updated > 0) {
      _clearPersistedMessageCache();
      notifyListeners();
    }
    return updated;
  }

  Future<void> _resetAfterOverwriteRestore() async {
    for (final id in _temporaryConversationIds) {
      _rememberDiscardedTemporaryConversation(id);
    }
    _messagesCache.clear();
    _draftConversations.clear();
    _temporaryConversationIds.clear();
    _temporaryConversationTrees.clear();
    _temporaryToolEvents.clear();
    _temporaryGeminiThoughtSigs.clear();
    _toolEventsCache.clear();
    _geminiThoughtSigsCache.clear();
    _messageCounts.clear();
    _messageOrderIds.clear();
    _currentConversationId = null;
    await _backfillAssetReferencesForCurrentRoot();
    await _loadConversationsCache();
    notifyListeners();
  }

  // 直接将消息添加到现有对话（用于合并模式）
  Future<void> addMessageDirectly(
    String conversationId,
    ChatMessage message,
  ) async {
    if (!_initialized) await init();

    final conversation = _conversationsCache[conversationId];
    if (conversation == null) return;
    if (await _repo.getMessage(message.id) != null) return;
    final persisted = await _repo.appendLinearMessageToConversation(
      conversation: conversation,
      message: message,
      touchUpdatedAt: false,
    );
    if (_messageCanOwnAssets(message)) {
      await _synchronizeMessageAssetsBestEffort(message);
    }
    _conversationsCache[conversationId] = persisted;
    await reloadActiveTimelineCache(conversationId);

    notifyListeners();
  }

  // 对话范围内的 MCP 服务器选择
  List<String> getConversationMcpServers(String conversationId) {
    if (!_initialized) return const <String>[];
    final c =
        _conversationsCache[conversationId] ??
        _draftConversations[conversationId];
    return c?.mcpServerIds ?? const <String>[];
  }

  Future<void> setConversationMcpServers(
    String conversationId,
    List<String> serverIds,
  ) async {
    if (!_initialized) await init();
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.mcpServerIds = List.of(serverIds);
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    final c = _conversationsCache[conversationId];
    if (c == null) return;
    c.mcpServerIds = List.of(serverIds);
    c.updatedAt = DateTime.now();
    await _saveConversation(c);
    _bumpConversationListRevision();
    notifyListeners();
  }

  Future<void> toggleConversationMcpServer(
    String conversationId,
    String serverId,
    bool enabled,
  ) async {
    final current = getConversationMcpServers(conversationId);
    final set = current.toSet();
    if (enabled) {
      set.add(serverId);
    } else {
      set.remove(serverId);
    }
    await setConversationMcpServers(conversationId, set.toList());
  }

  Future<void> renameConversation(String id, String newTitle) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(id)) {
      final draft = _draftConversations[id]!;
      draft.title = newTitle;
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    final conversation = _conversationsCache[id];
    if (conversation == null) return;

    conversation.title = newTitle;
    conversation.updatedAt = DateTime.now();
    await _saveConversation(conversation);
    _bumpConversationListRevision();
    notifyListeners();
  }

  /// 更新由 LLM 生成的对话摘要。
  Future<void> updateConversationSummary(
    String id,
    String summary,
    int messageCount,
  ) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(id)) {
      final draft = _draftConversations[id]!;
      draft.summary = summary;
      draft.lastSummarizedMessageCount = messageCount;
      notifyListeners();
      return;
    }

    final conversation = _conversationsCache[id];
    if (conversation == null) return;

    conversation.summary = summary;
    conversation.lastSummarizedMessageCount = messageCount;
    await _saveConversation(conversation);
    notifyListeners();
  }

  /// 获取特定助手所有摘要非空的对话。
  List<Conversation> getConversationsWithSummaryForAssistant(
    String assistantId,
  ) {
    if (!_initialized) return [];
    return getAllConversations()
        .where(
          (c) =>
              c.assistantId == assistantId &&
              c.summary != null &&
              c.summary!.trim().isNotEmpty,
        )
        .toList();
  }

  /// 清除特定对话的摘要。
  Future<void> clearConversationSummary(String conversationId) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.summary = null;
      draft.lastSummarizedMessageCount = 0;
      notifyListeners();
      return;
    }

    final conversation = _conversationsCache[conversationId];
    if (conversation == null) return;

    conversation.summary = null;
    conversation.lastSummarizedMessageCount = 0;
    await _saveConversation(conversation);
    notifyListeners();
  }

  Future<void> updateConversationSuggestions(
    String conversationId,
    List<String> suggestions,
  ) async {
    if (!_initialized) return;

    final clean = suggestions
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(3)
        .toList();

    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.chatSuggestions = clean;
      notifyListeners();
      return;
    }

    final conversation = _conversationsCache[conversationId];
    if (conversation == null) return;

    conversation.chatSuggestions = clean;
    await _saveConversation(conversation);
    notifyListeners();
  }

  Future<void> clearConversationSuggestions(String conversationId) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      if (draft.chatSuggestions.isEmpty) return;
      draft.chatSuggestions = <String>[];
      notifyListeners();
      return;
    }

    final conversation = _conversationsCache[conversationId];
    if (conversation == null || conversation.chatSuggestions.isEmpty) return;

    conversation.chatSuggestions = <String>[];
    await _saveConversation(conversation);
    notifyListeners();
  }

  Future<void> togglePinConversation(String id) async {
    if (!_initialized) return;

    if (_draftConversations.containsKey(id)) {
      final draft = _draftConversations[id]!;
      draft.isPinned = !draft.isPinned;
      notifyListeners();
      return;
    }
    final conversation = _conversationsCache[id];
    if (conversation == null) return;

    conversation.isPinned = !conversation.isPinned;
    await _saveConversation(conversation);
    _bumpConversationListRevision();
    notifyListeners();
  }

  /// 把每个会话的置顶状态设为 [pinned]，跳过无变化和不存在的 ID。
  Future<int> setConversationsPinned(Iterable<String> ids, bool pinned) async {
    if (!_initialized) await init();

    var changed = 0;
    final seen = <String>{};
    for (final id in ids) {
      if (id.isEmpty || !seen.add(id)) continue;
      final draft = _draftConversations[id];
      if (draft != null) {
        if (draft.isPinned == pinned) continue;
        draft.isPinned = pinned;
        changed++;
        continue;
      }
      final conversation = _conversationsCache[id];
      if (conversation == null || conversation.isPinned == pinned) continue;
      conversation.isPinned = pinned;
      await _saveConversation(conversation);
      changed++;
    }
    if (changed == 0) return 0;
    _bumpConversationListRevision();
    notifyListeners();
    return changed;
  }

  Future<ChatMessage> addMessage({
    required String conversationId,
    required String role,
    String content = '',
    List<MessagePart>? parts,
    String? modelId,
    String? providerId,
    int? totalTokens,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
    bool isStreaming = false,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? groupId,
    int? version,
    bool selectVersion = false,
    String? parentMessageId,
    String? branchId,
  }) async {
    if (!_initialized) await init();

    var conversation = _conversationsCache[conversationId];
    final temporary = _temporaryConversationIds.contains(conversationId);
    if (conversation == null) {
      final draft = temporary
          ? _draftConversations[conversationId]
          : _draftConversations[conversationId];
      if (draft != null) {
        conversation = draft;
      } else {
        conversation = Conversation(
          id: conversationId,
          title: _defaultConversationTitle,
        );
        if (temporary) {
          _draftConversations[conversationId] = conversation;
        }
      }
    }

    final message = ChatMessage(
      role: role,
      content: parts == null ? content : null,
      parts: parts,
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerId,
      totalTokens: totalTokens,
      translation: translation,
      reasoningSegmentsJson: reasoningSegmentsJson,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      durationMs: durationMs,
      isStreaming: isStreaming,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      groupId: groupId,
      version: version,
    );

    if (_discardedTemporaryConversationIds.contains(conversationId)) {
      _discardedTemporaryMessageIds.add(message.id);
      return message;
    }

    if (temporary) {
      var tree = await _loadOrCreateConversationTree(conversationId);
      var effectiveParentMessageId = parentMessageId;
      var effectiveBranchId = branchId;
      // 旧调用方可能仍通过 selectVersion 写入一条版本。把它转换为
      // 树上的兄弟节点，字段只作为兼容元数据，不参与活动路径计算。
      if (selectVersion &&
          groupId != null &&
          parentMessageId == null &&
          branchId == null) {
        final source = (_messagesCache[conversationId] ?? const <ChatMessage>[])
            .where(
              (candidate) => (candidate.groupId ?? candidate.id) == groupId,
            )
            .lastOrNull;
        final sourceEdge = source == null ? null : tree.edges[source.id];
        if (sourceEdge != null) {
          effectiveParentMessageId = sourceEdge.parentMessageId;
          effectiveBranchId = 'branch-${const Uuid().v4()}';
          tree = tree.createMessageBranchFromParent(
            branchId: effectiveBranchId,
            fromMessageId: effectiveParentMessageId,
          );
        }
      }
      final updatedTree = tree.appendToActiveBranch(
        message.id,
        parentMessageId: effectiveParentMessageId,
        branchId: effectiveBranchId,
        createdAt: message.timestamp,
        activate: effectiveBranchId != null,
      );
      _temporaryConversationTrees[conversationId] = updatedTree;
      _messageOrderIds[conversationId] = updatedTree.activePath();
      _messageCounts[conversationId] = updatedTree.activePath().length;
      conversation.messageIds.add(message.id);
      conversation.updatedAt = DateTime.now();
      if (selectVersion) {
        conversation.versionSelections[groupId ?? message.id] = message.version;
      }
      _messagesCache.putIfAbsent(conversationId, () => <ChatMessage>[]);
    } else {
      if (_conversationsCache.containsKey(conversationId)) {
        await _loadMessageOrder(conversationId);
      }
      final persisted = await _repo.appendLinearMessageToConversation(
        conversation: conversation,
        message: message,
        selectVersion: selectVersion,
      );
      if (_messageCanOwnAssets(message)) {
        await _synchronizeMessageAssetsBestEffort(message);
      }
      _draftConversations.remove(conversationId);
      _conversationsCache[conversationId] = persisted;
      conversation = persisted;
      await reloadActiveTimelineCache(conversationId);
      // 持久化追加会修改 updatedAt（列表顺序），并可能将
      // 草稿提升为持久化列表。
      _bumpConversationListRevision();
    }

    // 更新缓存
    if (_messagesCache.containsKey(conversationId) && temporary) {
      _messagesCache[conversationId]!.add(message);
    }
    _touchMessageCache(conversationId);

    notifyListeners();
    return message;
  }

  Future<GenerationBeginResult> beginSendGeneration({
    required String conversationId,
    required List<MessagePart> userParts,
    required String modelId,
    required String providerId,
  }) async {
    if (!_initialized) await init();
    if (isTemporaryConversation(conversationId)) {
      throw StateError('temporary_generation_is_not_persisted');
    }
    final conversation =
        _conversationsCache[conversationId] ??
        _draftConversations[conversationId] ??
        Conversation(id: conversationId, title: _defaultConversationTitle);
    if (_conversationsCache.containsKey(conversationId)) {
      await _loadMessageOrder(conversationId);
    }
    final userMessage = ChatMessage(
      role: 'user',
      parts: userParts,
      conversationId: conversationId,
    );
    final assistantMessage = ChatMessage(
      role: 'assistant',
      content: '',
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerId,
      isStreaming: true,
    );
    final result = await _repo.beginSendGeneration(
      conversation: conversation,
      userMessage: userMessage,
      assistantMessage: assistantMessage,
      runId: const Uuid().v4(),
    );
    await _publishGenerationBegin(result);
    return result;
  }

  Future<GenerationBeginResult> beginRegeneration({
    required String conversationId,
    required String modelId,
    required String providerId,
    required String groupId,
    required int version,
    required bool truncateFuture,
    String? parentMessageId,
    String? branchId,
  }) async {
    if (!_initialized) await init();
    if (isTemporaryConversation(conversationId)) {
      throw StateError('temporary_generation_is_not_persisted');
    }
    final conversation = _conversationsCache[conversationId];
    if (conversation == null) throw StateError('conversation_missing');
    await _loadMessageOrder(conversationId);
    final assistantMessage = ChatMessage(
      role: 'assistant',
      content: '',
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerId,
      isStreaming: true,
      groupId: groupId,
      version: version,
    );
    final result = await _repo.beginRegeneration(
      conversation: conversation,
      assistantMessage: assistantMessage,
      runId: const Uuid().v4(),
      truncateFuture: truncateFuture,
      parentMessageId: parentMessageId,
      branchId: branchId,
    );
    if (truncateFuture) {
      _messagesCache.remove(conversationId);
      _messageOrderIds.remove(conversationId);
      _firstGroupIndicesCache.remove(conversationId);
      await _loadMessageOrder(conversationId);
    }
    await _publishGenerationBegin(result);
    return result;
  }

  Future<GenerationBeginResult> beginAssistantGeneration({
    required String conversationId,
    required String modelId,
    required String providerId,
    required String anchorGroupId,
    required bool truncateFuture,
    String? parentMessageId,
    String? branchId,
  }) async {
    if (!_initialized) await init();
    if (isTemporaryConversation(conversationId)) {
      throw StateError('temporary_generation_is_not_persisted');
    }
    final conversation = _conversationsCache[conversationId];
    if (conversation == null) throw StateError('conversation_missing');
    await _loadMessageOrder(conversationId);
    final assistantMessage = ChatMessage(
      role: 'assistant',
      content: '',
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerId,
      isStreaming: true,
    );
    final result = await _repo.beginAssistantGeneration(
      conversation: conversation,
      assistantMessage: assistantMessage,
      anchorGroupId: anchorGroupId,
      runId: const Uuid().v4(),
      truncateFuture: truncateFuture,
      parentMessageId: parentMessageId,
      branchId: branchId,
    );
    if (truncateFuture) {
      _messagesCache.remove(conversationId);
      _messageOrderIds.remove(conversationId);
      _firstGroupIndicesCache.remove(conversationId);
      await _loadMessageOrder(conversationId);
    }
    await _publishGenerationBegin(result);
    return result;
  }

  Future<void> _publishGenerationBegin(GenerationBeginResult result) async {
    final conversationId = result.conversation.id;
    _draftConversations.remove(conversationId);
    _conversationsCache[conversationId] = result.conversation;
    if (result.userMessage case final userMessage?
        when _messageCanOwnAssets(userMessage)) {
      await _synchronizeMessageAssetsBestEffort(userMessage);
    }
    await reloadActiveTimelineCache(conversationId);
    _bumpConversationListRevision();
    notifyListeners();
  }

  ChatMessage? _cachedTemporaryMessage(String messageId) {
    for (final entry in _messagesCache.entries) {
      if (!_temporaryConversationIds.contains(entry.key)) continue;
      for (final message in entry.value) {
        if (message.id == messageId) return message;
      }
    }
    return null;
  }

  bool _isTemporaryMessageId(String messageId) {
    return _cachedTemporaryMessage(messageId) != null;
  }

  void _replaceCachedMessage(ChatMessage updatedMessage) {
    final messages = _messagesCache[updatedMessage.conversationId];
    if (messages != null) {
      final index = messages.indexWhere((m) => m.id == updatedMessage.id);
      if (index >= 0) messages[index] = updatedMessage;
      _touchMessageCache(updatedMessage.conversationId);
    }
    final groupMessages = _groupMessagesCache[updatedMessage.conversationId];
    if (groupMessages != null) {
      final index = groupMessages.indexWhere((m) => m.id == updatedMessage.id);
      if (index >= 0) groupMessages[index] = updatedMessage;
    }
  }

  Future<void> updateMessage(
    String messageId, {
    String? content,
    int? totalTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    return _updateMessage(
      messageId,
      notify: true,
      content: content,
      totalTokens: totalTokens,
      isStreaming: isStreaming,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      translation: translation,
      reasoningSegmentsJson: reasoningSegmentsJson,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      durationMs: durationMs,
    );
  }

  /// 用编辑器提供的完整结构化部件覆盖原消息，保留消息 ID、版本和树位置。
  ///
  /// 这条路径与流式消息的部分字段更新分开，避免把编辑器中的附件或未知
  /// 部件折叠成纯文本，也避免创建新的消息分支。
  Future<ChatMessage?> overwriteMessage({
    required String messageId,
    required List<MessagePart> parts,
  }) async {
    if (!_initialized) await init();

    final temporaryOriginal = _cachedTemporaryMessage(messageId);
    if (temporaryOriginal != null) {
      final updated = temporaryOriginal.copyWith(
        parts: parts,
        isStreaming: false,
      );
      _replaceCachedMessage(updated);
      notifyListeners();
      return updated;
    }

    final original = await _repo.getMessage(messageId);
    if (original == null) return null;

    // 即使新部件不含附件，也要让旧消息的资产引用进入清理队列。
    await _repo.markMessageAssetReferencesDirty(messageId);
    final updated = original.copyWith(parts: parts, isStreaming: false);
    await _repo.updateMessage(updated);
    if (_messageCanOwnAssets(updated)) {
      await _synchronizeMessageAssetsBestEffort(updated);
    }
    _replaceCachedMessage(updated);
    notifyListeners();
    return updated;
  }

  Future<bool> switchMessageRole(String messageId, String role) async {
    if (role != 'user' && role != 'assistant') {
      throw ArgumentError.value(role, 'role', 'must be user or assistant');
    }
    if (!_initialized) await init();

    final temporaryMessage = _cachedTemporaryMessage(messageId);
    if (temporaryMessage != null) {
      if (temporaryMessage.role == role) return false;
      _replaceCachedMessage(temporaryMessage.copyWith(role: role));
      notifyListeners();
      return true;
    }

    final current = await _repo.getMessage(messageId);
    if (current == null || current.role == role) return false;
    final updated = await _repo.updateMessageFields(messageId, role: role);
    if (updated == null) return false;
    // Changing role changes the prompt semantics; a frozen prompt can no
    // longer be reused for this revision.
    await _repo.deleteMessagePrompt(messageId);
    _replaceCachedMessage(updated);
    notifyListeners();
    return true;
  }

  /// 在流式传输期间更新消息内容，而不触发 notifyListeners。
  /// 这用于流式更新，避免观察 ChatService 的 widget（例如 side_drawer）进行不必要的重建。
  Future<void> updateMessageSilent(
    String messageId, {
    String? content,
    int? totalTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    return _updateMessage(
      messageId,
      notify: false,
      content: content,
      totalTokens: totalTokens,
      isStreaming: isStreaming,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      translation: translation,
      reasoningSegmentsJson: reasoningSegmentsJson,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      durationMs: durationMs,
    );
  }

  // 仅进行部分列写入：并发写入者更新互不相交的字段
  // （例如翻译与图像清理）时不得互相覆盖。
  Future<void> _updateMessage(
    String messageId, {
    required bool notify,
    String? content,
    int? totalTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) async {
    if (!_initialized) return;

    // 临时对话仅存在于内存中。
    final temporaryMessage = _cachedTemporaryMessage(messageId);
    if (temporaryMessage != null) {
      _replaceCachedMessage(
        temporaryMessage.copyWith(
          content: content,
          totalTokens: totalTokens,
          isStreaming: isStreaming,
          reasoningText: reasoningText,
          reasoningStartAt: reasoningStartAt,
          reasoningFinishedAt: reasoningFinishedAt,
          translation: translation,
          reasoningSegmentsJson: reasoningSegmentsJson,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          cachedTokens: cachedTokens,
          durationMs: durationMs,
        ),
      );
      if (notify) notifyListeners();
      return;
    }

    if (content != null) {
      await _repo.markMessageAssetReferencesDirty(messageId);
    }

    final updatedMessage = await _repo.updateMessageFields(
      messageId,
      content: content,
      totalTokens: totalTokens,
      isStreaming: isStreaming,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      translation: translation,
      reasoningSegmentsJson: reasoningSegmentsJson,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      durationMs: durationMs,
    );
    if (updatedMessage == null) return;

    if (content != null) {
      await _synchronizeMessageAssetsBestEffort(updatedMessage);
    }

    _replaceCachedMessage(updatedMessage);
    if (notify) notifyListeners();
  }

  /// 在不先读后写的情况下持久化一个完整的流式快照。
  Future<void> updateStreamingCheckpointSilent(
    ChatMessage message,
    List<Map<String, dynamic>> toolEvents, {
    String? generationRunId,
    int? checkpointSeq,
  }) async {
    if (!_initialized) return;

    if (_discardedTemporaryConversationIds.contains(message.conversationId)) {
      return;
    }
    if (isTemporaryConversation(message.conversationId)) {
      _replaceCachedMessage(message);
      _temporaryToolEvents[message.id] = List<Map<String, dynamic>>.of(
        toolEvents,
      );
      return;
    }

    await _repo.updateStreamingCheckpoint(
      message,
      toolEvents,
      generationRunId: generationRunId,
      checkpointSeq: checkpointSeq,
    );
    _replaceCachedMessage(message);
    _toolEventsCache[message.id] = List<Map<String, dynamic>>.of(toolEvents);
  }

  Future<GenerationRun> transitionGenerationRun({
    required String id,
    required GenerationRunState expectedState,
    required int expectedStateRevision,
    required GenerationRunState nextState,
    String? errorCode,
  }) => _repo.transitionGenerationRun(
    id: id,
    expectedState: expectedState,
    expectedStateRevision: expectedStateRevision,
    nextState: nextState,
    updatedAt: DateTime.now().toUtc(),
    errorCode: errorCode,
  );

  Future<GenerationRun?> finalizeGenerationRunSilent({
    required ChatMessage message,
    required List<Map<String, dynamic>> toolEvents,
    required String? generationRunId,
    required GenerationRunState? expectedState,
    required int? expectedStateRevision,
    required GenerationRunState terminalState,
    int? checkpointSeq,
    String? errorCode,
  }) async {
    if (!_initialized) return null;
    if (isTemporaryConversation(message.conversationId)) {
      await updateStreamingCheckpointSilent(message, toolEvents);
      return null;
    }
    if (generationRunId == null) {
      await updateStreamingCheckpointSilent(message, toolEvents);
      _statisticsRevision++;
      notifyListeners();
      return null;
    }
    if (expectedState == null || expectedStateRevision == null) {
      throw StateError('generation_run_cursor_missing');
    }
    final run = await _repo.finalizeGenerationRun(
      message: message,
      toolEvents: toolEvents,
      generationRunId: generationRunId,
      expectedState: expectedState,
      expectedStateRevision: expectedStateRevision,
      terminalState: terminalState,
      checkpointSeq: checkpointSeq,
      errorCode: errorCode,
      geminiThoughtSignature: _geminiThoughtSigsCache[message.id],
    );
    if (_messageCanOwnAssets(message)) {
      await _synchronizeMessageAssetsBestEffort(message);
    }
    _replaceCachedMessage(message);
    _toolEventsCache[message.id] = List<Map<String, dynamic>>.of(toolEvents);
    _statisticsRevision++;
    notifyListeners();
    return run;
  }

  // 工具事件持久化（按助手消息）
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) {
    if (!_initialized) return const <Map<String, dynamic>>[];
    final temporary = _temporaryToolEvents[assistantMessageId];
    if (temporary != null) return List<Map<String, dynamic>>.of(temporary);
    return List<Map<String, dynamic>>.of(
      _toolEventsCache[assistantMessageId] ?? const [],
    );
  }

  Future<void> setToolEvents(
    String assistantMessageId,
    List<Map<String, dynamic>> events,
  ) async {
    if (!_initialized) await init();
    if (_isTemporaryMessageId(assistantMessageId)) {
      _temporaryToolEvents[assistantMessageId] = List<Map<String, dynamic>>.of(
        events,
      );
      notifyListeners();
      return;
    }
    await _repo.setToolEvents(assistantMessageId, events);
    _toolEventsCache[assistantMessageId] = List<Map<String, dynamic>>.of(
      events,
    );
    notifyListeners();
  }

  Future<void> upsertToolEvent(
    String assistantMessageId, {
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_initialized) await init();
    final list = List<Map<String, dynamic>>.of(
      getToolEvents(assistantMessageId),
    );
    final cleanId = (id).toString();

    int idx = -1;
    // 优先通过非空 id 进行匹配
    if (cleanId.isNotEmpty) {
      idx = list.indexWhere((e) => (e['id']?.toString() ?? '') == cleanId);
    }
    // 如果没有 id 或未找到，则匹配同名且（无内容）的第一个占位符
    if (idx < 0) {
      idx = list.indexWhere(
        (e) =>
            (e['name']?.toString() ?? '') == name &&
            (e['content'] == null ||
                (e['content']?.toString().isEmpty ?? true)),
      );
    }

    final record = <String, dynamic>{
      'id': cleanId,
      'name': name,
      'arguments': arguments,
      'content': content,
    };
    final existingMetadata = idx >= 0 ? list[idx]['metadata'] : null;
    if (metadata != null && metadata.isNotEmpty) {
      record['metadata'] = metadata;
    } else if (existingMetadata is Map && existingMetadata.isNotEmpty) {
      record['metadata'] = existingMetadata.cast<String, dynamic>();
    }
    if (idx >= 0) {
      list[idx] = record;
    } else {
      list.add(record);
    }
    if (_isTemporaryMessageId(assistantMessageId)) {
      _temporaryToolEvents[assistantMessageId] = list;
      notifyListeners();
      return;
    }
    await _repo.setToolEvents(assistantMessageId, list);
    _toolEventsCache[assistantMessageId] = list;
    notifyListeners();
  }

  // Gemini 思考签名持久化（按助手消息）
  String? getGeminiThoughtSignature(String assistantMessageId) {
    if (!_initialized) return null;
    final temporary = _temporaryGeminiThoughtSigs[assistantMessageId];
    if (temporary != null && temporary.trim().isNotEmpty) return temporary;
    return _geminiThoughtSigsCache[assistantMessageId];
  }

  Future<void> setGeminiThoughtSignature(
    String assistantMessageId,
    String signature,
  ) async {
    if (!_initialized) await init();
    if (_discardedTemporaryMessageIds.contains(assistantMessageId)) return;
    if (_isTemporaryMessageId(assistantMessageId)) {
      _temporaryGeminiThoughtSigs[assistantMessageId] = signature;
      notifyListeners();
      return;
    }
    await _repo.setGeminiThoughtSignature(assistantMessageId, signature);
    _geminiThoughtSigsCache[assistantMessageId] = signature;
    notifyListeners();
  }

  Future<void> removeGeminiThoughtSignature(String assistantMessageId) async {
    if (!_initialized) await init();
    if (_isTemporaryMessageId(assistantMessageId)) {
      _temporaryGeminiThoughtSigs.remove(assistantMessageId);
      return;
    }
    try {
      await _repo.deleteGeminiThoughtSignature(assistantMessageId);
      _geminiThoughtSigsCache.remove(assistantMessageId);
    } catch (_) {}
  }

  Future<ConversationTree?> loadConversationTree(String conversationId) async {
    if (!_initialized) await init();
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      return _loadOrCreateConversationTree(conversationId);
    }
    return _repo.loadConversationTree(conversationId);
  }

  Future<List<LegacyTreeMigrationWarning>>
  consumeContextTreeMigrationWarnings() async {
    if (!_initialized) await init();
    final warnings = await _repo.readAndClearContextTreeMigrationWarnings();
    if (warnings.isEmpty) return warnings;
    await _writeContextTreeMigrationWarningLog(warnings);
    return warnings;
  }

  Future<void> _writeContextTreeMigrationWarningLog(
    List<LegacyTreeMigrationWarning> warnings,
  ) async {
    try {
      final root = await AppDirectories.getAppDataDirectory();
      final logsDirectory = Directory(p.join(root.path, 'logs'));
      await logsDirectory.create(recursive: true);
      final file = File(
        p.join(logsDirectory.path, 'context_tree_migration_warnings.log'),
      );
      final timestamp = DateTime.now().toUtc().toIso8601String();
      final payload = <String, Object>{
        'timestamp': timestamp,
        'warnings': [for (final warning in warnings) warning.toJson()],
      };
      final sink = file.openWrite(mode: FileMode.append);
      try {
        sink.writeln(jsonEncode(payload));
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (_) {
      // 失败的警告日志不得导致正常启动失败。
    }
  }

  Future<void> ensureConversationTree(String conversationId) async {
    if (!_initialized) await init();
    await _loadOrCreateConversationTree(conversationId);
  }

  Future<ConversationTree> _loadOrCreateConversationTree(
    String conversationId,
  ) async {
    if (_temporaryConversationIds.contains(conversationId) ||
        _draftConversations.containsKey(conversationId)) {
      final existing = _temporaryConversationTrees[conversationId];
      if (existing != null) return existing;
      final messages = _messagesCache[conversationId] ?? const <ChatMessage>[];
      final created = ConversationTree.linear(
        conversationId: conversationId,
        messageIds: [for (final message in messages) message.id],
        activeBranchId: 'root-$conversationId',
      );
      _temporaryConversationTrees[conversationId] = created;
      return created;
    }
    var tree = await _repo.loadConversationTree(conversationId);
    if (tree != null) return tree;
    await _repo.syncLinearConversationTree(conversationId);
    tree = await _repo.loadConversationTree(conversationId);
    if (tree == null) {
      throw StateError('conversation_tree_missing_after_migration');
    }
    return tree;
  }

  /// 从持久化活动树重建内存消息投影。
  ///
  /// 树突变不能简单追加或裁剪旧的线性缓存：分支可以在存储中保持相同逻辑
  /// 位置的同时替换旧兄弟消息内容。当前路径是正常聊天界面唯一的权威窗口。
  Future<void> reloadActiveTimelineCache(String conversationId) async {
    if (!_initialized) await init();
    final tree = await _loadOrCreateConversationTree(conversationId);
    final activeIds = tree.activePath();
    final messages = _temporaryConversationIds.contains(conversationId)
        ? (_messagesCache[conversationId] ?? const <ChatMessage>[])
        : await _repo.getMessagesByIds(activeIds);
    final byId = <String, ChatMessage>{
      for (final message in messages) message.id: message,
    };
    final activeMessages = <ChatMessage>[
      for (final id in activeIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (activeMessages.length != activeIds.length) {
      throw StateError('active_timeline_message_missing');
    }
    if (!_temporaryConversationIds.contains(conversationId)) {
      _messagesCache[conversationId] = activeMessages;
    }
    _messageOrderIds[conversationId] = List<String>.of(activeIds);
    _messageCounts[conversationId] = activeIds.length;
    final firstIndices = <String, int>{};
    for (var index = 0; index < activeMessages.length; index++) {
      final groupId = activeMessages[index].groupId ?? activeMessages[index].id;
      firstIndices.putIfAbsent(groupId, () => index);
    }
    _firstGroupIndicesCache[conversationId] = firstIndices;
    await _cacheMessageArtifacts(activeMessages);
    _touchMessageCache(conversationId);
  }

  Future<ConversationTree?> switchConversationBranch({
    required String conversationId,
    required String branchId,
  }) async {
    if (!_initialized) await init();
    final tree = await _loadOrCreateConversationTree(conversationId);
    if (!tree.branches.containsKey(branchId)) {
      throw StateError('conversation_branch_missing');
    }
    final updated = tree.switchBranch(branchId);
    if (_temporaryConversationIds.contains(conversationId)) {
      _temporaryConversationTrees[conversationId] = updated;
    } else {
      await _repo.saveConversationTree(updated);
      await _syncContextBoundaryToActivePath(conversationId, updated);
    }
    await reloadActiveTimelineCache(conversationId);
    notifyListeners();
    return updated;
  }

  /// Message Fork: clone the selected message as a sibling branch node.
  Future<ConversationTree> createMessageBranch({
    required String conversationId,
    required String? fromMessageId,
    String name = '',
  }) async {
    if (!_initialized) await init();
    // A null message is only used by low-level callers to open an empty root
    // branch; the user-facing Message Fork always supplies a message to clone.
    if (fromMessageId == null) {
      return createMessageContinuationBranch(
        conversationId: conversationId,
        fromMessageId: null,
        name: name,
      );
    }

    if (_temporaryConversationIds.contains(conversationId)) {
      final original = _cachedTemporaryMessage(fromMessageId);
      final tree = await _loadOrCreateConversationTree(conversationId);
      final edge = tree.edges[fromMessageId];
      if (original == null || edge == null) {
        throw StateError('message_branch_source_missing');
      }
      final cloneGroupId = original.groupId ?? original.id;
      final cloneVersion =
          (_messagesCache[conversationId] ?? const <ChatMessage>[])
              .where(
                (candidate) =>
                    (candidate.groupId ?? candidate.id) == cloneGroupId,
              )
              .fold<int>(-1, (max, candidate) {
                return candidate.version > max ? candidate.version : max;
              }) +
          1;
      final clone = ChatMessage(
        role: original.role,
        parts: original.parts,
        timestamp: original.timestamp,
        modelId: original.modelId,
        providerId: original.providerId,
        totalTokens: original.totalTokens,
        conversationId: conversationId,
        isStreaming: false,
        reasoningText: original.reasoningText,
        reasoningStartAt: original.reasoningStartAt,
        reasoningFinishedAt: original.reasoningFinishedAt,
        translation: original.translation,
        reasoningSegmentsJson: original.reasoningSegmentsJson,
        promptTokens: original.promptTokens,
        completionTokens: original.completionTokens,
        cachedTokens: original.cachedTokens,
        durationMs: original.durationMs,
        groupId: cloneGroupId,
        version: cloneVersion,
      );
      final branchId = 'branch-${const Uuid().v4()}';
      final updated = tree.createBranchFromParent(
        branchId: branchId,
        parentMessageId: edge.parentMessageId,
        tipMessageId: clone.id,
        name: name,
        createdAt: clone.timestamp,
      );
      _messagesCache
          .putIfAbsent(conversationId, () => <ChatMessage>[])
          .add(clone);
      _draftConversations[conversationId]?.messageIds.add(clone.id);
      _temporaryConversationTrees[conversationId] = updated;
      await reloadActiveTimelineCache(conversationId);
      notifyListeners();
      return updated;
    }

    final result = await _repo.cloneMessageAsBranch(
      conversationId: conversationId,
      messageId: fromMessageId,
    );
    if (result == null) {
      throw StateError('message_branch_source_missing');
    }
    _conversationsCache[conversationId] = result.conversation;
    await reloadActiveTimelineCache(conversationId);
    final updated = await _loadOrCreateConversationTree(conversationId);
    await _syncContextBoundaryToActivePath(conversationId, updated);
    notifyListeners();
    return updated;
  }

  /// 为重新生成或继续对话创建一个空的分支锚点。
  ///
  /// 这不是用户菜单中的 Message Fork：调用方随后会把一条新消息挂到
  /// [fromMessageId] 下，因此此处不能预先克隆消息。
  Future<ConversationTree> createMessageContinuationBranch({
    required String conversationId,
    required String? fromMessageId,
    String name = '',
  }) async {
    if (!_initialized) await init();
    final tree = await _loadOrCreateConversationTree(conversationId);
    final branchId = 'branch-${const Uuid().v4()}';
    final updated = tree.createMessageBranchFromParent(
      branchId: branchId,
      fromMessageId: fromMessageId,
      name: name,
    );
    if (_temporaryConversationIds.contains(conversationId)) {
      _temporaryConversationTrees[conversationId] = updated;
    } else {
      await _repo.saveConversationTree(updated);
      await _syncContextBoundaryToActivePath(conversationId, updated);
    }
    await reloadActiveTimelineCache(conversationId);
    notifyListeners();
    return updated;
  }

  Future<Set<String>> deleteBranchSiblings({
    required String conversationId,
    required String messageId,
  }) async {
    if (!_initialized) await init();
    final tree = await _loadOrCreateConversationTree(conversationId);
    final target = tree.edges[messageId];
    final siblingIds = target == null
        ? <String>{messageId}
        : (tree.childrenByParent[target.parentMessageId] ?? <String>[]).toSet();
    return deleteMessages(
      conversationId: conversationId,
      messageIds: siblingIds.isEmpty ? <String>{messageId} : siblingIds,
      versionSelectionChanges: const {},
    );
  }

  /// 只删除 [messageId]，保留其后续消息并重挂到父节点。
  Future<Set<String>> deleteMessageOnly({
    required String conversationId,
    required String messageId,
  }) async {
    if (!_initialized) await init();
    if (_temporaryConversationIds.contains(conversationId)) {
      final conversation = _draftConversations[conversationId];
      final messages = _messagesCache[conversationId];
      if (conversation == null || messages == null) return const <String>{};
      final tree = await _loadOrCreateConversationTree(conversationId);
      if (!tree.edges.containsKey(messageId)) return const <String>{};
      _temporaryConversationTrees[conversationId] = tree.removeMessageOnly(
        messageId,
      );
      messages.removeWhere((message) => message.id == messageId);
      conversation.messageIds.remove(messageId);
      conversation.updatedAt = DateTime.now();
      _temporaryToolEvents.remove(messageId);
      _temporaryGeminiThoughtSigs.remove(messageId);
      await reloadActiveTimelineCache(conversationId);
      notifyListeners();
      return <String>{messageId};
    }

    final result = await _repo.deleteMessageOnly(
      conversationId: conversationId,
      messageId: messageId,
    );
    if (result == null) return const <String>{};

    _conversationsCache[conversationId] = result.conversation;
    _toolEventsCache.remove(messageId);
    _geminiThoughtSigsCache.remove(messageId);
    _messagesCache.remove(conversationId);
    final groupMessages = _groupMessagesCache[conversationId];
    if (groupMessages != null) {
      groupMessages.removeWhere((message) => message.id == messageId);
      if (groupMessages.isEmpty) _groupMessagesCache.remove(conversationId);
    }
    _messageOrderIds.remove(conversationId);
    _firstGroupIndicesCache.remove(conversationId);
    final tree = await _repo.loadConversationTree(conversationId);
    if (tree != null) {
      await _syncContextBoundaryToActivePath(conversationId, tree);
    }
    await reloadActiveTimelineCache(conversationId);
    await _cleanupOrphanUploads();
    _bumpConversationListRevision();
    notifyListeners();
    return <String>{messageId};
  }

  /// Conversation Fork: copy a message prefix into a new conversation.
  ///
  /// [ConversationForkMode.preserveBranches] keeps every sibling subtree that
  /// branches from the copied active prefix. [ConversationForkMode
  /// .activeBranchOnly] keeps only the active prefix.
  Future<Conversation> createConversationForkAtRevision({
    required String sourceConversationId,
    required String sourceRevisionId,
    required String title,
    ConversationForkMode mode = ConversationForkMode.activeBranchOnly,
  }) async {
    if (!_initialized) await init();
    if (_temporaryConversationIds.contains(sourceConversationId)) {
      throw StateError('conversation_fork_temporary_source');
    }
    final source = _conversationsCache[sourceConversationId];
    if (source == null) throw StateError('conversation_missing');
    final targetMessage = await _repo.getMessage(sourceRevisionId);
    if (targetMessage == null ||
        targetMessage.conversationId != sourceConversationId) {
      throw StateError('conversation_fork_target_missing');
    }
    final tree = await _loadOrCreateConversationTree(sourceConversationId);
    final activePath = tree.activePath();
    final targetIndex = activePath.indexOf(sourceRevisionId);
    if (targetIndex < 0) {
      throw StateError('conversation_fork_target_not_in_active_path');
    }
    final selectedSourceIds = _conversationForkSourceIds(
      tree,
      activePath,
      targetIndex,
      mode,
    );
    final allMessages = await _repo.getMessagesRange(
      sourceConversationId,
      start: 0,
      limit: await _repo.getMessageCount(sourceConversationId),
    );
    final loadedById = <String, ChatMessage>{
      for (final message in allMessages) message.id: message,
    };
    final sourceIds = [
      for (final message in allMessages)
        if (selectedSourceIds.contains(message.id)) message.id,
    ];
    final loaded = [
      for (final id in sourceIds)
        if (loadedById[id] != null) loadedById[id]!,
    ];
    if (loaded.length != sourceIds.length) {
      throw StateError('conversation_fork_path_message_missing');
    }
    final targetIdBySourceId = <String, String>{
      for (final id in sourceIds) id: const Uuid().v4(),
    };
    final targetMessages = [
      for (final message in loaded)
        ChatMessage(
          id: targetIdBySourceId[message.id],
          role: message.role,
          parts: message.parts,
          timestamp: message.timestamp,
          modelId: message.modelId,
          providerId: message.providerId,
          totalTokens: message.totalTokens,
          conversationId: '', // replaced below after target creation
          isStreaming: false,
          reasoningText: message.reasoningText,
          reasoningStartAt: message.reasoningStartAt,
          reasoningFinishedAt: message.reasoningFinishedAt,
          translation: message.translation,
          reasoningSegmentsJson: message.reasoningSegmentsJson,
          promptTokens: message.promptTokens,
          completionTokens: message.completionTokens,
          cachedTokens: message.cachedTokens,
          durationMs: message.durationMs,
        ),
    ];
    final persisted = Conversation(
      title: source.title,
      assistantId: source.assistantId,
      mcpServerIds: List<String>.of(source.mcpServerIds),
    );
    final remappedMessages = [
      for (final message in targetMessages)
        message.copyWith(conversationId: persisted.id),
    ];
    final targetTree = _remapConversationForkTree(
      tree,
      sourceIds.toSet(),
      targetIdBySourceId,
      persisted.id,
      mode,
    );
    await _repo.putConversationTreeClone(
      conversation: persisted,
      messages: remappedMessages,
      sourceMessageIdByTargetId: {
        for (final entry in targetIdBySourceId.entries) entry.value: entry.key,
      },
      tree: targetTree,
    );
    _conversationsCache[persisted.id] = persisted;
    _messagesCache[persisted.id] = remappedMessages;
    _messageOrderIds[persisted.id] = targetTree.activePath();
    _messageCounts[persisted.id] = targetTree.activePath().length;
    _currentConversationId = persisted.id;
    _bumpConversationListRevision();
    notifyListeners();
    return persisted;
  }

  /// 从给定消息顺序创建一个新的线性会话。
  ///
  /// 用于上下文压缩的“保留最近消息”模式：摘要消息由调用方创建，
  /// 其余消息通过结构化 parts 原样写入新会话。
  Future<Conversation> forkConversationFromMessages({
    required String title,
    required String? assistantId,
    required List<ChatMessage> sourceMessages,
  }) async {
    if (!_initialized) await init();
    final persisted = await createConversation(
      title: title,
      assistantId: assistantId,
    );
    final sourceIds = sourceMessages
        .map((message) => message.id)
        .where((id) => id.isNotEmpty)
        .toSet();
    final toolEventsBySourceId = sourceIds.isEmpty
        ? const <String, List<Map<String, dynamic>>>{}
        : await _repo.getToolEventsForMessages(sourceIds);
    final signaturesBySourceId = sourceIds.isEmpty
        ? const <String, String>{}
        : await _repo.getGeminiThoughtSignaturesForMessages(sourceIds);
    for (final source in sourceMessages) {
      final cloned = await addMessage(
        conversationId: persisted.id,
        role: source.role,
        parts: source.parts,
        modelId: source.modelId,
        providerId: source.providerId,
        totalTokens: source.totalTokens,
        translation: source.translation,
        reasoningSegmentsJson: source.reasoningSegmentsJson,
        promptTokens: source.promptTokens,
        completionTokens: source.completionTokens,
        cachedTokens: source.cachedTokens,
        durationMs: source.durationMs,
        reasoningText: source.reasoningText,
        reasoningStartAt: source.reasoningStartAt,
        reasoningFinishedAt: source.reasoningFinishedAt,
        groupId: source.groupId,
        version: source.version,
      );
      final toolEvents =
          toolEventsBySourceId[source.id] ?? getToolEvents(source.id);
      if (toolEvents.isNotEmpty) {
        await setToolEvents(cloned.id, toolEvents);
      }
      final signature =
          signaturesBySourceId[source.id] ??
          getGeminiThoughtSignature(source.id);
      if (signature != null && signature.trim().isNotEmpty) {
        await setGeminiThoughtSignature(cloned.id, signature);
      }
    }
    _currentConversationId = persisted.id;
    notifyListeners();
    return _conversationsCache[persisted.id] ?? persisted;
  }

  List<String> _conversationForkSourceIds(
    ConversationTree tree,
    List<String> activePath,
    int targetIndex,
    ConversationForkMode mode,
  ) {
    final included = activePath.take(targetIndex + 1).toSet();
    if (mode == ConversationForkMode.preserveBranches) {
      for (var index = 0; index <= targetIndex; index++) {
        final parent = index == 0 ? null : activePath[index - 1];
        final activeChild = activePath[index];
        for (final child in tree.childrenOf(parent)) {
          if (child == activeChild) continue;
          _addConversationForkSubtree(tree, child, included);
        }
      }
    }
    final ordered = <String>[];
    for (final edge in tree.edges.values) {
      if (included.contains(edge.messageId)) ordered.add(edge.messageId);
    }
    return ordered;
  }

  void _addConversationForkSubtree(
    ConversationTree tree,
    String messageId,
    Set<String> included,
  ) {
    if (!included.add(messageId)) return;
    for (final child in tree.childrenOf(messageId)) {
      _addConversationForkSubtree(tree, child, included);
    }
  }

  ConversationTree _remapConversationForkTree(
    ConversationTree source,
    Set<String> included,
    Map<String, String> messageIdMap,
    String targetConversationId,
    ConversationForkMode mode,
  ) {
    final edges = <String, MessageTreeEdge>{};
    for (final edge in source.edges.values) {
      if (!included.contains(edge.messageId)) continue;
      final targetId = messageIdMap[edge.messageId]!;
      final parent = edge.parentMessageId;
      edges[targetId] = MessageTreeEdge(
        messageId: targetId,
        parentMessageId: parent == null || !included.contains(parent)
            ? null
            : messageIdMap[parent],
      );
    }
    final branchIdMap = <String, String>{};
    final branches = <String, ConversationBranch>{};
    if (mode == ConversationForkMode.activeBranchOnly) {
      final targetBranchId = 'root-$targetConversationId';
      branches[targetBranchId] = ConversationBranch(
        id: targetBranchId,
        conversationId: targetConversationId,
        tipMessageId: messageIdMap[_activePathLastIncluded(source, included)],
        createdAt: DateTime.now(),
      );
      branchIdMap[source.activeBranchId] = targetBranchId;
    } else {
      for (final branch in source.branches.values) {
        final path = source
            .branchPath(branch.id)
            .where(included.contains)
            .toList(growable: false);
        if (path.isEmpty) continue;
        final targetBranchId = 'branch-${const Uuid().v4()}';
        branchIdMap[branch.id] = targetBranchId;
        branches[targetBranchId] = ConversationBranch(
          id: targetBranchId,
          conversationId: targetConversationId,
          tipMessageId: messageIdMap[path.last],
          name: branch.name,
          createdAt: branch.createdAt,
        );
      }
    }
    final activeBranchId = branchIdMap[source.activeBranchId];
    if (activeBranchId == null) {
      throw StateError('conversation_fork_active_branch_missing');
    }
    final selections = mode == ConversationForkMode.activeBranchOnly
        ? const <String, String>{}
        : <String, String>{
            for (final entry in source.branchSelections.entries)
              if (included.contains(entry.key) &&
                  branchIdMap[entry.value] != null)
                messageIdMap[entry.key]!: branchIdMap[entry.value]!,
          };
    return ConversationTree(
      conversationId: targetConversationId,
      activeBranchId: activeBranchId,
      branches: branches,
      edges: edges,
      branchSelections: selections,
    );
  }

  String _activePathLastIncluded(ConversationTree tree, Set<String> included) {
    final path = tree.activePath().where(included.contains);
    if (path.isEmpty) throw StateError('conversation_fork_active_path_missing');
    return path.last;
  }

  Future<ChatMessage?> appendMessageVersion({
    required String messageId,
    String content = '',
    List<MessagePart>? parts,
  }) async {
    if (!_initialized) await init();
    final temporaryOriginal = _cachedTemporaryMessage(messageId);
    if (temporaryOriginal != null) {
      final conversationId = temporaryOriginal.conversationId;
      final conversation = _draftConversations[conversationId];
      final messages = _messagesCache[conversationId];
      if (conversation == null || messages == null) return null;
      // 保留旧字段仅用于导出/兼容检查；活动分支仍完全由树决定。
      final groupId = temporaryOriginal.groupId ?? temporaryOriginal.id;
      final nextVersion =
          messages
              .where((message) => (message.groupId ?? message.id) == groupId)
              .map((message) => message.version)
              .fold<int>(-1, (max, value) => value > max ? value : max) +
          1;
      // 仅追加内容时必须保留先前的 ImagePart/FilePart 附件，
      // 并保持顺序（[Image, Text] 保持为 [Image, Text(new)]）。
      final resolvedParts =
          parts ??
          ChatMessage.partsWithReplacedText(temporaryOriginal.parts, content);
      final newMsg = ChatMessage(
        role: temporaryOriginal.role,
        parts: resolvedParts,
        conversationId: conversationId,
        modelId: temporaryOriginal.modelId,
        providerId: temporaryOriginal.providerId,
        groupId: groupId,
        version: nextVersion,
      );
      final tree = await _loadOrCreateConversationTree(conversationId);
      final edge = tree.edges[temporaryOriginal.id];
      if (edge == null) return null;
      final branchId = 'branch-${const Uuid().v4()}';
      final updatedTree = tree.createBranchFromParent(
        branchId: branchId,
        parentMessageId: edge.parentMessageId,
        tipMessageId: newMsg.id,
        createdAt: newMsg.timestamp,
      );
      _temporaryConversationTrees[conversationId] = updatedTree;
      messages.add(newMsg);
      conversation.messageIds.add(newMsg.id);
      conversation.updatedAt = DateTime.now();
      await reloadActiveTimelineCache(conversationId);
      notifyListeners();
      return newMsg;
    }

    final original = await _repo.getMessage(messageId);
    if (original != null) await _loadMessageOrder(original.conversationId);
    final result = await _repo.appendMessageVersion(
      messageId: messageId,
      content: content,
      parts: parts,
    );
    if (result == null) return null;
    final newMsg = result.message;
    if (_messageCanOwnAssets(newMsg)) {
      await _synchronizeMessageAssetsBestEffort(newMsg);
    }
    if (newMsg.role == 'user') {
      await _inheritImageOcrArtifactsBestEffort(
        fromRevisionId: messageId,
        toRevisionId: newMsg.id,
      );
    }
    final cid = newMsg.conversationId;
    _conversationsCache[cid] = result.conversation;
    await reloadActiveTimelineCache(cid);
    _bumpConversationListRevision();
    notifyListeners();
    return newMsg;
  }

  /// 根据当前字节将图像 path/data-URL 解析为内容 SHA-256。
  ///
  /// 绝不只信任 path→hash 行：同一路径在内容替换后可能指向不同的历史资产。
  /// 重复输入只计算一次哈希并复用。
  Future<Map<String, String>> resolveImageContentHashes(
    List<String> imagePaths,
  ) async {
    if (!_initialized) await init();
    final result = <String, String>{};
    if (imagePaths.isEmpty) return result;

    final uniquePaths = <String>{
      for (final raw in imagePaths)
        if (raw.trim().isNotEmpty) raw.trim(),
    };
    for (final path in uniquePaths) {
      try {
        if (path.startsWith('data:')) {
          result[path] = await _hashDataUrl(path);
          continue;
        }
        final fixed = SandboxPathResolver.resolveForIo(path);
        if (fixed == null) continue;
        final normalized = p.normalize(File(fixed).absolute.path);
        final file = File(normalized);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        final stat = await file.stat();
        final cached = _imageContentHashCache[file.path];
        if (cached != null &&
            cached.length == stat.size &&
            cached.mtimeMs == stat.modified.millisecondsSinceEpoch) {
          result[path] = cached.hash;
          continue;
        }
        final hash = await _assetContentHash(file);
        if (_imageContentHashCache.length >= _imageContentHashCacheMaxEntries) {
          _imageContentHashCache.clear();
        }
        _imageContentHashCache[file.path] = (
          length: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
          hash: hash,
        );
        result[path] = hash;
      } catch (_) {
        // 跳过无法读取的来源；调用方会将其视为缓存未命中。
      }
    }
    return result;
  }

  static Future<String> _hashDataUrl(String dataUrl) {
    return Isolate.run(() {
      final comma = dataUrl.indexOf(',');
      if (comma < 0) {
        return sha256.convert(utf8.encode(dataUrl)).toString();
      }
      final meta = dataUrl.substring(0, comma).toLowerCase();
      final payload = dataUrl.substring(comma + 1);
      if (meta.contains(';base64')) {
        return sha256.convert(base64Decode(payload)).toString();
      }
      return sha256.convert(utf8.encode(Uri.decodeFull(payload))).toString();
    });
  }

  Future<Map<String, Map<String, String>>> getImageOcrArtifacts(
    Iterable<String> revisionIds,
  ) async {
    if (!_initialized) await init();
    final ids = revisionIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && !_isTemporaryMessageId(id))
        .toList(growable: false);
    if (ids.isEmpty) return const {};
    try {
      return await _repo.getImageOcrArtifacts(ids);
    } catch (error) {
      debugPrint('OCR artifact load failed: $error');
      return const {};
    }
  }

  Future<void> upsertImageOcrArtifactItems(
    String revisionId,
    Map<String, String> items,
  ) async {
    if (!_initialized) await init();
    if (_isTemporaryMessageId(revisionId) || items.isEmpty) return;
    try {
      await _repo.upsertImageOcrArtifactItems(
        revisionId: revisionId,
        items: items,
      );
    } catch (error) {
      debugPrint('OCR artifact persist failed: $error');
    }
  }

  Future<void> _inheritImageOcrArtifactsBestEffort({
    required String fromRevisionId,
    required String toRevisionId,
  }) async {
    if (_isTemporaryMessageId(toRevisionId)) return;
    try {
      var hashes = await _repo.getMessageImageContentHashes(toRevisionId);
      if (hashes.isEmpty) {
        final message = await _repo.getMessage(toRevisionId);
        if (message == null) return;
        final paths = _extractOcrImageSourcesFromMessage(message);
        if (paths.isEmpty) return;
        hashes = (await resolveImageContentHashes(paths)).values.toSet();
      }
      if (hashes.isEmpty) return;
      await _repo.inheritImageOcrArtifacts(
        fromRevisionId: fromRevisionId,
        toRevisionId: toRevisionId,
        retainedContentHashes: hashes,
      );
    } catch (error) {
      debugPrint('OCR artifact inherit failed: $error');
    }
  }

  Map<String, int> getVersionSelections(String conversationId) {
    return Map<String, int>.from(
      (_draftConversations[conversationId] ??
                  _conversationsCache[conversationId])
              ?.versionSelections ??
          const <String, int>{},
    );
  }

  Future<void> setSelectedVersion(
    String conversationId,
    String groupId,
    int version,
  ) async {
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.versionSelections[groupId] = version;
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    final candidates = await _repo.getMessagesForGroups(conversationId, [
      groupId,
    ]);
    ChatMessage? target;
    for (final candidate in candidates) {
      if (candidate.version == version) {
        target = candidate;
        break;
      }
    }
    final selectedTarget = target;
    if (selectedTarget == null) {
      throw StateError('message_version_missing');
    }
    // 不再写入 versionSelections，树是唯一真相
    var tree = await _loadOrCreateConversationTree(conversationId);
    final matchingBranches =
        tree.branches.values
            .where(
              (branch) =>
                  tree.branchPath(branch.id).contains(selectedTarget.id),
            )
            .toList()
          ..sort((left, right) {
            final leftExact = left.tipMessageId == selectedTarget.id ? 0 : 1;
            final rightExact = right.tipMessageId == selectedTarget.id ? 0 : 1;
            if (leftExact != rightExact) return leftExact.compareTo(rightExact);
            final leftLength = tree.branchPath(left.id).length;
            final rightLength = tree.branchPath(right.id).length;
            if (leftLength != rightLength) {
              return leftLength.compareTo(rightLength);
            }
            return left.id.compareTo(right.id);
          });
    if (matchingBranches.isNotEmpty &&
        matchingBranches.first.id != tree.activeBranchId) {
      tree = tree.switchBranch(matchingBranches.first.id);
      await _repo.saveConversationTree(tree);
    }
    await _syncContextBoundaryToActivePath(conversationId, tree);
    await reloadActiveTimelineCache(conversationId);
    _bumpConversationListRevision();
    notifyListeners();
  }

  Future<void> clearSelectedVersion(
    String conversationId,
    String groupId,
  ) async {
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      draft.versionSelections.remove(groupId);
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    // 不再写入 versionSelections，树是唯一真相
    await reloadActiveTimelineCache(conversationId);
    _bumpConversationListRevision();
    notifyListeners();
  }

  Future<Conversation?> toggleTruncateAtTail(
    String conversationId, {
    String? defaultTitle,
  }) async {
    if (!_initialized) await init();
    // 草稿情况
    if (_draftConversations.containsKey(conversationId)) {
      final draft = _draftConversations[conversationId]!;
      final lastIndexPlusOne = draft.messageIds.length; // 最后一个索引 + 1
      final newValue = (draft.truncateIndex == lastIndexPlusOne)
          ? -1
          : lastIndexPlusOne;
      draft.truncateIndex = newValue;
      if ((defaultTitle ?? '').isNotEmpty) draft.title = defaultTitle!;
      draft.updatedAt = DateTime.now();
      notifyListeners();
      return draft;
    }
    // 已持久化的情况
    final c = _conversationsCache[conversationId];
    if (c == null) return null;
    final tree = await _loadOrCreateConversationTree(conversationId);
    final activePathLength = tree.activePath().length;
    if (activePathLength == 0) return c;
    c.truncateIndex = c.truncateIndex == activePathLength
        ? -1
        : activePathLength;
    if ((defaultTitle ?? '').isNotEmpty) c.title = defaultTitle!;
    c.updatedAt = DateTime.now();
    await _saveConversation(c);
    _bumpConversationListRevision();
    notifyListeners();
    return c;
  }

  Future<void> deleteMessage(String messageId) async {
    if (!_initialized) return;

    final message =
        await _repo.getMessage(messageId) ?? _cachedTemporaryMessage(messageId);
    if (message == null) return;

    if (isTemporaryConversation(message.conversationId)) {
      await deleteMessages(
        conversationId: message.conversationId,
        messageIds: {messageId},
        versionSelectionChanges: const {},
      );
      return;
    }
    final conversation = _conversationsCache[message.conversationId];
    if (conversation == null) return;
    await deleteMessages(
      conversationId: conversation.id,
      messageIds: {messageId},
      versionSelectionChanges: const {},
    );
  }

  Future<Set<String>> deleteMessages({
    required String conversationId,
    required Set<String> messageIds,
    required Map<String, int?> versionSelectionChanges,
  }) async {
    if (!_initialized || messageIds.isEmpty) return const <String>{};
    if (_temporaryConversationIds.contains(conversationId)) {
      final conversation = _draftConversations[conversationId];
      final messages = _messagesCache[conversationId];
      if (conversation == null || messages == null) return const <String>{};
      final tree = await _loadOrCreateConversationTree(conversationId);
      final deletedIds = <String>{};
      final pending = <String>[...messageIds];
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        if (!deletedIds.add(current)) continue;
        for (final child in tree.childrenOf(current)) {
          pending.add(child);
        }
      }
      deletedIds.removeWhere((id) => !tree.edges.containsKey(id));
      if (deletedIds.isEmpty) return const <String>{};
      messages.removeWhere((message) => deletedIds.contains(message.id));
      conversation.messageIds.removeWhere(deletedIds.contains);
      conversation.chatSuggestions = const <String>[];
      _temporaryConversationTrees[conversationId] = tree.deleteSubtree(
        messageIds.first,
      );
      if (messageIds.length > 1) {
        var updatedTree = _temporaryConversationTrees[conversationId]!;
        for (final id in messageIds.skip(1)) {
          updatedTree = updatedTree.deleteSubtree(id);
        }
        _temporaryConversationTrees[conversationId] = updatedTree;
      }
      conversation.updatedAt = DateTime.now();
      for (final id in deletedIds) {
        _temporaryToolEvents.remove(id);
        _temporaryGeminiThoughtSigs.remove(id);
      }
      await reloadActiveTimelineCache(conversationId);
      notifyListeners();
      return Set<String>.unmodifiable(deletedIds);
    }
    final result = await _repo.deleteMessages(
      conversationId: conversationId,
      messageIds: messageIds,
      versionSelectionChanges: versionSelectionChanges,
    );
    if (result == null) return const <String>{};

    _conversationsCache[conversationId] = result.conversation;
    final deletedIds = <String>{};
    for (final message in result.messages) {
      deletedIds.add(message.id);
      _toolEventsCache.remove(message.id);
      _geminiThoughtSigsCache.remove(message.id);
    }
    _messagesCache.remove(conversationId);
    final groupMessages = _groupMessagesCache[conversationId];
    if (groupMessages != null) {
      groupMessages.removeWhere((message) => deletedIds.contains(message.id));
      if (groupMessages.isEmpty) _groupMessagesCache.remove(conversationId);
    }
    _messageOrderIds.remove(conversationId);
    _firstGroupIndicesCache.remove(conversationId);
    final tree = await _repo.loadConversationTree(conversationId);
    if (tree != null) {
      await _syncContextBoundaryToActivePath(conversationId, tree);
    }
    await reloadActiveTimelineCache(conversationId);
    await _cleanupOrphanUploads();
    _bumpConversationListRevision();
    notifyListeners();
    return Set<String>.unmodifiable(deletedIds);
  }

  void setCurrentConversation(String? id) {
    if (id != _currentConversationId) {
      _discardTemporaryConversation(_currentConversationId);
    }
    _currentConversationId = id;
    _enforceMessageCacheLimits();
    notifyListeners();
  }

  Future<void> clearAllData({bool deleteUploads = true}) async {
    if (!_initialized) await init();

    await _repo.clearAllData();
    for (final id in _temporaryConversationIds) {
      _rememberDiscardedTemporaryConversation(id);
    }
    _messagesCache.clear();
    _groupMessagesCache.clear();
    _conversationsCache.clear();
    _draftConversations.clear();
    _temporaryConversationIds.clear();
    _temporaryConversationTrees.clear();
    _temporaryToolEvents.clear();
    _temporaryGeminiThoughtSigs.clear();
    _toolEventsCache.clear();
    _geminiThoughtSigsCache.clear();
    _messageCounts.clear();
    _messageOrderIds.clear();
    _firstGroupIndicesCache.clear();
    _currentConversationId = null;
    if (deleteUploads) await _deleteUploadDirectory();
    _bumpConversationListRevision();
    notifyListeners();
  }

  Future<void> _deleteUploadDirectory() async {
    final uploadDir = await AppDirectories.getUploadDirectory();
    if (await uploadDir.exists()) await uploadDir.delete(recursive: true);
  }

  // 上传统计：应用 documents/upload 目录下文件的数量和总大小
  Future<UploadStats> getUploadStats() async {
    try {
      final uploadDir = await AppDirectories.getUploadDirectory();
      if (!await uploadDir.exists()) {
        return const UploadStats(fileCount: 0, totalBytes: 0);
      }
      int count = 0;
      int bytes = 0;
      final entries = uploadDir.listSync(recursive: true, followLinks: false);
      for (final ent in entries) {
        if (ent is File) {
          count += 1;
          try {
            bytes += await ent.length();
          } catch (_) {}
        }
      }
      return UploadStats(fileCount: count, totalBytes: bytes);
    } catch (_) {
      return const UploadStats(fileCount: 0, totalBytes: 0);
    }
  }

  // 将现有会话移动到不同的助手。
  // 如果会话仍是草稿，则在内存中更新；
  // 否则持久化 assistantId 变更和 updatedAt。
  Future<bool> moveConversationToAssistant({
    required String conversationId,
    required String assistantId,
  }) async {
    final result = await _moveConversationToAssistantInternal(
      conversationId: conversationId,
      assistantId: assistantId,
      notify: true,
    );
    return result == _MoveConversationResult.moved ||
        result == _MoveConversationResult.unchanged;
  }

  Future<_MoveConversationResult> _moveConversationToAssistantInternal({
    required String conversationId,
    required String assistantId,
    required bool notify,
  }) async {
    if (!_initialized) await init();

    final draft = _draftConversations[conversationId];
    if (draft != null) {
      if (draft.assistantId == assistantId) {
        return _MoveConversationResult.unchanged;
      }
      draft.assistantId = assistantId;
      draft.updatedAt = DateTime.now();
      if (notify) notifyListeners();
      return _MoveConversationResult.moved;
    }

    final c = _conversationsCache[conversationId];
    if (c == null) return _MoveConversationResult.missing;
    if (c.assistantId == assistantId) {
      return _MoveConversationResult.unchanged;
    }
    final updatedAt = DateTime.now();
    final moved = await _repo.moveConversationToAssistant(
      conversationId: conversationId,
      assistantId: assistantId,
      updatedAt: updatedAt,
    );
    if (!moved) return _MoveConversationResult.busy;
    c.assistantId = assistantId;
    c.updatedAt = updatedAt;
    c.injectedMemoryHash = null;
    if (notify) {
      _bumpConversationListRevision();
      notifyListeners();
    }
    return _MoveConversationResult.moved;
  }

  /// 批量移动会话。生成中的会话保持原归属并计入 [skippedBusy]。
  Future<ConversationBatchMoveResult> moveConversationsToAssistant({
    required Iterable<String> conversationIds,
    required String assistantId,
  }) async {
    if (!_initialized) await init();

    var moved = 0;
    var skippedBusy = 0;
    final seen = <String>{};
    for (final id in conversationIds) {
      if (id.isEmpty || !seen.add(id)) continue;
      final result = await _moveConversationToAssistantInternal(
        conversationId: id,
        assistantId: assistantId,
        notify: false,
      );
      switch (result) {
        case _MoveConversationResult.moved:
          moved++;
        case _MoveConversationResult.busy:
          skippedBusy++;
        case _MoveConversationResult.unchanged:
        case _MoveConversationResult.missing:
          break;
      }
    }
    if (moved > 0) {
      _bumpConversationListRevision();
      notifyListeners();
    }
    return ConversationBatchMoveResult(moved: moved, skippedBusy: skippedBusy);
  }
}

class UploadStats {
  final int fileCount;
  final int totalBytes;
  const UploadStats({required this.fileCount, required this.totalBytes});
}

final class ActiveTimelineSlot {
  const ActiveTimelineSlot({
    required this.slotId,
    required this.revisionId,
    required this.parentRevisionId,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
    required this.finalizedAt,
    required this.versionCount,
    required this.logicalIndex,
  });

  final String slotId;
  final String revisionId;
  final String? parentRevisionId;
  final String role;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? finalizedAt;
  final int versionCount;
  final int logicalIndex;
}
