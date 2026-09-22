import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/shared/widgets/loading_dialog_card.dart';

void main() {
  group('LoadingDialogCard', () {
    testWidgets('renders activity indicator without label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LoadingDialogCard())),
      );

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(Text), findsNothing);
      expect(find.byType(Opacity), findsNothing);
    });

    testWidgets('renders optional label text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LoadingDialogCard(label: '正在加载')),
        ),
      );

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('正在加载'), findsOneWidget);
    });

    testWidgets('shows the phase label and percentage when progress is known', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LoadingDialogCard(
              label: '正在导出',
              phaseLabel: '正在打包',
              progress: 0.42,
            ),
          ),
        ),
      );

      // 有阶段时显示阶段文案，百分比单独一行。
      expect(find.text('正在打包'), findsOneWidget);
      expect(find.text('42%'), findsOneWidget);
      expect(find.text('正在导出'), findsNothing);

      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, 0.42);
    });

    testWidgets('hides the percentage when progress is unknown', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LoadingDialogCard(label: '正在导出', phaseLabel: '正在准备'),
          ),
        ),
      );

      expect(find.text('正在准备'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);

      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, isNull);
    });
  });
}
