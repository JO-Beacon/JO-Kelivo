import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/controllers/chat_controller.dart';

class _FakeLazyChatService extends ChatService {
  _FakeLazyChatService(this._messages, {this.allowFullLoad = false});

  final List<ChatMessage> _messages;
  final bool allowFullLoad;
  int fullLoadCalls = 0;
  int recentLoadCalls = 0;
  int rangeLoadCalls = 0;

  @override
  List<ChatMessage> getMessages(String conversationId) {
    fullLoadCalls++;
    if (!allowFullLoad) {
      throw StateError('full message load should not run on conversation open');
    }
    return List<ChatMessage>.of(_messages);
  }

  @override
  int getMessageCount(String conversationId) => _messages.length;

  @override
  int getMessageIndex(String conversationId, String messageId) {
    return _messages.indexWhere((message) => message.id == messageId);
  }

  @override
  List<ChatMessage> getRecentMessages(
    String conversationId, {
    int minMessages = 20,
    int textBudget = 20000,
    int maxMessages = 240,
  }) {
    recentLoadCalls++;
    const tailWindowSize = 20;
    final count = tailWindowSize > _messages.length
        ? _messages.length
        : tailWindowSize;
    return _messages.sublist(_messages.length - count);
  }

  @override
  List<ChatMessage> getMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) {
    rangeLoadCalls++;
    final end = (start + limit).clamp(0, _messages.length);
    return _messages.sublist(start, end);
  }

  @override
  Map<String, int> getVersionSelections(String conversationId) {
    if (_messages.any((message) => message.id == 'message-10-edit')) {
      return const <String, int>{'message-10': 1};
    }
    return const <String, int>{};
  }

  ChatMessage appendPersistedMessage(ChatMessage message) {
    _messages.add(message);
    return message;
  }

  @override
  Future<void> updateMessage(
    String messageId, {
    String? role,
    String? content,
    int? totalTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) async {
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index == -1) {
      throw StateError('message not found: $messageId');
    }

    final message = _messages[index];
    _messages[index] = message.copyWith(
      role: role ?? message.role,
      content: content ?? message.content,
      totalTokens: totalTokens ?? message.totalTokens,
      isStreaming: isStreaming ?? message.isStreaming,
      reasoningText: reasoningText ?? message.reasoningText,
      reasoningStartAt: reasoningStartAt ?? message.reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt ?? message.reasoningFinishedAt,
      translation: translation,
      reasoningSegmentsJson:
          reasoningSegmentsJson ?? message.reasoningSegmentsJson,
      promptTokens: promptTokens ?? message.promptTokens,
      completionTokens: completionTokens ?? message.completionTokens,
      cachedTokens: cachedTokens ?? message.cachedTokens,
      durationMs: durationMs ?? message.durationMs,
    );
  }

  @override
  Future<Conversation> createDraftConversation({
    String? title,
    String? assistantId,
    bool temporary = false,
  }) async {
    return Conversation(title: title ?? 'Draft', assistantId: assistantId);
  }
}

ChatMessage _message(int index) {
  return ChatMessage(
    id: 'message-$index',
    role: index.isEven ? 'user' : 'assistant',
    content: 'message $index',
    conversationId: 'conversation-1',
  );
}

ChatMessage _versionedMessage({
  required String id,
  required String groupId,
  required int version,
  required String content,
}) {
  return ChatMessage(
    id: id,
    role: 'user',
    content: content,
    conversationId: 'conversation-1',
    groupId: groupId,
    version: version,
  );
}

