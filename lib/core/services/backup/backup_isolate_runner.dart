import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../../database/sqlite_interrupt.dart';
import 'backup_cancel_token.dart';
import 'backup_task_progress.dart';

export '../../database/sqlite_interrupt.dart'
    show debugOnInterruptSqliteHandle, interruptSqliteHandle;

/// 仅供测试：跳过 `Isolate.kill`，用来模拟一个杀不掉的本地调用。
@visibleForTesting
bool debugSkipBackupIsolateKill = false;

/// 仅供测试：让调用线程阻塞在一个既不理会 `Isolate.kill`、也不理会信号的本地
/// sleep 里，用来模拟杀不掉的本地调用。
///
/// libc 的 `sleep` 遇到任何信号都会提前返回，而 Linux 上 Dart VM 的分析器
/// 会用 SIGPROF 采样线程，所以这里先把线程的信号屏蔽掉；不做这一步，
/// 那个“卡住”的隔离线程会在毫秒内就结束。
void debugNativeSleepIgnoringKill(int seconds) {
  if (Platform.isWindows) {
    DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Void Function(Uint32), void Function(int)>('Sleep')
        .call(seconds * 1000);
    return;
  }
  final libc = DynamicLibrary.process();
  final pthreadSigmask = libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Pointer<Void>),
        int Function(int, Pointer<Void>, Pointer<Void>)
      >('pthread_sigmask');
  // 比任何平台的 sigset_t 都大（glibc 是 128 字节）。
  final set = calloc<Uint8>(256);
  final oldSet = calloc<Uint8>(256);
  var maskChanged = false;
  try {
    libc
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('sigfillset')
        .call(set.cast());
    // SIG_BLOCK 在 Linux/Android 上是 0，在 BSD 系的 Apple libc 上是 1。
    final sigBlock = Platform.isMacOS || Platform.isIOS ? 1 : 0;
    maskChanged = pthreadSigmask(sigBlock, set.cast(), oldSet.cast()) == 0;
    libc
        .lookupFunction<Int32 Function(Uint32), int Function(int)>('sleep')
        .call(seconds);
  } finally {
    if (maskChanged) {
      // SIG_SETMASK 在 Linux/Android 上是 2，在 BSD 系的 Apple libc 上是 3。
      final sigSetMask = Platform.isMacOS || Platform.isIOS ? 3 : 2;
      pthreadSigmask(sigSetMask, oldSet.cast(), nullptr);
    }
    calloc.free(oldSet);
    calloc.free(set);
  }
}

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

Future<void>? backupIsolateExitFuture(Object error) {
  return switch (error) {
    BackupIsolateTimeoutException(:final isolateExit) => isolateExit,
    BackupCancelledException(:final isolateExit) => isolateExit,
    _ => null,
  };
}

final class BackupIsolateContext {
  BackupIsolateContext({
    required this.cancelFlag,
    required this._reportProgress,
    this._registerSqliteInterruptHandle,
    this._waitForSqliteCloseAck,
  });

  final IsolateCancelFlag cancelFlag;
  final void Function(BackupProgress progress) _reportProgress;
  final void Function(int handleAddress)? _registerSqliteInterruptHandle;
  final Future<void> Function()? _waitForSqliteCloseAck;

  void throwIfCancelled() => cancelFlag.throwIfCancelled();

  void reportProgress(BackupProgress progress) => _reportProgress(progress);

  void registerSqliteInterruptHandle(int address) {
    _registerSqliteInterruptHandle?.call(address);
  }

  Future<void> waitForSqliteCloseAck() async {
    await _waitForSqliteCloseAck?.call();
  }
}

