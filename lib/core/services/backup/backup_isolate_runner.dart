import 'dart:async';
import 'dart:isolate';

import '../../database/sqlite_interrupt.dart';
import '../../models/backup_task_progress.dart';
import '../../models/progress_update.dart';

typedef BackupIsolateBody<R, P> =
    FutureOr<R> Function(BackupIsolateContext context, P payload);

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
  Duration killGrace = const Duration(milliseconds: 250),
  Duration? timeout,
}) async {
  final progressPort = ReceivePort();
  final controlPort = ReceivePort();
  final exitPort = ReceivePort();
  final exitCompleter = Completer<void>();
  var exited = false;
  var workerRetained = false;

  void markExited() {
    exited = true;
    if (!exitCompleter.isCompleted) exitCompleter.complete();
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
  Timer? timeoutTimer;
  SendPort? commandPort;

  void interruptSqlite() {
    if (sqliteHandle != 0) interruptSqliteHandle(sqliteHandle);
  }

  void scheduleKill() {
    interruptSqlite();
    killTimer ??= Timer(killGrace, () {
      if (!exited) isolate.kill(priority: Isolate.immediate);
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
    markExited();
    if (result.isCompleted) return;
    if (timeoutRequested) {
      result.completeError(TimeoutException('backup_isolate_timeout', timeout));
    } else if (cancellationRequested) {
      result.completeError(const BackupCancelledException());
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
  } catch (error) {
    if (error is BackupCancelledException || error is TimeoutException) {
      if (!cancellationRequested && error is BackupCancelledException) {
        requestCancellation();
      }
      if (!exited) await exitCompleter.future;
    }
    rethrow;
  } finally {
    timeoutTimer?.cancel();
    killTimer?.cancel();
    await progressSub.cancel();
    progressPort.close();
    if (exited) {
      await controlSub.cancel();
      await exitSub.cancel();
      controlPort.close();
      exitPort.close();
    } else {
      unawaited(
        exitCompleter.future.whenComplete(() async {
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
