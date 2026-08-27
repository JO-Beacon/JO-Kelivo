import 'dart:convert';
import 'dart:io';

import 'dart:async';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../core/database/app_database.dart';
import '../../core/database/business_data.dart';
import '../../core/database/business_settings_router.dart';
import '../../core/database/chat_database_repository.dart';
import '../../core/services/backup/backup_settings_validator.dart';
import '../../core/services/backup/data_sync.dart';
import '../../core/services/migration/migration_chain_state.dart';
import 'hive_to_sqlite_migration_service.dart';

final class SqliteSchemaMigrationDecision {
  const SqliteSchemaMigrationDecision({
    required this.needsMigration,
    required this.appDataDirectory,
    required this.databaseFile,
    required this.schemaVersion,
  });

  final bool needsMigration;
  final Directory appDataDirectory;
  final File databaseFile;
  final int schemaVersion;
}

final class SqliteSchemaMigrationService implements MigrationWorkflow {
  SqliteSchemaMigrationService(this.decision);

  final SqliteSchemaMigrationDecision decision;

  @override
  Directory get appDataDirectory => decision.appDataDirectory;

  final _statusController =
      StreamController<HiveToSqliteMigrationStatus>.broadcast();
  final _log = <String>[];
  HiveToSqliteMigrationStatus? _lastStatus;
  ChatDatabaseSnapshotInfo? _snapshotInfo;

  @override
  Stream<HiveToSqliteMigrationStatus> get statusStream =>
      _statusController.stream;

  @override
  HiveToSqliteMigrationStatus initialStatus() {
    return const HiveToSqliteMigrationStatus(
      stage: HiveToSqliteMigrationStage.intro,
      progress: 0,
      title: 'intro',
      detail: 'waiting',
    );
  }

  @override
  bool get canOfferSkip => false;

  @override
  Future<int> loadAttemptState() async => 0;

  void _emit(
    HiveToSqliteMigrationStage stage,
    double progress,
    String detail, {
    String? backupPath,
    String? error,
    int conversations = 0,
    int messages = 0,
  }) {
    final status = HiveToSqliteMigrationStatus(
      stage: stage,
      progress: progress.clamp(0, 1).toDouble(),
      title: stage.name,
      detail: detail,
      backupPath: backupPath,
      error: error,
      log: List<String>.of(_log),
      conversations: conversations,
      messages: messages,
    );
    _lastStatus = status;
    _statusController.add(status);
  }

  void _logLine(Object error) {
    _log.add('$error');
    if (_log.length > 100) _log.removeAt(0);
  }

  static Future<SqliteSchemaMigrationDecision> check(
    Directory appDataDirectory,
  ) async {
    final databaseFile = File(
      p.join(appDataDirectory.path, AppDatabase.databaseFileName),
    );
    if (!await databaseFile.exists()) {
      return SqliteSchemaMigrationDecision(
        needsMigration: false,
        appDataDirectory: appDataDirectory,
        databaseFile: databaseFile,
        schemaVersion: AppDatabase.currentSchemaVersion,
      );
    }
    final schemaVersion = _readUserVersion(databaseFile);
    return SqliteSchemaMigrationDecision(
      needsMigration:
          schemaVersion >= 1 &&
          schemaVersion < AppDatabase.currentSchemaVersion,
      appDataDirectory: appDataDirectory,
      databaseFile: databaseFile,
      schemaVersion: schemaVersion,
    );
  }

  /// 创建与 0.1.8+8 兼容的 ZIP 数据包，由 0.1.6 迁移流程
  /// 负责外部位置和迁移链回执。
  @override
  Future<File> backupTo(Directory selectedDirectory) async {
    try {
      final target = await _createBackup(selectedDirectory);
      await _writeBackupState(target);
      return target;
    } catch (error) {
      _reportFailure(error);
      rethrow;
    }
  }

