import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/widgets/snackbar.dart';

String backupRestoreErrorMessage(AppLocalizations localizations, Object error) {
  final code = backupRestoreDiagnosticCode(error);
  if (_isJoaiclientArchiveError(code)) {
    return localizations.backupRestoreCorruptArchiveMessage(code);
  }
  return error.toString();
}

String backupRestoreDiagnosticCode(Object error) {
  final message = switch (error) {
    StateError() => error.message,
    FormatException() => error.message,
    _ => null,
  };
  final raw = message?.toString();
  if (raw != null && RegExp(r'^[a-zA-Z0-9_.:-]{1,160}$').hasMatch(raw)) {
    return raw;
  }
  return error.runtimeType.toString();
}

void showBackupRestoreErrorSnackBar(
  BuildContext context,
  Object error, {
  String? message,
}) {
  final l10n = AppLocalizations.of(context)!;
  final diagnosticCode = backupRestoreDiagnosticCode(error);
  showAppSnackBar(
    context,
    message: message ?? backupRestoreErrorMessage(l10n, error),
    type: NotificationType.error,
    actionIcon: Icons.copy_rounded,
    actionTooltip: l10n.backupRestoreFailureCopyButton,
    onAction: () {
      unawaited(Clipboard.setData(ClipboardData(text: diagnosticCode)));
    },
  );
}

bool _isJoaiclientArchiveError(String code) =>
    code == 'joaiclient_header' ||
    code == 'joaiclient_magic' ||
    code == 'joaiclient_header_version' ||
    code == 'joaiclient_payload_size' ||
    code == 'joaiclient_payload_length' ||
    code == 'joaiclient_payload_truncated' ||
    code == 'joaiclient_payload_hash';
