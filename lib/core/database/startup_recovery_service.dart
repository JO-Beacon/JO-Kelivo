import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../services/backup/restore_durability.dart';
import '../services/backup/restore_business_lease.dart';
import '../services/backup/restore_workspace_lock.dart';
import 'app_database.dart';
import 'database_installation_gate.dart';

/// 用户为预初始化失败屏幕发起的恢复操作。
///
/// 这些方法在任何应用服务存在之前运行，因此每个操作都只工作在文件层面。
/// 它们的存在是为了保证失败关闭的启动永远不会变成永久锁死：用户总能挽救一份
/// 数据副本、修复可恢复的元数据损坏，或者（作为最后手段）重置。
final class StartupRecoveryService {
  StartupRecoveryService._();

  // 绝不能阻塞启动验证的惰性操作系统元数据文件。
  static const _junkFileNames = <String>{
    '.DS_Store',
    'Thumbs.db',
    'desktop.ini',
    '.localized',
  };

  static const _receiptPrefix = 'database_installation_receipt_';
  static const _receiptSuffix = '.json';
  static const _temporaryPrefix = '.database_installation_receipt';
  static const _temporarySuffix = '.tmp';
  static const _restoreWorkspaceName = '.kelivo_restore';

  /// 将整个应用数据目录复制到 [destinationParent] 下带时间戳的文件夹，
  /// 以便用户在尝试任何修复或重置之前抢救其数据。
  /// 返回创建的目录。非破坏性操作。
  static Future<Directory> exportDataCopy({
    required Directory appDataDirectory,
    required Directory destinationParent,
    DateTime Function()? clock,
  }) async {
    if (!await appDataDirectory.exists()) {
      throw StateError('startup_recovery_source_missing');
    }
    // 目标位于数据目录内会导致复制递归到自身（列出源时目标会出现）。
    final sourcePath = p.normalize(appDataDirectory.absolute.path);
    final destinationPath = p.normalize(destinationParent.absolute.path);
    if (destinationPath == sourcePath ||
        p.isWithin(sourcePath, destinationPath)) {
      throw StateError('startup_recovery_export_inside_source');
    }
    await destinationParent.create(recursive: true);
    final stamp = (clock?.call() ?? DateTime.now())
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final target = Directory(
      p.join(destinationParent.path, 'kelivo-data-$stamp'),
    );
    if (await target.exists()) {
      throw StateError('startup_recovery_export_collision');
    }
    await target.create(recursive: true);
    await _copyDirectory(appDataDirectory, target);
    return target;
  }

  /// 修复会导致启动关闭且没有真实数据丢失的可恢复元数据损坏：残留的发布临时文件、
  /// 恢复工作区中的惰性 OS 垃圾文件，以及无法解析的安装回执。随后重新运行准入流程，
  /// 采用当前数据库的身份，让损坏或被替换的回执依据权威的磁盘数据库重写。
  ///
  /// 当数据库本身缺失或损坏时会重新抛出：这些情况无法
  /// 在文件层面修复，调用方应改为提供重置选项。
  static Future<void> repair({
    required Directory appDataDirectory,
    RestoreDurability? durability,
  }) async {
    if (!await appDataDirectory.exists()) {
      throw StateError('startup_recovery_source_missing');
    }
    await _sweepReceiptTemporaries(appDataDirectory);
    await _sweepRestoreWorkspaceJunk(appDataDirectory);
    await _deleteUnparseableReceipts(appDataDirectory);
    // 采用该身份后，因无法解析而被删除或内容不匹配的回执，可以从当前活动数据库重写；
    // 用户选择修复即隐式信任磁盘上的数据库。
    await DatabaseInstallationGate.ensureReady(
      appDataDirectory: appDataDirectory,
      allowDatabaseIdentityChange: true,
      durability: durability,
    );
  }

