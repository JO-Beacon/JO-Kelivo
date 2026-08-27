import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/models/message_part.dart';

void main() {
  late Directory root;
  late ChatDatabaseRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat_mini_map_search_');
    repository = ChatDatabaseRepository.open(
      file: File('${root.path}/search.sqlite'),
    );
    await repository.ensureReady();
  });

  tearDown(() async {
    await repository.close();
    await root.delete(recursive: true);
  });

  Future<void> seed({
    required Conversation conversation,
    required List<ChatMessage> messages,
  }) {
    return repository.putMigrationBatch(
      conversations: [conversation],
      messages: [
        for (final (index, message) in messages.indexed)
          (message: message, messageOrder: index),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  }

  Conversation conversation(String id) => Conversation(
    id: id,
    title: 'Mini Map',
    createdAt: DateTime.utc(2026, 8, 18),
    updatedAt: DateTime.utc(2026, 8, 18),
  );

  test('searches beyond the short message projection', () async {
    const id = 'conversation-1';
    await seed(
      conversation: conversation(id),
      messages: [
        ChatMessage(
          id: 'msg-1',
          role: 'user',
          content: '${'a' * 200}hidden-tail-token',
          conversationId: id,
        ),
      ],
    );

    final hits = await repository.searchMiniMapMatches(id, 'hidden-tail-token');
    expect(hits.single.messageId, 'msg-1');
    expect(hits.single.snippet, contains('hidden-tail-token'));
  });

  test('concatenates text parts and counts all matches', () async {
    const id = 'conversation-2';
    await seed(
      conversation: conversation(id),
      messages: [
        ChatMessage(
          id: 'msg-2',
          role: 'assistant',
          conversationId: id,
          parts: const [TextPart('prefix '), TextPart('needle needle tail')],
        ),
      ],
    );

    final hits = await repository.searchMiniMapMatches(id, 'needle');
    expect(hits.single.messageId, 'msg-2');
    expect(hits.single.matchCount, 2);
    expect(hits.single.snippet, contains('needle'));
  });

  test('searches only the selected branch version', () async {
    const id = 'conversation-3';
    final now = DateTime.utc(2026, 8, 18);
    await seed(
      conversation: Conversation(
        id: id,
        title: 'Versions',
        createdAt: now,
        updatedAt: now,
        versionSelections: const {'slot': 2},
      ),
      messages: [
        ChatMessage(
          id: 'v1',
          role: 'assistant',
          content: 'hidden-only-token',
          timestamp: now,
          conversationId: id,
          groupId: 'slot',
          version: 1,
        ),
        ChatMessage(
          id: 'v2',
          role: 'assistant',
          content: 'visible-only-token',
          timestamp: now,
          conversationId: id,
          groupId: 'slot',
          version: 2,
        ),
      ],
    );

    expect(
      await repository.searchMiniMapMatches(id, 'hidden-only-token'),
      isEmpty,
    );
    expect(
      (await repository.searchMiniMapMatches(
        id,
        'visible-only-token',
      )).single.messageId,
      'v2',
    );
  });
}
