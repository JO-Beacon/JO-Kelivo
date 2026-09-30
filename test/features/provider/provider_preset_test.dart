import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/provider_preset.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/provider/widgets/add_provider_sheet.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_tile_button.dart';
import 'package:Kelivo/theme/theme_factory.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('vendor preset keys are unique and resolve to usable defaults', () {
    expect(ProviderPreset.vendorKeys, hasLength(13));
    expect(ProviderPreset.vendorKeys.toSet(), hasLength(13));
    for (final key in ProviderPreset.vendorKeys) {
      final config = ProviderConfig.defaultsFor(key);
      expect(config.baseUrl, isNotEmpty, reason: key);
      // 协议类型必须可判定；预设页依赖它决定切到哪个表单。
      ProviderConfig.classify(key);
    }
  });

  testWidgets('picking a vendor preset prefills the matching form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildLightTheme(null),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: IosTileButton(
                  label: 'Add',
                  icon: LucideIcons.plus,
                  onTap: () => showAddProviderSheet(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek'), findsOneWidget);
    await tester.ensureVisible(find.text('DeepSeek'));
    await tester.tap(find.text('DeepSeek'));
    await tester.pumpAndSettle();

    // 切到 OpenAI 表单，并按预设填好名称与地址。
    expect(find.text('API Base Url'), findsOneWidget);
    // ListView 可能只构建到可见区域，这里只要求名称与地址两个字段可用。
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList(growable: false);
    expect(fields.length, greaterThanOrEqualTo(3));
    expect(fields[0].controller!.text, 'DeepSeek');
    expect(
      fields[2].controller!.text,
      ProviderConfig.defaultsFor('DeepSeek').baseUrl,
    );
    expect(tester.takeException(), isNull);
  });
}
