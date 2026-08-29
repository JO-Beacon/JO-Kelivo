import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/backup_task_progress.dart';
import 'package:Kelivo/core/models/progress_update.dart';
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
    token.dispose();
    expect(token.isCellAllocated, isFalse);
  });

  test('runner forwards progress and completes normally', () async {
    final updates = <ProgressUpdate>[];
    final result = await runBackupIsolate<int, int>(
      body: _reportAndReturn,
      payload: 7,
      onProgress: updates.add,
    );

    expect(result, 7);
    expect(updates.single.fraction, 0.5);
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
  context.reportProgress(const ProgressUpdate(processed: 1, total: 2));
  return value;
}
