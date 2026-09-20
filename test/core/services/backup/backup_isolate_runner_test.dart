import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/backup/backup_cancel_token.dart';
import 'package:Kelivo/core/services/backup/backup_task_progress.dart';
import 'package:Kelivo/core/services/backup/backup_isolate_runner.dart';

void main() {
  test('worker can observe a shared cancellation flag', () async {
    final token = BackupCancelToken();
    final worker = runBackupIsolate<int, int>(
      body: _pollUntilCancelled,
      payload: 100,
      cancelToken: token,
    );

    await Future<void>.delayed(const Duration(milliseconds: 30));
    token.cancel();

    await expectLater(worker, throwsA(isA<BackupCancelledException>()));
    // 取消标记必须活到隔离线程真正退出为止。
    //
    // 这里不能再断言"future 一完成单元格就释放"：那个保证来自旧实现的
    // "无限等线程退出"。现在线程可能杀不掉（卡在本地调用里）而 future 已
    // 经带错返回，此时隔离线程仍会去读这块共享内存——提前释放就是释放后
    // 使用。单元格改由线程退出时释放，所以这里等它释放。
    token.dispose();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (token.isCellAllocated && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(token.isCellAllocated, isFalse);
  });

  test('runner forwards progress and completes normally', () async {
    final updates = <BackupProgress>[];
    final result = await runBackupIsolate<int, int>(
      body: _reportAndReturn,
      payload: 7,
      onProgress: updates.add,
    );

    expect(result, 7);
    expect(updates.single.fraction, 0.5);
  });

  test('取消一个杀不掉的线程时，调用方按时拿到错误而不是被吊死', () async {
    final token = BackupCancelToken();
    addTearDown(token.dispose);
    final started = DateTime.now();
    final worker = runBackupIsolate<int, int>(
      body: _ignoreCancellationThenFinish,
      payload: 1,
      cancelToken: token,
      killGrace: const Duration(milliseconds: 40),
      isolateExitDeadline: const Duration(milliseconds: 60),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    try {
      // 跳过 Isolate.kill，模拟卡在本地调用里、杀不掉的线程。
      debugSkipBackupIsolateKill = true;
      token.cancel();
      await expectLater(
        worker,
        throwsA(
          isA<BackupCancelledException>().having(
            (error) => error.isolateExited,
            'isolateExited',
            isFalse,
          ),
        ),
      );
    } finally {
      debugSkipBackupIsolateKill = false;
    }

    // 线程还要 800ms 才自己结束，说明我们没等它——这正是这段代码的全部意义：
    // 旧实现会在这里一直等下去，调用方（备份界面）就永远停在"正在取消"。
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(milliseconds: 600)),
    );
  });
}

Future<int> _pollUntilCancelled(BackupIsolateContext context, int limit) async {
  for (var index = 0; index < limit; index++) {
    context.throwIfCancelled();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return limit;
}

int _reportAndReturn(BackupIsolateContext context, int value) {
  context.reportProgress(
    const BackupProgress(phase: BackupPhase.packing, processed: 1, total: 2),
  );
  return value;
}

/// 不响应取消（不调用 [BackupIsolateContext.throwIfCancelled]），
/// 模拟卡在一个既不理会信号、也不理会取消的本地调用里；但它最终会自己
/// 结束，免得给测试进程留下一个永不退出的隔离线程。
Future<int> _ignoreCancellationThenFinish(
  BackupIsolateContext context,
  int value,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 800));
  return value;
}
