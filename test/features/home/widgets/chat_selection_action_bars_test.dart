import "../../../support/business_test_harness.dart";
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/home/widgets/chat_selection_delete_bar.dart';
import 'package:Kelivo/features/home/widgets/chat_selection_export_bar.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/shared/widgets/ios_tactile.dart';
import 'package:Kelivo/theme/app_font_weights.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpBar(WidgetTester tester, Widget child) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(createBusinessTestPreferences()),
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(width: 420, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('分享导出栏不展示删除操作', (tester) async {
    await _pumpBar(
      tester,
      ChatSelectionExportBar(
        onExportMarkdown: () {},
        onExportTxt: () {},
        onExportImage: () {},
        showThinkingTools: false,
        showThinkingContent: false,
        onToggleThinkingTools: () {},
        onToggleThinkingContent: () {},
      ),
    );

    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('MD'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Delete Selected'), findsNothing);
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    expect(find.text(l10n.homePageDeleteMessage), findsNothing);
    expect(find.text(l10n.homePageDeleteAllVersions), findsNothing);
  });

  testWidgets('删除栏在单版本选择时只展示普通删除', (tester) async {
    var currentVersionDeletes = 0;
    var allVersionDeletes = 0;

    await _pumpBar(
      tester,
      ChatSelectionDeleteBar(
        hasMultiVersionSelection: false,
        onDeleteCurrentVersions: () {
          currentVersionDeletes++;
        },
        onDeleteAllVersions: () {
          allVersionDeletes++;
        },
      ),
    );

    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    expect(find.text(l10n.homePageDelete), findsOneWidget);
    expect(find.text(l10n.homePageDeleteMessage), findsNothing);
    expect(find.text(l10n.homePageDeleteAllVersions), findsNothing);
    expect(tester.getSize(find.byType(IosCardPress)).width, closeTo(396, 0.1));
    expect(
      tester.widget<Text>(find.text(l10n.homePageDelete)).style?.fontWeight,
      AppFontWeights.medium,
    );

    await tester.tap(find.text(l10n.homePageDelete));
    expect(currentVersionDeletes, 1);
    expect(allVersionDeletes, 0);
  });

  testWidgets('删除栏在多版本选择时展示当前分支和所有分支', (tester) async {
    var currentVersionDeletes = 0;
    var allVersionDeletes = 0;

    await _pumpBar(
      tester,
      ChatSelectionDeleteBar(
        hasMultiVersionSelection: true,
        onDeleteCurrentVersions: () {
          currentVersionDeletes++;
        },
        onDeleteAllVersions: () {
          allVersionDeletes++;
        },
      ),
    );

    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    expect(find.text(l10n.homePageDeleteMessage), findsOneWidget);
    expect(find.text(l10n.homePageDeleteAllVersions), findsOneWidget);

    await tester.tap(find.text(l10n.homePageDeleteMessage));
    await tester.tap(find.text(l10n.homePageDeleteAllVersions));

    expect(currentVersionDeletes, 1);
    expect(allVersionDeletes, 1);
  });
}
