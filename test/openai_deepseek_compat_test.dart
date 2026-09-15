import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/builtin_tools.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';

import 'support/collect_generation.dart';

ProviderConfig _deepSeekConfig(
  String baseUrl, {
  bool useResponseApi = false,
  Map<String, dynamic> modelOverrides = const <String, dynamic>{},
}) {
  return ProviderConfig(
    id: 'DeepSeekCompatTest',
    enabled: true,
    name: 'DeepSeekCompatTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    useResponseApi: useResponseApi,
    modelOverrides: modelOverrides,
  );
}

Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
  return jsonDecode(await utf8.decoder.bind(request).join())
      as Map<String, dynamic>;
}

Future<List<Map<String, dynamic>>> _collectToolOnlyContinuationRequests({
  required bool useEvents,
  bool deepSeek = true,
}) async {
  final requests = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });

  server.listen((request) async {
    requests.add(await _readJsonBody(request));
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    if (requests.length == 1) {
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_date',
                    'type': 'function',
                    'function': {'name': 'date', 'arguments': '{}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        })}\n\n',
      );
    } else {
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'role': 'assistant', 'content': '2026-08-29'},
              'finish_reason': 'stop',
            },
          ],
        })}\n\n',
      );
    }
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  });

  final baseUrl = 'http://${server.address.address}:${server.port}/v1';
  final modelId = deepSeek ? 'deepseek-v4-flash' : 'tool-only-model';
  final config = ProviderConfig(
    id: deepSeek ? 'DeepSeekCompatTest' : 'GenericCompatTest',
    enabled: true,
    name: deepSeek ? 'DeepSeekCompatTest' : 'GenericCompatTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    modelOverrides: {
      modelId: const {
        'abilities': ['tool'],
      },
    },
  );
  const messages = [
    {'role': 'user', 'content': 'What is the date?'},
  ];
  const tools = [
    {
      'type': 'function',
      'function': {
        'name': 'date',
        'description': 'Get the current date',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    },
  ];

  if (useEvents) {
    await ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      tools: tools,
      onToolCall: (_, __, {toolCallId}) async => '2026-08-29',
    ).toList();
  } else {
    await ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      tools: tools,
      onToolCall: (_, __, {toolCallId}) async => '2026-08-29',
    ).toList();
  }
  return requests;
}

