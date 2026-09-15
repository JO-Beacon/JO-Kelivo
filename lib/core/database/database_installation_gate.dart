import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

import '../services/backup/restore_durability.dart';
import 'app_database.dart';
import 'chat_database_repository.dart';

final class DatabaseInstallationReceipt {
  const DatabaseInstallationReceipt({
    required this.installationId,
    required this.databaseId,
  });

  static const formatVersion = 1;

  final String installationId;
  final String databaseId;

  Map<String, Object> toJson() => {
    'version': formatVersion,
    'installationId': installationId,
    'databaseId': databaseId,
  };

  static DatabaseInstallationReceipt fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        value['version'] != formatVersion ||
        value['installationId'] is! String ||
        value['databaseId'] is! String) {
      throw const FormatException('database_installation_receipt');
    }
    final receipt = DatabaseInstallationReceipt(
      installationId: value['installationId'] as String,
      databaseId: value['databaseId'] as String,
    );
    if (!_isUuid(receipt.installationId) || !_isUuid(receipt.databaseId)) {
      throw const FormatException('database_installation_receipt');
    }
    return receipt;
  }
}

/// 启动准入失败后的恢复路由。只有 [rebuildAutomatically] 可以在无需进一步
/// 用户确认的情况下运行；其他所有路由都必须先经用户确认。
enum DatabaseRecoveryAction {
  none,
  rebuildAutomatically,
  promptRemigration,
  promptUpgrade,
}

/// 被 [DatabaseInstallationGate.rebuildFresh] 改名移开（而非删除）的数据库族。
final class DisplacedDatabaseCopy {
  const DisplacedDatabaseCopy({
    required this.file,
    required this.stamp,
    required this.displacedAt,
    required this.bytes,
  });

  /// 数据库本体；附属文件带各自后缀位于其旁。
  final File file;

  /// 标识这一个世代。按文本排序即时间序。
  final String stamp;

  /// 当时间戳早于现行命名规则、无法解读时为 null。
  final DateTime? displacedAt;

  /// 整个族的总字节数，含附属文件。
  final int bytes;
}

final class DatabaseInstallationGate {
  DatabaseInstallationGate._();

  static const _receiptPrefix = 'database_installation_receipt_';
  static const _receiptSuffix = '.json';
  // 创建临时文件与重命名之间发生崩溃不能阻塞下次启动，因此每次发布都使用
  // 唯一临时名并清理过期文件，而不是复用一个可能被残留文件阻塞的固定名。
  // 前缀有意省略尾部路径分隔符，以便清理也能删除旧的固定名临时文件
  // ('.database_installation_receipt.tmp')。
  static const _temporaryPrefix = '.database_installation_receipt';
  static const _temporarySuffix = '.tmp';
  static const _maximumReceiptBytes = 4096;

  /// 被 [rebuildFresh] 改名保留（而非删除）的数据库族所带的后缀。时间戳使
  /// 各世代互不混淆、且按字典序即时间序；每个附属文件保留自身后缀，整套仍
  /// 可打开，包含尚未做检查点的事务。
  static const displacedDatabasePrefix = '.displaced-';
  static const _maximumDisplacedGenerations = 3;

  /// 数据库本身及 SQLite 可能留在它旁边的全部附属文件。必须与
  /// ChatDatabaseRepository 的族处理保持一致：只搬数据库而丢下日志，会把
  /// 日志留在替代者的旁边。
  static const _databaseFamilySuffixes = <String>[
    '',
    '-wal',
    '-shm',
    '-journal',
  ];

