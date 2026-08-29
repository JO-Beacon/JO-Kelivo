import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/backup.dart';
import '../../../core/models/backup_task_progress.dart';
import '../../../core/providers/backup_provider.dart';
import '../../../core/services/backup/associated_backup_path.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/dialogs/loading_task_dialog.dart';
import '../../../utils/app_directories.dart';
import '../backup_restart_dialog.dart';
import '../backup_restore_error_message.dart';

/// 处理 Windows 文件关联启动传入的 `.joaiclient` 路径。
///
/// 该组件只负责冷启动入口；手动导入仍由备份页面自己的交互处理。
class AssociatedBackupImportLauncher extends StatefulWidget {
  const AssociatedBackupImportLauncher({
    super.key,
    this.path,
    required this.child,
  });

  final String? path;
  final Widget child;

  @override
  State<AssociatedBackupImportLauncher> createState() =>
      _AssociatedBackupImportLauncherState();
}

class _AssociatedBackupImportLauncherState
    extends State<AssociatedBackupImportLauncher> {
  var _scheduled = false;
  StreamSubscription<String>? _pathSubscription;
  var _processing = false;
  final _queuedPaths = <String>[];

  @override
  void initState() {
    super.initState();
    _pathSubscription = AssociatedBackupPathEvents.instance.paths.listen(
      _receivePath,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final path = widget.path;
      if (path != null) await _openAssociatedBackup(path);
    });
  }

  void _receivePath(String path) {
    if (_processing) {
      _queuedPaths.add(path);
      return;
    }
    unawaited(_openAssociatedBackup(path));
  }

  Future<void> _openAssociatedBackup(String requestedPath) async {
    if (_processing) {
      _queuedPaths.add(requestedPath);
      return;
    }
    _processing = true;
    try {
      await _openAssociatedBackupOnce(requestedPath);
    } finally {
      _processing = false;
      if (_queuedPaths.isNotEmpty && mounted) {
        final nextPath = _queuedPaths.removeAt(0);
        unawaited(_openAssociatedBackup(nextPath));
      }
    }
  }

  Future<void> _openAssociatedBackupOnce(String requestedPath) async {
    if (!mounted) return;
    final path = requestedPath.trim();
    if (path.isEmpty || !path.toLowerCase().endsWith('.joaiclient')) return;

    final file = File(path);
    if (!await file.exists()) {
      stderr.writeln('[AssociatedBackupImport] file not found: $path');
      return;
    }
    if (!mounted) return;

    final appDataDirectory = await AppDirectories.getAppDataDirectory();
    if (await AssociatedBackupPathEvents.hasConsumedPath(
      appDataDirectory,
      path,
    )) {
      return;
    }

    await _waitForStartupNotices();
    if (!mounted) return;
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    final mode = await _showRestoreModeDialog(context);
    if (mode == null || !mounted) return;

    final backupProvider = context.read<BackupProvider>();
    final l10n = AppLocalizations.of(context)!;
    try {
      // Consume the request before restore starts. Windows process restarts
      // inherit the original command line and must not schedule this file again.
      await AssociatedBackupPathEvents.clearPendingPath(appDataDirectory);
      await AssociatedBackupPathEvents.persistConsumedPath(
        appDataDirectory,
        path,
      );
      if (!mounted) {
        await AssociatedBackupPathEvents.clearConsumedPath(appDataDirectory);
        return;
      }
      await runWithLoadingTaskDialog<void>(
        context: context,
        cancellableTask: (onProgress, cancelToken) =>
            backupProvider.restoreFromLocalFile(
              file,
              mode: mode,
              onProgress: onProgress,
              cancelToken: cancelToken,
            ),
        label: l10n.backupPageRestore,
        cancelLabel: l10n.backupPageCancel,
      );
    } on BackupCancelledException {
      await AssociatedBackupPathEvents.clearConsumedPath(appDataDirectory);
      return;
    } catch (error) {
      await AssociatedBackupPathEvents.clearConsumedPath(appDataDirectory);
      if (!mounted) return;
      showBackupRestoreErrorSnackBar(
        context,
        error,
        message: l10n.backupPageRestoreFailedMessage(
          backupRestoreErrorMessage(l10n, error),
        ),
      );
      return;
    }
    if (!rootContext.mounted) return;
    await showBackupRestartRequiredDialog(
      rootContext,
      skippedConversations: backupProvider.skippedConversations,
      suppressAssociatedPathOnRestart: true,
      associatedBackupPath: path,
    );
  }

  Future<void> _waitForStartupNotices() async {
    for (var attempt = 0; attempt < 100 && mounted; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent ?? true) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<RestoreMode?> _showRestoreModeDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return showDialog<RestoreMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.backupPageSelectImportMode),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RestoreModeOption(
              icon: Icons.restore_rounded,
              title: l10n.backupPageOverwriteMode,
              subtitle: l10n.backupPageOverwriteModeDescription,
              color: colors.primary,
              onTap: () =>
                  Navigator.of(dialogContext).pop(RestoreMode.overwrite),
            ),
            const SizedBox(height: 10),
            _RestoreModeOption(
              icon: Icons.merge_type_rounded,
              title: l10n.backupPageMergeMode,
              subtitle: l10n.backupPageMergeModeDescription,
              color: colors.primary,
              onTap: () => Navigator.of(dialogContext).pop(RestoreMode.merge),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.backupPageCancel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    _pathSubscription?.cancel();
    super.dispose();
  }
}

class _RestoreModeOption extends StatelessWidget {
  const _RestoreModeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
