import '../../../core/models/chat_message.dart';

/// 让生成身份与当前加载的时间线保持独立。
class ActiveStreamingMessageStore {
  final Map<String, ChatMessage> _messagesByConversation =
      <String, ChatMessage>{};

  ChatMessage? operator [](String conversationId) {
    return _messagesByConversation[conversationId];
  }

  /// 当前是否任一会话存在进行中的助手消息。
  bool get isNotEmpty => _messagesByConversation.isNotEmpty;

  /// 仍在跑（或正在收尾）的助手消息 ID。
  Set<String> get messageIds => {
    for (final message in _messagesByConversation.values) message.id,
  };

  void put(ChatMessage message) {
    _messagesByConversation[message.conversationId] = message;
  }

  bool isActive(ChatMessage message) {
    return _messagesByConversation[message.conversationId]?.id == message.id;
  }

  ChatMessage? cancellationTarget(
    String conversationId,
    List<ChatMessage> loadedMessages,
  ) {
    final active = _messagesByConversation[conversationId];
    if (active != null) return active;
    for (var index = loadedMessages.length - 1; index >= 0; index--) {
      final message = loadedMessages[index];
      if (message.conversationId == conversationId &&
          message.role == 'assistant' &&
          message.isStreaming) {
        return message;
      }
    }
    return null;
  }

  void removeIfMatches(ChatMessage message) {
    if (_messagesByConversation[message.conversationId]?.id == message.id) {
      _messagesByConversation.remove(message.conversationId);
    }
  }
}