  static Future<DatabaseInstallationReceipt> ensureReady({
    required Directory appDataDirectory,
    bool allowDatabaseIdentityChange = false,
    RestoreDurability? durability,
  }) async {
    final resolvedDurability = durability ?? RestorePlatformDurability();
    await appDataDirectory.create(recursive: true);
    final databaseFile = File(
      p.join(appDataDirectory.path, AppDatabase.databaseFileName),
    );
    final receipts = await _readReceipts(appDataDirectory);
    final databaseType = await FileSystemEntity.type(
      databaseFile.path,
      followLinks: false,
    );
    if (receipts.isNotEmpty && databaseType == FileSystemEntityType.notFound) {
      throw StateError('database_missing');
    }
    if (databaseType != FileSystemEntityType.notFound &&
        databaseType != FileSystemEntityType.file) {
      throw StateError('database_type');
    }

    late InstalledChatDatabaseInfo info;
    try {
      if (databaseType == FileSystemEntityType.notFound) {
        final repository = ChatDatabaseRepository.open(file: databaseFile);
        try {
          await repository.ensureReady();
        } finally {
          await repository.close();
        }
      } else {
        await ChatDatabaseRepository.migrateInstalledDatabase(databaseFile);
      }

      info = ChatDatabaseRepository.inspectInstalledDatabase(databaseFile);
    } on StateError catch (error) {
      // migrateInstalledDatabase 对所有 schema 不匹配都报告相同的
      // 代码；只有较新的 schema 才意味着用户必须更新应用。
      if (error.message == 'database_schema_version') {
        final userVersion = _tryReadUserVersion(databaseFile);
        if (userVersion != null &&
            userVersion > AppDatabase.currentSchemaVersion) {
          throw StateError('database_schema_too_new');
        }
      }
      rethrow;
    }
    if (info.databaseId == null) {
      if (receipts.isNotEmpty) {
        if (!allowDatabaseIdentityChange) {
          throw StateError('database_identity_missing');
        }
      }
      final databaseId = const Uuid().v4();
      ChatDatabaseRepository.assignInstalledDatabaseIdentity(
        databaseFile,
        databaseId,
      );
      info = ChatDatabaseRepository.inspectInstalledDatabase(databaseFile);
    }
    final databaseId = info.databaseId!;
    final matching = receipts
        .where((entry) => entry.receipt.databaseId == databaseId)
        .toList(growable: false);
    if (matching.length > 1) {
      throw StateError('database_installation_receipt_duplicate');
    }
    if (matching.length == 1) {
      await _removeStaleReceipts(
        receipts.where((entry) => entry.file.path != matching.single.file.path),
        durability: resolvedDurability,
      );
      return matching.single.receipt;
    }
    if (receipts.isNotEmpty) {
      if (!allowDatabaseIdentityChange) {
        throw StateError('database_identity_mismatch');
      }
    }
    final installationIds = receipts
        .map((entry) => entry.receipt.installationId)
        .toSet();
    if (installationIds.length > 1) {
      throw StateError('database_installation_identity_mismatch');
    }
    final updated = DatabaseInstallationReceipt(
      installationId: installationIds.firstOrNull ?? const Uuid().v4(),
      databaseId: databaseId,
    );
    final receiptFile = File(
      p.join(
        appDataDirectory.path,
        '$_receiptPrefix${updated.databaseId}$_receiptSuffix',
      ),
    );
    await _publishReceipt(receiptFile, updated, durability: resolvedDurability);
    await _removeStaleReceipts(receipts, durability: resolvedDurability);
    return updated;
  }