  /// 删除已安装的数据库族和安装回执，并重新运行首次启动设置。破坏性操作：当前数据库会丢失；
  /// 调用方必须与用户确认，并应优先提供 [exportDataCopy]。
  static Future<void> reset({
    required Directory appDataDirectory,
    RestoreBusinessLease? businessLease,
    RestoreDurability? durability,
  }) async {
    final resolvedDurability = durability ?? RestorePlatformDurability();
    final ownedLease = businessLease == null
        ? await RestoreBusinessLease.acquire(
            appDataDirectory: appDataDirectory,
            durability: resolvedDurability,
          )
        : null;
    final lease = businessLease ?? ownedLease!;
    try {
      final expectedLeasePath = p.join(
        appDataDirectory.absolute.path,
        RestoreBusinessLease.leaseDirectoryName,
        RestoreBusinessLease.lockFileName,
      );
      if (lease.isClosed ||
          !p.equals(lease.lockFile.absolute.path, expectedLeasePath)) {
        throw StateError('restore_startup_business_lease');
      }
      final workspaceLock = RestoreWorkspaceLock(
        appDataDirectory: appDataDirectory,
        durability: resolvedDurability,
      );
      await workspaceLock.synchronized(() async {
        // 一次重置会取代整次被打断的还原。把它的现场移到准入之外，这样已发布的
        // 候选就无法在下次启动时替换掉刚建立的数据库。在数据库与安装回执双双
        // 落盘之前，准入始终保持阻断。
        await workspaceLock.beginSnapshotRecoveryWhileLocked();
        // 先移除安装回执（以及所有临时文件）：rebuildFresh 只会重建数据库族，
        // 而准入会拒绝数据库已被重建的回执。清除这些回执后，
        // 新身份才能干净地签发。
        await _sweepReceiptTemporaries(appDataDirectory);
        await for (final entity in appDataDirectory.list(followLinks: false)) {
          final name = p.basename(entity.path);
          if (name.startsWith(_receiptPrefix) &&
              name.endsWith(_receiptSuffix)) {
            await _deleteFileIfPresent(entity.path);
          }
        }
        await DatabaseInstallationGate.rebuildFresh(
          appDataDirectory: appDataDirectory,
          durability: resolvedDurability,
          // 确认对话框承诺数据已经永久消失：这是唯一不能留下副本的调用方。
          preserveDisplacedCopy: false,
        );
        await workspaceLock.finishSnapshotRecoveryWhileLocked();
      });
    } finally {
      await ownedLease?.close();
    }
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await for (final entity in source.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final destinationPath = p.join(target.path, name);
      if (entity is Directory) {
        final childTarget = Directory(destinationPath);
        await childTarget.create(recursive: true);
        await _copyDirectory(entity, childTarget);
      } else if (entity is File) {
        await entity.copy(destinationPath);
      }
      // 链接和其他特殊实体会被有意跳过。
    }
  }

  static Future<void> _sweepReceiptTemporaries(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith(_temporaryPrefix) &&
          name.endsWith(_temporarySuffix)) {
        await _deleteFileIfPresent(entity.path);
      }
    }
  }

  static Future<void> _sweepRestoreWorkspaceJunk(Directory directory) async {
    final workspace = Directory(p.join(directory.path, _restoreWorkspaceName));
    if (!await workspace.exists()) return;
    await for (final entity in workspace.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && _junkFileNames.contains(p.basename(entity.path))) {
        await _deleteFileIfPresent(entity.path);
      }
    }
  }

  static Future<void> _deleteUnparseableReceipts(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!name.startsWith(_receiptPrefix) || !name.endsWith(_receiptSuffix)) {
        continue;
      }
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final file = File(entity.path);
      var valid = false;
      try {
        DatabaseInstallationReceipt.fromJson(
          jsonDecode(await file.readAsString()),
        );
        valid = true;
      } catch (_) {
        valid = false;
      }
      if (!valid) {
        await _deleteFileIfPresent(entity.path);
      }
    }
  }

  static Future<void> _deleteFileIfPresent(String path) async {
    try {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file) {
        await File(path).delete();
      }
    } catch (_) {
      // 尽力而为：无法删除的垃圾/临时文件不会阻止准入检查，
      // 因为准入检查使用唯一临时名称并采用数据库身份。
    }
  }

  /// 已安装数据库文件名，暴露出来是为了让失败页面能够提示重置会移除哪些内容。
  static String get databaseFileName => AppDatabase.databaseFileName;
}

/// 把启动失败的报告落盘、并把整份数据打成归档供移动端分享出去。
///
/// 报告存在数据目录下的 `logs/`，用的是 `.txt` 后缀，这样应用下次正常启动
/// 后，内置的日志查看器就能把它列出来——用户不必去翻文件管理器。
final class StartupDiagnosticsService {
  StartupDiagnosticsService._();

  static const _logDirectoryName = 'logs';
  static const _reportPrefix = 'startup_failure_';
  static const _reportSuffix = '.txt';

  /// 保留多少份失败报告。够把一次重复失败和第一次对照着看，
  /// 又少到永远不会影响磁盘占用。
  static const retainedReports = 5;

