import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/features/home/controllers/chat_actions.dart';

ChatMessage _message({
  required String id,
  required String role,
  required String groupId,
  required int version,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: '$role-$id',
    conversationId: 'conversation-1',
    groupId: groupId,
    version: version,
  );
}

void main() {
  test('unlimited context reads the complete persisted conversation', () {
    expect(
      ChatActions.contextReadLimit(
        assistant: const Assistant(
          id: 'assistant-1',
          name: 'Unlimited',
          limitContextMessages: false,
        ),
        persistedMessageCount: 1507,
      ),
      1507,
    );
    expect(
      ChatActions.contextReadLimit(
        assistant: const Assistant(
          id: 'assistant-1',
          name: 'Limited',
          contextMessageSize: 64,
          limitContextMessages: true,
        ),
        persistedMessageCount: 1507,
      ),
      64,
    );
    // Default assistants leave context unlimited (D-30 / 5d42eebc).
    expect(
      ChatActions.contextReadLimit(
        assistant: const Assistant(
          id: 'assistant-1',
          name: 'Default unlimited',
          contextMessageSize: 64,
        ),
        persistedMessageCount: 1507,
      ),
      1507,
    );
    expect(
      ChatActions.contextReadLimit(
        assistant: const Assistant(
          id: 'assistant-1',
          name: 'Unlimited with missing count',
          limitContextMessages: false,
        ),
        persistedMessageCount: 0,
      ),
      Assistant.maxContextMessageSize,
    );
  });

  test('unknown sentinel must not be passed into contextReadLimit', () {
    expect(
      () => ChatActions.contextReadLimit(
        assistant: const Assistant(
          id: 'assistant-1',
          name: 'Unlimited',
          limitContextMessages: false,
        ),
        persistedMessageCount: -1,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test(
    'resolveContextReadLimit awaits real count for unlimited assistants',
    () async {
      var resolveCalls = 0;
      final limit = await ChatActions.resolveContextReadLimit(
        assistant: const Assistant(
          id: 'assistant-1',
          name: 'Unlimited',
          limitContextMessages: false,
        ),
        resolvePersistedCount: () async {
          resolveCalls += 1;
          return 1507;
        },
      );
      expect(limit, 1507);
      expect(resolveCalls, 1);
      expect(limit, isNot(Assistant.maxContextMessageSize));
    },
  );

  test(
    'resolveContextReadLimit skips count lookup when context is limited',
    () async {
      var resolveCalls = 0;
      final limit = await ChatActions.resolveContextReadLimit(
        assistant: const Assistant(
          id: 'assistant-1',
          name: 'Limited',
          contextMessageSize: 64,
          limitContextMessages: true,
        ),
        resolvePersistedCount: () async {
          resolveCalls += 1;
          return 1507;
        },
      );
      expect(limit, 64);
      expect(resolveCalls, 0);
    },
  );

  test('send/regenerate/continue paths await context limit resolution', () {
    final source = File(
      'lib/features/home/controllers/chat_actions.dart',
    ).readAsStringSync();
    final runSendGeneration = RegExp(
      r'Future<void> _runSendGeneration[\s\S]*?'
      r'final contextLimit = await _contextReadLimit\(assistant, conversation\);',
    );
    final regenerate = RegExp(
      r'Future<ChatActionResult> _regenerateAtMessageClaimed[\s\S]*?'
      r'maxMessages: await _contextReadLimit\(assistant, conversation\),',
    );
    final continueAfterToolAnswer = RegExp(
      r'Future<ChatActionResult> continueAssistantMessageAfterToolAnswer[\s\S]*?'
      r'maxMessages: await _contextReadLimit\(assistant, conversation\),',
    );
    expect(
      runSendGeneration.hasMatch(source),
      isTrue,
      reason:
          'send must await the resolved context limit before reading history',
    );
    expect(
      regenerate.hasMatch(source),
      isTrue,
      reason: 'regenerate must await the resolved context limit',
    );
    expect(
      continueAfterToolAnswer.hasMatch(source),
      isTrue,
      reason: 'continue must await the resolved context limit',
    );
    expect(source.contains('maxMessages: _contextReadLimit('), isFalse);
  });

  group('ChatActions.conversationForMessageContext', () {
    test('投影历史短于持久化截断点时不截空重试上下文', () {
      final messages = <ChatMessage>[
        for (var i = 0; i < 20; i++)
          _message(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            groupId: 'm$i',
            version: 0,
          ),
      ];

      final conversation = ChatActions.conversationForMessageContext(
        conversation: Conversation(
          id: 'conversation-1',
          title: 'Long chat',
          truncateIndex: 50,
        ),
        messages: messages,
      );

      expect(conversation.truncateIndex, -1);
    });

    test('重试目标之前的上下文不使用未来截断点', () {
      final messages = <ChatMessage>[
        for (var i = 0; i < 60; i++)
          _message(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            groupId: 'm$i',
            version: 0,
          ),
      ];

      final conversation = ChatActions.conversationForMessageContext(
        conversation: Conversation(
          id: 'conversation-1',
          title: 'Long chat',
          truncateIndex: 50,
        ),
        messages: messages,
        maxRawTruncateIndex: 40,
      );

      expect(conversation.truncateIndex, -1);
    });

    test('完整历史上下文保留持久化截断点', () {
      final messages = <ChatMessage>[
        for (var i = 0; i < 80; i++)
          _message(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            groupId: 'm$i',
            version: 0,
          ),
      ];

      final conversation = ChatActions.conversationForMessageContext(
        conversation: Conversation(
          id: 'conversation-1',
          title: 'Long chat',
          truncateIndex: 50,
        ),
        messages: messages,
      );

      expect(conversation.truncateIndex, 50);
    });
  });
}