void main() {
  group('DeepSeek OpenAI compatibility', () {
    test('Responses non-stream returns reasoning and cached tokens', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody = await _readJsonBody(request);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'resp-deepseek',
            'object': 'response',
            'status': 'completed',
            'output_text': '9.8 is greater.',
            'output': [
              {
                'id': 'reasoning-deepseek',
                'type': 'reasoning',
                'content': [
                  {
                    'type': 'reasoning_text',
                    'text': 'Compare the decimal values.',
                  },
                ],
              },
              {
                'id': 'message-deepseek',
                'type': 'message',
                'role': 'assistant',
                'status': 'completed',
                'content': [
                  {'type': 'output_text', 'text': '9.8 is greater.'},
                ],
              },
            ],
            'usage': {
              'input_tokens': 100,
              'input_tokens_details': {'cached_tokens': 64},
              'output_tokens': 30,
              'output_tokens_details': {'reasoning_tokens': 20},
              'total_tokens': 130,
            },
          }),
        );
        await request.response.close();
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      final chunks = await ChatApiService.sendMessageStream(
        config: _deepSeekConfig(baseUrl, useResponseApi: true),
        modelId: 'deepseek-v4-flash',
        messages: const [
          {'role': 'user', 'content': '9.11 and 9.8, which is greater?'},
        ],
        thinkingBudget: 2000,
        stream: false,
      ).toList();

      expect(requestBody['stream'], isFalse);
      expect(chunks.joinedContent, '9.8 is greater.');
      expect(chunks.joinedReasoning, 'Compare the decimal values.');
      expect(chunks.lastUsage?.promptTokens, 100);
      expect(chunks.lastUsage?.completionTokens, 30);
      expect(chunks.lastUsage?.cachedTokens, 64);
      expect(chunks.lastUsage?.totalTokens, 130);
    });

    test('Responses stream reports cached tokens without DONE event', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        await _readJsonBody(request);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'output': const [],
              'usage': {
                'input_tokens': 80,
                'input_tokens_details': {'cached_tokens': 48},
                'output_tokens': 12,
                'output_tokens_details': {'reasoning_tokens': 8},
                'total_tokens': 92,
              },
            },
          })}\n\n',
        );
        await request.response.close();
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      final chunks = await ChatApiService.sendMessageStream(
        config: _deepSeekConfig(baseUrl, useResponseApi: true),
        modelId: 'deepseek-v4-flash',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
      ).toList();

      expect(chunks.isGenerationDone, isTrue);
      expect(chunks.lastUsage?.promptTokens, 80);
      expect(chunks.lastUsage?.completionTokens, 12);
      expect(chunks.lastUsage?.cachedTokens, 48);
      expect(chunks.lastUsage?.totalTokens, 92);
    });

    test('Responses off reasoning sends effort none', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody = await _readJsonBody(request);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'resp-deepseek',
            'object': 'response',
            'status': 'completed',
            'output_text': 'ok',
            'output': const [],
            'usage': {
              'input_tokens': 1,
              'input_tokens_details': {'cached_tokens': 0},
              'output_tokens': 1,
              'output_tokens_details': {'reasoning_tokens': 0},
              'total_tokens': 2,
            },
          }),
        );
        await request.response.close();
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      final chunks = await ChatApiService.sendMessageStream(
        config: _deepSeekConfig(baseUrl, useResponseApi: true),
        modelId: 'deepseek-v4-flash',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        thinkingBudget: 0,
        stream: false,
      ).toList();

      expect(chunks.isGenerationDone, isTrue);
      expect(requestBody['reasoning'], {'effort': 'none'});
    });

    test(
      'xhigh reasoning keeps thinking enabled and maps to high effort',
      () async {
        final requests = <Map<String, dynamic>>[];

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          requests.add(await _readJsonBody(request));
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: ${jsonEncode({
              'id': 'cmpl-deepseek',
              'object': 'chat.completion.chunk',
              'created': 0,
              'model': 'deepseek-v4-pro',
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        });

        final baseUrl = 'http://${server.address.address}:${server.port}/v1';
        final chunks = await ChatApiService.sendMessageStream(
          config: _deepSeekConfig(baseUrl),
          modelId: 'deepseek-v4-pro',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          thinkingBudget: 64000,
        ).toList();

        expect(chunks.isGenerationDone, isTrue);
        expect(requests, hasLength(1));
        expect(requests.single['thinking'], {'type': 'enabled'});
        expect(requests.single['reasoning_effort'], 'high');
      },
    );

    test('off reasoning disables thinking and strips effort', () async {
      final requests = <Map<String, dynamic>>[];

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requests.add(await _readJsonBody(request));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'id': 'cmpl-deepseek',
            'object': 'chat.completion.chunk',
            'created': 0,
            'model': 'deepseek-v4-pro',
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          })}\n\n',
        );
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      final chunks = await ChatApiService.sendMessageStream(
        config: _deepSeekConfig(baseUrl),
        modelId: 'deepseek-v4-pro',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        thinkingBudget: 0,
      ).toList();

      expect(chunks.isGenerationDone, isTrue);
      expect(requests, hasLength(1));
      expect(requests.single['thinking'], {'type': 'disabled'});
      expect(requests.single.containsKey('reasoning_effort'), isFalse);
    });

    for (final useEvents in [false, true]) {
      test(
        'tool-only model echoes empty reasoning_content for tool continuation '
        '(${useEvents ? 'event pipeline' : 'legacy pipeline'})',
        () async {
          final requests = await _collectToolOnlyContinuationRequests(
            useEvents: useEvents,
          );

          expect(requests, hasLength(2));
          expect(requests[1].containsKey('thinking'), isFalse);
          final messages = (requests[1]['messages'] as List).cast<Map>();
          final assistantToolMessage = messages.firstWhere(
            (message) =>
                message['role'] == 'assistant' && message['tool_calls'] is List,
          );
          expect(assistantToolMessage['reasoning_content'], '');
        },
      );

      test('tool-only non-DeepSeek model does not receive reasoning_content '
          '(${useEvents ? 'event pipeline' : 'legacy pipeline'})', () async {
        final requests = await _collectToolOnlyContinuationRequests(
          useEvents: useEvents,
          deepSeek: false,
        );

        expect(requests, hasLength(2));
        final messages = (requests[1]['messages'] as List).cast<Map>();
        final assistantToolMessage = messages.firstWhere(
          (message) =>
              message['role'] == 'assistant' && message['tool_calls'] is List,
        );
        expect(assistantToolMessage.containsKey('reasoning_content'), isFalse);
      });
    }

    test(
      'multi-round tool calls keep reasoning_content with its own turn',
      () async {
        final requests = <Map<String, dynamic>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          requests.add(await _readJsonBody(request));
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          final event = switch (requests.length) {
            1 => {
              'choices': [
                {
                  'delta': {
                    'role': 'assistant',
                    'reasoning_content': 'reason for first tool',
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_first',
                        'type': 'function',
                        'function': {'name': 'first_tool', 'arguments': '{}'},
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            },
            2 => {
              'choices': [
                {
                  'delta': {
                    'role': 'assistant',
                    'reasoning_content': 'reason for second tool',
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_second',
                        'type': 'function',
                        'function': {'name': 'second_tool', 'arguments': '{}'},
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            },
            _ => {
              'choices': [
                {
                  'delta': {'role': 'assistant', 'content': 'done'},
                  'finish_reason': 'stop',
                },
              ],
            },
          };
          request.response.write('data: ${jsonEncode(event)}\n\n');
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        });

        final baseUrl = 'http://${server.address.address}:${server.port}/v1';
        await ChatApiService.sendMessageStream(
          config: _deepSeekConfig(
            baseUrl,
            modelOverrides: const {
              'deepseek-reasoner': {
                'abilities': ['tool', 'reasoning'],
              },
            },
          ),
          modelId: 'deepseek-reasoner',
          messages: const [
            {'role': 'user', 'content': 'use both tools'},
          ],
          tools: const [
            {
              'type': 'function',
              'function': {
                'name': 'first_tool',
                'parameters': {'type': 'object'},
              },
            },
            {
              'type': 'function',
              'function': {
                'name': 'second_tool',
                'parameters': {'type': 'object'},
              },
            },
          ],
          onToolCall: (name, _, {toolCallId}) async => '$name result',
        ).toList();

        expect(requests, hasLength(3));
        final finalHistory = (requests[2]['messages'] as List).cast<Map>();
        final toolTurns = finalHistory
            .where(
              (message) =>
                  message['role'] == 'assistant' &&
                  message['tool_calls'] is List,
            )
            .toList();
        expect(toolTurns, hasLength(2));
        expect(toolTurns[0]['reasoning_content'], 'reason for first tool');
        expect(toolTurns[1]['reasoning_content'], 'reason for second tool');
      },
    );

    test('ordinary history strips reasoning_content', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody = await _readJsonBody(request);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          })}\n\n',
        );
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      await ChatApiService.sendMessageStream(
        config: _deepSeekConfig(baseUrl),
        modelId: 'deepseek-reasoner',
        messages: const [
          {'role': 'user', 'content': 'first question'},
          {
            'role': 'assistant',
            'content': 'first answer',
            'reasoning_content': 'private first-turn reasoning',
          },
          {'role': 'user', 'content': 'follow up'},
        ],
      ).toList();

      final history = (requestBody['messages'] as List).cast<Map>();
      expect(history[1].containsKey('reasoning_content'), isFalse);
    });

    test(
      'tool-call turn preserves every assistant reasoning_content',
      () async {
        late Map<String, dynamic> requestBody;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          requestBody = await _readJsonBody(request);
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        });

        final baseUrl = 'http://${server.address.address}:${server.port}/v1';
        await ChatApiService.sendMessageStream(
          config: _deepSeekConfig(baseUrl),
          modelId: 'deepseek-reasoner',
          messages: const [
            {'role': 'user', 'content': 'check the weather'},
            {
              'role': 'assistant',
              'content': '',
              'reasoning_content': 'decide to call weather tool',
              'tool_calls': [
                {
                  'id': 'call_weather',
                  'type': 'function',
                  'function': {'name': 'weather', 'arguments': '{}'},
                },
              ],
            },
            {
              'role': 'tool',
              'tool_call_id': 'call_weather',
              'content': 'sunny',
            },
            {
              'role': 'assistant',
              'content': 'It is sunny.',
              'reasoning_content': 'summarize the tool result',
            },
            {'role': 'user', 'content': 'thanks'},
          ],
        ).toList();

        final history = (requestBody['messages'] as List).cast<Map>();
        expect(history[1]['reasoning_content'], 'decide to call weather tool');
        expect(history[3]['reasoning_content'], 'summarize the tool result');
      },
    );

    test(
      'Responses API supports built-in search for the DeepSeek Flash / V4 family',
      () {
        for (final modelId in const [
          'deepseek-flash',
          'deepseek/deepseek-flash',
          'deepseek-v4-pro',
          'deepseek-v4-flash',
        ]) {
          final modelOverrides = <String, dynamic>{
            modelId: <String, dynamic>{
              'builtInTools': const <String>[BuiltInToolNames.search],
            },
          };
          final responsesConfig = _deepSeekConfig(
            'https://api.deepseek.com/v1',
            useResponseApi: true,
            modelOverrides: modelOverrides,
          );
          final chatConfig = _deepSeekConfig(
            'https://api.deepseek.com/v1',
            modelOverrides: modelOverrides,
          );

          expect(
            BuiltInToolsHelper.supportsBuiltInSearchForModel(
              cfg: responsesConfig,
              modelId: modelId,
            ),
            isTrue,
            reason: modelId,
          );
          expect(
            BuiltInToolsHelper.supportsBuiltInSearchForModel(
              cfg: chatConfig,
              modelId: modelId,
            ),
            isFalse,
            reason: modelId,
          );
        }
      },
    );
  });
}
