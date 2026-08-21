import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:Kelivo/core/database/app_database.dart';

import 'generated_schema/schema.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('frozen schema includes and matches current schema 3', () async {
    expect(AppDatabase.currentSchemaVersion, 3);
    expect(GeneratedHelper.versions, const [1, 2, 3]);
    final database = AppDatabase(NativeDatabase.memory());
    try {
      await database.customSelect('SELECT 1;').getSingle();
      await verifier.migrateAndValidate(
        database,
        AppDatabase.currentSchemaVersion,
        options: const ValidationOptions(validateDropped: true),
      );
    } finally {
      await database.close();
    }
  });

  test('schema 3 creates every business and tree persistence table', () async {
    final database = AppDatabase(NativeDatabase.memory());
    try {
      final rows = await database
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table';")
          .get();
      final tables = rows.map((row) => row.read<String>('name')).toSet();

      expect(
        tables,
        containsAll(const {
          'message_tree_edge_rows',
          'conversation_branch_rows',
          'conversation_tree_state_rows',
          'assistant_rows',
          'provider_rows',
          'provider_group_rows',
          'mcp_server_rows',
          'world_book_rows',
          'assistant_memory_rows',
          'quick_phrase_rows',
          'search_service_rows',
          'tts_service_rows',
          'instruction_injection_rows',
          'assistant_tag_rows',
          'preference_rows',
          'memory_entry_rows',
          'user_profile_field_rows',
          'message_prompt_rows',
          'asset_rows',
          'message_asset_rows',
          'asset_gc_rows',
          'gc_audit_rows',
          'asset_reference_dirty_rows',
        }),
      );
    } finally {
      await database.close();
    }
  });

  test('unpublished schema is rejected instead of migrated', () async {
    final directory = await Directory.systemTemp.createTemp(
      'kelivo_too_new_schema_',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File(p.join(directory.path, AppDatabase.databaseFileName));
    final raw = sqlite.sqlite3.open(file.path);
    raw.userVersion = 4;
    raw.close();

    final database = AppDatabase.open(file: file);
    try {
      Object? caught;
      try {
        await database.customSelect('SELECT 1;').getSingle();
      } catch (error) {
        caught = error;
      }
      expect(caught.toString(), contains('database_schema_too_new'));
    } finally {
      await database.close();
    }
  });
}
