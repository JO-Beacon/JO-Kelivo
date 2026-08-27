import 'support/business_test_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an explicitly empty OCR prompt survives reload', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    await settings.setOcrPrompt('   ');
    expect(settings.ocrPrompt, isEmpty);
    expect(harness.preferences.getString('ocr_prompt_v1'), isEmpty);

    final reloaded = SettingsProvider(harness.preferences);
    await reloaded.loaded;
    expect(reloaded.ocrPrompt, isEmpty);
  });

  test('an unset OCR prompt still uses the default', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;
    expect(settings.ocrPrompt, SettingsProvider.defaultOcrPrompt);
  });
}
