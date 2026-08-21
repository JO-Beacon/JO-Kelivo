import 'package:flutter/foundation.dart';
import '../database/business_preferences.dart';
import '../models/quick_phrase.dart';
import '../services/quick_phrase_store.dart';

class QuickPhraseProvider with ChangeNotifier {
  QuickPhraseProvider({required BusinessPreferences preferences})
    : _store = QuickPhraseStore(preferences);

  final QuickPhraseStore _store;
  List<QuickPhrase> _phrases = [];
  bool _initialized = false;
  Future<void>? _initializationFuture;

  List<QuickPhrase> get phrases => List.unmodifiable(_phrases);

  List<QuickPhrase> get globalPhrases =>
      _phrases.where((p) => p.isGlobal).toList();

  List<QuickPhrase> getForAssistant(String assistantId) => _phrases
      .where((p) => !p.isGlobal && p.assistantId == assistantId)
      .toList();

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await loadAll();
      _initialized = true;
    } finally {
      _initializationFuture = null;
    }
  }

  Future<void> loadAll() async {
    try {
      _phrases = await _store.getAll();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load quick phrases: $e');
      _phrases = [];
      notifyListeners();
    }
  }

  Future<void> add(QuickPhrase phrase) async {
    await _store.add(phrase);
    await loadAll();
  }

  Future<void> update(QuickPhrase phrase) async {
    await _store.update(phrase);
    await loadAll();
  }

  Future<void> delete(String id) async {
    await _store.delete(id);
    await loadAll();
  }

  Future<void> clear() async {
    await _store.clear();
    _phrases = [];
    notifyListeners();
  }

  void _reorderInMemory({
    required int oldIndex,
    required int newIndex,
    String? assistantId,
  }) {
    final bool isGlobal = assistantId == null;

    // 确定子集（全局或特定助手）中的索引
    final List<int> subsetIndices = [];
    for (int i = 0; i < _phrases.length; i++) {
      final p = _phrases[i];
      final matches = isGlobal
          ? p.isGlobal
          : (!p.isGlobal && p.assistantId == assistantId);
      if (matches) subsetIndices.add(i);
    }

    if (subsetIndices.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= subsetIndices.length) return;
    if (newIndex < 0 || newIndex >= subsetIndices.length) return;

    // 按当前顺序提取子集
    final List<QuickPhrase> subset = subsetIndices
        .map((i) => _phrases[i])
        .toList(growable: true);

    final item = subset.removeAt(oldIndex);
    subset.insert(newIndex, item);

    // 将重新排序后的子集合并回原始列表
    final List<QuickPhrase> merged = [];
    int take = 0;
    for (int i = 0; i < _phrases.length; i++) {
      final p = _phrases[i];
      final matches = isGlobal
          ? p.isGlobal
          : (!p.isGlobal && p.assistantId == assistantId);
      if (matches) {
        merged.add(subset[take++]);
      } else {
        merged.add(p);
      }
    }
    _phrases = merged;
  }

  Future<void> reorder({
    required int oldIndex,
    required int newIndex,
    String? assistantId,
  }) async {
    _reorderInMemory(
      oldIndex: oldIndex,
      newIndex: newIndex,
      assistantId: assistantId,
    );
    notifyListeners();
    await _store.save(_phrases);
  }

  // 为清晰起见提供的向后/替代 API 名称
  Future<void> reorderPhrases({
    required int oldIndex,
    required int newIndex,
    String? assistantId,
  }) async {
    // 立即更新 UI，然后持久化
    _reorderInMemory(
      oldIndex: oldIndex,
      newIndex: newIndex,
      assistantId: assistantId,
    );
    notifyListeners();
    await _store.save(_phrases);
  }
}
