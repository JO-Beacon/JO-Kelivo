import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/backup/backup_restore_error_message.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';

void main() {
  testWidgets('returns a generic restore error message', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFFFFFFFF),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (buildContext, child) {
          context = buildContext;
          return const SizedBox.shrink();
        },
      ),
    );

    expect(
      backupRestoreErrorMessage(
        AppLocalizations.of(context)!,
        const FormatException('invalid backup'),
      ),
      'FormatException: invalid backup',
    );
  });

  testWidgets('formats local export failures with the export prefix', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFFFFFFFF),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (buildContext, child) {
          context = buildContext;
          return const SizedBox.shrink();
        },
      ),
    );

    final l10n = AppLocalizations.of(context)!;
    final message = l10n.backupPageExportFailedMessage(
      backupRestoreErrorMessage(l10n, const FormatException('disk_full')),
    );

    expect(message, 'Export failed: FormatException: disk_full');
  });

  testWidgets(
    'explains damaged JO-Kelivo archives and keeps the diagnostic code',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFFFFFFFF),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (buildContext, child) {
            context = buildContext;
            return const SizedBox.shrink();
          },
        ),
      );

      final message = backupRestoreErrorMessage(
        AppLocalizations.of(context)!,
        const FormatException('joaiclient_payload_length'),
      );

      expect(message, contains('backup is damaged or incomplete'));
      expect(message, contains('joaiclient_payload_length'));
      expect(message, contains('current data was not modified'));
    },
  );

  testWidgets('restore errors expose a copy icon in the notification', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: AppSnackBarOverlay(
          child: Builder(builder: (context) => const SizedBox.shrink()),
        ),
      ),
    );

    final context = tester.element(find.byType(SizedBox));
    showBackupRestoreErrorSnackBar(
      context,
      StateError('database_schema_version'),
    );
    await tester.pump();

    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(find.byTooltip('Copy diagnostic code'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
