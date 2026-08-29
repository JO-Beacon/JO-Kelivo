import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

enum BackupPhase {
  preparing,
  snapshot,
  packing,
  verifying,
  wrapping,
  extracting,
  restoring,
  finalizing,
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
