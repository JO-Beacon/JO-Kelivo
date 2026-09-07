import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/services/backup/local_snapshot_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('publishes snapshots and prunes older archives', () async {
    final root = await Directory.systemTemp.createTemp('jo_snapshot_store_');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/prepared.zip');
    await source.writeAsBytes(<int>[1, 2, 3], flush: true);
    final store = LocalSnapshotStore(root);

    await store.publish(source, now: DateTime.utc(2026, 1, 1));
    await source.writeAsBytes(<int>[4, 5, 6], flush: true);
    await store.publish(source, now: DateTime.utc(2026, 1, 2));
    await source.writeAsBytes(<int>[7, 8, 9], flush: true);
    await store.publish(source, now: DateTime.utc(2026, 1, 3));

    expect((await store.list()).length, 3);
    await store.prune(2);
    final files = await store.list();
    expect(files.length, 2);
    expect(files.every((file) => file.existsSync()), isTrue);
  });

  test(
    'publishing an empty archive fails and leaves no temporary file',
    () async {
      final root = await Directory.systemTemp.createTemp('jo_snapshot_store_');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/prepared.zip');
      await source.writeAsBytes(const <int>[], flush: true);
      final store = LocalSnapshotStore(root);

      await expectLater(
        store.publish(source, now: DateTime.utc(2026, 1, 1)),
        throwsA(isA<StateError>()),
      );
      expect(await store.list(), isEmpty);
      final snapshotDirectory = Directory('${root.path}/snapshots');
      final leftovers = await snapshotDirectory
          .list()
          .where((entity) => entity.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    },
  );
}
