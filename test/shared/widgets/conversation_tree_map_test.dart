import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation_tree.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/conversation_tree_map.dart';

void main() {
  testWidgets('renders shared ancestors and hidden sibling branches', (
    tester,
  ) async {
    final rootUser = ChatMessage(
      role: 'user',
      content: 'root question',
      conversationId: 'conversation',
    );
    final rootAssistant = ChatMessage(
      role: 'assistant',
      content: 'original answer',
      conversationId: 'conversation',
    );
    final alternateAssistant = ChatMessage(
      role: 'assistant',
      content: 'alternate answer',
      conversationId: 'conversation',
    );
    final tree =
        ConversationTree.linear(
              conversationId: 'conversation',
              messageIds: [rootUser.id, rootAssistant.id],
            )
            .createMessageBranch(
              branchId: 'alternate',
              fromMessageId: rootUser.id,
            )
            .appendToActiveBranch(alternateAssistant.id);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ConversationTreeMap(
            tree: tree,
            messages: [rootUser, rootAssistant, alternateAssistant],
            onTapMessage: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('root question'), findsOneWidget);
    expect(find.text('original answer'), findsOneWidget);
    expect(find.text('alternate answer'), findsOneWidget);
  });

  testWidgets('builds only visible node cards for large trees', (tester) async {
    final messages = List<ChatMessage>.generate(
      200,
      (index) => ChatMessage(
        role: index.isEven ? 'user' : 'assistant',
        content: 'message $index',
        conversationId: 'conversation',
      ),
    );
    final tree = ConversationTree.linear(
      conversationId: 'conversation',
      messageIds: [for (final message in messages) message.id],
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: ConversationTreeMap(
                tree: tree,
                messages: messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final renderedNodeCards = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'conversationTreeMapNode-',
          ),
    );
    expect(renderedNodeCards.evaluate().length, lessThan(20));
    expect(find.text('message 0'), findsOneWidget);
    expect(find.text('message 199'), findsNothing);

    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    controller.value = Matrix4.translationValues(0, -18624, 0);
    await tester.pump();

    expect(find.text('message 199'), findsOneWidget);
    expect(find.text('message 0'), findsNothing);
  });

  testWidgets('uses one interactive viewport with two-dimensional scrollbars', (
    tester,
  ) async {
    final fixture = _branchingFixture();
    final messages = fixture.messages;
    final tree = fixture.tree;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 140,
              child: ConversationTreeMap(
                tree: tree,
                messages: messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(
      find.byKey(const ValueKey('conversationTreeMapVerticalScrollbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversationTreeMapHorizontalScrollbar')),
      findsOneWidget,
    );
  });

  testWidgets('mouse wheel scrolls vertically without zooming', (tester) async {
    final fixture = _branchingFixture();
    final messages = fixture.messages;
    final tree = fixture.tree;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 140,
              child: ConversationTreeMap(
                tree: tree,
                messages: messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final controller = viewer.transformationController!;
    final before = controller.value.getMaxScaleOnAxis();
    final beforeY = controller.value.getTranslation().y;
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(center);

    tester.binding.handlePointerEvent(pointer.scroll(const Offset(0, 20)));
    await tester.pump();

    expect(controller.value.getMaxScaleOnAxis(), before);
    expect(controller.value.getTranslation().y, lessThan(beforeY));
  });

  testWidgets('horizontal mouse wheel scrolls horizontally without zooming', (
    tester,
  ) async {
    final fixture = _branchingFixture();
    final messages = fixture.messages;
    final tree = fixture.tree;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 140,
              child: ConversationTreeMap(
                tree: tree,
                messages: messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final controller = viewer.transformationController!;
    final before = controller.value.getMaxScaleOnAxis();
    final beforeX = controller.value.getTranslation().x;
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(center);

    tester.binding.handlePointerEvent(pointer.scroll(const Offset(20, 0)));
    await tester.pump();

    expect(controller.value.getMaxScaleOnAxis(), before);
    expect(controller.value.getTranslation().x, lessThan(beforeX));
  });

  testWidgets('horizontal mouse wheel scrolls over the horizontal scrollbar', (
    tester,
  ) async {
    final fixture = _branchingFixture();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 140,
              child: ConversationTreeMap(
                tree: fixture.tree,
                messages: fixture.messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final beforeX = controller.value.getTranslation().x;
    final scrollbar = find.byKey(
      const ValueKey('conversationTreeMapHorizontalScrollbar'),
    );
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(scrollbar));

    tester.binding.handlePointerEvent(pointer.scroll(const Offset(20, 0)));
    await tester.pump();

    expect(controller.value.getTranslation().x, lessThan(beforeX));
  });

  testWidgets('resetToActualSize restores the map to 100 percent', (
    tester,
  ) async {
    final fixture = _branchingFixture();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 140,
              child: ConversationTreeMap(
                tree: fixture.tree,
                messages: fixture.messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final state = tester.state<ConversationTreeMapState>(
      find.byType(ConversationTreeMap),
    );
    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    controller.value = Matrix4.identity()..scaleByDouble(0.5, 0.5, 0.5, 1);
    await tester.pump();

    state.resetToActualSize();

    expect(controller.value.getMaxScaleOnAxis(), closeTo(1.0, 0.0001));
  });

  testWidgets('fitHorizontal scales the full tree width into the viewport', (
    tester,
  ) async {
    final fixture = _branchingFixture();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 140,
              child: ConversationTreeMap(
                tree: fixture.tree,
                messages: fixture.messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final state = tester.state<ConversationTreeMapState>(
      find.byType(ConversationTreeMap),
    );
    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    controller.value = Matrix4.identity()..scaleByDouble(0.75, 0.75, 0.75, 1);
    await tester.pump();

    state.fitHorizontal();

    expect(controller.value.getMaxScaleOnAxis(), closeTo(180 / 384, 0.0001));
    expect(controller.value.getTranslation().x, closeTo(0.0, 0.0001));
  });

  testWidgets('ctrl plus mouse wheel zooms the interactive tree map', (
    tester,
  ) async {
    final fixture = _branchingFixture();
    final messages = fixture.messages;
    final tree = fixture.tree;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 140,
              child: ConversationTreeMap(
                tree: tree,
                messages: messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final controller = viewer.transformationController!;
    final before = controller.value.getMaxScaleOnAxis();
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(center);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      tester.binding.handlePointerEvent(pointer.scroll(const Offset(0, -20)));
      await tester.pump();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    expect(controller.value.getMaxScaleOnAxis(), greaterThan(before));
  });

  testWidgets('dragging the map and scrollbars pans the same viewport', (
    tester,
  ) async {
    final fixture = _branchingFixture();
    final messages = fixture.messages;
    final tree = fixture.tree;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 140,
              child: ConversationTreeMap(
                tree: tree,
                messages: messages,
                onTapMessage: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final beforeX = controller.value.getTranslation().x;

    await tester.drag(find.byType(InteractiveViewer), const Offset(-45, 0));
    await tester.pumpAndSettle();

    expect(controller.value.getTranslation().x, lessThan(beforeX));

    final beforeY = controller.value.getTranslation().y;
    await tester.drag(
      find.byKey(const ValueKey('conversationTreeMapVerticalThumb')),
      const Offset(0, 24),
    );
    await tester.pumpAndSettle();

    expect(controller.value.getTranslation().y, lessThan(beforeY));
  });
}

({List<ChatMessage> messages, ConversationTree tree}) _branchingFixture() {
  final rootUser = ChatMessage(
    role: 'user',
    content: 'root question',
    conversationId: 'conversation',
  );
  final rootAssistant = ChatMessage(
    role: 'assistant',
    content: 'original answer',
    conversationId: 'conversation',
  );
  final alternateAssistant = ChatMessage(
    role: 'assistant',
    content: 'alternate answer',
    conversationId: 'conversation',
  );
  final tree =
      ConversationTree.linear(
            conversationId: 'conversation',
            messageIds: [rootUser.id, rootAssistant.id],
          )
          .createMessageBranch(
            branchId: 'alternate',
            fromMessageId: rootUser.id,
          )
          .appendToActiveBranch(alternateAssistant.id);
  return (messages: [rootUser, rootAssistant, alternateAssistant], tree: tree);
}
