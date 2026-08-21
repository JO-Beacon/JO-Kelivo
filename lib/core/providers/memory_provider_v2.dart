import 'package:flutter/foundation.dart';

import '../database/chat_database_repository.dart';
import '../models/memory_entry.dart';
import '../models/user_profile_field.dart';
import '../services/memory/memory_repository.dart';

/// 面向 UI 的 ChangeNotifier，用于记忆系统 V1（§13.7）。
///
/// 有意不命名为 [MemoryProvider]：该类仍是 §14.5 的旧版只读存储。
/// 通过 `context.read` 混用两者会在不知不觉中接入错误的系统。
class MemoryProviderV2 extends ChangeNotifier {
  MemoryProviderV2({required this.repository, required this.chatRepository});

  final MemoryRepository repository;
  final ChatDatabaseRepository chatRepository;

  List<MemoryEntry> _entries = const <MemoryEntry>[];
  List<UserProfileField> _profileFields = const <UserProfileField>[];
  int _orphanCount = 0;
  String? _focusAssistantId;
  bool _loadAll = false;
  bool _initialized = false;
  Future<void>? _initializationFuture;

  /// 来自上次 [refresh] / [refreshAll] 的完整缓存条目列表。
  List<MemoryEntry> get entries => List<MemoryEntry>.unmodifiable(_entries);

  List<UserProfileField> get profileFields =>
      List<UserProfileField>.unmodifiable(_profileFields);

  int get orphanCount => _orphanCount;

  /// 对 [assistantId] 可见的活跃记忆（全局 ∪ 助手）。
  List<MemoryEntry> visibleFor(String? assistantId) {
    return _entries
        .where(
          (entry) =>
              entry.status == MemoryStatus.active &&
              _isVisible(entry, assistantId),
        )
        .toList(growable: false);
  }

  /// 对 [assistantId] 可见的已归档记忆（全局 ∪ 助手）。
  List<MemoryEntry> archivedFor(String? assistantId) {
    return _entries
        .where(
          (entry) =>
              entry.status == MemoryStatus.archived &&
              _isVisible(entry, assistantId),
        )
        .toList(growable: false);
  }

  Future<void> initialize({String? assistantId, bool loadAll = false}) {
    if (_initialized &&
        assistantId == _focusAssistantId &&
        loadAll == _loadAll) {
      return Future<void>.value();
    }
    return _initializationFuture ??= _initialize(
      assistantId: assistantId,
      loadAll: loadAll,
    );
  }

  Future<void> _initialize({String? assistantId, bool loadAll = false}) async {
    try {
      await refresh(assistantId: assistantId, loadAll: loadAll);
      _initialized = true;
    } finally {
      _initializationFuture = null;
    }
  }

  /// 从类型化列读取路径（§13.1 / §13.3）重新加载缓存。
  ///
  /// 传入 [assistantId] 可将该助手的限定条目与全局条目一并加载。
  /// `null` 仅加载全局条目，除非 [loadAll] 为 true。
  Future<void> refresh({String? assistantId, bool loadAll = false}) async {
    _focusAssistantId = assistantId;
    _loadAll = loadAll;
    try {
      final entries = loadAll
          ? await chatRepository.queryAllMemories(includeArchived: true)
          : await chatRepository.queryVisibleMemories(
              assistantId: assistantId,
              includeArchived: true,
            );
      final profile = await chatRepository.readProfileFields();
      final orphans = await chatRepository.countOrphanAssistantMemories();
      _entries = entries;
      _profileFields = profile;
      _orphanCount = orphans;
      notifyListeners();
    } catch (e) {
      debugPrint('MemoryProviderV2.refresh failed: $e');
      _entries = const <MemoryEntry>[];
      _profileFields = const <UserProfileField>[];
      _orphanCount = 0;
      notifyListeners();
    }
  }

  /// 面向全局管理界面（§14.4）的便捷方法。
  Future<void> refreshAll() => refresh(loadAll: true);

  /// 重新读取，而不改变界面当前显示的条目。
  ///
  /// 后台工作不应缩小可见集合：它知道自己为哪个助手运行，
  /// 但用户可能正在查看所有助手，而把该 id 传给 [refresh] 会让其他条目消失，
  /// 直到页面重新打开才恢复。
  Future<void> reloadCurrentScope() =>
      refresh(assistantId: _focusAssistantId, loadAll: _loadAll);

  /// 按 §5.9 token AND 搜索。当 [acrossAll] 为 true 时，搜索所有
  /// 助手；否则遵循 [assistantId] 的可见范围。
  Future<List<MemoryEntry>> search({
    required List<String> tokens,
    String? assistantId,
    bool acrossAll = false,
    MemoryType? type,
    bool includeArchived = false,
    int limit = 200,
  }) {
    if (acrossAll) {
      return chatRepository.searchAllMemories(
        tokens: tokens,
        type: type,
        includeArchived: includeArchived,
        limit: limit,
      );
    }
    return chatRepository.searchMemories(
      assistantId: assistantId,
      tokens: tokens,
      type: type,
      matchAll: true,
      limit: limit,
    );
  }

  Future<MemoryEntry> create({
    required MemoryScope scope,
    String? assistantId,
    required MemoryType type,
    required String content,
    required MemorySource source,
    List<String> relatedIds = const [],
  }) async {
    final entry = await repository.create(
      scope: scope,
      assistantId: assistantId,
      type: type,
      content: content,
      source: source,
      relatedIds: relatedIds,
    );
    await _refreshAfterWrite();
    return entry;
  }

  Future<MemoryEntry?> updateContent(String id, String content) async {
    final entry = await repository.updateContent(id, content);
    await _refreshAfterWrite();
    return entry;
  }

  Future<MemoryEntry?> updateScope(
    String id, {
    required MemoryScope scope,
    String? assistantId,
  }) async {
    final entry = await repository.updateScope(
      id,
      scope: scope,
      assistantId: assistantId,
    );
    await _refreshAfterWrite();
    return entry;
  }

  Future<bool> archive(String id) async {
    final ok = await repository.archive(id);
    await _refreshAfterWrite();
    return ok;
  }

  Future<bool> restore(String id) async {
    final ok = await repository.restore(id);
    await _refreshAfterWrite();
    return ok;
  }

  Future<bool> hardDelete(String id) async {
    final ok = await repository.hardDelete(id);
    await _refreshAfterWrite();
    return ok;
  }

  Future<int> hardDeleteMany(List<String> ids) async {
    final count = await repository.hardDeleteMany(ids);
    await _refreshAfterWrite();
    return count;
  }

  Future<void> linkBidirectional(String a, String b) async {
    await repository.linkBidirectional(a, b);
    await _refreshAfterWrite();
  }

  Future<int> deleteOrphanAssistantMemories() async {
    final count = await repository.deleteOrphanAssistantMemories();
    await _refreshAfterWrite();
    return count;
  }

  Future<void> putProfileField(
    String key,
    String value,
    MemorySource source,
  ) async {
    await repository.putProfileField(key, value, source);
    await _refreshAfterWrite();
  }

  Future<bool> removeProfileField(String key) async {
    final ok = await repository.removeProfileField(key);
    await _refreshAfterWrite();
    return ok;
  }

  Future<void> _refreshAfterWrite() => reloadCurrentScope();

  static bool _isVisible(MemoryEntry entry, String? assistantId) {
    if (entry.scope == MemoryScope.global) return true;
    if (assistantId == null) return false;
    return entry.assistantId == assistantId;
  }
}
