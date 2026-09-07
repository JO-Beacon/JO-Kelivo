import 'dart:io';
import 'package:path/path.dart' as p;

final class LocalSnapshotStore {
  LocalSnapshotStore(this.appDataDirectory);
  final Directory appDataDirectory;
  Directory get directory =>
      Directory(p.join(appDataDirectory.path, 'snapshots'));

  Future<void> _ensure() async => directory.create(recursive: true);

  Future<List<File>> list() async {
    if (!await directory.exists()) return const <File>[];
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name.startsWith('kelivo-snapshot-') &&
          name.endsWith('.zip')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<File> publish(File archive, {DateTime? now}) async {
    await _ensure();
    await sweepIncomplete();
    final stamp = (now ?? DateTime.now()).toUtc().microsecondsSinceEpoch;
    final target = File(p.join(directory.path, 'kelivo-snapshot-$stamp.zip'));
    final temporary = File('${target.path}.tmp');
    try {
      if (await temporary.exists()) await temporary.delete();
      await archive.copy(temporary.path);
      if (await temporary.length() <= 0) {
        throw StateError('local_snapshot_empty');
      }
      await temporary.rename(target.path);
      return target;
    } catch (_) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// 清理由中断发布留下的临时文件，不触碰已发布的快照。
  Future<void> sweepIncomplete() async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.zip.tmp')) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> prune(int keepRecent) async {
    final files = await list();
    for (final file in files.skip(keepRecent.clamp(1, 10))) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
