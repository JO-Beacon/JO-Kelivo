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
    await tester.tap(find.text(tapLabel));
    await tester.pumpAndSettle();
  }
  return selectedAction;
}

void main() {
  testWidgets('多版本消息菜单显示删除全部版本', (tester) async {
    await _openMoreSheet(tester, canDeleteAllVersions: true);

    expect(find.text('Select Messages'), findsOneWidget);
    expect(find.text('Create Message Branch'), findsOneWidget);
    expect(find.text('Delete Message'), findsOneWidget);
    expect(find.text('Delete Branch'), findsOneWidget);
  });

  testWidgets('单版本消息菜单不显示删除全部版本', (tester) async {
    await _openMoreSheet(tester, canDeleteAllVersions: false);

    expect(find.text('Select Messages'), findsOneWidget);
    expect(find.text('Delete Message'), findsOneWidget);
    expect(find.text('Delete Branch'), findsNothing);
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
