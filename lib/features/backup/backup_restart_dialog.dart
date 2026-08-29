import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/backup/associated_backup_path.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/restart_app_action.dart';
import '../../utils/app_directories.dart';
import '../../utils/platform_utils.dart';

Future<void> showBackupRestartRequiredDialog(
  BuildContext context, {
  int skippedConversations = 0,
  bool suppressAssociatedPathOnRestart = false,
  String? associatedBackupPath,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: Theme.of(dialogContext).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.backupPageRestartRequired),
        content: Text(
          skippedConversations > 0
              ? l10n.backupPageRestartContentWithSkipped(skippedConversations)
              : l10n.backupPageRestartContent,
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Directory? appDataDirectory;
              Future<void> restart() async {
                if (suppressAssociatedPathOnRestart ||
                    associatedBackupPath != null) {
                  appDataDirectory = await AppDirectories.getAppDataDirectory();
                }
                if (suppressAssociatedPathOnRestart) {
                  await AssociatedBackupPathEvents.persistRestartSuppression(
                    appDataDirectory!,
                  );
                }
                try {
                  await PlatformUtils.restartApp();
                } catch (_) {
                  if (appDataDirectory != null) {
                    await AssociatedBackupPathEvents.clearRestartSuppression(
                      appDataDirectory!,
                    );
                    if (associatedBackupPath != null) {
                      await AssociatedBackupPathEvents.clearConsumedPath(
                        appDataDirectory!,
                      );
                    }
                  }
                  rethrow;
                }
              }

              if (await requestAppRestart(dialogContext, restart) &&
                  dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: Text(l10n.backupPageOK),
          ),
        ],
      ),
    ),
  );
}
