import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/provider_balance_service.dart';

ProviderConfig _openAiConfig(String baseUrl) {
  return ProviderConfig(
    id: 'BalanceTest',
    enabled: true,
    name: 'BalanceTest',
    apiKey: 'balance-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    balanceEnabled: true,
    balanceApiPath: '/credits',
    balanceResultPath: 'data.total_credits - data.total_usage',
  );
}

void main() {
  group('ProviderBalanceValueParser', () {
    test('reads dotted paths and array indexes', () {
      final body = jsonDecode('''
      {
        "balance_infos": [
          {"total_balance": 12.345}
        ]
      }
      ''');

      expect(
        ProviderBalanceValueParser.format(
          body,
          'balance_infos[0].total_balance',
        ),
        '12.35',
      );
    });

    test('subtracts two numeric JSON paths', () {
      final body = jsonDecode('''
      {
        "data": {
          "total_credits": 20,
          "total_usage": 7.755
        }
      }
      ''');

      expect(
        ProviderBalanceValueParser.format(
          body,
          'data.total_credits - data.total_usage',
        ),
        '12.25',
      );
    });

    test('returns non numeric values without numeric formatting', () {
      final body = jsonDecode('{"data":{"plan":"trial"}}');

      expect(ProviderBalanceValueParser.format(body, 'data.plan'), 'trial');
    });
  });

  group('ProviderBalanceService', () {
    test('requests configured balance path with bearer auth', () async {
      final requests = <HttpRequest>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requests.add(request);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': {'total_credits': 20, 'total_usage': 7.755},
          }),
        );
        await request.response.close();
      });

      final balance = await ProviderBalanceService.fetchBalance(
        _openAiConfig('http://${server.address.address}:${server.port}/v1'),
      );

      expect(balance, '12.25');
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.uri.path, '/v1/credits');
      expect(
        requests.single.headers.value(HttpHeaders.authorizationHeader),
        'Bearer balance-key',
      );
    });

    test('throws useful error for non success responses', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response.statusCode = HttpStatus.paymentRequired;
        request.response.write('quota unavailable');
        await request.response.close();
      });

      expect(
        () => ProviderBalanceService.fetchBalance(
          _openAiConfig('http://${server.address.address}:${server.port}/v1'),
        ),
        throwsA(
          isA<ProviderBalanceException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 402'),
          ),
        ),
      );
    });

    test('accepts a full balance URL for non OpenAI providers', () async {
      final requests = <HttpRequest>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requests.add(request);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'balance': 18.5}));
        await request.response.close();
      });

      final config = ProviderConfig(
        id: 'Gemini',
        enabled: true,
        name: 'Gemini',
        apiKey: 'key',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        providerType: ProviderKind.google,
        balanceEnabled: true,
        balanceApiPath:
            'http://${server.address.address}:${server.port}/account/balance',
        balanceResultPath: 'balance',
      );

      expect(await ProviderBalanceService.fetchBalance(config), '18.50');
      expect(requests, hasLength(1));
      expect(requests.single.uri.path, '/account/balance');
    });

    test('requires a full balance URL for non OpenAI providers', () async {
      final config = ProviderConfig(
        id: 'Gemini',
        enabled: true,
        name: 'Gemini',
        apiKey: 'key',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        providerType: ProviderKind.google,
        balanceEnabled: true,
        balanceApiPath: '/account/balance',
      );

      expect(
        () => ProviderBalanceService.fetchBalance(config),
        throwsA(
          isA<ProviderBalanceException>()
              .having(
                (error) => error.code,
                'code',
                'full_balance_api_url_required',
              )
              .having(
                (error) => error.message,
                'message',
                contains('full balance API URL'),
              ),
        ),
      );
    });

    test('keeps explicit DeepSeek OpenAI-compatible balance routing', () async {
      final requests = <HttpRequest>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requests.add(request);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'balance_infos': [
              {'total_balance': 9.5},
            ],
          }),
        );
        await request.response.close();
      });

      final config = ProviderConfig(
        id: 'deepseek-openai-explicit',
        enabled: true,
        name: 'DeepSeek OpenAI',
        apiKey: 'explicit-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        providerType: ProviderKind.openai,
        balanceEnabled: true,
        balanceApiPath: '/user/balance',
        balanceResultPath: 'balance_infos[0].total_balance',
      );

      expect(
        ProviderConfig.classify(config.id, explicitType: config.providerType),
        ProviderKind.openai,
      );
      expect(await ProviderBalanceService.fetchBalance(config), '9.50');
      expect(requests, hasLength(1));
      expect(requests.single.uri.path, '/v1/user/balance');
    });

    test(
      'routes DeepSeek Anthropic balance requests to root endpoint',
      () async {
        final requests = <HttpRequest>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          requests.add(request);
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'balance_infos': [
                {'total_balance': '12.345'},
              ],
            }),
          );
          await request.response.close();
        });

        final config = ProviderConfig(
          id: 'DeepSeek',
          enabled: true,
          name: 'DeepSeek',
          apiKey: 'deepseek-key',
          baseUrl: 'http://${server.address.address}:${server.port}/anthropic',
          providerType: ProviderKind.claude,
          balanceEnabled: true,
          balanceApiPath: '',
          balanceResultPath: 'balance_infos[0].total_balance',
        );

        expect(await ProviderBalanceService.fetchBalance(config), '12.35');
        expect(requests, hasLength(1));
        expect(requests.single.uri.path, '/user/balance');
        expect(
          requests.single.headers.value(HttpHeaders.authorizationHeader),
          'Bearer deepseek-key',
        );
      },
    );
  });

  group('ProviderConfig balance defaults', () {
    test('uses safe provider specific balance defaults', () {
      final aihubmix = ProviderConfig.defaultsFor('AIhubmix');
      final openRouter = ProviderConfig.defaultsFor('OpenRouter');
      final siliconFlow = ProviderConfig.defaultsFor('SiliconFlow');
      final vercel = ProviderConfig.defaultsFor('Vercel');
      final deepSeek = ProviderConfig.defaultsFor('DeepSeek');
      final moonshot = ProviderConfig.defaultsFor('Moonshot');

      expect(aihubmix.balanceEnabled, isTrue);
      expect(aihubmix.balanceApiPath, '/user/balance');
      expect(aihubmix.balanceResultPath, 'balance_infos[0].total_balance');
      expect(openRouter.balanceEnabled, isTrue);
      expect(openRouter.balanceApiPath, '/credits');
      expect(
        openRouter.balanceResultPath,
        'data.total_credits - data.total_usage',
      );
      expect(siliconFlow.balanceEnabled, isTrue);
      expect(siliconFlow.balanceApiPath, '/user/info');
      expect(siliconFlow.balanceResultPath, 'data.totalBalance');
      expect(vercel.balanceEnabled, isTrue);
      expect(vercel.balanceApiPath, '/credits');
      expect(vercel.balanceResultPath, 'balance');
      expect(deepSeek.providerType, ProviderKind.claude);
      expect(deepSeek.baseUrl, 'https://api.deepseek.com/anthropic');
      expect(deepSeek.balanceEnabled, isTrue);
      expect(deepSeek.balanceApiPath, '/user/balance');
      expect(deepSeek.balanceResultPath, 'balance_infos[0].total_balance');
      expect(moonshot.balanceEnabled, isTrue);
      expect(moonshot.balanceApiPath, '/users/me/balance');
      expect(moonshot.balanceResultPath, 'data.available_balance');
    });
  });
}
