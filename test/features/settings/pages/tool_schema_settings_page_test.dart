import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/models/tool_schema_override.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/search/search_tool_service.dart';
import 'package:Kelivo/features/settings/pages/tool_schema_settings_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

import '../../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile editor saves tool and parameter descriptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1800);
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
          home: ToolSchemaSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(SearchToolService.toolName));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('tool-schema-description')),
        matching: find.byType(TextField),
      ),
      'Search only when current sources are needed.',
    );
    await tester.tap(find.text('Parameter descriptions (1)'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('tool-schema-param-query')),
        matching: find.byType(TextField),
      ),
      'Write a precise query.',
    );
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    final value = settings.toolSchemaOverrides[SearchToolService.toolName];
    expect(value?.description, 'Search only when current sources are needed.');
    expect(value?.paramDescriptions['query'], 'Write a precise query.');
    expect(find.text('Modified'), findsOneWidget);
  });

  testWidgets('restoring one tool to defaults removes its override', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;
    await settings.setToolSchemaOverride(
      SearchToolService.toolName,
      const ToolSchemaOverride(description: 'Custom'),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ToolSchemaSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(SearchToolService.toolName));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore default'));
    await tester.pump();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(settings.toolSchemaOverrides, isEmpty);
  });
}
