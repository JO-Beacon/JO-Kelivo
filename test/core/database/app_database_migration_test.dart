import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/database/database_installation_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'generated_schema/schema.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'installation gate creates and validates only the current schema',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_current_schema_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      await DatabaseInstallationGate.ensureReady(appDataDirectory: directory);

      final file = File(p.join(directory.path, AppDatabase.databaseFileName));
      final installed = ChatDatabaseRepository.inspectInstalledDatabase(file);
      expect(installed.schemaVersion, AppDatabase.currentSchemaVersion);
      expect(installed.databaseId, isNotEmpty);
    },
  );

  test(
    'installation gate rejects every unpublished SQLite schema without mutation',
    () async {
      for (final schemaVersion in <int>[6, 7, 8, 9, 10, 11, 42]) {
        final directory = await Directory.systemTemp.createTemp(
          'kelivo_reject_schema_${schemaVersion}_',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final file = File(p.join(directory.path, AppDatabase.databaseFileName));
        final database = sqlite.sqlite3.open(file.path);
        database.execute('CREATE TABLE intermediate_only (value TEXT);');
        database.userVersion = schemaVersion;
        database.close();

        await expectLater(
          DatabaseInstallationGate.ensureReady(appDataDirectory: directory),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'database_schema_too_new',
            ),
          ),
        );

        final after = sqlite.sqlite3.open(
          file.path,
          mode: sqlite.OpenMode.readOnly,
        );
        try {
          expect(after.userVersion, schemaVersion);
          expect(
            after.select(
              "SELECT name FROM sqlite_master WHERE type='table' AND name=?;",
              ['intermediate_only'],
            ),
            hasLength(1),
          );
        } finally {
          after.close();
        }
      }
    },
  );

  test(
    'installed current schema is rejected when a business table is missing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_missing_business_table_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File(p.join(directory.path, AppDatabase.databaseFileName));
      final database = AppDatabase.open(file: file);
      await database.customSelect('SELECT 1;').getSingle();
      await database.close();

      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE preference_rows;');
      raw.close();

      expect(
        () => ChatDatabaseRepository.inspectInstalledDatabase(file),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'required_tables',
          ),
        ),
      );
    },
  );

  test('schema 3 assistant tags migrate to groups without data loss', () async {
    final directory = await Directory.systemTemp.createTemp(
      'kelivo_assistant_tag_migration_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File(p.join(directory.path, AppDatabase.databaseFileName));
    final database = AppDatabase.open(file: file);
    await database.customSelect('SELECT 1;').getSingle();
    await database.close();

    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(
      'ALTER TABLE assistant_group_rows RENAME TO assistant_tag_rows;',
    );
    raw.execute(
      'INSERT INTO assistant_tag_rows (id, sort_order, payload, updated_at) '
      "VALUES ('legacy-tag', 0, '{\"name\":\"Legacy\"}', 1);",
    );
    raw.userVersion = 3;
    raw.close();

    expect(await ChatDatabaseRepository.migrateInstalledDatabase(file), isTrue);

    final migrated = sqlite.sqlite3.open(
      file.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      expect(migrated.userVersion, AppDatabase.currentSchemaVersion);
      expect(
        migrated.select(
          "SELECT name FROM sqlite_master WHERE name = 'assistant_tag_rows';",
        ),
        isEmpty,
      );
      expect(
        migrated
            .select(
              'SELECT id, sort_order, payload, updated_at '
              'FROM assistant_group_rows;',
            )
            .single,
        containsPair('id', 'legacy-tag'),
      );
    } finally {
      migrated.close();
    }
  });

  test('assistant tag and group table conflict aborts migration', () async {
    final directory = await Directory.systemTemp.createTemp(
      'kelivo_assistant_group_conflict_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File(p.join(directory.path, AppDatabase.databaseFileName));
    final database = AppDatabase.open(file: file);
    await database.customSelect('SELECT 1;').getSingle();
    await database.close();

    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(
      'CREATE TABLE assistant_tag_rows ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'sort_order INTEGER NOT NULL CHECK(sort_order >= 0), '
      'payload TEXT NOT NULL, updated_at INTEGER NOT NULL);',
    );
    raw.userVersion = 3;
    raw.close();

    await expectLater(
      ChatDatabaseRepository.migrateInstalledDatabase(file),
      throwsA(
        predicate<Object>(
          (error) =>
              error.toString().contains('assistant_group_table_conflict'),
          'keeps the assistant table conflict diagnostic',
        ),
      ),
    );

    final unchanged = sqlite.sqlite3.open(
      file.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      expect(unchanged.userVersion, 3);
      expect(
        unchanged
            .select(
              "SELECT name FROM sqlite_master WHERE name IN "
              "('assistant_tag_rows', 'assistant_group_rows');",
            )
            .map((row) => row['name']),
        containsAll({'assistant_tag_rows', 'assistant_group_rows'}),
      );
    } finally {
      unchanged.close();
    }
  });

  test(
    'schema 5 adds prompt source hashes and clears legacy prompt cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'kelivo_prompt_cache_migration_',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final file = File(p.join(directory.path, AppDatabase.databaseFileName));
      final database = AppDatabase.open(file: file);
      await database.customSelect('SELECT 1;').getSingle();
      await database.close();

      final raw = sqlite.sqlite3.open(file.path);
      final now = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
      raw.execute(
        'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
        "VALUES ('prompt-conversation', 'prompt', $now, $now);",
      );
      raw.execute(
        'INSERT INTO message_rows '
        '(id, conversation_id, role, timestamp, message_order) VALUES '
        "('prompt-message', 'prompt-conversation', 'user', $now, 0);",
      );
      raw.execute(
        'INSERT INTO message_prompt_rows '
        '(revision_id, conversation_id, payload, carries_memory_snapshot, '
        'created_at) VALUES '
        "('prompt-message', 'prompt-conversation', 'stale', 0, $now);",
      );
      raw.userVersion = 4;
      raw.close();

      expect(
        await ChatDatabaseRepository.migrateInstalledDatabase(file),
        isTrue,
      );

      final migrated = sqlite.sqlite3.open(
        file.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(migrated.userVersion, 5);
        expect(
          migrated.select('PRAGMA table_info(message_prompt_rows);'),
          anyElement(containsPair('name', 'source_content_hash')),
        );
        expect(migrated.select('SELECT * FROM message_prompt_rows;'), isEmpty);
      } finally {
        migrated.close();
      }
    },
  );

  test(
    'schema 1 linear conversations migrate into populated tree tables',
    () async {
      final verifier = SchemaVerifier(GeneratedHelper());
      final schema = await verifier.schemaAt(1);
      addTearDown(schema.close);

      final raw = schema.rawDatabase;
      final createdAt = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
      raw.execute(
        'INSERT INTO conversation_rows (id, title, created_at, updated_at) '
        "VALUES ('conversation-1', 'linear', $createdAt, $createdAt);",
      );
      raw.execute(
        'INSERT INTO message_rows '
        '(id, conversation_id, role, timestamp, message_order) VALUES '
        "('message-1', 'conversation-1', 'user', $createdAt, 0),"
        "('message-2', 'conversation-1', 'assistant', $createdAt, 1),"
        "('message-3', 'conversation-1', 'user', $createdAt, 2);",
      );

      final database = AppDatabase(schema.newConnection());
      try {
        await verifier.migrateAndValidate(
          database,
          AppDatabase.currentSchemaVersion,
          options: const ValidationOptions(validateDropped: true),
        );
      } finally {
        await database.close();
      }

      final branches = raw.select(
        'SELECT id, conversation_id, tip_message_id FROM '
        'conversation_branch_rows WHERE conversation_id = ?;',
        ['conversation-1'],
      );
      expect(branches, hasLength(1));
      expect(branches.single['id'], 'root-conversation-1');
      expect(branches.single['tip_message_id'], 'message-3');

      final edges = raw.select(
        'SELECT message_id, parent_message_id FROM message_tree_edge_rows '
        'WHERE conversation_id = ? ORDER BY message_id;',
        ['conversation-1'],
      );
      expect(edges, hasLength(3));
      expect(edges[0]['message_id'], 'message-1');
      expect(edges[0]['parent_message_id'], null);
      expect(edges[1]['message_id'], 'message-2');
      expect(edges[1]['parent_message_id'], 'message-1');
      expect(edges[2]['message_id'], 'message-3');
      expect(edges[2]['parent_message_id'], 'message-2');

      final state = raw.select(
        'SELECT active_branch_id FROM conversation_tree_state_rows '
        'WHERE conversation_id = ?;',
        ['conversation-1'],
      );
      expect(state.single['active_branch_id'], 'root-conversation-1');
      expect(
        raw
            .select('SELECT COUNT(*) AS count FROM message_rows;')
            .single['count'],
        3,
      );
    },
  );

  test('schema 1 version groups migrate into visible sibling branches', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(1);
    addTearDown(schema.close);

    final raw = schema.rawDatabase;
    final createdAt = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, version_selections_json) VALUES '
      "('conversation-branch', 'branch', $createdAt, $createdAt, "
      '\'{"assistant-group":1}\');',
    );
    raw.execute(
      'INSERT INTO message_rows '
      '(id, conversation_id, role, timestamp, message_order, group_id, version) '
      'VALUES '
      "('u1', 'conversation-branch', 'user', $createdAt, 0, NULL, 0),"
      "('a1-v0', 'conversation-branch', 'assistant', $createdAt, 1, "
      "'assistant-group', 0),"
      "('a1-v1', 'conversation-branch', 'assistant', $createdAt, 2, "
      "'assistant-group', 1),"
      "('u2', 'conversation-branch', 'user', $createdAt, 3, NULL, 0);",
    );

    final database = AppDatabase(schema.newConnection());
    try {
      await verifier.migrateAndValidate(
        database,
        AppDatabase.currentSchemaVersion,
        options: const ValidationOptions(validateDropped: true),
      );
    } finally {
      await database.close();
    }

    final branches = raw.select(
      'SELECT id, tip_message_id FROM conversation_branch_rows '
      'WHERE conversation_id = ? ORDER BY id;',
      ['conversation-branch'],
    );
    expect(branches, hasLength(2));
    expect(branches[0]['id'], 'legacy-a1-v0');
    expect(branches[0]['tip_message_id'], 'a1-v0');
    expect(branches[1]['id'], 'root-conversation-branch');
    expect(branches[1]['tip_message_id'], 'u2');

    final edges = raw.select(
      'SELECT message_id, parent_message_id FROM message_tree_edge_rows '
      'WHERE conversation_id = ? ORDER BY message_id;',
      ['conversation-branch'],
    );
    expect(edges, hasLength(4));
    expect(edges[0]['message_id'], 'a1-v0');
    expect(edges[0]['parent_message_id'], 'u1');
    expect(edges[1]['message_id'], 'a1-v1');
    expect(edges[1]['parent_message_id'], 'u1');
    expect(edges[2]['message_id'], 'u1');
    expect(edges[2]['parent_message_id'], null);
    expect(edges[3]['message_id'], 'u2');
    expect(edges[3]['parent_message_id'], 'a1-v1');

    final state = raw.select(
      'SELECT active_branch_id FROM conversation_tree_state_rows '
      'WHERE conversation_id = ?;',
      ['conversation-branch'],
    );
    expect(state.single['active_branch_id'], 'root-conversation-branch');
  });

  test('missing legacy version selection is repaired and reported', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(1);
    addTearDown(schema.close);

    final raw = schema.rawDatabase;
    final createdAt = DateTime.utc(2026, 1, 1).microsecondsSinceEpoch;
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, version_selections_json) VALUES '
      "('conversation-warning', 'warning', $createdAt, $createdAt, '{}');",
    );
    raw.execute(
      'INSERT INTO message_rows '
      '(id, conversation_id, role, timestamp, message_order, group_id, version) '
      'VALUES '
      "('u1', 'conversation-warning', 'user', $createdAt, 0, NULL, 0),"
      "('a1-v0', 'conversation-warning', 'assistant', $createdAt, 1, "
      "'assistant-group', 0),"
      "('a1-v1', 'conversation-warning', 'assistant', $createdAt, 2, "
      "'assistant-group', 1),"
      "('u2', 'conversation-warning', 'user', $createdAt, 3, NULL, 0);",
    );

    final database = AppDatabase(schema.newConnection());
    try {
      await verifier.migrateAndValidate(
        database,
        AppDatabase.currentSchemaVersion,
        options: const ValidationOptions(validateDropped: true),
      );
    } finally {
      await database.close();
    }

    final conversation = raw.select(
      'SELECT version_selections_json FROM conversation_rows WHERE id = ?;',
      ['conversation-warning'],
    ).single;
    expect(jsonDecode(conversation['version_selections_json'] as String), {
      'assistant-group': 1,
    });

    final warningRows = raw.select(
      'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
      [AppDatabase.contextTreeMigrationWarningsKey],
    );
    expect(warningRows, hasLength(1));
    final warnings = jsonDecode(warningRows.single['value'] as String);
    expect(warnings, isA<List<dynamic>>());
    expect(warnings, hasLength(1));
    expect(
      (warnings as List<dynamic>).single,
      containsPair('conversationId', 'conversation-warning'),
    );
    expect(warnings.single, containsPair('groupId', 'assistant-group'));
    expect(warnings.single, containsPair('fallbackVersion', 1));
  });
}
