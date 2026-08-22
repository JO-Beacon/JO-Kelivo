import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
