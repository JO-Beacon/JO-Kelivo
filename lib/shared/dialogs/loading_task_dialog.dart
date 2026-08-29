import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../core/models/progress_update.dart';
import '../../core/models/backup_task_progress.dart';
import '../widgets/loading_dialog_card.dart';

/// 只有在不可关闭的加载对话框绘制完成后才运行 [task]。
Future<T> runWithLoadingTaskDialog<T>({
  required BuildContext context,
  Future<T> Function(ProgressCallback onProgress)? task,
  Future<T> Function(ProgressCallback onProgress, BackupCancelToken token)?
  cancellableTask,
  String? label,
  String? cancelLabel,
}) async {
  assert(task != null || cancellableTask != null);
  final overlay = Overlay.of(context, rootOverlay: true);
  final progress = ValueNotifier<ProgressUpdate?>(null);
  final cancelToken = BackupCancelToken();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) {
      final loadingLayer = Stack(
        fit: StackFit.expand,
        children: [
          const ModalBarrier(dismissible: false, color: Colors.black54),
          ValueListenableBuilder<ProgressUpdate?>(
            valueListenable: progress,
            builder: (context, update, child) => LoadingDialogCard(
              label: label,
              progress: update?.fraction,
              onCancel: cancellableTask == null ? null : cancelToken.cancel,
              cancelLabel: cancelLabel,
            ),
          ),
        ],
      );
      if (defaultTargetPlatform == TargetPlatform.windows) {
        return Positioned.fill(top: 40, child: loadingLayer);
      }
      return loadingLayer;
    },
  );
  overlay.insert(entry);

  // Overlay 的插入及其首次绘制发生在下一帧。如果在此之前开始同步前缀操作，
  // 窗口可能会保持视觉空白。
  await WidgetsBinding.instance.endOfFrame;

  try {
    if (cancellableTask != null) {
      return await cancellableTask(
        (update) => progress.value = update,
        cancelToken,
      );
    }
    final regularTask = task;
    if (regularTask == null) {
      throw StateError('missing_loading_task');
    }
    return await regularTask((update) => progress.value = update);
  } finally {
    if (entry.mounted) entry.remove();
    cancelToken.dispose();
    progress.dispose();
  }
}
