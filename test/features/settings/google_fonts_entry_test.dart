import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/fonts/google_fonts_service.dart';
import 'package:Kelivo/desktop/desktop_settings_page.dart';
import 'package:Kelivo/features/settings/pages/display_settings_page.dart';
import 'package:Kelivo/features/settings/pages/google_fonts_picker_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import '../../support/business_test_harness.dart';

class _FontPaths extends PathProviderPlatform {
  _FontPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previous;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('joaiclient-font-entry-');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FontPaths(root.path);
    final cache = File(
      p.join(root.path, 'cache', 'google_fonts', 'catalog.json'),
    );
    await cache.parent.create(recursive: true);
    await cache.writeAsString(
      jsonEncode({
        'items': [
          {
            'family': 'Cached Font',
            'files': {'regular': 'https://fonts.gstatic.com/cached.ttf'},
            'subsets': ['latin'],
          },
        ],
      }),
    );
  });
  tearDown(() async {
    PathProviderPlatform.instance = previous;
    await root.delete(recursive: true);
  });

  for (final desktop in [false, true]) {
    for (final forCode in [false, true]) {
      testWidgets(
        '字体入口正确保存到对应设置，desktop=$desktop code=$forCode',
        (tester) async {
          tester.view.physicalSize = desktop
              ? const Size(1400, 900)
              : const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late BusinessTestHarness business;
          late SettingsProvider settings;
          await tester.runAsync(() async {
            business = await createBusinessTestHarness();
            settings = SettingsProvider(business.preferences);
            await settings.loaded;
          });
          addTearDown(settings.dispose);
          await tester.pumpWidget(
            ChangeNotifierProvider.value(
              value: settings,
              child: MaterialApp(
                locale: const Locale('en'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: desktop
                    ? const Scaffold(body: DesktopSettingsPage())
                    : const DisplaySettingsPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (desktop) {
            await tester.tap(
              find.byTooltip('Google Fonts').at(forCode ? 1 : 0),
            );
          } else {
            final context = tester.element(find.byType(DisplaySettingsPage));
            final l10n = AppLocalizations.of(context)!;
            final entry = find.text(
              forCode
                  ? l10n.displaySettingsPageCodeFontTitle
                  : l10n.displaySettingsPageAppFontTitle,
            );
            await tester.scrollUntilVisible(entry, 200);
            await tester.tap(entry);
            await tester.pumpAndSettle();
            await tester.tap(find.text('Google Fonts'));
          }
          for (
            var i = 0;
            i < 40 && find.text('Cached Font').evaluate().isEmpty;
            i++
          ) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          await tester.pumpAndSettle();
          expect(find.byType(GoogleFontsPickerPage), findsOneWidget);
          expect(find.text('Cached Font'), findsOneWidget);
          expect(find.byType(Dialog), desktop ? findsOneWidget : findsNothing);
          if (desktop) {
            tester.view.physicalSize = const Size(600, 620);
            await tester.pumpAndSettle();
            expect(find.byType(Dialog), findsOneWidget);
            expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          final page = tester.widget<GoogleFontsPickerPage>(
            find.byType(GoogleFontsPickerPage),
          );
          await tester.runAsync(() async {
            final downloadDirectory = await Directory(
              p.join(root.path, 'test-download'),
            ).create();
            final source = await File(
              'dependencies/gpt_markdown/lib/fonts/JetBrainsMono-Regular.ttf',
            ).copy(p.join(downloadDirectory.path, 'font.ttf'));
            final download = DownloadedGoogleFont(
              file: source,
              license: 'Test font license',
            );
            expect(await page.onApply(download), isTrue);
            await download.dispose();
            final path = business.preferences.getString(
              forCode
                  ? 'display_code_font_local_path_v1'
                  : 'display_app_font_local_path_v1',
            )!;
            expect(await File(path).exists(), isTrue);
            expect(
              await File('$path.license.txt').readAsString(),
              'Test font license',
            );
          });
          expect(
            forCode ? settings.codeFontLocalAlias : settings.appFontLocalAlias,
            isNotEmpty,
          );
          expect(
            forCode ? settings.appFontLocalAlias : settings.codeFontLocalAlias,
            isNull,
          );
          await tester.tap(find.byTooltip('Close'));
          await tester.pumpAndSettle();
          expect(find.byType(GoogleFontsPickerPage), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant.only(
          desktop ? TargetPlatform.windows : TargetPlatform.android,
        ),
      );
    }
  }
}
