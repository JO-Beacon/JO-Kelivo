import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/model_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';

Future<HttpServer> _startServer({
  required int statusCode,
  required String body,
  required void Function(HttpRequest request) onRequest,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    onRequest(request);
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(body);
    await request.response.close();
  });
  return server;
}

ProviderConfig _config({
  required String baseUrl,
  required ProviderKind kind,
  String id = 'Test provider',
}) {
  return ProviderConfig(
    id: id,
    enabled: true,
    name: id,
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: kind,
  );
}

void main() {
  test('DeepSeek Anthropic model listing uses root models endpoint', () async {
    late String path;
    late String? authorization;
    late String? apiKeyHeader;
    final server = await _startServer(
      statusCode: HttpStatus.ok,
      body: jsonEncode({
        'object': 'list',
        'data': [
          {'id': 'deepseek-chat', 'owned_by': 'deepseek'},
        ],
      }),
      onRequest: (request) {
        path = request.uri.path;
        authorization = request.headers.value('authorization');
        apiKeyHeader = request.headers.value('x-api-key');
      },
    );
    addTearDown(() => server.close(force: true));

    final cfg = _config(
      baseUrl: 'http://${server.address.address}:${server.port}/anthropic',
      kind: ProviderKind.claude,
      id: 'DeepSeek',
    );

    final models = await ProviderManager.listModels(cfg);

    expect(path, '/models');
    expect(authorization, 'Bearer test-key');
    expect(apiKeyHeader, isNull);
    expect(models.map((model) => model.id), contains('deepseek-chat'));
  });

  test(
    'standard Anthropic listing preserves configured path and headers',
    () async {
      late String path;
      late String? authorization;
      late String? apiKeyHeader;
      late String? anthropicVersion;
      final server = await _startServer(
        statusCode: HttpStatus.ok,
        body: jsonEncode({
          'data': [
            {'id': 'claude-sonnet', 'display_name': 'Claude Sonnet'},
          ],
        }),
        onRequest: (request) {
          path = request.uri.path;
          authorization = request.headers.value('authorization');
          apiKeyHeader = request.headers.value('x-api-key');
          anthropicVersion = request.headers.value('anthropic-version');
        },
      );
      addTearDown(() => server.close(force: true));

      final cfg = _config(
        baseUrl: 'http://${server.address.address}:${server.port}/v1/',
        kind: ProviderKind.claude,
      );

      final models = await ProviderManager.listModels(cfg);

      expect(path, '/v1/models');
      expect(authorization, isNull);
      expect(apiKeyHeader, 'test-key');
      expect(anthropicVersion, ClaudeProvider.anthropicVersion);
      expect(models.single.displayName, 'Claude Sonnet');
    },
  );

  test('non-2xx model listing responses surface useful errors', () async {
    final cases = <({ProviderKind kind, int status, String body})>[
      (
        kind: ProviderKind.openai,
        status: HttpStatus.unauthorized,
        body: 'openai denied',
      ),
      (
        kind: ProviderKind.claude,
        status: HttpStatus.forbidden,
        body: 'anthropic denied',
      ),
      (
        kind: ProviderKind.google,
        status: HttpStatus.serviceUnavailable,
        body: 'google unavailable',
      ),
    ];

    for (final testCase in cases) {
      final server = await _startServer(
        statusCode: testCase.status,
        body: testCase.body,
        onRequest: (_) {},
      );
      final cfg = _config(
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        kind: testCase.kind,
      );

      await expectLater(
        ProviderManager.listModels(cfg),
        throwsA(
          isA<HttpException>().having(
            (error) => error.message,
            'message',
            allOf(contains('HTTP ${testCase.status}'), contains(testCase.body)),
          ),
        ),
      );
      await server.close(force: true);
    }
  });

  test('non-2xx empty responses still include a diagnostic', () async {
    final server = await _startServer(
      statusCode: HttpStatus.tooManyRequests,
      body: '',
      onRequest: (_) {},
    );
    addTearDown(() => server.close(force: true));
    final cfg = _config(
      baseUrl: 'http://${server.address.address}:${server.port}/v1',
      kind: ProviderKind.openai,
    );

    await expectLater(
      ProviderManager.listModels(cfg),
      throwsA(
        isA<HttpException>().having(
          (error) => error.message,
          'message',
          allOf(contains('HTTP 429'), contains('empty response body')),
        ),
      ),
    );
  });
}
