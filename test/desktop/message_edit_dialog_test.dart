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
    await tester.enterText(find.byType(TextField), '  after  ');
    await tester.tap(find.text('Trim whitespace'));
    await tester.pump();
    await tester.tap(find.text('Save as New Branch'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result, isNotNull);
    expect(result!.content, 'after');
    expect(result!.saveMode, MessageEditSaveMode.newBranch);
    expect(result!.parts.map((part) => part.kind), <String>[
      'text',
      'file',
      'future',
    ]);
    expect(identical(result!.parts.last, opaque), isTrue);
  });

  testWidgets('desktop editor scales from the application minimum size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMessageEditDesktopDialog(
                  context,
                  message: ChatMessage(
                    role: 'user',
                    content: 'before',
                    conversationId: 'conversation',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final baseSize = tester.renderObject<RenderBox>(find.byType(Dialog)).size;

    tester.view.physicalSize = const Size(1440, 960);
    await tester.pumpAndSettle();
    final enlargedSize = tester
        .renderObject<RenderBox>(find.byType(Dialog))
        .size;

    expect(enlargedSize.width, closeTo(baseSize.width * 1.5, 1));
    expect(enlargedSize.height, greaterThan(baseSize.height));
  });

  testWidgets('unchanged desktop editor closes without asking to save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
                  await showMessageEditDesktopDialog(
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
    await tester.tap(find.byIcon(Lucide.X).last);
    await tester.pumpAndSettle();

    expect(find.text('Close without saving?'), findsNothing);
    expect(completed, isTrue);
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

    expect(find.text('Close without saving?'), findsOneWidget);
    expect(completed, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Lucide.X));
    await tester.pumpAndSettle();

    expect(find.text('Close without saving?'), findsOneWidget);
    expect(completed, isFalse);

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });
}