void main() {
  group('ChatController lazy history', () {
    late List<ChatMessage> messages;
    late Conversation conversation;
    late _FakeLazyChatService chatService;
    late ChatController controller;

    setUp(() {
      messages = List<ChatMessage>.generate(100, _message);
      conversation = Conversation(
        id: 'conversation-1',
        title: 'Long chat',
        messageIds: messages.map((message) => message.id).toList(),
      );
      chatService = _FakeLazyChatService(messages);
      controller = ChatController(chatService: chatService);
    });

    tearDown(() {
      controller.dispose();
    });

    test('opening a conversation loads only the tail window', () {
      controller.setCurrentConversation(conversation);

      expect(chatService.fullLoadCalls, 0);
      expect(chatService.recentLoadCalls, 1);
      expect(controller.messages, messages.sublist(80));
      expect(controller.loadedStartIndex, 80);
      expect(controller.totalMessageCount, 100);
      expect(controller.hasMoreBefore, isTrue);
    });

    test(
      'opening a conversation loads all messages when lazy history is disabled',
      () {
        chatService = _FakeLazyChatService(messages, allowFullLoad: true);
        controller.dispose();
        controller = ChatController(
          chatService: chatService,
          lazyHistoryEnabled: () => false,
        );

        controller.setCurrentConversation(conversation);

        expect(chatService.fullLoadCalls, 1);
        expect(chatService.recentLoadCalls, 0);
        expect(controller.messages, messages);
        expect(controller.loadedStartIndex, 0);
        expect(controller.totalMessageCount, 100);
        expect(controller.hasMoreBefore, isFalse);
        expect(controller.hasMoreAfter, isFalse);
        expect(controller.loadMoreBefore(), isFalse);
        expect(controller.loadMoreAfter(), isFalse);
      },
    );

    test(
      'reloading after deletion keeps full history when lazy history is disabled',
      () {
        chatService = _FakeLazyChatService(messages, allowFullLoad: true);
        controller.dispose();
        controller = ChatController(
          chatService: chatService,
          lazyHistoryEnabled: () => false,
        );
        controller.setCurrentConversation(conversation);
        messages.removeRange(77, 80);

        controller.reloadMessages();

        expect(controller.messages, messages);
        expect(controller.messages.length, 97);
        expect(controller.messages.last.id, 'message-99');
        expect(controller.loadedStartIndex, 0);
        expect(controller.totalMessageCount, 97);
        expect(controller.hasMoreAfter, isFalse);
      },
    );

    test(
      'reloading after deletion keeps bounded window when lazy history is enabled',
      () {
        controller.setCurrentConversation(conversation);
        messages.removeRange(77, 80);

        controller.reloadMessages();

        expect(controller.messages.length, 20);
        expect(controller.messages.first.id, 'message-80');
        expect(controller.messages.last.id, 'message-99');
        expect(controller.loadedStartIndex, 77);
        expect(controller.totalMessageCount, 97);
        expect(controller.hasMoreBefore, isTrue);
        expect(controller.hasMoreAfter, isFalse);
        expect(chatService.fullLoadCalls, 0);
      },
    );

    test(
      'updating message role persists through service and syncs loaded list',
      () async {
        controller.setCurrentConversation(conversation);
        final message = controller.messages.first;

        await controller.updateMessage(message.id, role: 'assistant');

        expect(messages[80].role, 'assistant');
        expect(controller.messages.first.role, 'assistant');
        expect(controller.messages.first.content, message.content);
      },
    );

    test('opening a 5000-message conversation keeps only the tail window', () {
      messages = List<ChatMessage>.generate(5000, _message);
      conversation = Conversation(
        id: 'conversation-1',
        title: 'Very long chat',
        messageIds: messages.map((message) => message.id).toList(),
      );
      chatService = _FakeLazyChatService(messages);
      controller.dispose();
      controller = ChatController(chatService: chatService);

      controller.setCurrentConversation(conversation);

      expect(chatService.fullLoadCalls, 0);
      expect(chatService.recentLoadCalls, 1);
      expect(controller.messages.length, 20);
      expect(controller.messages.first.id, 'message-4980');
      expect(controller.messages.last.id, 'message-4999');
      expect(controller.loadedStartIndex, 4980);
      expect(controller.totalMessageCount, 5000);
      expect(controller.hasMoreBefore, isTrue);
    });

    test(
      'loading older history prepends one page before the visible window',
      () {
        controller.setCurrentConversation(conversation);

        final loaded = controller.loadMoreBefore();

        expect(loaded, isTrue);
        expect(chatService.rangeLoadCalls, 1);
        expect(controller.messages, messages.sublist(60));
        expect(controller.loadedStartIndex, 60);
        expect(controller.hasMoreBefore, isTrue);
      },
    );

    test('loading older history keeps the visible window bounded', () {
      messages = List<ChatMessage>.generate(5000, _message);
      conversation = Conversation(
        id: 'conversation-1',
        title: 'Very long chat',
        messageIds: messages.map((message) => message.id).toList(),
      );
      chatService = _FakeLazyChatService(messages);
      controller.dispose();
      controller = ChatController(chatService: chatService);
      controller.setCurrentConversation(conversation);

      for (var i = 0; i < 30; i++) {
        expect(controller.loadMoreBefore(), isTrue);
      }

      expect(controller.messages.length, ChatService.defaultLoadedWindowMax);
      expect(controller.messages.first.id, 'message-4380');
      expect(controller.messages.last.id, 'message-4739');
      expect(controller.loadedStartIndex, 4380);
      expect(controller.hasMoreBefore, isTrue);
      expect(controller.hasMoreAfter, isTrue);
    });

    test('loading older history stops at the beginning', () {
      controller.setCurrentConversation(conversation);

      controller.loadMoreBefore(limit: 80);
      final loadedAgain = controller.loadMoreBefore();

      expect(loadedAgain, isFalse);
      expect(controller.messages, messages);
      expect(controller.loadedStartIndex, 0);
      expect(controller.hasMoreBefore, isFalse);
    });

    test('loading until a message is visible supports direct navigation', () {
      controller.setCurrentConversation(conversation);

      final visible = controller.loadUntilMessageVisible('message-10');

      expect(visible, isTrue);
      expect(controller.messages.first, messages[0]);
      expect(controller.messages, contains(messages[10]));
      expect(controller.loadedStartIndex, 0);
      expect(controller.hasMoreBefore, isFalse);
    });

    test('direct navigation loads a bounded target window', () {
      messages = List<ChatMessage>.generate(5000, _message);
      conversation = Conversation(
        id: 'conversation-1',
        title: 'Very long chat',
        messageIds: messages.map((message) => message.id).toList(),
      );
      chatService = _FakeLazyChatService(messages);
      controller.dispose();
      controller = ChatController(chatService: chatService);
      controller.setCurrentConversation(conversation);

      final visible = controller.loadUntilMessageVisible('message-2500');

      expect(visible, isTrue);
      expect(chatService.rangeLoadCalls, 1);
      expect(controller.messages.length, ChatService.defaultLoadedWindowMax);
      expect(controller.messages.first.id, 'message-2480');
      expect(controller.messages.last.id, 'message-2839');
      expect(
        controller.messages.any((message) => message.id == 'message-2500'),
        isTrue,
      );
      expect(controller.loadedStartIndex, 2480);
      expect(controller.hasMoreBefore, isTrue);
      expect(controller.hasMoreAfter, isTrue);
    });

    test('loading newer history moves the bounded window forward', () {
      messages = List<ChatMessage>.generate(5000, _message);
      conversation = Conversation(
        id: 'conversation-1',
        title: 'Very long chat',
        messageIds: messages.map((message) => message.id).toList(),
      );
      chatService = _FakeLazyChatService(messages);
      controller.dispose();
      controller = ChatController(chatService: chatService);
      controller.setCurrentConversation(conversation);
      controller.loadUntilMessageVisible('message-2500');

      final loaded = controller.loadMoreAfter();

      expect(loaded, isTrue);
      expect(controller.messages.length, ChatService.defaultLoadedWindowMax);
      expect(controller.messages.first.id, 'message-2500');
      expect(controller.messages.last.id, 'message-2859');
      expect(controller.loadedStartIndex, 2500);
      expect(controller.hasMoreBefore, isTrue);
      expect(controller.hasMoreAfter, isTrue);
    });

    test(
      'appending a persisted tail message from a middle window loads the tail',
      () {
        messages = List<ChatMessage>.generate(5000, _message);
        conversation = Conversation(
          id: 'conversation-1',
          title: 'Very long chat',
          messageIds: messages.map((message) => message.id).toList(),
        );
        chatService = _FakeLazyChatService(messages);
        controller.dispose();
        controller = ChatController(chatService: chatService);
        controller.setCurrentConversation(conversation);
        controller.loadUntilMessageVisible('message-2500');

        final appended = chatService.appendPersistedMessage(_message(5000));
        controller.appendPersistedTailMessage(appended);

        expect(controller.messages.length, ChatService.defaultLoadedWindowMax);
        expect(controller.messages.first.id, 'message-4641');
        expect(controller.messages.last.id, 'message-5000');
        expect(controller.loadedStartIndex, 4641);
        expect(controller.totalMessageCount, 5001);
        expect(controller.hasMoreAfter, isFalse);
      },
    );

    test('appending a persisted tail message trims a full tail window', () {
      messages = List<ChatMessage>.generate(5000, _message);
      conversation = Conversation(
        id: 'conversation-1',
        title: 'Very long chat',
        messageIds: messages.map((message) => message.id).toList(),
      );
      chatService = _FakeLazyChatService(messages);
      controller.dispose();
      controller = ChatController(chatService: chatService);
      controller.setCurrentConversation(conversation);
      controller.loadEndWindow();

      final appended = chatService.appendPersistedMessage(_message(5000));
      controller.appendPersistedTailMessage(appended);

      expect(controller.messages.length, ChatService.defaultLoadedWindowMax);
      expect(controller.messages.first.id, 'message-4641');
      expect(controller.messages.last.id, 'message-5000');
      expect(controller.loadedStartIndex, 4641);
      expect(controller.totalMessageCount, 5001);
      expect(controller.hasMoreAfter, isFalse);
    });

    test(
      'tail window does not render a stale edited version without its group anchor',
      () {
        messages = List<ChatMessage>.generate(100, _message);
        messages.add(
          _versionedMessage(
            id: 'message-10-edit',
            groupId: 'message-10',
            version: 1,
            content: 'edited message 10',
          ),
        );
        conversation = Conversation(
          id: 'conversation-1',
          title: 'Long chat with versions',
          messageIds: messages.map((message) => message.id).toList(),
          versionSelections: const {'message-10': 1},
        );
        chatService = _FakeLazyChatService(messages);
        controller.dispose();
        controller = ChatController(chatService: chatService);

        controller.setCurrentConversation(conversation);

        final collapsed = controller.collapsedMessages;
        expect(
          collapsed.any((message) => message.id == 'message-10-edit'),
          isFalse,
        );
        expect(collapsed.first.id, 'message-81');
        expect(collapsed.last.id, 'message-99');
        expect(controller.messages.last.id, 'message-10-edit');
      },
    );

    test(
      'complete collapsed history keeps selected edited version at original group position',
      () {
        messages = List<ChatMessage>.generate(100, _message);
        messages.add(
          _versionedMessage(
            id: 'message-10-edit',
            groupId: 'message-10',
            version: 1,
            content: 'edited message 10',
          ),
        );
        conversation = Conversation(
          id: 'conversation-1',
          title: 'Long chat with versions',
          messageIds: messages.map((message) => message.id).toList(),
          versionSelections: const {'message-10': 1},
        );
        chatService = _FakeLazyChatService(messages);
        controller.dispose();
        controller = ChatController(chatService: chatService);
        controller.setCurrentConversation(conversation);

        final collapsed = controller
            .allCollapsedMessagesForCurrentConversation();

        expect(collapsed.length, 100);
        expect(collapsed[9].id, 'message-9');
        expect(collapsed[10].id, 'message-10-edit');
        expect(collapsed[11].id, 'message-11');
        expect(collapsed.last.id, 'message-99');
      },
    );

    test(
      'mini map source includes all messages without expanding chat window',
      () {
        messages = List<ChatMessage>.generate(5000, _message);
        conversation = Conversation(
          id: 'conversation-1',
          title: 'Very long chat',
          messageIds: messages.map((message) => message.id).toList(),
        );
        chatService = _FakeLazyChatService(messages);
        controller.dispose();
        controller = ChatController(chatService: chatService);
        controller.setCurrentConversation(conversation);

        final miniMapMessages = controller
            .allCollapsedMessagesForCurrentConversation();

        expect(miniMapMessages.length, 5000);
        expect(miniMapMessages.first.id, 'message-0');
        expect(miniMapMessages.last.id, 'message-4999');
        expect(controller.messages.length, 20);
        expect(controller.loadedStartIndex, 4980);
        expect(chatService.fullLoadCalls, 0);
      },
    );

    test('maps persisted truncate index into the loaded tail window', () {
      final truncatedConversation = conversation.copyWith(truncateIndex: 90);
      controller.setCurrentConversation(truncatedConversation);

      expect(controller.loadedWindowTruncateIndex(), 10);
      expect(
        controller
            .conversationForLoadedWindow(truncatedConversation)
            .truncateIndex,
        10,
      );
    });

    test(
      'model context source keeps complete history and persisted truncate index',
      () {
        final truncatedConversation = conversation.copyWith(truncateIndex: 30);
        controller.setCurrentConversation(truncatedConversation);

        final contextMessages = controller
            .allMessagesForCurrentConversationContext();
        final contextConversation = controller
            .conversationForCompleteHistoryContext(truncatedConversation);

        expect(contextMessages, messages);
        expect(contextConversation.truncateIndex, 30);
        expect(controller.messages, messages.sublist(80));
        expect(controller.loadedStartIndex, 80);
        expect(chatService.fullLoadCalls, 0);
      },
    );

    test(
      'creating a draft conversation clears the loaded history window',
      () async {
        controller.setCurrentConversation(conversation);

        final draft = await controller.createNewConversation(title: 'Draft');

        expect(draft.title, 'Draft');
        expect(controller.messages, isEmpty);
        expect(controller.loadedStartIndex, 0);
        expect(controller.totalMessageCount, 0);
        expect(controller.hasMoreBefore, isFalse);
      },
    );
  });
}