Future<R> runBackupIsolate<R, P>({
  required FutureOr<R> Function(BackupIsolateContext context, P payload) body,
  required P payload,
  BackupCancelToken? cancelToken,
  BackupProgressSink? onProgress,
  // 取消后先中断 SQLite 并给线程一段时间自己收尾，再硬杀。JO 原先只有
  // 250ms，太短：正常收尾（关库、清中间文件）常常还没走完就被杀了。
  Duration killGrace = const Duration(seconds: 3),
  // 硬杀之后最多再等多久；超过就放弃等待并如实上报“线程可能还活着”。
  Duration isolateExitDeadline = const Duration(seconds: 2),
  Duration? timeout,
}) async {
  final progressPort = ReceivePort();
  final controlPort = ReceivePort();
  final exitPort = ReceivePort();
  final isolateExit = Completer<void>();
  var isolateHasExited = false;
  var workerReleased = false;

  void markIsolateExited() {
    isolateHasExited = true;
    if (!isolateExit.isCompleted) {
      isolateExit.complete();
    }
    if (!workerReleased) {
      workerReleased = true;
      cancelToken?.releaseWorker();
    }
  }

  var retained = false;
  late final Isolate isolate;
  try {
    if (cancelToken != null) {
      cancelToken.retainWorker();
      retained = true;
    }
    isolate = await Isolate.spawn(
      _backupIsolateEntry,
      _BackupIsolateSpawnMessage(
        progressPort: progressPort.sendPort,
        controlPort: controlPort.sendPort,
        cancelCellAddress: cancelToken?.cellAddress,
        payload: payload,
        body: body,
      ),
      errorsAreFatal: true,
      onExit: exitPort.sendPort,
    );
  } catch (error) {
    if (retained && !workerReleased) {
      workerReleased = true;
      cancelToken?.releaseWorker();
    }
    progressPort.close();
    controlPort.close();
    exitPort.close();
    rethrow;
  }

  final done = Completer<R>();
  var killScheduled = false;
  var timedOut = false;
  var sqliteHandleAddress = 0;
  SendPort? workerCommandPort;
  Timer? exitFallback;

  void interruptIfOpen() {
    if (sqliteHandleAddress == 0) return;
    interruptSqliteHandle(sqliteHandleAddress);
  }

  final progressSub = progressPort.listen((message) {
    if (message is! BackupProgress) return;
    if (!message.cancellable) {
      cancelToken?.setCancellable(false);
    }
    onProgress?.call(message);
  });
  final controlSub = controlPort.listen((message) {
    if (message is _BackupIsolateReady) {
      workerCommandPort = message.commandPort;
      return;
    }
    if (message is _BackupSqliteOpened) {
      sqliteHandleAddress = message.address;
      if (killScheduled) {
        interruptIfOpen();
      }
      return;
    }
    if (message is _BackupSqliteClosing) {
      sqliteHandleAddress = 0;
      workerCommandPort?.send(const _BackupSqliteCloseAck());
      return;
    }
    if (done.isCompleted || timedOut) return;
    if (message is _BackupIsolateSuccess) {
      done.complete(message.value as R);
    } else if (message is _BackupIsolateFailure) {
      done.completeError(message.error, message.stackTrace);
    }
  });
  final exitSub = exitPort.listen((_) {
    markIsolateExited();
    if (done.isCompleted) return;
    if (timedOut) {
      done.completeError(
        BackupIsolateTimeoutException(
          isolateExited: true,
          isolateExit: isolateExit.future,
          duration: timeout,
        ),
      );
      return;
    }
    if (killScheduled) {
      done.completeError(
        BackupCancelledException(isolateExit: isolateExit.future),
      );
      return;
    }
    exitFallback = Timer(const Duration(milliseconds: 20), () {
      if (!done.isCompleted) {
        done.completeError(StateError('backup_isolate_exited'));
      }
    });
  });

  Timer? killTimer;
  Timer? abandonTimer;
  void scheduleKill() {
    interruptIfOpen();
    killScheduled = true;
    killTimer ??= Timer(killGrace, () {
      if (debugSkipBackupIsolateKill) return;
      isolate.kill(priority: Isolate.immediate);
    });
    // 放弃等待那个已经不响应杀掉的线程。
    //
    // 这里必须让 done 有个结果，否则调用方会被一个永远不退出的隔离线程
    // 吊死；而抛出的异常带上 isolateExited 与 isolateExit，让上层据此把
    // 临时目录的删除推迟到线程真正退出之后。
    abandonTimer ??= Timer(killGrace + isolateExitDeadline, () {
      if (done.isCompleted) return;
      if (timedOut) {
        done.completeError(
          BackupIsolateTimeoutException(
            isolateExited: isolateHasExited,
            isolateExit: isolateExit.future,
            duration: timeout,
          ),
        );
        return;
      }
      done.completeError(
        BackupCancelledException(
          isolateExited: isolateHasExited,
          isolateExit: isolateExit.future,
        ),
      );
    });
  }

  Timer? timeoutTimer;
  if (timeout != null) {
    timeoutTimer = Timer(timeout, () {
      timedOut = true;
      cancelToken?.cancel();
      scheduleKill();
    });
  }

  if (cancelToken != null && cancelToken.isCancelled) {
    scheduleKill();
  }
  final cancelSub = cancelToken?.whenCancelled.asStream().listen((_) {
    scheduleKill();
  });

  try {
    return await done.future;
  } finally {
    timeoutTimer?.cancel();
    killTimer?.cancel();
    abandonTimer?.cancel();
    exitFallback?.cancel();
    await cancelSub?.cancel();
    await progressSub.cancel();
    progressPort.close();
    if (isolateHasExited) {
      await controlSub.cancel();
      controlPort.close();
      await exitSub.cancel();
      exitPort.close();
    } else {
      unawaited(
        isolateExit.future.whenComplete(() async {
          await controlSub.cancel();
          controlPort.close();
          await exitSub.cancel();
          exitPort.close();
        }),
      );
    }
  }
}

