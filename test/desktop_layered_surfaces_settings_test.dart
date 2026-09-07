import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/desktop/desktop_settings_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop display settings expose the layered surfaces switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;
    expect(settings.useLayeredSurfaces, isFalse);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>(
            create: (_) =>
                AssistantProvider(preferences: createBusinessTestPreferences()),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DesktopSettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final label = find.text('Layered surfaces');
    expect(label, findsOneWidget);
    await tester.ensureVisible(label);
    final row = find.ancestor(of: label, matching: find.byType(Row)).first;
    final toggle = find.descendant(of: row, matching: find.byType(IosSwitch));
    expect(tester.widget<IosSwitch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pump();

    expect(settings.useLayeredSurfaces, isTrue);

    await tester.tap(toggle);
    await tester.pump();

    expect(settings.useLayeredSurfaces, isFalse);
  });
}
