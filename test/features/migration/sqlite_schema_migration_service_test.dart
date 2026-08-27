import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/services/migration/migration_chain_state.dart';
import 'package:Kelivo/features/migration/sqlite_schema_migration_service.dart';

import '../../core/database/generated_schema/schema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PackageInfo.setMockInitialValues(
    appName: 'JO-Kelivo',
    packageName: 'com.psyche',
    version: '0.1.9',
    buildNumber: '9',
    buildSignature: '',
    installerStore: '',
  );

  late Directory root;
  late Directory appData;
  late File database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sqlite_migration_service_');
    appData = Directory(p.join(root.path, 'app-data'))..createSync();
    database = File(p.join(appData.path, AppDatabase.databaseFileName));
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(1);
    final raw = sqlite.sqlite3.open(database.path);
    await schema.rawDatabase.backup(raw).drain<void>();
    schema.close();
    final timestamp = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
    raw.execute(
      'ALTER TABLE assistant_group_rows RENAME TO assistant_tag_rows;',
    );
    raw.execute('''
      INSERT INTO assistant_tag_rows (id, sort_order, payload, updated_at)
      VALUES ('tag-1', 0, '{"id":"tag-1","name":"Legacy tag"}', 1);
    ''');
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at) '
      "VALUES ('c1', 'legacy', $timestamp, $timestamp);",
    );
    raw.execute(
      'INSERT INTO message_rows '
      '(id, conversation_id, role, timestamp, message_order) '
      "VALUES ('m1', 'c1', 'user', $timestamp, 0);",
    );
    raw.execute('''
      INSERT INTO assistant_rows (id, sort_order, payload, updated_at)
      VALUES ('a1', 0, '{"name":"legacy"}', 1);
    ''');
    raw.execute('''
      INSERT INTO preference_rows (key, value, updated_at)
      VALUES ('theme_mode', '"dark"', 1);
    ''');
    raw.userVersion = 1;
    raw.close();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('detects linear SQLite without opening the Drift migration', () async {
    final decision = await SqliteSchemaMigrationService.check(appData);

    expect(decision.needsMigration, isTrue);
    expect(decision.schemaVersion, 1);
    final raw = sqlite.sqlite3.open(
      database.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      expect(raw.userVersion, 1);
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE name = 'conversation_rows';",
        ),
        hasLength(1),
      );
    } finally {
      raw.close();
    }
  });

  test('creates and validates the 0.1.8 SQLite export payload', () async {
    final decision = await SqliteSchemaMigrationService.check(appData);
    final service = SqliteSchemaMigrationService(decision);
    final externalRoot = Directory(p.join(root.path, 'external'))..createSync();

    final backup = await service.backupTo(externalRoot);
    expect(
      p.basename(backup.path),
      matches(
        RegExp(
          r'^kelivo_migration_backup_\d{4}-\d{2}-\d{2}T'
          r'\d{2}-\d{2}-\d{2}-\d{6}Z\.zip$',
        ),
      ),
    );
    final input = InputFileStream(backup.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final names = archive.map((entry) => entry.name).toSet();
      expect(names, containsAll({'settings.json', 'database/kelivo.db'}));
      expect(names, contains('manifest.json'));
    } finally {
      input.closeSync();
    }
    final state = await MigrationChainStateStore(appData).read();
    expect(state?.sourceKind, 'linear-sqlite');
    expect(state?.externalBackupSaved, isTrue);
  });

  test(
    'writes the migration backup to the desktop-selected ZIP path',
    () async {
      final decision = await SqliteSchemaMigrationService.check(appData);
      final service = SqliteSchemaMigrationService(decision);
      final selected = File(p.join(root.path, 'external', 'selected.zip'));

      final backup = await service.backupToFile(selected);

      expect(backup.path, selected.path);
      expect(await selected.exists(), isTrue);
      final state = await MigrationChainStateStore(appData).read();
      expect(state?.backupPath, selected.path);
    },
  );

  test(
    'retains a mobile external-backup receipt across service recreation',
    () async {
      final decision = await SqliteSchemaMigrationService.check(appData);
      final service = SqliteSchemaMigrationService(decision);

      await service.recordExternalBackupSaved();

      final restartedService = SqliteSchemaMigrationService(decision);
      expect(await restartedService.hasExternallySavedBackup(), isTrue);
      expect(await restartedService.existingBackupPath(), isNull);
    },
  );

  test(
    'reuses one verified backup after restart and completes the tree migration',
    () async {
      final decision = await SqliteSchemaMigrationService.check(appData);
      final firstService = SqliteSchemaMigrationService(decision);
      final selected = File(p.join(root.path, 'external', 'selected.zip'));

      final backup = await firstService.backupToFile(selected);
      await firstService.dispose();

      final restartedDecision = await SqliteSchemaMigrationService.check(
        appData,
      );
      final restartedService = SqliteSchemaMigrationService(restartedDecision);
      expect(await restartedService.existingBackupPath(), backup.path);

      await restartedService.migrate();
      await restartedService.dispose();

      expect(
        ChatDatabaseRepository.readInstalledSchemaVersion(database),
        AppDatabase.currentSchemaVersion,
      );
      final raw = sqlite.sqlite3.open(
        database.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(
          raw
              .select(
                'SELECT COUNT(*) AS count FROM conversation_rows '
                "WHERE id = 'c1';",
              )
              .single['count'],
          1,
        );
        expect(
          raw
              .select(
                'SELECT COUNT(*) AS count FROM message_rows '
                "WHERE id = 'm1';",
              )
              .single['count'],
          1,
        );
        expect(
          raw
              .select(
                'SELECT COUNT(*) AS count FROM assistant_rows '
                "WHERE id = 'a1';",
              )
              .single['count'],
          1,
        );
        expect(
          raw
              .select(
                'SELECT COUNT(*) AS count FROM assistant_group_rows '
                "WHERE id = 'tag-1';",
              )
              .single['count'],
          1,
        );
        expect(
          raw.select(
            "SELECT name FROM sqlite_master WHERE name = 'assistant_tag_rows';",
          ),
          isEmpty,
        );
        expect(
          raw
              .select(
                'SELECT COUNT(*) AS count FROM conversation_branch_rows '
                "WHERE conversation_id = 'c1';",
              )
              .single['count'],
          1,
        );
        expect(
          raw
              .select(
                'SELECT active_branch_id FROM conversation_tree_state_rows '
                "WHERE conversation_id = 'c1';",
              )
              .single['active_branch_id'],
          'root-c1',
        );
      } finally {
        raw.close();
      }
      expect(await backup.exists(), isTrue);
    },
  );

  test('rejects a backup directory inside live application data', () async {
    final decision = await SqliteSchemaMigrationService.check(appData);
    final service = SqliteSchemaMigrationService(decision);
    final nested = Directory(p.join(appData.path, 'backup'));

    await expectLater(
      service.backupTo(nested),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'migration_backup_must_be_external',
        ),
      ),
    );
  });

  test('does not copy unrelated application files into the export', () async {
    final decision = await SqliteSchemaMigrationService.check(appData);
    final service = SqliteSchemaMigrationService(decision);
    final externalRoot = Directory(p.join(root.path, 'external'))..createSync();
    final backup = await service.backupTo(externalRoot);
    final input = InputFileStream(backup.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      expect(
        archive.map((entry) => entry.name),
        everyElement(isNot('kelivo.db-wal')),
      );
    } finally {
      input.closeSync();
    }
  });

  test('rejects a tampered export before migrating', () async {
    final decision = await SqliteSchemaMigrationService.check(appData);
    final service = SqliteSchemaMigrationService(decision);
    final externalRoot = Directory(p.join(root.path, 'external'))..createSync();
    final backup = await service.backupTo(externalRoot);
    final bytes = await backup.readAsBytes();
    bytes[0] = bytes[0] ^ 0xff;
    await backup.writeAsBytes(bytes, flush: true);

    await expectLater(
      service.migrate(backupPath: backup.path),
      throwsA(anything),
    );
    final raw = sqlite.sqlite3.open(
      database.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      expect(raw.userVersion, 1);
    } finally {
      raw.close();
    }
  });
}
