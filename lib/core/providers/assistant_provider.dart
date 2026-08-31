import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../utils/sandbox_path_resolver.dart';
import '../database/business_preferences.dart';
import '../database/business_data.dart';
import '../database/business_repository.dart';
import '../models/assistant.dart';
import '../models/assistant_list_item.dart';
import '../models/assistant_regex.dart';
import '../models/preset_message.dart';
import '../services/chat/chat_service.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/avatar_cache.dart';
import '../../utils/app_directories.dart';

class AssistantProvider extends ChangeNotifier {
  static const String _assistantsKey = 'assistants_v1';
  static const String _currentAssistantKey = 'current_assistant_id_v1';

  final BusinessPreferences preferences;
  final List<Assistant> _assistants = <Assistant>[];
  final Map<String, Assistant> _assistantsById = <String, Assistant>{};
  List<AssistantListItem> _assistantDirectory = const <AssistantListItem>[];
  int _directoryRevision = 0;
  String? _currentAssistantId;
  final ChatService? chatService;
  final BusinessRepository? businessRepository;

  List<Assistant> get assistants => List.unmodifiable(_assistants);

  /// 列表和搜索使用的轻量目录，不包含完整助手配置。
  List<AssistantListItem> get assistantDirectory => _assistantDirectory;
  int get assistantDirectoryRevision => _directoryRevision;
  String? get currentAssistantId => _currentAssistantId;
  Assistant? get currentAssistant {
    final selectedId = _currentAssistantId;
    if (selectedId != null) {
      final selected = _assistantsById[selectedId];
      if (selected != null) return selected;
    }
    if (_assistants.isNotEmpty) return _assistants.first;
    return null;
  }

  bool get currentSearchEnabled => currentAssistant?.searchEnabled ?? false;

  AssistantProvider({
    required this.preferences,
    this.chatService,
    this.businessRepository,
  }) {
    loaded = _load();
  }

  late final Future<void> loaded;

  Future<void> _load() async {
    if (!preferences.isLoaded) {
      await preferences.load();
    }
    final repository = businessRepository;
    if (repository != null) {
      final rows = await repository.readEntities(BusinessEntityKind.assistant);
      if (rows.isNotEmpty) {
        _assistants
          ..clear()
          ..addAll(_decodeAssistantRows(rows));
      } else {
        final raw = preferences.getString(_assistantsKey);
        if (raw != null && raw.isNotEmpty) {
          _assistants
            ..clear()
            ..addAll(_decodeAssistants(raw));
          await _replaceAllAssistantRows();
        }
      }
    } else {
      final raw = preferences.getString(_assistantsKey);
      if (raw != null && raw.isNotEmpty) {
        _assistants
          ..clear()
          ..addAll(_decodeAssistants(raw));
      }
    }
    _rebuildAssistantIndex();
    _rebuildAssistantDirectory();

    if (_assistants.isNotEmpty) {
      // 修复从其他平台导入的沙盒本地路径（头像/背景）
      bool changed = false;
      for (int i = 0; i < _assistants.length; i++) {
        final a = _assistants[i];
        String? av = a.avatar;
        String? bg = a.background;
        var itemChanged = false;
        if (av != null &&
            av.isNotEmpty &&
            (av.startsWith('/') || av.contains(':')) &&
            !av.startsWith('http')) {
          final fixed = SandboxPathResolver.fix(av);
          if (fixed != av) {
            av = fixed;
            changed = true;
            itemChanged = true;
          }
        }
        if (bg != null &&
            bg.isNotEmpty &&
            (bg.startsWith('/') || bg.contains(':')) &&
            !bg.startsWith('http')) {
          final fixedBg = SandboxPathResolver.fix(bg);
          if (fixedBg != bg) {
            bg = fixedBg;
            changed = true;
            itemChanged = true;
          }
        }
        if (itemChanged) {
          _assistants[i] = a.copyWith(avatar: av, background: bg);
        }
      }
      if (changed) {
        if (repository != null) {
          await _replaceAllAssistantRows();
        } else {
          try {
            await _persistLegacyPreferences();
          } catch (_) {}
        }
        _rebuildAssistantIndex();
        _rebuildAssistantDirectory();
      }
    }
    // 不要在此处创建默认值，因为本地化尚不可用。
    // 默认值将在稍后通过 ensureDefaults(context) 确保。
    // 如果存在当前助手则恢复
    final savedValue = preferences.get(_currentAssistantKey);
    final savedId = savedValue is String ? savedValue : null;
    if (savedId != null && _assistantsById.containsKey(savedId)) {
      _currentAssistantId = savedId;
    } else {
      _currentAssistantId = null;
    }
    notifyListeners();
  }

