import '../services/backup/backup_task_progress.dart';

typedef ProgressCallback = void Function(ProgressUpdate update);

final class ProgressUpdate {
  const ProgressUpdate({this.value, this.processed, this.total, this.phase});

  final double? value;
  final int? processed;
  final int? total;
  final BackupPhase? phase;

  double? get fraction {
    final explicit = value;
    if (explicit != null) return explicit.clamp(0, 1).toDouble();
    final current = processed;
    final maximum = total;
    if (current == null || maximum == null || maximum <= 0) return null;
    return (current / maximum).clamp(0, 1).toDouble();
  }
}

/// 把本仓库老管线的 [ProgressCallback] 适配成上游的 [BackupProgressSink]。
///
/// 两套进度类型暂时并存（[adaptBackupProgressSink] 是反方向的适配）：
/// 老的 [ProgressUpdate] 只带 0..1 的比值，这里改由 processed／total 承载，
/// 下游用 [BackupProgress.fraction] 读回来仍是同一个比值，阶段原样透传。
BackupProgressSink? adaptProgressCallbackToSink(ProgressCallback? callback) {
  if (callback == null) return null;
  return (progress) {
    callback(
      ProgressUpdate(
        processed: progress.processed,
        total: progress.total,
        phase: progress.phase,
      ),
    );
  };
}
