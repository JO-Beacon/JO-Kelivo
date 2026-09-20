import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'conversation.g.dart';

@HiveType(typeId: 1)
class Conversation extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  final DateTime createdAt;

  @HiveField(3)
  DateTime updatedAt;

  @HiveField(4)
  final List<String> messageIds;

  @HiveField(5)
  bool isPinned;

  // 每个会话启用的 MCP 服务器（按服务器 id）
  @HiveField(6)
  List<String> mcpServerIds;

  // 所属助手 id；全局/默认时为 null
  @HiveField(7)
  String? assistantId;

  // 从此索引开始截断上下文（-1 表示不截断）
  @HiveField(8)
  int truncateIndex;

  // 每个消息组选定的版本（groupId -> 选定的版本索引）
  @HiveField(9)
  Map<String, int> versionSelections;

  // LLM 生成的会话摘要
  @HiveField(10)
  String? summary;

  // 上次生成摘要时的消息数量（以避免冗余更新）
  @HiveField(11)
  int lastSummarizedMessageCount;

  // 由 LLM 生成的针对最新助手回复的快捷追问建议。
  @HiveField(12)
  List<String> chatSuggestions;

  // 上次注入的记忆块的哈希；null 表示从未注入。
  @HiveField(13)
  String? injectedMemoryHash;

  // 后台记忆提取已处理的最高 message_order；-1 表示从未处理。
  @HiveField(14)
  int lastMemoryExtractedOrder;

  // 会话级模型覆盖；为空时继承助手模型，再继承全局默认模型。
  @HiveField(15)
  String? chatModelProvider;

  @HiveField(16)
  String? chatModelId;

  // 仅存于 Drift 的特性包（工作区绑定等）。不是 Hive 字段：旧版适配器
  // 必须保持冻结，且 Hive 源数据早于 extras。
  final Map<String, dynamic> extras;

  Conversation({
    String? id,
    required this.title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? messageIds,
    this.isPinned = false,
    List<String>? mcpServerIds,
    this.assistantId,
    int? truncateIndex,
    Map<String, int>? versionSelections,
    this.summary,
    int? lastSummarizedMessageCount,
    List<String>? chatSuggestions,
    this.injectedMemoryHash,
    int? lastMemoryExtractedOrder,
    this.chatModelProvider,
    this.chatModelId,
    this.extras = const <String, dynamic>{},
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       messageIds = messageIds ?? [],
       mcpServerIds = mcpServerIds ?? [],
       truncateIndex = truncateIndex ?? -1,
       versionSelections = versionSelections ?? <String, int>{},
       lastSummarizedMessageCount = lastSummarizedMessageCount ?? 0,
       chatSuggestions = chatSuggestions ?? [],
       lastMemoryExtractedOrder = lastMemoryExtractedOrder ?? -1;

  Conversation copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? messageIds,
    bool? isPinned,
    List<String>? mcpServerIds,
    String? assistantId,
    int? truncateIndex,
    Map<String, int>? versionSelections,
    String? summary,
    int? lastSummarizedMessageCount,
    List<String>? chatSuggestions,
    String? injectedMemoryHash,
    int? lastMemoryExtractedOrder,
    String? chatModelProvider,
    String? chatModelId,
    Map<String, dynamic>? extras,
    bool clearSummary = false,
    bool clearInjectedMemoryHash = false,
    bool clearChatModel = false,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageIds: messageIds ?? this.messageIds,
      isPinned: isPinned ?? this.isPinned,
      mcpServerIds: mcpServerIds ?? this.mcpServerIds,
      assistantId: assistantId ?? this.assistantId,
      truncateIndex: truncateIndex ?? this.truncateIndex,
      versionSelections: versionSelections ?? this.versionSelections,
      summary: clearSummary ? null : (summary ?? this.summary),
      lastSummarizedMessageCount:
          lastSummarizedMessageCount ?? this.lastSummarizedMessageCount,
      chatSuggestions: chatSuggestions ?? this.chatSuggestions,
      injectedMemoryHash: clearInjectedMemoryHash
          ? null
          : (injectedMemoryHash ?? this.injectedMemoryHash),
      lastMemoryExtractedOrder:
          lastMemoryExtractedOrder ?? this.lastMemoryExtractedOrder,
      chatModelProvider: clearChatModel
          ? null
          : (chatModelProvider ?? this.chatModelProvider),
      chatModelId: clearChatModel ? null : (chatModelId ?? this.chatModelId),
      extras: extras ?? this.extras,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'messageIds': messageIds,
      'isPinned': isPinned,
      'mcpServerIds': mcpServerIds,
      'assistantId': assistantId,
      'truncateIndex': truncateIndex,
      'versionSelections': versionSelections,
      'summary': summary,
      'lastSummarizedMessageCount': lastSummarizedMessageCount,
      'chatSuggestions': chatSuggestions,
      'injectedMemoryHash': injectedMemoryHash,
      'lastMemoryExtractedOrder': lastMemoryExtractedOrder,
      'chatModelProvider': chatModelProvider,
      'chatModelId': chatModelId,
      'extras': extras,
    };
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      messageIds: (json['messageIds'] as List<dynamic>).cast<String>(),
      isPinned: json['isPinned'] as bool? ?? false,
      mcpServerIds:
          (json['mcpServerIds'] as List?)?.cast<String>() ?? const <String>[],
      assistantId: json['assistantId'] as String?,
      truncateIndex: json['truncateIndex'] as int? ?? -1,
      versionSelections:
          (json['versionSelections'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), (v as num).toInt()),
          ) ??
          <String, int>{},
      summary: json['summary'] as String?,
      lastSummarizedMessageCount:
          json['lastSummarizedMessageCount'] as int? ?? 0,
      chatSuggestions:
          (json['chatSuggestions'] as List?)?.cast<String>() ??
          const <String>[],
      injectedMemoryHash: json['injectedMemoryHash'] as String?,
      lastMemoryExtractedOrder: json['lastMemoryExtractedOrder'] as int? ?? -1,
      chatModelProvider: json['chatModelProvider'] as String?,
      chatModelId: json['chatModelId'] as String?,
      extras: decodeExtras(json['extras']),
    );
  }

  /// 解析会话 extras：接受 JSON map、JSON 字符串或垃圾输入。
  /// 非法输入与 `'{}'` 一律解析为空 map。
  static Map<String, dynamic> decodeExtras(Object? raw) {
    if (raw == null) return const <String, dynamic>{};
    if (raw is String) {
      if (raw.isEmpty || raw == '{}') return const <String, dynamic>{};
      try {
        return decodeExtras(jsonDecode(raw));
      } catch (_) {
        return const <String, dynamic>{};
      }
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }
}
