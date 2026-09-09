import 'dart:convert';

import 'package:Kelivo/core/models/auto_retry_options.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AutoRetryConfig.current = const AutoRetryOptions.defaults();
  });

  test('automatic retry defaults to enabled', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.autoRetryEnabled, isTrue);
    expect(AutoRetryConfig.current.enabled, isTrue);
  });

  test(
    'automatic retry loads and persists an explicit disabled value',
    () async {
      final harness = await createBusinessTestHarness(
        initial: {'display_auto_retry_enabled_v1': false},
      );
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;
      // 旧 D10 布尔键经一次性迁移种子到新 JSON 配置的 enabled。
      expect(settings.autoRetryEnabled, isFalse);
      expect(AutoRetryConfig.current.enabled, isFalse);

      await settings.setAutoRetryEnabled(true);

      expect(settings.autoRetryEnabled, isTrue);
      expect(AutoRetryConfig.current.enabled, isTrue);
      final stored = harness.preferences.getString('auto_retry_options');
      expect(stored, isNotNull);
      expect(
        AutoRetryOptions.fromJson(
          jsonDecode(stored!) as Map<String, dynamic>,
        ).enabled,
        isTrue,
      );
    },
  );
}
