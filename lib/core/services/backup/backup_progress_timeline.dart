import 'backup_task_progress.dart';

/// 这条进度流水线属于哪种任务：导出（含云备份上传）还是恢复。
///
/// 两种任务经过的阶段集合不同，同一个阶段在各自流水线里占的比重也不同
/// （例如导出里的 packing 与恢复里的 extracting 都是一大步），因此需要
/// 两张独立的权重表。
enum BackupProgressFlow { export, restore }

/// 阶段在整条流水线里占的区间 [起点, 终点]，取值 0..1。
///
/// 这些权重是**估算**，只用来把「当前处在哪一步、这一步走了多少」换算成
/// 一条连续的总体进度条；它不代表字节数，也不用于任何业务判断。阶段内
/// 没有可量化进度时，进度条停在区间起点，不向前编造。
const Map<BackupPhase, (double, double)> _exportTimeline =
    <BackupPhase, (double, double)>{
      BackupPhase.preparing: (0.00, 0.03),
      BackupPhase.listingRemote: (0.02, 0.05),
      BackupPhase.snapshottingDatabase: (0.03, 0.12),
      BackupPhase.packing: (0.12, 0.55),
      BackupPhase.verifying: (0.55, 0.75),
      BackupPhase.wrapping: (0.75, 0.97),
      BackupPhase.uploading: (0.75, 0.97),
      BackupPhase.finalizing: (0.97, 1.00),
    };

const Map<BackupPhase, (double, double)> _restoreTimeline =
    <BackupPhase, (double, double)>{
      BackupPhase.preparing: (0.00, 0.02),
      BackupPhase.extracting: (0.02, 0.30),
      BackupPhase.validating: (0.30, 0.38),
      BackupPhase.readingSettings: (0.38, 0.42),
      BackupPhase.stagingCandidate: (0.42, 0.80),
      BackupPhase.restoring: (0.42, 0.80),
      BackupPhase.committing: (0.80, 0.85),
      BackupPhase.importingSessions: (0.85, 0.90),
      BackupPhase.importingMessages: (0.90, 0.95),
      BackupPhase.materializingFiles: (0.95, 0.97),
      BackupPhase.finalizing: (0.97, 1.00),
    };

/// 把「阶段 + 阶段内进度」换算成整条流水线的总体进度（0..1）。
///
/// [localFraction] 为 null 表示该阶段没有可量化的进度，此时返回区间起点；
/// 阶段不在表中时返回 null，由调用方决定回退显示。
double? globalBackupFraction({
  required BackupProgressFlow flow,
  required BackupPhase phase,
  required double? localFraction,
}) {
  final table = flow == BackupProgressFlow.export
      ? _exportTimeline
      : _restoreTimeline;
  final range = table[phase];
  if (range == null) return null;
  final (start, end) = range;
  final local = localFraction;
  if (local == null) return start;
  return (start + (end - start) * local.clamp(0.0, 1.0)).clamp(0.0, 1.0);
}

/// 把连续的进度上报折叠成一条单调不减的总体进度。
///
/// 流水线里有些上报不带阶段（例如收尾时的 `value: 1`），这里沿用上一个已知
/// 阶段；总体进度只增不减，避免界面来回跳。
final class BackupProgressTimeline {
  BackupProgressTimeline(this.flow);

  final BackupProgressFlow flow;
  BackupPhase? _phase;
  double _current = 0;

  /// 当前总体进度；一次都还没收到有效上报时为 null。
  double? get current => _phase == null ? null : _current;

  double? update(BackupProgress progress) {
    _phase = progress.phase;
    return updatePhase(progress.phase, progress.fraction);
  }

  double? updatePhase(BackupPhase? phase, double? localFraction) {
    if (phase != null) _phase = phase;
    final known = _phase;
    if (known == null) return null;
    final global = globalBackupFraction(
      flow: flow,
      phase: known,
      localFraction: localFraction,
    );
    if (global == null) return _current;
    if (global > _current) _current = global;
    return _current;
  }
}
