import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/shared/dialogs/loading_task_dialog.dart';
import 'package:Kelivo/core/models/backup_task_progress.dart';

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
                  task: (_) {
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
                task: (_) => task.future,
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

  testWidgets('keeps the Windows title bar outside the loading barrier', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final task = Completer<void>();
      Future<void>? invocation;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                invocation = runWithLoadingTaskDialog<void>(
                  context: context,
                  task: (_) => task.future,
                );
              },
              child: const Text('Start'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Start'));
      await tester.pump();

      expect(tester.getTopLeft(find.byType(ModalBarrier).last).dy, 40);

      task.complete();
      await invocation;
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('exposes cancellation to a cancellable task', (tester) async {
    final task = Completer<void>();
    BackupCancelToken? receivedToken;
    Future<void>? invocation;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              invocation = runWithLoadingTaskDialog<void>(
                context: context,
                task: (_) => task.future,
                cancellableTask: (_, token) {
                  receivedToken = token;
                  return task.future;
                },
                cancelLabel: 'Cancel',
              );
            },
            child: const Text('Start'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    expect(receivedToken?.isCancelled, isTrue);

    task.completeError(const BackupCancelledException());
    await expectLater(invocation, throwsA(isA<BackupCancelledException>()));
  });
}
