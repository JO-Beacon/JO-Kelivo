import 'dart:convert';

/// 结构化的消息 part —— 附件与文本的唯一权威表示。
///
/// 载荷约定：
/// - `text` / `reasoning`：原始字符串
/// - `tool_call`：原样保留的 JSON 字符串
/// - `image`：`{"uri","mime"?,"assetId"?,"unavailable"?}`
/// - `file`：`{"uri","name","mime"?,"assetId"?,"unavailable"?}`
/// - 未知类型：存入 [UnknownPart]，写回时保持原样
/// - 已知类型但格式损坏：仅在从数据库行填充时创建，
///   存入 [MalformedPart] 以便无损写回
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TextPart && text == other.text;

  @override
  int get hashCode => text.hashCode;
}

final class ReasoningPart extends MessagePart {
  const ReasoningPart(this.text);

  final String text;

  @override
  String get kind => 'reasoning';

  @override
  String encodePayload() => text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ReasoningPart && text == other.text;

  @override
  int get hashCode => text.hashCode;
}

final class ToolCallPart extends MessagePart {
  const ToolCallPart(this.payloadJson);

  final String payloadJson;

  @override
  String get kind => 'tool_call';

  @override
  String encodePayload() => payloadJson;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolCallPart && payloadJson == other.payloadJson;

  @override
  int get hashCode => payloadJson.hashCode;
}

