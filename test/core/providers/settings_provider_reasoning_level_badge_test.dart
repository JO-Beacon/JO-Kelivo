import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 与上游有意分歧：上游该项默认关，本仓库默认开。
  test('showReasoningLevelBadge defaults on and round-trips', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    addTearDown(settings.dispose);
    await settings.loaded;
    expect(settings.showReasoningLevelBadge, isTrue);

    var notified = false;
    settings.addListener(() {
      notified = true;
    });
    await settings.setShowReasoningLevelBadge(false);
    expect(notified, isTrue);
    expect(settings.showReasoningLevelBadge, isFalse);
    expect(
      harness.preferences.getBool('display_show_reasoning_level_badge_v1'),
      isFalse,
    );

    final copied = settings.copyWith();
    addTearDown(copied.dispose);
    expect(copied.showReasoningLevelBadge, isFalse);

    final reloaded = SettingsProvider(harness.preferences);
    addTearDown(reloaded.dispose);
    await reloaded.loaded;
    expect(reloaded.showReasoningLevelBadge, isFalse);
  });

  test('showReasoningLevelBadge loads a persisted false value', () async {
    final harness = await createBusinessTestHarness(
      initial: const {'display_show_reasoning_level_badge_v1': false},
    );
    final settings = SettingsProvider(harness.preferences);
    addTearDown(settings.dispose);
    await settings.loaded;
    expect(settings.showReasoningLevelBadge, isFalse);
  });
}
