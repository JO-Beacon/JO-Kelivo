import '../support/business_test_harness.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/desktop/message_edit_dialog.dart';
import 'package:Kelivo/features/chat/models/message_edit_result.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('desktop editor saves structured parts without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const opaque = UnknownPart(rawKind: 'future', payload: 'opaque');
    MessageEditResult? result;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showMessageEditDesktopDialog(
                    context,
                    message: ChatMessage(
                      role: 'assistant',
                      conversationId: 'conversation',
                      parts: const <MessagePart>[
                        TextPart('before'),
                        FilePart(uri: 'a.pdf', name: 'a.pdf'),
                        opaque,
                      ],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'after');
    await tester.tap(find.byIcon(Lucide.X).last);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result, isNotNull);
    expect(result!.content, 'after');
    expect(result!.parts.map((part) => part.kind), <String>['text', 'future']);
    expect(identical(result!.parts.last, opaque), isTrue);
  });

  testWidgets('desktop outside click and close button ask before discarding', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    MessageEditResult? result;
    var completed = false;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showMessageEditDesktopDialog(
                    context,
                    message: ChatMessage(
                      role: 'user',
                      content: 'before',
                      conversationId: 'conversation',
                    ),
                  );
                  completed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'edited draft');
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    expect(find.text('Save changes?'), findsOneWidget);
    expect(completed, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Lucide.X));
    await tester.pumpAndSettle();

    expect(find.text('Save changes?'), findsOneWidget);
    expect(completed, isFalse);

    await tester.tap(find.text("Don't Save"));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });
}
