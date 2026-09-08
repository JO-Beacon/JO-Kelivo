import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';

ProviderConfig _geminiConfig(String baseUrl) {
  return ProviderConfig(
    id: 'GeminiTest',
    enabled: true,
    name: 'GeminiTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.google,
  );
}

Future<HttpServer> _startGeminiServer(
  void Function(Map<String, dynamic> body) onBody,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final bodyText = await utf8.decoder.bind(request).join();
    onBody(jsonDecode(bodyText) as Map<String, dynamic>);

    request.response.statusCode = HttpStatus.ok;
    if (request.uri.path.endsWith(':streamGenerateContent')) {
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: ${jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ok'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 1, 'totalTokenCount': 2},
        })}\n\n',
      );
      request.response.write('data: [DONE]');
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ok'},
                ],
              },
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 1,
            'candidatesTokenCount': 1,
            'totalTokenCount': 2,
          },
        }),
      );
    }
    await request.response.close();
  });
  return server;
}

Map<String, dynamic>? _thinkingConfig(Map<String, dynamic> body) {
  final generationConfig = body['generationConfig'];
  if (generationConfig is! Map) return null;
  final thinkingConfig = generationConfig['thinkingConfig'];
  if (thinkingConfig is! Map) return null;
  return thinkingConfig.cast<String, dynamic>();
}

Future<Map<String, dynamic>> _captureThinkingConfig({
  required String modelId,
  int? thinkingBudget,
}) async {
  late Map<String, dynamic> body;
  final server = await _startGeminiServer((captured) => body = captured);
  addTearDown(() => server.close(force: true));

  final chunks = await ChatApiService.sendMessageStream(
    config: _geminiConfig(
      'http://${server.address.address}:${server.port}/v1beta',
    ),
    modelId: modelId,
    messages: const [
      {'role': 'user', 'content': 'hello'},
    ],
    thinkingBudget: thinkingBudget,
    stream: false,
  ).toList();

  expect(chunks.last.isDone, isTrue, reason: modelId);
  return body;
}

void main() {
  group('Google Gemma 4 thinking config', () {
    test('non-stream request maps custom budget to thinking level', () async {
      late Map<String, dynamic> capturedBody;
      final server = await _startGeminiServer((body) {
        capturedBody = body;
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _geminiConfig(
          'http://${server.address.address}:${server.port}/v1beta',
        ),
        modelId: 'google/gemma-4-E4B-it',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        thinkingBudget: 16000,
        stream: false,
      ).toList();

      expect(chunks.last.isDone, isTrue);
      expect(_thinkingConfig(capturedBody), {
        'includeThoughts': true,
        'thinkingLevel': 'high',
      });
      expect(
        _thinkingConfig(capturedBody)!.containsKey('thinkingBudget'),
        isFalse,
      );
    });

    test('stream request maps enabled budget to thinking level', () async {
      late Map<String, dynamic> capturedBody;
      final server = await _startGeminiServer((body) {
        capturedBody = body;
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _geminiConfig(
          'http://${server.address.address}:${server.port}/v1beta',
        ),
        modelId: 'google/gemma-4-31B-it',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        thinkingBudget: 1024,
      ).toList();

      expect(chunks.last.isDone, isTrue);
      expect(_thinkingConfig(capturedBody), {
        'includeThoughts': true,
        'thinkingLevel': 'high',
      });
      expect(
        _thinkingConfig(capturedBody)!.containsKey('thinkingBudget'),
        isFalse,
      );
    });

    test('off budget sends minimal thinking level for Gemma 4', () async {
      late Map<String, dynamic> capturedBody;
      final server = await _startGeminiServer((body) {
        capturedBody = body;
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _geminiConfig(
          'http://${server.address.address}:${server.port}/v1beta',
        ),
        modelId: 'gemma-4-E2B-it',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        thinkingBudget: 0,
      ).toList();

      expect(chunks.last.isDone, isTrue);
      expect(_thinkingConfig(capturedBody), {
        'includeThoughts': false,
        'thinkingLevel': 'minimal',
      });
    });
  });

  group('latest Gemini Flash thinking config', () {
    test('routes an unknown Gemini 3.x Pro through thinkingLevel', () async {
      final body = await _captureThinkingConfig(
        modelId: 'gemini-3.2-pro-preview',
        thinkingBudget: 16000,
      );

      expect(_thinkingConfig(body), {
        'includeThoughts': true,
        'thinkingLevel': 'medium',
      });
    });

    test('hides thoughts when Gemini 3.7 thinking is off', () async {
      final body = await _captureThinkingConfig(
        modelId: 'gemini-3.7-flash',
        thinkingBudget: 0,
      );

      expect(_thinkingConfig(body), {
        'includeThoughts': false,
        'thinkingLevel': 'low',
      });
    });

    test(
      'Gemini 3.8 Flash inherits 3.7 thinking levels and default medium',
      () async {
        final body = await _captureThinkingConfig(modelId: 'gemini-3.8-flash');

        expect(_thinkingConfig(body), {
          'includeThoughts': true,
          'thinkingLevel': 'medium',
        });

        final offBody = await _captureThinkingConfig(
          modelId: 'gemini-3.8-flash',
          thinkingBudget: 0,
        );
        expect(_thinkingConfig(offBody), {
          'includeThoughts': false,
          'thinkingLevel': 'low',
        });
      },
    );

    test('Gemini 3.6 Flash defaults to medium with 64K output', () async {
      late Map<String, dynamic> capturedBody;
      final server = await _startGeminiServer((body) {
        capturedBody = body;
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _geminiConfig(
          'http://${server.address.address}:${server.port}/v1beta',
        ),
        modelId: 'gemini-3.6-flash',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        stream: false,
      ).toList();

      expect(chunks.last.isDone, isTrue);
      expect(_thinkingConfig(capturedBody), {
        'includeThoughts': true,
        'thinkingLevel': 'medium',
      });
      expect(
        (capturedBody['generationConfig'] as Map)['maxOutputTokens'],
        65536,
      );
    });

    test('Gemini 3.5 Flash-Lite defaults to minimal thinking', () async {
      late Map<String, dynamic> capturedBody;
      final server = await _startGeminiServer((body) {
        capturedBody = body;
      });
      addTearDown(() async {
        await server.close(force: true);
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _geminiConfig(
          'http://${server.address.address}:${server.port}/v1beta',
        ),
        modelId: 'gemini-3.5-flash-lite',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        stream: false,
      ).toList();

      expect(chunks.last.isDone, isTrue);
      expect(_thinkingConfig(capturedBody), {
        'includeThoughts': true,
        'thinkingLevel': 'minimal',
      });
      expect(
        (capturedBody['generationConfig'] as Map)['maxOutputTokens'],
        65536,
      );
    });
  });
}
