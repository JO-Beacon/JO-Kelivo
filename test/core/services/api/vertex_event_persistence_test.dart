import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk_handler.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';

void main() {
  late Directory root;
  late ChatDatabaseRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('vertex_event_persistence_');
    repository = ChatDatabaseRepository.open(
      file: File('${root.path}/chat.sqlite'),
    );
    await repository.ensureReady();
  });

  tearDown(() async {
    await repository.close();
    await root.delete(recursive: true);
  });

  test(
    'Vertex Gemini events fold into parts and survive SQLite round-trip',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(
          request.uri.path,
          '/models/gemini-persist-test:streamGenerateContent',
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'thought': true, 'text': 'reasoning'},
                    {'text': 'answer'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
            'usageMetadata': {'promptTokenCount': 4, 'candidatesTokenCount': 6, 'totalTokenCount': 10},
          })}\n\n',
        );
        await request.response.close();
      });

      final modelId = 'gemini-persist-test';
      final config = ProviderConfig(
        id: 'VertexPersistenceTest',
        enabled: true,
        name: 'VertexPersistenceTest',
        apiKey: 'vertex-token',
        baseUrl: 'http://${server.address.address}:${server.port}',
        providerType: ProviderKind.google,
        vertexAI: true,
        location: '',
        projectId: '',
        models: [modelId],
        modelOverrides: {
          modelId: {
            'type': 'chat',
            'input': ['text'],
            'output': ['text'],
          },
        },
      );
      final events = await ChatApiService.sendMessageStreamEvents(
        config: config,
        modelId: modelId,
        messages: const [
          {'role': 'user', 'content': 'persist this'},
        ],
      ).toList();
      final result = StreamChunkHandler.collect(events);

      expect(result.parts, hasLength(2));
      expect(result.parts[0], isA<ReasoningPart>());
      expect((result.parts[0] as ReasoningPart).text, 'reasoning');
      expect(result.parts[1], isA<TextPart>());
      expect((result.parts[1] as TextPart).text, 'answer');
      expect(result.usage?.promptTokens, 4);
      expect(result.usage?.completionTokens, 6);
      expect(result.usage?.totalTokens, 10);
      expect(events.whereType<Finish>(), hasLength(1));

      final now = DateTime.utc(2026, 8, 27, 12);
      const conversationId = 'vertex-persistence-conversation';
      const messageId = 'vertex-persistence-message';
      final message = ChatMessage(
        id: messageId,
        role: 'assistant',
        conversationId: conversationId,
        timestamp: now,
        parts: result.parts,
        reasoningText: result.parts
            .whereType<ReasoningPart>()
            .map((part) => part.text)
            .join(),
        promptTokens: result.usage?.promptTokens,
        completionTokens: result.usage?.completionTokens,
        totalTokens: result.usage?.totalTokens,
      );
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: conversationId,
            title: 'Vertex persistence',
            createdAt: now,
            updatedAt: now,
            messageIds: const [messageId],
          ),
        ],
        messages: [(message: message, messageOrder: 0)],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );

      final restored = await repository.getMessage(messageId);
      expect(restored, isNotNull);
      expect(restored!.parts, hasLength(2));
      expect(restored.parts[0], isA<ReasoningPart>());
      expect((restored.parts[0] as ReasoningPart).text, 'reasoning');
      expect(restored.parts[1], isA<TextPart>());
      expect((restored.parts[1] as TextPart).text, 'answer');
      expect(restored.content, 'answer');
      expect(restored.reasoningText, 'reasoning');
      expect(restored.promptTokens, 4);
      expect(restored.completionTokens, 6);
      expect(restored.totalTokens, 10);
    },
  );

  test('Vertex Gemini HTTP errors remain visible to the caller', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.badGateway
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'vertex unavailable'}));
      await request.response.close();
    });

    const modelId = 'gemini-error-test';
    final config = ProviderConfig(
      id: 'VertexErrorTest',
      enabled: true,
      name: 'VertexErrorTest',
      apiKey: 'vertex-token',
      baseUrl: 'http://${server.address.address}:${server.port}',
      providerType: ProviderKind.google,
      vertexAI: true,
      location: '',
      projectId: '',
      models: [modelId],
    );

    expect(
      () => ChatApiService.sendMessageStreamEvents(
        config: config,
        modelId: modelId,
        messages: const [
          {'role': 'user', 'content': 'fail'},
        ],
      ).toList(),
      throwsA(isA<HttpException>()),
    );
  });
}