  List<Assistant> _decodeAssistants(String raw) {
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in decoded)
          if (e is Map) Assistant.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const <Assistant>[];
    }
  }

  List<Assistant> _decodeAssistantRows(List<BusinessEntityValue> rows) {
    final assistants = <Assistant>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row.payload);
        if (decoded is! Map) continue;
        final payload = decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        payload['id'] = row.id;
        assistants.add(Assistant.fromJson(payload.cast<String, dynamic>()));
      } catch (_) {
        // A corrupt row must not prevent other assistants from loading.
      }
    }
    return assistants;
  }

  void _rebuildAssistantIndex() {
    _assistantsById
      ..clear()
      ..addEntries(
        _assistants.map((assistant) => MapEntry(assistant.id, assistant)),
      );
  }

  void _rebuildAssistantDirectory() {
    _assistantDirectory = List<AssistantListItem>.unmodifiable([
      for (var index = 0; index < _assistants.length; index++)
        AssistantListItem.fromAssistant(_assistants[index], sortOrder: index),
    ]);
    _directoryRevision++;
  }

  /// 按 ID 获取完整助手配置。列表页只应使用 [assistantDirectory]；
  /// 需要提示词、工具或正则时再调用此方法。
  Future<Assistant?> loadAssistantDetails(String id) async {
    await loaded;
    final cached = _assistantsById[id];
    if (cached != null) return cached;
    final repository = businessRepository;
    if (repository == null) return null;
    final row = await repository.readEntity(BusinessEntityKind.assistant, id);
    if (row == null) return null;
    try {
      final decoded = jsonDecode(row.payload);
      if (decoded is! Map) return null;
      final payload = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      payload['id'] = row.id;
      final assistant = Assistant.fromJson(payload.cast<String, dynamic>());
      _assistantsById[assistant.id] = assistant;
      return assistant;
    } catch (_) {
      return null;
    }
  }

  BusinessEntityValue _assistantEntity(Assistant assistant, int sortOrder) {
    return BusinessEntityValue(
      id: assistant.id,
      sortOrder: sortOrder,
      payload: jsonEncode(assistant.toJson()),
    );
  }

  Future<void> _replaceAllAssistantRows() async {
    final repository = businessRepository;
    if (repository == null) return;
    await repository.replaceEntities(BusinessEntityKind.assistant, [
      for (var index = 0; index < _assistants.length; index++)
        _assistantEntity(_assistants[index], index),
    ]);
  }

  Future<void> _persistAssistant(Assistant assistant, int sortOrder) async {
    final repository = businessRepository;
    if (repository != null) {
      await repository.upsertEntity(
        BusinessEntityKind.assistant,
        _assistantEntity(assistant, sortOrder),
      );
      return;
    }
    await _persistLegacyPreferences();
  }

  Future<void> _deleteAssistantRow(String id) async {
    final repository = businessRepository;
    if (repository != null) {
      await repository.deleteEntity(BusinessEntityKind.assistant, id);
    } else {
      await _persistLegacyPreferences();
    }
  }

  Future<void> _persistAssistantOrder() async {
    final repository = businessRepository;
    if (repository != null) {
      await repository.updateEntitySortOrders(
        BusinessEntityKind.assistant,
        _assistants.map((assistant) => assistant.id).toList(growable: false),
      );
    } else {
      await _persistLegacyPreferences();
    }
  }

  Future<void> _persistLegacyPreferences() =>
      preferences.setString(_assistantsKey, Assistant.encodeList(_assistants));

  Assistant _defaultAssistant(AppLocalizations l10n) => Assistant(
    id: const Uuid().v4(),
    name: l10n.assistantProviderDefaultAssistantName,
    systemPrompt: '',
    thinkingBudget: null,
    temperature: null,
    topP: null,
    limitContextMessages: false,
  );

  // 确保本地化默认助手存在；请在本地化就绪后调用此方法。
  Future<void> ensureDefaults(dynamic context) async {
    await loaded;
    if (_assistants.isNotEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    // 1) 默认助手
    _assistants.add(_defaultAssistant(l10n));
    // 2) 示例助手（带提示词模板）
    _assistants.add(
      Assistant(
        id: const Uuid().v4(),
        name: l10n.assistantProviderSampleAssistantName,
        systemPrompt: l10n.assistantProviderSampleAssistantSystemPrompt(
          '{model_name}',
        ),
        temperature: null,
        topP: null,
        limitContextMessages: false,
      ),
    );
    _rebuildAssistantIndex();
    _rebuildAssistantDirectory();
    await _persist();
    // 若当前助手未设置，则进行设置
    if (_currentAssistantId == null && _assistants.isNotEmpty) {
      _currentAssistantId = _assistants.first.id;
      await preferences.setString(_currentAssistantKey, _currentAssistantId!);
    }
    notifyListeners();
  }

  String _buildCopyName(Assistant source, AppLocalizations? l10n) {
    final suffix = (l10n?.assistantSettingsCopySuffix ?? 'Copy').trim();
    final baseName = source.name.trim().isEmpty
        ? (l10n?.assistantProviderNewAssistantName ?? 'Assistant')
        : source.name.trim();
    final existingNames = _assistants.map((a) => a.name).toSet();

    String candidate = suffix.isEmpty ? baseName : '$baseName $suffix';
    int counter = 2;
    while (existingNames.contains(candidate)) {
      final counterSuffix = suffix.isEmpty ? '$counter' : '$suffix $counter';
      candidate = '$baseName $counterSuffix';
      counter++;
    }
    return candidate;
  }

  Future<String?> _duplicateLocalFile(
    String? rawPath, {
    required bool isAvatar,
    required String newId,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty) return rawPath;
    if (raw.startsWith('http') || raw.startsWith('data:')) return rawPath;
    final fixed = SandboxPathResolver.fix(raw);
    final src = File(fixed);
    if (!await src.exists()) {
      final looksLikeLocalPath = raw.startsWith('/') || raw.contains(':');
      return looksLikeLocalPath ? null : rawPath;
    }

    try {
      final dir = isAvatar
          ? await AppDirectories.getAvatarsDirectory()
          : await AppDirectories.getImagesDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      String ext = '';
      final dot = fixed.lastIndexOf('.');
      if (dot != -1 && dot < fixed.length - 1) {
        ext = fixed.substring(dot + 1).toLowerCase();
        if (ext.length > 6) ext = 'jpg';
      } else {
        ext = 'jpg';
      }
      final prefix = isAvatar ? 'assistant' : 'background';
      final dest = File(
        '${dir.path}/${prefix}_${newId}_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await src.copy(dest.path);
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  bool _isLocalAssetReference(String? rawPath) {
    final raw = (rawPath ?? '').trim();
    return raw.isNotEmpty &&
        !raw.startsWith('http') &&
        !raw.startsWith('data:') &&
        (raw.startsWith('/') || raw.contains(':'));
  }

  bool _isReferencedByAnotherAssistant(
    String? rawPath,
    String assistantId, {
    required bool isAvatar,
  }) {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty) return false;
    final target = p.normalize(
      File(SandboxPathResolver.fix(raw)).absolute.path,
    );
    for (final assistant in _assistants) {
      if (assistant.id == assistantId) continue;
      final candidate = isAvatar ? assistant.avatar : assistant.background;
      final value = (candidate ?? '').trim();
      if (value.isEmpty) continue;
      final normalized = p.normalize(
        File(SandboxPathResolver.fix(value)).absolute.path,
      );
      if (p.equals(target, normalized)) return true;
    }
    return false;
  }

  Future<String?> _copyLocalAssetToManagedDirectory(
    String? rawPath, {
    required Future<Directory> Function() directoryAsync,
    required String filenamePrefix,
    required String id,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty || raw.startsWith('http') || raw.startsWith('data:')) {
      return rawPath;
    }
    if (!(raw.startsWith('/') || raw.contains(':'))) return rawPath;

    final fixed = SandboxPathResolver.fix(raw);
    final src = File(fixed);
    if (!await src.exists()) return rawPath;

    final managedDir = await directoryAsync();
    final managedRoot = p.normalize(managedDir.absolute.path);
    final sourcePath = p.normalize(src.absolute.path);
    if (p.isWithin(managedRoot, sourcePath)) return fixed;

    if (!await managedDir.exists()) {
      await managedDir.create(recursive: true);
    }

    var ext = p.extension(fixed).toLowerCase();
    if (ext.isEmpty || ext.length > 7) ext = '.jpg';
    final safeId = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dest = File(
      p.join(
        managedDir.path,
        '${filenamePrefix}_${safeId}_${DateTime.now().millisecondsSinceEpoch}$ext',
      ),
    );
    await src.copy(dest.path);
    return dest.path;
  }

  Future<void> _deleteManagedFileIfOwned(
    String? rawPath, {
    required Future<Directory> Function() directoryAsync,
    required String? replacementPath,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty) return;
    try {
      final dir = await directoryAsync();
      final root = p.normalize(dir.absolute.path);
      final targetFile = File(raw);
      final target = p.normalize(targetFile.absolute.path);
      if (!p.isWithin(root, target)) return;
      if (replacementPath != null &&
          p.equals(target, p.normalize(File(replacementPath).absolute.path))) {
        return;
      }
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    if (businessRepository != null) {
      await _replaceAllAssistantRows();
    } else {
      await _persistLegacyPreferences();
    }
  }

  Future<void> setCurrentAssistant(String id) async {
    await loaded;
    if (_currentAssistantId == id) return;
    _currentAssistantId = id;
    notifyListeners();
    await preferences.setString(_currentAssistantKey, id);
  }

  Assistant? getById(String id) {
    return _assistantsById[id];
  }

  // 轻量级访问器，使调用方无需依赖 Assistant.presetMessages 符号
  List<Map<String, String>> getPresetMessagesForAssistant(String? assistantId) {
    Assistant? a;
    if (assistantId != null) {
      a = getById(assistantId);
    } else {
      a = currentAssistant;
    }
    if (a == null) return const <Map<String, String>>[];
    return [
      for (final m in a.presetMessages) {'role': m.role, 'content': m.content},
    ];
  }

  Future<String> addAssistant({
    String? name,
    dynamic context,
    bool insertAtTop = false,
  }) async {
    final a = Assistant(
      id: const Uuid().v4(),
      name:
          (name ??
          (context != null
              ? AppLocalizations.of(context)!.assistantProviderNewAssistantName
              : 'New Assistant')),
      temperature: null,
      topP: null,
      limitContextMessages: false,
    );
    if (insertAtTop) {
      _assistants.insert(0, a);
    } else {
      _assistants.add(a);
    }
    _rebuildAssistantIndex();
    _rebuildAssistantDirectory();
    if (businessRepository != null) {
      await _persistAssistant(a, _assistants.indexOf(a));
      await _persistAssistantOrder();
    } else {
      await _persistLegacyPreferences();
    }
    notifyListeners();
    return a.id;
  }

  /// Persists an assistant reconstructed from an external conversation
  /// without changing an existing assistant with the same stable id.
  Future<void> addImportedAssistant(Assistant assistant) async {
    await loaded;
    if (_assistantsById.containsKey(assistant.id)) return;
    _assistants.add(assistant);
    _rebuildAssistantIndex();
    _rebuildAssistantDirectory();
    if (businessRepository != null) {
      await _persistAssistant(assistant, _assistants.indexOf(assistant));
      await _persistAssistantOrder();
    } else {
      await _persistLegacyPreferences();
    }
    notifyListeners();
  }

  Future<String?> duplicateAssistant(
    String id, {
    AppLocalizations? l10n,
    bool insertAtTop = false,
  }) async {
    final source = _assistantsById[id];
    if (source == null) return null;
    final idx = _assistants.indexOf(source);
    final newId = const Uuid().v4();

    final avatarCopy = await _duplicateLocalFile(
      source.avatar,
      isAvatar: true,
      newId: newId,
    );
    if (_isLocalAssetReference(source.avatar) && avatarCopy == null) {
      return null;
    }
    final backgroundCopy = await _duplicateLocalFile(
      source.background,
      isAvatar: false,
      newId: newId,
    );
    if (_isLocalAssetReference(source.background) && backgroundCopy == null) {
      if (avatarCopy != null) {
        await _deleteManagedFileIfOwned(
          avatarCopy,
          directoryAsync: AppDirectories.getAvatarsDirectory,
          replacementPath: null,
        );
      }
      return null;
    }

    final copy = source.copyWith(
      id: newId,
      name: _buildCopyName(source, l10n),
      avatar: avatarCopy,
      background: backgroundCopy,
      mcpServerIds: List<String>.of(source.mcpServerIds),
      localToolIds: List<String>.of(source.localToolIds),
      customHeaders: source.customHeaders
          .map((e) => Map<String, String>.from(e))
          .toList(),
      customBody: source.customBody
          .map((e) => Map<String, String>.from(e))
          .toList(),
      presetMessages: source.presetMessages
          .map((m) => PresetMessage(role: m.role, content: m.content))
          .toList(),
      regexRules: source.regexRules
          .map(
            (r) => AssistantRegex(
              id: const Uuid().v4(),
              name: r.name,
              pattern: r.pattern,
              replacement: r.replacement,
              scopes: List<AssistantRegexScope>.of(r.scopes),
              visualOnly: r.visualOnly,
              replaceOnly: r.replaceOnly,
              enabled: r.enabled,
            ),
          )
          .toList(),
    );

    if (insertAtTop) {
      _assistants.insert(0, copy);
    } else {
      _assistants.insert(idx + 1, copy);
    }
    _rebuildAssistantIndex();
    _rebuildAssistantDirectory();
    if (businessRepository != null) {
      await _persistAssistant(copy, _assistants.indexOf(copy));
      await _persistAssistantOrder();
    } else {
      await _persistLegacyPreferences();
    }
    notifyListeners();
    return copy.id;
  }

  Future<void> updateAssistant(Assistant updated) async {
    final idx = _assistants.indexWhere((a) => a.id == updated.id);
    if (idx == -1) return;

    var next = updated;

    try {
      final prev = _assistants[idx];
      final raw = (updated.avatar ?? '').trim();
      final prevRaw = (prev.avatar ?? '').trim();
      final changed = raw != prevRaw;

      // Changing the source image/type invalidates the previous display crop,
      // unless the caller explicitly supplied a new transform.
      if (changed && updated.avatarTransform == prev.avatarTransform) {
        next = updated.copyWith(clearAvatarTransform: true);
      }

      if (changed) {
        final avatarPath = await _copyLocalAssetToManagedDirectory(
          raw,
          directoryAsync: AppDirectories.getAvatarsDirectory,
          filenamePrefix: 'assistant',
          id: updated.id,
        );
        if (avatarPath != updated.avatar) {
          if (!_isReferencedByAnotherAssistant(
            prevRaw,
            updated.id,
            isAvatar: true,
          )) {
            await _deleteManagedFileIfOwned(
              prevRaw,
              directoryAsync: AppDirectories.getAvatarsDirectory,
              replacementPath: avatarPath,
            );
          }
          next = next.copyWith(avatar: avatarPath);
        } else if (raw.isEmpty) {
          if (!_isReferencedByAnotherAssistant(
            prevRaw,
            updated.id,
            isAvatar: true,
          )) {
            await _deleteManagedFileIfOwned(
              prevRaw,
              directoryAsync: AppDirectories.getAvatarsDirectory,
              replacementPath: null,
            );
          }
        }
      }

      // 预取 URL 头像，以便稍后可离线显示
      if (changed && raw.startsWith('http')) {
        try {
          await AvatarCache.getPath(raw);
        } catch (_) {}
      }

      // 处理背景持久化，方式与头像类似，但位于 images/ 下
      final bgRaw = (updated.background ?? '').trim();
      final prevBgRaw = (prev.background ?? '').trim();
      final bgChanged = bgRaw != prevBgRaw;
      if (bgChanged) {
        final backgroundPath = await _copyLocalAssetToManagedDirectory(
          bgRaw,
          directoryAsync: AppDirectories.getImagesDirectory,
          filenamePrefix: 'background',
          id: updated.id,
        );
        if (backgroundPath != updated.background) {
          if (!_isReferencedByAnotherAssistant(
            prevBgRaw,
            updated.id,
            isAvatar: false,
          )) {
            await _deleteManagedFileIfOwned(
              prevBgRaw,
              directoryAsync: AppDirectories.getImagesDirectory,
              replacementPath: backgroundPath,
            );
          }
          next = next.copyWith(background: backgroundPath);
        } else if (bgRaw.isEmpty) {
          if (!_isReferencedByAnotherAssistant(
            prevBgRaw,
            updated.id,
            isAvatar: false,
          )) {
            await _deleteManagedFileIfOwned(
              prevBgRaw,
              directoryAsync: AppDirectories.getImagesDirectory,
              replacementPath: null,
            );
          }
        }
      }
    } catch (_) {
      // 任何失败时，原样回退到提供的值。
    }

    _assistants[idx] = next;
    _assistantsById[next.id] = next;
    _rebuildAssistantDirectory();
    if (businessRepository != null) {
      await _persistAssistant(next, idx);
    } else {
      await _persistLegacyPreferences();
    }
    notifyListeners();
  }

  Future<void> setSearchEnabledForCurrentAssistant(bool enabled) async {
    final a = currentAssistant;
    if (a == null || a.searchEnabled == enabled) return;
    await updateAssistant(a.copyWith(searchEnabled: enabled));
  }

  Future<void> reorderAssistantRegex({
    required String assistantId,
    required int oldIndex,
    required int newIndex,
  }) async {
    final idx = _assistants.indexWhere((a) => a.id == assistantId);
    if (idx == -1) return;
    final list = List<AssistantRegex>.of(_assistants[idx].regexRules);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex < 0 || newIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _assistants[idx] = _assistants[idx].copyWith(regexRules: list);
    _assistantsById[assistantId] = _assistants[idx];
    _rebuildAssistantDirectory();
    notifyListeners();
    if (businessRepository != null) {
      await _persistAssistant(_assistants[idx], idx);
    } else {
      await _persistLegacyPreferences();
    }
  }

  Future<bool> deleteAssistant(String id) async {
    final idx = _assistants.indexWhere((a) => a.id == id);
    if (idx == -1) return false;
    // 不允许删除最后一个剩余的助手
    if (_assistants.length <= 1) return false;

    await chatService?.deleteConversationsForAssistant(id);

    final removingCurrent = _assistants[idx].id == _currentAssistantId;
    _assistants.removeAt(idx);
    _assistantsById.remove(id);
    _rebuildAssistantDirectory();
    if (removingCurrent) {
      _currentAssistantId = _assistants.isNotEmpty
          ? _assistants.first.id
          : null;
    }
    if (businessRepository != null) {
      await _deleteAssistantRow(id);
      await _persistAssistantOrder();
    } else {
      await _persistLegacyPreferences();
    }
    if (_currentAssistantId != null) {
      await preferences.setString(_currentAssistantKey, _currentAssistantId!);
    } else {
      await preferences.remove(_currentAssistantKey);
    }
    notifyListeners();
    return true;
  }

  /// 删除多个助手。至少保留一个助手；当请求包含全部助手时保留当前列表中的第一个。
  Future<int> deleteAssistants(Iterable<String> ids) async {
    final uniqueIds = ids.toSet();
    if (uniqueIds.isEmpty || _assistants.length <= 1) return 0;
    final deletable = _assistants
        .where((assistant) => uniqueIds.contains(assistant.id))
        .map((assistant) => assistant.id)
        .toList();
    if (deletable.length >= _assistants.length) {
      final keepId = _currentAssistantId ?? _assistants.first.id;
      deletable.remove(keepId);
    }
    var deleted = 0;
    for (final id in deletable) {
      if (await deleteAssistant(id)) deleted++;
    }
    return deleted;
  }

  Future<void> reorderAssistants(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _assistants.length) return;
    if (newIndex < 0 || newIndex >= _assistants.length) return;

    final assistant = _assistants.removeAt(oldIndex);
    _assistants.insert(newIndex, assistant);
    _rebuildAssistantIndex();
    _rebuildAssistantDirectory();

    // 立即通知监听器，以便 UI 平滑更新
    notifyListeners();

    // 然后持久化更改
    await _persistAssistantOrder();
  }

  // 仅在子集内重新排序（例如属于某个标签组或未分组的助手）。
  // subsetIds 定义集合与顺序边界；其他助手保持原位。
  Future<void> reorderAssistantsWithin({
    required List<String> subsetIds,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex == newIndex) return;
    if (subsetIds.isEmpty) return;

    // 在主列表中构建子集索引，同时保留当前顺序
    final idSet = subsetIds.toSet();
    final subsetIndices = <int>[];
    for (int i = 0; i < _assistants.length; i++) {
      if (idSet.contains(_assistants[i].id)) subsetIndices.add(i);
    }
    if (subsetIndices.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= subsetIndices.length) return;
    if (newIndex < 0 || newIndex >= subsetIndices.length) return;

    // 按当前顺序提取子集
    final subset = subsetIndices
        .map((i) => _assistants[i])
        .toList(growable: true);
    final moved = subset.removeAt(oldIndex);
    subset.insert(newIndex, moved);

    // 合并回主列表
    final merged = <Assistant>[];
    int take = 0;
    for (int i = 0; i < _assistants.length; i++) {
      final a = _assistants[i];
      if (idSet.contains(a.id)) {
        merged.add(subset[take++]);
      } else {
        merged.add(a);
      }
    }
    _assistants
      ..clear()
      ..addAll(merged);
    _rebuildAssistantIndex();
    _rebuildAssistantDirectory();

    notifyListeners();
    await _persistAssistantOrder();
  }
}
