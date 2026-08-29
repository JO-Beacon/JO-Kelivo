import 'support/business_test_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'title generation is disabled until a model is explicitly selected',
    () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      expect(settings.isTitleGenerationEnabled, isFalse);

      await settings.setTitleModel('TestProvider', 'title-model');
      expect(settings.isTitleGenerationEnabled, isTrue);

      await settings.resetTitleModel();
      expect(settings.isTitleGenerationEnabled, isFalse);
    },
  );
}
