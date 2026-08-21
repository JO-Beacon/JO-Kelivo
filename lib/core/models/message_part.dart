import 'dart:convert';

/// 结构化消息 part —— 附件和文本的唯一事实来源。
///
/// 载荷约定：
/// - `text` / `reasoning`：原始字符串
/// - `tool_call`：原样保留的 JSON 字符串
/// - `image`：`{"uri","mime"?,"assetId"?,"unavailable"?}`
/// - `file`：`{"uri","name","mime"?,"assetId"?,"unavailable"?}`
/// - 未知类型：存储在 [UnknownPart] 中，并按原样写回
/// - 已知类型的损坏数据：仅在从数据库行水合时创建，并
///   存储在 [MalformedPart] 中以便无损写回
sealed class MessagePart {
  const MessagePart();

  factory MessagePart.fromRow(String kind, String payload) {
    switch (kind) {
      case 'text':
        return TextPart(payload);
      case 'reasoning':
        return ReasoningPart(payload);
      case 'tool_call':
        return ToolCallPart(payload);
      case 'image':
        return ImagePart.fromPayload(payload);
      case 'file':
        return FilePart.fromPayload(payload);
      default:
        return UnknownPart(rawKind: kind, payload: payload);
    }
  }

  String get kind;

  String encodePayload();
}

final class TextPart extends MessagePart {
  const TextPart(this.text);

  final String text;

  @override
  String get kind => 'text';

  @override
  String encodePayload() => text;
}

final class ReasoningPart extends MessagePart {
  const ReasoningPart(this.text);

  final String text;

  @override
  String get kind => 'reasoning';

  @override
  String encodePayload() => text;
}

final class ToolCallPart extends MessagePart {
  const ToolCallPart(this.payloadJson);

  final String payloadJson;

  @override
  String get kind => 'tool_call';

  @override
  String encodePayload() => payloadJson;
}

final class ImagePart extends MessagePart {
  const ImagePart({
    required this.uri,
    this.mime,
    this.assetId,
    this.unavailable = false,
  });

  factory ImagePart.fromPayload(String payload) {
    final map = _decodeObjectPayload(payload);
    final uri = map['uri'];
    if (uri is! String || uri.isEmpty) {
      throw const _MessagePartFormatException('missing_uri');
    }
    return ImagePart(
      uri: uri,
      mime: _optionalString(map, 'mime'),
      assetId: _optionalString(map, 'assetId'),
      unavailable: _optionalBool(map, 'unavailable'),
    );
  }

  final String uri;
  final String? mime;
  final String? assetId;
  final bool unavailable;

  @override
  String get kind => 'image';

  @override
  String encodePayload() => jsonEncode({
    'uri': uri,
    if (mime != null) 'mime': mime,
    if (assetId != null) 'assetId': assetId,
    if (unavailable) 'unavailable': true,
  });
}

final class FilePart extends MessagePart {
  const FilePart({
    required this.uri,
    required this.name,
    this.mime,
    this.assetId,
    this.unavailable = false,
  });

  factory FilePart.fromPayload(String payload) {
    final map = _decodeObjectPayload(payload);
    final uri = map['uri'];
    final name = map['name'];
    if (uri is! String || uri.isEmpty) {
      throw const _MessagePartFormatException('missing_uri');
    }
    if (name is! String || name.isEmpty) {
      throw const _MessagePartFormatException('missing_name');
    }
    return FilePart(
      uri: uri,
      name: name,
      mime: _optionalString(map, 'mime'),
      assetId: _optionalString(map, 'assetId'),
      unavailable: _optionalBool(map, 'unavailable'),
    );
  }

  final String uri;
  final String name;
  final String? mime;
  final String? assetId;
  final bool unavailable;

  @override
  String get kind => 'file';

  @override
  String encodePayload() => jsonEncode({
    'uri': uri,
    'name': name,
    if (mime != null) 'mime': mime,
    if (assetId != null) 'assetId': assetId,
    if (unavailable) 'unavailable': true,
  });
}

/// 用于此构建无法理解的 kind 的前向兼容载体。
final class UnknownPart extends MessagePart {
  const UnknownPart({required this.rawKind, required this.payload});

  final String rawKind;
  final String payload;

  @override
  String get kind => rawKind;

  @override
  String encodePayload() => payload;
}

/// 已知的 part 类型，但其持久化载荷无法解析。
///
/// 与 [UnknownPart] 不同，一个附件形态的损坏 part 仍可能拥有
/// 资源引用。数据库水合使用此载体隔离损坏的
/// 行，同时保留其精确载荷，以便后续修复或写回。
final class MalformedPart extends MessagePart {
  const MalformedPart({
    required this.rawKind,
    required this.rawPayload,
    required this.parseError,
  });

  final String rawKind;
  final String rawPayload;
  final String parseError;

  bool get isAttachmentKind => rawKind == 'image' || rawKind == 'file';

  @override
  String get kind => rawKind;

  @override
  String encodePayload() => rawPayload;
}

String messagePartParseErrorCategory(FormatException error) {
  return error is _MessagePartFormatException
      ? error.category
      : 'invalid_payload';
}

final class _MessagePartFormatException extends FormatException {
  const _MessagePartFormatException(this.category) : super(category);

  final String category;
}

Map<String, dynamic> _decodeObjectPayload(String payload) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    throw const _MessagePartFormatException('invalid_json');
  }
  if (decoded is! Map) {
    throw const _MessagePartFormatException('not_object');
  }
  return Map<String, dynamic>.from(decoded);
}

String? _optionalString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    final category = switch (key) {
      'mime' => 'invalid_mime',
      'assetId' => 'invalid_asset_id',
      _ => 'invalid_optional_string',
    };
    throw _MessagePartFormatException(category);
  }
  return value;
}

bool _optionalBool(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return false;
  if (value is! bool) {
    throw const _MessagePartFormatException('invalid_unavailable');
  }
  return value;
}
