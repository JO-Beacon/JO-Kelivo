import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/backup.dart';
import '../../core/services/backup/associated_backup_path.dart';
import '../../core/services/backup/local_device_settings_ledger.dart';
import '../../core/services/device/device_identity.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/restart_app_action.dart';
import '../../utils/app_directories.dart';
import '../../utils/platform_utils.dart';
import 'device_ledger_labels.dart';

Future<void> showBackupRestartRequiredDialog(
  BuildContext context, {
  int skippedConversations = 0,
  List<DeviceSettingsRecord> ledgerRecords = const [],
  String? currentFingerprint,
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
        content: _RestoreCompletionContent(
          lines: [
            skippedConversations > 0
                ? l10n.backupPageRestartContentWithSkipped(skippedConversations)
                : l10n.backupPageRestartContent,
          ],
          ledgerRecords: ledgerRecords,
          currentFingerprint: currentFingerprint,
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

/// 恢复流程结束后的收尾提示。
///
/// 完全覆盖会换库，必须重启才能安全应用，因此仍走重启提示。
/// 合并保留是就地合并，流程结束时数据已经生效，不再要求重启；
/// 但如果备份里有会话因消息顺序非法被跳过，需要单独告知，
/// 否则这部分数据会被静默丢弃。
Future<void> showRestoreCompletionDialog(
  BuildContext context, {
  required RestoreMode mode,
  int skippedConversations = 0,
  int localSettingsApplied = 0,
  List<DeviceSettingsRecord> ledgerRecords = const [],
  bool suppressAssociatedPathOnRestart = false,
  String? associatedBackupPath,
}) async {
  // 只有确实要展示设备记录时才去解析本机指纹（用于标注「（本机）」）。
  // 指纹服务有进程内缓存，导出/恢复流程早已解析过，这里不会重复付出代价。
  final currentFingerprint = ledgerRecords.isEmpty
      ? null
      : (await DeviceIdentityService.resolve())?.fingerprintHash;
  if (!context.mounted) return;
  if (mode == RestoreMode.overwrite) {
    return showBackupRestartRequiredDialog(
      context,
      skippedConversations: skippedConversations,
      ledgerRecords: ledgerRecords,
      currentFingerprint: currentFingerprint,
      suppressAssociatedPathOnRestart: suppressAssociatedPathOnRestart,
      associatedBackupPath: associatedBackupPath,
    );
  }
  if (skippedConversations <= 0 && localSettingsApplied <= 0) {
    return Future<void>.value();
  }
  return _showMergeNotice(
    context,
    skippedConversations: skippedConversations,
    localSettingsApplied: localSettingsApplied,
    ledgerRecords: ledgerRecords,
    currentFingerprint: currentFingerprint,
  );
}

Future<void> _showMergeNotice(
  BuildContext context, {
  required int skippedConversations,
  required int localSettingsApplied,
  List<DeviceSettingsRecord> ledgerRecords = const [],
  String? currentFingerprint,
}) {
  final l10n = AppLocalizations.of(context)!;
  final lines = <String>[
    if (skippedConversations > 0)
      l10n.backupPageMergeCompletedWithSkipped(skippedConversations),
    if (localSettingsApplied > 0)
      l10n.backupLocalSettingsAppliedNotice(localSettingsApplied),
  ];
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Theme.of(dialogContext).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.backupPageMergeCompleted),
      content: _RestoreCompletionContent(
        lines: lines,
        ledgerRecords: ledgerRecords,
        currentFingerprint: currentFingerprint,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.backupPageOK),
        ),
      ],
    ),
  );
}

/// 收尾弹窗的正文：若干提示行 + 「本机设置记录」纯展示区块。
///
/// 区块只列出本次恢复在包内看到的设备记录（设备名 / 平台 / 时间 / 设置项数），
/// 本机那一行带「（本机）」标注；不含任何交互控件——恢复控制已按模式自动决定。
class _RestoreCompletionContent extends StatelessWidget {
  const _RestoreCompletionContent({
    required this.lines,
    required this.ledgerRecords,
    required this.currentFingerprint,
  });

  final List<String> lines;
  final List<DeviceSettingsRecord> ledgerRecords;
  final String? currentFingerprint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (lines.isNotEmpty) Text(lines.join('\n\n')),
          if (ledgerRecords.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '${l10n.backupLedgerTitle} · '
              '${l10n.backupLedgerDeviceCount(ledgerRecords.length)}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            for (final record in ledgerRecords)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${record.deviceName}'
                      '${record.fingerprint == currentFingerprint ? l10n.backupLedgerThisDevice : ''}',
                      style: TextStyle(fontSize: 13, color: cs.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${devicePlatformLabel(l10n, record.platform)} · '
                      '${deviceLedgerTimestamp(record.savedAtUtc)} · '
                      '${l10n.backupLedgerItemCount(record.values.length)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
