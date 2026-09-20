/// 备份/恢复流水线的阶段。
///
/// 前 16 项与上游逐字一致；末尾两项是 JO-AIClient 独有的阶段：
/// [wrapping] 表示把 ZIP 载荷封装进 `.joaiclient` 容器，
/// [restoring] 表示 JO 自有恢复流程的落盘阶段。两者都只用于 JO 自己的
/// 进度上报，上游没有对应阶段。
enum BackupPhase {
  preparing,
  snapshottingDatabase,
  packing,
  verifying,
  uploading,
  downloading,
  extracting,
  validating,
  readingSettings,
  stagingCandidate,
  committing,
  importingSessions,
  importingMessages,
  materializingFiles,
  listingRemote,
  finalizing,
  // --- JO-AIClient 独有 ---
  wrapping,
  restoring,
}

enum BackupProgressUnit { none, bytes, items }

/// 与 [ProgressUpdate] 并存：本仓库的备份流水线用 [ProgressUpdate]（只报一个
/// 0..1 的值），而这一套带单位、可取消标记与明细，供进度弹窗使用。
typedef BackupProgressSink = void Function(BackupProgress progress);

final class BackupProgress {
  const BackupProgress({
    required this.phase,
    required this.processed,
    this.total,
    this.unit = BackupProgressUnit.none,
    this.cancellable = true,
    this.detail,
  });

  final BackupPhase phase;
  final int processed;
  final int? total;
  final BackupProgressUnit unit;
  final bool cancellable;
  final String? detail;

  double? get fraction => (total != null && total! > 0)
      ? (processed / total!).clamp(0.0, 1.0)
      : null;
}
