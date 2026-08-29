import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'message_part.dart';

part 'chat_message.g.dart';

@HiveType(typeId: 0)
class ChatMessage extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String role; // 'user' 或 'assistant'

  /// 结构化 parts —— 正文文本和附件的唯一事实来源。
  ///
  /// 此处有意不把 Hive 字段 2（旧版 content 字符串）存储为字段。
  /// [ChatMessageAdapter] 仍仅出于迁移目的读取字段 2；
  /// [content] 派生自 [TextPart]。
  final List<MessagePart> parts;

  /// 派生文本正文：按 [parts] 顺序连接每个 [TextPart]。
  String get content =>
      parts.whereType<TextPart>().map((part) => part.text).join();

  /// 用于构建提示词的消息语义指纹。
  ///
  /// 仅使用派生文本不够：附件、工具调用或未知 part 变化时，外显文本
  /// 可能保持不变。指纹包含 part 类型、载荷和顺序，确保任何与提示词
  /// 相关的消息数据变化都会使持久化提示词失效。
  String get semanticContentHash => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            for (final part in parts)
              {'kind': part.kind, 'payload': part.encodePayload()},
          ]),
        ),
      )
      .toString();

  @HiveField(3)
  final DateTime timestamp;

  @HiveField(4)
  final String? modelId;

  @HiveField(5)
  final String? providerId;

  @HiveField(6)
  final int? totalTokens;

  @HiveField(7)
  final String conversationId;

  @HiveField(8)
  final bool isStreaming;

  // 助手消息的可选推理字段
  @HiveField(9)
  final String? reasoningText;

  @HiveField(10)
  final DateTime? reasoningStartAt;

  @HiveField(11)
  final DateTime? reasoningFinishedAt;

  // 用于翻译内容的翻译字段
  @HiveField(12)
  final String? translation;

  // 用于多个推理块的 JSON 编码推理片段
  @HiveField(13)
  final String? reasoningSegmentsJson;

  // 版本控制：将共享同一语义位置的消息分组，
  // groupId 标识一个消息线程；version 从 0 开始递增
  @HiveField(14)
  final String? groupId;

  @HiveField(15)
  final int version;

  @HiveField(16)
  final int? promptTokens;

  @HiveField(17)
  final int? completionTokens;

  @HiveField(18)
  final int? cachedTokens;

  @HiveField(19)
  final int? durationMs;

  ChatMessage({
    String? id,
    required this.role,
    String? content,
    List<MessagePart>? parts,
    DateTime? timestamp,
    this.modelId,
    this.providerId,
    this.totalTokens,
    required this.conversationId,
    this.isStreaming = false,
    this.reasoningText,
    this.reasoningStartAt,
    this.reasoningFinishedAt,
    this.translation,
    this.reasoningSegmentsJson,
    String? groupId,
    int? version,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.durationMs,
  }) : parts = List<MessagePart>.unmodifiable(
         parts ?? <MessagePart>[TextPart(content ?? '')],
       ),
       id = id ?? const Uuid().v4(),
       timestamp = timestamp ?? DateTime.now(),
       groupId = groupId ?? id,
       version = version ?? 0;

  /// 仅重写内容的操作，保留 part 的序号。
  ///
  /// 按顺序遍历 [original]：在第一个 TextPart 位置发出带 [newContent] 的 [TextPart]，
  /// 跳过后续 TextPart，并将 Image/File/ToolCall/
  /// Reasoning/Unknown/Malformed part 保留在原位。如果没有 TextPart，
  /// 则在开头插入一个。
  static List<MessagePart> partsWithReplacedText(
    List<MessagePart> original,
    String newContent,
  ) {
    final next = <MessagePart>[];
    var replaced = false;
    for (final part in original) {
      if (part is TextPart) {
        if (!replaced) {
          next.add(TextPart(newContent));
          replaced = true;
        }
        continue;
      }
      next.add(part);
    }
    if (!replaced) {
      next.insert(0, TextPart(newContent));
    }
    return next;
  }

  ChatMessage copyWith({
    String? id,
    String? role,
    String? content,
    List<MessagePart>? parts,
    DateTime? timestamp,
    String? modelId,
    String? providerId,
    int? totalTokens,
    String? conversationId,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    String? groupId,
    int? version,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    final List<MessagePart>? nextParts;
    if (parts != null) {
      nextParts = parts;
    } else if (content != null) {
      // 展开步骤兼容：将派生文本重写为单个 TextPart，同时
      // 保留非 TextPart 附件及其序号。
      nextParts = partsWithReplacedText(this.parts, content);
    } else {
      nextParts = this.parts;
    }
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      parts: nextParts,
      timestamp: timestamp ?? this.timestamp,
      modelId: modelId ?? this.modelId,
      providerId: providerId ?? this.providerId,
      totalTokens: totalTokens ?? this.totalTokens,
      conversationId: conversationId ?? this.conversationId,
      isStreaming: isStreaming ?? this.isStreaming,
      reasoningText: reasoningText ?? this.reasoningText,
      reasoningStartAt: reasoningStartAt ?? this.reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt ?? this.reasoningFinishedAt,
      translation: translation ?? this.translation,
      reasoningSegmentsJson:
          reasoningSegmentsJson ?? this.reasoningSegmentsJson,
      groupId: groupId ?? this.groupId,
      version: version ?? this.version,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      cachedTokens: cachedTokens ?? this.cachedTokens,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role,
      // 供较旧读取器使用的派生文本；结构化附件位于 [parts] 中。
      'content': content,
      'parts': [
        for (final part in parts)
          {'kind': part.kind, 'payload': part.encodePayload()},
      ],
      'timestamp': timestamp.toIso8601String(),
      'modelId': modelId,
      'providerId': providerId,
      'totalTokens': totalTokens,
      'conversationId': conversationId,
      'isStreaming': isStreaming,
      'reasoningText': reasoningText,
      'reasoningStartAt': reasoningStartAt?.toIso8601String(),
      'reasoningFinishedAt': reasoningFinishedAt?.toIso8601String(),
      'translation': translation,
      'reasoningSegmentsJson': reasoningSegmentsJson,
      'groupId': groupId,
      'version': version,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'cachedTokens': cachedTokens,
      'durationMs': durationMs,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawParts = json['parts'];
    List<MessagePart>? parts;
    if (rawParts is List) {
      parts = <MessagePart>[];
      for (var ordinal = 0; ordinal < rawParts.length; ordinal++) {
        final entry = rawParts[ordinal];
        if (entry is! Map) continue;
        final kind = (entry['kind'] ?? '').toString();
        final payload = (entry['payload'] ?? '').toString();
        try {
          parts.add(MessagePart.fromRow(kind, payload));
        } on FormatException catch (error) {
          final parseError = messagePartParseErrorCategory(error);
          throw FormatException(
            'Invalid message part: messageId=${json['id']} '
            'ordinal=$ordinal kind=$kind parseError=$parseError',
          );
        }
      }
    }
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String,
      // 存在结构化 part 时优先使用它们。只携带
      // 含标记的 [content] 的旧备份会将字符串保留在此处；导入边界会运行
      // decodeLegacyContent，将标记提升为 part。
      content: parts == null ? json['content'] as String : null,
      parts: parts,
      timestamp: DateTime.parse(json['timestamp'] as String),
      modelId: json['modelId'] as String?,
      providerId: json['providerId'] as String?,
      totalTokens: json['totalTokens'] as int?,
      conversationId: json['conversationId'] as String,
      isStreaming: json['isStreaming'] as bool? ?? false,
      reasoningText: json['reasoningText'] as String?,
      reasoningStartAt: json['reasoningStartAt'] != null
          ? DateTime.parse(json['reasoningStartAt'] as String)
          : null,
      reasoningFinishedAt: json['reasoningFinishedAt'] != null
          ? DateTime.parse(json['reasoningFinishedAt'] as String)
          : null,
      translation: json['translation'] as String?,
      reasoningSegmentsJson: json['reasoningSegmentsJson'] as String?,
      groupId: json['groupId'] as String?,
      version: (json['version'] as int?) ?? 0,
      promptTokens: json['promptTokens'] as int?,
      completionTokens: json['completionTokens'] as int?,
      cachedTokens: json['cachedTokens'] as int?,
      durationMs: json['durationMs'] as int?,
    );
  }
}
