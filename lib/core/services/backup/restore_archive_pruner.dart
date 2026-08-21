import 'dart:io';

import 'package:path/path.dart' as p;

import 'restore_trace_service.dart';
import 'restore_workspace_lock.dart';

/// 在几次成功冷启动后清理 `.kelivo_restore/completed/` 归档，以免每次覆盖
/// 恢复都永久遗留一份旧数据库和资源的完整副本。
///
/// 冷启动计数器位于调用方提供的存储中（main.dart 以应用偏好存储作为其
/// 后端）。计数器仅在成功清理后重置，因此失败的清理会在下次冷启动时重试；
/// 修剪永远不会把异常抛进启动流程。
final class RestoreArchivePruner {
  RestoreArchivePruner({
    required this.appDataDirectory,
    required Future<int> Function() readColdStarts,
    required Future<void> Function(int count) writeColdStarts,
    this.coldStartsThreshold = 3,
    Future<void> Function()? clearArchive,
    // ignore: prefer_initializing_formals
  }) : _readColdStarts = readColdStarts,
       // ignore: prefer_initializing_formals
       _writeColdStarts = writeColdStarts,
       _clearArchive =
           clearArchive ??
           (() => RestoreTraceService(appDataDirectory).clear());

  static const coldStartsKey = 'restore_archive_prune_cold_starts_v1';

  final Directory appDataDirectory;
  final int coldStartsThreshold;
  final Future<int> Function() _readColdStarts;
  final Future<void> Function(int count) _writeColdStarts;
  final Future<void> Function() _clearArchive;

  Future<void> pruneAfterSuccessfulColdStart() async {
    try {
      if (!await _hasArchivedRuns()) {
        if (await _readColdStarts() != 0) await _writeColdStarts(0);
        return;
      }
      final coldStarts = await _readColdStarts() + 1;
      if (coldStarts < coldStartsThreshold) {
        await _writeColdStarts(coldStarts);
        return;
      }
      await _clearArchive();
      await _writeColdStarts(0);
    } catch (_) {
      // 修剪是尽力而为的，绝不能影响启动。
    }
  }

  Future<bool> _hasArchivedRuns() async {
    final completed = Directory(
      p.join(
        appDataDirectory.path,
        RestoreWorkspaceLock.workspaceRootName,
        RestoreWorkspaceLock.completedRunsDirectoryName,
      ),
    );
    if (await FileSystemEntity.type(completed.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    await for (final _ in completed.list(followLinks: false)) {
      return true;
    }
    return false;
  }
}
