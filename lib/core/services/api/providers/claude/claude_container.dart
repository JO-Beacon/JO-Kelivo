import 'dart:convert';

const String claudeContainerArtifactKind = 'claude_container';

class ClaudeContainerRef {
  const ClaudeContainerRef({required this.id});

  final String id;

  static ClaudeContainerRef? fromResponse(Object? container) {
    if (container is! Map) return null;
    final id = (container['id'] ?? '').toString();
    return id.isEmpty ? null : ClaudeContainerRef(id: id);
  }

  String encode() => jsonEncode({'id': id});

  static ClaudeContainerRef? decode(Object? payload) {
    if (payload is! String || payload.isEmpty) return null;
    try {
      return fromResponse(jsonDecode(payload));
    } catch (_) {
      return null;
    }
  }
}

bool isClaudeStaleContainerError(int statusCode, String errorBody) {
  if (statusCode < 400 || statusCode >= 500) return false;
  return errorBody
      .toLowerCase()
      .replaceAll('container_upload', '')
      .contains('container');
}
