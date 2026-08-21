import "support/business_test_harness.dart";
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider regeneration preferences', () {
    test(
      'defaults keep the regeneration confirmation dialog enabled',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);

        await settings.loaded;

        expect(settings.showRegenerateConfirmDialog, isTrue);
      },
    );

    test('loads the persisted regeneration confirmation value', () async {
      final harness = await createBusinessTestHarness(
        initial: {'display_show_regenerate_confirm_dialog_v1': false},
      );
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.showRegenerateConfirmDialog, isFalse);
    });

    test('persists regeneration confirmation changes', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      await settings.setShowRegenerateConfirmDialog(false);

      expect(settings.showRegenerateConfirmDialog, isFalse);

      final prefs = harness.preferences;
      expect(
        prefs.getBool('display_show_regenerate_confirm_dialog_v1'),
        isFalse,
      );
    });
  });
}
