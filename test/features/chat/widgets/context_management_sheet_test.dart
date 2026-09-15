import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/chat/widgets/context_management_sheet.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

Future<void> _pumpSheet(
  WidgetTester tester, {
  String? clearLabel,
  String? messageCountLabel,
}) async {
  await tester.pumpWidget(
    MaterialApp(
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
          child: SizedBox(
            width: 420,
            child: ContextManagementSheet(
              clearLabel: clearLabel,
              messageCountLabel: messageCountLabel,
              onCompress: () {},
              onClear: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 面板上全部文本。计数标签一律以数字开头，正文描述不会，故可用它定位计数。
List<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .toList();

void main() {
  testWidgets('面板在屏蔽那一行的右侧显示上下文消息条数', (tester) async {
    await _pumpSheet(
      tester,
      clearLabel: 'Temporarily Mask Context',
      messageCountLabel: '2/10 messages',
    );

    expect(find.text('Temporarily Mask Context'), findsOneWidget);
    expect(find.text('2/10 messages'), findsOneWidget);
    expect(_texts(tester).where((t) => RegExp(r'^\d').hasMatch(t)).toList(), [
      '2/10 messages',
    ]);
  });

  testWidgets('没给条数时右侧不出现任何计数文本', (tester) async {
    await _pumpSheet(tester, clearLabel: 'Temporarily Mask Context');

    expect(find.text('Temporarily Mask Context'), findsOneWidget);
    expect(
      _texts(tester).where((t) => RegExp(r'^\d').hasMatch(t)).toList(),
      isEmpty,
    );
  });

  testWidgets('条数文案由 l10n 生成，设了上限时报实际值／上限', (tester) async {
    await _pumpSheet(tester, messageCountLabel: '2/10 messages');
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ContextManagementSheet)),
    )!;

    expect(l10n.contextMessageCount(12), '12 messages');
    expect(l10n.contextMessageCountLimited(2, 10), '2/10 messages');
  });
}
