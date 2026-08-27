import '../../../support/business_test_harness.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/providers/tts_provider.dart';
import 'package:Kelivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Kelivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Kelivo/features/home/services/tool_approval_service.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildHarness({required Widget child}) {
  SharedPreferences.setMockInitialValues(const {});
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
      ),
      ChangeNotifierProvider(
        create: (_) =>
            TtsProvider(preferences: createBusinessTestPreferences()),
      ),
      ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void _expectAbove(WidgetTester tester, Finder upper, Finder lower) {
  expect(upper, findsWidgets);
  expect(lower, findsWidgets);
  expect(
    tester.getTopLeft(upper.first).dy,
    lessThan(tester.getTopLeft(lower.first).dy),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('valid historical content splits keep reasoning before text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        child: ChatMessageWidget(
          message: ChatMessage(
            id: 'valid-splits',
            role: 'assistant',
            content: 'hello',
            conversationId: 'conversation-1',
          ),
          showModelIcon: false,
          reasoningSegments: const [
            ReasoningSegment(text: 'plan', expanded: true, loading: false),
          ],
          contentSplitOffsets: const [0],
          reasoningCountAtSplit: const [1],
          toolCountAtSplit: const [0],
        ),
      ),
    );
    await tester.pump();

    _expectAbove(
      tester,
      find.textContaining('plan'),
      find.textContaining('hello'),
    );
  });

  testWidgets('invalid content splits fall back to structured parts order', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildHarness(
        child: ChatMessageWidget(
          message: ChatMessage(
            id: 'invalid-splits-parts',
            role: 'assistant',
            conversationId: 'conversation-1',
            parts: const [ReasoningPart('THINK_PLAN'), TextPart('BODY_HELLO')],
          ),
          showModelIcon: false,
          contentSplitOffsets: const [0],
          reasoningCountAtSplit: const [1, 2],
          toolCountAtSplit: const [0],
        ),
      ),
    );
    await tester.pump();

    _expectAbove(
      tester,
      find.textContaining('THINK_PLAN'),
      find.textContaining('BODY_HELLO'),
    );
  });

  testWidgets(
    'incomplete valid-looking splits keep leftover tools above text',
    (tester) async {
      final tools = [
        for (var i = 1; i <= 3; i++)
          ToolUIPart(
            id: 'tool-$i',
            toolName: 'search_$i',
            arguments: const {},
            content: 'ok',
          ),
      ];

      await tester.pumpWidget(
        _buildHarness(
          child: SingleChildScrollView(
            child: ChatMessageWidget(
              message: ChatMessage(
                id: 'incomplete-splits-tools',
                role: 'assistant',
                content: 'BODY_HELLO',
                conversationId: 'conversation-1',
              ),
              showModelIcon: false,
              reasoningSegments: const [
                ReasoningSegment(
                  text: 'THINK_PLAN',
                  expanded: true,
                  loading: false,
                ),
              ],
              toolParts: tools,
              contentSplitOffsets: const [0],
              reasoningCountAtSplit: const [1],
              toolCountAtSplit: const [1],
            ),
          ),
        ),
      );
      await tester.pump();

      _expectAbove(
        tester,
        find.textContaining('search_3'),
        find.textContaining('BODY_HELLO'),
      );
    },
  );
}