final class ImagePart extends MessagePart {
  const ImagePart({
    required this.uri,
    this.mime,
    this.assetId,
    this.id,
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

  /// 流式图片 id。仅运行时使用 —— 不写入 [encodePayload]。
  final String? id;
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImagePart &&
          uri == other.uri &&
          mime == other.mime &&
          assetId == other.assetId &&
          id == other.id &&
          unavailable == other.unavailable;

  @override
  int get hashCode => Object.hash(uri, mime, assetId, id, unavailable);
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FilePart &&
          uri == other.uri &&
          name == other.name &&
          mime == other.mime &&
          assetId == other.assetId &&
          unavailable == other.unavailable;

  @override
  int get hashCode => Object.hash(uri, name, mime, assetId, unavailable);
}

/// 本构建尚不认识的类型的向前兼容载体。
final class UnknownPart extends MessagePart {
  const UnknownPart({required this.rawKind, required this.payload});

  final String rawKind;
  final String payload;

  @override
  String get kind => rawKind;

  @override
  String encodePayload() => payload;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnknownPart &&
          rawKind == other.rawKind &&
          payload == other.payload;

  @override
  int get hashCode => Object.hash(rawKind, payload);
}

/// 已知类型，但持久化载荷无法解析。
///
/// 与 [UnknownPart] 不同，形似附件的损坏 part 仍可能持有
/// 资源引用。数据库填充阶段用这个载体隔离损坏的
/// 行，同时保留其原始载荷，以便日后修复或写回。
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MalformedPart &&
          rawKind == other.rawKind &&
          rawPayload == other.rawPayload &&
          parseError == other.parseError;

  @override
  int get hashCode => Object.hash(rawKind, rawPayload, parseError);
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

/// 持久化的切分三元组能否驱动历史交错
/// 渲染。
///
/// 空数组、长度不匹配、负值以及计数回退都视为不可用。
/// 这类消息必须保持 [MessagePart] 的到达顺序。
bool contentSplitsAreUsable(
  List<int>? offsets,
  List<int>? reasoningCounts,
  List<int>? toolCounts,
) {
  if (offsets == null || reasoningCounts == null || toolCounts == null) {
    return false;
  }
  if (offsets.isEmpty ||
      offsets.length != reasoningCounts.length ||
      offsets.length != toolCounts.length) {
    return false;
  }

  var previousOffset = 0;
  var previousReasoning = 0;
  var previousTool = 0;
  for (var i = 0; i < offsets.length; i++) {
    final offset = offsets[i];
    final reasoning = reasoningCounts[i];
    final tool = toolCounts[i];
    if (offset < 0 || reasoning < 0 || tool < 0) {
      return false;
    }
    if (i > 0 &&
        (offset < previousOffset ||
            reasoning < previousReasoning ||
            tool < previousTool)) {
      return false;
    }
    previousOffset = offset;
    previousReasoning = reasoning;
    previousTool = tool;
  }
  return true;
}

/// 仅在通过 [contentSplitsAreUsable] 时才解析持久化的切分三元组。
///
/// 长度不匹配会被拒绝，而不是截断到最短的
/// 数组，因此损坏的载荷无法被“修复”成一个看似合法的
/// 交错。
({List<int> offsets, List<int> reasoningCounts, List<int> toolCounts})?
tryParseContentSplits(dynamic raw) {
  if (raw is! Map) return null;
  final json = raw is Map<String, dynamic> ? raw : raw.cast<String, dynamic>();
  final offsets = _tryContentSplitIntList(json['offsets']);
  final reasoningCounts = _tryContentSplitIntList(json['reasoningCounts']);
  final toolCounts = _tryContentSplitIntList(json['toolCounts']);
  if (!contentSplitsAreUsable(offsets, reasoningCounts, toolCounts)) {
    return null;
  }
  return (
    offsets: offsets!,
    reasoningCounts: reasoningCounts!,
    toolCounts: toolCounts!,
  );
}

List<int>? _tryContentSplitIntList(dynamic value) {
  if (value == null) return const <int>[];
  if (value is! List) return null;
  final out = <int>[];
  for (final item in value) {
    if (item is int) {
      out.add(item);
    } else if (item is num && item == item.roundToDouble()) {
      out.add(item.toInt());
    } else {
      return null;
    }
  }
  return out;
}

/// 结构上合法的切分三元组是否真正覆盖了整条时间线。
///
/// 偏移量必须落在 [contentLength] 以内，每个目标计数对必须
/// 按序出现在渲染出的步骤上，且最后一个目标必须消费
/// 所有步骤。否则覆盖不完整时，会在尾部正文之后
/// 追加多余的推理/工具卡片。
bool contentSplitsMatchTimeline({
  required List<int> offsets,
  required List<int> reasoningCounts,
  required List<int> toolCounts,
  required int contentLength,
  required List<int> stepReasoningCounts,
  required List<int> stepToolCounts,
}) {
  if (!contentSplitsAreUsable(offsets, reasoningCounts, toolCounts)) {
    return false;
  }
  if (stepReasoningCounts.length != stepToolCounts.length ||
      stepReasoningCounts.isEmpty) {
    return false;
  }

  var stepIndex = 0;
  for (var i = 0; i < offsets.length; i++) {
    if (offsets[i] > contentLength) return false;
    final targetReasoning = reasoningCounts[i];
    final targetTool = toolCounts[i];
    var found = false;
    while (stepIndex < stepReasoningCounts.length) {
      final reasoningAfter = stepReasoningCounts[stepIndex];
      final toolAfter = stepToolCounts[stepIndex];
      stepIndex++;
      if (reasoningAfter == targetReasoning && toolAfter == targetTool) {
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return stepIndex == stepReasoningCounts.length;
}

/// 助手气泡应遍历 [parts] 还是 contentSplits。
///
/// 历史行保持扁平的 `[reasoning, tools…, body]` 布局，另存
/// 重建交错所需的切分三元组，这类走切分渲染器。
/// 新的流式消息按到达顺序持久化 [ReasoningPart] / [ToolCallPart]
///（以及生成的 [ImagePart]），没有切分。
bool renderAssistantFromParts({
  required List<MessagePart> parts,
  required bool hasContentSplits,
}) {
  if (hasContentSplits) return false;
  for (final part in parts) {
    if (part is ReasoningPart || part is ToolCallPart) return true;
  }
  return parts.any((part) => part is ImagePart);
}
