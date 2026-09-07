import 'support/business_test_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'title generation defaults enabled and can be disabled explicitly',
    () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      expect(settings.isTitleGenerationEnabled, isTrue);

      await settings.setTitleModel('TestProvider', 'title-model');
      expect(settings.isTitleGenerationEnabled, isTrue);

      await settings.disableTitleGeneration();
      expect(settings.isTitleGenerationEnabled, isFalse);
      expect(settings.titleModelKey, isNull);

      await settings.resetTitleModel();
      expect(settings.isTitleGenerationEnabled, isTrue);
    },
  );

  test('legacy title model configuration remains enabled', () async {
    final harness = await createBusinessTestHarness(
      initial: {'title_model_v1': 'TestProvider::title-model'},
    );
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;
    expect(settings.isTitleGenerationEnabled, isTrue);
    expect(settings.titleModelKey, 'TestProvider::title-model');
  });
}