@pragma('vm:entry-point')
void _backupIsolateEntry(_BackupIsolateSpawnMessage message) async {
  final commandPort = ReceivePort();
  message.controlPort.send(_BackupIsolateReady(commandPort.sendPort));
  Completer<void>? closingAck;
  final commandSub = commandPort.listen((incoming) {
    if (incoming is _BackupSqliteCloseAck) {
      closingAck?.complete();
    }
  });
  final cancelFlag = message.cancelCellAddress == null
      ? IsolateCancelFlag.disabled()
      : IsolateCancelFlag.fromAddress(message.cancelCellAddress!);
  final reporter = _ThrottledProgressReporter(message.progressPort);
  final context = BackupIsolateContext(
    cancelFlag: cancelFlag,
    reportProgress: reporter.report,
    registerSqliteInterruptHandle: (address) {
      message.controlPort.send(_BackupSqliteOpened(address));
    },
    waitForSqliteCloseAck: () async {
      final ack = Completer<void>();
      closingAck = ack;
      message.controlPort.send(const _BackupSqliteClosing());
      await ack.future;
    },
  );
  try {
    final value = await (message.body as dynamic)(context, message.payload);
    reporter.flush();
    message.controlPort.send(_BackupIsolateSuccess(value));
  } catch (error, stackTrace) {
    reporter.flush();
    message.controlPort.send(_BackupIsolateFailure(error, stackTrace));
  } finally {
    await commandSub.cancel();
    commandPort.close();
  }
}

final class _BackupIsolateSpawnMessage {
  const _BackupIsolateSpawnMessage({
    required this.progressPort,
    required this.controlPort,
    required this.cancelCellAddress,
    required this.payload,
    required this.body,
  });

  final SendPort progressPort;
  final SendPort controlPort;
  final int? cancelCellAddress;
  final Object? payload;
  final Function body;
}

final class _BackupIsolateSuccess {
  const _BackupIsolateSuccess(this.value);

  final Object? value;
}

final class _BackupIsolateFailure {
  const _BackupIsolateFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

final class _BackupIsolateReady {
  const _BackupIsolateReady(this.commandPort);

  final SendPort commandPort;
}

final class _BackupSqliteOpened {
  const _BackupSqliteOpened(this.address);

  final int address;
}

final class _BackupSqliteClosing {
  const _BackupSqliteClosing();
}

final class _BackupSqliteCloseAck {
  const _BackupSqliteCloseAck();
}

final class _ThrottledProgressReporter {
  _ThrottledProgressReporter(this._port) {
    _elapsed.start();
  }

  static const _minIntervalMs = 100;

  final SendPort _port;
  final Stopwatch _elapsed = Stopwatch();
  int? _lastEmitMs;
  BackupPhase? _lastPhase;
  int? _lastTotal;
  BackupProgress? _pending;
  var _emittedPhaseFinal = false;

  void report(BackupProgress progress) {
    final nowMs = _elapsed.elapsedMilliseconds;
    final phaseChanged = progress.phase != _lastPhase;
    if (phaseChanged) {
      _emittedPhaseFinal = false;
    }
    final becameIndeterminate = progress.total == null && _lastTotal != null;
    final reachedEnd =
        progress.total != null && progress.processed >= progress.total!;
    final isFinal = reachedEnd && !_emittedPhaseFinal;
    final due = _lastEmitMs == null || nowMs - _lastEmitMs! >= _minIntervalMs;
    if (phaseChanged || isFinal || due || becameIndeterminate) {
      if (reachedEnd) {
        _emittedPhaseFinal = true;
      }
      _emit(progress, nowMs);
    } else {
      _pending = progress;
    }
  }

  void flush() {
    final pending = _pending;
    if (pending != null) {
      _emit(pending, _elapsed.elapsedMilliseconds);
    }
  }

  void _emit(BackupProgress progress, int nowMs) {
    _pending = null;
    _lastEmitMs = nowMs;
    _lastPhase = progress.phase;
    _lastTotal = progress.total;
    _port.send(progress);
  }
}
