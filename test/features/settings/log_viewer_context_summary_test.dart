import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

void main() {
  Future<void> pumpLocale(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            return Text(
              AppLocalizations.of(context)!.contextLogTokensEstimateHint,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('exposes the token estimate hint in every supported locale', (
    tester,
  ) async {
    const cases = <String, String>{
      'en':
          "Token counts are estimates only; use the model's actual usage as the source of truth.",
      'zh': 'tokens 仅为预估值，请以模型实际消耗为准。',
      'zh_Hans': 'tokens 仅为预估值，请以模型实际消耗为准。',
      'zh_Hant': 'tokens 僅為預估值，請以模型實際消耗為準。',
    };

    for (final entry in cases.entries) {
      final localeParts = entry.key.split('_');
      final locale = localeParts.length == 2
          ? Locale.fromSubtags(
              languageCode: localeParts[0],
              scriptCode: localeParts[1],
            )
          : Locale(localeParts[0]);
      await pumpLocale(tester, locale);
      expect(find.text(entry.value), findsOneWidget);
    }
  });
}
