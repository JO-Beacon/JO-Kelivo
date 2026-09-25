import 'package:drift/drift.dart' hide isNull;

import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/app_database.dart';

import 'generated_schema/schema.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('schema 8 migrates to schema 9 additively and preserves rows', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(8);
    addTearDown(schema.close);

    final raw = schema.rawDatabase;
    final createdAt = DateTime.utc(2026, 9, 23).microsecondsSinceEpoch;
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, version_selections_json) VALUES '
      "('schema9-conv', 'Schema 9', $createdAt, $createdAt, '{}');",
    );
    raw.execute(
      'INSERT INTO message_rows '
      '(id, conversation_id, role, timestamp, message_order) VALUES '
      "('schema9-msg', 'schema9-conv', 'user', $createdAt, 0);",
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

    expect(raw.userVersion, 9);
    final messageColumns = raw
        .select('PRAGMA table_info(message_rows);')
        .map((row) => row['name'] as String)
        .toList();
    expect(messageColumns.sublist(messageColumns.length - 3), [
      'updated_at',
      'sender_id',
      'extras_json',
    ]);
    final message = raw
        .select(
          'SELECT updated_at, sender_id, extras_json FROM message_rows '
          "WHERE id = 'schema9-msg';",
        )
        .single;
    expect(message['updated_at'], isNull);
    expect(message['sender_id'], isNull);
    expect(message['extras_json'], '{}');

    final assetColumns = raw
        .select('PRAGMA table_info(asset_rows);')
        .map((row) => row['name'] as String)
        .toList();
    expect(assetColumns.last, 'extras_json');

    final tombstones = raw.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='tombstone_rows';",
    );
    expect(tombstones, hasLength(1));
  });
}
