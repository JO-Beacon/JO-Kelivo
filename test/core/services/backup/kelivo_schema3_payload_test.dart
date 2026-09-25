import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/services/backup/kelivo_schema3_payload.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'generated/upstream_kelivo_schema3/schema_v3.dart' as upstream_v3;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late File databaseFile;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'kelivo_schema3_importer_',
    );
    databaseFile = File('${directory.path}/upstream.sqlite');
    final database = upstream_v3.DatabaseAtV3(NativeDatabase(databaseFile));
    await database.customSelect('SELECT 1;').getSingle();
    await database.close();
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> seedUpstreamDatabase() async {
    final createdAt = DateTime.utc(2026, 9, 22).microsecondsSinceEpoch;
    final raw = sqlite.sqlite3.open(databaseFile.path);
    try {
      raw.execute(
        'INSERT INTO conversation_rows '
        '(id, title, created_at, updated_at, version_selections_json, '
        'extras_json) VALUES '
        "('upstream-conv', 'Upstream', $createdAt, $createdAt, "
        "'{\"upstream-group\":0}', '{\"upstream\":true}');",
      );
      raw.execute(
        'INSERT INTO message_rows '
        '(id, conversation_id, role, timestamp, message_order, group_id, '
        'version, sender_id, extras_json) VALUES '
        "('upstream-user', 'upstream-conv', 'user', $createdAt, 0, NULL, 0, "
        "NULL, '{}'), "
        "('upstream-v0', 'upstream-conv', 'assistant', $createdAt, 1, "
        "'upstream-group', 0, 'assistant-a', '{\"subagent\":false}'), "
        "('upstream-v1', 'upstream-conv', 'assistant', $createdAt, 2, "
        "'upstream-group', 1, 'assistant-b', '{\"subagent\":true}');",
      );
      raw.execute(
        'INSERT INTO message_part_rows '
        '(conversation_id, revision_id, ordinal, kind, payload, created_at, '
        'updated_at) VALUES '
        "('upstream-conv', 'upstream-v0', 0, 'text', "
        "'${jsonEncode({'text': 'selected answer'})}', $createdAt, "
        '$createdAt);',
      );
      raw.execute(
        'INSERT INTO assistant_tag_rows (id, sort_order, payload, updated_at) '
        "VALUES ('tag', 0, '{\"name\":\"Tag\"}', $createdAt);",
      );
      raw.execute(
        'INSERT INTO asset_rows '
        '(id, content_hash, path, byte_size, created_at, last_referenced_at, '
        'extras_json) VALUES '
        "('asset', 'hash', 'upload/asset.png', 1, $createdAt, $createdAt, "
        "'{\"colorSpace\":\"srgb\"}');",
      );
      raw.execute(
        'INSERT INTO tombstone_rows (scope, entity_id, deleted_at, payload) '
        "VALUES ('conversation', 'deleted', $createdAt, '{}');",
      );
    } finally {
      raw.close();
    }
  }

  test('recognizes only the exact upstream schema 3 shape', () async {
    await seedUpstreamDatabase();
    expect(KelivoSchema3Payload.isSchema3Payload(databaseFile), isTrue);

    final raw = sqlite.sqlite3.open(databaseFile.path);
    raw.execute('DROP TABLE tombstone_rows;');
    raw.close();
    expect(KelivoSchema3Payload.isSchema3Payload(databaseFile), isFalse);

    final current = File('${directory.path}/current.sqlite');
    final repository = ChatDatabaseRepository.open(file: current);
    await repository.ensureReady();
    await repository.close();
    expect(KelivoSchema3Payload.isSchema3Payload(current), isFalse);
  });

  test('converts upstream schema 3 into current importer payload', () async {
    await seedUpstreamDatabase();

    await KelivoSchema3Payload.convertToCurrentSchema(databaseFile);

    final installed = ChatDatabaseRepository.inspectInstalledDatabase(
      databaseFile,
      validateContents: true,
    );
    expect(installed.schemaVersion, AppDatabase.currentSchemaVersion);

    final raw = sqlite.sqlite3.open(
      databaseFile.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      expect(raw.userVersion, AppDatabase.currentSchemaVersion);
      final message = raw
          .select(
            'SELECT sender_id, extras_json, updated_at FROM message_rows '
            "WHERE id = 'upstream-v1';",
          )
          .single;
      expect(message['sender_id'], 'assistant-b');
      expect(message['extras_json'], '{"subagent":true}');
      expect(message['updated_at'], isNull);

      expect(
        raw.select('SELECT payload FROM assistant_group_rows WHERE id = ?;', [
          'tag',
        ]).single['payload'],
        '{"name":"Tag"}',
      );
      expect(
        raw.select('SELECT extras_json FROM asset_rows WHERE id = ?;', [
          'asset',
        ]).single['extras_json'],
        '{"colorSpace":"srgb"}',
      );
      expect(
        raw
            .select(
              "SELECT entity_id FROM tombstone_rows WHERE scope = 'conversation';",
            )
            .single['entity_id'],
        'deleted',
      );

      final edges = raw.select(
        'SELECT message_id, parent_message_id FROM message_tree_edge_rows '
        'ORDER BY message_id;',
      );
      expect(edges, hasLength(3));
      expect(edges.first['message_id'], 'upstream-user');
      expect(edges.first['parent_message_id'], isNull);
      expect(edges[1]['message_id'], 'upstream-v0');
      expect(edges[1]['parent_message_id'], 'upstream-user');
      expect(edges[2]['message_id'], 'upstream-v1');
      expect(edges[2]['parent_message_id'], 'upstream-user');
      expect(
        raw
            .select(
              'SELECT tip_message_id FROM conversation_branch_rows '
              "WHERE id = 'legacy-upstream-v1';",
            )
            .single['tip_message_id'],
        'upstream-v1',
      );
    } finally {
      raw.close();
    }
  });
}
