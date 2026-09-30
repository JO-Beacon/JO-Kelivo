import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/desktop/add_provider_dialog.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/theme/theme_factory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsProvider settings;
  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
  });
  tearDown(() => settings.dispose());

  Widget app(Widget child) {
    return ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(null),
        home: Scaffold(body: child),
      ),
    );
  }

  testWidgets(
    'add button is hidden on the presets tab and shown on every form',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showDesktopAddProviderDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      Future<void> openTab(String label) async {
        // 厂商名会在预设列表里重名，页签在结构中排在前面。
        final tab = find.text(label).first;
        await tester.tap(tab);
        await tester.pumpAndSettle();
      }

      // 预设页只负责预填，提交是空操作，因此不给按钮。
      expect(find.text('Add'), findsNothing, reason: '预设页不应有添加按钮');

      // 三个表单页都必须能提交。
      for (final label in const ['OpenAI', 'Google', 'Claude']) {
        await openTab(label);
        expect(find.text('Add'), findsOneWidget, reason: '$label 页应有添加按钮');
      }

      await openTab('Presets');
      expect(find.text('Add'), findsNothing, reason: '切回预设页后按钮应再次隐藏');
      expect(tester.takeException(), isNull);
    },
  );
}
