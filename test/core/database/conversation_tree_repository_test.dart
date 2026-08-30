import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/models/conversation_tree.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'conversation tree persistence round-trips branches and edges',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();

      final createdAt = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
      await database.customStatement(
        'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
        'VALUES (?, ?, ?, ?);',
        ['conversation-1', 'tree', createdAt, createdAt],
      );

      final repository = ChatDatabaseRepository(database);
      final tree = ConversationTree.linear(
        conversationId: 'conversation-1',
        messageIds: const ['message-1', 'message-2'],
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await repository.saveConversationTree(tree);
      final loaded = await repository.loadConversationTree('conversation-1');

      expect(loaded, isA<ConversationTree>());
      expect(loaded!.activeBranchId, 'root');
      expect(loaded.activePath(), const ['message-1', 'message-2']);
      expect(loaded.fingerprint, tree.fingerprint);

      final branched = loaded.createBranch(
        branchId: 'branch-alt',
        fromMessageId: 'message-1',
        tipMessageId: 'message-2-alt',
        name: 'alt',
        createdAt: DateTime.utc(2026, 1, 2),
      );
      await repository.saveConversationTree(branched);

      final loadedBranch = await repository.loadConversationTree(
        'conversation-1',
      );
      expect(loadedBranch, isA<ConversationTree>());
      expect(loadedBranch!.activeBranchId, 'branch-alt');
      expect(loadedBranch.activePath(), const ['message-1', 'message-2-alt']);
      expect(loadedBranch.branchPath('root'), const ['message-1', 'message-2']);
      expect(loadedBranch.branches['branch-alt']?.name, 'alt');
      expect(loadedBranch.fingerprint, branched.fingerprint);
    },
  );

  test(
    'loadConversationTree returns null for an unknown conversation',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();

      final repository = ChatDatabaseRepository(database);
      expect(await repository.loadConversationTree('missing'), null);
    },
  );

  test('rejects an invalid tree before replacing persisted rows', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customSelect('SELECT 1;').getSingle();
    await database.customStatement(
      'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
      'VALUES (?, ?, ?, ?);',
      ['conversation-invalid', 'invalid', 1, 1],
    );

    final repository = ChatDatabaseRepository(database);
    final invalidTree = ConversationTree(
      conversationId: 'conversation-invalid',
      activeBranchId: 'root',
      branches: {
        'root': ConversationBranch(
          id: 'root',
          conversationId: 'conversation-invalid',
          tipMessageId: 'm1',
          createdAt: DateTime.utc(2026),
        ),
      },
      edges: const {
        'm1': MessageTreeEdge(messageId: 'm1', parentMessageId: null),
        'orphan': MessageTreeEdge(messageId: 'orphan', parentMessageId: null),
      },
    );

    await expectLater(
      repository.saveConversationTree(invalidTree),
      throwsA(isA<ConversationTreeIntegrityException>()),
    );
    final edgeRows = await database
        .customSelect(
          'SELECT message_id FROM message_tree_edge_rows '
          'WHERE conversation_id = ?;',
          variables: [Variable.withString('conversation-invalid')],
        )
        .get();
    expect(edgeRows, isEmpty);
  });

  test(
    'loading an invalid tree reports diagnostics without repairing it',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();
      await database.customStatement(
        'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
        'VALUES (?, ?, ?, ?);',
        ['conversation-invalid-load', 'invalid', 1, 1],
      );
      await database.customStatement(
        'INSERT INTO conversation_branch_rows '
        '(id, conversation_id, tip_message_id, name, created_at) '
        'VALUES (?, ?, ?, ?, ?);',
        ['root', 'conversation-invalid-load', 'm1', '', 1],
      );
      await database.customStatement(
        'INSERT INTO message_tree_edge_rows '
        '(conversation_id, message_id, parent_message_id) VALUES (?, ?, ?);',
        ['conversation-invalid-load', 'm1', null],
      );
      await database.customStatement(
        'INSERT INTO message_tree_edge_rows '
        '(conversation_id, message_id, parent_message_id) VALUES (?, ?, ?);',
        ['conversation-invalid-load', 'orphan', null],
      );
      await database.customStatement(
        'INSERT INTO conversation_tree_state_rows '
        '(conversation_id, active_branch_id, branch_selections_json) '
        'VALUES (?, ?, ?);',
        ['conversation-invalid-load', 'root', '{}'],
      );

      final repository = ChatDatabaseRepository(database);
      await expectLater(
        repository.loadConversationTree('conversation-invalid-load'),
        throwsA(
          isA<ConversationTreeIntegrityException>().having(
            (error) => error.issues.map((issue) => issue.code),
            'issue codes',
            contains('unreachable_edge'),
          ),
        ),
      );
      final persistedOrphan = await database
          .customSelect(
            'SELECT message_id FROM message_tree_edge_rows '
            'WHERE conversation_id = ? AND message_id = ?;',
            variables: [
              Variable.withString('conversation-invalid-load'),
              Variable.withString('orphan'),
            ],
          )
          .get();
      expect(persistedOrphan, hasLength(1));
    },
  );

  test('loading malformed branch selection JSON fails explicitly', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customSelect('SELECT 1;').getSingle();
    await database.customStatement(
      'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
      'VALUES (?, ?, ?, ?);',
      ['conversation-invalid-selection', 'invalid', 1, 1],
    );
    await database.customStatement(
      'INSERT INTO conversation_branch_rows '
      '(id, conversation_id, tip_message_id, name, created_at) '
      'VALUES (?, ?, ?, ?, ?);',
      ['root', 'conversation-invalid-selection', null, '', 1],
    );
    await database.customStatement(
      'INSERT INTO conversation_tree_state_rows '
      '(conversation_id, active_branch_id, branch_selections_json) '
      'VALUES (?, ?, ?);',
      ['conversation-invalid-selection', 'root', '{not-json'],
    );

    final repository = ChatDatabaseRepository(database);
    await expectLater(
      repository.loadConversationTree('conversation-invalid-selection'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          startsWith('conversation_tree_selections_invalid_json'),
        ),
      ),
    );
  });

  test(
    'migration batch preserves an explicitly supplied message tree',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();

      final repository = ChatDatabaseRepository(database);
      final conversation = Conversation(
        id: 'conversation-migration-tree',
        title: 'tree migration',
      );
      final messages = [
        ChatMessage(
          id: 'migration-user',
          role: 'user',
          content: 'question',
          conversationId: conversation.id,
        ),
        ChatMessage(
          id: 'migration-answer-old',
          role: 'assistant',
          content: 'old answer',
          conversationId: conversation.id,
        ),
        ChatMessage(
          id: 'migration-answer-new',
          role: 'assistant',
          content: 'new answer',
          conversationId: conversation.id,
        ),
      ];
      final tree =
          ConversationTree.linear(
            conversationId: conversation.id,
            messageIds: const ['migration-user', 'migration-answer-old'],
            createdAt: conversation.createdAt,
          ).createBranch(
            branchId: 'migration-new-answer',
            fromMessageId: 'migration-user',
            tipMessageId: 'migration-answer-new',
          );

      await repository.putMigrationBatch(
        conversations: [
          conversation.copyWith(
            messageIds: [for (final message in messages) message.id],
          ),
        ],
        messages: [
          for (final (index, message) in messages.indexed)
            (message: message, messageOrder: index),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
        conversationTree: tree,
      );

      final loaded = await repository.loadConversationTree(conversation.id);
      expect(loaded?.activeBranchId, 'migration-new-answer');
      expect(loaded?.activePath(), const [
        'migration-user',
        'migration-answer-new',
      ]);
      expect(loaded?.branchPath('root'), const [
        'migration-user',
        'migration-answer-old',
      ]);
    },
  );

  test('persists the last branch selected below a shared prefix', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customSelect('SELECT 1;').getSingle();

    final createdAt = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
    await database.customStatement(
      'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
      'VALUES (?, ?, ?, ?);',
      ['conversation-memory', 'tree', createdAt, createdAt],
    );

    final repository = ChatDatabaseRepository(database);
    var tree = ConversationTree.linear(
      conversationId: 'conversation-memory',
      messageIds: const ['root', 'shared'],
      createdAt: DateTime.utc(2026, 1, 1),
    );
    tree = tree
        .createMessageBranch(branchId: 'a1', fromMessageId: 'shared')
        .appendToActiveBranch('a1-tail');
    tree = tree
        .switchBranch('root')
        .createMessageBranch(branchId: 'a2', fromMessageId: 'shared')
        .appendToActiveBranch('a2-tail')
        .switchBranch('a1')
        .createMessageBranchFromParent(branchId: 'b', fromMessageId: null)
        .appendToActiveBranch('b-tail');

    await repository.saveConversationTree(tree);
    final loaded = await repository.loadConversationTree('conversation-memory');

    expect(loaded!.branchSelections['shared'], 'a1');
    expect(loaded.preferredBranchIdForMessage('shared'), 'a1');
  });

  test(
    'readAndClearContextTreeMigrationWarnings survives malformed metadata',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();
      await database.customStatement(
        'INSERT INTO chat_storage_meta_rows (key, value) VALUES (?, ?);',
        [AppDatabase.contextTreeMigrationWarningsKey, 'not-json'],
      );

      final repository = ChatDatabaseRepository(database);
      final warnings = await repository
          .readAndClearContextTreeMigrationWarnings();

      expect(warnings, hasLength(1));
      expect(warnings.single.conversationId, isEmpty);
      expect(warnings.single.groupId, isEmpty);
      expect(warnings.single.fallbackVersion, 0);
      final remaining = await database
          .customSelect(
            'SELECT 1 FROM chat_storage_meta_rows WHERE key = ?;',
            variables: [
              Variable.withString(AppDatabase.contextTreeMigrationWarningsKey),
            ],
          )
          .get();
      expect(remaining, isEmpty);
    },
  );

  test('deleting a linear parent removes its descendant subtree', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customSelect('SELECT 1;').getSingle();

    final createdAt = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
    await database.customStatement(
      'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
      'VALUES (?, ?, ?, ?);',
      ['conversation-sync', 'sync', createdAt, createdAt],
    );

    final repository = ChatDatabaseRepository(database);
    var conversation = await repository.getConversation('conversation-sync');
    expect(conversation, isA<Object>());

    conversation = await repository.appendLinearMessageToConversation(
      conversation: conversation!,
      message: ChatMessage(
        id: 'message-1',
        role: 'user',
        content: 'first',
        conversationId: 'conversation-sync',
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
      ),
    );
    conversation = await repository.appendLinearMessageToConversation(
      conversation: conversation,
      message: ChatMessage(
        id: 'message-2',
        role: 'assistant',
        content: 'second',
        conversationId: 'conversation-sync',
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, 2),
      ),
    );

    var tree = await repository.loadConversationTree('conversation-sync');
    expect(tree, isA<ConversationTree>());
    expect(tree!.activePath(), const ['message-1', 'message-2']);

    await repository.deleteMessage('message-1');
    tree = await repository.loadConversationTree('conversation-sync');
    expect(tree, isA<ConversationTree>());
    expect(tree!.activePath(), isEmpty);
    expect(await repository.getMessage('message-2'), null);
  });

  test(
    'deleting a branched message removes that branch and its descendants',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();

      final createdAt = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
      await database.customStatement(
        'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
        'VALUES (?, ?, ?, ?);',
        ['conversation-delete-branch', 'branch', createdAt, createdAt],
      );

      final repository = ChatDatabaseRepository(database);
      final conversation = Conversation(
        id: 'conversation-delete-branch',
        title: 'branch',
      );
      final messages = <({ChatMessage message, int messageOrder})>[
        (
          message: ChatMessage(
            id: 'u1',
            conversationId: conversation.id,
            role: 'user',
            content: 'question',
            timestamp: DateTime.utc(2026, 1, 1),
          ),
          messageOrder: 0,
        ),
        (
          message: ChatMessage(
            id: 'a1-v0',
            conversationId: conversation.id,
            role: 'assistant',
            content: 'old answer',
            groupId: 'assistant-group',
            version: 0,
            timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
          messageOrder: 1,
        ),
        (
          message: ChatMessage(
            id: 'a1-v1',
            conversationId: conversation.id,
            role: 'assistant',
            content: 'selected answer',
            groupId: 'assistant-group',
            version: 1,
            timestamp: DateTime.utc(2026, 1, 1, 0, 0, 2),
          ),
          messageOrder: 2,
        ),
        (
          message: ChatMessage(
            id: 'u2',
            conversationId: conversation.id,
            role: 'user',
            content: 'follow-up',
            timestamp: DateTime.utc(2026, 1, 1, 0, 0, 3),
          ),
          messageOrder: 3,
        ),
      ];
      await repository.putMigrationBatch(
        conversations: [
          conversation.copyWith(
            messageIds: messages
                .map((entry) => entry.message.id)
                .toList(growable: false),
            versionSelections: const {'assistant-group': 1},
          ),
        ],
        messages: messages,
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
      await repository.saveConversationTree(
        ConversationTree(
          conversationId: conversation.id,
          activeBranchId: 'root',
          branches: <String, ConversationBranch>{
            'root': ConversationBranch(
              id: 'root',
              conversationId: 'conversation-delete-branch',
              tipMessageId: 'u2',
              createdAt: DateTime(2026),
            ),
            'legacy-a1-v0': ConversationBranch(
              id: 'legacy-a1-v0',
              conversationId: 'conversation-delete-branch',
              tipMessageId: 'a1-v0',
              createdAt: DateTime(2026),
            ),
          },
          edges: const <String, MessageTreeEdge>{
            'u1': MessageTreeEdge(messageId: 'u1', parentMessageId: null),
            'a1-v0': MessageTreeEdge(messageId: 'a1-v0', parentMessageId: 'u1'),
            'a1-v1': MessageTreeEdge(messageId: 'a1-v1', parentMessageId: 'u1'),
            'u2': MessageTreeEdge(messageId: 'u2', parentMessageId: 'a1-v1'),
          },
        ),
      );

      final deleted = await repository.deleteMessages(
        conversationId: conversation.id,
        messageIds: const {'a1-v1'},
        versionSelectionChanges: const {},
      );
      final tree = await repository.loadConversationTree(conversation.id);

      expect(deleted, isNot(equals(null)));
      expect(deleted!.messages.map((message) => message.id), ['a1-v1', 'u2']);
      expect(await repository.getMessage('u1'), isNot(equals(null)));
      expect(await repository.getMessage('a1-v0'), isNot(equals(null)));
      expect(await repository.getMessage('a1-v1'), equals(null));
      expect(await repository.getMessage('u2'), equals(null));
      expect(tree, isA<ConversationTree>());
      expect(tree!.activePath(), const ['u1', 'a1-v0']);
      expect(tree.branches.containsKey('root'), isFalse);
      expect(tree.branches.containsKey('legacy-a1-v0'), isTrue);
    },
  );

  test(
    'regeneration appends the new assistant to the requested branch',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();

      final createdAt = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
      await database.customStatement(
        'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
        'VALUES (?, ?, ?, ?);',
        ['conversation-regenerate', 'regenerate', createdAt, createdAt],
      );

      final repository = ChatDatabaseRepository(database);
      final conversation = Conversation(
        id: 'conversation-regenerate',
        title: 'regenerate',
      );
      await repository.putMigrationBatch(
        conversations: [conversation],
        messages: [
          (
            message: ChatMessage(
              id: 'u1',
              conversationId: conversation.id,
              role: 'user',
              content: 'question',
              timestamp: DateTime.utc(2026, 1, 1),
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
      await repository.saveConversationTree(
        ConversationTree.linear(
          conversationId: conversation.id,
          messageIds: const ['u1'],
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
      final messageBranchTree = await repository
          .loadConversationTree(conversation.id)
          .then(
            (tree) => tree!.createMessageBranch(
              branchId: 'branch-new',
              fromMessageId: 'u1',
            ),
          );
      await repository.saveConversationTree(messageBranchTree);

      await repository.beginAssistantGeneration(
        conversation: conversation,
        assistantMessage: ChatMessage(
          id: 'a-new',
          conversationId: conversation.id,
          role: 'assistant',
          content: '',
          isStreaming: true,
          timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
        ),
        anchorGroupId: 'u1',
        runId: 'run-branch',
        truncateFuture: false,
        parentMessageId: 'u1',
        branchId: 'branch-new',
      );

      final tree = await repository.loadConversationTree(conversation.id);
      expect(tree, isA<ConversationTree>());
      expect(tree!.activeBranchId, 'branch-new');
      expect(tree.activePath(), const ['u1', 'a-new']);
      expect(tree.edges['a-new']?.parentMessageId, 'u1');
      expect(await repository.getMessage('a-new'), isNot(equals(null)));
    },
  );

  test('editing a message creates a sibling branch at its parent', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customSelect('SELECT 1;').getSingle();
    final repository = ChatDatabaseRepository(database);
    final conversation = Conversation(id: 'edit-tree', title: 'edit');
    await repository.putMigrationBatch(
      conversations: [conversation],
      messages: [
        (
          message: ChatMessage(
            id: 'u1',
            conversationId: conversation.id,
            role: 'user',
            content: 'question',
            timestamp: DateTime.utc(2026, 1, 1),
          ),
          messageOrder: 0,
        ),
        (
          message: ChatMessage(
            id: 'a1',
            conversationId: conversation.id,
            role: 'assistant',
            content: 'answer',
            timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
          messageOrder: 1,
        ),
        (
          message: ChatMessage(
            id: 'u2',
            conversationId: conversation.id,
            role: 'user',
            content: 'follow-up',
            timestamp: DateTime.utc(2026, 1, 1, 0, 0, 2),
          ),
          messageOrder: 2,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final edited = await repository.appendMessageVersion(
      messageId: 'a1',
      content: 'edited answer',
    );
    final tree = await repository.loadConversationTree(conversation.id);

    expect(edited, isNot(equals(null)));
    expect(tree, isNot(equals(null)));
    expect(tree!.activePath(), ['u1', edited!.message.id]);
    expect(tree.branchPath('root-edit-tree'), ['u1', 'a1', 'u2']);
    expect(tree.edges[edited.message.id]?.parentMessageId, 'u1');
    expect(tree.childrenOf('u1'), containsAll(['a1', edited.message.id]));
  });

  test(
    'legacy import materializes selected versions as message forks',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customSelect('SELECT 1;').getSingle();
      final repository = ChatDatabaseRepository(database);
      final conversation = Conversation(
        id: 'legacy-import',
        title: 'legacy',
        versionSelections: const {'a1': 1},
      );
      await repository.putMigrationBatch(
        conversations: [conversation],
        messages: [
          (
            message: ChatMessage(
              id: 'u1',
              conversationId: conversation.id,
              role: 'user',
              content: 'question',
            ),
            messageOrder: 0,
          ),
          (
            message: ChatMessage(
              id: 'a1-v0',
              conversationId: conversation.id,
              role: 'assistant',
              content: 'old',
              groupId: 'a1',
              version: 0,
            ),
            messageOrder: 1,
          ),
          (
            message: ChatMessage(
              id: 'a1-v1',
              conversationId: conversation.id,
              role: 'assistant',
              content: 'selected',
              groupId: 'a1',
              version: 1,
            ),
            messageOrder: 2,
          ),
          (
            message: ChatMessage(
              id: 'u2',
              conversationId: conversation.id,
              role: 'user',
              content: 'follow-up',
            ),
            messageOrder: 3,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final tree = await repository.loadConversationTree(conversation.id);
      expect(tree, isNot(equals(null)));
      expect(tree!.activePath(), ['u1', 'a1-v1', 'u2']);
      expect(tree.branchPath('legacy-a1-v0'), ['u1', 'a1-v0']);
      expect(tree.edges['a1-v0']?.parentMessageId, 'u1');
      expect(tree.edges['a1-v1']?.parentMessageId, 'u1');
    },
  );
}
