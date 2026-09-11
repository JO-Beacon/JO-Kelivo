import "../../../support/business_test_harness.dart";
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/providers/tts_provider.dart';
import 'package:Kelivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Kelivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Kelivo/features/home/services/tool_approval_service.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
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
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SizedBox(width: 420, child: child)),
    ),
  );
}

/// 重新生成按钮位于助手消息操作栏内，按 key 限定范围避免命中其他位置的图标。
Finder _regenerateButton() => find.descendant(
  of: find.byKey(const ValueKey('assistant-actions')),
  matching: find.byIcon(Lucide.RefreshCw),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('regenerate dialog explains the running reply is interrupted', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    var regenerated = 0;

    await tester.pumpWidget(
      _buildHarness(
        child: ChatMessageWidget(
          message: ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: 'hello',
            conversationId: 'conversation-1',
          ),
          showModelIcon: false,
          conversationStreaming: true,
          onRegenerate: () => regenerated++,
        ),
      ),
    );
    await tester.pump();

    expect(_regenerateButton(), findsOneWidget);
    await tester.tap(_regenerateButton());
    await tester.pumpAndSettle();

    expect(
      find.textContaining(l10n.chatMessageWidgetRegenerateConfirmContent),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        l10n.chatMessageWidgetRegenerateConfirmInterruptNotice,
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(l10n.chatMessageWidgetRegenerateConfirmOk));
    await tester.pumpAndSettle();
    expect(regenerated, 1);
  });

  testWidgets('regenerate dialog omits the notice when nothing is streaming', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _buildHarness(
        child: ChatMessageWidget(
          message: ChatMessage(
            id: 'assistant-2',
            role: 'assistant',
            content: 'hello',
            conversationId: 'conversation-1',
          ),
          showModelIcon: false,
          onRegenerate: () {},
        ),
      ),
    );
    await tester.pump();

    await tester.tap(_regenerateButton());
    await tester.pumpAndSettle();

    expect(
      find.textContaining(l10n.chatMessageWidgetRegenerateConfirmContent),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        l10n.chatMessageWidgetRegenerateConfirmInterruptNotice,
      ),
      findsNothing,
    );
  });
}
