import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/tool_schema_override.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/app_exit_flush.dart';

import 'support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(AppExitFlush.debugReset);

  test('tool schema overrides default to empty', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    expect(settings.toolSchemaOverrides, isEmpty);
  });

  test('set persists to business preferences and reloads', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    const value = ToolSchemaOverride(
      description: 'Custom search',
      paramDescriptions: {'query': 'Look this up'},
    );
    await settings.setToolSchemaOverride('search_web', value);

    expect(settings.toolSchemaOverrides['search_web'], value);
    expect(
      jsonDecode(harness.preferences.getString('tool_schema_overrides_v1')!),
      <String, dynamic>{
        'search_web': {
          'description': 'Custom search',
          'paramDescriptions': {'query': 'Look this up'},
        },
      },
    );

    final reloaded = SettingsProvider(harness.preferences);
    addTearDown(reloaded.dispose);
    await reloaded.loaded;
    expect(reloaded.toolSchemaOverrides['search_web'], value);
  });

  test('empty and reset-all remove persisted overrides', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    await settings.setToolSchemaOverride(
      'search_web',
      const ToolSchemaOverride(description: 'custom'),
    );
    await settings.resetToolSchemaOverride('search_web');
    expect(settings.toolSchemaOverrides, isEmpty);
    expect(harness.preferences.getString('tool_schema_overrides_v1'), isNull);

    await settings.setToolSchemaOverride(
      'search_web',
      const ToolSchemaOverride(description: 'custom'),
    );
    await settings.resetAllToolSchemaOverrides();
    expect(settings.toolSchemaOverrides, isEmpty);
    expect(harness.preferences.getString('tool_schema_overrides_v1'), isNull);
  });

  test('invalid stored JSON does not block settings load', () async {
    final harness = await createBusinessTestHarness(
      initial: const <String, Object?>{'tool_schema_overrides_v1': '{broken'},
    );
    final settings = SettingsProvider(harness.preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    expect(settings.toolSchemaOverrides, isEmpty);
  });

  test(
    'live edits are debounced and exit flush persists the final value',
    () async {
      final harness = await createBusinessTestHarness();
      final settings = SettingsProvider(harness.preferences);
      addTearDown(settings.dispose);
      await settings.loaded;

      settings.setToolSchemaOverrideLive(
        'search_web',
        const ToolSchemaOverride(description: 'first'),
      );
      settings.setToolSchemaOverrideLive(
        'search_web',
        const ToolSchemaOverride(description: 'final'),
      );
      expect(harness.preferences.getString('tool_schema_overrides_v1'), isNull);

      await AppExitFlush.flushAll();
      expect(
        jsonDecode(harness.preferences.getString('tool_schema_overrides_v1')!),
        <String, dynamic>{
          'search_web': {'description': 'final'},
        },
      );
    },
  );

  test(
    'reset-all clears an older persisted value during a pending live reset',
    () async {
      final harness = await createBusinessTestHarness();
      final settings = SettingsProvider(harness.preferences);
      addTearDown(settings.dispose);
      await settings.loaded;
      await settings.setToolSchemaOverride(
        'search_web',
        const ToolSchemaOverride(description: 'persisted'),
      );

      settings.setToolSchemaOverrideLive(
        'search_web',
        const ToolSchemaOverride(),
      );
      expect(settings.toolSchemaOverrides, isEmpty);
      expect(
        harness.preferences.getString('tool_schema_overrides_v1'),
        isNotNull,
      );

      await settings.resetAllToolSchemaOverrides();
      expect(harness.preferences.getString('tool_schema_overrides_v1'), isNull);
    },
  );
}
