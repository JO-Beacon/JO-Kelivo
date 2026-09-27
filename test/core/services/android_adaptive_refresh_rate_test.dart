import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/android_refresh_rate_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.refresh_rate');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'Android applies, toggles and reloads the adaptive refresh preference',
    (tester) async {
      final preferences = createBusinessTestPreferences();
      final settings = SettingsProvider(preferences);
      addTearDown(settings.dispose);
      await settings.loaded;
      expect(settings.androidAdaptiveRefreshRate, isFalse);
      // 启动时把默认值（固定最高刷新率）下发一次。
      expect(calls.map((call) => call.arguments['adaptive']), [false]);

      await settings.setAndroidAdaptiveRefreshRate(true);
      expect(settings.androidAdaptiveRefreshRate, isTrue);
      expect(settings.copyWith().androidAdaptiveRefreshRate, isTrue);
      final reloaded = SettingsProvider(preferences);
      addTearDown(reloaded.dispose);
      await reloaded.loaded;
      expect(reloaded.androidAdaptiveRefreshRate, isTrue);

      final local = await SharedPreferences.getInstance();
      expect(local.getBool(AndroidRefreshRateService.adaptiveKey), isTrue);
      // 只存本机：业务库不应写入该键。
      expect(
        preferences.getBool(AndroidRefreshRateService.adaptiveKey),
        isNull,
      );
      expect(calls.map((call) => call.arguments['adaptive']), [
        false,
        true,
        true,
      ]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'adaptive refresh availability is gated to Android API 30+',
    (tester) async {
      addTearDown(() => AndroidRefreshRateService.debugSetSdkInt(null));
      AndroidRefreshRateService.debugSetSdkInt(29);
      expect(AndroidRefreshRateService.supportsAdaptiveRefreshRate, isFalse);
      AndroidRefreshRateService.debugSetSdkInt(30);
      expect(AndroidRefreshRateService.supportsAdaptiveRefreshRate, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'other platforms ignore the adaptive refresh preference',
    (tester) async {
      final settings = SettingsProvider(
        createBusinessTestPreferences(
          localInitial: {AndroidRefreshRateService.adaptiveKey: true},
        ),
      );
      addTearDown(settings.dispose);
      await settings.loaded;
      expect(settings.androidAdaptiveRefreshRate, isFalse);

      await settings.setAndroidAdaptiveRefreshRate(true);
      expect(calls, isEmpty);
      expect(settings.androidAdaptiveRefreshRate, isFalse);
    },
    variant: TargetPlatformVariant(
      TargetPlatform.values.where((p) => p != TargetPlatform.android).toSet(),
    ),
  );
}
