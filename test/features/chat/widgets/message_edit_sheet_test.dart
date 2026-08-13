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

  testWidgets('dismissing sheet returns null', (tester) async {
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
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(result, isNull);
  });
}
