import 'package:flutter/material.dart';

import '../widgets/loading_dialog_card.dart';

/// Runs [task] only after a non-dismissible loading dialog has been painted.
Future<T> runWithLoadingTaskDialog<T>({
  required BuildContext context,
  required Future<T> Function() task,
  String? label,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        PopScope(canPop: false, child: LoadingDialogCard(label: label)),
  );
  final dialogClosed = navigator.push<void>(route);

  // Route insertion and its first paint happen in the next frame. Starting a
  // synchronous prefix before this point can leave the window visually blank.
  await WidgetsBinding.instance.endOfFrame;

  try {
    return await task();
  } finally {
    if (route.isActive && navigator.mounted) {
      navigator.removeRoute(route);
    }
    await dialogClosed;
  }
}
