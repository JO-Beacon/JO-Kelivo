import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
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

/// 上下文修订号的契约：进入模型上下文的结构变了就前进，
/// 纯流式增量、用量回填、重命名、置顶、建议都不算。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final services = <ChatService>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kelivo_context_revision_test_',
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

  Future<ChatService> createService() async {
    final service = ChatService();
    services.add(service);
    await service.init();
    return service;
  }

  Future<void> expectChanged(
    ChatService chat,
    String conversationId,
    Future<void> Function() action,
  ) async {
    final before = chat.contextRevision(conversationId);
    await action();
    expect(
      chat.contextRevision(conversationId),
      greaterThan(before),
      reason: '这一步改变了进入模型上下文的结构，修订号必须前进',
    );
  }

  Future<void> expectUnchanged(
    ChatService chat,
    String conversationId,
    Future<void> Function() action,
  ) async {
    final before = chat.contextRevision(conversationId);
    await action();
    expect(
      chat.contextRevision(conversationId),
      before,
      reason: '这一步不改变进入模型上下文的结构，修订号必须原地不动',
    );
  }

  test('结构化改动推进修订号，流式与展示类改动不推进', () async {
    final chat = await createService();
    final conversation = await chat.createConversation(title: 'Rev');
    final id = conversation.id;
    expect(chat.contextRevision(id), 0);

    late ChatMessage first;
    await expectChanged(chat, id, () async {
      first = await chat.addMessage(
        conversationId: id,
        role: 'user',
        content: 'hello',
      );
    });

    await expectChanged(chat, id, () async {
      await chat.addMessageDirectly(
        id,
        ChatMessage(role: 'user', content: 'direct', conversationId: id),
      );
    });

    await expectChanged(chat, id, () async {
      await chat.setConversationMcpServers(id, const ['mcp-1']);
    });

    await expectChanged(chat, id, () async {
      await chat.updateConversationSummary(id, 'sum', 1);
    });

    await expectChanged(chat, id, () async {
      await chat.clearConversationSummary(id);
    });

    await expectChanged(chat, id, () async {
      await chat.updateConversationExtras(id, (extras) {
        extras['note'] = 'x';
        return extras;
      });
    });

    await expectChanged(chat, id, () async {
      await chat.updateMessage(first.id, content: 'hello edited');
    });

    await expectChanged(chat, id, () async {
      await chat.appendMessageVersion(messageId: first.id, content: 'hello v2');
    });

    await expectChanged(chat, id, () async {
      await chat.setConversationModel(
        id,
        providerKey: 'openai',
        modelId: 'gpt-test',
      );
    });

    await expectChanged(chat, id, () async {
      await chat.clearConversationModelOverrides(providerKey: 'openai');
    });

    await expectChanged(chat, id, () async {
      await chat.toggleTruncateAtTail(id);
    });

    await expectChanged(chat, id, () async {
      await chat.moveConversationToAssistant(
        conversationId: id,
        assistantId: 'assistant-b',
      );
    });

    final extra = await chat.addMessage(
      conversationId: id,
      role: 'user',
      content: 'to delete',
    );
    await expectChanged(chat, id, () async {
      await chat.deleteMessage(extra.id);
    });

    await expectUnchanged(chat, id, () async {
      await chat.updateMessageSilent(first.id, content: 'streaming delta');
    });

    await expectUnchanged(chat, id, () async {
      await chat.updateMessage(
        first.id,
        promptTokens: 12,
        completionTokens: 3,
        cachedTokens: 1,
        totalTokens: 15,
      );
    });

    await expectUnchanged(chat, id, () async {
      await chat.updateMessage(first.id, reasoningStartAt: DateTime.now());
    });

    await expectUnchanged(chat, id, () async {
      await chat.updateStreamingCheckpointSilent(
        first.copyWith(content: 'checkpoint'),
        const [],
      );
    });

    await expectUnchanged(chat, id, () async {
      await chat.renameConversation(id, 'Renamed');
    });

    await expectUnchanged(chat, id, () async {
      await chat.togglePinConversation(id);
    });

    await expectUnchanged(chat, id, () async {
      await chat.updateConversationSuggestions(id, const ['one']);
    });

    await expectUnchanged(chat, id, () async {
      chat.setCurrentConversation(id);
    });
  });

  test('修订号监听只通知对应会话', () async {
    final chat = await createService();
    final first = await chat.createConversation(title: 'A');
    final second = await chat.createConversation(title: 'B');
    var firstTicks = 0;
    var secondTicks = 0;
    chat.contextRevisionListenable(first.id).addListener(() => firstTicks++);
    chat.contextRevisionListenable(second.id).addListener(() => secondTicks++);

    await chat.addMessage(conversationId: first.id, role: 'user', content: 'a');

    expect(firstTicks, greaterThanOrEqualTo(1));
    expect(secondTicks, 0);
    expect(
      chat.contextRevisionListenable(first.id).value,
      chat.contextRevision(first.id),
    );
    expect(chat.contextRevision(second.id), 0);
  });
}
