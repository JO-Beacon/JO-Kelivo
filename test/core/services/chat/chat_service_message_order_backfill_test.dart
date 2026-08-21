import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/utils/app_directories.dart';

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

class _SpyChatDatabaseRepository extends ChatDatabaseRepository {
  _SpyChatDatabaseRepository(super.db, {super.databaseFile});

  int getMessageIdsCalls = 0;
  int getMessagesForGroupsCalls = 0;

  @override
  Future<List<String>> getMessageIds(String conversationId) async {
    getMessageIdsCalls += 1;
    return super.getMessageIds(conversationId);
  }

  @override
  Future<List<ChatMessage>> getMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async {
    getMessagesForGroupsCalls += 1;
    return super.getMessagesForGroups(conversationId, groupIds);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];
  final repositories = <_SpyChatDatabaseRepository>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_message_order_skeleton_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    for (final repository in repositories) {
      await repository.close();
    }
    repositories.clear();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ChatService createService({ChatDatabaseRepository? existingRepository}) {
    final service = ChatService(existingRepository: existingRepository);
    services.add(service);
    return service;
  }

  Future<File> databaseFile() async {
    final appDataDir = await AppDirectories.getAppDataDirectory();
    return File('${appDataDir.path}/${AppDatabase.databaseFileName}');
  }

  Future<_SpyChatDatabaseRepository> openSpyRepository() async {
    final file = await databaseFile();
    final spy = _SpyChatDatabaseRepository(
      AppDatabase.open(file: file),
      databaseFile: file,
    );
    await spy.ensureReady();
    repositories.add(spy);
    return spy;
  }

  Future<(String, List<String>)> seedConversation({
    int messageCount = 5,
  }) async {
    final writer = createService();
    await writer.init();
    final conversation = await writer.createConversation(title: 'Chat');
    final ids = <String>[];
    for (var i = 0; i < messageCount; i++) {
      final message = await writer.addMessage(
        conversationId: conversation.id,
        role: i.isEven ? 'user' : 'assistant',
        content: 'message $i',
      );
      ids.add(message.id);
    }
    await writer.close();
    services.remove(writer);
    return (conversation.id, ids);
  }

  test('loadTimelinePage installs the complete active-path skeleton', () async {
    final (conversationId, ids) = await seedConversation(messageCount: 6);
    final spy = await openSpyRepository();
    final service = createService(existingRepository: spy);
    await service.init();

    final page = await service.loadTimelinePage(conversationId, limit: 2);

    expect(page, isNotNull);
    expect(
      page!.slots.map((slot) => slot.message.id),
      orderedEquals(ids.sublist(4)),
    );
    expect(service.debugHasMessageOrderSkeleton(conversationId), isTrue);
    expect(service.debugMessageOrderSkeletonLength(conversationId), ids.length);
    expect(service.getMessageCount(conversationId), ids.length);
    expect(service.isConversationFullyCached(conversationId), isFalse);
    expect(spy.getMessageIdsCalls, 0);
  });

  test('paging does not perform a separate full message-id read', () async {
    final (conversationId, ids) = await seedConversation(messageCount: 8);
    final spy = await openSpyRepository();
    final service = createService(existingRepository: spy);
    await service.init();

    await service.loadTimelinePage(conversationId, limit: 3);
    await service.loadTimelinePage(
      conversationId,
      beforeRevisionId: ids[5],
      limit: 3,
    );
    await service.loadTimelinePage(
      conversationId,
      afterRevisionId: ids[1],
      limit: 3,
    );

    expect(spy.getMessageIdsCalls, 0);
    expect(service.debugMessageOrderSkeletonLength(conversationId), ids.length);
  });

  test(
    'loadMessagesForGroups caches bodies without creating an order skeleton',
    () async {
      final (conversationId, ids) = await seedConversation(messageCount: 4);
      final spy = await openSpyRepository();
      final service = createService(existingRepository: spy);
      await service.init();

      final messages = await service.loadMessagesForGroups(conversationId, [
        ids[1],
      ]);

      expect(messages.map((message) => message.id), contains(ids[1]));
      expect(spy.getMessagesForGroupsCalls, 1);
      expect(spy.getMessageIdsCalls, 0);
      expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
      expect(service.isMessageCountKnown(conversationId), isFalse);
    },
  );

  test(
    'branch switch replaces the skeleton with the new active path',
    () async {
      final writer = createService();
      await writer.init();
      final conversation = await writer.createConversation(title: 'Branches');
      final user = await writer.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'question',
      );
      final rootReply = await writer.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: 'root reply',
      );
      final forkTree = await writer.createConversationBranch(
        conversationId: conversation.id,
        fromMessageId: user.id,
      );
      final forkReply = await writer.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: 'fork reply',
      );
      await writer.close();
      services.remove(writer);

      final spy = await openSpyRepository();
      final service = createService(existingRepository: spy);
      await service.init();
      await service.loadTimelinePage(conversation.id);
      expect(
        service.getMessages(conversation.id).map((message) => message.id),
        orderedEquals([user.id, forkReply.id]),
      );

      final rootBranchId = forkTree.branches.values
          .singleWhere((branch) => branch.tipMessageId == rootReply.id)
          .id;
      await service.switchConversationBranch(
        conversationId: conversation.id,
        branchId: rootBranchId,
      );

      expect(service.debugMessageOrderSkeletonLength(conversation.id), 2);
      expect(
        service.getMessages(conversation.id).map((message) => message.id),
        orderedEquals([user.id, rootReply.id]),
      );
      expect(spy.getMessageIdsCalls, 0);
    },
  );

  test('deleting a conversation clears its order skeleton and count', () async {
    final (conversationId, ids) = await seedConversation(messageCount: 3);
    final service = createService();
    await service.init();
    await service.loadTimelinePage(conversationId);
    expect(service.debugMessageOrderSkeletonLength(conversationId), ids.length);

    await service.deleteConversation(conversationId);

    expect(service.debugHasMessageOrderSkeleton(conversationId), isFalse);
    expect(service.getMessageCount(conversationId), -1);
    expect(service.isMessageCountKnown(conversationId), isFalse);
  });

  test(
    'context mask follows the active branch after a branch switch',
    () async {
      final service = createService();
      await service.init();
      final conversation = await service.createConversation(title: 'Context');
      final user = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'question',
      );
      await service.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: 'root reply',
      );
      await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'follow-up',
      );
      await service.createConversationBranch(
        conversationId: conversation.id,
        fromMessageId: user.id,
      );
      final forkReply = await service.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: 'fork reply',
      );

      final tree = await service.loadConversationTree(conversation.id);
      expect(tree, isNotNull);
      final rootBranchId = tree!.branches.values
          .singleWhere((branch) => branch.tipMessageId != forkReply.id)
          .id;
      final forkBranchId = tree.activeBranchId;
      await service.switchConversationBranch(
        conversationId: conversation.id,
        branchId: rootBranchId,
      );
      await service.toggleTruncateAtTail(conversation.id);
      expect(service.getContextStartIndex(conversation.id), 3);

      await service.switchConversationBranch(
        conversationId: conversation.id,
        branchId: forkBranchId,
      );

      expect(service.getContextStartIndex(conversation.id), 2);
    },
  );
}