  /// 把 [text] 存下来，让这次失败能活过紧随其后的重启，之后可以从内置
  /// 日志查看器或文件管理器里读到。
  ///
  /// 有意做成尽力而为：写不出报告绝不能把一次本来就在失败的启动弄得更糟，
  /// 所以调用方拿到的是 null，而不是异常。
  static Future<File?> writeFailureReport({
    required Directory appDataDirectory,
    required String text,
    DateTime Function()? clock,
  }) async {
    try {
      final directory = Directory(
        p.join(appDataDirectory.path, _logDirectoryName),
      );
      await directory.create(recursive: true);
      final stamp = (clock?.call() ?? DateTime.now())
          .toUtc()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final file = File(
        p.join(directory.path, '$_reportPrefix$stamp$_reportSuffix'),
      );
      await file.writeAsString(text, flush: true);
      await _pruneReports(directory);
      return file;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _pruneReports(Directory directory) async {
    try {
      final reports = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith(_reportPrefix) && name.endsWith(_reportSuffix)) {
          reports.add(entity);
        }
      }
      if (reports.length <= retainedReports) return;
      reports.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final stale in reports.take(reports.length - retainedReports)) {
        try {
          await stale.delete();
        } catch (_) {
          // 删不掉的报告无害，只是占一点磁盘。
        }
      }
    } catch (_) {
      // 清理属于杂务，绝不能因此丢掉刚写好的那份报告。
    }
  }

  /// 把整个应用数据目录压成一个归档，返回该文件；移动端拿不到"目标文件夹"
  /// 这类输入，只能靠分享面板把东西交出去。
  ///
  /// [workingDirectory] 必须位于 [appDataDirectory] 之外，否则归档会试图
  /// 把自己装进去。
  static Future<File> createDataArchive({
    required Directory appDataDirectory,
    required Directory workingDirectory,
    DateTime Function()? clock,
  }) async {
    if (!await appDataDirectory.exists()) {
      throw StateError('startup_recovery_source_missing');
    }
    final sourcePath = p.normalize(appDataDirectory.absolute.path);
    final workingPath = p.normalize(workingDirectory.absolute.path);
    if (workingPath == sourcePath || p.isWithin(sourcePath, workingPath)) {
      throw StateError('startup_recovery_export_inside_source');
    }
    await workingDirectory.create(recursive: true);
    final stamp = (clock?.call() ?? DateTime.now())
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final archive = File(
      p.join(workingDirectory.path, 'kelivo-data-$stamp.zip'),
    );
    if (await archive.exists()) {
      throw StateError('startup_recovery_export_collision');
    }
    final encoder = ZipFileEncoder();
    await encoder.zipDirectory(
      appDataDirectory,
      filename: archive.path,
      followLinks: false,
    );
    return archive;
  }

  /// 用 SQLite 自带的检查跑一遍已安装的数据库。
  ///
  /// 这是唯一一个贵到必须由用户主动触发的探针：两个 pragma 都会全文件扫描。
  /// 它回答的是这个页面本来无法回答的问题——数据本身完好、问题出在准入逻辑里，
  /// 还是文件真的坏了。
  static Future<StartupIntegrityResult> checkIntegrity({
    required Directory appDataDirectory,
  }) async {
    final file = File(
      p.join(appDataDirectory.path, AppDatabase.databaseFileName),
    );
    if (!await file.exists()) {
      return const StartupIntegrityResult(
        databasePresent: false,
        quickCheck: null,
        foreignKeyViolations: null,
      );
    }
    final database = sqlite.sqlite3.open(
      file.absolute.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      final quickCheck = database
          .select('PRAGMA quick_check;')
          .map((row) => row.values.first?.toString() ?? '')
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
      final foreignKeys = database.select('PRAGMA foreign_key_check;').length;
      return StartupIntegrityResult(
        databasePresent: true,
        quickCheck: quickCheck,
        foreignKeyViolations: foreignKeys,
      );
    } finally {
      database.close();
    }
  }
}

/// [StartupDiagnosticsService.checkIntegrity] 的结果。
final class StartupIntegrityResult {
  const StartupIntegrityResult({
    required this.databasePresent,
    required this.quickCheck,
    required this.foreignKeyViolations,
  });

  final bool databasePresent;

  /// SQLite `quick_check` 的输出；只有一条 `ok` 表示没查出损坏。
  final List<String>? quickCheck;
  final int? foreignKeyViolations;

  bool get isHealthy =>
      databasePresent &&
      quickCheck != null &&
      quickCheck!.length == 1 &&
      quickCheck!.single == 'ok' &&
      foreignKeyViolations == 0;

  String describe() {
    if (!databasePresent) return 'database file missing';
    final checks = quickCheck ?? const <String>[];
    final buffer = StringBuffer()
      ..write(
        'quick_check: ${checks.isEmpty ? 'no output' : checks.join('; ')}',
      )
      ..write(
        ' · foreign_key_check: ${foreignKeyViolations ?? '?'} violation(s)',
      );
    return buffer.toString();
  }
}
