import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:Kelivo/core/services/backup/restore_lease_lock.dart';

void main() {
  group('RestoreLeaseLock', () {
    late Directory root;
    late File lockFile;

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'kelivo_restore_lease_lock_test_',
      );
      lockFile = File(p.join(root.path, 'lease.lock'));
      await lockFile.create();
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'reacquires after a previous isolate left its descriptor open',
      () async {
        final leakedPath = lockFile.path;
        await Isolate.run(() async {
          final leaked = await RestoreLeaseLock.tryAcquire(File(leakedPath));
          return leaked != null;
        });

        final lock = await RestoreLeaseLock.tryAcquire(lockFile);
        expect(lock, isNotNull);
        await lock!.release();
      },
      skip: Platform.isWindows
          ? 'Windows file locks are handle-scoped, unlike the POSIX lock used by this restart case.'
          : false,
    );

    test('release is idempotent and allows reacquire', () async {
      final held = await RestoreLeaseLock.tryAcquire(lockFile);
      expect(held, isNotNull);
      await held!.release();
      await held.release();

      final reacquired = await RestoreLeaseLock.tryAcquire(lockFile);
      expect(reacquired, isNotNull);
      await reacquired!.release();
    });
  });
}
