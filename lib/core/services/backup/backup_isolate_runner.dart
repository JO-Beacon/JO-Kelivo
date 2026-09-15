import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../database/sqlite_interrupt.dart';
import '../../models/backup_task_progress.dart';
import '../../models/progress_update.dart';

typedef BackupIsolateBody<R, P> =
    FutureOr<R> Function(BackupIsolateContext context, P payload);

/// 隔离线程在杀掉它之后仍然没有退出的超时。
///
/// [isolateExited] 为 false 表示线程可能还活着——它正卡在某个既不响应
/// 信号、也不响应 `Isolate.kill` 的本地调用里。[isolateExit] 是它真正
/// 退出的那一刻，供调用方把临时目录的删除推迟到那之后。
final class BackupIsolateTimeoutException extends TimeoutException {
  BackupIsolateTimeoutException({
    required this.isolateExited,
    this.isolateExit,
    Duration? duration,
  }) : super('backup_isolate_timeout', duration);

  final bool isolateExited;
  final Future<void>? isolateExit;
}

/// 隔离线程是否可能还活着。
///
/// 只有这个为真时，调用方才不能立刻删除它的工作目录：那个目录可能正被
/// 一个仍在运行的本地调用写入，删早了它会写进一个已删除的路径，或者
/// 把文件重新创建出来。
bool backupIsolateStillAlive(Object error) {
  return (error is BackupIsolateTimeoutException && !error.isolateExited) ||
      (error is BackupCancelledException && !error.isolateExited);
}

/// 隔离线程真正退出的那一刻；无法得知时为 null。
Future<void>? backupIsolateExitFuture(Object error) {
  return switch (error) {
    BackupIsolateTimeoutException(:final isolateExit) => isolateExit,
    BackupCancelledException(:final isolateExit) => isolateExit,
    _ => null,
  };
}

/// 仅供测试：跳过 `Isolate.kill`，用来模拟一个杀不掉的本地调用。
@visibleForTesting
bool debugSkipBackupIsolateKill = false;

final class BackupIsolateContext {
  const BackupIsolateContext({
    required this.cancelFlag,
    required this.reportCallback,
    this.registerSqliteHandleCallback,
    this.waitForSqliteCloseCallback,
  });

  final IsolateCancelFlag cancelFlag;
  final void Function(ProgressUpdate update) reportCallback;
  final void Function(int address)? registerSqliteHandleCallback;
  final Future<void> Function()? waitForSqliteCloseCallback;

  void throwIfCancelled() => cancelFlag.throwIfCancelled();

  void reportProgress(ProgressUpdate update) => reportCallback(update);

  void registerSqliteHandle(int address) =>
      registerSqliteHandleCallback?.call(address);

  Future<void> waitForSqliteClose() async =>
      await waitForSqliteCloseCallback?.call();
}

