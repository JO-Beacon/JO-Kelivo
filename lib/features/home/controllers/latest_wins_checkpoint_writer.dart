import 'dart:async';

typedef CheckpointDelay = Future<void> Function(Duration duration);

/// 串行化检查点写入，同时只保留最新的待处理值。
///
/// [finalize] 关闭队列，丢弃被最终写入取代的待处理检查点，等待正在进行的检查点，
/// 然后执行最终写入。
class LatestWinsCheckpointWriter<T> {
  LatestWinsCheckpointWriter({
    required this.write,
    this.minimumInterval = const Duration(milliseconds: 250),
    DateTime Function()? now,
    CheckpointDelay? delay,
    this.onError,
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  final Future<void> Function(T value) write;
  final DateTime Function() _now;
  final CheckpointDelay _delay;
  final void Function(Object error, StackTrace stackTrace)? onError;
  final Duration minimumInterval;

  T Function()? _pending;
  Future<void>? _drainFuture;
  DateTime? _lastWriteStartedAt;
  bool _accepting = true;

  void add(T Function() build) {
    if (!_accepting) {
      throw StateError('Checkpoint writer is closed.');
    }
    _pending = build;
    _drainFuture ??= _drain();
  }

  Future<void> barrier() => _drainFuture ?? Future<void>.value();

  Future<R> finalize<R>(Future<R> Function() writeFinal) async {
    if (!_accepting) {
      throw StateError('Checkpoint writer is closed.');
    }
    _accepting = false;
    _pending = null;
    await _drainFuture;
    return writeFinal();
  }

  Future<void> _drain() async {
    try {
      while (_pending != null) {
        final lastStartedAt = _lastWriteStartedAt;
        if (lastStartedAt != null) {
          final elapsed = _now().difference(lastStartedAt);
          final remaining = minimumInterval - elapsed;
          if (remaining > Duration.zero) {
            await _delay(remaining);
          }
        }

        final build = _pending;
        if (build == null) break;
        _pending = null;
        _lastWriteStartedAt = _now();
        try {
          await write(build());
        } catch (error, stackTrace) {
          // 中间检查点是尽力而为。失败的快照
          // （例如临时 DB busy/locked）会被丢弃并报告，
          // 但绝不能污染队列或中止正在进行的生成：
          // 下一个块会取代它，权威的 finalize
          // 写入会暴露其上的任何持久性失败（例如磁盘已满）。
          // 自身。
          onError?.call(error, stackTrace);
        }
      }
    } finally {
      _drainFuture = null;
    }
  }
}