  @override
  Future<File> backupToFile(File selectedFile) async {
    File? generated;
    try {
      generated = await _createBackup(selectedFile.parent);
      if (p.normalize(generated.path) != p.normalize(selectedFile.path)) {
        if (await selectedFile.exists()) await selectedFile.delete();
        final renamed = await generated.rename(selectedFile.path);
        await _writeBackupState(renamed);
        return renamed;
      }
      await _writeBackupState(generated);
      return generated;
    } catch (error) {
      if (generated != null && await generated.exists()) {
        await generated.delete();
      }
      _reportFailure(error);
      rethrow;
    }
  }

  @override
  Future<File> backupToTemporaryFile() async {
    try {
      return await _createBackup(Directory.systemTemp);
    } catch (error) {
      _reportFailure(error);
      rethrow;
    }
  }

  Future<File> _createBackup(Directory selectedDirectory) async {
    _emit(HiveToSqliteMigrationStage.backingUp, 0.02, 'snapshot');
    final sourceRoot = await _resolveExistingDirectory(
      decision.appDataDirectory,
    );
    final targetRoot = await _resolveExistingDirectory(selectedDirectory);
    if (p.equals(sourceRoot, targetRoot) ||
        p.isWithin(sourceRoot, targetRoot)) {
      throw StateError('migration_backup_must_be_external');
    }

    final workDir = await Directory.systemTemp.createTemp(
      'jo_kelivo_sqlite_migration_',
    );
    final snapshot = File(p.join(workDir.path, 'kelivo.db'));
    File? backup;
    try {
      final snapshotInfo = await _createLinearSnapshot(
        decision.databaseFile,
        snapshot,
      );
      _snapshotInfo = snapshotInfo;
      final settings = await _exportBusinessSettings(snapshot);
      _emit(
        HiveToSqliteMigrationStage.backingUp,
        0.18,
        'package',
        conversations: snapshotInfo.conversationCount,
        messages: snapshotInfo.messageCount,
      );
      backup = await DataSync.prepareMigrationBackupFile(
        outputDirectory: selectedDirectory,
        snapshotDatabase: snapshot,
        snapshotInfo: snapshotInfo,
        settingsJson: settings.settingsJson,
        businessEntityRowIds: settings.entityRowIds,
        uploadDirectory: Directory(
          p.join(decision.appDataDirectory.path, 'upload'),
        ),
        avatarsDirectory: Directory(
          p.join(decision.appDataDirectory.path, 'avatars'),
        ),
        imagesDirectory: Directory(
          p.join(decision.appDataDirectory.path, 'images'),
        ),
        fontsDirectory: Directory(
          p.join(decision.appDataDirectory.path, 'fonts'),
        ),
      );
      _emit(
        HiveToSqliteMigrationStage.backingUp,
        0.78,
        'validate',
        backupPath: backup.path,
        conversations: snapshotInfo.conversationCount,
        messages: snapshotInfo.messageCount,
      );
      await _validateStoredBackup(backup);
      _emit(
        HiveToSqliteMigrationStage.backupReady,
        1,
        'done',
        backupPath: backup.path,
        conversations: snapshotInfo.conversationCount,
        messages: snapshotInfo.messageCount,
      );
      return backup;
    } catch (_) {
      if (backup != null && await backup.exists()) await backup.delete();
      rethrow;
    } finally {
      if (await workDir.exists()) await workDir.delete(recursive: true);
    }
  }

  Future<void> _writeBackupState(File backup) {
    return MigrationChainStateStore(decision.appDataDirectory).write(
      MigrationChainState(
        sourceKind: 'linear-sqlite',
        backupPath: backup.path,
        stage: 'backup-verified',
        externalBackupSaved: true,
      ),
    );
  }

  @override
  Future<void> migrate({String? backupPath}) async {
    try {
      await _migrate(backupPath: backupPath);
    } catch (error) {
      _reportFailure(error);
      rethrow;
    }
  }

