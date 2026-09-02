import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/chat/widgets/message_more_sheet.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

import 'support/business_test_harness.dart';

ChatMessage _message({String role = 'assistant'}) {
  return ChatMessage(
    id: 'message-1',
    role: role,
    content: 'hello',
    conversationId: 'conversation-1',
  );
}

Future<MessageMoreAction?> _openMoreSheet(
  WidgetTester tester, {
  required bool canDeleteAllVersions,
  bool canDeleteCurrentBranch = false,
  bool canDeleteMessageNode = false,
  bool canDeleteMessageOnly = true,
  bool canDeleteMessageAndFollowing = true,
  bool canCreateBranch = true,
  String role = 'assistant',
  String? tapLabel,
}) async {
  MessageMoreAction? selectedAction;
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(createBusinessTestPreferences()),
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  selectedAction = await showMessageMoreSheet(
                    context,
                    _message(role: role),
                    canDeleteAllVersions: canDeleteAllVersions,
                    canDeleteCurrentBranch: canDeleteCurrentBranch,
                    canDeleteMessageNode: canDeleteMessageNode,
                    canDeleteMessageOnly: canDeleteMessageOnly,
                    canDeleteMessageAndFollowing: canDeleteMessageAndFollowing,
                    canCreateBranch: canCreateBranch,
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  if (tapLabel != null) {
    await tester.ensureVisible(find.text(tapLabel));
    await tester.tap(find.text(tapLabel));
    await tester.pumpAndSettle();
  }
  return selectedAction;
}

void main() {
  testWidgets('分叉节点消息菜单显示删除当前分支和删除全部版本', (tester) async {
    await _openMoreSheet(
      tester,
      canDeleteAllVersions: true,
      canDeleteCurrentBranch: true,
      canDeleteMessageNode: true,
      canDeleteMessageOnly: false,
      canDeleteMessageAndFollowing: false,
    );

    expect(find.text('Select Messages'), findsOneWidget);
    expect(find.text('Create Message Branch'), findsOneWidget);
    expect(find.text('Delete This Message'), findsNothing);
    expect(find.text('Delete Current Branch'), findsOneWidget);
    expect(find.text('Delete This Node'), findsOneWidget);
    expect(find.text('Delete This Message and Following'), findsNothing);
    expect(find.text('Delete All Branches'), findsOneWidget);

    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList();
    expect(
      labels.indexOf('Delete This Node'),
      lessThan(labels.indexOf('Delete Current Branch')),
    );
  });

  testWidgets('普通节点消息菜单不显示删除当前分支和删除全部版本', (tester) async {
    await _openMoreSheet(tester, canDeleteAllVersions: false);

    expect(find.text('Select Messages'), findsOneWidget);
    expect(find.text('Delete This Message'), findsOneWidget);
    expect(find.text('Delete Current Branch'), findsNothing);
    expect(find.text('Delete This Node'), findsNothing);
    expect(find.text('Delete This Message and Following'), findsOneWidget);
    expect(find.text('Delete All Branches'), findsNothing);
  });

  testWidgets('叶子非分支节点菜单仅显示删除当前消息', (tester) async {
    await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      canDeleteMessageAndFollowing: false,
    );

    expect(find.text('Delete This Message'), findsOneWidget);
    expect(find.text('Delete This Message and Following'), findsNothing);
  });

  testWidgets('消息菜单可以触发删除当前分支', (tester) async {
    final action = await _openMoreSheet(
      tester,
      canDeleteAllVersions: true,
      canDeleteCurrentBranch: true,
      tapLabel: 'Delete Current Branch',
    );

    expect(action, MessageMoreAction.deleteCurrentBranch);
  });

  testWidgets('分叉节点消息菜单可以触发删除此节点', (tester) async {
    final action = await _openMoreSheet(
      tester,
      canDeleteAllVersions: true,
      canDeleteCurrentBranch: true,
      canDeleteMessageNode: true,
      canDeleteMessageOnly: false,
      canDeleteMessageAndFollowing: false,
      tapLabel: 'Delete This Node',
    );

    expect(action, MessageMoreAction.deleteMessageNode);
  });

  testWidgets('临时会话消息菜单不显示创建消息分支', (tester) async {
    await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      canCreateBranch: false,
    );

    expect(find.text('Create Message Branch'), findsNothing);
  });

  testWidgets('助手消息菜单可以切换为用户', (tester) async {
    final action = await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      tapLabel: 'Switch to User',
    );

    expect(action, MessageMoreAction.switchToUser);
  });

  testWidgets('消息菜单可以触发删除当前消息', (tester) async {
    final action = await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      tapLabel: 'Delete This Message',
    );

    expect(action, MessageMoreAction.deleteMessageOnly);
  });

  testWidgets('消息菜单可以触发删除此消息及后续', (tester) async {
    final action = await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      tapLabel: 'Delete This Message and Following',
    );

    expect(action, MessageMoreAction.deleteMessageAndFollowing);
  });

  testWidgets('用户消息菜单可以切换为助手', (tester) async {
    final action = await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      role: 'user',
      tapLabel: 'Switch to Assistant',
    );

    expect(action, MessageMoreAction.switchToAssistant);
  });
}
