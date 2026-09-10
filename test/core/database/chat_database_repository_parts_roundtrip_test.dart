import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/models/message_part.dart';

void main() {
  late Directory root;
  late ChatDatabaseRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat_parts_roundtrip_');
    repository = ChatDatabaseRepository.open(
      file: File('${root.path}/parts.sqlite'),
    );
    await repository.ensureReady();
  });

  tearDown(() async {
    await repository.close();
    await root.delete(recursive: true);
  });

  test('text+image+file parts roundtrip preserves order and payload', () async {
    final now = DateTime.utc(2026, 8, 9, 12);
    const conversationId = 'conversation-parts';
    const messageId = 'message-parts';
    final conversation = Conversation(
      id: conversationId,
      title: 'Parts',
      createdAt: now,
      updatedAt: now,
      messageIds: const [messageId],
    );
    final message = ChatMessage(
      id: messageId,
      role: 'user',
      conversationId: conversationId,
      timestamp: now,
      parts: const [
        TextPart('帮我看看'),
        ImagePart(uri: '/tmp/a.png', mime: 'image/png', assetId: 'asset-image'),
        FilePart(
          uri: '/tmp/spec.pdf',
          name: 'spec.pdf',
          mime: 'application/pdf',
          assetId: 'asset-file',
        ),
        TextPart('谢谢'),
      ],
    );

    await repository.putMigrationBatch(
      conversations: [conversation],
      messages: [(message: message, messageOrder: 0)],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final reloaded = await repository.getMessage(messageId);
    expect(reloaded, isNotNull);
    expect(reloaded!.content, '帮我看看谢谢');
    expect(reloaded.parts, hasLength(4));

    expect(reloaded.parts[0], isA<TextPart>());
    expect((reloaded.parts[0] as TextPart).text, '帮我看看');

    expect(reloaded.parts[1], isA<ImagePart>());
    final image = reloaded.parts[1] as ImagePart;
    expect(image.uri, '/tmp/a.png');
    expect(image.mime, 'image/png');
    expect(image.assetId, 'asset-image');
    expect(image.unavailable, isFalse);

    expect(reloaded.parts[2], isA<FilePart>());
    final file = reloaded.parts[2] as FilePart;
    expect(file.uri, '/tmp/spec.pdf');
    expect(file.name, 'spec.pdf');
    expect(file.mime, 'application/pdf');
    expect(file.assetId, 'asset-file');
    expect(file.unavailable, isFalse);

    expect(reloaded.parts[3], isA<TextPart>());
    expect((reloaded.parts[3] as TextPart).text, '谢谢');

    // Encode payloads must match the domain model contract exactly.
    for (var i = 0; i < message.parts.length; i++) {
      expect(
        reloaded.parts[i].encodePayload(),
        message.parts[i].encodePayload(),
      );
      expect(reloaded.parts[i].kind, message.parts[i].kind);
    }
  });

  test(
    'attachment parts mark asset references dirty without marker strings',
    () async {
      final now = DateTime.utc(2026, 8, 9, 13);
      const conversationId = 'conversation-dirty';
      const messageId = 'message-dirty';
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Dirty',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: messageId,
              role: 'user',
              conversationId: conversationId,
              timestamp: now,
              parts: const [
                TextPart('plain text only — no markers'),
                ImagePart(uri: '/tmp/b.png', mime: 'image/png'),
              ],
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      expect(await repository.hasPendingAssetReferenceSync(), isTrue);
    },
  );
  test('appendMessageVersion content-only keeps prior ImagePart', () async {
    final now = DateTime.utc(2026, 8, 9, 14);
    const conversationId = 'conversation-append-parts';
    const messageId = 'message-append-parts';
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: conversationId,
          title: 'Append',
          createdAt: now,
          updatedAt: now,
          messageIds: const [messageId],
        ),
      ],
      messages: [
        (
          message: ChatMessage(
            id: messageId,
            role: 'user',
            conversationId: conversationId,
            timestamp: now,
            groupId: messageId,
            version: 0,
            parts: const [
              ImagePart(uri: '/tmp/keep.png', mime: 'image/png'),
              TextPart('original caption'),
            ],
          ),
          messageOrder: 0,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final result = await repository.appendMessageVersion(
      messageId: messageId,
      content: 'edited caption',
    );
    expect(result, isNotNull);
    final persisted = await repository.getMessage(result!.message.id);
    expect(persisted, isNotNull);
    expect(persisted!.content, 'edited caption');
    expect(persisted.parts, hasLength(2));
    expect(persisted.parts[0], isA<ImagePart>());
    expect((persisted.parts[0] as ImagePart).uri, '/tmp/keep.png');
    expect((persisted.parts[0] as ImagePart).mime, 'image/png');
    expect(persisted.parts[1], isA<TextPart>());
    expect((persisted.parts[1] as TextPart).text, 'edited caption');
  });

  test(
    'unknown future_widget part persists and writes back unchanged',
    () async {
      final now = DateTime.utc(2026, 8, 9, 14);
      const conversationId = 'conversation-unknown';
      const messageId = 'message-unknown';
      const unknownPayload = '{"widget":"chart","v":2}';
      final message = ChatMessage(
        id: messageId,
        role: 'assistant',
        conversationId: conversationId,
        timestamp: now,
        parts: const [
          TextPart('hello'),
          UnknownPart(rawKind: 'future_widget', payload: unknownPayload),
        ],
      );

      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Unknown',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [(message: message, messageOrder: 0)],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final reloaded = await repository.getMessage(messageId);
      expect(reloaded, isNotNull);
      expect(reloaded!.parts, hasLength(2));
      expect(reloaded.parts[1], isA<UnknownPart>());
      final unknown = reloaded.parts[1] as UnknownPart;
      expect(unknown.kind, 'future_widget');
      expect(unknown.rawKind, 'future_widget');
      expect(unknown.payload, unknownPayload);
      expect(unknown.encodePayload(), unknownPayload);

      // Write back unchanged.
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Unknown',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [(message: reloaded, messageOrder: 0)],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final again = await repository.getMessage(messageId);
      expect(again, isNotNull);
      expect(again!.parts[1], isA<UnknownPart>());
      expect(again.parts[1].kind, 'future_widget');
      expect(again.parts[1].encodePayload(), unknownPayload);

      final raw = sqlite.sqlite3.open('${root.path}/parts.sqlite');
      try {
        final rows = raw.select(
          "SELECT kind, payload FROM message_part_rows "
          "WHERE revision_id = '$messageId' ORDER BY ordinal;",
        );
        expect(rows.map((row) => row['kind']).toList(), [
          'text',
          'future_widget',
        ]);
        expect(rows[1]['payload'], unknownPayload);
      } finally {
        raw.close();
      }
    },
  );

  test(
    'malformed attachment is isolated and survives an edited message write-back',
    () async {
      final now = DateTime.utc(2026, 8, 10, 10);
      const conversationId = 'conversation-malformed';
      const malformedId = 'message-malformed';
      const healthyId = 'message-healthy';
      const malformedPayload = '{"uri":"/tmp/corrupt.png",broken';
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Malformed',
            createdAt: now,
            updatedAt: now,
            messageIds: const [malformedId, healthyId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: malformedId,
              role: 'user',
              conversationId: conversationId,
              timestamp: now,
              parts: const [
                TextPart('before'),
                ImagePart(uri: '/tmp/corrupt.png'),
                TextPart('after'),
              ],
            ),
            messageOrder: 0,
          ),
          (
            message: ChatMessage(
              id: healthyId,
              role: 'assistant',
              conversationId: conversationId,
              timestamp: now,
              content: 'healthy',
            ),
            messageOrder: 1,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final raw = sqlite.sqlite3.open('${root.path}/parts.sqlite');
      try {
        raw.execute(
          'UPDATE message_part_rows SET payload = ? '
          'WHERE revision_id = ? AND ordinal = 1;',
          [malformedPayload, malformedId],
        );
        raw.execute(
          'DELETE FROM asset_reference_dirty_rows WHERE revision_id = ?;',
          [malformedId],
        );
      } finally {
        raw.close();
      }

      final single = await repository.getMessage(malformedId);
      expect(single, isNotNull);
      expect(single!.content, 'beforeafter');
      expect(single.parts, hasLength(3));
      expect(single.parts[0], isA<TextPart>());
      expect(single.parts[1], isA<MalformedPart>());
      expect(single.parts[2], isA<TextPart>());
      final malformed = single.parts[1] as MalformedPart;
      expect(malformed.rawKind, 'image');
      expect(malformed.rawPayload, malformedPayload);
      expect(malformed.isAttachmentKind, isTrue);

      final batch = await repository.getMessagesRange(
        conversationId,
        start: 0,
        limit: 10,
      );
      expect(batch, hasLength(2));
      expect(batch[0].parts[1], isA<MalformedPart>());
      expect(batch[1].content, 'healthy');

      await repository.updateMessage(single.copyWith(content: 'edited'));

      final persisted = sqlite.sqlite3.open('${root.path}/parts.sqlite');
      try {
        final row = persisted.select(
          'SELECT ordinal, kind, payload FROM message_part_rows '
          'WHERE revision_id = ? AND kind = ?;',
          [malformedId, 'image'],
        ).single;
        expect(row['ordinal'], 1);
        expect(row['payload'], malformedPayload);
        expect(
          persisted.select(
            'SELECT 1 FROM asset_reference_dirty_rows '
            'WHERE revision_id = ?;',
            [malformedId],
          ).length,
          1,
        );
      } finally {
        persisted.close();
      }
    },
  );

  test(
    'attachment payload validation paginates and reports progress',
    () async {
      final now = DateTime.utc(2026, 8, 10, 11);
      const conversationId = 'conversation-validation-progress';
      const messageId = 'message-validation-progress';
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Validation progress',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: messageId,
              role: 'user',
              conversationId: conversationId,
              timestamp: now,
              parts: [
                for (var i = 0; i < 257; i++) ImagePart(uri: '/tmp/$i.png'),
              ],
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final progress = <({int processed, int total})>[];
      await repository.validateAttachmentPartPayloads(
        onProgress: (processed, total) {
          progress.add((processed: processed, total: total));
        },
      );

      expect(progress.first, (processed: 0, total: 257));
      expect(progress, contains((processed: 256, total: 257)));
      expect(progress.last, (processed: 257, total: 257));
    },
  );

  test(
    'attachment payload validation enforces a byte budget per page',
    () async {
      final now = DateTime.utc(2026, 8, 10, 12);
      const conversationId = 'conversation-validation-byte-budget';
      const messageId = 'message-validation-byte-budget';
      final inlineBody = List.filled(1100000, 'A').join();
      final inlineUri = 'data:image/png;base64,$inlineBody';
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Validation byte budget',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: messageId,
              role: 'user',
              conversationId: conversationId,
              timestamp: now,
              parts: [
                ImagePart(uri: inlineUri),
                ImagePart(uri: inlineUri),
              ],
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final progress = <({int processed, int total})>[];
      final metadataWindows = <int>[];
      await repository.validateAttachmentPartPayloads(
        onProgress: (processed, total) {
          progress.add((processed: processed, total: total));
        },
        onMetadataWindow: metadataWindows.add,
      );

      expect(metadataWindows, [2]);
      expect(progress, [
        (processed: 0, total: 2),
        (processed: 1, total: 2),
        (processed: 2, total: 2),
      ]);
    },
  );

  test(
    'appendMessageVersion with editor parts keeps the reasoning chain',
    () async {
      final now = DateTime.utc(2026, 9, 9, 15);
      const conversationId = 'conversation-append-reasoning';
      const messageId = 'message-append-reasoning';
      final startedAt = now.add(const Duration(minutes: 1));
      final finishedAt = now.add(const Duration(minutes: 2));
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Append reasoning',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: messageId,
              role: 'assistant',
              conversationId: conversationId,
              timestamp: now,
              parts: const [
                ReasoningPart('old chain'),
                TextPart('original answer'),
              ],
              reasoningStartAt: startedAt,
              reasoningFinishedAt: finishedAt,
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      // 编辑器返回的部件保留了思维链卡片：新分支必须继承思维链与元数据。
      final result = await repository.appendMessageVersion(
        messageId: messageId,
        parts: const [ReasoningPart('new chain'), TextPart('edited answer')],
      );
      expect(result, isNotNull);
      expect(result!.message.reasoningText, 'new chain');
      // 数据库往返后 DateTime 仅时区表示可能变化，按时刻比较。
      expect(result.message.reasoningStartAt!.isAtSameMomentAs(startedAt), isTrue);
      expect(
        result.message.reasoningFinishedAt!.isAtSameMomentAs(finishedAt),
        isTrue,
      );

      final persisted = await repository.getMessage(result.message.id);
      expect(persisted, isNotNull);
      expect(persisted!.reasoningText, 'new chain');
      expect(persisted.parts, hasLength(2));
      expect(persisted.parts[0], isA<ReasoningPart>());
      expect((persisted.parts[0] as ReasoningPart).text, 'new chain');
      expect((persisted.parts[1] as TextPart).text, 'edited answer');
    },
  );

  test(
    'appendMessageVersion drops reasoning when the editor removed the part',
    () async {
      final now = DateTime.utc(2026, 9, 9, 16);
      const conversationId = 'conversation-append-reasoning-drop';
      const messageId = 'message-append-reasoning-drop';
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Append reasoning drop',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: messageId,
              role: 'assistant',
              conversationId: conversationId,
              timestamp: now,
              parts: const [
                ReasoningPart('doomed chain'),
                TextPart('original answer'),
              ],
              reasoningStartAt: now.add(const Duration(minutes: 1)),
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final result = await repository.appendMessageVersion(
        messageId: messageId,
        parts: const [TextPart('edited answer')],
      );
      expect(result, isNotNull);
      expect(result!.message.reasoningText, isNull);
      expect(result.message.reasoningStartAt, isNull);

      final persisted = await repository.getMessage(result.message.id);
      expect(persisted, isNotNull);
      expect(persisted!.reasoningText, isNull);
      expect(persisted.parts, hasLength(1));
      expect(persisted.parts.single, isA<TextPart>());

      final raw = sqlite.sqlite3.open('${root.path}/parts.sqlite');
      try {
        final reasoningRows = raw.select(
          "SELECT 1 FROM message_part_rows "
          "WHERE revision_id = '${result.message.id}' AND kind = 'reasoning';",
        );
        expect(reasoningRows, isEmpty);
      } finally {
        raw.close();
      }
    },
  );

  test(
    'updateMessage without reasoning parts clears a previous reasoning chain',
    () async {
      final now = DateTime.utc(2026, 9, 9, 17);
      const conversationId = 'conversation-overwrite-reasoning';
      const messageId = 'message-overwrite-reasoning';
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Overwrite reasoning',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: messageId,
              role: 'assistant',
              conversationId: conversationId,
              timestamp: now,
              parts: const [
                ReasoningPart('chain to remove'),
                TextPart('original answer'),
              ],
              reasoningStartAt: now.add(const Duration(minutes: 1)),
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      // 覆盖保存路径：编辑器删除了思维链部件，消息层也不再携带
      // reasoningText 与 reasoningStartAt，落库不得复活旧思考。
      final cleared = ChatMessage(
        id: messageId,
        role: 'assistant',
        conversationId: conversationId,
        timestamp: now,
        parts: const [TextPart('edited answer')],
      );
      await repository.updateMessage(cleared);

      final persisted = await repository.getMessage(messageId);
      expect(persisted, isNotNull);
      expect(persisted!.reasoningText, isNull);
      expect(persisted.parts, hasLength(1));
      expect(persisted.parts.single, isA<TextPart>());
    },
  );

  test('interleaved text/reasoning order survives persistence', () async {
    final now = DateTime.utc(2026, 9, 10, 10);
    const conversationId = 'conversation-interleaved';
    const messageId = 'message-interleaved';
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: conversationId,
          title: 'Interleaved',
          createdAt: now,
          updatedAt: now,
          messageIds: const [messageId],
        ),
      ],
      messages: [
        (
          message: ChatMessage(
            id: messageId,
            role: 'assistant',
            conversationId: conversationId,
            timestamp: now,
            parts: const [
              TextPart('正文1'),
              ReasoningPart('思维链2'),
              TextPart('正文3'),
            ],
          ),
          messageOrder: 0,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final reloaded = await repository.getMessage(messageId);
    expect(reloaded, isNotNull);
    expect(reloaded!.reasoningText, '思维链2');
    expect(reloaded.parts, hasLength(3));
    expect((reloaded.parts[0] as TextPart).text, '正文1');
    expect((reloaded.parts[1] as ReasoningPart).text, '思维链2');
    expect((reloaded.parts[2] as TextPart).text, '正文3');

    final raw = sqlite.sqlite3.open('${root.path}/parts.sqlite');
    try {
      final rows = raw.select(
        "SELECT kind, payload FROM message_part_rows "
        "WHERE revision_id = '$messageId' ORDER BY ordinal;",
      );
      expect(rows.map((row) => row['kind']).toList(), [
        'text',
        'reasoning',
        'text',
      ]);
      expect(rows[1]['payload'], '思维链2');
    } finally {
      raw.close();
    }

    // 双重保存幂等：原样写回再读，顺序不变。
    await repository.updateMessage(reloaded);
    final again = await repository.getMessage(messageId);
    expect(again, isNotNull);
    expect(again!.parts, hasLength(3));
    expect((again.parts[0] as TextPart).text, '正文1');
    expect((again.parts[1] as ReasoningPart).text, '思维链2');
    expect((again.parts[2] as TextPart).text, '正文3');
  });

  test(
    'appendMessageVersion keeps editor order with reasoning after text',
    () async {
      final now = DateTime.utc(2026, 9, 10, 11);
      const conversationId = 'conversation-reorder-append';
      const messageId = 'message-reorder-append';
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Reorder append',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: messageId,
              role: 'assistant',
              conversationId: conversationId,
              timestamp: now,
              parts: const [
                ReasoningPart('old chain'),
                TextPart('original answer'),
              ],
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      // 编辑器把正文拖到思维链前面：新分支必须原样保留这个顺序。
      final result = await repository.appendMessageVersion(
        messageId: messageId,
        parts: const [TextPart('edited answer'), ReasoningPart('kept chain')],
      );
      expect(result, isNotNull);
      expect(result!.message.reasoningText, 'kept chain');

      final persisted = await repository.getMessage(result.message.id);
      expect(persisted, isNotNull);
      expect(persisted!.parts, hasLength(2));
      expect((persisted.parts[0] as TextPart).text, 'edited answer');
      expect((persisted.parts[1] as ReasoningPart).text, 'kept chain');
      expect(persisted.reasoningText, 'kept chain');
    },
  );

  test('tool call keeps its edited position and event roundtrips', () async {
    final now = DateTime.utc(2026, 9, 10, 12);
    const conversationId = 'conversation-tool-position';
    const messageId = 'message-tool-position';
    const toolJson = '{"id":"call_1","name":"web_search","arguments":{}}';
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: conversationId,
          title: 'Tool position',
          createdAt: now,
          updatedAt: now,
          messageIds: const [messageId],
        ),
      ],
      messages: [
        (
          message: ChatMessage(
            id: messageId,
            role: 'assistant',
            conversationId: conversationId,
            timestamp: now,
            parts: const [
              TextPart('before'),
              ToolCallPart(toolJson),
              TextPart('after'),
            ],
          ),
          messageOrder: 0,
        ),
      ],
      toolEventsByMessageId: {
        messageId: [
          {'id': 'call_1', 'name': 'web_search', 'arguments': <String, dynamic>{}},
        ],
      },
      geminiSignaturesByMessageId: const {},
    );

    final reloaded = await repository.getMessage(messageId);
    expect(reloaded, isNotNull);
    expect(reloaded!.parts, hasLength(3));
    expect(reloaded.parts[0], isA<TextPart>());
    expect(reloaded.parts[1], isA<ToolCallPart>());
    expect((reloaded.parts[1] as ToolCallPart).payloadJson, toolJson);
    expect(reloaded.parts[2], isA<TextPart>());

    // 事件记录从部件行读回：位置重排后仍能完整取回，供回传使用。
    final events = await repository.getToolEvents(messageId);
    expect(events, hasLength(1));
    expect(events.single['id'], 'call_1');
    expect(events.single['name'], 'web_search');
  });
}
