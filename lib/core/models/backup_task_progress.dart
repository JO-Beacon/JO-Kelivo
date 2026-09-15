import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

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

/// 与 [ProgressUpdate] 并存：JO 的备份流水线用 [ProgressUpdate]（只报一个
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

final class BackupCancelToken {
  BackupCancelToken() : _cell = calloc<Int32>() {
    _cell!.value = 0;
  }

  Pointer<Int32>? _cell;
  final Completer<void> _cancelled = Completer<void>();
  var _cancellable = true;
  var _disposeRequested = false;
  var _outstandingWorkers = 0;

  int get cellAddress {
    final cell = _cell;
    if (_disposeRequested || cell == null) {
      throw StateError('BackupCancelToken disposed');
    }
    return cell.address;
  }

  bool get isCancelled => (_cell?.value ?? 0) != 0;

  bool get cancellable => _cancellable;

  bool get isCellAllocated => _cell != null;

  Future<void> get whenCancelled => _cancelled.future;

  void setCancellable(bool value) => _cancellable = value;

  void retainWorker() {
    if (_disposeRequested || _cell == null) {
      throw StateError('BackupCancelToken disposed');
    }
    _outstandingWorkers++;
  }

  void releaseWorker() {
    if (_outstandingWorkers > 0) _outstandingWorkers--;
    if (_disposeRequested && _outstandingWorkers == 0) _freeCell();
  }

  void cancel() {
    if (_disposeRequested || !_cancellable) return;
    final cell = _cell;
    if (cell != null) cell.value = 1;
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const BackupCancelledException();
  }

  void dispose() {
    if (_disposeRequested) return;
    _disposeRequested = true;
    if (_outstandingWorkers == 0) _freeCell();
  }

  void _freeCell() {
    final cell = _cell;
    _cell = null;
    if (cell != null) calloc.free(cell);
  }
}

final class BackupCancelledException implements Exception {
  const BackupCancelledException({this.isolateExited = true, this.isolateExit});

  final bool isolateExited;
  final Future<void>? isolateExit;

  @override
  String toString() => 'backup_cancelled';
}

final class IsolateCancelFlag {
  IsolateCancelFlag.fromAddress(int address)
    : _cell = Pointer<Int32>.fromAddress(address);

  IsolateCancelFlag.disabled() : _cell = nullptr;

  final Pointer<Int32> _cell;

  bool get isCancelled => _cell.address != 0 && _cell.value != 0;

  void throwIfCancelled() {
    if (isCancelled) throw const BackupCancelledException();
  }
}
