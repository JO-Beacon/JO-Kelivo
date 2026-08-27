import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/features/home/widgets/mini_map_sheet.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

void main() {
  final messages = [
    ChatMessage(
      id: 'user-1',
      role: 'user',
      content: 'alpha user prompt',
      conversationId: 'conversation',
    ),
    ChatMessage(
      id: 'asst-1',
      role: 'assistant',
      content: 'first assistant reply',
      conversationId: 'conversation',
    ),
    ChatMessage(
      id: 'user-2',
      role: 'user',
      content: 'beta user prompt',
      conversationId: 'conversation',
    ),
    ChatMessage(
      id: 'asst-2',
      role: 'assistant',
      content: 'second assistant reply',
      conversationId: 'conversation',
    ),
  ];

  Future<void> pumpSheet(
    WidgetTester tester, {
    Future<List<MiniMapSearchHit>> Function(String query)? onSearch,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                showMiniMapSheet(context, messages, onSearch: onSearch),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byIcon(Lucide.Search));
    await tester.pumpAndSettle();
  }

  testWidgets('waits 250ms before querying', (tester) async {
    final queries = <String>[];
    await pumpSheet(
      tester,
      onSearch: (query) async {
        queries.add(query);
        return const <MiniMapSearchHit>[];
      },
    );
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'needle');
    await tester.pump(const Duration(milliseconds: 249));
    expect(queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(queries, ['needle']);
  });

  testWidgets('renders a returned snippet and match count', (tester) async {
    await pumpSheet(
      tester,
      onSearch: (_) async => const [
        MiniMapSearchHit(
          messageId: 'asst-1',
          matchCount: 3,
          snippet: 'visible-needle here',
          snippetStart: 0,
        ),
      ],
    );
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'visible');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(
      find.text('visible-needle here', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('3'), findsOneWidget);
    expect(find.text('beta user prompt'), findsNothing);
  });

  testWidgets('ignores stale results after the query changes', (tester) async {
    final first = Completer<List<MiniMapSearchHit>>();
    await pumpSheet(
      tester,
      onSearch: (query) => query == 'alpha'
          ? first.future
          : Future.value(const <MiniMapSearchHit>[]),
    );
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pump();
    first.complete(const [
      MiniMapSearchHit(
        messageId: 'asst-1',
        matchCount: 1,
        snippet: 'stale-snippet',
        snippetStart: 0,
      ),
    ]);
    await tester.pump();
    expect(find.text('stale-snippet', findRichText: true), findsNothing);
  });
}