Future<R> runBackupIsolate<R, P>({
  required BackupIsolateBody<R, P> body,
  required P payload,
  BackupCancelToken? cancelToken,
  ProgressCallback? onProgress,
  // 取消后先中断 SQLite 并给线程一段时间自己收尾，再硬杀。JO 原先只有
  // 250ms，太短：正常收尾（关库、清中间文件）常常还没走完就被杀了。
  Duration killGrace = const Duration(seconds: 3),
  // 硬杀之后最多再等多久；超过就放弃等待并如实上报"线程可能还活着"。
  Duration isolateExitDeadline = const Duration(seconds: 2),
  Duration? timeout,
}) async {
  final progressPort = ReceivePort();
  final controlPort = ReceivePort();
  final exitPort = ReceivePort();
  final isolateExit = Completer<void>();
  var isolateHasExited = false;
  var workerRetained = false;

  void markIsolateExited() {
    isolateHasExited = true;
    if (!isolateExit.isCompleted) isolateExit.complete();
    if (workerRetained) {
      workerRetained = false;
      cancelToken?.releaseWorker();
    }
  }

  if (cancelToken != null) {
    cancelToken.retainWorker();
    workerRetained = true;
  }

  late final Isolate isolate;
  try {
    isolate = await Isolate.spawn<_SpawnMessage>(
      _entry,
      _SpawnMessage(
        progressPort.sendPort,
        controlPort.sendPort,
        cancelToken?.cellAddress,
        payload,
        body,
      ),
      errorsAreFatal: true,
      onExit: exitPort.sendPort,
    );
  } catch (_) {
    if (workerRetained) cancelToken?.releaseWorker();
    progressPort.close();
    controlPort.close();
    exitPort.close();
    rethrow;
  }

  final result = Completer<R>();
  var cancellationRequested = cancelToken?.isCancelled == true;
  var timeoutRequested = false;
  var sqliteHandle = 0;
  Timer? killTimer;
  Timer? abandonTimer;
  Timer? timeoutTimer;
  SendPort? commandPort;

  void interruptSqlite() {
    if (sqliteHandle != 0) interruptSqliteHandle(sqliteHandle);
  }

  /// 放弃等待那个已经不响应杀掉的线程。
  ///
  /// 这里必须让 [result] 有个结果，否则调用方会被一个永远不退出的隔离
  /// 线程吊死；而抛出的异常带上 `isolateExited: false` 与 [isolateExit]，
  /// 让上层据此把临时目录的删除推迟到线程真正退出之后。
  void abandonStuckIsolate() {
    if (result.isCompleted) return;
    if (timeoutRequested) {
      result.completeError(
        BackupIsolateTimeoutException(
          isolateExited: isolateHasExited,
          isolateExit: isolateExit.future,
          duration: timeout,
        ),
      );
      return;
    }
    result.completeError(
      BackupCancelledException(
        isolateExited: isolateHasExited,
        isolateExit: isolateExit.future,
      ),
    );
  }

  void scheduleKill() {
    interruptSqlite();
    killTimer ??= Timer(killGrace, () {
      if (debugSkipBackupIsolateKill) return;
      if (!isolateHasExited) isolate.kill(priority: Isolate.immediate);
    });
    abandonTimer ??= Timer(killGrace + isolateExitDeadline, () {
      abandonStuckIsolate();
    });
  }

  final progressSub = progressPort.listen((message) {
    if (message is ProgressUpdate) onProgress?.call(message);
  });
  final controlSub = controlPort.listen((message) {
    if (message is _Ready) {
      commandPort = message.commandPort;
    } else if (message is _SqliteOpened) {
      sqliteHandle = message.address;
      if (cancellationRequested || timeoutRequested) interruptSqlite();
    } else if (message is _SqliteClosing) {
      sqliteHandle = 0;
      commandPort?.send(const _SqliteCloseAck());
    } else if (!result.isCompleted && message is _Success) {
      result.complete(message.value as R);
    } else if (!result.isCompleted && message is _Failure) {
      result.completeError(message.error, message.stackTrace);
    }
  });
  final exitSub = exitPort.listen((_) {
    markIsolateExited();
    if (result.isCompleted) return;
    if (timeoutRequested) {
      result.completeError(
        BackupIsolateTimeoutException(
          isolateExited: true,
          isolateExit: isolateExit.future,
          duration: timeout,
        ),
      );
    } else if (cancellationRequested) {
      result.completeError(
        BackupCancelledException(isolateExit: isolateExit.future),
      );
    } else {
      result.completeError(StateError('backup_isolate_exited'));
    }
  });

  void requestCancellation() {
    if (cancellationRequested) return;
    cancellationRequested = true;
    scheduleKill();
  }

  if (cancelToken != null) {
    cancelToken.whenCancelled.then((_) => requestCancellation());
  }
  if (timeout != null) {
    timeoutTimer = Timer(timeout, () {
      timeoutRequested = true;
      cancelToken?.cancel();
      requestCancellation();
    });
  }
  if (cancellationRequested) scheduleKill();

  try {
    return await result.future;
  } finally {
    timeoutTimer?.cancel();
    killTimer?.cancel();
    abandonTimer?.cancel();
    await progressSub.cancel();
    progressPort.close();
    if (isolateHasExited) {
      await controlSub.cancel();
      await exitSub.cancel();
      controlPort.close();
      exitPort.close();
    } else {
      unawaited(
        isolateExit.future.whenComplete(() async {
          await controlSub.cancel();
          await exitSub.cancel();
          controlPort.close();
          exitPort.close();
        }),
      );
    }
  }
}

@pragma('vm:entry-point')
void _entry(_SpawnMessage message) async {
  final commandPort = ReceivePort();
  message.controlPort.send(_Ready(commandPort.sendPort));
  Completer<void>? closeAck;
  final commandSub = commandPort.listen((value) {
    if (value is _SqliteCloseAck) closeAck?.complete();
  });
  final flag = message.cancelCellAddress == null
      ? IsolateCancelFlag.disabled()
      : IsolateCancelFlag.fromAddress(message.cancelCellAddress!);
  final context = BackupIsolateContext(
    cancelFlag: flag,
    reportCallback: (update) => message.progressPort.send(update),
    registerSqliteHandleCallback: (address) =>
        message.controlPort.send(_SqliteOpened(address)),
    waitForSqliteCloseCallback: () async {
      final completer = Completer<void>();
      closeAck = completer;
      message.controlPort.send(const _SqliteClosing());
      await completer.future;
    },
  );
  try {
    final value = await message.body(context, message.payload);
    message.controlPort.send(_Success(value));
  } catch (error, stackTrace) {
    message.controlPort.send(_Failure(error, stackTrace));
  } finally {
    await commandSub.cancel();
    commandPort.close();
  }
}

final class _SpawnMessage {
  const _SpawnMessage(
    this.progressPort,
    this.controlPort,
    this.cancelCellAddress,
    this.payload,
    this.body,
  );

  final SendPort progressPort;
  final SendPort controlPort;
  final int? cancelCellAddress;
  final Object? payload;
  final Function body;
}

final class _Ready {
  const _Ready(this.commandPort);
  final SendPort commandPort;
}

final class _Success {
  const _Success(this.value);
  final Object? value;
}

final class _Failure {
  const _Failure(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

final class _SqliteOpened {
  const _SqliteOpened(this.address);
  final int address;
}

final class _SqliteClosing {
  const _SqliteClosing();
}

final class _SqliteCloseAck {
  const _SqliteCloseAck();
}