  Future<void> _migrate({String? backupPath}) async {
    final chainStore = MigrationChainStateStore(decision.appDataDirectory);
    final chain = await chainStore.read();
    final isLinearBackup = chain?.sourceKind == 'linear-sqlite';
    final effectiveBackupPath =
        backupPath ?? (isLinearBackup ? chain?.backupPath : null);
    if (effectiveBackupPath != null) {
      final backup = File(effectiveBackupPath);
      if (!await backup.exists()) {
        throw StateError('migration_backup_missing');
      }
      await _validateStoredBackup(backup);
    } else if (!isLinearBackup || chain?.externalBackupSaved != true) {
      // 系统文档保存器在临时副本删除后会持有移动端备份，
      // 因此不能期望它一定具有本地路径。
      throw StateError('migration_backup_missing');
    }
    _emit(
      HiveToSqliteMigrationStage.migrating,
      0.05,
      'schema',
      backupPath: effectiveBackupPath,
      conversations: _snapshotInfo?.conversationCount ?? 0,
      messages: _snapshotInfo?.messageCount ?? 0,
    );
    await chainStore.write(
      MigrationChainState(
        sourceKind: 'linear-sqlite',
        backupPath: effectiveBackupPath,
        stage: 'backup-verified',
        externalBackupSaved: true,
      ),
    );
    await ChatDatabaseRepository.migrateInstalledDatabase(
      decision.databaseFile,
    );
    _emit(
      HiveToSqliteMigrationStage.migrating,
      0.8,
      'validate',
      backupPath: effectiveBackupPath,
      conversations: _snapshotInfo?.conversationCount ?? 0,
      messages: _snapshotInfo?.messageCount ?? 0,
    );
    ChatDatabaseRepository.inspectInstalledDatabase(
      decision.databaseFile,
      validateContents: true,
    );
    _emit(
      HiveToSqliteMigrationStage.complete,
      1,
      'done',
      backupPath: effectiveBackupPath,
      conversations: _snapshotInfo?.conversationCount ?? 0,
      messages: _snapshotInfo?.messageCount ?? 0,
    );
  }

  @override
  Future<String?> existingBackupPath() async {
    final state = await MigrationChainStateStore(
      decision.appDataDirectory,
    ).read();
    if (state?.sourceKind != 'linear-sqlite' || state?.backupPath == null) {
      return null;
    }
    final file = File(state!.backupPath!);
    return await file.exists() ? file.path : null;
  }

  @override
  Future<bool> hasExternallySavedBackup() async {
    final state = await MigrationChainStateStore(
      decision.appDataDirectory,
    ).read();
    return state?.sourceKind == 'linear-sqlite' &&
        state?.externalBackupSaved == true;
  }

  @override
  Future<void> recordExternalBackupSaved() async {
    final store = MigrationChainStateStore(decision.appDataDirectory);
    final previous = await store.read();
    await store.write(
      MigrationChainState(
        sourceKind: 'linear-sqlite',
        backupPath: previous?.sourceKind == 'linear-sqlite'
            ? previous?.backupPath
            : null,
        stage: 'backup-verified',
        externalBackupSaved: true,
      ),
    );
  }

  @override
  Future<void> recordFailedAttempt() async {}

  @override
  Future<void> skipMigrationAndStartFresh() async {
    throw UnsupportedError('sqlite_migration_skip');
  }

  @override
  Future<void> dispose() => _statusController.close();

  void _reportFailure(Object error) {
    _logLine(error);
    _emit(
      HiveToSqliteMigrationStage.failed,
      _lastStatus?.progress ?? 0,
      'failed',
      backupPath: _lastStatus?.backupPath,
      error: '$error',
      conversations: _snapshotInfo?.conversationCount ?? 0,
      messages: _snapshotInfo?.messageCount ?? 0,
    );
  }

  static Future<ChatDatabaseSnapshotInfo> _createLinearSnapshot(
    File sourceFile,
    File destinationFile,
  ) async {
    if (!await sourceFile.exists()) {
      throw StateError('migration_database_missing');
    }
    await destinationFile.parent.create(recursive: true);
    final source = sqlite.sqlite3.open(
      sourceFile.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      if (source.userVersion != 1) {
        throw StateError('migration_database_schema_version');
      }
      source.execute('PRAGMA query_only = ON;');
      final destination = sqlite.sqlite3.open(destinationFile.path);
      try {
        await source.backup(destination, nPage: 2048).drain<void>();
        final info = _validateLinearSnapshot(destination);
        destination.execute('PRAGMA wal_checkpoint(TRUNCATE);');
        destination.select('PRAGMA journal_mode = DELETE;');
        return info;
      } finally {
        destination.close();
      }
    } finally {
      source.close();
    }
  }

