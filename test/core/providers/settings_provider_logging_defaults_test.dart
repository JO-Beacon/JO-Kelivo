import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/logging/context_logger.dart';
import 'package:Kelivo/core/services/network/request_logger.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await ContextLogger.setEnabled(false);
    await RequestLogger.setEnabled(false);
  });

  test('fresh settings use the approved memory and logging defaults', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.legacyMemoryMode, isFalse);
    expect(settings.requestLogEnabled, isTrue);
    expect(settings.contextLogEnabled, isTrue);
    expect(settings.logSaveOutput, isFalse);
    expect(settings.logElideLargePayloads, isTrue);
    expect(settings.logMaxSizeMB, 50);
    expect(settings.newChatOnLaunch, isFalse);
  });
}
