import 'dart:convert';

import '../../../core/database/business_preferences.dart';

/// 持久化聊天侧栏的轻量 UI 状态。
final class ChatSidebarStateStore {
  ChatSidebarStateStore(this._preferences);

  static const lastOpenedConversationKey =
      'chat_sidebar_last_opened_conversation_v1';
  static const assistantScrollOffsetsKey =
      'chat_sidebar_assistant_scroll_offsets_v1';

  final BusinessPreferences _preferences;
  Map<String, double> _assistantScrollOffsets = <String, double>{};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    await _preferences.load();
    _assistantScrollOffsets = _decodeOffsets(
      _preferences.getString(assistantScrollOffsetsKey),
    );
    _loaded = true;
  }

  String? get lastOpenedConversationId =>
      _preferences.getString(lastOpenedConversationKey);

  Future<void> setLastOpenedConversationId(String? id) async {
    if (!_loaded) await load();
    final trimmed = id?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await _preferences.remove(lastOpenedConversationKey);
    } else {
      await _preferences.setString(lastOpenedConversationKey, trimmed);
    }
  }

  double assistantScrollOffset(String scope) {
    final value = _assistantScrollOffsets[scope];
    return value != null && value.isFinite && value >= 0 ? value : 0;
  }

  Future<void> setAssistantScrollOffset(String scope, double offset) async {
    if (!_loaded) await load();
    if (!offset.isFinite || offset < 0) return;
    _assistantScrollOffsets[scope] = offset;
    await _preferences.setString(
      assistantScrollOffsetsKey,
      jsonEncode(_assistantScrollOffsets),
    );
  }

  static Map<String, double> _decodeOffsets(String? raw) {
    if (raw == null || raw.isEmpty) return <String, double>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, double>{};
      return <String, double>{
        for (final entry in decoded.entries)
          if (entry.value is num &&
              (entry.value as num).toDouble().isFinite &&
              (entry.value as num).toDouble() >= 0)
            entry.key.toString(): (entry.value as num).toDouble(),
      };
    } on FormatException {
      return <String, double>{};
    }
  }
}
