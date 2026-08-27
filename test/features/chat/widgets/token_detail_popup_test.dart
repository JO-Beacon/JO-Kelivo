import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/chat/widgets/token_detail_popup.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

Widget _harness({
  int? promptTokens,
  int? completionTokens,
  int? cachedTokens,
  int? durationMs,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: TokenDetailPopup(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        cachedTokens: cachedTokens,
        durationMs: durationMs,
      ),
    ),
  );
}

Finder _popupConstraints() {
  return find.byWidgetPredicate(
    (widget) => widget is ConstrainedBox && widget.constraints.maxWidth == 280,
  );
}

void main() {
  testWidgets('keeps long cached token details within the widened popup', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        promptTokens: 123456789,
        completionTokens: 987654321,
        cachedTokens: 123456789,
        durationMs: 123456,
      ),
    );

    final popup = tester.widget<ConstrainedBox>(_popupConstraints());
    expect(popup.constraints.maxWidth, 280);
    expect(tester.getSize(_popupConstraints()).width, lessThanOrEqualTo(280));
    expect(find.byType(Text), findsWidgets);
  });

  testWidgets('does not build a popup when no token detail exists', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());

    expect(_popupConstraints(), findsNothing);
  });
}
