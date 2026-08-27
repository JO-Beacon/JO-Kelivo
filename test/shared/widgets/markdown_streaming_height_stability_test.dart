import '../../support/business_test_harness.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/markdown_with_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  Future<double> renderHeight(
    WidgetTester tester,
    String text, {
    required bool streaming,
    TextStyle? style,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: MarkdownWithCodeHighlight(
                text: text,
                streaming: streaming,
                baseStyle: style,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return tester.getSize(find.byType(MarkdownWithCodeHighlight)).height;
  }

  String paddedParagraph(int index) =>
      'Body $index. ${'The rain kept falling on the quiet street. ' * 16}';

  Future<void> expectSameHeight(
    WidgetTester tester,
    List<String> blocks, {
    TextStyle? style,
  }) async {
    final text = blocks.join('\n\n');
    final streaming = await renderHeight(
      tester,
      text,
      streaming: true,
      style: style,
    );
    final finished = await renderHeight(
      tester,
      text,
      streaming: false,
      style: style,
    );
    expect(streaming, finished);
  }

  testWidgets('长段落在流式和完成态保持相同高度', (tester) async {
    tester.view.physicalSize = const Size(1170, 2100);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await expectSameHeight(tester, [
      paddedParagraph(1),
      paddedParagraph(2),
      paddedParagraph(3),
      paddedParagraph(4),
    ]);
    await expectSameHeight(tester, [
      paddedParagraph(1),
      paddedParagraph(2),
    ], style: const TextStyle(fontSize: 20, height: 1.5));
  });

  testWidgets('列表边界不会重复加入段落分隔高度', (tester) async {
    tester.view.physicalSize = const Size(1170, 2100);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await expectSameHeight(tester, [
      '- one\n- two\n- three',
      paddedParagraph(1),
    ]);
    await expectSameHeight(tester, [
      paddedParagraph(1),
      '- one\n- two\n- three',
    ]);
  });

  testWidgets('复杂空行和特殊块在流式与完成态保持相同高度', (tester) async {
    tester.view.physicalSize = const Size(1170, 2100);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final body = paddedParagraph(1);
    for (final text in [
      '$body\n\n\nNext paragraph.',
      '$body\n \nNext paragraph.',
      '$body\n\n---\n\nNext paragraph.',
      '$body\n\n# Heading #\n\nNext paragraph.',
      '$body\n\n\$\$\na + b\n\$\$\n\nNext paragraph.',
    ]) {
      final streaming = await renderHeight(tester, text, streaming: true);
      final finished = await renderHeight(tester, text, streaming: false);
      expect(streaming, finished, reason: text);
    }
  });
}
