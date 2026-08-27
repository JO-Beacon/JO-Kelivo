import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/memory/memory_prompts.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('memory advanced settings use approved defaults', () async {
    final harness = await createBusinessTestHarness();
    addTearDown(harness.close);
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.memoryMigrationBatchSize, 12);
    expect(settings.memoryInjectionMaxItems, 10);
    expect(settings.memoryMigratePromptZh, MemoryPrompts.migrateZh);
    expect(settings.memoryMigratePromptEn, MemoryPrompts.migrateEn);
    expect(settings.legacyMemoryPromptZh, MemoryPrompts.legacyRulesZh);
    expect(settings.legacyMemoryPromptEn, MemoryPrompts.legacyRulesEn);
  });

  test('memory advanced settings persist and clamp numeric values', () async {
    final harness = await createBusinessTestHarness();
    addTearDown(harness.close);
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    await settings.setMemoryMigrationBatchSize(99);
    await settings.setMemoryInjectionMaxItems(0);
    await settings.setMemoryMigratePromptZh('自定义迁移提示词');
    await settings.setLegacyMemoryPromptEn('Custom legacy prompt');

    final reloaded = SettingsProvider(harness.preferences);
    await reloaded.loaded;

    expect(reloaded.memoryMigrationBatchSize, 24);
    expect(reloaded.memoryInjectionMaxItems, 1);
    expect(reloaded.memoryMigratePromptZh, '自定义迁移提示词');
    expect(reloaded.legacyMemoryPromptEn, 'Custom legacy prompt');

    await reloaded.setMemoryInjectionMaxItems(101);
    expect(reloaded.memoryInjectionMaxItems, 100);
  });
}
