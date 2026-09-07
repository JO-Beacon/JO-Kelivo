import 'dart:io';
import '../../models/backup.dart';
import 'backup_activity.dart';
import 'data_sync.dart';
import 'local_snapshot_settings.dart';
import 'local_snapshot_store.dart';

final class LocalSnapshotService {
  LocalSnapshotService({
    required this.appDataDirectory,
    required this.preferences,
    required this.dataSync,
  }) : store = LocalSnapshotStore(appDataDirectory);

  final Directory appDataDirectory;
  final LocalSnapshotPreferences preferences;
  final DataSync dataSync;
  final LocalSnapshotStore store;
  bool running = false;

  Future<File> takeNow() async {
    if (running) throw StateError('local_snapshot_running');
    if (BackupActivity.isActive) throw StateError('local_snapshot_busy');
    running = true;
    BackupActivity.begin();
    File? prepared;
    try {
      final archive = await dataSync.prepareBackupFile(
        const WebDavConfig(includeChats: true, includeFiles: false),
      );
      prepared = archive;
      final published = await store.publish(archive);
      await store.prune(preferences.readSettings().keepRecent);
      await preferences.recordSuccess(DateTime.now());
      return published;
    } catch (error) {
      await preferences.recordFailure(error);
      rethrow;
    } finally {
      if (prepared != null) await DataSync.cleanupTemporaryBackupFile(prepared);
      BackupActivity.end();
      running = false;
    }
  }

  Future<bool> runIfDue({DateTime? now}) async {
    final settings = preferences.readSettings();
    if (!settings.enabled || running || BackupActivity.isActive) return false;
    final last = preferences.lastSuccess;
    final current = (now ?? DateTime.now()).toUtc();
    if (last != null && current.difference(last) < const Duration(days: 1)) {
      return false;
    }
    await takeNow();
    return true;
  }
}
