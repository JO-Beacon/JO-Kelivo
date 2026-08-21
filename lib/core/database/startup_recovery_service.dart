import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/backup/restore_durability.dart';
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
    RestoreDurability? durability,
  }) async {
    // 先移除安装回执（以及所有临时文件）：rebuildFresh 只会重建数据库族，
    // 而准入会拒绝数据库已被重建的回执。清除这些回执后，
    // 新身份才能干净地签发。
    await _sweepReceiptTemporaries(appDataDirectory);
    await for (final entity in appDataDirectory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith(_receiptPrefix) && name.endsWith(_receiptSuffix)) {
        await _deleteFileIfPresent(entity.path);
      }
    }
    await DatabaseInstallationGate.rebuildFresh(
      appDataDirectory: appDataDirectory,
      durability: durability,
    );
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
