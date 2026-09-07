import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/business_settings_router.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';

import 'support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('assistant paragraph splitting defaults to disabled', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    expect(settings.assistantBubbleSplitParagraphs, isFalse);
  });

  test('assistant paragraph splitting persists and reloads', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    await settings.setAssistantBubbleSplitParagraphs(true);

    expect(
      harness.preferences.getBool(
        'display_assistant_bubble_split_paragraphs_v1',
      ),
      isTrue,
    );
    final reloaded = SettingsProvider(harness.preferences);
    await reloaded.loaded;
    expect(reloaded.assistantBubbleSplitParagraphs, isTrue);
  });

  test('assistant paragraph splitting enters business backup preferences', () {
    expect(
      BusinessKeyRegistry.classify(
        'display_assistant_bubble_split_paragraphs_v1',
      ),
      BusinessKeyDisposition.preference,
    );
  });
}
