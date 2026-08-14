import '../../../support/business_test_harness.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/chat/models/message_edit_result.dart';
import 'package:Kelivo/features/chat/widgets/message_edit_sheet.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  Widget harness({
    required ChatMessage message,
    required ValueChanged<MessageEditResult?> onResult,
  }) {
    return ChangeNotifierProvider(
      create: (_) => SettingsProvider(createBusinessTestPreferences()),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                onResult(await showMessageEditSheet(context, message: message));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('save returns edited text and complete structured parts', (
    tester,
  ) async {
    const opaque = UnknownPart(rawKind: 'future', payload: '{"v":1}');
    MessageEditResult? result;
    await tester.pumpWidget(
      harness(
        message: ChatMessage(
          role: 'assistant',
          conversationId: 'conversation',
          parts: const <MessagePart>[
            TextPart('before'),
            ImagePart(uri: 'a.png'),
            opaque,
          ],
        ),
        onResult: (value) => result = value,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'after');
    await tester.tap(find.byIcon(Lucide.X));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.content, 'after');
    expect(result!.shouldSend, isFalse);
    expect(result!.parts.map((part) => part.kind), <String>['text', 'future']);
    expect((result!.parts.first as TextPart).text, 'after');
    expect(identical(result!.parts.last, opaque), isTrue);
  });

  testWidgets('dismissing sheet asks whether to save changes', (tester) async {
    MessageEditResult? result;
    var completed = false;
    await tester.pumpWidget(
      harness(
        message: ChatMessage(
          role: 'assistant',
          content: 'before',
          conversationId: 'conversation',
        ),
        onResult: (value) {
          result = value;
          completed = true;
        },
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'edited draft');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('Save changes?'), findsOneWidget);
    expect(completed, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Message'), findsOneWidget);
    expect(completed, isFalse);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't Save"));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets('dismiss confirmation can save the current structured draft', (
    tester,
  ) async {
    const opaque = UnknownPart(rawKind: 'future', payload: '{"v":1}');
    MessageEditResult? result;
    await tester.pumpWidget(
      harness(
        message: ChatMessage(
          role: 'user',
          conversationId: 'conversation',
          parts: const <MessagePart>[
            TextPart('before'),
            opaque,
            FilePart(uri: 'keep.pdf', name: 'keep.pdf', unavailable: true),
          ],
        ),
        onResult: (value) => result = value,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'after');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.content, 'after');
    expect(result!.shouldSend, isFalse);
    expect(result!.parts.map((part) => part.kind), <String>[
      'text',
      'future',
      'file',
    ]);
    expect(identical(result!.parts[1], opaque), isTrue);
    expect((result!.parts[2] as FilePart).unavailable, isTrue);
  });

  testWidgets('dragging the sheet down asks before discarding', (tester) async {
    var completed = false;
    await tester.pumpWidget(
      harness(
        message: ChatMessage(
          role: 'user',
          content: 'before',
          conversationId: 'conversation',
        ),
        onResult: (_) => completed = true,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'edited draft');
    await tester.fling(find.text('Edit Message'), const Offset(0, 500), 2400);
    await tester.pumpAndSettle();

    expect(find.text('Save changes?'), findsOneWidget);
    expect(completed, isFalse);
  });
}
