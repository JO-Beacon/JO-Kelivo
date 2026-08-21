import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../core/models/progress_update.dart';
import '../widgets/loading_dialog_card.dart';

/// 只有在不可关闭的加载对话框绘制完成后才运行 [task]。
Future<T> runWithLoadingTaskDialog<T>({
  required BuildContext context,
  required Future<T> Function(ProgressCallback onProgress) task,
  String? label,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final progress = ValueNotifier<ProgressUpdate?>(null);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) {
      final loadingLayer = Stack(
        fit: StackFit.expand,
        children: [
          const ModalBarrier(dismissible: false, color: Colors.black54),
          ValueListenableBuilder<ProgressUpdate?>(
            valueListenable: progress,
            builder: (context, update, child) =>
                LoadingDialogCard(label: label, progress: update?.fraction),
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
    return await task((update) => progress.value = update);
  } finally {
    if (entry.mounted) entry.remove();
    progress.dispose();
  }
}
