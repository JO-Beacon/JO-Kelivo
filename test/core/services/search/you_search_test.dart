import 'dart:convert';

import 'package:Kelivo/core/services/search/providers/you_search_service.dart';
import 'package:Kelivo/core/services/search/search_service.dart';
import 'package:Kelivo/utils/brand_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('You.com search provider', () {
    test(
      'posts /v1/search with X-API-Key and merges web+news results',
      () async {
        http.Request? captured;
        final service = YouSearchService(
          client: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({
                'results': {
                  'web': [
                    {
                      'title': 'Web',
                      'url': 'https://example.com/w',
                      'contents': {
                        'highlights': ['hl1', 'hl2'],
                      },
                    },
                  ],
                  'news': [
                    {
                      'title': 'News',
                      'url': 'https://example.com/n',
                      'snippets': ['snip'],
                    },
                  ],
                },
              }),
              200,
            );
          }),
        );

        final result = await service.search(
          query: 'you',
          commonOptions: const SearchCommonOptions(
            resultSize: 5,
            timeout: 1000,
          ),
          serviceOptions: YouSearchOptions(id: 'y1', apiKey: 'k'),
        );

        expect(captured?.url.toString(), YouSearchService.endpoint);
        expect(captured?.headers['X-API-Key'], 'k');
        final body = jsonDecode(captured!.body) as Map<String, dynamic>;
        expect(body['query'], 'you');
        expect(body['count'], 5);
        // 默认 highlights 模式会附带 extraction 参数。
        expect((body['extraction'] as Map)['extraction_mode'], 'highlights');
        expect(result.items, hasLength(2));
        expect(result.items[0].title, 'Web');
        expect(result.items[0].text, 'hl1\n\nhl2');
        expect(result.items[1].title, 'News');
        expect(result.items[1].text, 'snip');
        expect(
          SearchService.getService(YouSearchOptions(id: 'x', apiKey: '')),
          isA<YouSearchService>(),
        );
      },
    );

    test('snippets mode omits extraction and prefers snippets text', () async {
      http.Request? captured;
      final service = YouSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'results': {
                'web': [
                  {
                    'title': 'T',
                    'url': 'https://e.com',
                    'snippets': ['s1'],
                    'description': 'fallback desc',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'q',
        commonOptions: const SearchCommonOptions(resultSize: 3, timeout: 1000),
        serviceOptions: YouSearchOptions(
          id: 'y2',
          apiKey: 'k',
          contentMode: YouSearchOptions.snippetsMode,
        ),
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body.containsKey('extraction'), isFalse);
      expect(result.items.single.text, 's1');
    });

    test(
      'falls back to description when highlights/snippets are empty',
      () async {
        final service = YouSearchService(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'results': {
                  'web': [
                    {
                      'title': 'T',
                      'url': 'https://e.com',
                      'description': 'desc only',
                    },
                  ],
                },
              }),
              200,
            ),
          ),
        );

        final result = await service.search(
          query: 'q',
          commonOptions: const SearchCommonOptions(
            resultSize: 3,
            timeout: 1000,
          ),
          serviceOptions: YouSearchOptions(id: 'y3', apiKey: 'k'),
        );

        expect(result.items.single.text, 'desc only');
      },
    );

    test('round-trips options through JSON and normalizes content mode', () {
      final options = YouSearchOptions(
        id: 'y4',
        apiKey: 'primary',
        contentMode: YouSearchOptions.snippetsMode,
        extraApiKeys: const ['extra1'],
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());
      expect(restored, isA<YouSearchOptions>());
      final you = restored as YouSearchOptions;
      expect(you.apiKey, 'primary');
      expect(you.contentMode, 'snippets');
      expect(you.extraApiKeys, ['extra1']);

      // 非法/缺失内容模式回落 highlights（旧配置兼容）。
      final legacy = YouSearchOptions.fromJson({'id': 'y5', 'apiKey': 'k'});
      expect(legacy.contentMode, YouSearchOptions.defaultContentMode);
      expect(YouSearchOptions.normalizeContentMode('nonsense'), 'highlights');
      expect(YouSearchOptions.normalizeContentMode(null), 'highlights');
    });

    test('maps the brand icon for provider avatars', () {
      final asset = BrandAssets.assetForName('You.com');
      expect(asset, 'assets/icons/you.svg');
      expect(BrandAssets.assetForName('you'), 'assets/icons/you.svg');
      // 宽松子串不应误伤其它名称。
      expect(BrandAssets.assetForName('youtube'), isNull);
      expect(BrandAssets.selectableAssetOrNull(asset!), asset);
    });
  });
}
