import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../database/business_preferences.dart';
import '../models/assistant_group.dart';

/// 管理助手分组、分配、顺序和折叠状态。
class AssistantGroupProvider extends ChangeNotifier {
  // These keys are part of the existing settings and backup format.
  static const String _groupsKey = 'assistant_tags_v1';
  static const String _assignKey =
      'assistant_tag_map_v1'; // assistantId -> groupId
  static const String _collapsedKey =
      'assistant_tag_collapsed_v1'; // groupId -> bool

  final BusinessPreferences preferences;
  final List<AssistantGroup> _groups = <AssistantGroup>[];
  final Map<String, String> _assignment = <String, String>{};
  final Map<String, bool> _collapsed = <String, bool>{};

  List<AssistantGroup> get groups => List.unmodifiable(_groups);
  Map<String, String> get assignment => Map.unmodifiable(_assignment);
  bool isGroupCollapsed(String groupId) => _collapsed[groupId] ?? false;

  AssistantGroupProvider({required this.preferences}) {
    _load();
  }

  Future<void> _load() async {
    await preferences.load();
    final rawGroups = preferences.getString(_groupsKey);
    if (rawGroups != null && rawGroups.isNotEmpty) {
      _groups
        ..clear()
        ..addAll(AssistantGroup.decodeList(rawGroups));
    }
    final rawMap = preferences.getString(_assignKey);
    if (rawMap != null && rawMap.isNotEmpty) {
      try {
        final m = jsonDecode(rawMap) as Map<String, dynamic>;
        _assignment
          ..clear()
          ..addAll(m.map((k, v) => MapEntry(k, v.toString())));
      } catch (_) {}
    }
    final rawCol = preferences.getString(_collapsedKey);
    if (rawCol != null && rawCol.isNotEmpty) {
      try {
        final m = jsonDecode(rawCol) as Map<String, dynamic>;
        _collapsed
          ..clear()
          ..addAll(
            m.map(
              (k, v) => MapEntry(k, (v is bool) ? v : (v.toString() == 'true')),
            ),
          );
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _persistGroups() async {
    await preferences.setString(_groupsKey, AssistantGroup.encodeList(_groups));
  }

  Future<void> _persistAssignment() async {
    await preferences.setString(_assignKey, jsonEncode(_assignment));
  }

  Future<void> _persistCollapsed() async {
    await preferences.setString(_collapsedKey, jsonEncode(_collapsed));
  }

  String? groupOfAssistant(String assistantId) => _assignment[assistantId];

  Future<String> createGroup(String name) async {
    final id = const Uuid().v4();
    _groups.add(AssistantGroup(id: id, name: name.trim()));
    await _persistGroups();
    notifyListeners();
    return id;
  }

  Future<void> renameGroup(String groupId, String name) async {
    final idx = _groups.indexWhere((group) => group.id == groupId);
    if (idx == -1) return;
    _groups[idx] = _groups[idx].copyWith(name: name.trim());
    await _persistGroups();
    notifyListeners();
  }

  Future<void> deleteGroup(String groupId) async {
    final idx = _groups.indexWhere((group) => group.id == groupId);
    if (idx == -1) return;
    _groups.removeAt(idx);
    _collapsed.remove(groupId);
    // 取消分配使用此分组的助手
    _assignment.removeWhere((_, v) => v == groupId);
    await _persistGroups();
    await _persistAssignment();
    await _persistCollapsed();
    notifyListeners();
  }

  Future<void> reorderGroups(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _groups.length) return;
    if (newIndex < 0 || newIndex >= _groups.length) return;
    final group = _groups.removeAt(oldIndex);
    _groups.insert(newIndex, group);
    notifyListeners();
    await _persistGroups();
  }

  Future<void> assignAssistantToGroup(
    String assistantId,
    String? groupId,
  ) async {
    if (groupId == null || groupId.isEmpty) {
      _assignment.remove(assistantId);
    } else {
      _assignment[assistantId] = groupId;
    }
    notifyListeners();
    await _persistAssignment();
  }

  Future<void> assignAssistantsToGroup(
    Iterable<String> assistantIds,
    String? groupId,
  ) async {
    var changed = false;
    for (final assistantId in assistantIds.toSet()) {
      if (groupId == null || groupId.isEmpty) {
        changed = _assignment.remove(assistantId) != null || changed;
      } else if (_assignment[assistantId] != groupId) {
        _assignment[assistantId] = groupId;
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    await _persistAssignment();
  }

  Future<void> unassignAssistantFromGroup(String assistantId) async {
    if (_assignment.containsKey(assistantId)) {
      _assignment.remove(assistantId);
      notifyListeners();
      await _persistAssignment();
    }
  }

  Future<void> setGroupCollapsed(String groupId, bool value) async {
    _collapsed[groupId] = value;
    notifyListeners();
    await _persistCollapsed();
  }

  Future<void> toggleGroupCollapsed(String groupId) =>
      setGroupCollapsed(groupId, !isGroupCollapsed(groupId));
}
