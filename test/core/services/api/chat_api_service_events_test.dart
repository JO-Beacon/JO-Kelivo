import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_provider.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';

ProviderConfig _config(
  String baseUrl, {
  ProviderKind kind = ProviderKind.openai,
  String modelId = 'gpt-events-test',
}) {
  return ProviderConfig(
    id: '${kind.name}EventsTest',
    enabled: true,
    name: '${kind.name}EventsTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: kind,
    models: [modelId],
    modelOverrides: {
      modelId: {
        'type': 'chat',
        'input': ['text'],
        'output': ['text'],
      },
    },
  );
}

class _VertexClaudeClient extends http.BaseClient {
  late http.Request request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request as http.Request;
    final events = [
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text', 'text': ''},
      },
      {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'vertex hello'},
      },
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {'input_tokens': 2, 'output_tokens': 3},
      },
      {'type': 'message_stop'},
    ];
    final payload = StringBuffer();
    for (final event in events) {
      payload
        ..write('event: ${event['type']}\n')
        ..write('data: ${jsonEncode(event)}\n\n');
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(payload.toString())),
      200,
      headers: const {'content-type': 'text/event-stream'},
    );
  }
}

void main() {
  test('OpenAI event entry decodes text and terminal SSE events', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/v1/chat/completions');
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'hello'},
            },
          ],
        })}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });

    final events = await ChatApiService.sendMessageStreamEvents(
      config: _config('http://${server.address.address}:${server.port}/v1'),
      modelId: 'gpt-events-test',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
    ).toList();

    expect(events.whereType<TextDelta>().map((event) => event.text), ['hello']);
    expect(events.whereType<Finish>(), hasLength(1));
  });

  test('Claude event entry decodes Messages SSE text and finish', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/messages');
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      final events = [
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'hello'},
        },
        {'type': 'message_stop'},
      ];
      for (final event in events) {
        request.response.write('event: ${event['type']}\n');
        request.response.write('data: ${jsonEncode(event)}\n\n');
      }
      await request.response.close();
    });

    final events = await ChatApiService.sendMessageStreamEvents(
      config: _config(
        'http://${server.address.address}:${server.port}',
        kind: ProviderKind.claude,
        modelId: 'claude-events-test',
      ),
      modelId: 'claude-events-test',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
    ).toList();

    expect(events.whereType<TextDelta>().map((event) => event.text), ['hello']);
    expect(events.whereType<Finish>(), hasLength(1));
  });

  test(
    'Gemini event entry decodes streamGenerateContent SSE text and finish',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(
          request.uri.path,
          '/models/gemini-events-test:streamGenerateContent',
        );
        expect(request.uri.queryParameters['alt'], 'sse');
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
                    {'text': 'hello'},
                  ],
                  'role': 'model',
                },
              },
            ],
          })}\n\n',
        );
        request.response.write(
          'data: ${jsonEncode({
            'candidates': [
              {
                'finishReason': 'STOP',
                'content': {'parts': []},
              },
            ],
          })}\n\n',
        );
        await request.response.close();
      });

      final events = await ChatApiService.sendMessageStreamEvents(
        config: _config(
          'http://${server.address.address}:${server.port}',
          kind: ProviderKind.google,
          modelId: 'gemini-events-test',
        ),
        modelId: 'gemini-events-test',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(events.whereType<TextDelta>().map((event) => event.text), [
        'hello',
      ]);
      expect(events.whereType<Finish>(), hasLength(1));
    },
  );

  test(
    'Vertex Gemini event entry uses the provider-independent sender',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(
          request.uri.path,
          '/models/gemini-vertex-events-test:streamGenerateContent',
        );
        expect(request.uri.queryParameters['alt'], 'sse');
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
                    {'text': 'vertex hello'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
          })}\n\n',
        );
        await request.response.close();
      });

      final config = _config(
        'http://${server.address.address}:${server.port}',
        kind: ProviderKind.google,
        modelId: 'gemini-vertex-events-test',
      ).copyWith(vertexAI: true, location: '', projectId: '');
      final events = await ChatApiService.sendMessageStreamEvents(
        config: config,
        modelId: 'gemini-vertex-events-test',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(events.whereType<TextDelta>().map((event) => event.text), [
        'vertex hello',
      ]);
      expect(events.whereType<Finish>(), hasLength(1));
    },
  );

  test(
    'Vertex Claude event sender uses streamRawPredict endpoint and auth',
    () async {
      final client = _VertexClaudeClient();
      addTearDown(client.close);
      final config = ProviderConfig(
        id: 'VertexClaudeEventsTest',
        enabled: true,
        name: 'VertexClaudeEventsTest',
        apiKey: 'vertex-token',
        baseUrl: 'https://unused.invalid',
        providerType: ProviderKind.google,
        vertexAI: true,
        location: 'us-central1',
        projectId: 'test-project',
        models: const ['claude-sonnet-4@20250514'],
        modelOverrides: const {
          'claude-sonnet-4@20250514': {
            'type': 'chat',
            'input': ['text'],
            'output': ['text'],
          },
        },
      );
      final events = await sendClaudeStreamEvents(
        client,
        config,
        'claude-sonnet-4@20250514',
        const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList();

      expect(client.request.url.host, 'us-central1-aiplatform.googleapis.com');
      expect(
        client.request.url.path,
        '/v1/projects/test-project/locations/us-central1/publishers/anthropic/models/claude-sonnet-4@20250514:streamRawPredict',
      );
      expect(client.request.headers['authorization'], 'Bearer vertex-token');
      final body = jsonDecode(client.request.body) as Map<String, dynamic>;
      expect(body['anthropic_version'], 'vertex-2023-10-16');
      expect(body.containsKey('model'), isFalse);
      expect(events.whereType<TextDelta>().map((event) => event.text), [
        'vertex hello',
      ]);
      expect(events.whereType<Usage>().last.usage.totalTokens, 5);
      expect(events.whereType<Finish>(), hasLength(1));
    },
  );

  test('OpenAI Images event entry emits an image series and finish', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/images/generations');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            {'url': 'https://example.test/generated.png'},
          ],
        }),
      );
      await request.response.close();
    });

    final events = await ChatApiService.sendMessageStreamEvents(
      config: _config(
        'http://${server.address.address}:${server.port}',
        modelId: 'gpt-image-events-test',
      ),
      modelId: 'gpt-image-events-test',
      messages: const [
        {'role': 'user', 'content': 'draw a test image'},
      ],
    ).toList();

    expect(events.whereType<ImageStart>(), hasLength(1));
    expect(
      events.whereType<ImageSnapshot>().single.data,
      'https://example.test/generated.png',
    );
    expect(events.whereType<ImageEnd>(), hasLength(1));
    expect(events.whereType<Finish>(), hasLength(1));
  });

  test('GLM-OCR event entry emits markdown text and finish', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/layout_parsing');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'md_results': '# parsed',
          'usage': {'total_tokens': 3},
        }),
      );
      await request.response.close();
    });

    final client = http.Client();
    addTearDown(client.close);
    final events = await sendZhipuLayoutParsingEvents(
      client,
      ProviderConfig(
        id: 'ZhipuEventsTest',
        enabled: true,
        name: 'ZhipuEventsTest',
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.address}:${server.port}',
        providerType: ProviderKind.google,
        models: const ['glm-ocr'],
      ),
      'glm-ocr',
      const [
        {'role': 'user', 'content': 'data:image/png;base64,aGVsbG8='},
      ],
    ).toList();

    expect(events.whereType<TextDelta>().map((event) => event.text), [
      '# parsed',
    ]);
    expect(events.whereType<Usage>().single.usage.totalTokens, 3);
    expect(events.whereType<Finish>(), hasLength(1));
  });
}
