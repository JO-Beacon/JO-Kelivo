import 'dart:convert';

import 'package:Kelivo/core/services/search/providers/brave_search_service.dart';
import 'package:Kelivo/core/services/search/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Brave search provider', () {
    test('web mode (default) hits web/search endpoint as before', () async {
      http.Request? captured;
      final service = BraveSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'web': {
                'results': [
                  {
                    'title': 'Brave',
                    'url': 'https://example.com/b',
                    'description': 'desc',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'privacy',
        commonOptions: const SearchCommonOptions(resultSize: 5, timeout: 1000),
        serviceOptions: BraveOptions(id: 'b1', apiKey: 'k'),
      );

      expect(
        captured?.url.toString(),
        startsWith(BraveSearchService.webEndpoint),
      );
      expect(captured?.method, 'GET');
      expect(captured?.headers['X-Subscription-Token'], 'k');
      expect(result.items.single.title, 'Brave');
    });

    test('llmContext mode posts /llm/context with token budget', () async {
      http.Request? captured;
      final service = BraveSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'grounding': {
                'generic': [
                  {
                    'title': 'Ctx',
                    'url': 'https://example.com/c',
                    'snippets': ['s1', 's2'],
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'llm',
        commonOptions: const SearchCommonOptions(resultSize: 4, timeout: 1000),
        serviceOptions: BraveOptions(
          id: 'b2',
          apiKey: 'k',
          mode: BraveOptions.llmContextMode,
          maximumNumberOfTokens: 4096,
        ),
      );

      expect(captured?.url.toString(), BraveSearchService.llmContextEndpoint);
      expect(captured?.method, 'POST');
      expect(captured?.headers['X-Subscription-Token'], 'k');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['q'], 'llm');
      expect(body['count'], 4);
      expect(body['maximum_number_of_urls'], 4);
      expect(body['maximum_number_of_tokens'], 4096);
      expect(result.items.single.title, 'Ctx');
      expect(result.items.single.text, 's1\n\ns2');
    });

    test('round-trips options and keeps legacy configs on web mode', () {
      final options = BraveOptions(
        id: 'b3',
        apiKey: 'primary',
        mode: BraveOptions.llmContextMode,
        maximumNumberOfTokens: 16384,
        extraApiKeys: const ['extra1'],
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());
      expect(restored, isA<BraveOptions>());
      final brave = restored as BraveOptions;
      expect(brave.mode, 'llmContext');
      expect(brave.maximumNumberOfTokens, 16384);
      expect(brave.extraApiKeys, ['extra1']);

      // 旧配置（无 mode / token 字段）回落 web + 默认 8192。
      final legacy = BraveOptions.fromJson({'id': 'b4', 'apiKey': 'k'});
      expect(legacy.mode, BraveOptions.webMode);
      expect(legacy.maximumNumberOfTokens, 8192);

      // token 归一化：越界收敛、非数字回落默认。
      expect(BraveOptions.normalizeMaximumNumberOfTokens(100), 1024);
      expect(BraveOptions.normalizeMaximumNumberOfTokens(99999), 32768);
      expect(BraveOptions.normalizeMaximumNumberOfTokens('abc'), 8192);
      expect(BraveOptions.normalizeMaximumNumberOfTokens(null), 8192);

      // 输入校验：空合法（保存时回落默认）；越界不合法。
      expect(BraveOptions.isValidMaximumNumberOfTokensInput(''), isTrue);
      expect(BraveOptions.isValidMaximumNumberOfTokensInput('2048'), isTrue);
      expect(BraveOptions.isValidMaximumNumberOfTokensInput('100'), isFalse);
      expect(BraveOptions.isValidMaximumNumberOfTokensInput('99999'), isFalse);
      expect(BraveOptions.isValidMaximumNumberOfTokensInput('abc'), isFalse);
    });
  });
}
