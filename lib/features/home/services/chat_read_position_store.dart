import 'dart:convert';

import '../../../core/database/business_preferences.dart';

/// 保存每个会话最近一次阅读位置的会话级 UI 状态。
///
/// 浏览位置不适合进入会话模型；这里复用业务偏好的键值存储，并在桌面退出时
/// 随 [BusinessPreferences] 一起排空。
final class ChatReadPositionStore {
  ChatReadPositionStore(this._preferences);

  static const preferenceKey = 'chat_read_position_by_conversation_v1';

  final BusinessPreferences _preferences;
  Map<String, String> _positions = <String, String>{};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    await _preferences.load();
    final raw = _preferences.getString(preferenceKey);
    _positions = raw == null ? <String, String>{} : _decode(raw);
    _loaded = true;
  }

  String? read(String conversationId) => _positions[conversationId];

  Future<void> write(String conversationId, String? messageId) async {
    if (!_loaded) await load();
    if (messageId == null || messageId.isEmpty) {
      _positions.remove(conversationId);
    } else {
      _positions[conversationId] = messageId;
    }
    await _preferences.setString(preferenceKey, jsonEncode(_positions));
  }

  Map<String, String> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return <String, String>{
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value?.toString() ?? '',
      }..removeWhere((key, value) => key.isEmpty || value.isEmpty);
    } on FormatException {
      return <String, String>{};
    }
  }
}