  static ChatDatabaseSnapshotInfo _validateLinearSnapshot(
    sqlite.Database database,
  ) {
    final integrity = database.select('PRAGMA integrity_check;');
    if (integrity.length != 1 || integrity.single.values.single != 'ok') {
      throw StateError('migration_database_integrity');
    }
    if (database.select('PRAGMA foreign_key_check;').isNotEmpty) {
      throw StateError('migration_database_foreign_key');
    }
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table';")
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();
    if (!tables.contains('conversation_rows') ||
        !tables.contains('message_rows')) {
      throw StateError('migration_database_tables');
    }
    return (
      schemaVersion: database.userVersion,
      conversationCount: _tableCount(database, 'conversation_rows'),
      messageCount: _tableCount(database, 'message_rows'),
    );
  }

  static int _tableCount(sqlite.Database database, String table) =>
      (database.select('SELECT COUNT(*) AS count FROM $table;').single['count']
          as int);

  static Future<({String settingsJson, Map<String, List<String>> entityRowIds})>
  _exportBusinessSettings(File snapshotFile) async {
    final database = sqlite.sqlite3.open(
      snapshotFile.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      final entities = <BusinessEntityKind, List<BusinessEntityValue>>{};
      final tables = database
          .select("SELECT name FROM sqlite_master WHERE type = 'table';")
          .map((row) => row['name'])
          .whereType<String>()
          .toSet();
      for (final kind in BusinessEntityKind.values) {
        final tableName =
            kind == BusinessEntityKind.assistantGroup &&
                !tables.contains(kind.tableName) &&
                tables.contains('assistant_tag_rows')
            ? 'assistant_tag_rows'
            : kind.tableName;
        if (!tables.contains(tableName)) {
          entities[kind] = const <BusinessEntityValue>[];
          continue;
        }
        final isMemory = kind == BusinessEntityKind.assistantMemory;
        final rows = database.select(
          'SELECT ${kind.idColumn} AS entity_id, sort_order, payload'
          '${isMemory ? ', assistant_id' : ''} FROM $tableName '
          'ORDER BY sort_order, ${kind.idColumn};',
        );
        entities[kind] = [
          for (final row in rows)
            BusinessEntityValue(
              id: row['entity_id'] as String,
              sortOrder: row['sort_order'] as int,
              payload: row['payload'] as String,
              assistantId: isMemory ? row['assistant_id'] as String : null,
            ),
        ];
      }
      final preferences = <String, Object>{};
      if (tables.contains('preference_rows')) {
        for (final row in database.select(
          'SELECT key, value FROM preference_rows ORDER BY key;',
        )) {
          final key = row['key'] as String;
          final value = jsonDecode(row['value'] as String);
          if (value == null ||
              !(value is bool ||
                  value is int ||
                  value is double ||
                  value is String ||
                  (value is List && value.every((item) => item is String)))) {
            throw StateError('migration_business_preference:$key');
          }
          preferences[key] = value;
        }
      }
      final exported = BusinessSettingsRouter.exportSnapshotWithRowIds(
        BusinessSnapshot(entities: entities, preferences: preferences),
      );
      final settings = Map<String, Object>.from(exported.settings)
        ..removeWhere((key, _) => BackupSettingsValidator.shouldIgnore(key));
      BackupSettingsValidator.retainCloudAsrForExport(settings);
      return (
        settingsJson: jsonEncode(settings),
        entityRowIds: exported.entityRowIds,
      );
    } finally {
      database.close();
    }
  }

