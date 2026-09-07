import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/search/search_tool_service.dart';
import 'package:Kelivo/desktop/setting/tool_schemas_pane.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

import '../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop editor updates live and reset-all remounts defaults', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DesktopToolSchemasPane()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final descriptionField = find.descendant(
      of: find.byKey(const ValueKey('tool-schema-description')),
      matching: find.byType(TextField),
    );
    await tester.enterText(descriptionField, 'Custom desktop wording');
    await tester.pump();
    expect(
      settings.toolSchemaOverrides[SearchToolService.toolName]?.description,
      'Custom desktop wording',
    );

    await tester.tap(find.text('Restore all defaults'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(settings.toolSchemaOverrides, isEmpty);
    expect(
      tester.widget<TextField>(descriptionField).controller?.text,
      SearchToolService.toolDescription,
    );
  });
}
