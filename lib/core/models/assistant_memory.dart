class AssistantMemory {
  final int id; // 0 表示新建（不写入存储），>0 表示已持久化
  final String assistantId;
  final String content;

  const AssistantMemory({
    required this.id,
    required this.assistantId,
    required this.content,
  });

  AssistantMemory copyWith({int? id, String? assistantId, String? content}) =>
      AssistantMemory(
        id: id ?? this.id,
        assistantId: assistantId ?? this.assistantId,
        content: content ?? this.content,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'assistantId': assistantId,
    'content': content,
  };

  static AssistantMemory fromJson(Map<String, dynamic> json) => AssistantMemory(
    id: (json['id'] as num?)?.toInt() ?? 0,
    assistantId: (json['assistantId'] ?? '').toString(),
    content: (json['content'] ?? '').toString(),
  );
}