  static Future<void> _validateStoredBackup(File backup) async {
    final temp = await Directory.systemTemp.createTemp(
      'jo_kelivo_backup_verify_',
    );
    final input = InputFileStream(backup.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final entries = <String, ArchiveFile>{};
      for (final entry in archive) {
        if (!entry.isFile || entries.containsKey(entry.name)) {
          if (entry.isFile) throw StateError('migration_backup_entries');
          continue;
        }
        entries[entry.name] = entry;
      }
      final manifestEntry = entries['manifest.json'];
      final settingsEntry = entries['settings.json'];
      final databaseEntry = entries['database/kelivo.db'];
      if (manifestEntry == null ||
          settingsEntry == null ||
          databaseEntry == null) {
        throw StateError('migration_backup_manifest');
      }
      final manifestBytes = manifestEntry.readBytes();
      if (manifestBytes == null) {
        throw StateError('migration_backup_manifest');
      }
      final manifestFile = File(p.join(temp.path, 'manifest.json'))
        ..writeAsBytesSync(manifestBytes, flush: true);
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
      if (manifest['format'] != 'kelivo-backup' ||
          manifest['formatVersion'] != 2 ||
          manifest['payloadKind'] != 'sqlite' ||
          manifest['includeChats'] != true) {
        throw StateError('migration_backup_manifest');
      }
      final rawEntries = manifest['entries'];
      if (rawEntries is! Map) {
        throw StateError('migration_backup_manifest_entries');
      }
      final declared = <String, ({int bytes, String sha256})>{};
      for (final rawEntry in rawEntries.entries) {
        final name = rawEntry.key;
        final metadata = rawEntry.value;
        if (name is! String ||
            metadata is! Map ||
            metadata['bytes'] is! int ||
            metadata['sha256'] is! String ||
            !_isSafeArchivePath(name)) {
          throw StateError('migration_backup_manifest_entries');
        }
        declared[name] = (
          bytes: metadata['bytes'] as int,
          sha256: metadata['sha256'] as String,
        );
      }
      if (declared.length != entries.length - 1 ||
          !declared.keys.every(entries.containsKey) ||
          entries.keys.any(
            (name) => name != 'manifest.json' && !declared.containsKey(name),
          )) {
        throw StateError('migration_backup_manifest_entries');
      }
      for (final entry in declared.entries) {
        final output = File(
          p.joinAll([temp.path, ...p.posix.split(entry.key)]),
        );
        await output.parent.create(recursive: true);
        final stream = OutputFileStream(output.path);
        try {
          entries[entry.key]!.writeContent(stream);
        } finally {
          stream.closeSync();
        }
        if (await output.length() != entry.value.bytes ||
            (await sha256.bind(output.openRead()).first).toString() !=
                entry.value.sha256) {
          throw StateError('migration_backup_entry_hash:${entry.key}');
        }
      }
      final dbFile = File(p.join(temp.path, 'database', 'kelivo.db'));
      final database = sqlite.sqlite3.open(dbFile.path);
      try {
        final info = _validateLinearSnapshot(database);
        final metadata = manifest['database'];
        if (metadata is! Map ||
            metadata['schemaVersion'] != info.schemaVersion ||
            metadata['conversationCount'] != info.conversationCount ||
            metadata['messageCount'] != info.messageCount) {
          throw StateError('migration_backup_database_metadata');
        }
      } finally {
        database.close();
      }
    } finally {
      input.closeSync();
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  static bool _isSafeArchivePath(String value) {
    return value.isNotEmpty &&
        !value.contains('\\') &&
        !p.posix.isAbsolute(value) &&
        p.posix.normalize(value) == value &&
        !p.posix.split(value).contains('..');
  }

  static int _readUserVersion(File file) {
    return ChatDatabaseRepository.readInstalledSchemaVersion(file);
  }

  static Future<String> _resolveExistingDirectory(Directory directory) async {
    var unresolved = p.normalize(directory.absolute.path);
    final suffix = <String>[];
    while (await FileSystemEntity.type(unresolved, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(unresolved);
      if (parent == unresolved) break;
      suffix.insert(0, p.basename(unresolved));
      unresolved = parent;
    }
    final resolved = await Directory(unresolved).resolveSymbolicLinks();
    return p.normalize(p.joinAll([resolved, ...suffix]));
  }
}
