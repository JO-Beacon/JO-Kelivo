import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/models/chat_input_data.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/chat/utils/message_attachment_parser.dart';

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

  group('MessageAttachmentParser', () {
    test('keeps plain text without attachments unchanged', () {
      final parsed = MessageAttachmentParser.parse('hello\nworld');

      expect(parsed.text, 'hello\nworld');
      expect(parsed.imagePaths, isEmpty);
      expect(parsed.documents, isEmpty);
      expect(parsed.toContent(), 'hello\nworld');
    });

    test('parses image markers and rebuilds compatible content', () {
      final parsed = MessageAttachmentParser.parse(
        'see this\n[image:C:/tmp/a.png]\n[image:/tmp/b.webp]',
      );

      expect(parsed.text, 'see this');
      expect(parsed.imagePaths, ['C:/tmp/a.png', '/tmp/b.webp']);
      expect(
        parsed.toContent(),
        'see this\n[image:C:/tmp/a.png]\n[image:/tmp/b.webp]',
      );
    });

    test('parses file markers and rebuilds compatible content', () {
      final parsed = MessageAttachmentParser.parse(
        'read this\n[file:/tmp/a.pdf|a.pdf|application/pdf]',
      );

      expect(parsed.text, 'read this');
      expect(parsed.documents, hasLength(1));
      expect(parsed.documents.single.path, '/tmp/a.pdf');
      expect(parsed.documents.single.fileName, 'a.pdf');
      expect(parsed.documents.single.mime, 'application/pdf');
      expect(
        parsed.toContent(),
        'read this\n[file:/tmp/a.pdf|a.pdf|application/pdf]',
      );
    });

    test('parses mixed attachments and allows removing an attachment', () {
      final parsed = MessageAttachmentParser.parse(
        'mixed\n[image:/tmp/a.png]\n[file:/tmp/a.txt|a.txt|text/plain]',
      );

      final content = MessageAttachmentParser.buildContent(
        text: parsed.text,
        imagePaths: const [],
        documents: parsed.documents,
      );

      expect(content, 'mixed\n[file:/tmp/a.txt|a.txt|text/plain]');
    });

    test('builds content from structured edit result data', () {
      final content = MessageAttachmentParser.buildContent(
        text: 'updated',
        imagePaths: const ['/tmp/new.png'],
        documents: const [
          DocumentAttachment(
            path: '/tmp/new.pdf',
            fileName: 'new.pdf',
            mime: 'application/pdf',
          ),
        ],
      );

      expect(
        content,
        'updated\n[image:/tmp/new.png]\n[file:/tmp/new.pdf|new.pdf|application/pdf]',
      );
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

        final editedContent = MessageAttachmentParser.buildContent(
          text: 'first edited',
          imagePaths: const ['/tmp/edited.png'],
          documents: const [
            DocumentAttachment(
              path: '/tmp/edited.pdf',
              fileName: 'edited.pdf',
              mime: 'application/pdf',
            ),
          ],
        );
        final edited = await service.appendMessageVersion(
          messageId: first.id,
          content: editedContent,
        );

        expect(edited, isNotNull);
        expect(service.getConversation(conversation.id)!.messageIds, [
          first.id,
          edited!.id,
          second.id,
          third.id,
        ]);
        expect(service.getMessages(conversation.id).map((m) => m.id), [
          first.id,
          edited.id,
          second.id,
          third.id,
        ]);
        expect(edited.content, editedContent);
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
        expect(service.getMessages(conversation.id).map((m) => m.id), [
          firstUser.id,
          firstAssistant.id,
          regenerated.id,
          secondUser.id,
          secondAssistant.id,
        ]);
      },
    );

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
