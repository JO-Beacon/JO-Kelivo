import '../../../support/business_test_harness.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/providers/tts_provider.dart';
import 'package:Kelivo/core/providers/user_provider.dart';
import 'package:Kelivo/features/home/controllers/scroll_controller.dart'
    as scroll_ctrl;
import 'package:Kelivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Kelivo/features/home/services/tool_approval_service.dart';
import 'package:Kelivo/features/home/utils/chat_layout_constants.dart';
import 'package:Kelivo/features/home/widgets/message_list_view.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('删除分支折叠动画后移除消息不会破坏继承依赖', (tester) async {
    final harness = await createBusinessTestHarness(
      initial: <String, Object?>{
        'display_chat_message_background_style_v1': 'frosted',
      },
    );
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    await tester.pumpWidget(_DeleteHarness(settings: settings));
    await tester.pump();

    expect(find.byType(BackdropFilter), findsWidgets);

    final state = tester.state<_DeleteHarnessState>(
      find.byType(_DeleteHarness),
    );
    state.startRemoval();
    await tester.pump();
    await tester.pump(
      ChatLayoutConstants.slotRemovalAnimationDuration +
          const Duration(milliseconds: 16),
    );

    state.finishRemoval();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('surviving message'), findsOneWidget);
  });
}

class _DeleteHarness extends StatefulWidget {
  const _DeleteHarness({required this.settings});

  final SettingsProvider settings;

  @override
  State<_DeleteHarness> createState() => _DeleteHarnessState();
}

class _DeleteHarnessState extends State<_DeleteHarness> {
  final scrollController = scroll_ctrl.ChatAutoFollowScrollController();
  final listController = ListController();
  final isProcessingFiles = ValueNotifier<bool>(false);

  late List<ChatMessage> messages = <ChatMessage>[
    ChatMessage(
      id: 'remove-me',
      role: 'assistant',
      content: 'removed message',
      conversationId: 'conversation-1',
    ),
    ChatMessage(
      id: 'survivor',
      role: 'assistant',
      content: 'surviving message',
      conversationId: 'conversation-1',
    ),
  ];

  Set<String> removing = <String>{};

  Map<String, List<ChatMessage>> get byGroup => <String, List<ChatMessage>>{
    for (final message in messages)
      message.groupId ?? message.id: <ChatMessage>[message],
  };

  void startRemoval() {
    setState(() {
      removing = <String>{'remove-me'};
    });
  }

  void finishRemoval() {
    setState(() {
      messages = messages
          .where((message) => message.id != 'remove-me')
          .toList(growable: false);
      removing = <String>{};
    });
  }

  @override
  void dispose() {
    scrollController.dispose();
    listController.dispose();
    isProcessingFiles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: widget.settings),
        ChangeNotifierProvider(
          create: (_) =>
              AssistantProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              TtsProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              UserProvider(preferences: createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
        ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: BackdropGroup(
            child: MessageListView(
              scrollController: scrollController,
              listController: listController,
              messages: messages,
              byGroup: byGroup,
              reasoning: const {},
              reasoningSegments: const {},
              contentSplits: const {},
              toolParts: const {},
              translations: const {},
              selecting: false,
              selectedItems: const {},
              dividerPadding: EdgeInsets.zero,
              isProcessingFiles: isProcessingFiles,
              removingSlotIds: removing,
              showTokenStats: false,
            ),
          ),
        ),
      ),
    );
  }
}
