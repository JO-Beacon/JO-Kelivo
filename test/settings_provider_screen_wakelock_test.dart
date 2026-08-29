import 'support/business_test_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/screen_wakelock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(ScreenWakelock.debugReset);

  test('screen wakelock setting defaults to disabled', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.keepScreenOnDuringGeneration, isFalse);
    expect(
      harness.preferences.getBool(
        'display_keep_screen_on_during_generation_v1',
      ),
      isNull,
    );
  });

  test('screen wakelock setting persists changes', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;
    await settings.setKeepScreenOnDuringGeneration(true);

    expect(settings.keepScreenOnDuringGeneration, isTrue);
    expect(
      harness.preferences.getBool(
        'display_keep_screen_on_during_generation_v1',
      ),
      isTrue,
    );

    await settings.setKeepScreenOnDuringGeneration(false);
    expect(settings.keepScreenOnDuringGeneration, isFalse);
    expect(
      harness.preferences.getBool(
        'display_keep_screen_on_during_generation_v1',
      ),
      isFalse,
    );
  });

  test('screen wakelock setting loads a persisted value', () async {
    final harness = await createBusinessTestHarness(
      initial: {'display_keep_screen_on_during_generation_v1': true},
    );
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.keepScreenOnDuringGeneration, isTrue);
  });
}
