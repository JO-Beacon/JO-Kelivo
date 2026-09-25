import 'dart:io';

import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// 上游 Kelivo schema 3 SQLite 载荷的显式导入适配器。
///
/// 这个类不参与 JO-AIClient 安装库的版本迁移链。它只在“从 Kelivo 导入”
/// 的临时解包目录中工作：先验证上游 schema 3 的完整结构，再生成一份
/// JO-AIClient schema 9 临时数据库，交给现有导入／合并流程继续处理。
final class KelivoSchema3Payload {
  KelivoSchema3Payload._();

  static const _sourceAlias = 'upstream_kelivo_schema3';

  static const _sourceTables = <String, List<String>>{
    'conversation_rows': [
      'id',
      'title',
      'created_at',
      'updated_at',
      'is_pinned',
      'assistant_id',
      'truncate_index',
      'version_selections_json',
      'summary',
      'last_summarized_message_count',
      'chat_suggestions_json',
      'injected_memory_hash',
      'last_memory_extracted_order',
      'chat_model_provider',
      'chat_model_id',
      'extras_json',
    ],
    'message_rows': [
      'id',
      'conversation_id',
      'role',
      'timestamp',
      'model_id',
      'provider_id',
      'total_tokens',
      'is_streaming',
      'reasoning_start_at',
      'reasoning_finished_at',
      'translation',
      'reasoning_segments_json',
      'group_id',
      'version',
      'prompt_tokens',
      'completion_tokens',
      'cached_tokens',
      'duration_ms',
      'message_order',
      'updated_at',
      'sender_id',
      'extras_json',
    ],
    'conversation_mcp_server_rows': ['conversation_id', 'server_id', 'ordinal'],
    'chat_storage_meta_rows': ['key', 'value'],
    'message_part_rows': [
      'part_id',
      'conversation_id',
      'revision_id',
      'ordinal',
      'kind',
      'payload',
      'created_at',
      'updated_at',
    ],
    'provider_artifact_rows': [
      'conversation_id',
      'revision_id',
      'kind',
      'payload',
      'created_at',
      'updated_at',
    ],
    'asset_rows': [
      'id',
      'content_hash',
      'path',
      'byte_size',
      'width',
      'height',
      'thumbnail_path',
      'created_at',
      'last_referenced_at',
      'extras_json',
    ],
    'message_asset_rows': [
      'conversation_id',
      'revision_id',
      'asset_id',
      'kind',
    ],
    'asset_gc_rows': ['asset_id', 'not_before', 'attempts', 'generation'],
    'gc_audit_rows': ['id', 'kind', 'entity_id', 'completed_at'],
    'asset_reference_dirty_rows': ['revision_id'],
    'generation_run_rows': [
      'id',
      'conversation_id',
      'target_revision_id',
      'state',
      'state_revision',
      'checkpoint_seq',
      'error_code',
      'created_at',
      'updated_at',
      'terminal_at',
    ],
    'assistant_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'provider_rows': ['provider_key', 'sort_order', 'payload', 'updated_at'],
    'provider_group_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'mcp_server_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'world_book_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'assistant_memory_rows': [
      'id',
      'sort_order',
      'assistant_id',
      'payload',
      'updated_at',
    ],
    'quick_phrase_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'search_service_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'tts_service_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'instruction_injection_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'assistant_tag_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'preference_rows': ['key', 'value', 'updated_at'],
    'memory_entry_rows': [
      'id',
      'sort_order',
      'scope',
      'assistant_id',
      'type',
      'status',
      'content',
      'content_normalized',
      'entry_created_at',
      'entry_updated_at',
      'payload',
      'updated_at',
    ],
    'user_profile_field_rows': ['id', 'sort_order', 'payload', 'updated_at'],
    'message_prompt_rows': [
      'revision_id',
      'conversation_id',
      'payload',
      'carries_memory_snapshot',
      'created_at',
    ],
    'tombstone_rows': ['scope', 'entity_id', 'deleted_at', 'payload'],
    'extension_entity_rows': [
      'kind',
      'id',
      'sort_order',
      'owner_id',
      'payload',
      'updated_at',
    ],
  };

  /// 完整结构匹配才认定为上游 schema 3；不看裸版本号猜。
  static bool isSchema3Payload(File file) {
    sqlite.Database? database;
    try {
      database = sqlite.sqlite3.open(
        file.absolute.path,
        mode: sqlite.OpenMode.readOnly,
      );
      return _matchesExactShape(database);
    } on sqlite.SqliteException {
      return false;
    } finally {
      database?.close();
    }
  }

  static Future<void> convertToCurrentSchema(File file) async {
    if (!await file.exists()) {
      throw FileSystemException('Upstream database missing', file.path);
    }
    final source = file.absolute;
    final target = File('${source.path}.joaiclient-schema9.tmp');
    await _deleteDatabaseFamily(target);
    try {
      var repository = ChatDatabaseRepository.open(file: target);
      await repository.ensureReady();
      await repository.close();

      final conversationIds = _copySchema3Tables(
        source: source,
        target: target,
      );
      repository = ChatDatabaseRepository.open(file: target);
      try {
        for (final conversationId in conversationIds) {
          await repository.rebuildLegacyConversationTreeForImport(
            conversationId,
          );
        }
        await repository.validateIntegrity();
        await repository.checkpoint();
      } finally {
        await repository.close();
      }

      await _deleteDatabaseFamily(source);
      await target.rename(source.path);
      await ChatDatabaseRepository.normalizeSnapshotJournal(source);
    } catch (_) {
      await _deleteDatabaseFamily(target);
      rethrow;
    }
  }

  static bool _matchesExactShape(sqlite.Database database) {
    if (database.userVersion != 3) return false;
    final rows = database.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%';",
    );
    final actualTables = rows.map((row) => row['name'] as String).toSet();
    if (!_setEquals(actualTables, _sourceTables.keys.toSet())) return false;
    for (final entry in _sourceTables.entries) {
      final columns = database
          .select('PRAGMA table_info("${entry.key}");')
          .map((row) => row['name'] as String)
          .toList(growable: false);
      if (!_sameOrderedStrings(columns, entry.value)) return false;
    }
    return true;
  }

  static List<String> _copySchema3Tables({
    required File source,
    required File target,
  }) {
    final database = sqlite.sqlite3.open(target.absolute.path);
    var attached = false;
    var transaction = false;
    try {
      database
        ..execute('PRAGMA busy_timeout = 5000;')
        ..execute('PRAGMA foreign_keys = OFF;')
        ..execute('ATTACH DATABASE ? AS $_sourceAlias;', [
          source.absolute.path,
        ]);
      attached = true;
      database.execute('BEGIN IMMEDIATE;');
      transaction = true;

      for (final entry in _sourceTables.entries) {
        final sourceTable = entry.key;
        final targetTable = sourceTable == 'assistant_tag_rows'
            ? 'assistant_group_rows'
            : sourceTable;
        final columns = entry.value.join(', ');
        if (sourceTable == 'message_prompt_rows') {
          database.execute('''
            INSERT INTO main."$targetTable"
              ($columns, source_content_hash)
            SELECT $columns, NULL
            FROM $_sourceAlias."$sourceTable";
          ''');
        } else {
          database.execute('''
            INSERT INTO main."$targetTable" ($columns)
            SELECT $columns FROM $_sourceAlias."$sourceTable";
          ''');
        }
      }

      final violations = database.select('PRAGMA foreign_key_check;');
      if (violations.isNotEmpty) {
        throw StateError('kelivo_schema3_foreign_keys');
      }
      database.execute('COMMIT;');
      transaction = false;
      final conversationIds = database
          .select(
            'SELECT id FROM main.conversation_rows ORDER BY created_at, id;',
          )
          .map((row) => row['id'] as String)
          .toList(growable: false);
      database.execute('DETACH DATABASE $_sourceAlias;');
      attached = false;
      return conversationIds;
    } catch (_) {
      if (transaction) {
        try {
          database.execute('ROLLBACK;');
        } on sqlite.SqliteException {
          // SQLite 可能已自动结束失效事务；保留原始错误。
        }
      }
      if (attached) {
        try {
          database.execute('DETACH DATABASE $_sourceAlias;');
        } on sqlite.SqliteException {
          // 保留原始转换错误。
        }
      }
      rethrow;
    } finally {
      database.close();
    }
  }

  static bool _setEquals(Set<String> left, Set<String> right) {
    if (left.length != right.length) return false;
    return left.containsAll(right);
  }

  static bool _sameOrderedStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  static Future<void> _deleteDatabaseFamily(File file) async {
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final sidecar = File('${file.path}$suffix');
      if (await sidecar.exists()) {
        await sidecar.delete();
      }
    }
  }
}
