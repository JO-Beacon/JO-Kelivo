import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/shared/dialogs/loading_task_dialog.dart';

void main() {
  testWidgets(
    'paints the loading dialog before starting and returns the value',
    (tester) async {
      final task = Completer<int>();
      Future<int>? invocation;
      var taskStarted = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                invocation = runWithLoadingTaskDialog<int>(
                  context: context,
                  label: 'Exporting',
                  task: () {
                    taskStarted = true;
                    return task.future;
                  },
                );
              },
              child: const Text('Start'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Start'));
      expect(taskStarted, isFalse);

      await tester.pump();
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.text('Exporting'), findsOneWidget);
      expect(taskStarted, isTrue);

      task.complete(7);
      await tester.pump();

      expect(await invocation, 7);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    },
  );

  testWidgets('cannot be dismissed while running and closes after an error', (
    tester,
  ) async {
    final task = Completer<void>();
    Future<void>? invocation;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              invocation = runWithLoadingTaskDialog<void>(
                context: context,
                task: () => task.future,
              );
            },
            child: const Text('Start'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

    await tester.tapAt(const Offset(1, 1));
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

    final expectation = expectLater(invocation, throwsA(isA<StateError>()));
    task.completeError(StateError('backup failed'));
    await tester.pump();
    await expectation;

    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });
}
