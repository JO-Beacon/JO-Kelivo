import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/controllers/chat_controller.dart';

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
      'kelivo_complete_history_sqlite_test_',
    );
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ChatService createService() {
    final service = ChatService();
    services.add(service);
    return service;
  }

  test(
    'complete-history mode pages through a cold SQLite conversation',
    () async {
      final writer = createService();
      await writer.init();
      final conversation = await writer.createConversation(title: 'Long chat');
      final ids = <String>[];
      for (var index = 0; index < 900; index++) {
        final message = await writer.addMessage(
          conversationId: conversation.id,
          role: index.isEven ? 'user' : 'assistant',
          content: 'message $index',
        );
        ids.add(message.id);
      }
      await writer.close();
      services.remove(writer);

      final reader = createService();
      await reader.init();
      final persistedConversation = reader.getConversation(conversation.id)!;
      final controller = ChatController(
        chatService: reader,
        lazyHistoryEnabled: false,
      );
      addTearDown(controller.dispose);

      await controller.setCurrentConversationAndLoad(persistedConversation);

      expect(
        controller.messages.map((message) => message.id),
        orderedEquals(ids),
      );
      expect(controller.loadedStartIndex, 0);
      expect(controller.totalMessageCount, 900);
      expect(controller.hasMoreBefore, isFalse);
      expect(controller.hasMoreAfter, isFalse);

      await controller.setLazyHistoryEnabled(true);
      expect(
        controller.messages,
        hasLength(ChatService.defaultLoadedWindowMax),
      );
      expect(controller.messages.first.id, ids[540]);
      expect(controller.messages.last.id, ids.last);
      expect(controller.loadedStartIndex, 540);
      expect(controller.hasMoreBefore, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
