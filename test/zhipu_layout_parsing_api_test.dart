import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';

ProviderConfig config(String baseUrl) => ProviderConfig(
  id: 'ZhipuTest',
  enabled: true,
  name: 'ZhipuTest',
  apiKey: 'test-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
);

void main() {
  test('routes only the official host and exact GLM-OCR model', () {
    expect(
      shouldUseZhipuLayoutParsing(
        config('https://open.bigmodel.cn/api/paas/v4'),
        'glm-ocr',
      ),
      isTrue,
    );
    expect(
      shouldUseZhipuLayoutParsing(
        config('https://open.bigmodel.cn/api/paas/v4'),
        'GLM-OCR',
      ),
      isTrue,
    );
    expect(
      shouldUseZhipuLayoutParsing(
        config('https://openrouter.ai/api/v1'),
        'glm-ocr',
      ),
      isFalse,
    );
    expect(
      shouldUseZhipuLayoutParsing(
        config('https://open.bigmodel.cn/api/paas/v4'),
        'glm-ocr-v1',
      ),
      isFalse,
    );
  });

  test('posts layout parsing payload and emits markdown plus usage', () async {
    late Map<String, dynamic> requestBody;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requestBody = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
          .cast<String, dynamic>();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'md_results': '# Title\nExtracted text',
          'usage': {
            'prompt_tokens': 3,
            'completion_tokens': 5,
            'total_tokens': 8,
          },
        }),
      );
      await request.response.close();
    });

    final client = http.Client();
    addTearDown(client.close);
    final chunks = await sendZhipuLayoutParsingStream(
      client,
      config('http://${server.address.address}:${server.port}/api/paas/v4'),
      'glm-ocr',
      const [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'https://example.com/image.png'},
            },
          ],
        },
      ],
    ).toList();

    expect(requestBody, {
      'model': officialGlmOcrModelId,
      'file': 'https://example.com/image.png',
    });
    expect(chunks.first.content, '# Title\nExtracted text');
    expect(chunks.last.isDone, isTrue);
    expect(chunks.last.usage?.totalTokens, 8);
  });
}
