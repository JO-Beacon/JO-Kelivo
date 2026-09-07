import 'dart:convert';

import 'package:Kelivo/core/services/search/providers/parallel_search_service.dart';
import 'package:Kelivo/core/services/search/search_service.dart';
import 'package:Kelivo/utils/brand_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Parallel search provider', () {
    test('posts /v1/search with x-api-key and parses excerpts', () async {
      http.Request? captured;
      final service = ParallelSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'title': 'Para',
                  'url': 'https://example.com/p',
                  'excerpts': ['first', 'second'],
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'llm search',
        commonOptions: const SearchCommonOptions(resultSize: 5, timeout: 1000),
        serviceOptions: ParallelOptions(id: 'p1', apiKey: 'k'),
      );

      expect(captured?.url.toString(), ParallelSearchService.endpoint);
      expect(captured?.headers['x-api-key'], 'k');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['objective'], 'llm search');
      expect(body['search_queries'], ['llm search']);
      expect(body['mode'], 'advanced');
      expect(result.items.single.title, 'Para');
      expect(result.items.single.text, 'first\n\nsecond');
      expect(
        SearchService.getService(ParallelOptions(id: 'x', apiKey: '')),
        isA<ParallelSearchService>(),
      );
    });

    test('sends configured mode and caps items to result size', () async {
      http.Request? captured;
      final service = ParallelSearchService(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'results': [
                for (var i = 0; i < 4; i++)
                  {
                    'title': 'T$i',
                    'url': 'https://e.com/$i',
                    'excerpts': ['e'],
                  },
              ],
            }),
            200,
          );
        }),
      );

      final result = await service.search(
        query: 'q',
        commonOptions: const SearchCommonOptions(resultSize: 2, timeout: 1000),
        serviceOptions: ParallelOptions(id: 'p2', apiKey: 'k', mode: 'turbo'),
      );

      expect(jsonDecode(captured!.body)['mode'], 'turbo');
      expect(result.items, hasLength(2));
    });

    test('round-trips options through JSON and normalizes mode', () {
      final options = ParallelOptions(
        id: 'p3',
        apiKey: 'primary',
        mode: 'fast',
        extraApiKeys: const ['extra1'],
      );

      final restored = SearchServiceOptions.fromJson(options.toJson());
      expect(restored, isA<ParallelOptions>());
      final parallel = restored as ParallelOptions;
      expect(parallel.apiKey, 'primary');
      expect(parallel.mode, 'fast');
      expect(parallel.extraApiKeys, ['extra1']);

      // 非法/缺失模式回落 advanced（旧配置兼容）。
      final legacy = ParallelOptions.fromJson({'id': 'p4', 'apiKey': 'k'});
      expect(legacy.mode, ParallelOptions.defaultMode);
      expect(ParallelOptions.normalizeMode('nonsense'), 'advanced');
      expect(ParallelOptions.normalizeMode(null), 'advanced');
      expect(ParallelOptions.modes, ['advanced', 'basic', 'fast', 'turbo']);
    });

    test('maps the brand icon for provider avatars', () {
      final asset = BrandAssets.assetForName('Parallel');
      expect(asset, 'assets/icons/parallel.svg');
      expect(BrandAssets.selectableAssetOrNull(asset!), asset);
      expect(BrandAssets.assetNeedsDarkInvert(asset), isTrue);
    });
  });
}
