import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/backup/backup_progress_timeline.dart';
import 'package:Kelivo/core/services/backup/backup_task_progress.dart';

void main() {
  group('globalBackupFraction', () {
    test('导出流：阶段内的局部进度落在该阶段的区间里', () {
      final start = globalBackupFraction(
        flow: BackupProgressFlow.export,
        phase: BackupPhase.packing,
        localFraction: 0,
      );
      final mid = globalBackupFraction(
        flow: BackupProgressFlow.export,
        phase: BackupPhase.packing,
        localFraction: 0.5,
      );
      final end = globalBackupFraction(
        flow: BackupProgressFlow.export,
        phase: BackupPhase.packing,
        localFraction: 1,
      );
      expect(start, 0.12);
      expect(mid, closeTo(0.335, 1e-9));
      expect(end, 0.55);
      expect(start! < mid! && mid < end!, isTrue);
    });

    test('没有局部进度时停在区间起点，不向前编造', () {
      expect(
        globalBackupFraction(
          flow: BackupProgressFlow.export,
          phase: BackupPhase.snapshottingDatabase,
          localFraction: null,
        ),
        0.03,
      );
    });

    test('不在表里的阶段返回 null', () {
      expect(
        globalBackupFraction(
          flow: BackupProgressFlow.export,
          phase: BackupPhase.committing,
          localFraction: 0.5,
        ),
        isNull,
      );
    });

    test('恢复流的 extracting 覆盖 0.02..0.30', () {
      expect(
        globalBackupFraction(
          flow: BackupProgressFlow.restore,
          phase: BackupPhase.extracting,
          localFraction: 0,
        ),
        0.02,
      );
      expect(
        globalBackupFraction(
          flow: BackupProgressFlow.restore,
          phase: BackupPhase.extracting,
          localFraction: 1,
        ),
        0.30,
      );
    });
  });

  group('BackupProgressTimeline', () {
    test('总体进度单调不减，且忽略回退', () {
      final timeline = BackupProgressTimeline(BackupProgressFlow.export);
      expect(timeline.current, isNull);

      timeline.update(
        const BackupProgress(
          phase: BackupPhase.packing,
          processed: 50,
          total: 100,
        ),
      );
      final atPacking = timeline.current!;
      expect(atPacking, greaterThan(0.12));

      // 迟到的、阶段更靠前的上报不得让进度回退。
      timeline.update(
        const BackupProgress(
          phase: BackupPhase.snapshottingDatabase,
          processed: 1,
          total: 100,
        ),
      );
      expect(timeline.current, atPacking);
    });

    test('阶段内没有总量时取区间起点', () {
      final timeline = BackupProgressTimeline(BackupProgressFlow.export);
      timeline.update(
        const BackupProgress(phase: BackupPhase.preparing, processed: 0),
      );
      expect(timeline.current, 0.0);
    });

    test('不带阶段的上报沿用上一个已知阶段', () {
      final timeline = BackupProgressTimeline(BackupProgressFlow.restore);
      timeline.updatePhase(BackupPhase.stagingCandidate, null);
      final atStaging = timeline.current!;
      timeline.updatePhase(null, null);
      expect(timeline.current, atStaging);
    });
  });
}
