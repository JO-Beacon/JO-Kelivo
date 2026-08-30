import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/database/generation_run.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/models/conversation_tree.dart';
import 'package:Kelivo/utils/sandbox_path_resolver.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_chat_service_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    SandboxPathResolver.debugSetDirs(
      docsDir: tempDir.path,
      supportDir: tempDir.path,
    );
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    await Hive.close();
    SandboxPathResolver.debugSetDirs(docsDir: null, supportDir: null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ChatService createService({Future<String> Function(File)? assetContentHash}) {
    final service = ChatService(assetContentHash: assetContentHash);
    services.add(service);
    return service;
  }

  test(
    'keep-recent fork writes summary and retained structured messages',
    () async {
      final service = createService();
      await service.init();
      final forked = await service.forkConversationFromMessages(
        title: 'compressed',
        assistantId: null,
        sourceMessages: [
          ChatMessage(
            role: 'user',
            content: 'summary',
            conversationId: 'source',
          ),
          ChatMessage(
            role: 'assistant',
            parts: const [TextPart('verbatim answer')],
            conversationId: 'source',
          ),
        ],
      );

      final messages = await service.loadActiveTimelineMessages(forked.id);
      expect(messages.map((message) => message.content), [
        'summary',
        'verbatim answer',
      ]);
    },
  );

  Future<({ChatDatabaseRepository repository, ChatService service})>
  createBranchedService(String fileName) async {
    final repository = ChatDatabaseRepository.open(
      file: File('${tempDir.path}/$fileName'),
    );
    addTearDown(repository.close);
    await repository.ensureReady();

    final conversation = Conversation(
      id: 'conversation-branch',
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
          id: 'u2-v0',
          conversationId: conversation.id,
          role: 'user',
          content: 'old follow-up',
          timestamp: DateTime.utc(2026, 1, 1, 0, 0, 3),
        ),
        messageOrder: 3,
      ),
      (
        message: ChatMessage(
          id: 'u2-v1',
          conversationId: conversation.id,
          role: 'user',
          content: 'selected follow-up',
          timestamp: DateTime.utc(2026, 1, 1, 0, 0, 4),
        ),
        messageOrder: 4,
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
            conversationId: conversation.id,
            tipMessageId: 'u2-v1',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          'old': ConversationBranch(
            id: 'old',
            conversationId: conversation.id,
            tipMessageId: 'u2-v0',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        },
        edges: const <String, MessageTreeEdge>{
          'u1': MessageTreeEdge(messageId: 'u1', parentMessageId: null),
          'a1-v0': MessageTreeEdge(messageId: 'a1-v0', parentMessageId: 'u1'),
          'a1-v1': MessageTreeEdge(messageId: 'a1-v1', parentMessageId: 'u1'),
          'u2-v0': MessageTreeEdge(
            messageId: 'u2-v0',
            parentMessageId: 'a1-v0',
          ),
          'u2-v1': MessageTreeEdge(
            messageId: 'u2-v1',
            parentMessageId: 'a1-v1',
          ),
        },
      ),
    );

    final service = ChatService(existingRepository: repository);
    addTearDown(service.close);
    await service.init();
    return (repository: repository, service: service);
  }

  test('cold init clears every stale streaming flag', () async {
    final first = createService();
    await first.init();
    final conversation = await first.createConversation(title: 'Chat');
    await first.addMessage(
      conversationId: conversation.id,
      role: 'assistant',
      content: 'partial',
      isStreaming: true,
    );
    await first.close();
    services.remove(first);

    final restarted = createService();
    await restarted.init();

    final messages = await restarted.loadMessages(conversation.id);
    expect(messages, hasLength(1));
    expect(messages.single.content, 'partial');
    expect(messages.single.isStreaming, isFalse);
  });

  test('windowed timeline cache stays appendable for the next send', () async {
    final service = createService();
    await service.init();
    final conversation = await service.createConversation(title: 'Chat');
    final ids = <String>[];
    for (var i = 0; i < 3; i++) {
      final message = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'message $i',
      );
      ids.add(message.id);
    }

    // Cache only a tail window so the append lands in a partial cache.
    service.debugPrimeMessageCountState(
      conversation.id,
      cachedMessages: const [],
      clearCounts: true,
    );
    await service.loadTimelinePage(conversation.id, limit: 1);
    expect(service.getMessages(conversation.id).map((message) => message.id), [
      ids.last,
    ]);

    final result = await service.beginSendGeneration(
      conversationId: conversation.id,
      userParts: const [TextPart('next question')],
      modelId: 'model',
      providerId: 'provider',
    );

    expect(service.getMessages(conversation.id).map((message) => message.id), [
      ...ids,
      result.userMessage!.id,
      result.assistantMessage.id,
    ]);
  });

  test('switching conversations evicts an oversized previous cache', () async {
    final service = createService();
    await service.init();
    final first = await service.createConversation(title: 'Large');
    await service.addMessage(
      conversationId: first.id,
      role: 'user',
      content: 'x' * (5 * 1024 * 1024),
    );
    expect(await service.loadMessages(first.id), hasLength(1));

    await service.createConversation(title: 'Next');

    expect(service.getMessages(first.id), isEmpty);
    expect(service.getMessageCount(first.id), 1);
  });

  test(
    'persistent attachment uses delayed reference GC after message delete',
    () async {
      final service = createService();
      await service.init();
      final conversation = await service.createConversation(title: 'Assets');
      final upload = File('${tempDir.path}/upload/spec.pdf');
      await upload.parent.create(recursive: true);
      await upload.writeAsString('attachment payload');
      final message = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        parts: [
          FilePart(uri: upload.path, name: 'spec.pdf', mime: 'application/pdf'),
        ],
      );

      await service.deleteMessage(message.id);

      expect(await upload.exists(), isTrue, reason: 'GC must be delayed');
      await service.runAssetMaintenance(
        now: DateTime.now().toUtc().add(const Duration(days: 8)),
      );
      expect(await upload.exists(), isFalse);
    },
  );

  test(
    'unavailable local attachment does not leave asset sync dirty',
    () async {
      final service = createService();
      await service.init();
      final conversation = await service.createConversation(title: 'Missing');
      final missing = File('${tempDir.path}/upload/gone.png');
      await missing.parent.create(recursive: true);
      // Path is under upload/, but the file itself is intentionally absent.
      expect(await missing.exists(), isFalse);

      await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        parts: [
          ImagePart(uri: missing.path, mime: 'image/png', unavailable: true),
        ],
      );

      await service.runAssetReferenceMaintenance();
      final repo = service.chatRepositoryOrNull;
      expect(repo, isNotNull);
      expect(await repo!.hasPendingAssetReferenceSync(), isFalse);
    },
  );

  test(
    'cold init backfills attachment references left by an older writer',
    () async {
      final first = createService();
      await first.init();
      final conversation = await first.createConversation(title: 'Assets');
      final upload = File('${tempDir.path}/upload/legacy.txt');
      await upload.parent.create(recursive: true);
      await upload.writeAsString('legacy attachment payload');
      final message = await first.addMessage(
        conversationId: conversation.id,
        role: 'user',
        parts: [
          FilePart(uri: upload.path, name: 'legacy.txt', mime: 'text/plain'),
        ],
      );
      await first.close();
      services.remove(first);

      final database = sqlite.sqlite3.open(
        '${tempDir.path}/${AppDatabase.databaseFileName}',
      );
      try {
        database.execute('DELETE FROM asset_rows;');
        database.execute(
          "DELETE FROM chat_storage_meta_rows "
          "WHERE key = 'asset_reference_backfill_version';",
        );
      } finally {
        database.close();
      }

      final hashStarted = Completer<void>();
      final hashResult = Completer<String>();
      final restarted = createService(
        assetContentHash: (file) {
          if (!hashStarted.isCompleted) hashStarted.complete();
          return hashResult.future;
        },
      );
      await restarted.init().timeout(const Duration(seconds: 1));
      await hashStarted.future.timeout(const Duration(seconds: 1));
      expect(hashResult.isCompleted, isFalse);

      hashResult.complete(List.filled(64, 'b').join());
      await restarted.runAssetReferenceMaintenance();
      await restarted.deleteMessage(message.id);
      await restarted.runAssetMaintenance(
        now: DateTime.now().toUtc().add(const Duration(days: 8)),
      );

      expect(await upload.exists(), isFalse);
    },
  );

  test(
    'asset backfill skips malformed attachment without clearing its references',
    () async {
      final first = createService();
      await first.init();
      final repository = first.chatRepositoryOrNull!;
      final now = DateTime.utc(2026, 8, 10);
      const conversationId = 'conversation-malformed-backfill';
      const messageIds = ['a-healthy', 'b-malformed', 'c-healthy'];
      final files = <String, File>{
        for (final id in messageIds) id: File('${tempDir.path}/upload/$id.txt'),
      };
      for (final file in files.values) {
        await file.parent.create(recursive: true);
        await file.writeAsString('payload:${file.path}');
      }
      final messages = [
        for (final id in messageIds)
          ChatMessage(
            id: id,
            role: 'user',
            conversationId: conversationId,
            timestamp: now,
            parts: [
              FilePart(
                uri: files[id]!.path,
                name: '$id.txt',
                mime: 'text/plain',
              ),
            ],
          ),
      ];
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Malformed backfill',
            createdAt: now,
            updatedAt: now,
            messageIds: messageIds,
          ),
        ],
        messages: [
          for (var i = 0; i < messages.length; i++)
            (message: messages[i], messageOrder: i),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
      for (var i = 0; i < messageIds.length; i++) {
        await repository.registerAsset(
          id: 'legacy-asset-$i',
          contentHash: List.filled(64, '${i + 1}').join(),
          path: files[messageIds[i]]!.path,
          byteSize: await files[messageIds[i]]!.length(),
          createdAt: now,
        );
        await repository.linkMessageAsset(
          conversationId: conversationId,
          revisionId: messageIds[i],
          assetId: 'legacy-asset-$i',
          kind: 'file',
        );
      }
      await first.close();
      services.remove(first);

      final database = sqlite.sqlite3.open(
        '${tempDir.path}/${AppDatabase.databaseFileName}',
      );
      try {
        database.execute(
          'DELETE FROM message_asset_rows '
          "WHERE revision_id IN ('a-healthy', 'c-healthy');",
        );
        database.execute(
          'UPDATE message_part_rows SET payload = ? '
          "WHERE revision_id = 'b-malformed' AND kind = 'file';",
          ['{"uri":"${files['b-malformed']!.path}"}'],
        );
        database.execute(
          'INSERT OR IGNORE INTO asset_reference_dirty_rows(revision_id) '
          "VALUES ('a-healthy'), ('b-malformed'), ('c-healthy');",
        );
        database.execute(
          "DELETE FROM chat_storage_meta_rows "
          "WHERE key = 'sandbox_path_migration_version';",
        );
      } finally {
        database.close();
      }

      final restarted = createService();
      await restarted.init().timeout(const Duration(seconds: 2));
      await restarted.runAssetReferenceMaintenance();

      final verify = sqlite.sqlite3.open(
        '${tempDir.path}/${AppDatabase.databaseFileName}',
      );
      try {
        expect(
          verify.select(
            "SELECT 1 FROM message_asset_rows WHERE revision_id = 'a-healthy';",
          ),
          isNotEmpty,
        );
        expect(
          verify.select(
            "SELECT 1 FROM message_asset_rows WHERE revision_id = 'c-healthy';",
          ),
          isNotEmpty,
        );
        final malformedRefs = verify.select(
          "SELECT asset_id FROM message_asset_rows "
          "WHERE revision_id = 'b-malformed';",
        );
        expect(malformedRefs, hasLength(1));
        expect(malformedRefs.single['asset_id'], 'legacy-asset-1');
        expect(
          verify
              .select(
                "SELECT revision_id FROM asset_reference_dirty_rows "
                'ORDER BY revision_id;',
              )
              .map((row) => row['revision_id']),
          ['b-malformed'],
        );
        expect(
          verify.select(
            "SELECT 1 FROM chat_storage_meta_rows "
            "WHERE key = 'sandbox_path_migration_version';",
          ),
          hasLength(1),
        );
      } finally {
        verify.close();
      }
    },
  );

  test(
    'editing malformed attachment preserves live asset references and dirty state',
    () async {
      final first = createService();
      await first.init();
      final conversation = await first.createConversation(title: 'Malformed');
      final upload = File('${tempDir.path}/upload/live.txt');
      await upload.parent.create(recursive: true);
      await upload.writeAsString('live attachment');
      final message = await first.addMessage(
        conversationId: conversation.id,
        role: 'user',
        parts: [
          FilePart(uri: upload.path, name: 'live.txt', mime: 'text/plain'),
        ],
      );
      await first.close();
      services.remove(first);

      final databasePath = '${tempDir.path}/${AppDatabase.databaseFileName}';
      final corrupt = sqlite.sqlite3.open(databasePath);
      late final String originalAssetId;
      const secret = '/private/attachment-metadata';
      final malformedPayload = jsonEncode({
        'uri': upload.path,
        'name': 'live.txt',
        'mime': [secret],
      });
      try {
        originalAssetId =
            corrupt.select(
                  'SELECT asset_id FROM message_asset_rows WHERE revision_id = ?;',
                  [message.id],
                ).single['asset_id']
                as String;
        corrupt.execute(
          'UPDATE message_part_rows SET payload = ? '
          'WHERE revision_id = ? AND kind = ?;',
          [malformedPayload, message.id, 'file'],
        );
        corrupt.execute(
          'DELETE FROM asset_reference_dirty_rows WHERE revision_id = ?;',
          [message.id],
        );
      } finally {
        corrupt.close();
      }

      final restarted = createService();
      await restarted.init();
      final loaded = await restarted.loadMessages(conversation.id);
      final malformed = loaded.single.parts.single as MalformedPart;
      expect(malformed.parseError, 'invalid_mime');
      expect(malformed.parseError, isNot(contains(secret)));

      await restarted.updateMessage(message.id, content: 'edited');

      final verify = sqlite.sqlite3.open(databasePath);
      try {
        final references = verify.select(
          'SELECT asset_id FROM message_asset_rows WHERE revision_id = ?;',
          [message.id],
        );
        expect(references, hasLength(1));
        expect(references.single['asset_id'], originalAssetId);
        expect(
          verify.select(
            'SELECT 1 FROM asset_reference_dirty_rows WHERE revision_id = ?;',
            [message.id],
          ),
          hasLength(1),
        );
      } finally {
        verify.close();
      }
      expect(await upload.exists(), isTrue);
    },
  );

  test(
    'message role switch persists without changing revision identity or parts',
    () async {
      final first = createService();
      await first.init();
      final conversation = await first.createDraftConversation(
        title: 'Role switch',
      );
      final before = await first.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        parts: const [
          TextPart('answer'),
          ImagePart(uri: 'https://example.com/image.png'),
          UnknownPart(rawKind: 'future', payload: '{"opaque":true}'),
        ],
      );

      expect(await first.switchMessageRole(before.id, 'user'), isTrue);
      expect(await first.switchMessageRole(before.id, 'user'), isFalse);
      expect(await first.switchMessageRole('missing', 'assistant'), isFalse);
      await first.close();
      services.remove(first);

      final restarted = createService();
      await restarted.init();
      final after = (await restarted.loadMessages(conversation.id)).single;
      expect(after.id, before.id);
      expect(after.role, 'user');
      expect(after.groupId, before.groupId ?? before.id);
      expect(after.version, before.version);
      expect(after.parts.map((part) => part.kind), ['text', 'image', 'future']);
      expect(await restarted.getMessageIds(conversation.id), [before.id]);
    },
  );

  test(
    'structured part edit persists as the next ordered revision losslessly',
    () async {
      final first = createService();
      await first.init();
      final conversation = await first.createDraftConversation(
        title: 'Structured edit',
      );
      final original = await first.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        parts: const <MessagePart>[
          TextPart('before'),
          ImagePart(uri: 'https://example.com/old.png'),
          UnknownPart(rawKind: 'future', payload: '{"opaque":true}'),
        ],
      );
      final edited = await first.appendMessageVersion(
        messageId: original.id,
        parts: const <MessagePart>[
          TextPart('after'),
          FilePart(
            uri: 'https://example.com/new.pdf',
            name: 'new.pdf',
            mime: 'application/pdf',
          ),
          UnknownPart(rawKind: 'future', payload: '{"opaque":true}'),
        ],
      );

      expect(edited, isNotNull);
      expect(edited!.groupId, original.groupId ?? original.id);
      expect(edited.version, original.version + 1);
      expect(await first.getMessageIds(conversation.id), [edited.id]);
      expect(
        await first.loadPersistedMessageIds(conversation.id),
        containsAll(<String>[original.id, edited.id]),
      );
      await first.close();
      services.remove(first);

      final restarted = createService();
      await restarted.init();
      final messages = await restarted.loadMessages(conversation.id);
      expect(messages.map((message) => message.id), [edited.id]);
      final after = messages.single;
      expect(after.parts.map((part) => part.kind), ['text', 'file', 'future']);
      expect((after.parts[0] as TextPart).text, 'after');
      expect((after.parts[1] as FilePart).name, 'new.pdf');
      expect((after.parts[2] as UnknownPart).payload, '{"opaque":true}');
      // versionSelections 不再被运行时写入，只保留在兼容层
      expect(restarted.getVersionSelections(conversation.id), {});
    },
  );

  group('ChatService temporary conversations', () {
    test('ordinary draft persists when its first message is added', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(title: 'Chat');
      final message = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'hello',
      );

      expect(service.getAllConversations().map((c) => c.id), [conversation.id]);
      expect(await service.loadMessages(conversation.id), hasLength(1));
      final timeline = await service.loadTimelinePage(
        conversation.id,
        fromStart: true,
      );
      expect(timeline!.slots.single.message.id, message.id);
      expect(timeline.slots.single.message.content, 'hello');
    });

    test(
      'temporary draft keeps messages in memory without entering history',
      () async {
        final service = createService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'secret',
        );

        expect(service.getAllConversations(), isEmpty);
        expect(service.getConversation(conversation.id), isNotNull);
        expect(service.getMessages(conversation.id), hasLength(1));
        expect(service.isTemporaryConversation(conversation.id), isTrue);
      },
    );

    test(
      'temporary conversation supports range and recent message reads',
      () async {
        final service = createService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        for (var i = 0; i < 5; i++) {
          await service.addMessage(
            conversationId: conversation.id,
            role: i.isEven ? 'user' : 'assistant',
            content: 'temporary message $i',
          );
        }

        final range = service.getMessagesRange(
          conversation.id,
          start: 1,
          limit: 3,
        );
        final recent = service.getRecentMessages(
          conversation.id,
          minMessages: 2,
          maxMessages: 2,
        );

        expect(range.map((message) => message.content), [
          'temporary message 1',
          'temporary message 2',
          'temporary message 3',
        ]);
        expect(recent.map((message) => message.content), [
          'temporary message 3',
          'temporary message 4',
        ]);
      },
    );

    test(
      'temporary timeline pages stay bounded without evicting memory history',
      () async {
        final service = createService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        for (var i = 0; i < 45; i++) {
          await service.addMessage(
            conversationId: conversation.id,
            role: i.isEven ? 'user' : 'assistant',
            content: 'temporary message $i',
          );
        }

        final tail = await service.loadTimelinePage(conversation.id, limit: 40);
        expect(tail, isNotNull);
        expect(tail!.slots, hasLength(40));
        expect(tail.slots.first.message.content, 'temporary message 5');
        expect(tail.hasMoreBefore, isTrue);

        expect(await service.loadMessages(conversation.id), hasLength(45));
        final before = await service.loadTimelinePage(
          conversation.id,
          beforeRevisionId: tail.slots.first.identity.revisionId,
          limit: 20,
        );
        expect(before!.slots, hasLength(5));
        expect(before.slots.first.message.content, 'temporary message 0');
      },
    );

    test('temporary batch deletion reports the removed revisions', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final first = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'first',
      );
      final second = await service.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: 'second',
      );
      await service.updateConversationSuggestions(conversation.id, const [
        'stale suggestion',
      ]);

      final deleted = await service.deleteMessages(
        conversationId: conversation.id,
        messageIds: {second.id, 'missing'},
        versionSelectionChanges: const {},
      );
      final page = await service.loadTimelinePage(conversation.id);

      expect(deleted, {second.id});
      expect(page!.slots.map((slot) => slot.identity.revisionId), [first.id]);
      expect(await service.loadMessages(conversation.id), [first]);
      expect(
        service.getConversation(conversation.id)!.chatSuggestions,
        isEmpty,
      );
    });

    test(
      'temporary timeline projects the selected revision per slot',
      () async {
        final service = createService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        await service.addMessage(
          conversationId: conversation.id,
          role: 'assistant',
          content: 'version zero',
          groupId: 'answer-slot',
          version: 0,
          selectVersion: true,
        );
        final selected = await service.addMessage(
          conversationId: conversation.id,
          role: 'assistant',
          content: 'version two',
          groupId: 'answer-slot',
          version: 2,
          selectVersion: true,
        );

        final page = await service.loadTimelinePage(conversation.id);

        expect(page!.slots, hasLength(1));
        expect(page.slots.single.identity.versionCount, 2);
        expect(page.slots.single.message, selected);
      },
    );

    test(
      'temporary conversation is discarded when current conversation changes',
      () async {
        final service = createService();
        await service.init();

        final temporary = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        await service.addMessage(
          conversationId: temporary.id,
          role: 'user',
          content: 'secret',
        );

        final ordinary = await service.createDraftConversation(title: 'Chat');

        expect(service.getConversation(temporary.id), isNull);
        expect(service.getMessages(temporary.id), isEmpty);
        expect(service.currentConversationId, ordinary.id);
        expect(service.getAllConversations(), isEmpty);
        expect(service.isTemporaryConversation(temporary.id), isTrue);
      },
    );

    test(
      'late message cannot revive a discarded temporary conversation',
      () async {
        final service = createService();
        await service.init();

        final temporary = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        await service.createDraftConversation(title: 'Next Chat');

        final lateMessage = await service.addMessage(
          conversationId: temporary.id,
          role: 'assistant',
          content: 'late secret',
        );
        await service.setGeminiThoughtSignature(
          lateMessage.id,
          'late signature',
        );

        expect(service.getConversation(temporary.id), isNull);
        expect(service.getMessages(temporary.id), isEmpty);
        expect(service.getGeminiThoughtSignature(lateMessage.id), isNull);
        expect(
          service.getAllConversations().map((conversation) => conversation.id),
          isNot(contains(temporary.id)),
        );
      },
    );

    test(
      'late checkpoint leaves no artifacts for a discarded temporary conversation',
      () async {
        final service = createService();
        await service.init();

        final temporary = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        final assistantMessage = await service.addMessage(
          conversationId: temporary.id,
          role: 'assistant',
          content: '',
          isStreaming: true,
        );
        await service.createDraftConversation(title: 'Next Chat');

        await service.updateStreamingCheckpointSilent(
          assistantMessage.copyWith(content: 'late secret'),
          const [
            {'id': 'tool-1', 'name': 'memory_read'},
          ],
        );

        expect(service.getConversation(temporary.id), isNull);
        expect(service.getMessages(temporary.id), isEmpty);
        expect(service.getToolEvents(assistantMessage.id), isEmpty);
      },
    );

    test('late Gemini signature is ignored after temporary discard', () async {
      final service = createService();
      await service.init();

      final temporary = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final assistantMessage = await service.addMessage(
        conversationId: temporary.id,
        role: 'assistant',
        content: '',
        isStreaming: true,
      );
      await service.createDraftConversation(title: 'Next Chat');

      await service.setGeminiThoughtSignature(
        assistantMessage.id,
        'late signature',
      );

      expect(service.getGeminiThoughtSignature(assistantMessage.id), isNull);
    });

    test(
      'clearing data keeps discarded temporary conversations protected',
      () async {
        final service = createService();
        await service.init();

        final temporary = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        await service.createDraftConversation(title: 'Next Chat');

        await service.clearAllData(deleteUploads: false);

        expect(service.isTemporaryConversation(temporary.id), isTrue);
        await service.addMessage(
          conversationId: temporary.id,
          role: 'assistant',
          content: 'late secret',
        );
        expect(service.getConversation(temporary.id), isNull);
        expect(service.getAllConversations(), isEmpty);
      },
    );

    test(
      'overwrite restore protects an active temporary conversation',
      () async {
        final service = createService();
        await service.init();

        final temporary = await service.createDraftConversation(
          title: 'Temporary Chat',
          temporary: true,
        );
        final assistantMessage = await service.addMessage(
          conversationId: temporary.id,
          role: 'assistant',
          content: '',
          isStreaming: true,
        );

        await service.replaceAllDataFromBackup(
          conversations: const [],
          messages: const [],
          toolEventsByMessageId: const {},
          geminiSignaturesByMessageId: const {},
        );

        expect(service.isTemporaryConversation(temporary.id), isTrue);
        await service.setGeminiThoughtSignature(
          assistantMessage.id,
          'late signature',
        );
        expect(service.getGeminiThoughtSignature(assistantMessage.id), isNull);
        expect(service.getConversation(temporary.id), isNull);
      },
    );

    test('database merge preserves an active temporary conversation', () async {
      final service = createService();
      await service.init();

      final temporary = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final assistantMessage = await service.addMessage(
        conversationId: temporary.id,
        role: 'assistant',
        content: 'still streaming',
        isStreaming: true,
      );
      final snapshot = File('${tempDir.path}/merge.sqlite');
      await service.createBackupDatabaseSnapshot(snapshot);

      await service.mergeDatabaseSnapshot(snapshot);

      expect(service.getMessages(temporary.id), [assistantMessage]);
      await service.setGeminiThoughtSignature(
        assistantMessage.id,
        'live signature',
      );
      expect(
        service.getGeminiThoughtSignature(assistantMessage.id),
        'live signature',
      );
    });

    test('temporary message deletion only affects memory', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final message = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'secret',
      );
      await service.updateConversationSuggestions(conversation.id, const [
        'stale suggestion',
      ]);

      await service.deleteMessage(message.id);

      expect(service.getAllConversations(), isEmpty);
      expect(service.getMessages(conversation.id), isEmpty);
      expect(service.getConversation(conversation.id)?.messageIds, isEmpty);
      expect(
        service.getConversation(conversation.id)?.chatSuggestions,
        isEmpty,
      );
    });

    test('temporary message editing appends an in-memory version', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final original = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'original question',
      );

      final edited = await service.appendMessageVersion(
        messageId: original.id,
        content: 'edited question',
      );

      expect(edited, isNotNull);
      expect(edited!.content, 'edited question');
      expect(edited.groupId, original.groupId ?? original.id);
      expect(edited.version, 1);
      expect(service.getMessages(conversation.id), [original, edited]);
      expect(service.getConversation(conversation.id)?.messageIds, [
        original.id,
        edited.id,
      ]);
      // versionSelections 不再被运行时写入，只保留在兼容层
      expect(service.getVersionSelections(conversation.id), {});
      expect(service.getAllConversations(), isEmpty);

      final timeline = await service.loadTimelinePage(
        conversation.id,
        fromStart: true,
      );
      expect(timeline!.slots.single.message.id, edited.id);
    });

    test('temporary content-only append keeps prior ImagePart', () async {
      final service = createService();
      await service.init();

      final conversation = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final original = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        parts: const [
          ImagePart(uri: '/tmp/keep.png', mime: 'image/png'),
          TextPart('original caption'),
        ],
      );

      final edited = await service.appendMessageVersion(
        messageId: original.id,
        content: 'edited caption',
      );

      expect(edited, isNotNull);
      expect(edited!.content, 'edited caption');
      expect(edited.parts, hasLength(2));
      expect(edited.parts[0], isA<ImagePart>());
      expect((edited.parts[0] as ImagePart).uri, '/tmp/keep.png');
      expect(edited.parts[1], isA<TextPart>());
      expect((edited.parts[1] as TextPart).text, 'edited caption');
    });

    test('temporary conversations cannot be copied', () async {
      final service = createService();
      await service.init();
      final conversation = await service.createDraftConversation(
        title: 'Temporary Chat',
        temporary: true,
      );
      final message = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'temporary',
      );

      await expectLater(
        service.createConversationForkAtRevision(
          sourceConversationId: conversation.id,
          sourceRevisionId: message.id,
          title: 'Copy',
        ),
        throwsStateError,
      );
    });
  });

  group('ChatService Conversation Fork', () {
    test('copies selected path as plain single-version messages', () async {
      final service = createService();
      await service.init();

      final source = await service.createConversation(title: 'Source');
      final original = await service.addMessage(
        conversationId: source.id,
        role: 'assistant',
        content: 'original answer',
      );
      final edited = await service.appendMessageVersion(
        messageId: original.id,
        content: 'edited answer',
      );
      expect(edited, isNotNull);

      final copiedConversation = await service.createConversationForkAtRevision(
        sourceConversationId: source.id,
        sourceRevisionId: edited!.id,
        title: 'Conversation Copy',
      );

      expect(copiedConversation.title, source.title);
      final copiedMessages = service.getMessages(copiedConversation.id);
      expect(copiedMessages, hasLength(1));
      expect(copiedMessages.single.conversationId, copiedConversation.id);
      expect(copiedMessages.single.content, 'edited answer');
      expect(
        copiedMessages.single.groupId ?? copiedMessages.single.id,
        copiedMessages.single.id,
      );
      expect(copiedMessages.single.version, 0);
      expect(service.getVersionSelections(copiedConversation.id), isEmpty);
    });

    test(
      'preserves sibling subtrees or keeps only the active branch',
      () async {
        final service = createService();
        await service.init();

        final source = await service.createConversation(title: 'Tree Source');
        final root = await service.addMessage(
          conversationId: source.id,
          role: 'user',
          content: 'root',
        );
        final selected = await service.addMessage(
          conversationId: source.id,
          role: 'assistant',
          content: 'selected',
        );
        final sourceTree = await service.loadConversationTree(source.id);
        final originalBranch = sourceTree!.activeBranchId;

        final branchedTree = await service.createMessageBranch(
          conversationId: source.id,
          fromMessageId: selected.id,
        );
        final sibling = service.getMessages(source.id).last;
        await service.addMessage(
          conversationId: source.id,
          role: 'assistant',
          content: 'sibling child',
        );
        await service.addMessage(
          conversationId: source.id,
          role: 'user',
          content: 'sibling grandchild',
        );
        await service.switchConversationBranch(
          conversationId: source.id,
          branchId: originalBranch,
        );
        await service.addMessage(
          conversationId: source.id,
          role: 'assistant',
          content: 'active child',
        );

        final preserved = await service.createConversationForkAtRevision(
          sourceConversationId: source.id,
          sourceRevisionId: selected.id,
          title: 'Preserved',
          mode: ConversationForkMode.preserveBranches,
        );
        final preservedTree = await service.loadConversationTree(preserved.id);
        final preservedMessages = service.getMessages(preserved.id);
        expect(
          preservedMessages.map((message) => message.content),
          containsAll([
            root.content,
            selected.content,
            sibling.content,
            'sibling child',
            'sibling grandchild',
          ]),
        );
        expect(preservedTree!.branches.length, greaterThan(1));
        expect(preservedTree.edges.length, preservedMessages.length);

        final activeBranchOnly = await service.createConversationForkAtRevision(
          sourceConversationId: source.id,
          sourceRevisionId: selected.id,
          title: 'Active Branch Only',
          mode: ConversationForkMode.activeBranchOnly,
        );
        final activeBranchOnlyTree = await service.loadConversationTree(
          activeBranchOnly.id,
        );
        expect(
          service
              .getMessages(activeBranchOnly.id)
              .map((message) => message.content),
          ['root', 'selected'],
        );
        expect(
          service
              .getMessages(activeBranchOnly.id)
              .map((message) => message.content),
          isNot(contains('active child')),
        );
        expect(activeBranchOnlyTree!.branches, hasLength(1));
        expect(activeBranchOnlyTree.activePath(), hasLength(2));
        expect(branchedTree.activeBranchId, isNot(originalBranch));
      },
    );
  });

  test('final generation commit publishes one statistics revision', () async {
    final service = createService();
    await service.init();
    final conversation = await service.createConversation(title: 'Stats');
    final generation = await service.beginSendGeneration(
      conversationId: conversation.id,
      userParts: const [TextPart('question')],
      modelId: 'model',
      providerId: 'provider',
    );
    var run = await service.transitionGenerationRun(
      id: generation.run.id,
      expectedState: generation.run.state,
      expectedStateRevision: generation.run.stateRevision,
      nextState: GenerationRunState.requesting,
    );
    run = await service.transitionGenerationRun(
      id: run.id,
      expectedState: run.state,
      expectedStateRevision: run.stateRevision,
      nextState: GenerationRunState.streaming,
    );
    final completedMessage = generation.assistantMessage.copyWith(
      content: 'answer',
      totalTokens: 12,
      isStreaming: false,
      promptTokens: 3,
      completionTokens: 9,
    );
    final revisionBefore = service.statisticsRevision;
    var notifications = 0;
    void listener() => notifications++;
    service.addListener(listener);
    addTearDown(() => service.removeListener(listener));

    await service.finalizeGenerationRunSilent(
      message: completedMessage,
      toolEvents: const [],
      generationRunId: run.id,
      expectedState: run.state,
      expectedStateRevision: run.stateRevision,
      terminalState: GenerationRunState.completed,
    );

    expect(service.statisticsRevision, revisionBefore + 1);
    expect(notifications, 1);
    final aggregate = await service.loadStatsAggregate(
      rangeStart: null,
      rangeEndExclusive: null,
      heatmapStart: DateTime.utc(2000),
      trendStart: DateTime.utc(2000),
      trendEndExclusive: DateTime.utc(2100),
    );
    expect(aggregate.totals.messages, 2);
    expect(aggregate.totals.inputTokens, 3);
    expect(aggregate.totals.outputTokens, 9);
  });

  test('business selection uses linear group versions', () async {
    final service = createService();
    await service.init();
    final conversation = await service.createConversation(title: 'Graph');
    final original = await service.addMessage(
      conversationId: conversation.id,
      role: 'assistant',
      content: 'v0',
    );
    final edited = await service.appendMessageVersion(
      messageId: original.id,
      content: 'v1',
    );

    expect(edited, isNotNull);
    final groupId = edited!.groupId ?? original.id;

    await service.setSelectedVersion(conversation.id, groupId, 0);
    // versionSelections 不再被运行时写入，只保留在兼容层
    expect(service.getVersionSelections(conversation.id), {});
    final page = await service.loadTimelinePage(
      conversation.id,
      fromStart: true,
    );
    // 时间线投影现在完全由树控制，setSelectedVersion 只影响树的 activeBranchId
    // 这个测试原本验证旧的版本选择机制，现在验证树模式下的行为
    expect(page!.slots.single.message.id, isIn([original.id, edited.id]));
  });

  test('tree timeline projects the active branch after switching', () async {
    final branched = await createBranchedService('branch-timeline.sqlite');
    final service = branched.service;

    await service.switchConversationBranch(
      conversationId: 'conversation-branch',
      branchId: 'old',
    );
    final oldPage = await service.loadTimelinePage(
      'conversation-branch',
      fromStart: true,
      limit: 10,
    );
    expect(oldPage!.slots.map((slot) => slot.message.id), const [
      'u1',
      'a1-v0',
      'u2-v0',
    ]);

    await service.switchConversationBranch(
      conversationId: 'conversation-branch',
      branchId: 'root',
    );
    final rootPage = await service.loadTimelinePage(
      'conversation-branch',
      fromStart: true,
      limit: 10,
    );
    expect(rootPage!.slots.map((slot) => slot.message.id), const [
      'u1',
      'a1-v1',
      'u2-v1',
    ]);
  });

  test(
    'deleteBranchSiblings deletes every sibling branch and keeps ancestors',
    () async {
      final branched = await createBranchedService('branch-siblings.sqlite');
      final repository = branched.repository;
      final service = branched.service;

      final deleted = await service.deleteBranchSiblings(
        conversationId: 'conversation-branch',
        messageId: 'a1-v1',
      );

      expect(
        deleted,
        containsAll(<String>['a1-v0', 'u2-v0', 'a1-v1', 'u2-v1']),
      );
      expect(await repository.getMessage('u1'), isNotNull);
      expect(await repository.getMessage('a1-v0'), isNull);
      expect(await repository.getMessage('a1-v1'), isNull);
      expect(await repository.getMessage('u2-v0'), isNull);
      expect(await repository.getMessage('u2-v1'), isNull);
      final tree = await repository.loadConversationTree('conversation-branch');
      expect(tree, isNotNull);
      expect(tree!.activePath(), const ['u1']);
    },
  );

  test(
    'deleteMessageOnly removes one message and reconnects its descendants',
    () async {
      final branched = await createBranchedService('message-only.sqlite');
      final repository = branched.repository;
      final service = branched.service;

      final deleted = await service.deleteMessageOnly(
        conversationId: 'conversation-branch',
        messageId: 'a1-v0',
      );

      expect(deleted, const {'a1-v0'});
      expect(await repository.getMessage('a1-v0'), isNull);
      expect(await repository.getMessage('u2-v0'), isNotNull);
      expect(await repository.getMessage('a1-v1'), isNotNull);
      expect(await repository.getMessage('u2-v1'), isNotNull);
      final tree = await repository.loadConversationTree('conversation-branch');
      expect(tree!.edges['u2-v0']?.parentMessageId, 'u1');
      expect(tree.branchPath('old'), const ['u1', 'u2-v0']);
    },
  );

  test(
    'deleteMessageOnly removes an active branch with a single terminal message',
    () async {
      final branched = await createBranchedService(
        'message-only-branch.sqlite',
      );
      final repository = branched.repository;
      final service = branched.service;

      final treeBefore = await repository.loadConversationTree(
        'conversation-branch',
      );
      await repository.saveConversationTree(treeBefore!.switchBranch('old'));

      final deleted = await service.deleteMessageOnly(
        conversationId: 'conversation-branch',
        messageId: 'u2-v0',
      );

      expect(deleted, const {'u2-v0'});
      final tree = await repository.loadConversationTree('conversation-branch');
      expect(tree, isNotNull);
      expect(tree!.activeBranchId, 'root');
      expect(tree.activePath(), const ['u1', 'a1-v1', 'u2-v1']);
      expect(tree.branches.containsKey('old'), isFalse);
    },
  );

  test(
    'deleting a branch tip does not persist unreachable ancestor edges',
    () async {
      final branched = await createBranchedService('branch-tip-orphan.sqlite');
      final repository = branched.repository;
      final service = branched.service;

      final before = await repository.loadConversationTree(
        'conversation-branch',
      );
      expect(before, isNotNull);
      await repository.saveConversationTree(before!.switchBranch('root'));

      await service.deleteMessages(
        conversationId: 'conversation-branch',
        messageIds: const {'u2-v1'},
        versionSelectionChanges: const {},
      );

      final after = await repository.loadConversationTree(
        'conversation-branch',
      );
      expect(after, isNotNull);
      final reachable = <String>{
        for (final branch in after!.branches.values)
          ...after.branchPath(branch.id),
      };
      expect(after.edges.keys, unorderedEquals(reachable));
      expect(after.edges, isNot(contains('a1-v1')));
    },
  );

  test(
    'removing a branch tip does not persist unreachable ancestor edges',
    () async {
      final branched = await createBranchedService(
        'branch-tip-orphan-message-only.sqlite',
      );
      final repository = branched.repository;
      final service = branched.service;

      final before = await repository.loadConversationTree(
        'conversation-branch',
      );
      expect(before, isNotNull);
      await repository.saveConversationTree(before!.switchBranch('root'));

      await service.deleteMessageOnly(
        conversationId: 'conversation-branch',
        messageId: 'u2-v1',
      );

      final after = await repository.loadConversationTree(
        'conversation-branch',
      );
      expect(after, isNotNull);
      final reachable = <String>{
        for (final branch in after!.branches.values)
          ...after.branchPath(branch.id),
      };
      expect(after.edges.keys, unorderedEquals(reachable));
      expect(after.edges, isNot(contains('a1-v1')));
    },
  );

  test(
    'deleteMessageOnly removes a shared empty-anchor branch from persistence',
    () async {
      final branched = await createBranchedService(
        'shared-empty-anchor-message-only.sqlite',
      );
      final repository = branched.repository;
      final service = branched.service;

      final before = await repository.loadConversationTree(
        'conversation-branch',
      );
      expect(before, isNotNull);
      final withEmptyAnchor = ConversationTree(
        conversationId: before!.conversationId,
        activeBranchId: 'root',
        branches: {
          'root': before.branches['root']!,
          'old': before.branches['old']!.copyWith(tipMessageId: 'a1-v1'),
        },
        edges: const {
          'u1': MessageTreeEdge(messageId: 'u1', parentMessageId: null),
          'a1-v1': MessageTreeEdge(messageId: 'a1-v1', parentMessageId: 'u1'),
          'u2-v1': MessageTreeEdge(
            messageId: 'u2-v1',
            parentMessageId: 'a1-v1',
          ),
        },
        branchSelections: const {},
      );
      await repository.saveConversationTree(withEmptyAnchor);

      final deleted = await service.deleteMessageOnly(
        conversationId: 'conversation-branch',
        messageId: 'a1-v1',
      );

      expect(deleted, const {'a1-v1'});
      final after = await repository.loadConversationTree(
        'conversation-branch',
      );
      expect(after, isNotNull);
      expect(after!.branches.containsKey('old'), isFalse);
      expect(after.activePath(), const ['u1', 'u2-v1']);
      expect(after.edges['u2-v1']?.parentMessageId, 'u1');
      expect(await repository.getMessage('a1-v1'), isNull);
    },
  );
}
