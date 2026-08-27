import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/settings/pages/memory_about_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

void main() {
  testWidgets('about page presents the memory guide as separate sections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MemoryAboutContent()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Get started'), findsOneWidget);
    expect(find.text('Memory types'), findsOneWidget);
    expect(find.text('Global vs assistant'), findsOneWidget);
    expect(find.text('How memories are injected'), findsOneWidget);
    expect(find.text('Background pipeline'), findsOneWidget);
    expect(find.text('Keep caching healthy'), findsOneWidget);
    expect(find.text('FAQ'), findsOneWidget);
    expect(find.text("Why wasn't this remembered?"), findsOneWidget);
  });
}
