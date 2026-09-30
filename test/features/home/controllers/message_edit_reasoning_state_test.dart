import '../../../support/business_test_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/models/conversation_tree.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/controllers/home_page_controller.dart';
import 'package:Kelivo/features/home/controllers/scroll_controller.dart';
import 'package:Kelivo/features/home/controllers/stream_controller.dart'
    show ReasoningData, ReasoningSegmentData;
import 'package:Kelivo/features/home/widgets/chat_input_bar.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

/// 编辑保存后必须丢弃该消息在流控制器里按 ID 缓存的旧推理状态。
///
/// 症状：编辑助手消息、删除思维链部件并“覆盖保存”后，消息气泡里仍能看到
/// 原来的思维链；再次打开编辑面板时思维链确实已经不在。原因是持久化部件
/// 与 `reasoningText` 都已清空，但渲染读的是流控制器里按消息 ID 缓存的状态，
/// 编辑没有让它失效，于是渲染落到“实时推理”这条回退路径。
void main() {
  testWidgets('覆盖保存删除思维链后不再回落到旧推理状态', (tester) async {
    final scenario = await _pumpEditor(tester);
    final controller = scenario.controller;
    final assistant = scenario.assistant;

    // 前提：渲染读取的就是流控制器里按消息 ID 缓存的状态。
    expect(controller.reasoning[assistant.id], isNotNull);

    final message = controller.messages.firstWhere((m) => m.id == assistant.id);
    final editDone = controller.editMessage(message);
    await tester.pumpAndSettle();

    // 删除思维链部件（第一张卡片）并确认。
    await tester.tap(find.byIcon(Lucide.Trash2).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(scenario.l10n.messageEditDeletePart));
    await tester.pumpAndSettle();

    // 覆盖保存并确认。
    await _confirmOverwrite(tester, scenario.l10n);
    await editDone;
    await tester.pumpAndSettle();

    // 持久化部件必须已经不含思维链。
    final saved = scenario.service.messages.firstWhere(
      (m) => m.id == assistant.id,
    );
    expect(saved.parts.whereType<ReasoningPart>(), isEmpty);
    expect(saved.reasoningText, isNull);

    // 渲染用的推理 / 工具 / 切分状态都不得残留。
    expect(controller.reasoning[assistant.id], isNull);
    expect(controller.reasoningSegments[assistant.id], isNull);
    expect(controller.contentSplits[assistant.id], isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('覆盖保存保留思维链时按持久化结果重建渲染状态', (tester) async {
    final scenario = await _pumpEditor(tester);
    final controller = scenario.controller;
    final assistant = scenario.assistant;

    final message = controller.messages.firstWhere((m) => m.id == assistant.id);
    final editDone = controller.editMessage(message);
    await tester.pumpAndSettle();

    // 不改动部件，只覆盖保存。
    await _confirmOverwrite(tester, scenario.l10n);
    await editDone;
    await tester.pumpAndSettle();

    // 推理被保留时必须重新装回渲染状态，不能只是简单清空。
    expect(controller.reasoning[assistant.id], isNotNull);
    expect(controller.reasoning[assistant.id]!.text, 'thinking chain');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _confirmOverwrite(
  WidgetTester tester,
  AppLocalizations l10n,
) async {
  await tester.tap(find.text(l10n.messageEditPageOverwriteSave));
  await tester.pumpAndSettle();
  await tester.tap(find.text(l10n.messageEditOverwriteConfirmConfirm));
  await tester.pumpAndSettle();
}

typedef _EditorScenario = ({
  _EditFakeChatService service,
  HomePageController controller,
  ChatMessage assistant,
  AppLocalizations l10n,
});

Future<_EditorScenario> _pumpEditor(WidgetTester tester) async {
  final user = ChatMessage(
    id: 'user-1',
    role: 'user',
    content: 'prompt',
    conversationId: 'conversation-1',
    groupId: 'user-1',
  );
  final assistant = ChatMessage(
    id: 'assistant-1',
    role: 'assistant',
    conversationId: 'conversation-1',
    groupId: 'assistant-1',
    parts: const <MessagePart>[
      ReasoningPart('thinking chain'),
      TextPart('answer'),
    ],
    reasoningText: 'thinking chain',
    reasoningStartAt: DateTime(2026, 1, 1, 12),
    reasoningFinishedAt: DateTime(2026, 1, 1, 12, 0, 5),
  );
  final service = _EditFakeChatService(
    conversation: Conversation(
      id: 'conversation-1',
      title: 'Edit',
      messageIds: const ['user-1', 'assistant-1'],
    ),
    messages: <ChatMessage>[user, assistant],
  );

  HomePageController? controller;
  await tester.pumpWidget(_buildHarness(service, (c) => controller = c));
  await controller!.chatController.setCurrentConversationAndLoad(
    service.conversation,
  );
  await tester.pumpAndSettle();

  // 模拟“编辑前已经装好推理”的现场：恢复或流式都把状态写进这份缓存。
  controller!.reasoning[assistant.id] = ReasoningData()
    ..text = 'thinking chain'
    ..startAt = DateTime(2026, 1, 1, 12)
    ..finishedAt = DateTime(2026, 1, 1, 12, 0, 5);
  controller!.reasoningSegments[assistant.id] = <ReasoningSegmentData>[
    ReasoningSegmentData()
      ..text = 'thinking chain'
      ..startAt = DateTime(2026, 1, 1, 12)
      ..finishedAt = DateTime(2026, 1, 1, 12, 0, 5),
  ];

  final l10n = AppLocalizations.of(
    tester.element(find.byType(Scaffold).first),
  )!;
  return (
    service: service,
    controller: controller!,
    assistant: assistant,
    l10n: l10n,
  );
}

class _EditFakeChatService extends ChatService {
  _EditFakeChatService({required this.conversation, required this.messages});

  final Conversation conversation;
  final List<ChatMessage> messages;

  @override
  Conversation? getConversation(String id) =>
      id == conversation.id ? conversation : null;

  @override
  int getMessageCount(String conversationId) => -1;

  @override
  bool isMessageCountKnown(String conversationId) => false;

  @override
  bool debugHasMessageOrderSkeleton(String conversationId) => false;

  @override
  Future<List<String>> getMessageIds(String conversationId) async =>
      messages.map((m) => m.id).toList(growable: false);

  @override
  List<ChatMessage> getMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) {
    if (limit < 0) return const <ChatMessage>[];
    final end = (start + limit).clamp(0, messages.length);
    return messages.sublist(start.clamp(0, messages.length), end);
  }

  @override
  Future<List<ChatMessage>> loadMessages(String conversationId) async =>
      List<ChatMessage>.of(messages);

  @override
  Future<List<ChatMessage>> loadAllConversationMessages(
    String conversationId,
  ) async => List<ChatMessage>.of(messages);

  @override
  Future<LoadedTimelinePage?> loadTimelinePage(
    String conversationId, {
    String? beforeRevisionId,
    String? afterRevisionId,
    String? aroundRevisionId,
    bool fromStart = false,
    int limit = 40,
  }) async {
    final start = (messages.length - limit).clamp(0, messages.length);
    final selected = messages.sublist(start);
    final timestamp = DateTime(2026, 8, 10);
    return LoadedTimelinePage(
      conversationId: conversationId,
      stateRevision: 0,
      contextStartRevisionId: null,
      slots: [
        for (final (offset, message) in selected.indexed)
          LoadedTimelineSlot(
            identity: ActiveTimelineSlot(
              slotId: message.groupId ?? message.id,
              revisionId: message.id,
              parentRevisionId: null,
              role: message.role,
              createdAt: timestamp,
              updatedAt: timestamp,
              finalizedAt: timestamp,
              versionCount: 1,
              logicalIndex: start + offset,
            ),
            message: message,
          ),
      ],
      hasMoreBefore: start > 0,
      hasMoreAfter: false,
      totalSlotCount: messages.length,
    );
  }

  @override
  Map<String, int> getVersionSelections(String conversationId) =>
      const <String, int>{};

  @override
  Future<ConversationTree?> loadConversationTree(String conversationId) async =>
      null;

  @override
  List<ChatMessage> getMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) {
    final targets = groupIds.toSet();
    return messages
        .where((m) => targets.contains(m.groupId ?? m.id))
        .toList(growable: false);
  }

  @override
  Future<List<ChatMessage>> loadMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async => getMessagesForGroups(conversationId, groupIds);

  @override
  Map<String, int> getFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) => {for (final id in groupIds) id: 0};

  @override
  Future<Map<String, int>> loadFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async => getFirstMessageIndicesForGroups(conversationId, groupIds);

  @override
  Future<List<ChatMessage>> loadMessagesByIds(List<String> ids) async {
    final wanted = ids.toSet();
    return messages.where((m) => wanted.contains(m.id)).toList();
  }

  @override
  Future<Set<String>> loadMessageIdsForGroups(
    String conversationId,
    Set<String> groupIds,
  ) async {
    return {
      for (final message in messages)
        if (groupIds.contains(message.groupId ?? message.id)) message.id,
    };
  }

  @override
  Future<List<ChatMessage>> loadSelectedMessageProjections(
    String conversationId,
  ) async => List<ChatMessage>.of(messages);

  @override
  Future<void> clearConversationSuggestions(String conversationId) async {}

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) =>
      const <Map<String, dynamic>>[];

  @override
  String? getGeminiThoughtSignature(String assistantMessageId) => null;

  @override
  Future<ChatMessage?> overwriteMessage({
    required String messageId,
    required List<MessagePart> parts,
  }) async {
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return null;
    final original = messages[index];
    final derivedReasoning = ChatMessage.reasoningTextFromParts(parts);
    final keepMeta = derivedReasoning != null;
    final updated = ChatMessage(
      id: original.id,
      role: original.role,
      parts: parts,
      conversationId: original.conversationId,
      isStreaming: false,
      reasoningText: derivedReasoning,
      reasoningStartAt: keepMeta ? original.reasoningStartAt : null,
      reasoningFinishedAt: keepMeta ? original.reasoningFinishedAt : null,
      reasoningSegmentsJson: keepMeta ? original.reasoningSegmentsJson : null,
      groupId: original.groupId,
      version: original.version,
    );
    messages[index] = updated;
    notifyListeners();
    return updated;
  }
}

Widget _buildHarness(
  ChatService chatService,
  ValueChanged<HomePageController> onCreated,
) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(createBusinessTestPreferences()),
      ),
      ChangeNotifierProvider<ChatService>.value(value: chatService),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: _ControllerHarness(onCreated: onCreated),
    ),
  );
}

class _ControllerHarness extends StatefulWidget {
  const _ControllerHarness({required this.onCreated});

  final ValueChanged<HomePageController> onCreated;

  @override
  State<_ControllerHarness> createState() => _ControllerHarnessState();
}

class _ControllerHarnessState extends State<_ControllerHarness>
    with TickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _inputBarKey = GlobalKey();
  final _inputFocus = FocusNode();
  final _inputController = TextEditingController();
  final _mediaController = ChatInputBarController();
  final _scrollController = ChatAutoFollowScrollController();
  late final HomePageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = HomePageController(
      context: context,
      vsync: this,
      scaffoldKey: _scaffoldKey,
      inputBarKey: _inputBarKey,
      inputFocus: _inputFocus,
      inputController: _inputController,
      mediaController: _mediaController,
      scrollController: _scrollController,
    );
    widget.onCreated(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    _inputFocus.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(key: _scaffoldKey);
}
