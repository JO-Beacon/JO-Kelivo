import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'snackbar.dart';

/// 请求进程重启；当平台无法安排重启时，保持当前重试界面可见。
Future<bool> requestAppRestart(
  BuildContext context,
  Future<void> Function() restart,
) async {
  try {
    await restart();
    return true;
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Kelivo restart',
        context: ErrorDescription('while requesting a process restart'),
      ),
    );
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: AppLocalizations.of(context)!.restartAppFailedMessage,
        type: NotificationType.error,
      );
    }
    return false;
  }
}