  /// 让安装元数据与一次已提交、已验证的还原对齐。
  ///
  /// 必须在归档终态运行之前、持有启动业务／工作区租约时运行。它从不改动
  /// 数据库字节，因此被打断的终态复核仍能把数据库与候选哈希做比较。
  static Future<void> reconcileCommittedRestore({
    required Directory appDataDirectory,
    required RestoreDurability durability,
  }) async {
    final info = ChatDatabaseRepository.inspectInstalledDatabase(
      File(p.join(appDataDirectory.path, AppDatabase.databaseFileName)),
    );
    var receipts = <({File file, DatabaseInstallationReceipt receipt})>[];
    try {
      receipts = await _readReceipts(appDataDirectory);
    } on FormatException {
      // 下面会原样保住这份畸形元数据，而不是信任或删除它。
    }
    if (info.databaseId != null &&
        receipts.length == 1 &&
        receipts.single.receipt.databaseId == info.databaseId) {
      return;
    }
    final files = await appDataDirectory.list(followLinks: false).where((
      entity,
    ) {
      final name = p.basename(entity.path);
      return name.startsWith(_receiptPrefix) && name.endsWith(_receiptSuffix);
    }).toList();
    for (final file in files) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('database_installation_receipt_type');
      }
    }
    if (files.isNotEmpty) {
      final archive = await appDataDirectory.createTemp(
        '.kelivo_installation_receipts_',
      );
      await durability.restrictDirectory(archive);
      await durability.syncDirectory(appDataDirectory, fullBarrier: true);
      for (final file in files) {
        await durability.renameAndSync(
          source: file,
          targetPath: p.join(archive.path, p.basename(file.path)),
        );
      }
    }
    // 旧快照可能没有身份。旧回执已安全移走，因此即便再经历一次冷启动，正常
    // 准入也会补发一个。在这里补发会让尚未归档的终态运行的哈希对不上。
    final databaseId = info.databaseId;
    if (databaseId == null) return;
    final installationIds = receipts
        .map((entry) => entry.receipt.installationId)
        .toSet();
    final receipt = DatabaseInstallationReceipt(
      installationId: installationIds.length == 1
          ? installationIds.single
          : const Uuid().v4(),
      databaseId: databaseId,
    );
    await _publishReceipt(
      File(
        p.join(
          appDataDirectory.path,
          '$_receiptPrefix$databaseId$_receiptSuffix',
        ),
      ),
      receipt,
      durability: durability,
    );
  }

  /// 将启动准入失败映射到最安全有效的恢复路径。
  ///
  /// 仅当不存在安装回执、不存在旧版 Hive 源，且已安装文件处于半创建
  /// （userVersion 0）或不可读状态时，才会返回自动重建，因此不会丢失任何
  /// 可达数据。
  static Future<DatabaseRecoveryAction> recoveryActionFor({
    required Directory appDataDirectory,
    required Object error,
    required bool legacyHiveDataPresent,
  }) async {
    if (error is StateError && error.message == 'database_schema_too_new') {
      return DatabaseRecoveryAction.promptUpgrade;
    }
    final isSchemaOrCorrupt =
        error is StateError &&
        (error.message == 'database_schema_version' ||
            error.message == 'database_corrupt');
    final isRawSqliteFailure = error is sqlite.SqliteException;
    if (!isSchemaOrCorrupt && !isRawSqliteFailure) {
      return DatabaseRecoveryAction.none;
    }
    // 存在但无法解析的回执仍然证明之前安装过，
    // 因此它必须像有效回执一样阻止自动重建。
    final bool hasReceipts;
    try {
      hasReceipts = (await _readReceipts(appDataDirectory)).isNotEmpty;
    } catch (_) {
      return DatabaseRecoveryAction.none;
    }
    if (hasReceipts) return DatabaseRecoveryAction.none;
    if (legacyHiveDataPresent) {
      return DatabaseRecoveryAction.promptRemigration;
    }
    if (isRawSqliteFailure) {
      // 原始 sqlite 错误绝不能成为自动删除数据的理由。
      return DatabaseRecoveryAction.none;
    }
    final databaseFile = File(
      p.join(appDataDirectory.path, AppDatabase.databaseFileName),
    );
    if (await FileSystemEntity.type(databaseFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return DatabaseRecoveryAction.none;
    }
    final userVersion = _tryReadUserVersion(databaseFile);
    if (userVersion == null || userVersion == 0) {
      return DatabaseRecoveryAction.rebuildAutomatically;
    }
    return DatabaseRecoveryAction.none;
  }

  /// 移开已安装的数据库族并重复首次启动设置。仅在 [recoveryActionFor]
  /// 返回 [DatabaseRecoveryAction.rebuildAutomatically] 时安全。
  ///
  /// [preserveDisplacedCopy] 为真时把旧族改名保留而非删除：一次事后发现判断
  /// 错误的重建仍可挽回，也留下了说明问题所需的现场。无人值守的重建必须保留
  /// 副本；用户已确认的重置不能保留——对话框承诺数据已经没了。最多保留
  /// [_maximumDisplacedGenerations] 份，最旧的一份先丢弃。
  static Future<DatabaseInstallationReceipt> rebuildFresh({
    required Directory appDataDirectory,
    RestoreDurability? durability,
    bool preserveDisplacedCopy = true,
  }) async {
    final resolvedDurability = durability ?? RestorePlatformDurability();
    await appDataDirectory.create(recursive: true);
    final databaseFile = File(
      p.join(appDataDirectory.path, AppDatabase.databaseFileName),
    );
    if (preserveDisplacedCopy) {
      await _displaceDatabaseFamily(
        databaseFile,
        durability: resolvedDurability,
      );
    } else {
      for (final suffix in _databaseFamilySuffixes) {
        final target = File('${databaseFile.path}$suffix');
        if (await FileSystemEntity.type(target.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await target.delete();
        }
      }
      await _pruneDisplacedGenerations(
        appDataDirectory,
        keep: 0,
        durability: resolvedDurability,
      );
    }
    await resolvedDurability.syncDirectory(appDataDirectory, fullBarrier: true);
    return ensureReady(
      appDataDirectory: appDataDirectory,
      durability: resolvedDurability,
    );
  }

  /// 在安装一份已验证的快照之前，先保住读不出来的现行文件。调用方必须持有
  /// 业务／工作区租约，并且已经有一份持久化的还原候选。与自动重建不同，这里
  /// 从不剪枝现场。
  static Future<void> preserveFailedDatabaseForRestore({
    required Directory appDataDirectory,
    required RestoreDurability durability,
  }) async {
    await _displaceDatabaseFamily(
      File(p.join(appDataDirectory.path, AppDatabase.databaseFileName)),
      durability: durability,
      prune: false,
    );
  }

  /// [appDataDirectory] 中是否存在任何被移开的数据库副本。
  static Future<bool> hasDisplacedDatabases({
    required Directory appDataDirectory,
  }) async {
    final prefix = '${AppDatabase.databaseFileName}$displacedDatabasePrefix';
    try {
      await for (final entity in appDataDirectory.list(followLinks: false)) {
        if (p.basename(entity.path).startsWith(prefix)) return true;
      }
    } catch (_) {}
    return false;
  }

  /// 被 [rebuildFresh] 移开的数据库族，最新的在前。
  ///
  /// 每一个都是裸 SQLite 族：可能停在更旧的 schema 上，也可能还带着未回放的
  /// 日志，所以这里一律不打开它们。这份清单是给一个「导出或还原它」的界面用
  /// 的，而这两条路都走备份流水线，不直接读取文件本身。
  static Future<List<DisplacedDatabaseCopy>> listDisplacedDatabases({
    required Directory appDataDirectory,
  }) async {
    final prefix = '${AppDatabase.databaseFileName}$displacedDatabasePrefix';
    final bytesByStamp = <String, int>{};
    try {
      await for (final entity in appDataDirectory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(prefix)) continue;
        var stamp = name.substring(prefix.length);
        for (final suffix in _databaseFamilySuffixes) {
          if (suffix.isEmpty) continue;
          if (stamp.endsWith(suffix)) {
            stamp = stamp.substring(0, stamp.length - suffix.length);
            break;
          }
        }
        if (stamp.isEmpty) continue;
        try {
          bytesByStamp[stamp] =
              (bytesByStamp[stamp] ?? 0) + await entity.length();
        } catch (_) {
          bytesByStamp[stamp] ??= 0;
        }
      }
    } catch (_) {
      return const <DisplacedDatabaseCopy>[];
    }

    final copies = <DisplacedDatabaseCopy>[];
    for (final entry in bytesByStamp.entries) {
      final base = File(p.join(appDataDirectory.path, '$prefix${entry.key}'));
      if (await FileSystemEntity.type(base.path, followLinks: false) !=
          FileSystemEntityType.file) {
        // 族还在、但数据库本体不在了：没有东西可以拿来还原，因此不列出。
        continue;
      }
      final micros = int.tryParse(entry.key);
      copies.add(
        DisplacedDatabaseCopy(
          file: base,
          stamp: entry.key,
          displacedAt: micros == null
              ? null
              : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true),
          bytes: entry.value,
        ),
      );
    }
    copies.sort((a, b) => b.stamp.compareTo(a.stamp));
    return copies;
  }

  /// 删除一个被移开的族。有任何残留即抛错。
  static Future<void> deleteDisplacedDatabase({
    required Directory appDataDirectory,
    required String stamp,
  }) async {
    if (stamp.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(stamp)) {
      throw ArgumentError.value(stamp, 'stamp');
    }
    final prefix = '${AppDatabase.databaseFileName}$displacedDatabasePrefix';
    // 先删附属文件，最后删数据库本体。[listDisplacedDatabases] 只列出数据库
    // 本体仍在的族，所以先删本体就会把「随后删除失败的附属文件」藏起来——留下
    // 用户再也够不着的残骸，而 [hasDisplacedDatabases] 仍报告它存在。
    for (final suffix in _databaseFamilySuffixes.reversed) {
      final file = File(p.join(appDataDirectory.path, '$prefix$stamp$suffix'));
      try {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await file.delete();
        }
      } catch (_) {}
    }
    for (final suffix in _databaseFamilySuffixes) {
      final file = File(p.join(appDataDirectory.path, '$prefix$stamp$suffix'));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('displaced_databases_not_cleared');
      }
    }
  }

  /// 删除全部被移开的数据库副本。
  ///
  /// 一份副本可能是用户数据唯一幸存的版本，所以没有任何流程会按自己的节奏调
  /// 用这里——它服务于存储空间页，那里已经告诉用户即将丢弃什么。
  static Future<void> clearDisplacedDatabases({
    required Directory appDataDirectory,
    RestoreDurability? durability,
  }) async {
    await _pruneDisplacedGenerations(
      appDataDirectory,
      keep: 0,
      durability: durability ?? RestorePlatformDurability(),
    );
    // 剪枝会吞掉单个文件的错误，这样日常清理永远不会让一次重建失败。但这里的
    // 调用方是按下删除的用户，所以必须如实报告什么都没做成，而不是给出一个没
    // 达成的成功提示。
    if (await hasDisplacedDatabases(appDataDirectory: appDataDirectory)) {
      throw StateError('displaced_databases_not_cleared');
    }
  }

  /// 把数据库族改名移开。返回新的基准路径；没有可移的文件时返回 null。
  static Future<String?> _displaceDatabaseFamily(
    File databaseFile, {
    required RestoreDurability durability,
    bool prune = true,
  }) async {
    // 补零到固定宽度，使时间戳的字典序即时间序。
    final stamp = DateTime.now()
        .toUtc()
        .microsecondsSinceEpoch
        .toString()
        .padLeft(16, '0');
    final base = '${databaseFile.path}$displacedDatabasePrefix$stamp';
    String? displaced;
    for (final suffix in _databaseFamilySuffixes) {
      final source = File('${databaseFile.path}$suffix');
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      await durability.renameAndSync(
        source: source,
        targetPath: '$base$suffix',
      );
      displaced = base;
    }
    if (prune) {
      await _pruneDisplacedGenerations(
        databaseFile.parent,
        keep: _maximumDisplacedGenerations,
        durability: durability,
      );
    }
    return displaced;
  }

  /// 约束保留的世代数，且永远保住最旧的一份。
  ///
  /// 最旧的世代不可替代：它保存的是任何东西被移开之前磁盘上的状态，而后面的
  /// 世代通常是我们自己产出的状态的副本。若一个反复重试的调用方（例如一直失
  /// 败、每次启动都重新移开的迁移回滚）落在“保留最新”的窗口里，会把用户唯一
  /// 的真实副本挤出去。因此第一份无条件保留，窗口只覆盖最近 keep − 1 份。
  static Future<void> _pruneDisplacedGenerations(
    Directory directory, {
    required int keep,
    required RestoreDurability durability,
  }) async {
    final prefix = '${AppDatabase.databaseFileName}$displacedDatabasePrefix';
    final stamps = <String>{};
    try {
      await for (final entity in directory.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (!name.startsWith(prefix)) continue;
        var stamp = name.substring(prefix.length);
        for (final suffix in _databaseFamilySuffixes) {
          if (suffix.isEmpty) continue;
          if (stamp.endsWith(suffix)) {
            stamp = stamp.substring(0, stamp.length - suffix.length);
            break;
          }
        }
        if (stamp.isNotEmpty) stamps.add(stamp);
      }
    } catch (_) {
      // 剪枝属于清理事务，它的失败绝不能让一次重建失败。
      return;
    }
    if (stamps.length <= keep) return;
    final ordered = stamps.toList()..sort();
    final retained = keep <= 0
        ? const <String>{}
        : <String>{ordered.first, ...ordered.reversed.take(keep - 1)};
    final expiring = ordered.where((stamp) => !retained.contains(stamp));
    var removed = false;
    for (final stamp in expiring) {
      for (final suffix in _databaseFamilySuffixes) {
        final file = File(p.join(directory.path, '$prefix$stamp$suffix'));
        try {
          if (await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file) {
            await file.delete();
            removed = true;
          }
        } catch (_) {}
      }
    }
    if (removed) {
      try {
        await durability.syncDirectory(directory, fullBarrier: true);
      } catch (_) {}
    }
  }

  static int? _tryReadUserVersion(File file) {
    sqlite.Database? database;
    try {
      database = sqlite.sqlite3.open(
        file.absolute.path,
        mode: sqlite.OpenMode.readOnly,
      );
      return database.userVersion;
    } catch (_) {
      return null;
    } finally {
      try {
        database?.close();
      } catch (_) {}
    }
  }

  static Future<DatabaseInstallationReceipt?> read({
    required Directory appDataDirectory,
  }) async {
    final receipts = await _readReceipts(appDataDirectory);
    if (receipts.isEmpty) return null;
    final databaseFile = File(
      p.join(appDataDirectory.path, AppDatabase.databaseFileName),
    );
    if (!await databaseFile.exists()) throw StateError('database_missing');
    final databaseId = ChatDatabaseRepository.inspectInstalledDatabase(
      databaseFile,
    ).databaseId;
    final matching = receipts
        .where((entry) => entry.receipt.databaseId == databaseId)
        .toList(growable: false);
    if (matching.length != 1) {
      throw StateError('database_installation_receipt_match');
    }
    return matching.single.receipt;
  }

  static Future<List<({File file, DatabaseInstallationReceipt receipt})>>
  _readReceipts(Directory directory) async {
    final receipts = <({File file, DatabaseInstallationReceipt receipt})>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!name.startsWith(_receiptPrefix) || !name.endsWith(_receiptSuffix)) {
        continue;
      }
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('database_installation_receipt_type');
      }
      final file = File(entity.path);
      final receipt = await _readReceipt(file);
      if (name != '$_receiptPrefix${receipt.databaseId}$_receiptSuffix') {
        throw const FormatException('database_installation_receipt_name');
      }
      receipts.add((file: file, receipt: receipt));
    }
    return receipts;
  }

  static Future<void> _removeStaleReceipts(
    Iterable<({File file, DatabaseInstallationReceipt receipt})> entries, {
    required RestoreDurability durability,
  }) async {
    Directory? parent;
    for (final entry in entries) {
      await entry.file.delete();
      parent = entry.file.parent;
    }
    if (parent != null) {
      await durability.syncDirectory(parent, fullBarrier: true);
    }
  }

  static Future<DatabaseInstallationReceipt> _readReceipt(File file) async {
    if (await file.length() > _maximumReceiptBytes) {
      throw const FormatException('database_installation_receipt');
    }
    final decoded = jsonDecode(await file.readAsString());
    return DatabaseInstallationReceipt.fromJson(decoded);
  }

  static Future<void> _publishReceipt(
    File target,
    DatabaseInstallationReceipt receipt, {
    required RestoreDurability durability,
  }) async {
    // 删除早前发布崩溃留下的临时文件；它们不携带权威状态（数据库身份才是
    // 事实来源），绝不能阻塞新的发布。
    await _sweepStaleTemporaries(target.parent);
    final temporary = File(
      p.join(
        target.parent.path,
        '${_temporaryPrefix}_${pid}_'
        '${DateTime.now().microsecondsSinceEpoch}$_temporarySuffix',
      ),
    );
    try {
      await temporary.create(exclusive: true);
      await durability.restrictFile(temporary);
      await temporary.writeAsString(jsonEncode(receipt.toJson()), flush: true);
      await durability.syncFile(temporary, fullBarrier: true);
      if (await target.exists()) {
        throw StateError('database_installation_receipt_collision');
      }
      await durability.renameAndSync(
        source: temporary,
        targetPath: target.path,
      );
      final published = await _readReceipt(target);
      if (published.installationId != receipt.installationId ||
          published.databaseId != receipt.databaseId) {
        throw StateError('database_installation_receipt_publish');
      }
    } finally {
      if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await temporary.delete();
        await durability.syncDirectory(target.parent, fullBarrier: true);
      }
    }
  }

  static Future<void> _sweepStaleTemporaries(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!name.startsWith(_temporaryPrefix) ||
          !name.endsWith(_temporarySuffix)) {
        continue;
      }
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
          FileSystemEntityType.file) {
        try {
          await File(entity.path).delete();
        } catch (_) {
          // 尽力而为：无法删除的临时文件仍然不会阻止发布，
          // 因为现在发布使用唯一名称。
        }
      }
    }
  }
}

bool _isUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
).hasMatch(value);
