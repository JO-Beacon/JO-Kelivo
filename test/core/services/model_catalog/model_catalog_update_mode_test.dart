import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/provider/widgets/model_catalog_panel.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/core/services/model_catalog/model_catalog_service.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/core/services/network/provider_http_client.dart';

import '../../../support/business_test_harness.dart';

/// 只记录是否被调用，不做真实联网。
class _CountingClient extends http.BaseClient {
  _CountingClient(this.requests);

  final List<http.Request> requests;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{}')),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

ModelCatalogService _service(List<http.Request> requests) {
  return ModelCatalogService(
    // 无效的内置数据：目录始终没加载成功，isStale 恒为真，便于观察刷新决策。
    loadBundledJson: () async => '{}',
    cacheDirectory: () async =>
        Directory.systemTemp.createTemp('catalog_mode_test_'),
    clientFactory: () => _CountingClient(requests),
    now: () => DateTime.utc(2026, 1, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认是手动更新，不自动联网', () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    final service = _service(requests);

    expect(service.updateMode, ModelCatalogUpdateMode.manual);

    await service.maybeAutoRefresh();
    expect(requests, isEmpty);
  });

  test('更新方式会持久化，未知值回退到手动', () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    final service = _service(requests);
    await service.setUpdateMode(ModelCatalogUpdateMode.daily);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kModelCatalogUpdateModePrefsKey), 'daily');

    final reopened = _service(requests);
    await reopened.ensureLoaded();
    expect(reopened.updateMode, ModelCatalogUpdateMode.daily);

    SharedPreferences.setMockInitialValues({
      kModelCatalogUpdateModePrefsKey: 'unknown-value',
    });
    final fallback = _service(requests);
    await fallback.ensureLoaded();
    expect(fallback.updateMode, ModelCatalogUpdateMode.manual);
  });

  test('24 小时模式且数据陈旧时会联网刷新', () async {
    SharedPreferences.setMockInitialValues({
      kModelCatalogUpdateModePrefsKey: 'daily',
    });
    final requests = <http.Request>[];
    final service = _service(requests);

    await service.maybeAutoRefresh();

    expect(requests, hasLength(1));
    expect(requests.single.url.toString(), kModelCatalogRemoteUri.toString());
  });

  test('切回手动后不再自动联网', () async {
    SharedPreferences.setMockInitialValues({
      kModelCatalogUpdateModePrefsKey: 'daily',
    });
    final requests = <http.Request>[];
    final service = _service(requests);
    await service.setUpdateMode(ModelCatalogUpdateMode.manual);

    await service.maybeAutoRefresh();

    expect(requests, isEmpty);
  });

  test('全局代理设置映射成网络配置', () async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    expect(globalProxyConfigFor(settings), isNull);

    await settings.setGlobalProxyEnabled(true);
    // 只开了开关但没填地址时不算有效配置。
    expect(globalProxyConfigFor(settings), isNull);

    await settings.setGlobalProxyHost('proxy.example.com');
    await settings.setGlobalProxyPort('1080');
    await settings.setGlobalProxyType('socks5');
    await settings.setGlobalProxyUsername('user');
    await settings.setGlobalProxyPassword('secret');

    final config = globalProxyConfigFor(settings);
    expect(config, isNotNull);
    expect(config!.enabled, isTrue);
    expect(config.type, 'socks5');
    expect(config.host, 'proxy.example.com');
    expect(config.port, 1080);
    expect(config.username, 'user');
    expect(config.password, 'secret');
  });

  testWidgets('面板能切换更新方式，勾选跟着走', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    final catalog = ModelCatalogService(
      // 永不完成：避免真实加载与后台通知干扰组件测试。
      loadBundledJson: () => Completer<String>().future,
      clientFactory: () => _CountingClient(requests),
    );

    // IosNavRow 的触感反馈会读 SettingsProvider。
    final settings = SettingsProvider(createBusinessTestPreferences());
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ModelCatalogPanel(catalog: catalog)),
        ),
      ),
    );
    await tester.pump();

    final manualRow = find.byKey(const ValueKey('model-catalog-update-manual'));
    final dailyRow = find.byKey(const ValueKey('model-catalog-update-daily'));
    expect(manualRow, findsOneWidget);
    expect(dailyRow, findsOneWidget);
    expect(find.byKey(const ValueKey('model-catalog-refresh')), findsOneWidget);

    // 未选中的那行只有占位，没有勾。
    IconData? checkIconIn(Finder row) {
      final icons = find.descendant(of: row, matching: find.byType(Icon));
      if (icons.evaluate().isEmpty) return null;
      return tester.widget<Icon>(icons).icon;
    }

    // 默认手动：只有手动那行带勾。
    expect(checkIconIn(manualRow), Lucide.Check);
    expect(checkIconIn(dailyRow), isNull);

    await tester.tap(dailyRow);
    await tester.pump();

    expect(catalog.updateMode, ModelCatalogUpdateMode.daily);
    expect(checkIconIn(dailyRow), Lucide.Check);
    expect(checkIconIn(manualRow), isNull);
  });
}
