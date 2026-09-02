import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late ChatDatabaseRepository repository;
  late Conversation conversation;

  ChatMessage message({
    required String id,
    required String role,
    required String content,
    String? groupId,
    int version = 0,
    bool isStreaming = false,
  }) => ChatMessage(
    id: id,
    conversationId: conversation.id,
    role: role,
    content: content,
    groupId: groupId,
    version: version,
    isStreaming: isStreaming,
  );

  Future<void> seed({bool includeAlternate = false}) async {
    final messages = <ChatMessage>[
      message(id: 'user-0', role: 'user', content: 'question'),
      message(
        id: 'assistant-v0',
        role: 'assistant',
        content: 'answer v0',
        groupId: 'assistant-group',
      ),
      message(id: 'user-1', role: 'user', content: 'later question'),
      message(id: 'assistant-1', role: 'assistant', content: 'later answer'),
      if (includeAlternate)
        message(
          id: 'assistant-v1',
          role: 'assistant',
          content: 'answer v1',
          groupId: 'assistant-group',
          version: 1,
        ),
    ];
    await repository.putMigrationBatch(
      conversations: [
        conversation.copyWith(
          messageIds: messages.map((message) => message.id).toList(),
          versionSelections: includeAlternate
              ? const {'assistant-group': 1}
              : const {},
        ),
      ],
      messages: [
        for (final (index, item) in messages.indexed)
          (message: item, messageOrder: index),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  }

  Future<List<String>> activeIds() async =>
      (await repository.loadConversationTree(conversation.id))!.activePath();

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
    conversation = Conversation(id: 'conversation', title: 'Linear');
  });

  tearDown(() => repository.close());

  test(
    'save-only creates a sibling branch and preserves the original future',
    () async {
      await seed();

      final result = await repository.appendMessageVersion(
        messageId: 'assistant-v0',
        content: 'edited answer',
      );
      final tree = await repository.loadConversationTree(conversation.id);

      expect(result, isNotNull);
      expect(result!.message.groupId, isNull);
      expect(result.message.version, 0);
      expect(tree!.activePath(), ['user-0', result.message.id]);
      expect(
        tree.branches.values.map(
          (branch) => tree.branchPath(branch.id).join('|'),
        ),
        contains('user-0|assistant-v0|user-1|assistant-1'),
      );
      expect(await repository.getMessageIndex(conversation.id, 'user-1'), 2);
    },
  );

  test('cloning a message branch creates a visible sibling message', () async {
    await seed();

    final result = await repository.cloneMessageAsBranch(
      conversationId: conversation.id,
      messageId: 'user-0',
    );
    final clone = result!.message;
    final tree = await repository.loadConversationTree(conversation.id);

    expect(clone.id, isNot('user-0'));
    expect(clone.content, 'question');
    expect(tree!.activePath(), [clone.id]);
    final rootBranch = tree.branches.values.singleWhere(
      (branch) => branch.tipMessageId == 'assistant-1',
    );
    expect(tree.branchPath(rootBranch.id), [
      'user-0',
      'assistant-v0',
      'user-1',
      'assistant-1',
    ]);
    expect(tree.edges[clone.id]?.parentMessageId, isNull);
    expect(tree.siblingBranchIdsByMessageId()[clone.id], hasLength(2));
    expect(tree.siblingBranchIdsByMessageId()['user-0'], hasLength(2));
  });

  test('default assistant regeneration creates a sibling branch', () async {
    await seed();

    final result = await repository.beginRegeneration(
      conversation: conversation,
      assistantMessage: message(
        id: 'assistant-v1',
        role: 'assistant',
        content: '',
        groupId: 'assistant-group',
        version: 1,
        isStreaming: true,
      ),
      runId: 'run-default',
      truncateFuture: false,
    );
    final tree = await repository.loadConversationTree(conversation.id);

    expect(tree!.activePath(), ['user-0', 'assistant-v1']);
    expect(
      tree.branches.values.map(
        (branch) => tree.branchPath(branch.id).join('|'),
      ),
      contains('user-0|assistant-v0|user-1|assistant-1'),
    );
    expect(result.conversation.versionSelections, {'assistant-group': 1});
  });

  test('truncate regeneration is rejected by the tree model', () async {
    await seed();

    await expectLater(
      repository.beginRegeneration(
        conversation: conversation,
        assistantMessage: message(
          id: 'assistant-v1',
          role: 'assistant',
          content: '',
          groupId: 'assistant-group',
          version: 1,
          isStreaming: true,
        ),
        runId: 'run-truncate',
        truncateFuture: true,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'tree_regeneration_cannot_truncate_future',
        ),
      ),
    );

    expect(await activeIds(), [
      'user-0',
      'assistant-v0',
      'user-1',
      'assistant-1',
    ]);
    expect(await repository.getMessage('assistant-v0'), isNotNull);
    expect(await repository.getMessage('assistant-v1'), isNull);
  });

  test(
    'truncate regeneration leaves an existing edited branch unchanged',
    () async {
      await seed();
      final editedUser = await repository.appendMessageVersion(
        messageId: 'user-0',
        content: 'edited question',
      );

      await expectLater(
        repository.beginRegeneration(
          conversation: editedUser!.conversation,
          assistantMessage: message(
            id: 'assistant-v1',
            role: 'assistant',
            content: '',
            groupId: 'assistant-group',
            version: 1,
            isStreaming: true,
          ),
          runId: 'run-truncate-after-edit',
          truncateFuture: true,
        ),
        throwsStateError,
      );

      expect(await activeIds(), [editedUser.message.id]);
      expect(await repository.getMessage(editedUser.message.id), isNotNull);
      expect(await repository.getMessage('assistant-v1'), isNull);
    },
  );

  test(
    'repository selection metadata does not silently switch the tree',
    () async {
      await seed(includeAlternate: true);

      await repository.setSelectedVersion(
        conversationId: conversation.id,
        groupId: 'assistant-group',
        version: 0,
      );

      expect(await activeIds(), [
        'user-0',
        'assistant-v1',
        'user-1',
        'assistant-1',
      ]);
      expect(
        (await repository.getConversation(conversation.id))?.versionSelections,
        {'assistant-group': 0},
      );
      expect(await repository.getMessageIndex(conversation.id, 'user-1'), 2);
    },
  );

  test(
    'deleting a branch deletes its descendants and preserves its sibling',
    () async {
      await seed(includeAlternate: true);

      await repository.deleteMessages(
        conversationId: conversation.id,
        messageIds: const {'assistant-v1'},
        versionSelectionChanges: const {},
      );
      expect(await activeIds(), ['user-0', 'assistant-v0']);
      expect(
        (await repository.getConversation(conversation.id))?.versionSelections,
        {'assistant-group': 0},
      );

      await repository.deleteMessages(
        conversationId: conversation.id,
        messageIds: const {'assistant-v0'},
        versionSelectionChanges: const {},
      );
      expect(await activeIds(), ['user-0']);
      expect(await repository.getMessage('user-1'), isNull);
    },
  );

  test('deleting an old branch keeps the edited sibling active', () async {
    await seed();

    // Save-only edit: appends a new revision whose message_order lands at
    // the end of the conversation.
    final result = await repository.appendMessageVersion(
      messageId: 'assistant-v0',
      content: 'edited answer',
    );
    final editedId = result!.message.id;

    // Deleting the original (anchor) revision must not let the surviving
    // revision drift to the appended end-of-conversation position.
    await repository.deleteMessages(
      conversationId: conversation.id,
      messageIds: const {'assistant-v0'},
      versionSelectionChanges: const {},
    );

    expect(await activeIds(), ['user-0', editedId]);
    expect(await repository.getMessageIds(conversation.id), [
      'user-0',
      editedId,
    ]);
  });
}
