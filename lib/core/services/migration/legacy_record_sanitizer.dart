import '../../models/chat_message.dart';
import '../../models/conversation.dart';

/// 对脏的旧版（1.1.17 / Hive 时代）记录做字段级修复，使其
/// 满足 SQLite CHECK 约束。由 Hive 转 SQLite 迁移
/// 和 chats.json 导入边界共享：二者都读取旧运行时写入的数据，
/// 旧运行时容忍新 schema 拒绝的形态（设备时钟回拨可能持久化负时长，
/// 损坏记录可能携带空角色或越界计数器）。
///
/// 无需修复时原样（同一对象）返回输入，
/// 以便调用方通过 `identical(...)` 统计修复次数。
ChatMessage sanitizeLegacyMessageFields(ChatMessage message) {
  var changed = false;
  int? nonNegativeOrNull(int? value) {
    if (value != null && value < 0) {
      changed = true;
      return null;
    }
    return value;
  }

  // message_rows 强制 CHECK (role != '')。空角色只能来自损坏的
  // 旧版记录；默认置为 'user' 而非丢弃
  // 该消息。
  var role = message.role;
  if (role.isEmpty) {
    changed = true;
    role = 'user';
  }
  final totalTokens = nonNegativeOrNull(message.totalTokens);
  final promptTokens = nonNegativeOrNull(message.promptTokens);
  final completionTokens = nonNegativeOrNull(message.completionTokens);
  final cachedTokens = nonNegativeOrNull(message.cachedTokens);
  final durationMs = nonNegativeOrNull(message.durationMs);
  // 用钳制而非置 null：version 不可空，且供两个调用方在此之后运行的
  // (conversationId, groupId, version) 唯一性修复使用，
  // 该修复会解决钳制引入的任何冲突。
  var version = message.version;
  if (version < 0) {
    changed = true;
    version = 0;
  }
  var reasoningFinishedAt = message.reasoningFinishedAt;
  final reasoningStartAt = message.reasoningStartAt;
  if (reasoningFinishedAt != null &&
      reasoningStartAt != null &&
      reasoningFinishedAt.isBefore(reasoningStartAt)) {
    changed = true;
    reasoningFinishedAt = null;
  }
  if (!changed) return message;

  // copyWith 无法将字段清为 null，因此显式重建。
  return ChatMessage(
    id: message.id,
    role: role,
    parts: message.parts,
    timestamp: message.timestamp,
    modelId: message.modelId,
    providerId: message.providerId,
    totalTokens: totalTokens,
    conversationId: message.conversationId,
    isStreaming: message.isStreaming,
    reasoningText: message.reasoningText,
    reasoningStartAt: reasoningStartAt,
    reasoningFinishedAt: reasoningFinishedAt,
    translation: message.translation,
    reasoningSegmentsJson: message.reasoningSegmentsJson,
    groupId: message.groupId,
    version: version,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    cachedTokens: cachedTokens,
    durationMs: durationMs,
  );
}

/// 钳制旧版会话计数器，使其满足 conversation_rows
/// CHECK 约束（truncateIndex >= -1，lastSummarizedMessageCount >= 0，
/// lastMemoryExtractedOrder >= -1）。无需修复时原样
/// （同一对象）返回输入。
Conversation sanitizeLegacyConversationFields(Conversation conversation) {
  final truncateIndex = conversation.truncateIndex < -1
      ? -1
      : conversation.truncateIndex;
  final lastSummarizedMessageCount = conversation.lastSummarizedMessageCount < 0
      ? 0
      : conversation.lastSummarizedMessageCount;
  final lastMemoryExtractedOrder = conversation.lastMemoryExtractedOrder < -1
      ? -1
      : conversation.lastMemoryExtractedOrder;
  if (truncateIndex == conversation.truncateIndex &&
      lastSummarizedMessageCount == conversation.lastSummarizedMessageCount &&
      lastMemoryExtractedOrder == conversation.lastMemoryExtractedOrder) {
    return conversation;
  }
  return conversation.copyWith(
    truncateIndex: truncateIndex,
    lastSummarizedMessageCount: lastSummarizedMessageCount,
    lastMemoryExtractedOrder: lastMemoryExtractedOrder,
  );
}
