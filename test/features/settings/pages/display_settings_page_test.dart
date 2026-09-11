import "../../../support/business_test_harness.dart";
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/settings/pages/display_settings_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('input background opacity sheet shows light and dark controls', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DisplaySettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('82%'), findsOneWidget);
    expect(find.textContaining('Light 82% / Dark 74%'), findsNothing);

    final opacityRow = find.text('Input Box Background Opacity');
    await tester.scrollUntilVisible(opacityRow, 240);
    await tester.pumpAndSettle();

    await tester.tap(opacityRow);
    await tester.pumpAndSettle();

    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.byType(SfSlider), findsNWidgets(2));
  });

  testWidgets('behavior settings open the auto retry panel', (
    tester,
  ) async {
    final preferences = createBusinessTestPreferences();
    final settings = SettingsProvider(preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DisplaySettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Behavior & startup'));
    await tester.pumpAndSettle();

    final label = find.text('Auto Retry');
    expect(label, findsOneWidget);

    await tester.tap(label);
    await tester.pumpAndSettle();

    expect(find.text('Enable auto-retry'), findsOneWidget);
    expect(find.text('Max retries'), findsOneWidget);
  });

  testWidgets('the first-turn placeholder starts off and reveals its field', (
    tester,
  ) async {
    final preferences = createBusinessTestPreferences();
    final settings = SettingsProvider(preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DisplaySettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Behavior & startup'));
    await tester.pumpAndSettle();

    final switchLabel = find.text('First Message Placeholder');
    // 补位内容那个输入框自己带一个 Scrollable，所以这里必须点名外层列表。
    await tester.scrollUntilVisible(
      switchLabel,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // 默认关闭：补位内容不显示。
    expect(settings.claudeFirstTurnPlaceholderEnabled, isFalse);
    expect(find.text('Placeholder Content'), findsNothing);

    await tester.tap(switchLabel);
    await tester.pumpAndSettle();

    // 打开后才显示内容行，预填默认的井号。
    expect(settings.claudeFirstTurnPlaceholderEnabled, isTrue);
    expect(find.text('Placeholder Content'), findsOneWidget);
    expect(find.text('#'), findsOneWidget);
  });
}
