import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/chat/models/message_edit_result.dart';
import 'package:Kelivo/features/chat/widgets/message_edit_sheet.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatMessage _message() {
  return ChatMessage(
    id: 'message-1',
    role: 'user',
    content: 'original',
    conversationId: 'conversation-1',
  );
}

Widget _harness({required ValueChanged<Future<MessageEditResult?>> onOpen}) {
  return ChangeNotifierProvider(
    create: (_) => SettingsProvider(),
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  onOpen(showMessageEditSheet(context, message: _message())),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  required ValueChanged<Future<MessageEditResult?>> onOpen,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_harness(onOpen: onOpen));
}

Future<void> _pumpRouteAnimation(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('save and send returns edited content with send flag', (
    tester,
  ) async {
    Future<MessageEditResult?>? resultFuture;
    await _pumpHarness(tester, onOpen: (future) => resultFuture = future);

    await tester.tap(find.text('Open editor'));
    await _pumpRouteAnimation(tester);
    await tester.enterText(find.byType(TextField), 'edited text');
    await tester.tap(find.text('Save & Send'));
    await _pumpRouteAnimation(tester);

    final result = await resultFuture;
    expect(result, isNotNull);
    expect(result!.text, 'edited text');
    expect(result.shouldSend, isTrue);
  });

  testWidgets('tapping outside asks before closing and can keep editing', (
    tester,
  ) async {
    Future<MessageEditResult?>? resultFuture;
    await _pumpHarness(tester, onOpen: (future) => resultFuture = future);

    await tester.tap(find.text('Open editor'));
    await _pumpRouteAnimation(tester);
    await tester.enterText(find.byType(TextField), 'draft text');

    await tester.tapAt(const Offset(10, 10));
    await _pumpRouteAnimation(tester);

    expect(find.text('Save changes?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await _pumpRouteAnimation(tester);

    expect(find.text('Save changes?'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'draft text',
    );
    expect(resultFuture, isNotNull);
  });

  testWidgets('outside close confirmation can save edited draft', (
    tester,
  ) async {
    Future<MessageEditResult?>? resultFuture;
    await _pumpHarness(tester, onOpen: (future) => resultFuture = future);

    await tester.tap(find.text('Open editor'));
    await _pumpRouteAnimation(tester);
    await tester.enterText(find.byType(TextField), 'save me');

    await tester.tapAt(const Offset(10, 10));
    await _pumpRouteAnimation(tester);
    await tester.tap(find.text('Save').last);
    await _pumpRouteAnimation(tester);

    final result = await resultFuture;
    expect(result, isNotNull);
    expect(result!.text, 'save me');
    expect(result.shouldSend, isFalse);
  });

  testWidgets('outside close confirmation can discard edited draft', (
    tester,
  ) async {
    Future<MessageEditResult?>? resultFuture;
    await _pumpHarness(tester, onOpen: (future) => resultFuture = future);

    await tester.tap(find.text('Open editor'));
    await _pumpRouteAnimation(tester);
    await tester.enterText(find.byType(TextField), 'discard me');

    await tester.tapAt(const Offset(10, 10));
    await _pumpRouteAnimation(tester);
    await tester.tap(find.text("Don't Save"));
    await _pumpRouteAnimation(tester);

    final result = await resultFuture;
    await _pumpRouteAnimation(tester);

    expect(result, isNull);
    expect(find.byType(TextField), findsNothing);
  });
}
