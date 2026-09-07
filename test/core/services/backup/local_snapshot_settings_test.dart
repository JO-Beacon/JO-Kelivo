import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/backup/local_snapshot_settings.dart';

import '../../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local snapshots default to enabled and persist an explicit disable',
    () async {
      final harness = await createBusinessTestHarness(initial: {});
      final preferences = harness.preferences;
      final store = LocalSnapshotPreferences(preferences);

      expect(store.readSettings().enabled, isTrue);
      await store.writeSettings(store.readSettings().copyWith(enabled: false));
      expect(store.readSettings().enabled, isFalse);
      expect(preferences.getBool(LocalSnapshotPreferences.enabledKey), isFalse);
    },
  );

  test('snapshot retention count is clamped to a safe range', () async {
    final harness = await createBusinessTestHarness(
      initial: {LocalSnapshotPreferences.keepRecentKey: 100},
    );
    final preferences = harness.preferences;
    expect(LocalSnapshotPreferences(preferences).readSettings().keepRecent, 10);
  });
}
