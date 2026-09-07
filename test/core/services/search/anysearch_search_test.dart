import 'dart:convert';

import 'package:Kelivo/core/services/search/providers/anysearch_search_service.dart';
import 'package:Kelivo/core/services/search/search_service.dart';
import 'package:Kelivo/utils/brand_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AnySearch search provider', () {
    test(
      'posts /v1/search with bearer key and parses wrapped results',
      () async {
        http.Request? captured;
        final service = AnySearchSearchService(
          client: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({
                'data': {
                  'results': [
                    {
                      'title': 'Any',
                      'url': 'https://example.com/a',
                      'snippet': 'wrapped',
                    },
                  ],
                },
              }),
              200,
            );
          }),
        );

        final result = await service.search(
          query: 'kelivo',
          commonOptions: const SearchCommonOptions(
            resultSize: 5,
            timeout: 1000,
          ),
          serviceOptions: AnySearchOptions(id: 'a1', apiKey: 'k'),
        );

        expect(captured?.url.toString(), AnySearchOptions.defaultUrl);
        expect(captured?.headers['Authorization'], 'Bearer k');
        final body = jsonDecode(captured!.body) as Map<String, dynamic>;
        expect(body['query'], 'kelivo');
        expect(body['max_results'], 5);
        expect(result.items.single.title, 'Any');
        expect(result.items.single.url, 'https://example.com/a');
        expect(result.items.single.text, 'wrapped');
        expect(
          SearchService.getService(AnySearchOptions(id: 'x', apiKey: '')),
          isA<AnySearchSearchService>(),
        );
      },
    );

    test(
      'parses top-level results and omits Authorization without key',
      () async {
        http.Request? captured;
        final service = AnySearchSearchService(
          client: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({
                'results': [
                  {'title': 'T', 'url': 'https://e.com', 'content': 'flat'},
                ],
              }),
              200,
            );
          }),
        );

        final result = await service.search(
          query: 'q',
          commonOptions: const SearchCommonOptions(
            resultSize: 3,
            timeout: 1000,
          ),
          serviceOptions: AnySearchOptions(id: 'a2', apiKey: ''),
        );

        expect(captured?.headers.containsKey('Authorization'), isFalse);
        expect(result.items.single.text, 'flat');
      },
    );

    test('uses custom url when configured', () async {
      http.Request? captured;
      final service = AnySearchSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'results': [
                {'title': 'T', 'url': 'https://e.com', 'snippet': 's'},
              ],
            }),
            200,
          );
        }),
      );

      await service.search(
        query: 'q',
        commonOptions: const SearchCommonOptions(resultSize: 3, timeout: 1000),
        serviceOptions: AnySearchOptions(
          id: 'a3',
          apiKey: 'k',
          url: '  https://proxy.example.com/v1/search  ',
        ),
      );

      expect(captured?.url.toString(), 'https://proxy.example.com/v1/search');
    });

    test('round-trips options through JSON with extra keys', () {
      final options = AnySearchOptions(
        id: 'a4',
        apiKey: 'primary',
        url: 'https://custom.example.com/v1/search',
        extraApiKeys: const ['extra1', 'extra2'],
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());
      expect(restored, isA<AnySearchOptions>());
      final anySearch = restored as AnySearchOptions;
      expect(anySearch.apiKey, 'primary');
      expect(anySearch.url, 'https://custom.example.com/v1/search');
      expect(anySearch.resolvedUrl, 'https://custom.example.com/v1/search');
      expect(anySearch.extraApiKeys, ['extra1', 'extra2']);

      // 空自定义地址回落默认地址（旧配置兼容）。
      final legacy = AnySearchOptions.fromJson({'id': 'a5', 'apiKey': 'k'});
      expect(legacy.url, '');
      expect(legacy.resolvedUrl, AnySearchOptions.defaultUrl);
    });

    test('maps the brand icon for provider avatars', () {
      final asset = BrandAssets.assetForName('AnySearch');
      expect(asset, 'assets/icons/anysearch.svg');
      expect(BrandAssets.selectableAssetOrNull(asset!), asset);
      expect(BrandAssets.assetNeedsDarkInvert(asset), isTrue);
    });
  });
}
