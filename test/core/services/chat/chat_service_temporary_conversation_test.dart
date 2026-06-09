import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/services/chat/chat_service.dart';

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

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_chat_service_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ChatService temporary conversations', () {
    test('ordinary draft persists when its first message is added', () async {
      final service = ChatService();
      await service.init();

      final conversation = await service.createDraftConversation(title: 'Chat');
      await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'hello',
      );

      expect(service.getAllConversations().map((c) => c.id), [conversation.id]);
      expect(service.getMessages(conversation.id), hasLength(1));
    });

    test(
      'temporary draft keeps messages in memory without entering history',
      () async {
        final service = ChatService();
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
        final service = ChatService();
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
      'temporary conversation is discarded when current conversation changes',
      () async {
        final service = ChatService();
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
      },
    );

    test('temporary message deletion only affects memory', () async {
      final service = ChatService();
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

      await service.deleteMessage(message.id);

      expect(service.getAllConversations(), isEmpty);
      expect(service.getMessages(conversation.id), isEmpty);
      expect(service.getConversation(conversation.id)?.messageIds, isEmpty);
    });
  });

  group('ChatService message version ordering', () {
    test(
      'edited message version is inserted next to its original group',
      () async {
        final service = ChatService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Chat',
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
        final third = await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'third',
        );

        final edited = await service.appendMessageVersion(
          messageId: first.id,
          content: 'first edited',
        );

        expect(edited, isNotNull);
        expect(service.getConversation(conversation.id)!.messageIds, [
          first.id,
          edited!.id,
          second.id,
          third.id,
        ]);
        expect(
          service.getMessages(conversation.id).map((message) => message.id),
          [first.id, edited.id, second.id, third.id],
        );
        expect(service.getVersionSelections(conversation.id), {
          first.id: edited.version,
        });
      },
    );

    test(
      'regenerated assistant version is inserted next to its group',
      () async {
        final service = ChatService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Chat',
        );
        final firstUser = await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'first user',
        );
        final firstAssistant = await service.addMessage(
          conversationId: conversation.id,
          role: 'assistant',
          content: 'first assistant',
        );
        final secondUser = await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'second user',
        );
        final secondAssistant = await service.addMessage(
          conversationId: conversation.id,
          role: 'assistant',
          content: 'second assistant',
        );

        final regenerated = await service.addMessage(
          conversationId: conversation.id,
          role: 'assistant',
          content: '',
          groupId: firstAssistant.id,
          version: 1,
          isStreaming: true,
        );

        expect(service.getConversation(conversation.id)!.messageIds, [
          firstUser.id,
          firstAssistant.id,
          regenerated.id,
          secondUser.id,
          secondAssistant.id,
        ]);
        expect(
          service.getMessages(conversation.id).map((message) => message.id),
          [
            firstUser.id,
            firstAssistant.id,
            regenerated.id,
            secondUser.id,
            secondAssistant.id,
          ],
        );
      },
    );

    test('ordinary new message is still appended to the tail', () async {
      final service = ChatService();
      await service.init();

      final conversation = await service.createDraftConversation(title: 'Chat');
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
      final ordinary = await service.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'ordinary tail message',
      );

      expect(service.getConversation(conversation.id)!.messageIds, [
        first.id,
        second.id,
        ordinary.id,
      ]);
    });

    test(
      'versioned message falls back to tail when group anchor is missing',
      () async {
        final service = ChatService();
        await service.init();

        final conversation = await service.createDraftConversation(
          title: 'Chat',
        );
        final first = await service.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'first',
        );
        final orphanVersion = await service.addMessage(
          conversationId: conversation.id,
          role: 'assistant',
          content: '',
          groupId: 'missing-group',
          version: 1,
        );

        expect(service.getConversation(conversation.id)!.messageIds, [
          first.id,
          orphanVersion.id,
        ]);
      },
    );
  });
}
