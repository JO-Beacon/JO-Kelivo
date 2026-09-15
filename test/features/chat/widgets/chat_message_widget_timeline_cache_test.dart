import "../../../support/business_test_harness.dart";
import 'package:Kelivo/core/models/chat_message.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'timeline steps are memoized until their signature changes',
    (tester) async {
      debugTimelineStepBuilderCount = 0;
      addTearDown(() => debugTimelineStepBuilderCount = 0);

      final tools = [
        ToolUIPart(
          id: 'tool-1',
          toolName: 'search_1',
          arguments: const {},
          content: 'ok',
        ),
      ];
      var reasoningText = 'THINK_PLAN';
      late StateSetter rebuild;

      await tester.pumpWidget(
        _buildHarness(
          child: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SingleChildScrollView(
                child: ChatMessageWidget(
                  message: ChatMessage(
                    id: 'timeline-memo',
                    role: 'assistant',
                    content: 'BODY_HELLO',
                    conversationId: 'conversation-1',
                  ),
                  showModelIcon: false,
                  reasoningSegments: [
                    ReasoningSegment(
                      text: reasoningText,
                      expanded: true,
                      loading: false,
                    ),
                  ],
                  toolParts: tools,
                  contentSplitOffsets: const [0],
                  reasoningCountAtSplit: const [1],
                  toolCountAtSplit: const [1],
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('THINK_PLAN'), findsOneWidget);
      expect(find.textContaining('search_1'), findsOneWidget);

      // 输入完全没变的重建：每一步都应命中缓存，builder 一次都不跑。
      debugTimelineStepBuilderCount = 0;
      rebuild(() {});
      await tester.pump();
      expect(debugTimelineStepBuilderCount, 0);

      // 思考文本变化：这一步必须重建，并把新文本画出来。
      rebuild(() => reasoningText = 'THINK_PLAN_NEXT');
      await tester.pump();
      expect(debugTimelineStepBuilderCount, greaterThan(0));
      expect(find.textContaining('THINK_PLAN_NEXT'), findsOneWidget);
    },
  );
}
