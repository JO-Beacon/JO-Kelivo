import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/backup.dart';
import 'package:Kelivo/features/backup/backup_restart_dialog.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

void main() {
  testWidgets('successful import uses restart dialog without merge counts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showBackupRestartRequiredDialog(context),
              child: const Text('Import'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Restart Required'), findsOneWidget);
    expect(
      find.text('Import successful. Restart JO-AIClient to apply it safely.'),
      findsOneWidget,
    );
    expect(find.textContaining('identical skipped'), findsNothing);
    expect(find.textContaining('conflicts remapped'), findsNothing);
    expect(find.textContaining('Restart JO-AIClient'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Restart Required'), findsOneWidget);
  });

  testWidgets('merge mode without skipped conversations shows nothing', (
    tester,
  ) async {
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await showRestoreCompletionDialog(
                  context,
                  mode: RestoreMode.merge,
                );
                completed = true;
              },
              child: const Text('Import'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(find.text('Restart Required'), findsNothing);
    expect(find.text('Merge completed'), findsNothing);
  });

  testWidgets('merge mode reports skipped conversations without a restart', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRestoreCompletionDialog(
                context,
                mode: RestoreMode.merge,
                skippedConversations: 2,
              ),
              child: const Text('Import'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Merge completed'), findsOneWidget);
    expect(find.textContaining('2 conversations'), findsOneWidget);
    expect(find.textContaining('Restart'), findsNothing);
  });

  testWidgets('overwrite mode still asks for a restart', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRestoreCompletionDialog(
                context,
                mode: RestoreMode.overwrite,
              ),
              child: const Text('Import'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Restart Required'), findsOneWidget);
    expect(
      find.text('Import successful. Restart JO-AIClient to apply it safely.'),
      findsOneWidget,
    );
  });

  testWidgets('merge mode reports applied local settings without a restart', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRestoreCompletionDialog(
                context,
                mode: RestoreMode.merge,
                localSettingsApplied: 3,
              ),
              child: const Text('Import'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Merge completed'), findsOneWidget);
    expect(
      find.textContaining('Applied 3 device settings'),
      findsOneWidget,
    );
    expect(find.textContaining('Restart'), findsNothing);
  });

  testWidgets('merge mode combines skipped and applied notices', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRestoreCompletionDialog(
                context,
                mode: RestoreMode.merge,
                skippedConversations: 2,
                localSettingsApplied: 4,
              ),
              child: const Text('Import'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 conversations'), findsOneWidget);
    expect(
      find.textContaining('Applied 4 device settings'),
      findsOneWidget,
    );
  });
}
