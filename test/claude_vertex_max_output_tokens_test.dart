import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';

/// Vertex 端点不认识"档位式"的输出上限：老 Claude 模型的上限远小于 64000，
/// 按 64000 发出去会被上游拒。这里锁住按模型查表的行为，以及这条规则只在
/// Vertex 端点生效。
void main() {
  group('Vertex Claude 输出上限表', () {
    test('128000 档：fable-5 / opus 5、4.8、4.7、4.6 / sonnet 5、4.6', () {
      for (final id in const [
        'claude-fable-5-1',
        'claude-fable-5',
        'claude-opus-5',
        'claude-opus-4-8',
        'claude-opus-4-7',
        'claude-opus-4-6',
        'claude-sonnet-5',
        'claude-sonnet-4-6',
      ]) {
        expect(
          ChatApiService.claudeVertexMaxOutputTokensForTest(id),
          128000,
          reason: id,
        );
      }
    });

    test(
      '64000 档：opus 4.5 / sonnet 4.5 / haiku 4.5 / sonnet 4 / 3.7 sonnet',
      () {
        for (final id in const [
          'claude-opus-4-5@20251101',
          'claude-sonnet-4-5@20250929',
          'claude-haiku-4-5@20251001',
          'claude-sonnet-4@20250514',
          'claude-3-7-sonnet@20250219',
        ]) {
          expect(
            ChatApiService.claudeVertexMaxOutputTokensForTest(id),
            64000,
            reason: id,
          );
        }
      },
    );

    test('32000 档：opus 4.1 / opus 4', () {
      for (final id in const [
        'claude-opus-4-1@20250805',
        'claude-opus-4@20250514',
      ]) {
        expect(
          ChatApiService.claudeVertexMaxOutputTokensForTest(id),
          32000,
          reason: id,
        );
      }
    });

    test('小上限的老模型：3.5 sonnet 系 8192、3.5 haiku 8192、3 haiku 8000', () {
      for (final id in const [
        'claude-3-5-sonnet@20240620',
        'claude-3-5-sonnet-v2@20241022',
        'claude-3-5-haiku@20241022',
      ]) {
        expect(
          ChatApiService.claudeVertexMaxOutputTokensForTest(id),
          8192,
          reason: id,
        );
      }
      expect(
        ChatApiService.claudeVertexMaxOutputTokensForTest(
          'claude-3-haiku@20240307',
        ),
        8000,
      );
    });

    test('表外的模型回落 4096，不给 64000', () {
      for (final id in const [
        'claude-3-opus@20240229',
        'claude-2.1',
        'some-unknown-model',
      ]) {
        expect(
          ChatApiService.claudeVertexMaxOutputTokensForTest(id),
          4096,
          reason: id,
        );
      }
    });
  });

  group('这条规则只在 Vertex 端点生效', () {
    test('官方 Anthropic 端点上的 3.5 sonnet 仍按通用规则发 64000', () async {
      Map<String, dynamic>? requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });
      server.listen((request) async {
        requestBody =
            (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
                .cast<String, dynamic>();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'msg_1',
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: ProviderConfig(
          id: 'ClaudeOfficialMaxTokensTest',
          enabled: true,
          name: 'ClaudeOfficialMaxTokensTest',
          apiKey: 'test-key',
          baseUrl: 'http://${server.address.address}:${server.port}',
          providerType: ProviderKind.claude,
        ),
        modelId: 'claude-3-5-sonnet@20240620',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        stream: false,
      ).toList();

      final body = requestBody;
      expect(body, isNotNull);
      // Vertex 上这款模型只允许 8192；官方端点走通用规则，这里是 64000。
      expect(body!['max_tokens'], 64000);
    });
  });
}
