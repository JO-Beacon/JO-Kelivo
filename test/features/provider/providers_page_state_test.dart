import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/provider/pages/providers_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/theme/theme_factory.dart';

import '../../support/business_test_harness.dart';

Widget _app(SettingsProvider settings) =>
    ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(null),
        home: const ProvidersPage(),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty provider list shows the onboarding hint', (tester) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(_app(settings));
    await tester.pumpAndSettle();

    expect(
      find.text('No providers yet. Add one to get started.'),
      findsOneWidget,
    );
    expect(find.text('Add provider'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('list shows every configured provider with no built-in filter', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;
    for (final key in <String>['KelivoIN', '随想AI中转站']) {
      await settings.setProviderConfig(key, settings.getProviderConfig(key));
    }

    await tester.pumpWidget(_app(settings));
    await tester.pumpAndSettle();

    expect(find.text('KelivoIN'), findsOneWidget);
    expect(find.text('随想AI中转站'), findsOneWidget);
    // 不再有空列表引导。
    expect(
      find.text('No providers yet. Add one to get started.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('corrupted provider config shows error and reset flow', (
    tester,
  ) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = BusinessRepository(database);
    await repository.setPreference('provider_configs_v1', '{bad json');

    final settings = SettingsProvider(BusinessPreferences(repository));
    addTearDown(settings.dispose);
    await settings.loaded;
    expect(settings.providerConfigsCorrupted, isTrue);

    await tester.pumpWidget(_app(settings));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Provider settings failed to load'),
      findsOneWidget,
    );

    await tester.tap(find.text('Reset provider settings'));
    await tester.pumpAndSettle();
    expect(find.text('Reset provider settings?'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    expect(settings.providerConfigsCorrupted, isFalse);
    expect(
      find.textContaining('Provider settings failed to load'),
      findsNothing,
    );
    expect(
      find.text('No providers yet. Add one to get started.'),
      findsOneWidget,
    );
    // 冲掉重置成功的提示条计时器，避免遗留定时器。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
