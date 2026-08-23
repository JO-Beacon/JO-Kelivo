import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/conversation_tree.dart';
import '../models/message_part.dart';
import '../utils/multimodal_input_utils.dart';
import '../../utils/sandbox_path_resolver.dart';
import '../../utils/kelivo_file_uri.dart';
import '../models/memory_entry.dart';
import '../models/user_profile_field.dart';
import 'app_database.dart';
import 'business_data.dart';
import 'business_repository.dart';
import 'chat_database_observer.dart';
import 'generation_run.dart';
import 'generation_run_commands.dart';

typedef ChatDatabaseSnapshotInfo = ({
  int schemaVersion,
  int conversationCount,
  int messageCount,
});

typedef InstalledChatDatabaseInfo = ({int schemaVersion, String? databaseId});

typedef ParsedChatImportBatch = ({
  Conversation conversation,
  List<ChatMessage> messages,
  ConversationTree? tree,
});

final class LinearMessageWindowSlot {
  const LinearMessageWindowSlot({
    required this.groupId,
    required this.revisionId,
    required this.versionCount,
    required this.logicalIndex,
  });

  final String groupId;
  final String revisionId;
  final int versionCount;
  final int logicalIndex;
}

final class LinearMessageWindow {
  const LinearMessageWindow({
    required this.slots,
    required this.totalSlotCount,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
  });

  final List<LinearMessageWindowSlot> slots;
  final int totalSlotCount;
  final bool hasMoreBefore;
  final bool hasMoreAfter;
}

typedef AppendedMessageVersion = ({
  Conversation conversation,
  ChatMessage message,
});

typedef DeletedMessagesResult = ({
  Conversation conversation,
  List<ChatMessage> messages,
});

typedef GenerationBeginResult = ({
  Conversation conversation,
  ChatMessage? userMessage,
  ChatMessage assistantMessage,
  GenerationRun run,
});

class BackupMergeReport {
  const BackupMergeReport({
    required this.importedConversations,
    required this.deduplicatedConversations,
    required this.skippedConversations,
    required this.remappedConversationIds,
    this.importedConversationIds = const <String>[],
  });

  final int importedConversations;
  final int deduplicatedConversations;
  final int skippedConversations;
  final Map<String, String> remappedConversationIds;

  /// 此合并新插入的目标会话 ID（重映射后的 ID）。
  final List<String> importedConversationIds;

  int get remappedConversations => remappedConversationIds.length;
}

class SandboxPathMigrationResult {
  const SandboxPathMigrationResult({
    required this.ran,
    required this.scannedMessages,
    required this.updatedMessages,
    required this.skippedParts,
  });

  final bool ran;
  final int scannedMessages;
  final int updatedMessages;
  final int skippedParts;
}

class ChatDatabaseRepository {
  ChatDatabaseRepository(
    this._db, {
    File? databaseFile,
    ChatDatabaseObserver? observer,
  }) : _databaseFile = databaseFile?.absolute,
       _observer = observer ?? ChatDatabaseObserver.instance;

  final AppDatabase _db;
  final File? _databaseFile;
  final ChatDatabaseObserver _observer;
  bool _messageSearchFtsReady = false;

  static ChatDatabaseRepository open({
    File? file,
    ChatDatabaseObserver? observer,
  }) {
    final db = AppDatabase.open(file: file);
    return ChatDatabaseRepository(db, databaseFile: file, observer: observer);
  }

  Future<GenerationRun> createGenerationRun({
    required String id,
    required String conversationId,
    required String targetRevisionId,
    required DateTime createdAt,
  }) => GenerationRunCommands(_db).create(
    id: id,
    conversationId: conversationId,
    targetRevisionId: targetRevisionId,
    createdAt: createdAt,
  );

  Future<GenerationRun?> getGenerationRun(String id) =>
      GenerationRunCommands(_db).get(id);

  Future<GenerationRun> transitionGenerationRun({
    required String id,
    required GenerationRunState expectedState,
    required int expectedStateRevision,
    required GenerationRunState nextState,
    required DateTime updatedAt,
    String? errorCode,
  }) => GenerationRunCommands(_db).transition(
    id: id,
    expectedState: expectedState,
    expectedStateRevision: expectedStateRevision,
    nextState: nextState,
    updatedAt: updatedAt,
    errorCode: errorCode,
  );

  Future<GenerationRun> checkpointGenerationRun({
    required String id,
    required String targetRevisionId,
    required int checkpointSeq,
    required DateTime updatedAt,
  }) => GenerationRunCommands(_db).checkpoint(
    id: id,
    targetRevisionId: targetRevisionId,
    checkpointSeq: checkpointSeq,
    updatedAt: updatedAt,
  );

  Future<GenerationRun> finalizeGenerationRun({
    required ChatMessage message,
    required List<Map<String, dynamic>> toolEvents,
    required String generationRunId,
    required GenerationRunState expectedState,
    required int expectedStateRevision,
    required GenerationRunState terminalState,
    int? checkpointSeq,
    String? errorCode,
    String? geminiThoughtSignature,
  }) {
    if (!terminalState.isTerminal) {
      throw ArgumentError.value(terminalState, 'terminalState');
    }
    return _observer.measure(
      ChatDatabaseOperation.commandFinalCheckpoint,
      () => _db.transaction(() async {
        await _updateStreamingCheckpoint(
          message,
          toolEvents,
          generationRunId: checkpointSeq == null ? null : generationRunId,
          checkpointSeq: checkpointSeq,
        );
        final signature = geminiThoughtSignature?.trim();
        if (signature != null && signature.isNotEmpty) {
          await _upsertGeminiThoughtSignature(message.id, signature);
        }
        return GenerationRunCommands(_db).transition(
          id: generationRunId,
          expectedState: expectedState,
          expectedStateRevision: expectedStateRevision,
          nextState: terminalState,
          updatedAt: DateTime.now().toUtc(),
          errorCode: errorCode,
        );
      }),
    );
  }

  static Future<bool> migrateInstalledDatabase(File file) async {
    try {
      final installedSchemaVersion = _readRawUserVersion(file);
      if (installedSchemaVersion > AppDatabase.currentSchemaVersion) {
        throw StateError('database_schema_too_new');
      }
      if (installedSchemaVersion == AppDatabase.currentSchemaVersion) {
        _validateRawDatabaseFile(file);
        return false;
      }

      final appDatabase = AppDatabase.open(file: file);
      try {
        await appDatabase.customSelect('SELECT 1;').getSingle();
      } finally {
        await appDatabase.close();
      }
      _validateRawDatabaseFile(file);
      return true;
    } on sqlite.SqliteException {
      throw StateError('database_corrupt');
    }
  }

  /// 读取 SQLite 的 user_version，而不打开 Drift 运行时。
  /// 启动门在这里暂停，以免升级旧数据库。
  static int readInstalledSchemaVersion(File file) => _readRawUserVersion(file);

  static InstalledChatDatabaseInfo inspectInstalledDatabase(
    File file, {
    bool validateContents = false,
  }) {
    final database = sqlite.sqlite3.open(
      file.absolute.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      final schemaVersion = database.userVersion;
      if (schemaVersion > AppDatabase.currentSchemaVersion) {
        throw StateError('database_schema_too_new');
      }
      if (validateContents) {
        _validateRawSnapshot(database);
      } else {
        _validateRawStructure(database);
      }
      if (schemaVersion != AppDatabase.currentSchemaVersion) {
        throw StateError('database_schema_version');
      }
      final identityRows = database.select(
        'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
        [ChatStorageMetaKeys.databaseIdentity],
      );
      if (identityRows.length > 1) {
        throw StateError('database_identity_duplicate');
      }
      final databaseId = identityRows.isEmpty
          ? null
          : identityRows.single['value'] as String?;
      if (databaseId != null && !_isUuid(databaseId)) {
        throw StateError('database_identity_invalid');
      }
      return (schemaVersion: schemaVersion, databaseId: databaseId);
    } on sqlite.SqliteException {
      throw StateError('database_corrupt');
    } finally {
      database.close();
    }
  }

  static InstalledChatDatabaseInfo inspectUncleanInstalledDatabase(File file) {
    final database = sqlite.sqlite3.open(
      file.absolute.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      final quickCheckRows = database.select('PRAGMA quick_check;');
      if (quickCheckRows.length != 1 ||
          quickCheckRows.single.values.single != 'ok') {
        throw StateError('quick_check');
      }
      if (database.select('PRAGMA foreign_key_check;').isNotEmpty) {
        throw StateError('foreign_key_check');
      }
      _validateRawStructure(database);
      if (database.userVersion != AppDatabase.currentSchemaVersion) {
        throw StateError('database_schema_version');
      }
      final identityRows = database.select(
        'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
        [ChatStorageMetaKeys.databaseIdentity],
      );
      if (identityRows.length > 1) {
        throw StateError('database_identity_duplicate');
      }
      final databaseId = identityRows.isEmpty
          ? null
          : identityRows.single['value'] as String?;
      if (databaseId != null && !_isUuid(databaseId)) {
        throw StateError('database_identity_invalid');
      }
      return (schemaVersion: database.userVersion, databaseId: databaseId);
    } on sqlite.SqliteException {
      throw StateError('database_corrupt');
    } finally {
      database.close();
    }
  }

  static void assignInstalledDatabaseIdentity(File file, String databaseId) {
    if (!_isUuid(databaseId)) throw StateError('database_identity_invalid');
    final database = sqlite.sqlite3.open(file.absolute.path);
    try {
      database.execute('PRAGMA foreign_keys = ON;');
      database.execute('PRAGMA synchronous = FULL;');
      _validateRawStructure(database);
      if (database.userVersion != AppDatabase.currentSchemaVersion) {
        throw StateError('database_schema_version');
      }
      final existing = database.select(
        'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
        [ChatStorageMetaKeys.databaseIdentity],
      );
      if (existing.isNotEmpty && existing.single['value'] != databaseId) {
        throw StateError('database_identity_mismatch');
      }
      database.execute(
        'INSERT OR IGNORE INTO chat_storage_meta_rows (key, value) VALUES (?, ?);',
        [ChatStorageMetaKeys.databaseIdentity, databaseId],
      );
      database.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } on sqlite.SqliteException {
      throw StateError('database_corrupt');
    } finally {
      database.close();
    }
  }

  static bool _isUuid(String value) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(value);

  static Future<ChatDatabaseSnapshotInfo> createConsistentSnapshot({
    required File sourceFile,
    required File destinationFile,
  }) async {
    final sourcePath = sourceFile.absolute.path;
    final destinationPath = destinationFile.absolute.path;
    if (sourcePath == destinationPath) {
      throw ArgumentError.value(
        destinationFile.path,
        'destinationFile',
        'must differ from sourceFile',
      );
    }
    if (!await sourceFile.exists()) {
      throw FileSystemException('Source database does not exist', sourcePath);
    }

    await destinationFile.parent.create(recursive: true);
    await _deleteDatabaseFamily(destinationFile);

    try {
      late final ChatDatabaseSnapshotInfo initialInfo;
      final source = sqlite.sqlite3.open(sourcePath);
      try {
        source.execute('PRAGMA query_only = ON;');
        final destination = sqlite.sqlite3.open(destinationPath);
        try {
          final pageSizeRows = source.select('PRAGMA page_size;');
          final pageSize = pageSizeRows.first.values.first as int;
          final pagesPerStep = (8 * 1024 * 1024 ~/ pageSize).clamp(1, 1 << 20);
          await source.backup(destination, nPage: pagesPerStep).drain<void>();
          initialInfo = _validateRawSnapshot(destination);
          destination.execute('PRAGMA wal_checkpoint(TRUNCATE);');
          destination.select('PRAGMA journal_mode = DELETE;');
        } finally {
          destination.close();
        }
      } finally {
        source.close();
      }

      await _deleteDatabaseSidecars(destinationFile);
      final reopened = sqlite.sqlite3.open(destinationPath);
      try {
        final reopenedInfo = _validateRawSnapshot(reopened);
        if (reopenedInfo != initialInfo) {
          throw StateError('snapshot_reopen_mismatch');
        }
      } finally {
        reopened.close();
      }
      await _deleteDatabaseSidecars(destinationFile);
      return initialInfo;
    } catch (_) {
      await _deleteDatabaseFamily(destinationFile);
      rethrow;
    }
  }

  static Future<ChatDatabaseSnapshotInfo> prepareSnapshotForRestore(
    File snapshotFile,
  ) async {
    if (!await snapshotFile.exists()) {
      throw FileSystemException(
        'Snapshot database does not exist',
        snapshotFile.path,
      );
    }

    final database = sqlite.sqlite3.open(snapshotFile.absolute.path);
    late final ChatDatabaseSnapshotInfo initialInfo;
    try {
      initialInfo = _validateRawSnapshot(database);
      if (initialInfo.schemaVersion != AppDatabase.currentSchemaVersion) {
        throw StateError('database_schema_version');
      }
      database.execute('BEGIN IMMEDIATE;');
      try {
        database.execute(
          'UPDATE message_rows SET is_streaming = 0 '
          'WHERE is_streaming != 0;',
        );
        database.execute('DELETE FROM chat_storage_meta_rows WHERE key = ?;', [
          ChatStorageMetaKeys.activeStreamingIds,
        ]);
        database.execute(
          'INSERT OR REPLACE INTO chat_storage_meta_rows (key, value) '
          'VALUES (?, ?);',
          [ChatStorageMetaKeys.hiveMigrationComplete, 'true'],
        );
        database.execute('COMMIT;');
      } catch (_) {
        database.execute('ROLLBACK;');
        rethrow;
      }
      database.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      database.select('PRAGMA journal_mode = DELETE;');
    } finally {
      database.close();
    }

    await _deleteDatabaseSidecars(snapshotFile);
    final reopenedInfo = await inspectPreparedSnapshot(snapshotFile);
    if (reopenedInfo != initialInfo) {
      throw StateError('snapshot_reopen_mismatch');
    }
    return initialInfo;
  }

  static Future<ChatDatabaseSnapshotInfo> inspectPreparedSnapshot(
    File snapshotFile,
  ) async {
    if (await FileSystemEntity.type(snapshotFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException(
        'Snapshot database is not a regular file',
        snapshotFile.path,
      );
    }
    await _requireNoDatabaseSidecars(snapshotFile);

    final database = sqlite.sqlite3.open(
      snapshotFile.absolute.path,
      mode: sqlite.OpenMode.readOnly,
    );
    var inspectionCompleted = false;
    try {
      final info = _validateRawSnapshot(database);
      if (info.schemaVersion != AppDatabase.currentSchemaVersion) {
        throw StateError('database_schema_version');
      }
      final streamingRows = database.select(
        'SELECT COUNT(*) AS count FROM message_rows WHERE is_streaming != 0;',
      );
      if (streamingRows.single['count'] != 0) {
        throw StateError('database_streaming_messages');
      }
      final activeStreamingRows = database.select(
        'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
        [ChatStorageMetaKeys.activeStreamingIds],
      );
      if (activeStreamingRows.isNotEmpty) {
        throw StateError('database_active_streaming_ids');
      }
      final migrationRows = database.select(
        'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
        [ChatStorageMetaKeys.hiveMigrationComplete],
      );
      if (migrationRows.length != 1 ||
          migrationRows.single['value'] != 'true') {
        throw StateError('database_migration_receipt');
      }
      inspectionCompleted = true;
      return info;
    } finally {
      database.close();
      if (inspectionCompleted) {
        await _requireNoDatabaseSidecars(snapshotFile);
      }
    }
  }

  static Future<void> _requireNoDatabaseSidecars(File databaseFile) async {
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final sidecar = File('${databaseFile.path}$suffix');
      if (await FileSystemEntity.type(sidecar.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('database_sidecar:$suffix');
      }
    }
  }

  static ChatDatabaseSnapshotInfo _validateRawSnapshot(
    sqlite.Database database,
  ) {
    final integrityRows = database.select('PRAGMA integrity_check;');
    if (integrityRows.length != 1 ||
        integrityRows.single.values.single != 'ok') {
      throw StateError('integrity_check');
    }
    if (database.select('PRAGMA foreign_key_check;').isNotEmpty) {
      throw StateError('foreign_key_check');
    }

    _validateRawStructure(database);

    return (
      schemaVersion: database.userVersion,
      conversationCount: _rawTableCount(database, 'conversation_rows'),
      messageCount: _rawTableCount(database, 'message_rows'),
    );
  }

  static int _readRawUserVersion(File file) {
    final database = sqlite.sqlite3.open(
      file.absolute.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      return database.userVersion;
    } finally {
      database.close();
    }
  }

  static void _validateRawDatabaseFile(File file) {
    final database = sqlite.sqlite3.open(
      file.absolute.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      _validateRawStructure(database);
    } finally {
      database.close();
    }
  }

  static void _validateRawStructure(sqlite.Database database) {
    if (database.userVersion != AppDatabase.currentSchemaVersion) {
      throw StateError('database_schema_version');
    }

    const requiredTables = {
      'conversation_rows',
      'conversation_mcp_server_rows',
      'message_rows',
      'message_tree_edge_rows',
      'conversation_branch_rows',
      'conversation_tree_state_rows',
      'chat_storage_meta_rows',
      'message_part_rows',
      'generation_run_rows',
      'provider_artifact_rows',
      'asset_rows',
      'message_asset_rows',
      'asset_gc_rows',
      'gc_audit_rows',
      'asset_reference_dirty_rows',
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
      'assistant_group_rows',
      'preference_rows',
      'memory_entry_rows',
      'user_profile_field_rows',
      'message_prompt_rows',
    };
    final tableRows = database.select(
      "SELECT name FROM sqlite_master WHERE type = 'table';",
    );
    final tables = tableRows
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();
    if (tables.intersection(const {
      'message_slot_rows',
      'message_revision_rows',
      'conversation_state_rows',
    }).isNotEmpty) {
      throw StateError('retired_tables');
    }
    if (!tables.containsAll(requiredTables)) {
      throw StateError('required_tables');
    }
    _validateRawSchema(database);
  }

  static void _validateRawSchema(sqlite.Database database) {
    const expectedColumns = <String, List<String>>{
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
      ],
      'conversation_mcp_server_rows': [
        'conversation_id',
        'server_id',
        'ordinal',
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
      ],
      'message_tree_edge_rows': [
        'conversation_id',
        'message_id',
        'parent_message_id',
      ],
      'conversation_branch_rows': [
        'id',
        'conversation_id',
        'tip_message_id',
        'name',
        'created_at',
      ],
      'conversation_tree_state_rows': [
        'conversation_id',
        'active_branch_id',
        'branch_selections_json',
      ],
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
      'instruction_injection_rows': [
        'id',
        'sort_order',
        'payload',
        'updated_at',
      ],
      'assistant_group_rows': ['id', 'sort_order', 'payload', 'updated_at'],
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
    };
    for (final entry in expectedColumns.entries) {
      final tableInfo = database.select('PRAGMA table_info(${entry.key});');
      final actual = tableInfo
          .map((row) => row['name'])
          .whereType<String>()
          .toList(growable: false);
      if (!_sameOrderedStrings(actual, entry.value)) {
        throw StateError('table_schema:${entry.key}');
      }
    }

    const expectedPrimaryKeys = <String, List<String>>{
      'message_tree_edge_rows': ['conversation_id', 'message_id'],
      'conversation_branch_rows': ['id'],
      'conversation_tree_state_rows': ['conversation_id'],
      'asset_rows': ['id'],
      'message_asset_rows': ['revision_id', 'asset_id', 'kind'],
      'asset_gc_rows': ['asset_id'],
      'gc_audit_rows': ['id'],
      'asset_reference_dirty_rows': ['revision_id'],
      'assistant_rows': ['id'],
      'provider_rows': ['provider_key'],
      'provider_group_rows': ['id'],
      'mcp_server_rows': ['id'],
      'world_book_rows': ['id'],
      'assistant_memory_rows': ['id'],
      'quick_phrase_rows': ['id'],
      'search_service_rows': ['id'],
      'tts_service_rows': ['id'],
      'instruction_injection_rows': ['id'],
      'assistant_group_rows': ['id'],
      'preference_rows': ['key'],
      'memory_entry_rows': ['id'],
      'user_profile_field_rows': ['id'],
      'message_prompt_rows': ['revision_id'],
    };
    const sortOrderTables = {
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
      'assistant_group_rows',
      'memory_entry_rows',
      'user_profile_field_rows',
    };
    for (final entry in expectedPrimaryKeys.entries) {
      final primaryRows =
          database
              .select('PRAGMA table_info(${entry.key});')
              .where((row) => (row['pk'] as int? ?? 0) > 0)
              .toList()
            ..sort(
              (left, right) =>
                  (left['pk'] as int).compareTo(right['pk'] as int),
            );
      final actual = primaryRows
          .map((row) => row['name'])
          .whereType<String>()
          .toList(growable: false);
      if (!_sameOrderedStrings(actual, entry.value)) {
        throw StateError('primary_key_schema:${entry.key}');
      }
      if (sortOrderTables.contains(entry.key)) {
        final schemaRow = database.select(
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?;",
          [entry.key],
        ).single;
        final normalizedSql = (schemaRow['sql'] as String? ?? '')
            .replaceAll(RegExp(r'[\s"]'), '')
            .toLowerCase();
        if (!normalizedSql.contains('check(sort_order>=0)')) {
          throw StateError('check_schema:${entry.key}');
        }
      }
    }

    const memoryIndexName = 'idx_assistant_memories_assistant';
    final memoryIndexRows = database.select(
      'PRAGMA index_list(assistant_memory_rows);',
    );
    final memoryIndex = memoryIndexRows.where(
      (row) => row['name'] == memoryIndexName,
    );
    if (memoryIndex.length != 1 || memoryIndex.single['unique'] != 0) {
      throw StateError('index_schema:$memoryIndexName');
    }
    final memoryIndexColumns = database
        .select('PRAGMA index_info($memoryIndexName);')
        .map((row) => row['name'])
        .whereType<String>()
        .toList(growable: false);
    if (!_sameOrderedStrings(memoryIndexColumns, const [
      'assistant_id',
      'id',
    ])) {
      throw StateError('index_schema:$memoryIndexName');
    }

    void requireIndex({
      required String table,
      required String name,
      required List<String> columns,
    }) {
      final indexRows = database.select('PRAGMA index_list($table);');
      final index = indexRows.where((row) => row['name'] == name);
      if (index.length != 1 || index.single['unique'] != 0) {
        throw StateError('index_schema:$name');
      }
      final actual = database
          .select('PRAGMA index_info($name);')
          .map((row) => row['name'])
          .whereType<String>()
          .toList(growable: false);
      if (!_sameOrderedStrings(actual, columns)) {
        throw StateError('index_schema:$name');
      }
    }

    requireIndex(
      table: 'memory_entry_rows',
      name: 'idx_memory_entries_visible',
      columns: const ['status', 'type', 'scope', 'assistant_id'],
    );
    requireIndex(
      table: 'memory_entry_rows',
      name: 'idx_memory_entries_recent',
      columns: const ['status', 'type', 'entry_updated_at', 'id'],
    );
    requireIndex(
      table: 'memory_entry_rows',
      name: 'idx_memory_entries_dedupe',
      columns: const ['scope', 'assistant_id', 'type', 'content_normalized'],
    );
    requireIndex(
      table: 'message_tree_edge_rows',
      name: 'idx_message_tree_edges_conversation',
      columns: const ['conversation_id'],
    );
    requireIndex(
      table: 'conversation_branch_rows',
      name: 'idx_conversation_branches_conversation',
      columns: const ['conversation_id'],
    );
    requireIndex(
      table: 'conversation_tree_state_rows',
      name: 'idx_conversation_tree_state_conversation',
      columns: const ['conversation_id'],
    );
    requireIndex(
      table: 'message_prompt_rows',
      name: 'idx_message_prompts_conversation_snapshot',
      columns: const ['conversation_id', 'carries_memory_snapshot'],
    );

    const assetIndexName = 'idx_message_assets_asset';
    final assetIndexRows = database.select(
      'PRAGMA index_list(message_asset_rows);',
    );
    final assetIndex = assetIndexRows.where(
      (row) => row['name'] == assetIndexName,
    );
    if (assetIndex.length != 1 || assetIndex.single['unique'] != 0) {
      throw StateError('index_schema:$assetIndexName');
    }
    final assetIndexColumns = database
        .select('PRAGMA index_info($assetIndexName);')
        .map((row) => row['name'])
        .whereType<String>()
        .toList(growable: false);
    if (!_sameOrderedStrings(assetIndexColumns, const [
      'asset_id',
      'revision_id',
    ])) {
      throw StateError('index_schema:$assetIndexName');
    }

    final hasUniqueAssetContentHash = database
        .select('PRAGMA index_list(asset_rows);')
        .where(
          (row) => row['unique'] == 1 && (row['partial'] as int? ?? 0) == 0,
        )
        .any((row) {
          final indexName = row['name'] as String?;
          if (indexName == null) return false;
          final columns = database.select(
            'SELECT name FROM pragma_index_info(?) ORDER BY seqno;',
            [indexName],
          );
          return columns.length == 1 &&
              columns.single['name'] == 'content_hash';
        });
    if (!hasUniqueAssetContentHash) {
      throw StateError('index_schema:asset_rows.content_hash');
    }

    const expectedForeignKeys = <String, Set<String>>{
      'conversation_mcp_server_rows': {
        'conversation_id->conversation_rows.id:CASCADE',
      },
      'message_rows': {'conversation_id->conversation_rows.id:CASCADE'},
      'message_tree_edge_rows': {
        'conversation_id->conversation_rows.id:CASCADE',
      },
      'conversation_branch_rows': {
        'conversation_id->conversation_rows.id:CASCADE',
      },
      'conversation_tree_state_rows': {
        'conversation_id->conversation_rows.id:CASCADE',
      },
      'message_part_rows': {'revision_id->message_rows.id:CASCADE'},
      'generation_run_rows': {
        'conversation_id->conversation_rows.id:CASCADE',
        'target_revision_id->message_rows.id:NO ACTION',
      },
      'provider_artifact_rows': {'revision_id->message_rows.id:CASCADE'},
      'asset_rows': <String>{},
      'message_asset_rows': {
        'revision_id->message_rows.id:CASCADE',
        'asset_id->asset_rows.id:CASCADE',
      },
      'asset_gc_rows': {'asset_id->asset_rows.id:CASCADE'},
      'gc_audit_rows': <String>{},
      'asset_reference_dirty_rows': {'revision_id->message_rows.id:CASCADE'},
      'assistant_rows': <String>{},
      'provider_rows': <String>{},
      'provider_group_rows': <String>{},
      'mcp_server_rows': <String>{},
      'world_book_rows': <String>{},
      'assistant_memory_rows': <String>{},
      'quick_phrase_rows': <String>{},
      'search_service_rows': <String>{},
      'tts_service_rows': <String>{},
      'instruction_injection_rows': <String>{},
      'assistant_group_rows': <String>{},
      'preference_rows': <String>{},
      'memory_entry_rows': <String>{},
      'user_profile_field_rows': <String>{},
      'message_prompt_rows': {'revision_id->message_rows.id:CASCADE'},
    };
    for (final entry in expectedForeignKeys.entries) {
      final actual = database
          .select('PRAGMA foreign_key_list(${entry.key});')
          .map(
            (row) =>
                '${row['from']}->${row['table']}.${row['to']}:'
                '${row['on_delete']}',
          )
          .toSet();
      if (actual.length != entry.value.length ||
          !actual.containsAll(entry.value)) {
        throw StateError('foreign_key_schema:${entry.key}');
      }
    }
  }

  static bool _sameOrderedStrings(List<String> actual, List<String> expected) {
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  static int _rawTableCount(sqlite.Database database, String table) {
    return database
            .select('SELECT COUNT(*) AS count FROM $table;')
            .single['count']
        as int;
  }

  static Future<void> _deleteDatabaseFamily(File databaseFile) async {
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final file = File('${databaseFile.path}$suffix');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  static Future<void> _deleteDatabaseSidecars(File databaseFile) async {
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final file = File('${databaseFile.path}$suffix');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> close() async {
    await _db.close();
  }

  Future<void> ensureReady() async {
    await _db.customSelect('SELECT 1').get();
  }

  Future<List<LegacyTreeMigrationWarning>>
  readAndClearContextTreeMigrationWarnings() async {
    return _db.transaction(() async {
      final rows =
          await (_db.select(_db.chatStorageMetaRows)..where(
                (row) =>
                    row.key.equals(AppDatabase.contextTreeMigrationWarningsKey),
              ))
              .get();
      if (rows.isEmpty) return const <LegacyTreeMigrationWarning>[];

      Object? decoded;
      var malformed = false;
      try {
        decoded = jsonDecode(rows.first.value);
      } catch (_) {
        malformed = true;
        decoded = const <Object>[];
      }
      await (_db.delete(_db.chatStorageMetaRows)..where(
            (row) =>
                row.key.equals(AppDatabase.contextTreeMigrationWarningsKey),
          ))
          .go();
      if (malformed || decoded is! List) {
        return const <LegacyTreeMigrationWarning>[
          LegacyTreeMigrationWarning(
            conversationId: '',
            groupId: '',
            fallbackVersion: 0,
          ),
        ];
      }

      final warnings = <LegacyTreeMigrationWarning>[];
      for (final value in decoded) {
        if (value is! Map) continue;
        final conversationId = value['conversationId'];
        final groupId = value['groupId'];
        final fallbackVersion = value['fallbackVersion'];
        if (conversationId is String &&
            groupId is String &&
            fallbackVersion is int) {
          warnings.add(
            LegacyTreeMigrationWarning(
              conversationId: conversationId,
              groupId: groupId,
              fallbackVersion: fallbackVersion,
            ),
          );
        }
      }
      return warnings;
    });
  }

  Future<ChatDatabaseConnectionContract> validateConnectionContract() async {
    final stopwatch = Stopwatch()..start();
    try {
      Future<Object?> pragma(String name) async {
        final row = await _db.customSelect('PRAGMA $name;').getSingle();
        return row.data.values.single;
      }

      final contract = ChatDatabaseConnectionContract(
        schemaVersion: await pragma('user_version') as int,
        journalModeWal:
            (await pragma('journal_mode')).toString().toLowerCase() == 'wal',
        foreignKeysEnabled: await pragma('foreign_keys') == 1,
        busyTimeoutMillis: await pragma('busy_timeout') as int,
        synchronous: await pragma('synchronous') as int,
        walAutoCheckpointPages: await pragma('wal_autocheckpoint') as int,
        journalSizeLimitBytes: await pragma('journal_size_limit') as int,
      );
      if (contract.schemaVersion != AppDatabase.currentSchemaVersion) {
        throw StateError('database_connection_contract:schema_version');
      }
      if (!contract.journalModeWal) {
        throw StateError('database_connection_contract:journal_mode');
      }
      if (!contract.foreignKeysEnabled) {
        throw StateError('database_connection_contract:foreign_keys');
      }
      if (contract.busyTimeoutMillis != AppDatabase.busyTimeoutMillis) {
        throw StateError('database_connection_contract:busy_timeout');
      }
      if (contract.synchronous != AppDatabase.synchronousNormal) {
        throw StateError('database_connection_contract:synchronous');
      }
      if (contract.walAutoCheckpointPages !=
          AppDatabase.walAutoCheckpointPages) {
        throw StateError('database_connection_contract:wal_autocheckpoint');
      }
      if (contract.journalSizeLimitBytes != AppDatabase.journalSizeLimitBytes) {
        throw StateError('database_connection_contract:journal_size_limit');
      }
      stopwatch.stop();
      _observer.recordConnectionContract(
        contract,
        elapsedMicros: stopwatch.elapsedMicroseconds,
      );
      return contract;
    } catch (error) {
      stopwatch.stop();
      _observer.recordFailure(
        operation: ChatDatabaseOperation.connectionContract,
        elapsedMicros: stopwatch.elapsedMicroseconds,
        error: error,
      );
      rethrow;
    }
  }

  Future<String?> getDatabaseIdentity() async {
    final row =
        await (_db.select(_db.chatStorageMetaRows)..where(
              (table) => table.key.equals(ChatStorageMetaKeys.databaseIdentity),
            ))
            .getSingleOrNull();
    return row?.value;
  }

  Future<SandboxPathMigrationResult> migrateSandboxPaths({
    required int targetVersion,
    required String targetRoot,
    required String Function(String uri) rewriteUri,
    int batchSize = 360,
  }) async {
    if (targetVersion <= 0) {
      throw ArgumentError.value(targetVersion, 'targetVersion');
    }
    if (targetRoot.trim().isEmpty) {
      throw ArgumentError.value(targetRoot, 'targetRoot');
    }
    if (batchSize <= 0) throw ArgumentError.value(batchSize, 'batchSize');
    return _db.transaction(() async {
      final receipt =
          await (_db.select(_db.chatStorageMetaRows)..where(
                (row) => row.key.equals(ChatStorageMetaKeys.sandboxPathVersion),
              ))
              .getSingleOrNull();
      var currentVersion = 0;
      String? currentRoot;
      if (receipt != null) {
        final Object? decoded;
        try {
          decoded = jsonDecode(receipt.value);
        } on FormatException {
          throw StateError('sandbox_path_migration_receipt');
        }
        if (decoded is! Map<String, dynamic> ||
            decoded.length != 2 ||
            decoded['version'] is! int ||
            decoded['targetRoot'] is! String) {
          throw StateError('sandbox_path_migration_receipt');
        }
        currentVersion = decoded['version'] as int;
        currentRoot = decoded['targetRoot'] as String;
      }
      if (currentVersion > targetVersion) {
        throw StateError('sandbox_path_migration_version');
      }
      if (currentVersion == targetVersion && currentRoot == targetRoot) {
        return const SandboxPathMigrationResult(
          ran: false,
          scannedMessages: 0,
          updatedMessages: 0,
          skippedParts: 0,
        );
      }

      var scanned = 0;
      var updated = 0;
      var skipped = 0;
      // 基于 part_id（AUTOINCREMENT 主键）的游标：顺序稳定，不会遗漏行，
      // 且在 payload 重写后不会重新扫描循环（part_id 不变）。
      var cursor = 0;
      while (true) {
        final rows = await _db
            .customSelect(
              'SELECT part_id, revision_id, ordinal, kind, payload '
              'FROM message_part_rows '
              "WHERE kind IN ('image', 'file') AND part_id > ? "
              'ORDER BY part_id LIMIT ?;',
              variables: [Variable<int>(cursor), Variable<int>(batchSize)],
            )
            .get();
        if (rows.isEmpty) break;
        for (final row in rows) {
          final partId = row.read<int>('part_id');
          final revisionId = row.read<String>('revision_id');
          final ordinal = row.read<int>('ordinal');
          final kind = row.read<String>('kind');
          final payload = row.read<String>('payload');
          final rewrite = _rewriteAttachmentPartUri(
            kind: kind,
            payload: payload,
            rewriteUri: rewriteUri,
          );
          scanned += 1;
          if (rewrite.parseError case final parseError?) {
            skipped += 1;
            await markMessageAssetReferencesDirty(revisionId);
            debugPrint(
              'Sandbox path migration skipped malformed part: '
              'revisionId=$revisionId ordinal=$ordinal kind=$kind '
              'parseError=$parseError',
            );
          }
          final rewritten = rewrite.payload;
          if (rewritten != payload) {
            await _db.customStatement(
              'UPDATE message_part_rows SET payload = ? WHERE part_id = ?;',
              [rewritten, partId],
            );
            updated += 1;
          }
          cursor = partId;
        }
      }
      await _db
          .into(_db.chatStorageMetaRows)
          .insertOnConflictUpdate(
            ChatStorageMetaRowsCompanion.insert(
              key: ChatStorageMetaKeys.sandboxPathVersion,
              value: jsonEncode({
                'version': targetVersion,
                'targetRoot': targetRoot,
              }),
            ),
          );
      return SandboxPathMigrationResult(
        ran: true,
        scannedMessages: scanned,
        updatedMessages: updated,
        skippedParts: skipped,
      );
    });
  }

  ({String payload, String? parseError}) _rewriteAttachmentPartUri({
    required String kind,
    required String payload,
    required String Function(String uri) rewriteUri,
  }) {
    final MessagePart part;
    try {
      part = MessagePart.fromRow(kind, payload);
    } on FormatException catch (error) {
      return (
        payload: payload,
        parseError: messagePartParseErrorCategory(error),
      );
    }
    if (part is ImagePart) {
      final nextUri = rewriteUri(part.uri);
      final nextUnavailable = _unavailableForRewrittenUri(nextUri);
      if (nextUri == part.uri && nextUnavailable == part.unavailable) {
        return (payload: payload, parseError: null);
      }
      return (
        payload: ImagePart(
          uri: nextUri,
          mime: part.mime,
          assetId: part.assetId,
          unavailable: nextUnavailable,
        ).encodePayload(),
        parseError: null,
      );
    }
    if (part is FilePart) {
      final nextUri = rewriteUri(part.uri);
      final nextUnavailable = _unavailableForRewrittenUri(nextUri);
      if (nextUri == part.uri && nextUnavailable == part.unavailable) {
        return (payload: payload, parseError: null);
      }
      return (
        payload: FilePart(
          uri: nextUri,
          name: part.name,
          mime: part.mime,
          assetId: part.assetId,
          unavailable: nextUnavailable,
        ).encodePayload(),
        parseError: null,
      );
    }
    return (payload: payload, parseError: null);
  }

  /// 远程/data URI 保持可用；本地路径使用 [localFileExists]
  /// （不进行 fix→File SMB 探测）。
  bool _unavailableForRewrittenUri(String nextUri) {
    if (isRemoteOrDataUri(nextUri)) return false;
    return !SandboxPathResolver.localFileExists(nextUri);
  }

  Future<bool> needsAssetReferenceBackfill({
    required int version,
    required String targetRoot,
  }) async {
    final row =
        await (_db.select(_db.chatStorageMetaRows)..where(
              (table) => table.key.equals(
                ChatStorageMetaKeys.assetReferenceBackfillVersion,
              ),
            ))
            .getSingleOrNull();
    if (row == null) return true;
    try {
      final value = jsonDecode(row.value);
      return value is! Map<String, dynamic> ||
          value['version'] != version ||
          value['targetRoot'] != targetRoot;
    } on FormatException {
      return true;
    }
  }

  Future<void> markAssetReferenceBackfillComplete({
    required int version,
    required String targetRoot,
  }) async {
    await _db
        .into(_db.chatStorageMetaRows)
        .insertOnConflictUpdate(
          ChatStorageMetaRowsCompanion.insert(
            key: ChatStorageMetaKeys.assetReferenceBackfillVersion,
            value: jsonEncode({'version': version, 'targetRoot': targetRoot}),
          ),
        );
  }

  Future<List<ChatMessage>> getMessagesForAssetReferenceBackfill({
    required String afterMessageId,
    required bool includeLegacyCandidates,
    int limit = 360,
  }) async {
    if (limit <= 0) return const <ChatMessage>[];
    final rows = await _db
        .customSelect(
          '''
          SELECT m.* FROM message_rows m
          WHERE m.id > ? AND (
            EXISTS (
              SELECT 1 FROM asset_reference_dirty_rows d
              WHERE d.revision_id = m.id
            ) OR (? AND (
              EXISTS (
                SELECT 1 FROM message_part_rows p
                WHERE p.revision_id = m.id
                  AND p.kind IN ('image', 'file')
              ) OR
              EXISTS (
                SELECT 1 FROM message_asset_rows a WHERE a.revision_id = m.id
              )
            ))
          )
          ORDER BY m.id LIMIT ?;
        ''',
          variables: [
            Variable<String>(afterMessageId),
            Variable<bool>(includeLegacyCandidates),
            Variable<int>(limit),
          ],
          readsFrom: {_db.messageRows, _db.messagePartRows},
        )
        .get();
    return _messagesFromRowsWithParts(
      rows.map((row) => _db.messageRows.map(row.data)).toList(growable: false),
    );
  }

  Future<bool> hasPendingAssetReferenceSync() async {
    return await _db
            .customSelect('SELECT 1 FROM asset_reference_dirty_rows LIMIT 1;')
            .getSingleOrNull() !=
        null;
  }

  Future<void> markMessageAssetReferencesDirty(String revisionId) async {
    await _db.customStatement(
      'INSERT OR IGNORE INTO asset_reference_dirty_rows(revision_id) '
      'VALUES (?);',
      [revisionId],
    );
  }

  /// [markMessageAssetReferencesDirty] 的批量变体，用于恢复/导入路径，
  /// 这些路径写入消息行时不经过 `_replaceMessageParts`。将修订加入队列可维持
  /// 资产引用回填不变式：每个带附件的修订都会在 GC 可能收集其文件前
  /// 重新注册。
  Future<void> _markMessageAssetReferencesDirtyBatch(
    List<String> revisionIds,
  ) async {
    if (revisionIds.isEmpty) return;
    const chunkSize = 200;
    for (var start = 0; start < revisionIds.length; start += chunkSize) {
      final end = start + chunkSize < revisionIds.length
          ? start + chunkSize
          : revisionIds.length;
      final chunk = revisionIds.sublist(start, end);
      await _db.customStatement(
        'INSERT OR IGNORE INTO asset_reference_dirty_rows(revision_id) '
        'VALUES ${List.filled(chunk.length, '(?)').join(', ')};',
        chunk,
      );
    }
  }

  Future<void> checkpoint() async {
    final stopwatch = Stopwatch()..start();
    int? walBytesBefore;
    try {
      walBytesBefore = await _walBytes();
      final row = await _db
          .customSelect('PRAGMA wal_checkpoint(TRUNCATE);')
          .getSingle();
      final walBytesAfter = await _walBytes();
      stopwatch.stop();
      _observer.record(
        ChatDatabaseObservation(
          operation: ChatDatabaseOperation.walCheckpoint,
          elapsedMicros: stopwatch.elapsedMicroseconds,
          succeeded: true,
          walBytesBefore: walBytesBefore,
          walBytesAfter: walBytesAfter,
          checkpointBusy: row.read<int>('busy'),
          checkpointLogFrames: row.read<int>('log'),
          checkpointedFrames: row.read<int>('checkpointed'),
        ),
      );
    } catch (error) {
      stopwatch.stop();
      _observer.recordFailure(
        operation: ChatDatabaseOperation.walCheckpoint,
        elapsedMicros: stopwatch.elapsedMicroseconds,
        error: error,
        walBytesBefore: walBytesBefore,
      );
      rethrow;
    }
  }

  Future<void> validateIntegrity() async {
    await _observer.measure(ChatDatabaseOperation.integrityCheck, () async {
      final integrityRows = await _db
          .customSelect('PRAGMA integrity_check')
          .get();
      final integrityValues = integrityRows
          .expand((row) => row.data.values)
          .map((value) => value.toString())
          .toList(growable: false);
      if (integrityValues.length != 1 || integrityValues.single != 'ok') {
        throw StateError('integrity_check');
      }
      final foreignKeyRows = await _db
          .customSelect('PRAGMA foreign_key_check')
          .get();
      if (foreignKeyRows.isNotEmpty) {
        throw StateError('foreign_key_check');
      }
    });
  }

  Future<int?> _walBytes() async {
    final databaseFile = _databaseFile;
    if (databaseFile == null) return null;
    final wal = File('${databaseFile.path}-wal');
    if (await FileSystemEntity.type(wal.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return 0;
    }
    return wal.length();
  }

  Future<List<Conversation>> getAllConversations() async {
    return _observer.measure(
      ChatDatabaseOperation.queryConversationList,
      () async {
        final rows =
            await (_db.select(_db.conversationRows)..orderBy([
                  (t) => OrderingTerm(
                    expression: t.updatedAt,
                    mode: OrderingMode.desc,
                  ),
                ]))
                .get();
        final out = <Conversation>[];
        for (final row in rows) {
          out.add(await _conversationFromRow(row));
        }
        return out;
      },
      resultCount: (rows) => rows.length,
    );
  }

  Future<List<Conversation>> getAllConversationSummaries() async {
    return _observer.measure(
      ChatDatabaseOperation.queryConversationList,
      () async {
        final rows =
            await (_db.select(_db.conversationRows)..orderBy([
                  (t) => OrderingTerm(
                    expression: t.updatedAt,
                    mode: OrderingMode.desc,
                  ),
                ]))
                .get();
        // 一次批量读取，而不是逐个会话查询；顺序排序由下面的 Dart 内分桶
        // 保留。
        final mcpRows = await (_db.select(
          _db.conversationMcpServerRows,
        )..orderBy([(t) => OrderingTerm.asc(t.ordinal)])).get();
        final mcpServerIdsByConversation = <String, List<String>>{};
        for (final mcpRow in mcpRows) {
          mcpServerIdsByConversation
              .putIfAbsent(mcpRow.conversationId, () => <String>[])
              .add(mcpRow.serverId);
        }
        final out = <Conversation>[];
        for (final row in rows) {
          out.add(
            await _conversationFromRow(
              row,
              includeMessageIds: false,
              mcpServerIds:
                  mcpServerIdsByConversation[row.id] ?? const <String>[],
            ),
          );
        }
        return out;
      },
      resultCount: (rows) => rows.length,
    );
  }

  Future<Conversation?> getConversation(String id) async {
    return _observer.measure(
      ChatDatabaseOperation.queryConversation,
      () async {
        final row = await (_db.select(
          _db.conversationRows,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (row == null) return null;
        return _conversationFromRow(row);
      },
      resultCount: (conversation) => conversation == null ? 0 : 1,
    );
  }

  Future<int> getMessageCount(String conversationId) async {
    return _observer.measure(ChatDatabaseOperation.queryMessageCount, () async {
      final count = _db.messageRows.id.count();
      final row =
          await (_db.selectOnly(_db.messageRows)
                ..addColumns([count])
                ..where(_db.messageRows.conversationId.equals(conversationId)))
              .getSingle();
      return row.read(count) ?? 0;
    }, resultCount: (count) => count);
  }

  Future<Map<String, int>> getMessageCountsByConversation() async {
    final conversationId = _db.messageRows.conversationId;
    final count = _db.messageRows.id.count();
    final rows =
        await (_db.selectOnly(_db.messageRows)
              ..addColumns([conversationId, count])
              ..groupBy([conversationId]))
            .get();
    return {
      for (final row in rows) row.read(conversationId)!: row.read(count) ?? 0,
    };
  }

  Future<int> getConversationCount() async {
    return _observer.measure(
      ChatDatabaseOperation.queryConversationCount,
      () async {
        final count = _db.conversationRows.id.count();
        final row = await (_db.selectOnly(
          _db.conversationRows,
        )..addColumns([count])).getSingle();
        return row.read(count) ?? 0;
      },
      resultCount: (count) => count,
    );
  }

  Future<int> getTotalMessageCount() async {
    return _observer.measure(
      ChatDatabaseOperation.queryTotalMessageCount,
      () async {
        final count = _db.messageRows.id.count();
        final row = await (_db.selectOnly(
          _db.messageRows,
        )..addColumns([count])).getSingle();
        return row.read(count) ?? 0;
      },
      resultCount: (count) => count,
    );
  }

  Future<int> getTextPartCount() async {
    return _observer.measure(
      ChatDatabaseOperation.queryTextPartCount,
      () async {
        final count = _db.messagePartRows.partId.count();
        final row =
            await (_db.selectOnly(_db.messagePartRows)
                  ..addColumns([count])
                  ..where(_db.messagePartRows.kind.equals('text')))
                .getSingle();
        return row.read(count) ?? 0;
      },
      resultCount: (count) => count,
    );
  }

  Future<int> getToolCallPartCount() async {
    return _observer.measure(
      ChatDatabaseOperation.queryToolCallPartCount,
      () async {
        final count = _db.messagePartRows.partId.count();
        final row =
            await (_db.selectOnly(_db.messagePartRows)
                  ..addColumns([count])
                  ..where(_db.messagePartRows.kind.equals('tool_call')))
                .getSingle();
        return row.read(count) ?? 0;
      },
      resultCount: (count) => count,
    );
  }

  Future<int> getImagePartCount() async {
    return _observer.measure(
      ChatDatabaseOperation.queryImagePartCount,
      () async {
        final count = _db.messagePartRows.partId.count();
        final row =
            await (_db.selectOnly(_db.messagePartRows)
                  ..addColumns([count])
                  ..where(_db.messagePartRows.kind.equals('image')))
                .getSingle();
        return row.read(count) ?? 0;
      },
      resultCount: (count) => count,
    );
  }

  Future<int> getFilePartCount() async {
    return _observer.measure(
      ChatDatabaseOperation.queryFilePartCount,
      () async {
        final count = _db.messagePartRows.partId.count();
        final row =
            await (_db.selectOnly(_db.messagePartRows)
                  ..addColumns([count])
                  ..where(_db.messagePartRows.kind.equals('file')))
                .getSingle();
        return row.read(count) ?? 0;
      },
      resultCount: (count) => count,
    );
  }

  /// 以有界分页严格校验每个已持久化附件的 payload。
  ///
  /// 这是迁移发布守卫，而不是正常的水合路径：
  /// 格式错误的行会使迁移失败，而不是变成 [MalformedPart]。
  Future<void> validateAttachmentPartPayloads({
    void Function(int processed, int total)? onProgress,
    @visibleForTesting void Function(int rowCount)? onMetadataWindow,
  }) async {
    final totalRow = await _db
        .customSelect(
          "SELECT COUNT(*) AS total FROM message_part_rows "
          "WHERE kind IN ('image', 'file');",
          readsFrom: {_db.messagePartRows},
        )
        .getSingle();
    final total = totalRow.read<int>('total');
    onProgress?.call(0, total);

    const metadataPageSize = 256;
    const payloadPageByteBudget = 2 * 1024 * 1024;
    var cursor = 0;
    var processed = 0;
    while (true) {
      final metadataRows = await _db
          .customSelect(
            'SELECT part_id, LENGTH(CAST(payload AS BLOB)) AS payload_bytes '
            'FROM message_part_rows '
            "WHERE kind IN ('image', 'file') AND part_id > ? "
            'ORDER BY part_id LIMIT ?;',
            variables: [
              Variable<int>(cursor),
              const Variable<int>(metadataPageSize),
            ],
            readsFrom: {_db.messagePartRows},
          )
          .get();
      if (metadataRows.isEmpty) break;
      onMetadataWindow?.call(metadataRows.length);

      var metadataIndex = 0;
      while (metadataIndex < metadataRows.length) {
        final partIds = <int>[];
        var selectedBytes = 0;
        while (metadataIndex < metadataRows.length) {
          final row = metadataRows[metadataIndex];
          final payloadBytes = row.read<int>('payload_bytes');
          if (partIds.isNotEmpty &&
              selectedBytes + payloadBytes > payloadPageByteBudget) {
            break;
          }
          partIds.add(row.read<int>('part_id'));
          selectedBytes += payloadBytes;
          metadataIndex += 1;
        }
        final placeholders = List.filled(partIds.length, '?').join(', ');
        final rows = await _db
            .customSelect(
              'SELECT part_id, revision_id, ordinal, kind, payload '
              'FROM message_part_rows WHERE part_id IN ($placeholders) '
              'ORDER BY part_id;',
              variables: [for (final partId in partIds) Variable<int>(partId)],
              readsFrom: {_db.messagePartRows},
            )
            .get();
        if (rows.length != partIds.length) {
          throw StateError(
            'Migration validation failed (attachment payload page incomplete): '
            'expected=${partIds.length} actual=${rows.length}.',
          );
        }
        for (final row in rows) {
          final partId = row.read<int>('part_id');
          final revisionId = row.read<String>('revision_id');
          final ordinal = row.read<int>('ordinal');
          final kind = row.read<String>('kind');
          final payload = row.read<String>('payload');
          try {
            MessagePart.fromRow(kind, payload);
          } on FormatException {
            throw StateError(
              'Migration validation failed (attachment part payload): '
              'revisionId=$revisionId ordinal=$ordinal kind=$kind.',
            );
          }
          cursor = partId;
          processed += 1;
        }
        onProgress?.call(processed, total);
      }
    }
  }

  /// 为 true 时，worker isolate 摘要路径会在 spawn 前抛出异常，以便测试
  /// 断言 Drift 回退仍能完成校验。
  @visibleForTesting
  bool debugForceTextPartDigestIsolateFailureForTest = false;

  /// 对每个 `kind='text'` 的 part payload 生成的顺序无关摘要。
  ///
  /// 每行贡献 `SHA-256(revision_id || NUL || payload)`，XOR 进 32 字节累加器。
  /// 当数据库文件路径可用时，扫描和 SHA-256 工作优先使用**专用 worker isolate**
  /// （不是 Drift SQL isolate，也不是 UI isolate）。该路径上的任何基础设施
  /// 故障（包括 [Isolate.spawn]）都会通过 [_observer] 记录，并透明回退到
  /// Drift 进程内扫描——只有调用点的摘要 *mismatch* 才应使迁移失败。
  /// [onProgress] 报告 SQLite `LENGTH` 字符数
  /// （总数和已处理使用同一单位）。
  Future<String> getTextPartContentDigest({
    void Function(int processedChars, int totalChars)? onProgress,
  }) async {
    return _observer.measure(
      ChatDatabaseOperation.queryTextPartContentDigest,
      () async {
        final file = _databaseFile;
        if (file != null) {
          final isolateSw = Stopwatch()..start();
          try {
            if (debugForceTextPartDigestIsolateFailureForTest) {
              throw StateError('digest_isolate_forced_failure');
            }
            return await _computeTextPartContentDigestInIsolate(
              file.path,
              onProgress: onProgress,
            );
          } catch (error) {
            isolateSw.stop();
            // 仅基础设施：摘要不匹配由调用方决定。
            _observer.recordFailure(
              operation: ChatDatabaseOperation.queryTextPartContentDigest,
              elapsedMicros: isolateSw.elapsedMicroseconds,
              error: error,
            );
          }
        }
        return _computeTextPartContentDigestViaDrift(onProgress: onProgress);
      },
    );
  }

  /// Drift 支持的扫描：SQL 在 Drift worker isolate 上执行，SHA-256 在调用方执行。
  /// 在没有文件路径时使用，并在专用 digest isolate 无法完成时作为回退。
  Future<String> _computeTextPartContentDigestViaDrift({
    void Function(int processedChars, int totalChars)? onProgress,
  }) async {
    final totalRow = await _db
        .customSelect(
          "SELECT COALESCE(SUM(LENGTH(payload)), 0) AS total "
          "FROM message_part_rows WHERE kind = 'text';",
          readsFrom: {_db.messagePartRows},
        )
        .getSingle();
    final totalChars = totalRow.read<int>('total');
    _emitTextPartDigestProgress(onProgress, 0, totalChars);

    final digest = Uint8List(32);
    const pageSize = 256;
    var cursor = 0;
    var processedChars = 0;
    while (true) {
      final rows = await _db
          .customSelect(
            'SELECT part_id, revision_id, payload, LENGTH(payload) AS '
            'payload_length FROM message_part_rows '
            "WHERE kind = 'text' AND part_id > ? "
            'ORDER BY part_id LIMIT ?;',
            variables: [Variable<int>(cursor), const Variable<int>(pageSize)],
            readsFrom: {_db.messagePartRows},
          )
          .get();
      if (rows.isEmpty) break;
      for (final row in rows) {
        mixTextPartContentDigest(
          digest,
          row.read<String>('revision_id'),
          row.read<String>('payload'),
        );
        processedChars += row.read<int>('payload_length');
        cursor = row.read<int>('part_id');
      }
      _emitTextPartDigestProgress(onProgress, processedChars, totalChars);
      if (rows.length < pageSize) break;
    }
    return textPartContentDigestHex(digest);
  }

  static Future<String> _computeTextPartContentDigestInIsolate(
    String databasePath, {
    void Function(int processedChars, int totalChars)? onProgress,
  }) async {
    final receivePort = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(_textPartContentDigestIsolateMain, (
        path: databasePath,
        sendPort: receivePort.sendPort,
      ), debugName: 'text_part_content_digest');
      await for (final message in receivePort) {
        if (message is! Map) {
          throw StateError('digest_isolate_protocol');
        }
        final type = message['type'];
        if (type == 'progress') {
          _emitTextPartDigestProgress(
            onProgress,
            message['processed'] as int,
            message['total'] as int,
          );
          continue;
        }
        if (type == 'result') {
          return message['digest'] as String;
        }
        if (type == 'error') {
          throw StateError(
            'Migration validation digest isolate failed: '
            '${message['error']}',
          );
        }
        throw StateError('digest_isolate_protocol');
      }
      throw StateError('digest_isolate_ended');
    } finally {
      receivePort.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  /// Worker 入口：拥有自己的只读 sqlite3 连接；绝不接触 UI isolate。
  /// 进度/结果映射通过 [args.sendPort] 发回。
  ///
  /// 进度对总数和已处理数都使用 SQLite `LENGTH(payload)`，这样
  /// emoji/代理对不会让进度条超过 100%。
  static void _textPartContentDigestIsolateMain(
    ({String path, SendPort sendPort}) args,
  ) {
    try {
      final database = sqlite.sqlite3.open(
        args.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        final totalChars =
            database
                    .select(
                      "SELECT COALESCE(SUM(LENGTH(payload)), 0) AS total "
                      "FROM message_part_rows WHERE kind = 'text';",
                    )
                    .single['total']
                as int;
        args.sendPort.send({
          'type': 'progress',
          'processed': 0,
          'total': totalChars,
        });

        final digest = Uint8List(32);
        const pageSize = 256;
        var cursor = 0;
        var processedChars = 0;
        while (true) {
          final rows = database.select(
            'SELECT part_id, revision_id, payload, LENGTH(payload) AS '
            'payload_length FROM message_part_rows '
            "WHERE kind = 'text' AND part_id > ? "
            'ORDER BY part_id LIMIT ?;',
            [cursor, pageSize],
          );
          if (rows.isEmpty) break;
          for (final row in rows) {
            mixTextPartContentDigest(
              digest,
              row['revision_id'] as String,
              row['payload'] as String,
            );
            processedChars += row['payload_length'] as int;
            cursor = row['part_id'] as int;
          }
          args.sendPort.send({
            'type': 'progress',
            'processed': processedChars,
            'total': totalChars,
          });
          if (rows.length < pageSize) break;
        }
        args.sendPort.send({
          'type': 'result',
          'digest': textPartContentDigestHex(digest),
        });
      } finally {
        database.close();
      }
    } catch (error, stackTrace) {
      args.sendPort.send({'type': 'error', 'error': '$error\n$stackTrace'});
    }
  }

  static void _emitTextPartDigestProgress(
    void Function(int processedChars, int totalChars)? onProgress,
    int processedChars,
    int totalChars,
  ) {
    if (onProgress == null) return;
    final safeTotal = totalChars < 0 ? 0 : totalChars;
    final safeProcessed = processedChars.clamp(0, safeTotal);
    onProgress(safeProcessed, safeTotal);
  }

  /// 将一个文本 part 混入顺序无关的 32 字节 XOR 摘要。
  static void mixTextPartContentDigest(
    Uint8List digest,
    String revisionId,
    String payload,
  ) {
    final hash = sha256.convert(utf8.encode('$revisionId\u0000$payload')).bytes;
    for (var i = 0; i < digest.length; i++) {
      digest[i] ^= hash[i];
    }
  }

  static String textPartContentDigestHex(Uint8List digest) {
    final buffer = StringBuffer();
    for (final byte in digest) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  @visibleForTesting
  Future<void> corruptTextPartPayloadForTest(
    String revisionId,
    String payload,
  ) async {
    await _db.customStatement(
      "UPDATE message_part_rows SET payload = ? "
      "WHERE revision_id = ? AND kind = 'text';",
      [payload, revisionId],
    );
  }

  @visibleForTesting
  Future<void> corruptPartPayloadForTest(
    String revisionId,
    String kind,
    String payload,
  ) async {
    await _db.customStatement(
      'UPDATE message_part_rows SET payload = ? '
      'WHERE revision_id = ? AND kind = ?;',
      [payload, revisionId, kind],
    );
  }

  @visibleForTesting
  Future<void> deleteTextPartsForTest(String revisionId) async {
    await _db.customStatement(
      "DELETE FROM message_part_rows "
      "WHERE revision_id = ? AND kind = 'text';",
      [revisionId],
    );
  }

  @visibleForTesting
  Future<void> deletePartsByKindForTest(String revisionId, String kind) async {
    await _db.customStatement(
      'DELETE FROM message_part_rows '
      'WHERE revision_id = ? AND kind = ?',
      [revisionId, kind],
    );
  }

  Future<int> getMessageIndex(String conversationId, String messageId) async {
    final row =
        await (_db.select(_db.messageRows)
              ..where(
                (t) =>
                    t.conversationId.equals(conversationId) &
                    t.id.equals(messageId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.messageOrder ?? -1;
  }

  Future<ChatMessage?> getMessage(String messageId) async {
    final row = await (_db.select(
      _db.messageRows,
    )..where((t) => t.id.equals(messageId))).getSingleOrNull();
    return row == null ? null : _messageFromRowWithParts(row);
  }

  Future<List<ChatMessage>> getMessagesRange(
    String conversationId, {
    required int start,
    required int limit,
  }) async {
    if (limit <= 0) return const <ChatMessage>[];
    final safeStart = start < 0 ? 0 : start;
    return _observer.measure(ChatDatabaseOperation.queryMessageRange, () async {
      final rows =
          await (_db.select(_db.messageRows)
                ..where((t) => t.conversationId.equals(conversationId))
                ..orderBy([(t) => OrderingTerm.asc(t.messageOrder)])
                ..limit(limit, offset: safeStart))
              .get();
      return _messagesFromRowsWithParts(rows);
    }, resultCount: (rows) => rows.length);
  }

  /// 加载模型上下文所需的选定线性消息版本。
  ///
  /// 版本折叠、截断索引应用、尾部限制和 part hydration 有意放在一条 SQL 语句中，
  /// 这样大型会话不会仅仅为了丢弃前缀而被物化。
  Future<List<ChatMessage>> getSelectedContextMessages(
    String conversationId, {
    required int truncateIndex,
    required int limit,
    String? throughRevisionId,
    bool includeFollowingAssistant = false,
  }) async {
    if (limit <= 0) return const <ChatMessage>[];
    return _observer.measure(ChatDatabaseOperation.queryMessageRange, () async {
      final result = await _db
          .customSelect(
            '''
            WITH group_rows AS (
              SELECT
                COALESCE(m.group_id, m.id) AS group_id,
                MIN(m.message_order) AS anchor_order,
                MAX(m.version) AS latest_version
              FROM message_rows m
              WHERE m.conversation_id = ?
              GROUP BY COALESCE(m.group_id, m.id)
            ),
            selections AS (
              SELECT j.key AS group_id, CAST(j.value AS INTEGER) AS version
              FROM conversation_rows c, json_each(c.version_selections_json) j
              WHERE c.id = ?
            ),
            ranked AS (
              SELECT
                m.id AS revision_id,
                g.group_id,
                m.role,
                g.anchor_order,
                ROW_NUMBER() OVER (
                  PARTITION BY g.group_id
                  ORDER BY
                    CASE
                      WHEN m.version = COALESCE(s.version, g.latest_version)
                      THEN 0 ELSE 1
                    END,
                    m.version DESC,
                    m.message_order DESC,
                    m.id DESC
                ) AS version_rank
              FROM group_rows g
              JOIN message_rows m
                ON m.conversation_id = ?
               AND COALESCE(m.group_id, m.id) = g.group_id
              LEFT JOIN selections s ON s.group_id = g.group_id
            ),
            ordered AS (
              SELECT
                revision_id,
                group_id,
                role,
                ROW_NUMBER() OVER (ORDER BY anchor_order, revision_id) - 1
                  AS logical_index,
                COUNT(*) OVER () AS total_count
              FROM ranked
              WHERE version_rank = 1
            ),
            target AS (
              SELECT COALESCE(group_id, id) AS group_id, role
              FROM message_rows
              WHERE conversation_id = ? AND id = ?
            ),
            cutoff AS (
              SELECT CASE
                WHEN ? AND target.role = 'user' THEN COALESCE(
                  (
                    SELECT MIN(candidate.logical_index)
                    FROM ordered candidate
                    WHERE candidate.logical_index > selected.logical_index
                      AND candidate.role = 'assistant'
                  ),
                  selected.logical_index
                )
                ELSE selected.logical_index
              END AS logical_index
              FROM target
              JOIN ordered selected ON selected.group_id = target.group_id
            ),
            limited AS (
              SELECT revision_id, logical_index
              FROM ordered
              WHERE logical_index >= CASE
                WHEN ? >= 0 AND ? <= total_count THEN ?
                ELSE 0
              END
                AND (
                  ? IS NULL OR
                  logical_index <= (SELECT logical_index FROM cutoff)
                )
              ORDER BY logical_index DESC
              LIMIT ?
            )
            SELECT
              m.*,
              p.part_id AS part_part_id,
              p.ordinal AS part_ordinal,
              p.kind AS part_kind,
              p.payload AS part_payload,
              p.created_at AS part_created_at,
              p.updated_at AS part_updated_at
            FROM limited l
            JOIN message_rows m ON m.id = l.revision_id
            LEFT JOIN message_part_rows p ON p.revision_id = m.id
            ORDER BY l.logical_index, p.ordinal;
            ''',
            variables: [
              Variable<String>(conversationId),
              Variable<String>(conversationId),
              Variable<String>(conversationId),
              Variable<String>(conversationId),
              Variable<String>(throughRevisionId ?? ''),
              Variable<bool>(includeFollowingAssistant),
              Variable<int>(truncateIndex),
              Variable<int>(truncateIndex),
              Variable<int>(truncateIndex),
              Variable<String>(throughRevisionId),
              Variable<int>(limit),
            ],
            readsFrom: {
              _db.conversationRows,
              _db.messageRows,
              _db.messagePartRows,
            },
          )
          .get();
      final rowsById = <String, MessageRow>{};
      final partsById = <String, List<MessagePartRow>>{};
      for (final row in result) {
        final message = _db.messageRows.map(row.data);
        rowsById.putIfAbsent(message.id, () => message);
        final ordinal = row.readNullable<int>('part_ordinal');
        if (ordinal == null) continue;
        partsById
            .putIfAbsent(message.id, () => <MessagePartRow>[])
            .add(
              MessagePartRow(
                partId: row.read<int>('part_part_id'),
                conversationId: message.conversationId,
                revisionId: message.id,
                ordinal: ordinal,
                kind: row.read<String>('part_kind'),
                payload: row.read<String>('part_payload'),
                createdAt: _dateTimeFromSqlite(row.data['part_created_at']),
                updatedAt: _dateTimeFromSqlite(row.data['part_updated_at']),
              ),
            );
      }
      return [
        for (final message in rowsById.values)
          _messageFromRow(message, authoritativeParts: partsById[message.id]),
      ];
    }, resultCount: (rows) => rows.length);
  }

  Future<int> getMaxMessageVersionForGroup(
    String conversationId,
    String groupId,
  ) async {
    final maxVersion = _db.messageRows.version.max();
    final row =
        await (_db.selectOnly(_db.messageRows)
              ..addColumns([maxVersion])
              ..where(
                _db.messageRows.conversationId.equals(conversationId) &
                    (_db.messageRows.groupId.equals(groupId) |
                        _db.messageRows.id.equals(groupId)),
              ))
            .getSingle();
    return row.read(maxVersion) ?? -1;
  }

  Future<List<ChatMessage>> getSelectedMessageProjections(
    String conversationId, {
    int summaryCharacters = 200,
  }) async {
    final safeSummaryCharacters = summaryCharacters.clamp(0, 200);
    final rows = await _db
        .customSelect(
          '''
          WITH group_rows AS (
            SELECT
              COALESCE(m.group_id, m.id) AS group_id,
              MIN(m.message_order) AS anchor_order,
              MAX(m.version) AS latest_version
            FROM message_rows m
            WHERE m.conversation_id = ?
            GROUP BY COALESCE(m.group_id, m.id)
          ),
          selections AS (
            SELECT j.key AS group_id, CAST(j.value AS INTEGER) AS version
            FROM conversation_rows c, json_each(c.version_selections_json) j
            WHERE c.id = ?
          ),
          ranked AS (
            SELECT
              m.id,
              m.role,
              m.timestamp,
              m.conversation_id,
              COALESCE(m.group_id, m.id) AS group_id,
              m.version,
              g.anchor_order,
              ROW_NUMBER() OVER (
                PARTITION BY g.group_id
                ORDER BY
                  CASE
                    WHEN m.version = COALESCE(s.version, g.latest_version)
                    THEN 0 ELSE 1
                  END,
                  m.version DESC,
                  m.message_order DESC,
                  m.id DESC
              ) AS version_rank
            FROM group_rows g
            JOIN message_rows m
              ON m.conversation_id = ?
             AND COALESCE(m.group_id, m.id) = g.group_id
            LEFT JOIN selections s ON s.group_id = g.group_id
          )
          SELECT
            ranked.id,
            ranked.role,
            (SELECT SUBSTR(p.payload, 1, ?)
               FROM message_part_rows p
              WHERE p.revision_id = ranked.id AND p.kind = 'text')
              AS content_summary,
            ranked.timestamp,
            ranked.conversation_id,
            ranked.group_id,
            ranked.version
          FROM ranked
          WHERE ranked.version_rank = 1
          ORDER BY ranked.anchor_order, ranked.group_id;
          ''',
          variables: [
            Variable<String>(conversationId),
            Variable<String>(conversationId),
            Variable<String>(conversationId),
            Variable<int>(safeSummaryCharacters),
          ],
          readsFrom: {
            _db.conversationRows,
            _db.messageRows,
            _db.messagePartRows,
          },
        )
        .get();
    return [
      for (final row in rows)
        ChatMessage(
          id: row.read<String>('id'),
          role: row.read<String>('role'),
          content: row.readNullable<String>('content_summary') ?? '',
          timestamp: _dateTimeFromSqlite(row.data['timestamp']),
          conversationId: row.read<String>('conversation_id'),
          groupId: row.read<String>('group_id'),
          version: row.read<int>('version'),
        ),
    ];
  }

  Future<Set<String>> getMessageIdsForGroups(
    String conversationId,
    Set<String> groupIds,
  ) async {
    if (groupIds.isEmpty) return const <String>{};
    final rows =
        await (_db.selectOnly(_db.messageRows)
              ..addColumns([_db.messageRows.id])
              ..where(
                _db.messageRows.conversationId.equals(conversationId) &
                    (_db.messageRows.groupId.isIn(groupIds) |
                        _db.messageRows.id.isIn(groupIds)),
              ))
            .get();
    return {for (final row in rows) row.read(_db.messageRows.id)!};
  }

  Future<LinearMessageWindow> loadLinearMessageWindow({
    required String conversationId,
    String? beforeRevisionId,
    String? afterRevisionId,
    String? aroundRevisionId,
    bool fromStart = false,
    int limit = 40,
  }) async {
    if (limit <= 0) {
      return const LinearMessageWindow(
        slots: <LinearMessageWindowSlot>[],
        totalSlotCount: 0,
        hasMoreBefore: false,
        hasMoreAfter: false,
      );
    }
    final cursorCount = <String?>[
      beforeRevisionId,
      afterRevisionId,
      aroundRevisionId,
    ].whereType<String>().length;
    if (cursorCount > 1 || (fromStart && cursorCount > 0)) {
      throw ArgumentError('Only one linear message cursor may be supplied.');
    }
    final cursorVariables = <Variable<Object>>[];
    late final String pageSql;
    if (fromStart) {
      pageSql = 'SELECT * FROM ordered ORDER BY logical_index LIMIT ?';
    } else if (beforeRevisionId != null || afterRevisionId != null) {
      final cursor = beforeRevisionId ?? afterRevisionId!;
      cursorVariables.add(Variable<String>(cursor));
      final comparison = beforeRevisionId != null ? '<' : '>';
      final direction = beforeRevisionId != null ? 'DESC' : 'ASC';
      pageSql =
          '''
        , target_group AS (
          SELECT COALESCE(group_id, id) AS group_id
          FROM message_rows WHERE conversation_id = ? AND id = ?
        ),
        target_index AS (
          SELECT logical_index FROM ordered
          WHERE group_id = (SELECT group_id FROM target_group)
        )
        SELECT * FROM ordered
        WHERE logical_index $comparison (SELECT logical_index FROM target_index)
        ORDER BY logical_index $direction LIMIT ?
      ''';
      cursorVariables.insert(0, Variable<String>(conversationId));
    } else if (aroundRevisionId != null) {
      cursorVariables
        ..add(Variable<String>(conversationId))
        ..add(Variable<String>(aroundRevisionId));
      pageSql = '''
        , target_group AS (
          SELECT COALESCE(group_id, id) AS group_id
          FROM message_rows WHERE conversation_id = ? AND id = ?
        ),
        target_index AS (
          SELECT logical_index FROM ordered
          WHERE group_id = (SELECT group_id FROM target_group)
        ),
        nearest AS (
          SELECT ordered.* FROM ordered, target_index
          ORDER BY ABS(ordered.logical_index - target_index.logical_index),
                   ordered.logical_index
          LIMIT ?
        )
        SELECT * FROM nearest ORDER BY logical_index
      ''';
    } else {
      pageSql = 'SELECT * FROM ordered ORDER BY logical_index DESC LIMIT ?';
    }
    final rows = await _db
        .customSelect(
          '''
          WITH group_rows AS (
            SELECT
              COALESCE(m.group_id, m.id) AS group_id,
              MIN(m.message_order) AS anchor_order,
              COUNT(*) AS version_count,
              MAX(m.version) AS latest_version
            FROM message_rows m
            WHERE m.conversation_id = ?
            GROUP BY COALESCE(m.group_id, m.id)
          ),
          selections AS (
            SELECT j.key AS group_id, CAST(j.value AS INTEGER) AS version
            FROM conversation_rows c, json_each(c.version_selections_json) j
            WHERE c.id = ?
          ),
          ranked AS (
            SELECT
              m.id AS revision_id,
              g.group_id,
              g.anchor_order,
              g.version_count,
              ROW_NUMBER() OVER (
                PARTITION BY g.group_id
                ORDER BY
                  CASE
                    WHEN m.version = COALESCE(s.version, g.latest_version)
                    THEN 0 ELSE 1
                  END,
                  m.version DESC,
                  m.message_order DESC,
                  m.id DESC
              ) AS version_rank
            FROM group_rows g
            JOIN message_rows m
              ON m.conversation_id = ?
             AND COALESCE(m.group_id, m.id) = g.group_id
            LEFT JOIN selections s ON s.group_id = g.group_id
          ),
          ordered AS (
            SELECT
              revision_id,
              group_id,
              version_count,
              ROW_NUMBER() OVER (
                ORDER BY anchor_order, group_id
              ) - 1 AS logical_index,
              COUNT(*) OVER () AS total_count
            FROM ranked
            WHERE version_rank = 1
          )
          $pageSql;
        ''',
          variables: [
            Variable<String>(conversationId),
            Variable<String>(conversationId),
            Variable<String>(conversationId),
            ...cursorVariables,
            Variable<int>(limit),
          ],
          readsFrom: {_db.conversationRows, _db.messageRows},
        )
        .get();
    final orderedRows =
        beforeRevisionId != null ||
            (!fromStart && afterRevisionId == null && aroundRevisionId == null)
        ? rows.reversed
        : rows;
    final slots = orderedRows
        .map(
          (row) => LinearMessageWindowSlot(
            groupId: row.read<String>('group_id'),
            revisionId: row.read<String>('revision_id'),
            versionCount: row.read<int>('version_count'),
            logicalIndex: row.read<int>('logical_index'),
          ),
        )
        .toList(growable: false);
    final total = rows.isEmpty ? 0 : rows.first.read<int>('total_count');
    return LinearMessageWindow(
      slots: slots,
      totalSlotCount: total,
      hasMoreBefore: slots.isNotEmpty && slots.first.logicalIndex > 0,
      hasMoreAfter: slots.isNotEmpty && slots.last.logicalIndex + 1 < total,
    );
  }

  Future<List<ChatMessage>> getMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return const <ChatMessage>[];
    return _observer.measure(
      ChatDatabaseOperation.queryMessagesByIds,
      () async {
        final rows = await (_db.select(
          _db.messageRows,
        )..where((t) => t.id.isIn(ids))).get();
        final messages = await _messagesFromRowsWithParts(rows);
        final byId = <String, ChatMessage>{
          for (final message in messages) message.id: message,
        };
        return [
          for (final id in ids)
            if (byId[id] != null) byId[id]!,
        ];
      },
      resultCount: (rows) => rows.length,
    );
  }

  Future<Map<String, int>> getFirstMessageIndicesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async {
    final ids = groupIds.toSet();
    if (ids.isEmpty) return const <String, int>{};
    final group = _db.messageRows.groupId;
    final minOrder = _db.messageRows.messageOrder.min();
    final messageId = _db.messageRows.id;
    final rows =
        await (_db.selectOnly(_db.messageRows)
              ..addColumns([group, messageId, minOrder])
              ..where(
                _db.messageRows.conversationId.equals(conversationId) &
                    (group.isIn(ids) | messageId.isIn(ids)),
              )
              ..groupBy([group, messageId]))
            .get();
    return {
      for (final row in rows)
        if ((row.read(group) ?? row.read(messageId)) != null &&
            row.read(minOrder) != null)
          (row.read(group) ?? row.read(messageId))!: row.read(minOrder)!,
    };
  }

  Future<List<ChatMessage>> getMessagesForGroups(
    String conversationId,
    Iterable<String> groupIds,
  ) async {
    final ids = groupIds.toSet();
    if (ids.isEmpty) return const <ChatMessage>[];
    return _observer.measure(
      ChatDatabaseOperation.queryMessagesForGroups,
      () async {
        final rows =
            await (_db.select(_db.messageRows)
                  ..where(
                    (t) =>
                        t.conversationId.equals(conversationId) &
                        (t.groupId.isIn(ids) | t.id.isIn(ids)),
                  )
                  ..orderBy([(t) => OrderingTerm.asc(t.messageOrder)]))
                .get();
        return _messagesFromRowsWithParts(rows);
      },
      resultCount: (rows) => rows.length,
    );
  }

  Future<List<String>> getMessageIds(String conversationId) async {
    return _observer.measure(ChatDatabaseOperation.queryMessageIds, () async {
      final rows =
          await (_db.selectOnly(_db.messageRows)
                ..addColumns([_db.messageRows.id])
                ..where(_db.messageRows.conversationId.equals(conversationId))
                ..orderBy([OrderingTerm.asc(_db.messageRows.messageOrder)]))
              .get();
      return rows
          .map((row) => row.read(_db.messageRows.id)!)
          .toList(growable: false);
    }, resultCount: (rows) => rows.length);
  }

  @Deprecated('legacy/test only; rewrites the complete conversation order')
  Future<void> updateMessageOrder(
    String conversationId,
    List<String> messageIds,
  ) async {
    await _db.transaction(() async {
      await _rewriteMessageOrder(conversationId, messageIds);
    });
  }

  /// 按 [tokens] 搜索会话。
  ///
  /// [conversationId] 将搜索限定到一个对话，
  /// [excludeConversationId] 则排除一个对话。两者都在 SQL 中应用，而不是由
  /// 调用方应用，因为候选 `LIMIT` 是全局的：匹配项排名低于截断值的对话
  /// 否则会被过滤到一条不剩。
  Future<List<ConversationSearchMatch>> searchConversationMatches({
    required List<String> tokens,
    int limit = 200,
    int candidateMultiplier = 8,
    bool includeAllRevisions = false,
    String? conversationId,
    String? excludeConversationId,
  }) {
    return _observer.measure(
      ChatDatabaseOperation.querySearch,
      () => _searchConversationMatches(
        tokens: tokens,
        limit: limit,
        candidateMultiplier: candidateMultiplier,
        includeAllRevisions: includeAllRevisions,
        conversationId: conversationId,
        excludeConversationId: excludeConversationId,
      ),
      resultCount: (rows) => rows.length,
    );
  }

  Future<List<ConversationSearchMatch>> _searchConversationMatches({
    required List<String> tokens,
    required int limit,
    required int candidateMultiplier,
    required bool includeAllRevisions,
    String? conversationId,
    String? excludeConversationId,
  }) async {
    final cleanTokens = tokens
        .map((token) => token.trim().toLowerCase())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (cleanTokens.isEmpty || limit <= 0) {
      return const <ConversationSearchMatch>[];
    }
    await _ensureMessageSearchFts();
    final useSubstringFallback = cleanTokens.any(_requiresCjkFallback);

    String escapeLike(String value) => value
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');

    final titleClauses = <String>[];
    final existsClauses = <String>[];
    final messageAnyClauses = <String>[];
    final titleArgs = <Object?>[];
    final existsArgs = <Object?>[];
    final messageArgs = <Object?>[];
    for (final token in cleanTokens) {
      final pattern = '%${escapeLike(token)}%';
      titleClauses.add('LOWER(c.title) LIKE ? ESCAPE \'\\\'');
      titleArgs.add(pattern);
      existsClauses.add('''
        EXISTS (
          SELECT 1 FROM message_rows mx
          WHERE mx.conversation_id = c.id
            AND mx.role IN ('user', 'assistant')
            AND EXISTS (
              SELECT 1 FROM message_part_rows px
              WHERE px.revision_id = mx.id
                AND px.kind = 'text'
                AND LOWER(px.payload) LIKE ? ESCAPE '\\'
            )
            ${includeAllRevisions ? '' : 'AND EXISTS (SELECT 1 FROM visible_groups visible WHERE visible.conversation_id = mx.conversation_id AND visible.group_id = COALESCE(mx.group_id, mx.id) AND visible.selected_version = mx.version)'}
        )
        ''');
      existsArgs.add(pattern);
      if (useSubstringFallback) {
        messageAnyClauses.add('''
          EXISTS (
            SELECT 1 FROM message_part_rows px
            WHERE px.revision_id = m.id
              AND px.kind = 'text'
              AND LOWER(px.payload) LIKE ? ESCAPE '\\'
          )
          ''');
        messageArgs.add(pattern);
      }
    }
    final ftsQuery = cleanTokens
        .map((token) => '"${token.replaceAll('"', '""')}"')
        .join(' AND ');
    if (!useSubstringFallback) {
      messageAnyClauses.add(
        'm.id IN (SELECT revision_id FROM message_search_fts '
        'WHERE payload MATCH ?)',
      );
      messageArgs.add(ftsQuery);
      existsClauses
        ..clear()
        ..add('''
        EXISTS (
          SELECT 1 FROM message_search_fts fx
          WHERE fx.conversation_id = c.id AND fx.payload MATCH ?
            ${includeAllRevisions ? '' : 'AND EXISTS (SELECT 1 FROM visible_groups visible INNER JOIN message_rows selected ON selected.id = fx.revision_id WHERE visible.conversation_id = selected.conversation_id AND visible.group_id = COALESCE(selected.group_id, selected.id) AND visible.selected_version = selected.version)'}
        )
        ''');
      existsArgs
        ..clear()
        ..add(ftsQuery);
    }

    // 与匹配谓词同时应用，以便候选 LIMIT 只用于调用方实际可用的行。
    final scopeArgs = <String>[];
    var scopeSql = '';
    if (conversationId != null && conversationId.isNotEmpty) {
      scopeSql = 'AND c.id = ?';
      scopeArgs.add(conversationId);
    } else if (excludeConversationId != null &&
        excludeConversationId.isNotEmpty) {
      scopeSql = 'AND c.id <> ?';
      scopeArgs.add(excludeConversationId);
    }

    final candidateLimit = (limit * candidateMultiplier)
        .clamp(limit, 2000)
        .toInt();
    final rows = await _db
        .customSelect(
          '''
      WITH selections AS (
        SELECT c.id AS conversation_id, j.key AS group_id,
               CAST(j.value AS INTEGER) AS selected_version
        FROM conversation_rows c, json_each(c.version_selections_json) j
      ), visible_groups AS (
        SELECT
          m.conversation_id,
          COALESCE(m.group_id, m.id) AS group_id,
          MAX(m.version) AS max_version,
          COALESCE(
            MAX(CASE
              WHEN m.version = s.selected_version THEN m.version
            END),
            MAX(m.version)
          ) AS selected_version
        FROM message_rows m
        LEFT JOIN selections s
          ON s.conversation_id = m.conversation_id
         AND s.group_id = COALESCE(m.group_id, m.id)
        GROUP BY m.conversation_id, COALESCE(m.group_id, m.id)
      )
      SELECT
        c.id AS conversation_id,
        c.title AS conversation_title,
        c.updated_at AS updated_at,
        m.id AS message_id,
        (
          SELECT px.payload
          FROM message_part_rows px
          WHERE px.revision_id = m.id AND px.kind = 'text'
          ORDER BY px.ordinal
          LIMIT 1
        ) AS message_content,
        m.role AS message_role,
        m.group_id AS group_id,
        m.version AS version,
        m.message_order AS message_order,
        (
          SELECT visible.selected_version
          FROM visible_groups visible
          WHERE visible.conversation_id = m.conversation_id
            AND visible.group_id = COALESCE(m.group_id, m.id)
          LIMIT 1
        ) AS selected_version,
        (
          SELECT visible.max_version
          FROM visible_groups visible
          WHERE visible.conversation_id = m.conversation_id
            AND visible.group_id = COALESCE(m.group_id, m.id)
          LIMIT 1
        ) AS max_version
      FROM conversation_rows c
      LEFT JOIN message_rows m
        ON m.conversation_id = c.id
        AND m.role IN ('user', 'assistant')
        AND (${messageAnyClauses.join(' OR ')})
        ${includeAllRevisions ? '' : 'AND EXISTS (SELECT 1 FROM visible_groups visible WHERE visible.conversation_id = m.conversation_id AND visible.group_id = COALESCE(m.group_id, m.id) AND visible.selected_version = m.version)'}
      WHERE ((${titleClauses.join(' AND ')}) OR (${existsClauses.join(' AND ')}))
        $scopeSql
      ORDER BY c.updated_at DESC, m.message_order ASC
      LIMIT ?
      ''',
          variables: [
            ...messageArgs.map((value) => Variable<String>(value! as String)),
            ...titleArgs.map((value) => Variable<String>(value! as String)),
            ...existsArgs.map((value) => Variable<String>(value! as String)),
            ...scopeArgs.map(Variable<String>.new),
            Variable<int>(candidateLimit),
          ],
        )
        .get();

    return rows
        .map((row) {
          final groupId = row.readNullable<String>('group_id');
          final messageId = row.readNullable<String>('message_id');
          final effectiveGroupId = groupId ?? messageId;
          final selectedVersion = row.readNullable<int>('selected_version');
          return ConversationSearchMatch(
            conversationId: row.read<String>('conversation_id'),
            conversationTitle: row.read<String>('conversation_title'),
            updatedAt: _dateTimeFromSqlite(row.read<int>('updated_at')),
            versionSelections:
                effectiveGroupId == null || selectedVersion == null
                ? const {}
                : {effectiveGroupId: selectedVersion},
            messageId: messageId,
            messageContent: row.readNullable<String>('message_content'),
            messageRole: row.readNullable<String>('message_role'),
            groupId: groupId,
            version: row.readNullable<int>('version'),
            maxVersion: row.readNullable<int>('max_version'),
          );
        })
        .toList(growable: false);
  }

  Future<ChatStatsAggregate> queryStatsAggregate({
    required DateTime? rangeStart,
    required DateTime? rangeEndExclusive,
    required DateTime heatmapStart,
    required DateTime trendStart,
    required DateTime trendEndExclusive,
  }) async {
    final start = rangeStart?.microsecondsSinceEpoch;
    final end = rangeEndExclusive?.microsecondsSinceEpoch;
    final rangeClause = <String>[
      if (start != null) 'm.timestamp >= ?',
      if (end != null) 'm.timestamp < ?',
    ].join(' AND ');
    final rangeWhere = rangeClause.isEmpty ? '' : 'AND $rangeClause';
    final rangeVariables = <Variable>[
      if (start != null) Variable<int>(start),
      if (end != null) Variable<int>(end),
    ];
    final conversationRangeClause = <String>[
      if (start != null) 'c.created_at >= ?',
      if (end != null) 'c.created_at < ?',
    ].join(' AND ');

    final summary = await _db
        .customSelect(
          '''
      SELECT
        (SELECT COUNT(*) FROM conversation_rows c
          ${conversationRangeClause.isEmpty ? '' : 'WHERE $conversationRangeClause'}) AS conversations,
        COUNT(*) AS messages,
        COALESCE(SUM(prompt_tokens), 0) AS input_tokens,
        COALESCE(SUM(completion_tokens), 0) AS output_tokens,
        COALESCE(SUM(cached_tokens), 0) AS cached_tokens
      FROM message_rows m WHERE 1 = 1 $rangeWhere;
    ''',
          variables: [...rangeVariables, ...rangeVariables],
        )
        .getSingle();

    final heatmapRows = await _db
        .customSelect(
          '''
      SELECT strftime('%Y-%m-%d', m.timestamp / 1000000.0,
          'unixepoch', 'localtime') AS day,
        COUNT(*) AS message_count
      FROM message_rows m
      WHERE m.timestamp >= ?
      GROUP BY day ORDER BY day;
    ''',
          variables: [Variable<int>(heatmapStart.microsecondsSinceEpoch)],
        )
        .get();

    final trendRows = await _db
        .customSelect(
          '''
      SELECT strftime('%Y-%m-%d', m.timestamp / 1000000.0,
          'unixepoch', 'localtime') AS day,
        COALESCE(NULLIF(TRIM(m.provider_id), ''), '_unknown') AS provider_id,
        COUNT(*) AS activity_count,
        COALESCE(SUM(m.prompt_tokens), 0) AS input_tokens,
        COALESCE(SUM(m.completion_tokens), 0) AS output_tokens,
        COALESCE(SUM(m.cached_tokens), 0) AS cached_tokens,
        COALESCE(SUM(CASE WHEN COALESCE(m.prompt_tokens, 0) = 0
          AND COALESCE(m.completion_tokens, 0) = 0
          THEN COALESCE(m.total_tokens, 0) ELSE 0 END), 0) AS uncategorized_tokens
      FROM message_rows m
      WHERE m.timestamp >= ? AND m.timestamp < ?
        AND (NULLIF(TRIM(m.provider_id), '') IS NOT NULL
          OR COALESCE(m.prompt_tokens, 0) != 0
          OR COALESCE(m.completion_tokens, 0) != 0
          OR COALESCE(m.cached_tokens, 0) != 0
          OR COALESCE(m.total_tokens, 0) != 0)
      GROUP BY day, provider_id ORDER BY day, provider_id;
    ''',
          variables: [
            Variable<int>(trendStart.microsecondsSinceEpoch),
            Variable<int>(trendEndExclusive.microsecondsSinceEpoch),
          ],
        )
        .get();

    final modelRows = await _db.customSelect('''
      SELECT m.model_id AS id, MIN(m.provider_id) AS provider_id,
        COUNT(*) AS item_count
      FROM message_rows m
      WHERE NULLIF(TRIM(m.model_id), '') IS NOT NULL $rangeWhere
      GROUP BY m.model_id ORDER BY item_count DESC, id;
    ''', variables: rangeVariables).get();
    final topicRows = await _db.customSelect('''
      SELECT c.id AS id, c.title AS label, COUNT(*) AS item_count
      FROM message_rows m
      JOIN conversation_rows c ON c.id = m.conversation_id
      WHERE 1 = 1 $rangeWhere
      GROUP BY c.id, c.title ORDER BY item_count DESC, c.id;
    ''', variables: rangeVariables).get();
    final conversationRange = <String>[
      if (start != null) 'created_at >= ?',
      if (end != null) 'created_at < ?',
    ].join(' AND ');
    final assistantRows = await _db.customSelect('''
      SELECT COALESCE(NULLIF(TRIM(assistant_id), ''), '_default') AS id,
        COUNT(*) AS item_count
      FROM conversation_rows
      ${conversationRange.isEmpty ? '' : 'WHERE $conversationRange'}
      GROUP BY id ORDER BY item_count DESC, id;
    ''', variables: rangeVariables).get();

    return ChatStatsAggregate(
      conversations: summary.read<int>('conversations'),
      totals: ChatStatsTotals(
        messages: summary.read<int>('messages'),
        inputTokens: summary.read<int>('input_tokens'),
        outputTokens: summary.read<int>('output_tokens'),
        cachedTokens: summary.read<int>('cached_tokens'),
      ),
      heatmap: [
        for (final row in heatmapRows)
          ChatStatsDayCount(
            day: DateTime.parse(row.read<String>('day')),
            count: row.read<int>('message_count'),
          ),
      ],
      trend: [
        for (final row in trendRows)
          ChatStatsTrendBucket(
            day: DateTime.parse(row.read<String>('day')),
            providerId: row.read<String>('provider_id'),
            activityCount: row.read<int>('activity_count'),
            inputTokens: row.read<int>('input_tokens'),
            outputTokens: row.read<int>('output_tokens'),
            cachedTokens: row.read<int>('cached_tokens'),
            uncategorizedTokens: row.read<int>('uncategorized_tokens'),
          ),
      ],
      models: [
        for (final row in modelRows)
          ChatStatsRank(
            id: row.read<String>('id'),
            label: row.read<String>('id'),
            count: row.read<int>('item_count'),
            providerId: row.readNullable<String>('provider_id'),
          ),
      ],
      assistants: [
        for (final row in assistantRows)
          ChatStatsRank(
            id: row.read<String>('id'),
            label: row.read<String>('id'),
            count: row.read<int>('item_count'),
          ),
      ],
      topics: [
        for (final row in topicRows)
          ChatStatsRank(
            id: row.read<String>('id'),
            label: row.read<String>('label'),
            count: row.read<int>('item_count'),
          ),
      ],
    );
  }

  Future<void> registerAsset({
    required String id,
    required String contentHash,
    required String path,
    required int byteSize,
    int? width,
    int? height,
    String? thumbnailPath,
    DateTime? createdAt,
  }) async {
    final timestamp = (createdAt ?? DateTime.now()).microsecondsSinceEpoch;
    await _db.customStatement(
      '''
      INSERT INTO asset_rows(
        id, content_hash, path, byte_size, width, height, thumbnail_path,
        created_at, last_referenced_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        content_hash = excluded.content_hash,
        path = excluded.path,
        byte_size = excluded.byte_size,
        width = excluded.width,
        height = excluded.height,
        thumbnail_path = excluded.thumbnail_path;
    ''',
      [
        id,
        contentHash,
        path,
        byteSize,
        width,
        height,
        thumbnailPath,
        timestamp,
        timestamp,
      ],
    );
  }

  Future<void> linkMessageAsset({
    required String conversationId,
    required String revisionId,
    required String assetId,
    required String kind,
  }) async {
    await _db.transaction(() async {
      await _db.customStatement(
        '''
        INSERT OR IGNORE INTO message_asset_rows(
          conversation_id, revision_id, asset_id, kind
        ) VALUES (?, ?, ?, ?);
      ''',
        [conversationId, revisionId, assetId, kind],
      );
      await _db.customStatement(
        'UPDATE asset_rows SET last_referenced_at = '
        'MAX(last_referenced_at + 1, ?) WHERE id = ?;',
        [DateTime.now().microsecondsSinceEpoch, assetId],
      );
      await _db.customStatement(
        'DELETE FROM asset_gc_rows WHERE asset_id = ?;',
        [assetId],
      );
    });
  }

  Future<void> replaceMessageAssetReferences({
    required String conversationId,
    required String revisionId,
    required List<MessageAssetRegistration> assets,
  }) async {
    await _db.transaction(() async {
      await _db.customStatement(
        'DELETE FROM message_asset_rows WHERE revision_id = ?;',
        [revisionId],
      );
      final now = DateTime.now().microsecondsSinceEpoch;
      for (final asset in assets) {
        await _db.customStatement(
          '''
          INSERT INTO asset_rows(
            id, content_hash, path, byte_size, width, height, thumbnail_path,
            created_at, last_referenced_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            byte_size = excluded.byte_size,
            width = excluded.width,
            height = excluded.height,
            thumbnail_path = excluded.thumbnail_path,
            last_referenced_at = MAX(
              asset_rows.last_referenced_at + 1,
              excluded.last_referenced_at
            );
        ''',
          [
            asset.assetId,
            asset.contentHash,
            asset.path,
            asset.byteSize,
            asset.width,
            asset.height,
            asset.thumbnailPath,
            now,
            now,
          ],
        );
        await _db.customStatement(
          '''
          INSERT OR IGNORE INTO message_asset_rows(
            conversation_id, revision_id, asset_id, kind
          ) VALUES (?, ?, ?, ?);
        ''',
          [conversationId, revisionId, asset.assetId, asset.kind],
        );
        await _db.customStatement(
          'DELETE FROM asset_gc_rows WHERE asset_id = ?;',
          [asset.assetId],
        );
      }
      await _db.customStatement(
        'DELETE FROM asset_reference_dirty_rows WHERE revision_id = ?;',
        [revisionId],
      );
    });
  }

  Future<void> unlinkMessageAsset({
    required String revisionId,
    required String assetId,
  }) async {
    await _db.customStatement(
      'DELETE FROM message_asset_rows WHERE revision_id = ? AND asset_id = ?;',
      [revisionId, assetId],
    );
  }

  Future<int> scheduleUnreferencedAssetGc({required DateTime notBefore}) async {
    await _db.customStatement(
      '''
      INSERT OR IGNORE INTO asset_gc_rows(
        asset_id, not_before, attempts, generation
      )
      SELECT a.id, ?, 0, a.last_referenced_at FROM asset_rows a
      WHERE NOT EXISTS (
        SELECT 1 FROM message_asset_rows r WHERE r.asset_id = a.id
      );
    ''',
      [notBefore.microsecondsSinceEpoch],
    );
    final row = await _db
        .customSelect('SELECT changes() AS changed;')
        .getSingle();
    return row.read<int>('changed');
  }

  Future<List<AssetGcCandidate>> claimAssetGc({
    required DateTime now,
    int limit = 50,
    @visibleForTesting int maxScan = 500,
  }) async {
    if (limit <= 0) return const <AssetGcCandidate>[];
    return _db.transaction(() async {
      // 用 keyset 分页候选行，然后每页询问 SQLite 一次，是否有 dirty text 引用这些
      // 路径（基于集合的 instr）。绝不把完整 dirty payload 语料拉入 Dart。
      final ids = <String>[];
      final protectedIds = <String>[];
      var scanned = 0;
      const pageSize = 50;
      int? cursorNotBefore;
      String? cursorAssetId;

      while (ids.length < limit && scanned < maxScan) {
        final List<QueryRow> dueRows;
        if (cursorNotBefore == null) {
          dueRows = await _db
              .customSelect(
                '''
            SELECT g.asset_id, a.path, g.not_before FROM asset_gc_rows g
            JOIN asset_rows a ON a.id = g.asset_id
            WHERE g.not_before <= ?
              AND NOT EXISTS (
                SELECT 1 FROM message_asset_rows r
                WHERE r.asset_id = g.asset_id
              )
            ORDER BY g.not_before, g.asset_id
            LIMIT ?;
          ''',
                variables: [
                  Variable<int>(now.microsecondsSinceEpoch),
                  Variable<int>(pageSize),
                ],
              )
              .get();
        } else {
          dueRows = await _db
              .customSelect(
                '''
            SELECT g.asset_id, a.path, g.not_before FROM asset_gc_rows g
            JOIN asset_rows a ON a.id = g.asset_id
            WHERE g.not_before <= ?
              AND NOT EXISTS (
                SELECT 1 FROM message_asset_rows r
                WHERE r.asset_id = g.asset_id
              )
              AND (
                g.not_before > ?
                OR (g.not_before = ? AND g.asset_id > ?)
              )
            ORDER BY g.not_before, g.asset_id
            LIMIT ?;
          ''',
                variables: [
                  Variable<int>(now.microsecondsSinceEpoch),
                  Variable<int>(cursorNotBefore),
                  Variable<int>(cursorNotBefore),
                  Variable<String>(cursorAssetId!),
                  Variable<int>(pageSize),
                ],
              )
              .get();
        }
        if (dueRows.isEmpty) break;

        final page = <({String id, String path, int notBefore})>[];
        for (final row in dueRows) {
          if (scanned >= maxScan) break;
          scanned += 1;
          final assetId = row.read<String>('asset_id');
          final path = row.read<String>('path');
          final notBefore = row.read<int>('not_before');
          cursorNotBefore = notBefore;
          cursorAssetId = assetId;
          page.add((id: assetId, path: path, notBefore: notBefore));
        }
        if (page.isEmpty) break;

        final protected = await _dirtyPartProtectedAssetIds(page);
        for (final item in page) {
          if (ids.length >= limit) break;
          if (protected.contains(item.id)) {
            protectedIds.add(item.id);
            continue;
          }
          ids.add(item.id);
        }
        if (dueRows.length < pageSize) break;
      }

      if (protectedIds.isNotEmpty) {
        final deferUntil = now
            .add(const Duration(hours: 6))
            .microsecondsSinceEpoch;
        final placeholders = List.filled(protectedIds.length, '?').join(',');
        await _db.customStatement(
          'UPDATE asset_gc_rows SET not_before = ? '
          'WHERE asset_id IN ($placeholders);',
          [deferUntil, ...protectedIds],
        );
      }

      if (ids.isEmpty) return const <AssetGcCandidate>[];
      for (final id in ids) {
        await _db.customStatement(
          'UPDATE asset_gc_rows SET attempts = attempts + 1, '
          'generation = generation + 1 WHERE asset_id = ?;',
          [id],
        );
      }
      final rows = await _db.customSelect(
        '''
            SELECT a.id, a.path, a.thumbnail_path, a.byte_size, g.generation
            FROM asset_gc_rows g JOIN asset_rows a ON a.id = g.asset_id
            WHERE a.id IN (${List.filled(ids.length, '?').join(',')})
            ORDER BY g.not_before, a.id;
          ''',
        variables: ids.map(Variable<String>.new).toList(growable: false),
      ).get();
      return [
        for (final row in rows)
          AssetGcCandidate(
            assetId: row.read<String>('id'),
            path: row.read<String>('path'),
            thumbnailPath: row.readNullable<String>('thumbnail_path'),
            byteSize: row.read<int>('byte_size'),
            generation: row.read<int>('generation'),
          ),
      ];
    });
  }

  /// 对候选页面进行基于集合的脏 part 保护。
  ///
  /// 一个从未注册的畸形附件，其原始 payload 不再包含其路径（例如非字符串 `uri`），
  /// 无法在此受到保护，可能被收集。我们接受这一残余损失窗口，
  /// 因为全局畸形部分联锁会让一行损坏数据无限期禁用所有资产 GC，
  /// 导致磁盘无界增长。
  Future<Set<String>> _dirtyPartProtectedAssetIds(
    List<({String id, String path, int notBefore})> page,
  ) async {
    if (page.isEmpty) return const <String>{};
    final tuples = List.filled(page.length, '(?, ?, ?, ?, ?)').join(', ');
    final variables = <Variable<Object>>[];
    for (final item in page) {
      final pathForm = item.path.isEmpty ? ' ' : item.path;
      final altForm = _alternateAssetPathForm(pathForm);
      final jsonPathForm = _jsonEscapedPathForm(pathForm);
      final jsonAltForm = _jsonEscapedPathForm(altForm);
      variables
        ..add(Variable<String>(item.id))
        ..add(Variable<String>(pathForm))
        ..add(Variable<String>(altForm))
        ..add(Variable<String>(jsonPathForm))
        ..add(Variable<String>(jsonAltForm));
    }
    final rows = await _db.customSelect('''
          WITH candidates(
            asset_id, path_form, alt_form, json_path_form, json_alt_form
          ) AS (
            VALUES $tuples
          )
          SELECT DISTINCT c.asset_id AS asset_id
          FROM candidates c
          WHERE EXISTS (
            SELECT 1
            FROM asset_reference_dirty_rows d
            JOIN message_part_rows p ON p.revision_id = d.revision_id
            WHERE p.kind IN ('text', 'image', 'file')
              AND (
                instr(p.payload, c.path_form) > 0
                OR instr(p.payload, c.alt_form) > 0
                OR instr(p.payload, c.json_path_form) > 0
                OR instr(p.payload, c.json_alt_form) > 0
              )
          );
        ''', variables: variables).get();
    return {for (final row in rows) row.read<String>('asset_id')};
  }

  Future<bool> isAssetGcClaimStillValid(AssetGcCandidate candidate) async {
    final pathForm = candidate.path.isEmpty ? ' ' : candidate.path;
    final altForm = _alternateAssetPathForm(pathForm);
    final jsonPathForm = _jsonEscapedPathForm(pathForm);
    final jsonAltForm = _jsonEscapedPathForm(altForm);
    final row = await _db
        .customSelect(
          '''
          SELECT 1 AS valid FROM asset_gc_rows g
          WHERE g.asset_id = ? AND g.generation = ?
            AND NOT EXISTS (
              SELECT 1 FROM message_asset_rows r
              WHERE r.asset_id = g.asset_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM asset_reference_dirty_rows d
              JOIN message_part_rows p ON p.revision_id = d.revision_id
              WHERE p.kind IN ('text', 'image', 'file')
                AND (
                  instr(p.payload, ?) > 0 OR instr(p.payload, ?) > 0
                  OR instr(p.payload, ?) > 0 OR instr(p.payload, ?) > 0
                )
            )
          LIMIT 1;
        ''',
          variables: [
            Variable<String>(candidate.assetId),
            Variable<int>(candidate.generation),
            Variable<String>(pathForm),
            Variable<String>(altForm),
            Variable<String>(jsonPathForm),
            Variable<String>(jsonAltForm),
          ],
        )
        .getSingleOrNull();
    return row != null;
  }

  Future<bool> completeAssetGc({
    required String assetId,
    required int expectedGeneration,
    required String path,
    DateTime? completedAt,
  }) async {
    // 脏 part 保护必须匹配任一存储形式。绝不要传入 ''——
    // instr(x, '') 永远为 true，会让 GC 永久停滞。
    final pathForm = path.isEmpty ? ' ' : path;
    final altForm = _alternateAssetPathForm(pathForm);
    final jsonPathForm = _jsonEscapedPathForm(pathForm);
    final jsonAltForm = _jsonEscapedPathForm(altForm);
    return _db.transaction(() async {
      final claim = await _db
          .customSelect(
            '''
            SELECT 1 AS valid FROM asset_gc_rows g
            WHERE g.asset_id = ? AND g.generation = ?
              AND NOT EXISTS (
                SELECT 1 FROM message_asset_rows r
                WHERE r.asset_id = g.asset_id
              )
              AND NOT EXISTS (
                SELECT 1 FROM asset_reference_dirty_rows d
                JOIN message_part_rows p ON p.revision_id = d.revision_id
                WHERE p.kind IN ('text', 'image', 'file')
                  AND (
                    instr(p.payload, ?) > 0 OR instr(p.payload, ?) > 0
                    OR instr(p.payload, ?) > 0 OR instr(p.payload, ?) > 0
                  )
              )
            LIMIT 1;
          ''',
            variables: [
              Variable<String>(assetId),
              Variable<int>(expectedGeneration),
              Variable<String>(pathForm),
              Variable<String>(altForm),
              Variable<String>(jsonPathForm),
              Variable<String>(jsonAltForm),
            ],
          )
          .getSingleOrNull();
      if (claim == null) return false;
      await _db.customStatement('DELETE FROM asset_rows WHERE id = ?;', [
        assetId,
      ]);
      final changed =
          (await _db.customSelect('SELECT changes() AS changed;').getSingle())
              .read<int>('changed');
      if (changed == 0) return false;
      await _db.customStatement(
        '''
        INSERT INTO gc_audit_rows(kind, entity_id, completed_at)
        VALUES ('asset', ?, ?);
      ''',
        [assetId, (completedAt ?? DateTime.now()).microsecondsSinceEpoch],
      );
      return true;
    });
  }

  bool _requiresCjkFallback(String token) {
    return RegExp(
      r'[\u3400-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]',
    ).hasMatch(token);
  }

  Future<void> _ensureMessageSearchFts() async {
    if (_messageSearchFtsReady) return;
    final existing = await _db
        .customSelect(
          "SELECT sql FROM sqlite_master "
          "WHERE type = 'table' AND name = 'message_search_fts';",
        )
        .getSingleOrNull();
    final existingSql = existing?.readNullable<String>('sql') ?? '';
    final externalContent =
        existingSql.contains("content='message_part_rows'") &&
        existingSql.contains("content_rowid='part_id'");
    if (existing != null && !externalContent) {
      await _db.transaction(() async {
        await _db.customStatement(
          'DROP TRIGGER IF EXISTS message_search_fts_insert;',
        );
        await _db.customStatement(
          'DROP TRIGGER IF EXISTS message_search_fts_delete;',
        );
        await _db.customStatement(
          'DROP TRIGGER IF EXISTS message_search_fts_update;',
        );
        await _db.customStatement(
          'DROP TRIGGER IF EXISTS message_search_fts_finalize;',
        );
        await _db.customStatement(
          'DROP TRIGGER IF EXISTS message_search_fts_unindex;',
        );
        await _db.customStatement(
          'DROP TRIGGER IF EXISTS message_search_fts_message_delete;',
        );
        await _db.customStatement('DROP TABLE message_search_fts;');
      });
    }
    final needsRebuild = existing == null || !externalContent;
    await _db.customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS message_search_fts USING fts5(
        revision_id UNINDEXED,
        conversation_id UNINDEXED,
        payload,
        content='message_part_rows',
        content_rowid='part_id',
        tokenize = 'unicode61 remove_diacritics 2'
      );
    ''');
    // 只索引已完成的文本 part。使用正向 EXISTS（而不是 NOT EXISTS），这样
    // 比其 message_rows 父行提前插入的延迟 part 会保持不在索引中，直到后续
    // finalize/rebuild 路径能够看到 is_streaming=0。
    await _db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_search_fts_insert
      AFTER INSERT ON message_part_rows
      WHEN new.kind = 'text'
       AND EXISTS (
         SELECT 1 FROM message_rows m
         WHERE m.id = new.revision_id AND m.is_streaming = 0
       )
      BEGIN
        INSERT INTO message_search_fts(
          rowid, revision_id, conversation_id, payload
        ) VALUES (
          new.part_id, new.revision_id, new.conversation_id, new.payload
        );
      END;
    ''');
    // 与插入对称：只反向删除已索引的 posting。
    // 在 ON DELETE CASCADE 期间，父 message_rows 行已经消失，因此
    // 此 WHEN 失败——message_search_fts_message_delete 覆盖该路径。
    await _db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_search_fts_delete
      AFTER DELETE ON message_part_rows
      WHEN old.kind = 'text'
       AND EXISTS (
         SELECT 1 FROM message_rows m
         WHERE m.id = old.revision_id AND m.is_streaming = 0
       )
      BEGIN
        INSERT INTO message_search_fts(
          message_search_fts, rowid, revision_id, conversation_id, payload
        ) VALUES (
          'delete', old.part_id, old.revision_id, old.conversation_id,
          old.payload
        );
      END;
    ''');
    // 极少数直接重写 payload 的情况（例如沙箱路径迁移）。常规的
    // checkpoint 改为删除并重新插入 parts。
    await _db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_search_fts_update
      AFTER UPDATE OF payload, conversation_id, kind ON message_part_rows
      WHEN (old.kind = 'text' OR new.kind = 'text')
       AND EXISTS (
         SELECT 1 FROM message_rows m
         WHERE m.id = new.revision_id AND m.is_streaming = 0
       )
      BEGIN
        INSERT INTO message_search_fts(
          message_search_fts, rowid, revision_id, conversation_id, payload
        )
        SELECT
          'delete', old.part_id, old.revision_id, old.conversation_id,
          old.payload
        WHERE old.kind = 'text';
        INSERT INTO message_search_fts(
          rowid, revision_id, conversation_id, payload
        )
        SELECT
          new.part_id, new.revision_id, new.conversation_id, new.payload
        WHERE new.kind = 'text';
      END;
    ''');
    // 流式 checkpoint 会推迟 FTS；当 is_streaming 变为 0 时，索引
    // 当时存在的文本 parts。随后的 part 重写（如果发生）
    // 会在 finalized gate 下执行删除并重新插入。
    await _db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_search_fts_finalize
      AFTER UPDATE OF is_streaming ON message_rows
      WHEN old.is_streaming <> 0 AND new.is_streaming = 0
      BEGIN
        INSERT INTO message_search_fts(
          rowid, revision_id, conversation_id, payload
        )
        SELECT
          p.part_id, p.revision_id, p.conversation_id, p.payload
        FROM message_part_rows p
        WHERE p.revision_id = new.id AND p.kind = 'text';
      END;
    ''');
    // 与 finalize 对称：重新打开一个已完成的 revision（0→1）必须先丢弃
    // 其 postings，否则流式 checkpoint 会在 is_streaming≠0 gate 下重写 parts，
    // 留下孤立的 FTS 行。
    await _db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_search_fts_unindex
      AFTER UPDATE OF is_streaming ON message_rows
      WHEN old.is_streaming = 0 AND new.is_streaming <> 0
      BEGIN
        INSERT INTO message_search_fts(
          message_search_fts, rowid, revision_id, conversation_id, payload
        )
        SELECT
          'delete', p.part_id, p.revision_id, p.conversation_id, p.payload
        FROM message_part_rows p
        WHERE p.revision_id = new.id AND p.kind = 'text';
      END;
    ''');
    // 级联删除会在父行对 part DELETE 触发器的 EXISTS 门控不可见之后
    // 删除 part。此处先清理 FTS，并且只清理有资格建立索引的修订
    // （is_streaming = 0）。
    await _db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS message_search_fts_message_delete
      BEFORE DELETE ON message_rows
      WHEN old.is_streaming = 0
      BEGIN
        INSERT INTO message_search_fts(
          message_search_fts, rowid, revision_id, conversation_id, payload
        )
        SELECT
          'delete', p.part_id, p.revision_id, p.conversation_id, p.payload
        FROM message_part_rows p
        WHERE p.revision_id = old.id AND p.kind = 'text';
      END;
    ''');
    if (needsRebuild) {
      await _db.customStatement('''
        INSERT INTO message_search_fts(
          rowid, revision_id, conversation_id, payload
        )
        SELECT
          p.part_id, p.revision_id, p.conversation_id, p.payload
        FROM message_part_rows p
        INNER JOIN message_rows m ON m.id = p.revision_id
        WHERE p.kind = 'text' AND m.is_streaming = 0;
      ''');
    }
    _messageSearchFtsReady = true;
  }

  Future<void> putConversation(Conversation conversation) async {
    await _db.transaction(() async {
      // 现有行保留 prompt freeze 写入的、由数据库拥有的 hash；
      // 缓存的 Conversation 实例可能仍持有较旧的值。
      final updated =
          await (_db.update(
            _db.conversationRows,
          )..where((row) => row.id.equals(conversation.id))).write(
            _conversationCompanion(
              conversation,
              injectedMemoryHash: const Value.absent(),
            ),
          );
      if (updated == 0) {
        await _db
            .into(_db.conversationRows)
            .insert(_conversationCompanion(conversation));
      }
      await _replaceMcpServers(conversation.id, conversation.mcpServerIds);
    });
  }

  Future<Conversation?> duplicateConversation(String sourceId) {
    return _db.transaction(() async {
      final sourceRow = await (_db.select(
        _db.conversationRows,
      )..where((row) => row.id.equals(sourceId))).getSingleOrNull();
      if (sourceRow == null) return null;

      final sourceMessages =
          await (_db.select(_db.messageRows)
                ..where((row) => row.conversationId.equals(sourceId))
                ..orderBy([(row) => OrderingTerm.asc(row.messageOrder)]))
              .get();
      const uuid = Uuid();
      final targetId = uuid.v4();
      final messageIdMap = {
        for (final message in sourceMessages) message.id: uuid.v4(),
      };
      final groupIdMap = <String, String>{};
      for (final message in sourceMessages) {
        final groupId = message.groupId ?? message.id;
        groupIdMap.putIfAbsent(
          groupId,
          () => messageIdMap[groupId] ?? uuid.v4(),
        );
      }

      final source = await _conversationFromRow(
        sourceRow,
        includeMessageIds: false,
      );
      final duplicatedAt = DateTime.now();
      final duplicate = source.copyWith(
        id: targetId,
        createdAt: duplicatedAt,
        updatedAt: duplicatedAt,
        messageIds: [
          for (final message in sourceMessages) messageIdMap[message.id]!,
        ],
        versionSelections: {
          for (final entry in source.versionSelections.entries)
            groupIdMap[entry.key] ?? entry.key: entry.value,
        },
        clearInjectedMemoryHash: true,
        lastMemoryExtractedOrder: sourceMessages.isEmpty
            ? -1
            : sourceMessages.last.messageOrder,
      );
      await _db
          .into(_db.conversationRows)
          .insert(_conversationCompanion(duplicate));
      await _replaceMcpServers(targetId, duplicate.mcpServerIds);

      for (final message in sourceMessages) {
        final targetMessageId = messageIdMap[message.id]!;
        await _db
            .into(_db.messageRows)
            .insert(
              MessageRowsCompanion.insert(
                id: targetMessageId,
                conversationId: targetId,
                role: message.role,
                timestamp: message.timestamp,
                modelId: Value(message.modelId),
                providerId: Value(message.providerId),
                totalTokens: Value(message.totalTokens),
                isStreaming: const Value(false),
                reasoningStartAt: Value(message.reasoningStartAt),
                reasoningFinishedAt: Value(message.reasoningFinishedAt),
                translation: Value(message.translation),
                reasoningSegmentsJson: Value(message.reasoningSegmentsJson),
                groupId: Value(
                  message.groupId == null ? null : groupIdMap[message.groupId],
                ),
                version: Value(message.version),
                promptTokens: Value(message.promptTokens),
                completionTokens: Value(message.completionTokens),
                cachedTokens: Value(message.cachedTokens),
                durationMs: Value(message.durationMs),
                messageOrder: message.messageOrder,
              ),
            );
        await _db.customStatement(
          'INSERT INTO message_part_rows '
          '(conversation_id, revision_id, ordinal, kind, payload, '
          'created_at, updated_at) '
          'SELECT ?, ?, ordinal, kind, payload, created_at, updated_at '
          'FROM message_part_rows WHERE revision_id = ?;',
          [targetId, targetMessageId, message.id],
        );
        await _db.customStatement(
          'INSERT INTO provider_artifact_rows '
          '(conversation_id, revision_id, kind, payload, created_at, '
          'updated_at) '
          'SELECT ?, ?, kind, payload, created_at, updated_at '
          'FROM provider_artifact_rows WHERE revision_id = ?;',
          [targetId, targetMessageId, message.id],
        );
        await _db.customStatement(
          'INSERT INTO message_asset_rows '
          '(conversation_id, revision_id, asset_id, kind) '
          'SELECT ?, ?, asset_id, kind FROM message_asset_rows '
          'WHERE revision_id = ?;',
          [targetId, targetMessageId, message.id],
        );
      }
      await _db.customStatement(
        'INSERT OR IGNORE INTO asset_reference_dirty_rows(revision_id) '
        'SELECT revision_id FROM message_asset_rows WHERE conversation_id = ? '
        'UNION '
        'SELECT revision_id FROM message_part_rows '
        "WHERE conversation_id = ? AND kind IN ('image', 'file');",
        [targetId, targetId],
      );
      return duplicate;
    });
  }

  Future<bool> moveConversationToAssistant({
    required String conversationId,
    required String assistantId,
    required DateTime updatedAt,
  }) {
    return _db.transaction(() async {
      final activeRun =
          await (_db.select(_db.generationRunRows)
                ..where(
                  (row) =>
                      row.conversationId.equals(conversationId) &
                      row.state.isIn(const [
                        'preparing',
                        'requesting',
                        'streaming',
                        'waiting_tool',
                      ]),
                )
                ..limit(1))
              .getSingleOrNull();
      if (activeRun != null) return false;
      await (_db.delete(_db.messagePromptRows)..where(
            (row) =>
                row.conversationId.equals(conversationId) &
                row.carriesMemorySnapshot.equals(true),
          ))
          .go();
      final updated =
          await (_db.update(
            _db.conversationRows,
          )..where((row) => row.id.equals(conversationId))).write(
            ConversationRowsCompanion(
              assistantId: Value(assistantId),
              updatedAt: Value(updatedAt),
              injectedMemoryHash: const Value(null),
            ),
          );
      return updated != 0;
    });
  }

  Future<void> putMessage(ChatMessage message, {int? messageOrder}) async {
    final order =
        messageOrder ?? await _nextMessageOrder(message.conversationId);
    await _db.transaction(() async {
      await _db
          .into(_db.messageRows)
          .insertOnConflictUpdate(_messageCompanion(message, order));
      await _replaceMessageParts(message);
      await _appendMessageToTree(message.conversationId, message.id);
    });
  }

  Future<void> saveConversationTree(ConversationTree tree) {
    return _db.transaction(() => _writeConversationTree(tree));
  }

  Future<void> _writeConversationTree(ConversationTree tree) async {
    await (_db.delete(
      _db.messageTreeEdgeRows,
    )..where((row) => row.conversationId.equals(tree.conversationId))).go();
    await (_db.delete(
      _db.conversationBranchRows,
    )..where((row) => row.conversationId.equals(tree.conversationId))).go();
    await (_db.delete(
      _db.conversationTreeStateRows,
    )..where((row) => row.conversationId.equals(tree.conversationId))).go();

    for (final edge in tree.edges.values) {
      await _db
          .into(_db.messageTreeEdgeRows)
          .insert(
            MessageTreeEdgeRowsCompanion.insert(
              conversationId: tree.conversationId,
              messageId: edge.messageId,
              parentMessageId: Value(edge.parentMessageId),
            ),
          );
    }
    for (final branch in tree.branches.values) {
      await _db
          .into(_db.conversationBranchRows)
          .insert(
            ConversationBranchRowsCompanion.insert(
              id: branch.id,
              conversationId: tree.conversationId,
              tipMessageId: Value(branch.tipMessageId),
              name: Value(branch.name),
              createdAt: branch.createdAt,
            ),
          );
    }
    await _db
        .into(_db.conversationTreeStateRows)
        .insert(
          ConversationTreeStateRowsCompanion.insert(
            conversationId: tree.conversationId,
            activeBranchId: tree.activeBranchId,
            branchSelectionsJson: Value(jsonEncode(tree.branchSelections)),
          ),
        );
  }

  Future<ConversationTree?> loadConversationTree(String conversationId) async {
    return _db.transaction(() => _loadConversationTree(conversationId));
  }

  // 会话树横跨三张表；当其他操作可能整棵替换会话树时，
  // 必须在同一个事务快照中读取。
  Future<ConversationTree?> _loadConversationTree(String conversationId) async {
    final branchRows = await (_db.select(
      _db.conversationBranchRows,
    )..where((row) => row.conversationId.equals(conversationId))).get();
    if (branchRows.isEmpty) return null;

    final edgeRows = await (_db.select(
      _db.messageTreeEdgeRows,
    )..where((row) => row.conversationId.equals(conversationId))).get();
    final stateRow =
        await (_db.select(_db.conversationTreeStateRows)
              ..where((row) => row.conversationId.equals(conversationId)))
            .getSingleOrNull();
    if (stateRow == null) {
      throw StateError('conversation_tree_state_missing');
    }

    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: stateRow.activeBranchId,
      branchSelections: _decodeBranchSelections(stateRow.branchSelectionsJson),
      branches: {
        for (final row in branchRows)
          row.id: ConversationBranch(
            id: row.id,
            conversationId: row.conversationId,
            tipMessageId: row.tipMessageId,
            name: row.name,
            createdAt: row.createdAt,
          ),
      },
      edges: {
        for (final row in edgeRows)
          row.messageId: MessageTreeEdge(
            messageId: row.messageId,
            parentMessageId: row.parentMessageId,
          ),
      },
    );
  }

  Map<String, String> _decodeBranchSelections(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) {
        return {
          for (final entry in decoded.entries)
            if (entry.value is String) entry.key: entry.value as String,
        };
      }
    } catch (_) {}
    return <String, String>{};
  }

  String _conversationRootBranchId(String conversationId) =>
      'root-$conversationId';

  Future<void> syncLinearConversationTree(String conversationId) {
    return _db.transaction(
      () => _syncLinearTreeForConversation(conversationId),
    );
  }

  Future<void> _syncLinearTreeForConversation(String conversationId) async {
    final messageRows =
        await (_db.select(_db.messageRows)
              ..where((row) => row.conversationId.equals(conversationId))
              ..orderBy([
                (row) => OrderingTerm.asc(row.messageOrder),
                (row) => OrderingTerm.asc(row.id),
              ]))
            .get();
    final conversationRow = await (_db.select(
      _db.conversationRows,
    )..where((row) => row.id.equals(conversationId))).getSingleOrNull();
    final createdAt =
        conversationRow?.createdAt ??
        (messageRows.isEmpty ? DateTime.now() : messageRows.first.timestamp);
    await _writeConversationTree(
      ConversationTree.linear(
        conversationId: conversationId,
        messageIds: messageRows.map((row) => row.id).toList(growable: false),
        activeBranchId: _conversationRootBranchId(conversationId),
        createdAt: createdAt,
      ),
    );
  }

  Future<ConversationTree> _loadOrCreateConversationTree(
    String conversationId,
  ) async {
    final existing = await _loadConversationTree(conversationId);
    if (existing != null) return existing;

    final messageRows =
        await (_db.select(_db.messageRows)
              ..where((row) => row.conversationId.equals(conversationId))
              ..orderBy([
                (row) => OrderingTerm.asc(row.messageOrder),
                (row) => OrderingTerm.asc(row.id),
              ]))
            .get();
    final conversationRow = await (_db.select(
      _db.conversationRows,
    )..where((row) => row.id.equals(conversationId))).getSingleOrNull();
    final createdAt =
        conversationRow?.createdAt ??
        (messageRows.isEmpty ? DateTime.now() : messageRows.first.timestamp);
    return ConversationTree.linear(
      conversationId: conversationId,
      messageIds: messageRows.map((row) => row.id).toList(growable: false),
      activeBranchId: _conversationRootBranchId(conversationId),
      createdAt: createdAt,
    );
  }

  Future<void> _appendMessageToTree(
    String conversationId,
    String messageId, {
    String? parentMessageId,
    String? branchId,
  }) async {
    final persistedTree = await _loadConversationTree(conversationId);
    final tree =
        persistedTree ?? await _loadOrCreateConversationTree(conversationId);
    var baseTree = tree;
    if (branchId != null && !tree.branches.containsKey(branchId)) {
      baseTree = tree.createMessageBranchFromParent(
        branchId: branchId,
        fromMessageId: parentMessageId,
        createdAt: DateTime.now(),
      );
    }
    final nextTree = baseTree.edges.containsKey(messageId)
        ? baseTree
        : baseTree.appendToActiveBranch(
            messageId,
            parentMessageId: parentMessageId,
            branchId: branchId,
            createdAt: DateTime.now(),
            activate: branchId != null,
          );
    if (persistedTree == null) {
      await _writeConversationTree(nextTree);
    } else {
      await _appendTreeRows(tree, nextTree, messageId);
    }
  }

  Future<void> _appendTreeRows(
    ConversationTree previous,
    ConversationTree next,
    String messageId,
  ) async {
    final edge = next.edges[messageId];
    if (edge != null && !previous.edges.containsKey(messageId)) {
      await _db
          .into(_db.messageTreeEdgeRows)
          .insert(
            MessageTreeEdgeRowsCompanion.insert(
              conversationId: next.conversationId,
              messageId: edge.messageId,
              parentMessageId: Value(edge.parentMessageId),
            ),
          );
    }

    for (final branch in next.branches.values) {
      if (previous.branches[branch.id] == branch) continue;
      await _db
          .into(_db.conversationBranchRows)
          .insertOnConflictUpdate(
            ConversationBranchRowsCompanion.insert(
              id: branch.id,
              conversationId: next.conversationId,
              tipMessageId: Value(branch.tipMessageId),
              name: Value(branch.name),
              createdAt: branch.createdAt,
            ),
          );
    }

    await _db
        .into(_db.conversationTreeStateRows)
        .insertOnConflictUpdate(
          ConversationTreeStateRowsCompanion.insert(
            conversationId: next.conversationId,
            activeBranchId: next.activeBranchId,
            branchSelectionsJson: Value(jsonEncode(next.branchSelections)),
          ),
        );
  }

  Future<Conversation> appendLinearMessageToConversation({
    required Conversation conversation,
    required ChatMessage message,
    bool selectVersion = false,
    bool touchUpdatedAt = true,
  }) {
    return _observer.measure(
      ChatDatabaseOperation.commandAppendMessage,
      () => _appendLinearMessageToConversation(
        conversation: conversation,
        message: message,
        selectVersion: selectVersion,
        touchUpdatedAt: touchUpdatedAt,
      ),
    );
  }

  Future<GenerationBeginResult> beginSendGeneration({
    required Conversation conversation,
    required ChatMessage userMessage,
    required ChatMessage assistantMessage,
    required String runId,
  }) {
    _validateGenerationBeginMessages(
      conversation: conversation,
      userMessage: userMessage,
      assistantMessage: assistantMessage,
    );
    return _observer.measure(
      ChatDatabaseOperation.commandAppendMessage,
      () => _db.transaction(() async {
        final afterUser = await _appendLinearMessageToConversation(
          conversation: conversation,
          message: userMessage,
          selectVersion: false,
          touchUpdatedAt: true,
        );
        final persisted = await _appendLinearMessageToConversation(
          conversation: afterUser,
          message: assistantMessage,
          selectVersion: false,
          touchUpdatedAt: true,
        );
        final run = await GenerationRunCommands(_db).create(
          id: runId,
          conversationId: conversation.id,
          targetRevisionId: assistantMessage.id,
          createdAt: assistantMessage.timestamp,
        );
        return (
          conversation: persisted,
          userMessage: userMessage,
          assistantMessage: assistantMessage,
          run: run,
        );
      }),
    );
  }

  Future<GenerationBeginResult> beginRegeneration({
    required Conversation conversation,
    required ChatMessage assistantMessage,
    required String runId,
    required bool truncateFuture,
    String? parentMessageId,
    String? branchId,
  }) {
    _validateGenerationBeginMessages(
      conversation: conversation,
      assistantMessage: assistantMessage,
    );
    if (assistantMessage.groupId == null) {
      throw ArgumentError.value(
        assistantMessage.groupId,
        'assistantMessage.groupId',
      );
    }
    return _observer.measure(
      ChatDatabaseOperation.commandAppendMessage,
      () => _db.transaction(() async {
        if (truncateFuture) {
          throw StateError('tree_regeneration_cannot_truncate_future');
        }
        final persisted = await _appendLinearMessageToConversation(
          conversation: conversation,
          message: assistantMessage,
          selectVersion: true,
          touchUpdatedAt: true,
          parentMessageId: parentMessageId,
          branchId: branchId,
        );
        final run = await GenerationRunCommands(_db).create(
          id: runId,
          conversationId: conversation.id,
          targetRevisionId: assistantMessage.id,
          createdAt: assistantMessage.timestamp,
        );
        return (
          conversation: persisted,
          userMessage: null,
          assistantMessage: assistantMessage,
          run: run,
        );
      }),
    );
  }

  Future<GenerationBeginResult> beginAssistantGeneration({
    required Conversation conversation,
    required ChatMessage assistantMessage,
    required String anchorGroupId,
    required String runId,
    required bool truncateFuture,
    String? parentMessageId,
    String? branchId,
  }) {
    _validateGenerationBeginMessages(
      conversation: conversation,
      assistantMessage: assistantMessage,
    );
    return _observer.measure(
      ChatDatabaseOperation.commandAppendMessage,
      () => _db.transaction(() async {
        if (truncateFuture) {
          throw StateError('tree_generation_cannot_truncate_future');
        }
        final persisted = await _appendLinearMessageToConversation(
          conversation: conversation,
          message: assistantMessage,
          selectVersion: false,
          touchUpdatedAt: true,
          parentMessageId: parentMessageId,
          branchId: branchId,
        );
        final run = await GenerationRunCommands(_db).create(
          id: runId,
          conversationId: conversation.id,
          targetRevisionId: assistantMessage.id,
          createdAt: assistantMessage.timestamp,
        );
        return (
          conversation: persisted,
          userMessage: null,
          assistantMessage: assistantMessage,
          run: run,
        );
      }),
    );
  }

  static void _validateGenerationBeginMessages({
    required Conversation conversation,
    ChatMessage? userMessage,
    required ChatMessage assistantMessage,
  }) {
    if (userMessage != null &&
        (userMessage.conversationId != conversation.id ||
            userMessage.role != 'user' ||
            userMessage.isStreaming)) {
      throw ArgumentError.value(userMessage, 'userMessage');
    }
    if (assistantMessage.conversationId != conversation.id ||
        assistantMessage.role != 'assistant' ||
        !assistantMessage.isStreaming) {
      throw ArgumentError.value(assistantMessage, 'assistantMessage');
    }
  }

  Future<Conversation> _appendLinearMessageToConversation({
    required Conversation conversation,
    required ChatMessage message,
    required bool selectVersion,
    required bool touchUpdatedAt,
    String? parentMessageId,
    String? branchId,
  }) {
    if (message.conversationId != conversation.id) {
      throw ArgumentError.value(
        message.conversationId,
        'message.conversationId',
        'Message and conversation IDs must match.',
      );
    }
    return _db.transaction(() async {
      final existingRow = await (_db.select(
        _db.conversationRows,
      )..where((row) => row.id.equals(conversation.id))).getSingleOrNull();
      final current = existingRow == null
          ? conversation
          : await _conversationFromRow(existingRow, includeMessageIds: false);
      final selections = Map<String, int>.from(current.versionSelections);
      if (selectVersion) {
        selections[message.groupId ?? message.id] = message.version;
      }
      final persisted = current.copyWith(
        versionSelections: selections,
        updatedAt: touchUpdatedAt ? DateTime.now() : current.updatedAt,
      );
      await _db
          .into(_db.conversationRows)
          .insertOnConflictUpdate(_conversationCompanion(persisted));
      if (existingRow == null) {
        await _replaceMcpServers(persisted.id, persisted.mcpServerIds);
      }
      var resolvedParentMessageId = parentMessageId;
      var resolvedBranchId = branchId;
      if (resolvedBranchId == null &&
          (message.groupId != null || message.version > 0)) {
        final anchorRow =
            await (_db.select(_db.messageRows)
                  ..where(
                    (row) =>
                        row.conversationId.equals(persisted.id) &
                        (row.id.equals(message.groupId ?? '') |
                            row.groupId.equals(message.groupId ?? '')),
                  )
                  ..orderBy([(row) => OrderingTerm.asc(row.messageOrder)])
                  ..limit(1))
                .getSingleOrNull();
        if (anchorRow != null) {
          final tree = await _loadOrCreateConversationTree(persisted.id);
          final anchor = tree.edges[anchorRow.id];
          if (anchor != null) {
            resolvedParentMessageId = anchor.parentMessageId;
            resolvedBranchId = 'branch-${const Uuid().v4()}';
          }
        }
      }

      final order = await _nextMessageOrder(persisted.id);
      await _db
          .into(_db.messageRows)
          .insert(_messageCompanion(message, order), mode: InsertMode.insert);
      await _replaceMessageParts(message);
      await _appendMessageToTree(
        persisted.id,
        message.id,
        parentMessageId: resolvedParentMessageId,
        branchId: resolvedBranchId,
      );
      return persisted;
    });
  }

  Future<void> _replaceMessageParts(
    ChatMessage message, {
    List<Map<String, dynamic>>? toolEvents,
    bool preserveUnchangedToolParts = false,
  }) async {
    if (_messageHasAttachmentParts(message)) {
      await markMessageAssetReferencesDirty(message.id);
    }
    final preservedToolEvents = toolEvents ?? await getToolEvents(message.id);
    // 流中途的 reasoning 暂停不是移除 reasoning：checkpoint 快照仍带有预分配的
    // reasoningStartAt 时间戳，因此保留持久化 reasoning part，直到无时间戳消息
    // 证明 reasoning 已消失（完全重建、编辑、finalize）。
    final effectiveReasoningText =
        message.reasoningText == null && message.reasoningStartAt != null
        ? (await (_db.select(_db.messagePartRows)
                    ..where(
                      (row) =>
                          row.revisionId.equals(message.id) &
                          row.kind.equals('reasoning'),
                    )
                    ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
                  .get())
              .map((part) => part.payload)
              .join()
        : null;
    if (effectiveReasoningText != null && effectiveReasoningText.isNotEmpty) {
      message = message.copyWith(reasoningText: effectiveReasoningText);
    }
    // 带 attachment 的消息拥有交错排列的 body ordinals；
    // text/reasoning fast path 无法安全地保留它们。
    if (preserveUnchangedToolParts &&
        preservedToolEvents.isNotEmpty &&
        !_messageHasAttachmentParts(message)) {
      final keptToolParts = await _unchangedToolPartCount(
        message,
        preservedToolEvents,
      );
      if (keptToolParts != null) {
        await _replaceTextAndReasoningParts(message, keptToolParts);
        return;
      }
    }
    await (_db.delete(
      _db.messagePartRows,
    )..where((row) => row.revisionId.equals(message.id))).go();
    var ordinal = 0;
    final now = DateTime.now().toUtc();
    final updatedAt = now.isBefore(message.timestamp) ? message.timestamp : now;
    final reasoning = message.reasoningText;
    if (reasoning != null && reasoning.isNotEmpty) {
      await _db
          .into(_db.messagePartRows)
          .insert(
            MessagePartRowsCompanion.insert(
              conversationId: message.conversationId,
              revisionId: message.id,
              ordinal: ordinal++,
              kind: 'reasoning',
              payload: reasoning,
              createdAt: message.timestamp,
              updatedAt: updatedAt,
            ),
          );
    }
    for (final event in preservedToolEvents) {
      await _db
          .into(_db.messagePartRows)
          .insert(
            MessagePartRowsCompanion.insert(
              conversationId: message.conversationId,
              revisionId: message.id,
              ordinal: ordinal++,
              kind: 'tool_call',
              payload: jsonEncode(event),
              createdAt: message.timestamp,
              updatedAt: updatedAt,
            ),
          );
    }
    final bodyParts = _bodyPartsForPersistence(message);
    for (final part in bodyParts) {
      await _db
          .into(_db.messagePartRows)
          .insert(
            MessagePartRowsCompanion.insert(
              conversationId: message.conversationId,
              revisionId: message.id,
              ordinal: ordinal++,
              kind: part.kind,
              payload: part.encodePayload(),
              createdAt: message.timestamp,
              updatedAt: updatedAt,
            ),
          );
    }
  }

  /// 当现有持久化 tool_call part 与完整重建为 [toolEvents] 所写内容
  /// （payload 和 ordinal）一致时返回其数量；任何差异导致完整删除并重插时返回 null。
  /// reasoning 出现或消失会重新编号工具 ordinal，因此也会强制完整重建。
  /// 每个 tool event 恰好产生一个 `tool_call` part。
  Future<int?> _unchangedToolPartCount(
    ChatMessage message,
    List<Map<String, dynamic>> toolEvents,
  ) async {
    final existing =
        await (_db.select(_db.messagePartRows)
              ..where((row) => row.revisionId.equals(message.id))
              ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
            .get();
    if (existing.isEmpty) return null;
    if (existing.any((part) => part.kind == 'image' || part.kind == 'file')) {
      return null;
    }
    final reasoning = message.reasoningText;
    final hasReasoning = reasoning != null && reasoning.isNotEmpty;
    final hasPersistedReasoning = existing.any(
      (part) => part.kind == 'reasoning',
    );
    if (hasReasoning != hasPersistedReasoning) return null;
    final expectedPayloads = [
      for (final event in toolEvents) jsonEncode(event),
    ];
    final persistedToolParts = existing
        .where((part) => part.kind == 'tool_call')
        .toList(growable: false);
    if (persistedToolParts.length != expectedPayloads.length) return null;
    final firstToolOrdinal = hasReasoning ? 1 : 0;
    for (var i = 0; i < persistedToolParts.length; i++) {
      final part = persistedToolParts[i];
      if (part.payload != expectedPayloads[i] ||
          part.ordinal != firstToolOrdinal + i) {
        return null;
      }
    }
    return persistedToolParts.length;
  }

  /// 仅重写 text/reasoning parts；[toolPartCount] 个已持久化的
  /// tool parts 保留各自的 rows、ordinals 和 timestamps。
  Future<void> _replaceTextAndReasoningParts(
    ChatMessage message,
    int toolPartCount,
  ) async {
    await (_db.delete(_db.messagePartRows)..where(
          (row) =>
              row.revisionId.equals(message.id) &
              (row.kind.equals('text') | row.kind.equals('reasoning')),
        ))
        .go();
    final now = DateTime.now().toUtc();
    final updatedAt = now.isBefore(message.timestamp) ? message.timestamp : now;
    var ordinal = 0;
    final reasoning = message.reasoningText;
    if (reasoning != null && reasoning.isNotEmpty) {
      await _db
          .into(_db.messagePartRows)
          .insert(
            MessagePartRowsCompanion.insert(
              conversationId: message.conversationId,
              revisionId: message.id,
              ordinal: ordinal++,
              kind: 'reasoning',
              payload: reasoning,
              createdAt: message.timestamp,
              updatedAt: updatedAt,
            ),
          );
    }
    ordinal += toolPartCount;
    final bodyParts = _bodyPartsForPersistence(message);
    for (final part in bodyParts) {
      await _db
          .into(_db.messagePartRows)
          .insert(
            MessagePartRowsCompanion.insert(
              conversationId: message.conversationId,
              revisionId: message.id,
              ordinal: ordinal++,
              kind: part.kind,
              payload: part.encodePayload(),
              createdAt: message.timestamp,
              updatedAt: updatedAt,
            ),
          );
    }
  }

  Future<AppendedMessageVersion?> appendMessageVersion({
    required String messageId,
    String content = '',
    List<MessagePart>? parts,
  }) {
    return _observer.measure(
      ChatDatabaseOperation.commandAppendVersion,
      () => _appendMessageVersion(
        messageId: messageId,
        content: content,
        parts: parts,
      ),
    );
  }

  /// 克隆消息并从其原父节点创建一个新的消息分支。
  ///
  /// 克隆保留消息元数据、所有结构化部件、工具调用、提供商产物和资源引用，
  /// 但使用新的消息 ID 和版本号。原消息及其后续分支保持不变。
  Future<AppendedMessageVersion?> cloneMessageAsBranch({
    required String conversationId,
    required String messageId,
  }) {
    return _observer.measure(
      ChatDatabaseOperation.commandAppendVersion,
      () => _cloneMessageAsBranch(
        conversationId: conversationId,
        messageId: messageId,
      ),
    );
  }

  Future<AppendedMessageVersion?> _cloneMessageAsBranch({
    required String conversationId,
    required String messageId,
  }) async {
    return _db.transaction(() async {
      final originalRow = await (_db.select(
        _db.messageRows,
      )..where((row) => row.id.equals(messageId))).getSingleOrNull();
      if (originalRow == null) return null;
      if (originalRow.conversationId != conversationId) return null;
      final conversationRow =
          await (_db.select(_db.conversationRows)
                ..where((row) => row.id.equals(originalRow.conversationId)))
              .getSingleOrNull();
      if (conversationRow == null) return null;

      final original = await _messageFromRowWithParts(originalRow);
      final groupId = originalRow.groupId ?? originalRow.id;
      final maxVersion = _db.messageRows.version.max();
      final maxVersionRow =
          await (_db.selectOnly(_db.messageRows)
                ..addColumns([maxVersion])
                ..where(
                  _db.messageRows.conversationId.equals(
                        originalRow.conversationId,
                      ) &
                      (_db.messageRows.groupId.equals(groupId) |
                          (_db.messageRows.groupId.isNull() &
                              _db.messageRows.id.equals(groupId))),
                ))
              .getSingle();
      final nextVersion = (maxVersionRow.read(maxVersion) ?? -1) + 1;
      final clone = ChatMessage(
        role: original.role,
        parts: original.parts,
        timestamp: original.timestamp,
        modelId: original.modelId,
        providerId: original.providerId,
        totalTokens: original.totalTokens,
        conversationId: original.conversationId,
        isStreaming: false,
        reasoningText: original.reasoningText,
        reasoningStartAt: original.reasoningStartAt,
        reasoningFinishedAt: original.reasoningFinishedAt,
        translation: original.translation,
        reasoningSegmentsJson: original.reasoningSegmentsJson,
        groupId: groupId,
        version: nextVersion,
        promptTokens: original.promptTokens,
        completionTokens: original.completionTokens,
        cachedTokens: original.cachedTokens,
        durationMs: original.durationMs,
      );

      final currentConversation = await _conversationFromRow(
        conversationRow,
        includeMessageIds: false,
      );
      final conversation = currentConversation.copyWith(
        updatedAt: DateTime.now(),
      );
      final originalTree = await _loadOrCreateConversationTree(conversation.id);
      final originalEdge = originalTree.edges[messageId];
      if (originalEdge == null) {
        throw StateError('cloned_message_tree_edge_missing');
      }
      final branchId = 'branch-${const Uuid().v4()}';
      final updatedTree = originalTree.createBranchFromParent(
        branchId: branchId,
        parentMessageId: originalEdge.parentMessageId,
        tipMessageId: clone.id,
        createdAt: clone.timestamp,
      );

      final order = await _nextMessageOrder(conversation.id);
      await _db
          .into(_db.messageRows)
          .insert(_messageCompanion(clone, order), mode: InsertMode.insert);
      await _db.customStatement(
        'INSERT INTO message_part_rows '
        '(conversation_id, revision_id, ordinal, kind, payload, '
        'created_at, updated_at) '
        'SELECT ?, ?, ordinal, kind, payload, created_at, updated_at '
        'FROM message_part_rows WHERE revision_id = ?;',
        [conversation.id, clone.id, original.id],
      );
      await _db.customStatement(
        'INSERT INTO provider_artifact_rows '
        '(conversation_id, revision_id, kind, payload, created_at, '
        'updated_at) '
        'SELECT ?, ?, kind, payload, created_at, updated_at '
        'FROM provider_artifact_rows WHERE revision_id = ?;',
        [conversation.id, clone.id, original.id],
      );
      await _db.customStatement(
        'INSERT INTO message_asset_rows '
        '(conversation_id, revision_id, asset_id, kind) '
        'SELECT ?, ?, asset_id, kind FROM message_asset_rows '
        'WHERE revision_id = ?;',
        [conversation.id, clone.id, original.id],
      );
      await _db.customStatement(
        'INSERT OR IGNORE INTO asset_reference_dirty_rows(revision_id) '
        'SELECT ? WHERE EXISTS '
        '(SELECT 1 FROM message_asset_rows WHERE revision_id = ?);',
        [clone.id, clone.id],
      );
      await _writeConversationTree(updatedTree);
      await (_db.update(_db.conversationRows)
            ..where((row) => row.id.equals(conversation.id)))
          .write(_conversationCompanion(conversation));
      return (conversation: conversation, message: clone);
    });
  }

  Future<AppendedMessageVersion?> _appendMessageVersion({
    required String messageId,
    required String content,
    List<MessagePart>? parts,
  }) async {
    return _db.transaction(() async {
      final originalRow = await (_db.select(
        _db.messageRows,
      )..where((row) => row.id.equals(messageId))).getSingleOrNull();
      if (originalRow == null) return null;
      final conversationRow =
          await (_db.select(_db.conversationRows)
                ..where((row) => row.id.equals(originalRow.conversationId)))
              .getSingleOrNull();
      if (conversationRow == null) return null;

      // 仅 Metadata —— body 文本通过 message parts 写入。
      final groupId = originalRow.groupId ?? originalRow.id;
      final maxVersion = _db.messageRows.version.max();
      final maxVersionRow =
          await (_db.selectOnly(_db.messageRows)
                ..addColumns([maxVersion])
                ..where(
                  _db.messageRows.conversationId.equals(
                        originalRow.conversationId,
                      ) &
                      (_db.messageRows.groupId.equals(groupId) |
                          (_db.messageRows.groupId.isNull() &
                              _db.messageRows.id.equals(groupId))),
                ))
              .getSingle();
      final nextVersion = (maxVersionRow.read(maxVersion) ?? -1) + 1;
      // 仅追加 Content 时必须先加载原始 parts，并在新 revision 上保留非文本
      // attachments（ImagePart/FilePart/etc.），同时保持
      // ordinal（[Image, Text] 保持为 [Image, Text(new)]，而不是 [Text(new), Image]）。
      final List<MessagePart> resolvedParts;
      if (parts != null) {
        resolvedParts = parts;
      } else {
        final original = await _messageFromRowWithParts(originalRow);
        resolvedParts = ChatMessage.partsWithReplacedText(
          original.parts,
          content,
        );
      }
      final message = ChatMessage(
        role: originalRow.role,
        parts: resolvedParts,
        conversationId: originalRow.conversationId,
        modelId: originalRow.modelId,
        providerId: originalRow.providerId,
        totalTokens: null,
        isStreaming: false,
        groupId: groupId,
        version: nextVersion,
      );
      final currentConversation = await _conversationFromRow(
        conversationRow,
        includeMessageIds: false,
      );
      final conversation = currentConversation.copyWith(
        updatedAt: DateTime.now(),
      );
      final order = await _nextMessageOrder(conversation.id);
      await _db
          .into(_db.messageRows)
          .insert(_messageCompanion(message, order), mode: InsertMode.insert);
      await _replaceMessageParts(message);
      final tree = await _loadOrCreateConversationTree(conversation.id);
      final originalEdge = tree.edges[messageId];
      if (originalEdge == null) {
        throw StateError('edited_message_tree_edge_missing');
      }
      final branchId = 'branch-${const Uuid().v4()}';
      final updatedTree = tree.createBranchFromParent(
        branchId: branchId,
        parentMessageId: originalEdge.parentMessageId,
        tipMessageId: message.id,
        createdAt: message.timestamp,
      );
      await _writeConversationTree(updatedTree);
      await (_db.update(_db.conversationRows)
            ..where((row) => row.id.equals(conversation.id)))
          .write(_conversationCompanion(conversation));
      return (conversation: conversation, message: message);
    });
  }

  /// 废弃：改用 [saveConversationTree] 来持久化分支切换。
  /// 此方法仅保留用于兼容层，运行时不再依赖 versionSelections。
  @Deprecated('Use saveConversationTree() instead')
  Future<Conversation?> setSelectedVersion({
    required String conversationId,
    required String groupId,
    required int? version,
  }) {
    return _observer.measure(
      ChatDatabaseOperation.commandSelectVersion,
      () => _setSelectedVersion(
        conversationId: conversationId,
        groupId: groupId,
        version: version,
      ),
    );
  }

  Future<Conversation?> _setSelectedVersion({
    required String conversationId,
    required String groupId,
    required int? version,
  }) async {
    if (groupId.isEmpty) {
      throw ArgumentError.value(groupId, 'groupId', 'must not be empty');
    }
    if (version != null && version < 0) {
      throw ArgumentError.value(version, 'version', 'must not be negative');
    }
    return _db.transaction(() async {
      final row =
          await (_db.select(_db.conversationRows)..where(
                (conversation) => conversation.id.equals(conversationId),
              ))
              .getSingleOrNull();
      if (row == null) return null;
      final current = await _conversationFromRow(row, includeMessageIds: false);
      final selections = Map<String, int>.from(current.versionSelections);
      if (version == null) {
        selections.remove(groupId);
      } else {
        selections[groupId] = version;
      }
      final conversation = current.copyWith(
        versionSelections: selections,
        updatedAt: DateTime.now(),
      );
      await (_db.update(_db.conversationRows)
            ..where((conversation) => conversation.id.equals(conversationId)))
          .write(_conversationCompanion(conversation));
      return conversation;
    });
  }

  Future<void> putMigrationBatch({
    required List<Conversation> conversations,
    required List<({ChatMessage message, int messageOrder})> messages,
    required Map<String, List<Map<String, dynamic>>> toolEventsByMessageId,
    required Map<String, String> geminiSignaturesByMessageId,
  }) async {
    if (conversations.isEmpty &&
        messages.isEmpty &&
        toolEventsByMessageId.isEmpty &&
        geminiSignaturesByMessageId.isEmpty) {
      return;
    }

    await _db.transaction(() async {
      await _writeBackupData(
        conversations: conversations,
        messages: messages,
        toolEventsByMessageId: toolEventsByMessageId,
        geminiSignaturesByMessageId: geminiSignaturesByMessageId,
        freshParts: true,
      );
    });
  }

  /// 提交已完全解析的外部导入及其业务数据补丁。除非两个仓库共享这个确切的
  /// [AppDatabase] 实例，否则不会写入任何内容。
  Future<void> commitParsedImport({
    required BusinessRepository businessRepository,
    required bool overwrite,
    required List<ParsedChatImportBatch> conversationBatches,
    required Map<String, List<ChatMessage>> messagesToAppend,
    required BusinessSnapshot Function(BusinessSnapshot current)
    transformBusiness,
  }) async {
    if (!businessRepository.sharesDatabaseIdentity(_db)) {
      throw StateError('chat_business_database_mismatch');
    }
    if (overwrite && messagesToAppend.isNotEmpty) {
      throw ArgumentError.value(messagesToAppend, 'messagesToAppend');
    }
    for (final batch in conversationBatches) {
      for (final message in batch.messages) {
        if (message.conversationId != batch.conversation.id) {
          throw ArgumentError.value(
            message.conversationId,
            'message.conversationId',
          );
        }
      }
    }
    for (final entry in messagesToAppend.entries) {
      for (final message in entry.value) {
        if (message.conversationId != entry.key) {
          throw ArgumentError.value(
            message.conversationId,
            'message.conversationId',
          );
        }
      }
    }

    await _db.transaction(() async {
      if (overwrite) await _clearChatRows();

      final conversations = <Conversation>[];
      final messages = <({ChatMessage message, int messageOrder})>[];
      for (final batch in conversationBatches) {
        conversations.add(
          batch.conversation.copyWith(
            messageIds: batch.messages
                .map((message) => message.id)
                .toList(growable: false),
          ),
        );
        for (final (messageOrder, message) in batch.messages.indexed) {
          messages.add((message: message, messageOrder: messageOrder));
        }
      }
      await _writeBackupData(
        conversations: conversations,
        messages: messages,
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
        freshParts: false,
      );
      for (final batch in conversationBatches) {
        final tree = batch.tree;
        if (tree != null) await _writeConversationTree(tree);
      }

      for (final entry in messagesToAppend.entries) {
        final current = await getConversation(entry.key);
        if (current == null) {
          throw StateError('chat_import_conversation_missing');
        }
        var conversation = current;
        for (final message in entry.value) {
          conversation = await _appendLinearMessageToConversation(
            conversation: conversation,
            message: message,
            selectVersion: false,
            touchUpdatedAt: false,
          );
        }
      }

      await businessRepository.transformSnapshot(
        transformBusiness,
        writeReceipt: true,
      );
    });
  }

  Future<void> replaceBackupData({
    required List<Conversation> conversations,
    required List<({ChatMessage message, int messageOrder})> messages,
    required Map<String, List<Map<String, dynamic>>> toolEventsByMessageId,
    required Map<String, String> geminiSignaturesByMessageId,
  }) async {
    await _db.transaction(() async {
      await _clearChatRows();
      await _writeBackupData(
        conversations: conversations,
        messages: messages,
        toolEventsByMessageId: toolEventsByMessageId,
        geminiSignaturesByMessageId: geminiSignaturesByMessageId,
        freshParts: true,
      );
      await _writeMigrationCompleteReceipt();
    });
  }

  Future<BackupMergeReport> mergeBackupSnapshot(File snapshotFile) async {
    if (!await snapshotFile.exists()) {
      throw FileSystemException(
        'Snapshot database does not exist',
        snapshotFile.path,
      );
    }

    var attached = false;
    try {
      await _db.customStatement('ATTACH DATABASE ? AS merge_source;', [
        snapshotFile.absolute.path,
      ]);
      attached = true;
      return await _db.transaction(() async {
        final sourceRows = await _db
            .customSelect(
              'SELECT id FROM merge_source.conversation_rows ORDER BY id;',
            )
            .get();
        var imported = 0;
        var deduplicated = 0;
        var skipped = 0;
        final remapped = <String, String>{};
        final importedIds = <String>[];

        for (final sourceRow in sourceRows) {
          final sourceId = sourceRow.read<String>('id');
          try {
            await _requireValidMessageOrder('merge_source', sourceId);
          } on StateError catch (error) {
            if (error.message != 'conversation_message_order') rethrow;
            skipped += 1;
            continue;
          }
          final sourceFingerprint = await _conversationFingerprint(
            'merge_source',
            sourceId,
          );
          if (sourceFingerprint == null) {
            throw StateError('merge_source_conversation');
          }
          final existingFingerprint = await _conversationFingerprint(
            'main',
            sourceId,
          );
          if (existingFingerprint == sourceFingerprint) {
            deduplicated += 1;
            continue;
          }

          final sourceMessageIds = await _messageIds('merge_source', sourceId);
          final hasConversationConflict = existingFingerprint != null;
          final hasMessageConflict = await _anyMessageIdExists(
            sourceMessageIds,
          );
          var targetId = sourceId;
          var remapWholeConversation =
              hasConversationConflict || hasMessageConflict;
          if (remapWholeConversation) {
            targetId = _deterministicMergeId(
              'conversation',
              sourceId,
              sourceFingerprint,
            );
            var suffix = 0;
            while (true) {
              final candidateFingerprint = await _conversationFingerprint(
                'main',
                targetId,
              );
              if (candidateFingerprint == null) break;
              if (candidateFingerprint == sourceFingerprint) {
                deduplicated += 1;
                remapped[sourceId] = targetId;
                targetId = '';
                break;
              }
              suffix += 1;
              targetId =
                  '${_deterministicMergeId('conversation', sourceId, sourceFingerprint)}-$suffix';
            }
            if (targetId.isEmpty) continue;
            remapped[sourceId] = targetId;
          }

          final messageIdMap = <String, String>{};
          for (final messageId in sourceMessageIds) {
            messageIdMap[messageId] = remapWholeConversation
                ? _deterministicMergeId('message', messageId, sourceFingerprint)
                : messageId;
          }
          await _insertMergedConversation(
            sourceId: sourceId,
            targetId: targetId,
            messageIdMap: messageIdMap,
          );
          imported += 1;
          importedIds.add(targetId);
        }

        final foreignKeyFailures = await _db
            .customSelect('PRAGMA foreign_key_check;')
            .get();
        if (foreignKeyFailures.isNotEmpty) {
          throw StateError('foreign_key_check');
        }
        return BackupMergeReport(
          importedConversations: imported,
          deduplicatedConversations: deduplicated,
          skippedConversations: skipped,
          remappedConversationIds: Map.unmodifiable(remapped),
          importedConversationIds: List.unmodifiable(importedIds),
        );
      });
    } finally {
      if (attached) {
        await _db.customStatement('DETACH DATABASE merge_source;');
      }
    }
  }

  /// 仅 Chats 的 restore/merge：将本地 attachment parts 标记为 unavailable，
  /// 除非它们来自 remote/data。不会复用 asset_rows 中 path/hash 的巧合。
  Future<int> recomputeAttachmentAvailabilityForConversations({
    required Iterable<String> conversationIds,
    required bool filesRestored,
  }) async {
    final ids = conversationIds.toList(growable: false);
    if (ids.isEmpty) return 0;
    var updated = 0;
    for (final conversationId in ids) {
      final messages = await getMessagesRange(
        conversationId,
        start: 0,
        limit: 100000,
      );
      for (final message in messages) {
        final nextParts = <MessagePart>[];
        var changed = false;
        for (final part in message.parts) {
          if (part is ImagePart) {
            final unavailable = await _unavailableForRestoredPart(
              uri: part.uri,
              filesRestored: filesRestored,
            );
            if (unavailable != part.unavailable) changed = true;
            nextParts.add(
              ImagePart(
                uri: part.uri,
                mime: part.mime,
                assetId: part.assetId,
                unavailable: unavailable,
              ),
            );
          } else if (part is FilePart) {
            final unavailable = await _unavailableForRestoredPart(
              uri: part.uri,
              filesRestored: filesRestored,
            );
            if (unavailable != part.unavailable) changed = true;
            nextParts.add(
              FilePart(
                uri: part.uri,
                name: part.name,
                mime: part.mime,
                assetId: part.assetId,
                unavailable: unavailable,
              ),
            );
          } else {
            nextParts.add(part);
          }
        }
        if (!changed) continue;
        await updateMessage(message.copyWith(parts: nextParts));
        updated += 1;
      }
    }
    return updated;
  }

  Future<bool> _unavailableForRestoredPart({
    required String uri,
    required bool filesRestored,
  }) async {
    if (isRemoteOrDataUri(uri)) return false;
    if (filesRestored) {
      return !SandboxPathResolver.localFileExists(uri);
    }
    // 仅 Chats：绝不能信任候选 asset_rows 的 path / content_hash
    // 在目标机器上的巧合（同一 path 可能包含不同的 bytes）。
    // 复用需要对目标机器上的实际文件做 hash 并比较 bytes。
    return true;
  }

  /// 使用原生 sqlite3 打开 [databaseFile]，并在 [filesRestored] 为 false 时
  /// 将本地附件标记为不可用（覆盖发布前仅聊天候选的处理逻辑）。避免在恢复
  /// 暂存阶段打开 Drift isolate。
  ///
  /// 最小策略：每个非 remote/data 的本地附件都会变为不可用。这里刻意**不复用**
  /// 候选项 `asset_rows` 的 content_hash + 路径存在性——那会把候选项目自己的
  /// 绝对路径（或字节不同的目标冲突文件）当成证明。
  static Future<int> recomputeAttachmentAvailabilityOnDatabaseFile({
    required File databaseFile,
    required bool filesRestored,
  }) async {
    if (filesRestored) return 0;
    if (!await databaseFile.exists()) {
      throw FileSystemException(
        'Candidate database does not exist',
        databaseFile.path,
      );
    }
    return Future<int>.sync(() {
      final db = sqlite.sqlite3.open(databaseFile.absolute.path);
      try {
        final rows = db.select(
          "SELECT revision_id, ordinal, kind, payload "
          "FROM message_part_rows WHERE kind IN ('image', 'file');",
        );
        var updated = 0;
        final stmt = db.prepare(
          'UPDATE message_part_rows SET payload = ? '
          'WHERE revision_id = ? AND ordinal = ?;',
        );
        try {
          for (final row in rows) {
            final payload = row['payload'] as String;
            final decoded = jsonDecode(payload);
            if (decoded is! Map) continue;
            final map = Map<String, dynamic>.from(decoded);
            final uri = (map['uri'] ?? '').toString();
            if (uri.isEmpty || isRemoteOrDataUri(uri)) continue;
            if (map['unavailable'] == true) continue;
            map['unavailable'] = true;
            stmt.execute([jsonEncode(map), row['revision_id'], row['ordinal']]);
            updated += 1;
          }
        } finally {
          stmt.close();
        }
        return updated;
      } finally {
        db.close();
      }
    });
  }

  Future<String?> _conversationFingerprint(String schema, String id) async {
    final conversation = await _db
        .customSelect(
          'SELECT title, created_at, updated_at, is_pinned, assistant_id, '
          'truncate_index, version_selections_json, summary, '
          'last_summarized_message_count, chat_suggestions_json '
          'FROM $schema.conversation_rows WHERE id = ?;',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (conversation == null) return null;
    final mcpRows = await _db
        .customSelect(
          'SELECT server_id, ordinal FROM $schema.conversation_mcp_server_rows '
          'WHERE conversation_id = ? ORDER BY ordinal, server_id;',
          variables: [Variable<String>(id)],
        )
        .get();
    final messageRows = await _db
        .customSelect(
          'SELECT id, role, timestamp, model_id, provider_id, '
          'total_tokens, is_streaming, reasoning_start_at, '
          'reasoning_finished_at, translation, reasoning_segments_json, group_id, '
          'version, prompt_tokens, completion_tokens, cached_tokens, duration_ms, '
          'message_order FROM $schema.message_rows WHERE conversation_id = ? '
          'ORDER BY message_order, id;',
          variables: [Variable<String>(id)],
        )
        .get();
    // 文本/推理/工具负载和思考签名从物化的 parts/artifacts 中提取指纹；
    // part_id、时间戳和序号被排除，使相同负载在不同快照中哈希一致。两者
    // 每个会话只加载一次：合并大型备份时会对每个候选 id 调用本逻辑，
    // 因此逐消息查询会使每条消息产生四次数据库往返。它们通过 message_rows
    // 联接，而不是信任反规范化的 message_part_rows.conversation_id，
    // 与指纹一直使用的按修订版本分组保持一致。
    final partRows = await _db
        .customSelect(
          'SELECT p.revision_id, p.kind, p.payload '
          'FROM $schema.message_part_rows p '
          'INNER JOIN $schema.message_rows m ON m.id = p.revision_id '
          'WHERE m.conversation_id = ? '
          'ORDER BY p.revision_id, p.ordinal;',
          variables: [Variable<String>(id)],
        )
        .get();
    final partPayloads = <String, Map<String, List<String>>>{};
    // Image/file identity payloads 按 ordinal 顺序排列（unavailable 已剥离）。
    final attachmentPayloads = <String, List<String>>{};
    for (final part in partRows) {
      final revisionId = part.read<String>('revision_id');
      final kind = part.read<String>('kind');
      final payload = part.read<String>('payload');
      if (kind == 'image' || kind == 'file') {
        attachmentPayloads
            .putIfAbsent(revisionId, () => [])
            .add(_fingerprintAttachmentPayload(kind, payload));
        continue;
      }
      partPayloads
          .putIfAbsent(revisionId, () => {})
          .putIfAbsent(kind, () => [])
          .add(payload);
    }
    final signatureRows = await _db
        .customSelect(
          'SELECT a.revision_id, a.payload '
          'FROM $schema.provider_artifact_rows a '
          'INNER JOIN $schema.message_rows m ON m.id = a.revision_id '
          "WHERE m.conversation_id = ? AND a.kind = 'gemini_thought_signature';",
          variables: [Variable<String>(id)],
        )
        .get();
    final signatures = {
      for (final row in signatureRows)
        row.read<String>('revision_id'): row.read<String>('payload'),
    };
    final messages = <Object?>[];
    final groupOrdinals = <String, int>{};
    for (final row in messageRows) {
      final messageId = row.read<String>('id');
      final payloads = partPayloads[messageId];
      final data = Map<String, Object?>.from(row.data)..remove('id');
      data['is_streaming'] = 0;
      for (final field in const [
        'timestamp',
        'reasoning_start_at',
        'reasoning_finished_at',
      ]) {
        data[field] = _fingerprintTimestamp(data[field]);
      }
      final groupId = data.remove('group_id')?.toString() ?? '';
      data['group_ordinal'] = groupOrdinals.putIfAbsent(
        groupId,
        () => groupOrdinals.length,
      );
      messages.add([
        data,
        payloads?['text'],
        payloads?['reasoning'],
        payloads?['tool_call'],
        attachmentPayloads[messageId],
        signatures[messageId],
      ]);
    }
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              _normalizedConversationFingerprintData(
                conversation.data,
                groupOrdinals,
              ),
              mcpRows.map((row) => row.data).toList(),
              messages,
            ]),
          ),
        )
        .toString();
  }

  Map<String, Object?> _normalizedConversationFingerprintData(
    Map<String, Object?> data,
    Map<String, int> groupOrdinals,
  ) {
    final normalized = Map<String, Object?>.from(data);
    normalized['created_at'] = _fingerprintTimestamp(normalized['created_at']);
    normalized['updated_at'] = _fingerprintTimestamp(normalized['updated_at']);
    final rawSelections = normalized['version_selections_json'];
    if (rawSelections is String) {
      final decoded = _decodeStringIntMap(rawSelections);
      final selections = <String, int>{};
      for (final entry in decoded.entries) {
        final ordinal = groupOrdinals[entry.key];
        if (ordinal != null) selections['$ordinal'] = entry.value;
      }
      normalized['version_selections_json'] = selections;
    }
    return normalized;
  }

  /// 用于 merge fingerprints 的 attachment identity。丢弃环境状态
  /// `unavailable`，使同一 attachment 在一台设备可用、在另一台缺失时仍能去重；
  /// 保留 uri/name/mime/assetId 和 ordinal 顺序。
  String _fingerprintAttachmentPayload(String kind, String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return jsonEncode({'kind': kind, 'raw': payload});
      final map = Map<String, Object?>.from(decoded);
      return jsonEncode({
        'kind': kind,
        'uri': map['uri'],
        if (map['name'] != null) 'name': map['name'],
        if (map['mime'] != null) 'mime': map['mime'],
        if (map['assetId'] != null) 'assetId': map['assetId'],
      });
    } catch (_) {
      return jsonEncode({'kind': kind, 'raw': payload});
    }
  }

  Object? _fingerprintTimestamp(Object? value) {
    if (value is int) return value ~/ Duration.microsecondsPerSecond;
    if (value is num) {
      return value.toInt() ~/ Duration.microsecondsPerSecond;
    }
    return value;
  }

  Future<List<String>> _messageIds(String schema, String conversationId) async {
    final rows = await _db
        .customSelect(
          'SELECT id FROM $schema.message_rows WHERE conversation_id = ? '
          'ORDER BY message_order, id;',
          variables: [Variable<String>(conversationId)],
        )
        .get();
    return rows.map((row) => row.read<String>('id')).toList(growable: false);
  }

  /// 消息删除会故意保留 `message_order` 的空洞，因此稀疏序号是合法的；
  /// 这里仅拒绝绕过了数据库约束的负值或重复值。
  Future<void> _requireValidMessageOrder(
    String schema,
    String conversationId,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT message_order FROM $schema.message_rows '
          'WHERE conversation_id = ? ORDER BY message_order, id;',
          variables: [Variable<String>(conversationId)],
        )
        .get();
    int? previous;
    for (final row in rows) {
      final order = row.read<int>('message_order');
      if (order < 0 || (previous != null && order <= previous)) {
        throw StateError('conversation_message_order');
      }
      previous = order;
    }
  }

  Future<bool> _anyMessageIdExists(List<String> ids) async {
    for (final id in ids) {
      final row = await _db
          .customSelect(
            'SELECT 1 AS found FROM main.message_rows WHERE id = ? LIMIT 1;',
            variables: [Variable<String>(id)],
          )
          .getSingleOrNull();
      if (row != null) return true;
    }
    return false;
  }

  String _deterministicMergeId(String kind, String id, String fingerprint) {
    final digest = sha256.convert(
      utf8.encode('$kind\u0000$id\u0000$fingerprint'),
    );
    return 'merge-${digest.toString().substring(0, 32)}';
  }

  Future<void> _insertMergedConversation({
    required String sourceId,
    required String targetId,
    required Map<String, String> messageIdMap,
  }) async {
    final sourceMessages = await _db
        .customSelect(
          'SELECT id, group_id FROM merge_source.message_rows '
          'WHERE conversation_id = ? ORDER BY message_order, id;',
          variables: [Variable<String>(sourceId)],
        )
        .get();
    final remapping = sourceId != targetId;
    final groupIdMap = <String, String>{};
    for (final row in sourceMessages) {
      // 分组以 COALESCE(group_id, id) 为键：首个修订保留 null group_id，
      // 后续版本携带该修订的 id。因此重映射后的分组必须跟随锚点修订的
      // 新 id，否则锚点和其后续版本会落入两个不同的组。
      final groupId =
          row.data['group_id']?.toString() ?? row.read<String>('id');
      if (groupIdMap.containsKey(groupId)) continue;
      groupIdMap[groupId] =
          messageIdMap[groupId] ??
          (remapping
              ? _deterministicMergeId('group', groupId, targetId)
              : groupId);
    }
    final sourceConversation = await _db
        .customSelect(
          'SELECT version_selections_json FROM merge_source.conversation_rows '
          'WHERE id = ?;',
          variables: [Variable<String>(sourceId)],
        )
        .getSingle();
    final sourceSelections = _decodeStringIntMap(
      sourceConversation.read<String>('version_selections_json'),
    );
    final targetSelections = <String, int>{};
    for (final entry in sourceSelections.entries) {
      targetSelections[groupIdMap[entry.key] ?? entry.key] = entry.value;
    }
    await _db.customStatement(
      'INSERT INTO main.conversation_rows '
      '(id, title, created_at, updated_at, is_pinned, assistant_id, '
      'truncate_index, version_selections_json, summary, '
      'last_summarized_message_count, chat_suggestions_json, '
      'injected_memory_hash, last_memory_extracted_order) '
      'SELECT ?, title, created_at, updated_at, is_pinned, assistant_id, '
      'truncate_index, ?, summary, '
      'last_summarized_message_count, chat_suggestions_json, '
      'NULL, COALESCE((SELECT MAX(message_order) '
      'FROM merge_source.message_rows WHERE conversation_id = ?), -1) '
      'FROM merge_source.conversation_rows WHERE id = ?;',
      [targetId, jsonEncode(targetSelections), sourceId, sourceId],
    );
    await _db.customStatement(
      'INSERT INTO main.conversation_mcp_server_rows '
      '(conversation_id, server_id, ordinal) '
      'SELECT ?, server_id, ordinal FROM merge_source.conversation_mcp_server_rows '
      'WHERE conversation_id = ?;',
      [targetId, sourceId],
    );
    for (final entry in messageIdMap.entries) {
      final sourceMessage = sourceMessages.firstWhere(
        (row) => row.read<String>('id') == entry.key,
      );
      final sourceGroupId = sourceMessage.data['group_id']?.toString();
      // Anchor revisions 保留它们的 null group_id，这样合并后的 rows 描述的 groups
      // 与 snapshot 相同，并保持 fingerprint 一致。
      final targetGroupId = sourceGroupId == null
          ? null
          : (groupIdMap[sourceGroupId] ?? sourceGroupId);
      await _db.customStatement(
        'INSERT INTO main.message_rows '
        '(id, conversation_id, role, timestamp, model_id, provider_id, '
        'total_tokens, is_streaming, reasoning_start_at, '
        'reasoning_finished_at, translation, reasoning_segments_json, group_id, '
        'version, prompt_tokens, completion_tokens, cached_tokens, duration_ms, '
        'message_order) '
        'SELECT ?, ?, role, timestamp, model_id, provider_id, '
        'total_tokens, 0, reasoning_start_at, '
        'reasoning_finished_at, translation, reasoning_segments_json, '
        '?, version, '
        'prompt_tokens, completion_tokens, cached_tokens, duration_ms, '
        // message_order 是 conversation fingerprint 的一部分。原样保留它，
        // 以便稀疏的 snapshots 在重复 merge 时保持幂等。
        'message_order FROM merge_source.message_rows WHERE id = ?;',
        [entry.value, targetId, targetGroupId, entry.key],
      );
      await _db.customStatement(
        'INSERT INTO main.message_part_rows '
        '(conversation_id, revision_id, ordinal, kind, payload, '
        'created_at, updated_at) '
        'SELECT ?, ?, ordinal, kind, payload, created_at, updated_at '
        'FROM merge_source.message_part_rows WHERE revision_id = ?;',
        [targetId, entry.value, entry.key],
      );
      // generation_run_rows 有意不复制：合并后的 revisions
      // 始终以 non-streaming 方式持久化。
      await _db.customStatement(
        'INSERT INTO main.provider_artifact_rows '
        '(conversation_id, revision_id, kind, payload, created_at, updated_at) '
        'SELECT ?, ?, kind, payload, created_at, updated_at '
        'FROM merge_source.provider_artifact_rows WHERE revision_id = ?;',
        [targetId, entry.value, entry.key],
      );
    }
    // 合并的修订绕过了 _replaceMessageParts，因此在 GC 可能把附件文件视为
    // 未引用之前，先让带附件的修订加入资源引用回填队列。
    await _db.customStatement(
      'INSERT OR IGNORE INTO asset_reference_dirty_rows(revision_id) '
      'SELECT DISTINCT revision_id FROM main.message_part_rows '
      "WHERE conversation_id = ? AND kind IN ('image', 'file');",
      [targetId],
    );
    final sourceBranches = await _db
        .customSelect(
          'SELECT id, tip_message_id, name, created_at '
          'FROM merge_source.conversation_branch_rows '
          'WHERE conversation_id = ? ORDER BY id;',
          variables: [Variable<String>(sourceId)],
        )
        .get();
    final sourceState = await _db
        .customSelect(
          'SELECT * '
          'FROM merge_source.conversation_tree_state_rows '
          'WHERE conversation_id = ?;',
          variables: [Variable<String>(sourceId)],
        )
        .getSingleOrNull();
    final sourceEdges = await _db
        .customSelect(
          'SELECT message_id, parent_message_id '
          'FROM merge_source.message_tree_edge_rows '
          'WHERE conversation_id = ?;',
          variables: [Variable<String>(sourceId)],
        )
        .get();
    if (sourceState == null ||
        sourceBranches.isEmpty ||
        sourceEdges.length != sourceMessages.length) {
      await _rebuildLegacyConversationTree(targetId);
      return;
    }
    final branchIdMap = <String, String>{};
    for (final row in sourceBranches) {
      final sourceBranchId = row.read<String>('id');
      branchIdMap[sourceBranchId] = remapping
          ? _deterministicMergeId('branch', sourceBranchId, targetId)
          : sourceBranchId;
    }
    for (final edge in sourceEdges) {
      final sourceMessageId = edge.read<String>('message_id');
      final sourceParentId = edge.readNullable<String>('parent_message_id');
      await _db.customStatement(
        'INSERT INTO main.message_tree_edge_rows '
        '(conversation_id, message_id, parent_message_id) VALUES (?, ?, ?);',
        [
          targetId,
          messageIdMap[sourceMessageId]!,
          sourceParentId == null ? null : messageIdMap[sourceParentId]!,
        ],
      );
    }
    for (final branch in sourceBranches) {
      final sourceBranchId = branch.read<String>('id');
      final sourceTipId = branch.readNullable<String>('tip_message_id');
      await _db.customStatement(
        'INSERT INTO main.conversation_branch_rows '
        '(id, conversation_id, tip_message_id, name, created_at) '
        'VALUES (?, ?, ?, ?, ?);',
        [
          branchIdMap[sourceBranchId]!,
          targetId,
          sourceTipId == null ? null : messageIdMap[sourceTipId]!,
          branch.read<String>('name'),
          branch.read<int>('created_at'),
        ],
      );
    }
    final sourceBranchSelections = _decodeBranchSelections(
      sourceState.data['branch_selections_json']?.toString() ?? '{}',
    );
    final targetBranchSelections = <String, String>{};
    for (final entry in sourceBranchSelections.entries) {
      final targetMessageId = messageIdMap[entry.key];
      final targetBranchId = branchIdMap[entry.value];
      if (targetMessageId != null && targetBranchId != null) {
        targetBranchSelections[targetMessageId] = targetBranchId;
      }
    }
    final activeSourceBranchId = sourceState.read<String>('active_branch_id');
    final activeTargetBranchId = branchIdMap[activeSourceBranchId];
    if (activeTargetBranchId == null) {
      throw StateError('merge_source_active_branch_missing');
    }
    await _db.customStatement(
      'INSERT INTO main.conversation_tree_state_rows '
      '(conversation_id, active_branch_id, branch_selections_json) '
      'VALUES (?, ?, ?);',
      [targetId, activeTargetBranchId, jsonEncode(targetBranchSelections)],
    );
  }

  Future<void> _writeBackupData({
    required List<Conversation> conversations,
    required List<({ChatMessage message, int messageOrder})> messages,
    required Map<String, List<Map<String, dynamic>>> toolEventsByMessageId,
    required Map<String, String> geminiSignaturesByMessageId,
    // 当已知目标 rows 没有已存储的 parts（新数据库或刚清空的数据库）时为 true：
    // 此时缺少 tool events 表示“no events”，而不是“preserve stored ones”，
    // 从而跳过逐 message 的 SELECT。
    required bool freshParts,
  }) async {
    await _db.batch((batch) {
      for (final conversation in conversations) {
        batch.insert(
          _db.conversationRows,
          _conversationCompanion(conversation),
          mode: InsertMode.insertOrReplace,
        );
        for (var i = 0; i < conversation.mcpServerIds.length; i++) {
          batch.insert(
            _db.conversationMcpServerRows,
            ConversationMcpServerRowsCompanion.insert(
              conversationId: conversation.id,
              serverId: conversation.mcpServerIds[i],
              ordinal: i,
            ),
            mode: InsertMode.insertOrReplace,
          );
        }
      }
      for (final entry in messages) {
        batch.insert(
          _db.messageRows,
          _messageCompanion(entry.message, entry.messageOrder),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
    // Parts/artifacts 是 tool events 和 thought signatures 的唯一持久化载体；
    // legacy tables 不再接收写入。
    final batchMessageIds = <String>{};
    for (final entry in messages) {
      final id = entry.message.id;
      batchMessageIds.add(id);
      await _replaceMessageParts(
        entry.message,
        toolEvents:
            toolEventsByMessageId[id] ??
            (freshParts ? const <Map<String, dynamic>>[] : null),
      );
    }
    for (final entry in toolEventsByMessageId.entries) {
      if (batchMessageIds.contains(entry.key)) continue;
      final message = await getMessage(entry.key);
      if (message == null) throw StateError('tool_event_message_missing');
      await _replaceMessageParts(message, toolEvents: entry.value);
    }
    for (final entry in geminiSignaturesByMessageId.entries) {
      await _upsertGeminiThoughtSignature(entry.key, entry.value);
    }
    // _replaceMessageParts 已将带 attachment 的 revisions 入队；批量标记
    // 作为 asset backfill 不变量的低成本保险保留。
    await _markMessageAssetReferencesDirtyBatch([
      for (final entry in messages)
        if (_messageHasAttachmentParts(entry.message)) entry.message.id,
    ]);
    final affectedConversationIds = <String>{
      for (final conversation in conversations) conversation.id,
      for (final entry in messages) entry.message.conversationId,
    };
    for (final conversationId in affectedConversationIds) {
      await _rebuildLegacyConversationTree(conversationId);
    }
  }

  Future<void> _rebuildLegacyConversationTree(String conversationId) async {
    final conversationRow = await (_db.select(
      _db.conversationRows,
    )..where((row) => row.id.equals(conversationId))).getSingleOrNull();
    if (conversationRow == null) return;
    final rows =
        await (_db.select(_db.messageRows)
              ..where((row) => row.conversationId.equals(conversationId))
              ..orderBy([
                (row) => OrderingTerm.asc(row.messageOrder),
                (row) => OrderingTerm.asc(row.id),
              ]))
            .get();
    final groups = <String, List<MessageRow>>{};
    for (final row in rows) {
      groups.putIfAbsent(row.groupId ?? row.id, () => <MessageRow>[]).add(row);
    }
    final selections = _decodeStringIntMap(
      conversationRow.versionSelectionsJson,
    );
    final edges = <String, MessageTreeEdge>{};
    final branches = <String, ConversationBranch>{};
    String? previousSelectedId;
    for (final entry in groups.entries) {
      final versions = entry.value
        ..sort((left, right) {
          final byVersion = left.version.compareTo(right.version);
          if (byVersion != 0) return byVersion;
          return left.id.compareTo(right.id);
        });
      final selectedVersion = selections[entry.key];
      final selected =
          versions.cast<MessageRow?>().firstWhere(
            (row) => row!.version == selectedVersion,
            orElse: () => null,
          ) ??
          versions.last;
      for (final version in versions) {
        edges[version.id] = MessageTreeEdge(
          messageId: version.id,
          parentMessageId: previousSelectedId,
        );
        if (version.id != selected.id) {
          final branchId = 'legacy-${version.id}';
          branches[branchId] = ConversationBranch(
            id: branchId,
            conversationId: conversationId,
            tipMessageId: version.id,
            createdAt: version.timestamp,
          );
        }
      }
      previousSelectedId = selected.id;
    }
    final rootBranchId = _conversationRootBranchId(conversationId);
    branches[rootBranchId] = ConversationBranch(
      id: rootBranchId,
      conversationId: conversationId,
      tipMessageId: previousSelectedId,
      createdAt: conversationRow.createdAt,
    );
    await _writeConversationTree(
      ConversationTree(
        conversationId: conversationId,
        activeBranchId: rootBranchId,
        branches: branches,
        edges: edges,
      ),
    );
  }

  Future<void> updateMessage(ChatMessage message) async {
    await _db.transaction(() async {
      await _updateMessageRow(message);
      await _replaceMessageParts(message);
    });
  }

  Future<void> _updateMessageRow(ChatMessage message) async {
    await (_db.update(
      _db.messageRows,
    )..where((t) => t.id.equals(message.id))).write(_messageUpdate(message));
  }

  /// 部分列 UPDATE：只写入非 null 字段，因此写方修改互不相交的列时不会互相覆盖。
  /// 仅当内容或推理文本变化时才重建消息 parts；其他列绝不会影响 parts。返回
  /// 更新后的消息；没有行匹配 [messageId] 时返回 null。
  Future<ChatMessage?> updateMessageFields(
    String messageId, {
    String? role,
    String? content,
    int? totalTokens,
    bool? isStreaming,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    String? translation,
    String? reasoningSegmentsJson,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    final companion = MessageRowsCompanion(
      role: role != null ? Value(role) : const Value.absent(),
      totalTokens: totalTokens != null
          ? Value(totalTokens)
          : const Value.absent(),
      isStreaming: isStreaming != null
          ? Value(isStreaming)
          : const Value.absent(),
      reasoningStartAt: reasoningStartAt != null
          ? Value(reasoningStartAt)
          : const Value.absent(),
      reasoningFinishedAt: reasoningFinishedAt != null
          ? Value(reasoningFinishedAt)
          : const Value.absent(),
      translation: translation != null
          ? Value(translation)
          : const Value.absent(),
      reasoningSegmentsJson: reasoningSegmentsJson != null
          ? Value(reasoningSegmentsJson)
          : const Value.absent(),
      promptTokens: promptTokens != null
          ? Value(promptTokens)
          : const Value.absent(),
      completionTokens: completionTokens != null
          ? Value(completionTokens)
          : const Value.absent(),
      cachedTokens: cachedTokens != null
          ? Value(cachedTokens)
          : const Value.absent(),
      durationMs: durationMs != null ? Value(durationMs) : const Value.absent(),
    );
    return _db.transaction(() async {
      await (_db.update(
        _db.messageRows,
      )..where((t) => t.id.equals(messageId))).write(companion);
      final updated = await getMessage(messageId);
      if (updated == null) return null;
      if (content == null && reasoningText == null) return updated;
      // getMessage 会从 parts 中解析内容和推理，而它们仍保存着更新前的负载。
      // 只覆盖提供的字段，这样仅写内容不会清空推理（反之亦然）。
      final corrected = updated.copyWith(
        content: content ?? updated.content,
        reasoningText: reasoningText ?? updated.reasoningText,
      );
      await _replaceMessageParts(corrected);
      return corrected;
    });
  }

  Future<void> updateStreamingCheckpoint(
    ChatMessage message,
    List<Map<String, dynamic>> toolEvents, {
    String? generationRunId,
    int? checkpointSeq,
  }) {
    if ((generationRunId == null) != (checkpointSeq == null)) {
      throw ArgumentError('generationRunId and checkpointSeq must pair');
    }
    return _observer.measure(
      message.isStreaming
          ? ChatDatabaseOperation.commandStreamingCheckpoint
          : ChatDatabaseOperation.commandFinalCheckpoint,
      () => _updateStreamingCheckpoint(
        message,
        toolEvents,
        generationRunId: generationRunId,
        checkpointSeq: checkpointSeq,
      ),
    );
  }

  Future<void> _updateStreamingCheckpoint(
    ChatMessage message,
    List<Map<String, dynamic>> toolEvents, {
    String? generationRunId,
    int? checkpointSeq,
  }) async {
    await _db.transaction(() async {
      // 防止迟到的 flush 复活已终结的消息。
      // 流式快照（is_streaming = true）在最终写入已提交（行 is_streaming = 0）后到达时，
      // 绝不能覆盖最终内容，也不能把 is_streaming 重新打开（这还会把它从搜索
      // 索引中移除）。最终写入携带 is_streaming = false，因此不受影响。
      if (message.isStreaming) {
        final existing =
            await (_db.select(_db.messageRows)
                  ..where((row) => row.id.equals(message.id))
                  ..limit(1))
                .getSingleOrNull();
        if (existing != null && !existing.isStreaming) {
          return;
        }
      }
      // 保持 message_rows（包括 is_streaming）先于 parts 重写，以便
      // FTS finalize 触发器正确索引重写前的 text part。
      await _updateMessageRow(message);
      await _replaceMessageParts(
        message,
        toolEvents: toolEvents,
        preserveUnchangedToolParts: true,
      );
      if (generationRunId != null && checkpointSeq != null) {
        await GenerationRunCommands(_db).checkpoint(
          id: generationRunId,
          targetRevisionId: message.id,
          checkpointSeq: checkpointSeq,
          updatedAt: DateTime.now().toUtc(),
        );
      }
    });
  }

  @Deprecated('legacy/test only; rewrites the complete conversation order')
  Future<void> updateConversationMessages({
    required Conversation conversation,
    required List<String> messageIds,
  }) async {
    await _db.transaction(() async {
      await _db
          .into(_db.conversationRows)
          .insertOnConflictUpdate(
            _conversationCompanion(
              conversation.copyWith(messageIds: List<String>.of(messageIds)),
            ),
          );
      await _replaceMcpServers(conversation.id, conversation.mcpServerIds);
      await _rewriteMessageOrder(conversation.id, messageIds);
    });
  }

  Future<void> deleteConversation(String id) async {
    await (_db.delete(
      _db.conversationRows,
    )..where((t) => t.id.equals(id))).go();
  }

  Future<void> deleteMessage(String messageId) async {
    final row = await getMessage(messageId);
    if (row == null) return;
    await deleteMessages(
      conversationId: row.conversationId,
      messageIds: {messageId},
      versionSelectionChanges: const {},
    );
  }

  Future<DeletedMessagesResult?> deleteMessages({
    required String conversationId,
    required Set<String> messageIds,
    required Map<String, int?> versionSelectionChanges,
  }) {
    return _observer.measure(
      ChatDatabaseOperation.commandDeleteMessages,
      () async {
        return _deleteMessages(
          conversationId: conversationId,
          messageIds: messageIds,
          versionSelectionChanges: versionSelectionChanges,
        );
      },
    );
  }

  Future<DeletedMessagesResult?> _deleteMessages({
    required String conversationId,
    required Set<String> messageIds,
    required Map<String, int?> versionSelectionChanges,
  }) async {
    if (messageIds.isEmpty) return null;
    for (final entry in versionSelectionChanges.entries) {
      if (entry.key.isEmpty || (entry.value != null && entry.value! < 0)) {
        throw ArgumentError.value(
          versionSelectionChanges,
          'versionSelectionChanges',
          'Group IDs must be non-empty and versions non-negative.',
        );
      }
    }
    return _db.transaction(() async {
      final conversationRow = await (_db.select(
        _db.conversationRows,
      )..where((row) => row.id.equals(conversationId))).getSingleOrNull();
      if (conversationRow == null) return null;
      final rows =
          await (_db.select(_db.messageRows)
                ..where((row) => row.conversationId.equals(conversationId))
                ..orderBy([(row) => OrderingTerm.asc(row.messageOrder)]))
              .get();
      final requestedRows = rows
          .where((row) => messageIds.contains(row.id))
          .toList(growable: false);
      if (requestedRows.isEmpty) return null;
      if (requestedRows.length != messageIds.length) {
        throw StateError('delete_messages_not_found');
      }

      final treeBeforeDelete = await _loadOrCreateConversationTree(
        conversationId,
      );
      var treeAfterDelete = treeBeforeDelete;
      for (final row in requestedRows) {
        treeAfterDelete = treeAfterDelete.deleteSubtree(row.id);
      }
      final survivingEdges = treeAfterDelete.edges.keys.toSet();
      final effectiveMessageIds = treeBeforeDelete.edges.keys
          .where((id) => !survivingEdges.contains(id))
          .toSet();
      if (treeAfterDelete.activeBranchId != treeBeforeDelete.activeBranchId) {
        debugPrint(
          'conversation_tree_active_branch_fallback: '
          '$conversationId ${treeBeforeDelete.activeBranchId} '
          '-> ${treeAfterDelete.activeBranchId}',
        );
      }

      final deletedRows = rows
          .where((row) => effectiveMessageIds.contains(row.id))
          .toList(growable: false);
      if (deletedRows.isEmpty) return null;

      // 版本组在时间线查询中以 MIN(message_order) 为锚，后续 revision 得到
      // 会话末尾的 order。因此删除锚行会让幸存 revision 漂移到追加位置
      // （例如编辑会话后删除旧版本，组会跳到底部）。为了保留组位置，把
      // 最早幸存 revision 移回释放出来的锚 order。锚槽保证空闲：它属于本次
      // 事务删除的同一组行，而不同组不会共享锚行。
      final anchorRewrites = <String, int>{};
      final rowsByGroup = <String, List<MessageRow>>{};
      for (final row in rows) {
        rowsByGroup
            .putIfAbsent(row.groupId ?? row.id, () => <MessageRow>[])
            .add(row);
      }
      for (final group in rowsByGroup.values) {
        // `rows` 按 message_order 排序，因此 group.first 是锚点。
        final anchor = group.first;
        if (!effectiveMessageIds.contains(anchor.id)) continue;
        MessageRow? survivor;
        for (final row in group) {
          if (!effectiveMessageIds.contains(row.id)) {
            survivor = row;
            break;
          }
        }
        if (survivor == null) continue;
        anchorRewrites[survivor.id] = anchor.messageOrder;
      }

      final remainingRows = rows
          .where((row) => !effectiveMessageIds.contains(row.id))
          .toList(growable: false);
      final effectiveOrders = <String, int>{
        for (final row in remainingRows)
          row.id: anchorRewrites[row.id] ?? row.messageOrder,
      };
      final orderedIds = remainingRows.map((row) => row.id).toList()
        ..sort((a, b) => effectiveOrders[a]!.compareTo(effectiveOrders[b]!));

      final deletedIds = deletedRows
          .map((row) => row.id)
          .toList(growable: false);
      await (_db.delete(
        _db.generationRunRows,
      )..where((row) => row.targetRevisionId.isIn(deletedIds))).go();
      await (_db.delete(
        _db.messageRows,
      )..where((row) => row.id.isIn(deletedIds))).go();
      for (final rewrite in anchorRewrites.entries) {
        await (_db.update(_db.messageRows)
              ..where((row) => row.id.equals(rewrite.key)))
            .write(MessageRowsCompanion(messageOrder: Value(rewrite.value)));
      }
      await _writeConversationTree(treeAfterDelete);
      final currentConversation = await _conversationFromRow(
        conversationRow,
        includeMessageIds: false,
      );
      final selections = Map<String, int>.from(
        currentConversation.versionSelections,
      );
      for (final entry in versionSelectionChanges.entries) {
        final version = entry.value;
        if (version == null) {
          selections.remove(entry.key);
        } else {
          selections[entry.key] = version;
        }
      }
      final remainingByGroup = <String, List<MessageRow>>{};
      for (final row in rows) {
        if (effectiveMessageIds.contains(row.id)) continue;
        remainingByGroup
            .putIfAbsent(row.groupId ?? row.id, () => <MessageRow>[])
            .add(row);
      }
      for (final groupId in selections.keys.toList(growable: false)) {
        final remaining = remainingByGroup[groupId];
        if (remaining == null || remaining.isEmpty) {
          selections.remove(groupId);
          continue;
        }
        final selectedVersion = selections[groupId];
        if (!remaining.any((row) => row.version == selectedVersion)) {
          selections[groupId] = remaining
              .map((row) => row.version)
              .reduce((left, right) => left > right ? left : right);
        }
      }
      final conversation = currentConversation.copyWith(
        messageIds: orderedIds,
        versionSelections: selections,
        chatSuggestions: const <String>[],
        updatedAt: DateTime.now(),
      );
      await (_db.update(_db.conversationRows)
            ..where((row) => row.id.equals(conversationId)))
          .write(_conversationCompanion(conversation));
      // 调用方（ChatService.deleteMessages）只需要 message.id 用于缓存
      // 失效；正文文本有意省略。
      return (
        conversation: conversation,
        messages: [
          for (final row in deletedRows)
            ChatMessage(
              id: row.id,
              role: row.role,
              content: '',
              timestamp: row.timestamp,
              conversationId: row.conversationId,
              groupId: row.groupId,
              version: row.version,
            ),
        ],
      );
    });
  }

  Future<void> clearAllData() async {
    await _db.transaction(() async {
      await _clearChatRows();
    });
  }

  Future<void> _clearChatRows() async {
    await _db.delete(_db.conversationMcpServerRows).go();
    await _db.delete(_db.messageRows).go();
    await _db.delete(_db.conversationRows).go();
    await (_db.delete(
      _db.chatStorageMetaRows,
    )..where((t) => t.key.equals(ChatStorageMetaKeys.activeStreamingIds))).go();
  }

  Future<List<Map<String, dynamic>>> getToolEvents(String messageId) async {
    return (await getToolEventsForMessages([messageId]))[messageId] ??
        const <Map<String, dynamic>>[];
  }

  Future<Map<String, List<Map<String, dynamic>>>> getToolEventsForMessages(
    Iterable<String> messageIds,
  ) async {
    final ids = messageIds.toSet();
    if (ids.isEmpty) return const {};
    final partRows =
        await (_db.select(_db.messagePartRows)
              ..where(
                (row) =>
                    row.revisionId.isIn(ids) & row.kind.equals('tool_call'),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
            .get();
    final result = <String, List<Map<String, dynamic>>>{};
    for (final row in partRows) {
      final decoded = jsonDecode(row.payload);
      if (decoded is Map) {
        result
            .putIfAbsent(row.revisionId, () => <Map<String, dynamic>>[])
            .add(Map<String, dynamic>.from(decoded));
      }
    }
    return result;
  }

  Future<void> setToolEvents(
    String messageId,
    List<Map<String, dynamic>> events,
  ) async {
    await _db.transaction(() async {
      final message = await getMessage(messageId);
      if (message == null) throw StateError('tool_event_message_missing');
      await _replaceMessageParts(message, toolEvents: events);
    });
  }

  Future<void> deleteToolEvents(String messageId) async {
    await _db.transaction(() async {
      final message = await getMessage(messageId);
      if (message != null) {
        await _replaceMessageParts(message, toolEvents: const []);
      }
    });
  }

  Future<String?> getGeminiThoughtSignature(String messageId) async {
    return (await getGeminiThoughtSignaturesForMessages([
      messageId,
    ]))[messageId];
  }

  Future<Map<String, String>> getGeminiThoughtSignaturesForMessages(
    Iterable<String> messageIds,
  ) async {
    final ids = messageIds.toSet();
    if (ids.isEmpty) return const {};
    final rows =
        await (_db.select(_db.providerArtifactRows)..where(
              (row) =>
                  row.revisionId.isIn(ids) &
                  row.kind.equals('gemini_thought_signature'),
            ))
            .get();
    final result = <String, String>{
      for (final row in rows)
        if (row.payload.trim().isNotEmpty) row.revisionId: row.payload.trim(),
    };
    return result;
  }

  Future<void> setGeminiThoughtSignature(
    String messageId,
    String signature,
  ) async {
    await _db.transaction(() async {
      await _upsertGeminiThoughtSignature(messageId, signature);
    });
  }

  static const String imageOcrArtifactKind = 'image_ocr_v1';

  /// 批量加载各修订的 OCR 产物。
  ///
  /// 返回 revisionId → (contentHash → OCR text)。
  Future<Map<String, Map<String, String>>> getImageOcrArtifacts(
    Iterable<String> revisionIds,
  ) async {
    final ids = revisionIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return const {};
    final rows =
        await (_db.select(_db.providerArtifactRows)..where(
              (row) =>
                  row.revisionId.isIn(ids) &
                  row.kind.equals(imageOcrArtifactKind),
            ))
            .get();
    final result = <String, Map<String, String>>{};
    for (final row in rows) {
      final items = _decodeImageOcrPayload(row.payload);
      if (items.isEmpty) continue;
      result[row.revisionId] = items;
    }
    return result;
  }

  /// 将 OCR 条目合并进修订产物并 upsert。
  Future<void> upsertImageOcrArtifactItems({
    required String revisionId,
    required Map<String, String> items,
  }) async {
    final cleaned = <String, String>{
      for (final entry in items.entries)
        if (entry.key.trim().isNotEmpty && entry.value.trim().isNotEmpty)
          entry.key.trim(): entry.value.trim(),
    };
    if (cleaned.isEmpty) return;

    await _db.transaction(() async {
      final message = await (_db.select(
        _db.messageRows,
      )..where((row) => row.id.equals(revisionId))).getSingleOrNull();
      if (message == null) {
        throw StateError('provider_artifact_revision_missing');
      }

      final existingRows =
          await (_db.select(_db.providerArtifactRows)..where(
                (row) =>
                    row.revisionId.equals(revisionId) &
                    row.kind.equals(imageOcrArtifactKind),
              ))
              .get();
      final merged = <String, String>{
        for (final row in existingRows) ..._decodeImageOcrPayload(row.payload),
        ...cleaned,
      };
      final now = DateTime.now().toUtc();
      final createdAt = existingRows.isNotEmpty
          ? existingRows.first.createdAt
          : message.timestamp;
      final updatedAt = now.isBefore(createdAt) ? createdAt : now;
      await _db
          .into(_db.providerArtifactRows)
          .insertOnConflictUpdate(
            ProviderArtifactRowsCompanion.insert(
              conversationId: message.conversationId,
              revisionId: revisionId,
              kind: imageOcrArtifactKind,
              payload: _encodeImageOcrPayload(merged),
              createdAt: createdAt,
              updatedAt: updatedAt,
            ),
          );
    });
  }

  /// 将仍然存在的图片 OCR 条目从一个修订复制到另一个修订。
  Future<void> inheritImageOcrArtifacts({
    required String fromRevisionId,
    required String toRevisionId,
    required Set<String> retainedContentHashes,
  }) async {
    if (retainedContentHashes.isEmpty) return;
    if (fromRevisionId == toRevisionId) return;
    final source = await getImageOcrArtifacts([fromRevisionId]);
    final items = source[fromRevisionId];
    if (items == null || items.isEmpty) return;
    final inherited = <String, String>{
      for (final entry in items.entries)
        if (retainedContentHashes.contains(entry.key) &&
            entry.value.trim().isNotEmpty)
          entry.key: entry.value.trim(),
    };
    if (inherited.isEmpty) return;
    await upsertImageOcrArtifactItems(
      revisionId: toRevisionId,
      items: inherited,
    );
  }

  /// 查找已知资源路径对应的 content hash。
  ///
  /// 具有多个不同 content hash 的路径会被省略，这样调用方就不会在该路径上的
  /// 文件变化后意外复用陈旧的 hash。
  Future<Map<String, String>> getAssetContentHashesByPaths(
    Iterable<String> paths,
  ) async {
    final normalized = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalized.isEmpty) return const {};
    final placeholders = List.filled(normalized.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          '''
          SELECT path, content_hash
          FROM asset_rows
          WHERE path IN ($placeholders)
          ORDER BY last_referenced_at DESC, created_at DESC, id DESC;
          ''',
          variables: [for (final path in normalized) Variable<String>(path)],
        )
        .get();
    final hashesByPath = <String, Set<String>>{};
    for (final row in rows) {
      final path = row.read<String>('path');
      final hash = row.read<String>('content_hash');
      if (path.isEmpty || hash.isEmpty) continue;
      hashesByPath.putIfAbsent(path, () => <String>{}).add(hash);
    }
    return {
      for (final entry in hashesByPath.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
  }

  /// 链接到某个修订的图片资源的 content hash。
  Future<Set<String>> getMessageImageContentHashes(String revisionId) async {
    final id = revisionId.trim();
    if (id.isEmpty) return const {};
    final rows = await _db
        .customSelect(
          '''
      SELECT a.content_hash AS content_hash
      FROM message_asset_rows m
      JOIN asset_rows a ON a.id = m.asset_id
      WHERE m.revision_id = ? AND m.kind = 'image';
      ''',
          variables: [Variable<String>(id)],
        )
        .get();
    return {
      for (final row in rows)
        if (row.read<String>('content_hash').trim().isNotEmpty)
          row.read<String>('content_hash').trim(),
    };
  }

  Map<String, String> _decodeImageOcrPayload(String payload) {
    final raw = payload.trim();
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final itemsRaw = decoded['items'];
      if (itemsRaw is! Map) return const {};
      final items = <String, String>{};
      for (final entry in itemsRaw.entries) {
        final hash = entry.key.toString().trim();
        final text = entry.value?.toString().trim() ?? '';
        if (hash.isEmpty || text.isEmpty) continue;
        items[hash] = text;
      }
      return items;
    } catch (_) {
      return const {};
    }
  }

  String _encodeImageOcrPayload(Map<String, String> items) {
    return jsonEncode({'version': 1, 'items': items});
  }

  Future<void> _upsertGeminiThoughtSignature(
    String messageId,
    String signature,
  ) async {
    final message = await (_db.select(
      _db.messageRows,
    )..where((row) => row.id.equals(messageId))).getSingleOrNull();
    if (message == null) {
      throw StateError('provider_artifact_revision_missing');
    }
    final now = DateTime.now().toUtc();
    await _db
        .into(_db.providerArtifactRows)
        .insertOnConflictUpdate(
          ProviderArtifactRowsCompanion.insert(
            conversationId: message.conversationId,
            revisionId: messageId,
            kind: 'gemini_thought_signature',
            payload: signature,
            createdAt: message.timestamp,
            updatedAt: now.isBefore(message.timestamp)
                ? message.timestamp
                : now,
          ),
        );
  }

  Future<void> deleteGeminiThoughtSignature(String messageId) async {
    await (_db.delete(_db.providerArtifactRows)..where(
          (row) =>
              row.revisionId.equals(messageId) &
              row.kind.equals('gemini_thought_signature'),
        ))
        .go();
  }

  Future<List<String>> getActiveStreamingIds() async {
    final rows =
        await (_db.select(_db.generationRunRows)..where(
              (row) => row.state.isIn(const [
                'preparing',
                'requesting',
                'streaming',
                'waiting_tool',
              ]),
            ))
            .get();
    return rows.map((row) => row.targetRevisionId).toList(growable: false);
  }

  Future<void> clearActiveStreamingIds() async {
    await (_db.delete(
      _db.chatStorageMetaRows,
    )..where((t) => t.key.equals(ChatStorageMetaKeys.activeStreamingIds))).go();
  }

  /// 原子地终结所有由先前进程遗留的 generation。
  Future<int> resetStaleStreamingState() async {
    return _db.transaction(() async {
      final activeStates = const [
        'preparing',
        'requesting',
        'streaming',
        'waiting_tool',
      ];
      final runs = await (_db.select(
        _db.generationRunRows,
      )..where((row) => row.state.isIn(activeStates))).get();
      final now = DateTime.now().toUtc();
      if (runs.isNotEmpty) {
        await (_db.update(
          _db.generationRunRows,
        )..where((row) => row.state.isIn(activeStates))).write(
          GenerationRunRowsCompanion(
            state: const Value('interrupted'),
            stateRevision: const Value.absent(),
            errorCode: const Value('app_restart'),
            updatedAt: Value(now),
            terminalAt: Value(now),
          ),
        );
        await _db.customUpdate(
          'UPDATE generation_run_rows '
          'SET state_revision = state_revision + 1 '
          "WHERE state = 'interrupted' AND terminal_at = ?;",
          variables: [Variable.withInt(now.microsecondsSinceEpoch)],
          updates: {_db.generationRunRows},
        );
      }
      // 清除 is_streaming 会触发 message_search_fts_finalize，从而索引
      // 已放弃流所留下的 checkpointed text parts。
      await (_db.update(_db.messageRows)
            ..where((row) => row.isStreaming.equals(true)))
          .write(const MessageRowsCompanion(isStreaming: Value(false)));
      await clearActiveStreamingIds();
      return runs.length;
    });
  }

  Future<void> markMigrationComplete() async {
    await _writeMigrationCompleteReceipt();
  }

  Future<void> _writeMigrationCompleteReceipt() async {
    await _db
        .into(_db.chatStorageMetaRows)
        .insertOnConflictUpdate(
          ChatStorageMetaRowsCompanion.insert(
            key: ChatStorageMetaKeys.hiveMigrationComplete,
            value: 'true',
          ),
        );
  }

  Future<bool> isMigrationComplete() async {
    final row =
        await (_db.select(_db.chatStorageMetaRows)..where(
              (t) => t.key.equals(ChatStorageMetaKeys.hiveMigrationComplete),
            ))
            .getSingleOrNull();
    return row?.value == 'true';
  }

  Future<int> _nextMessageOrder(String conversationId) async {
    final maxOrder = _db.messageRows.messageOrder.max();
    final row =
        await (_db.selectOnly(_db.messageRows)
              ..addColumns([maxOrder])
              ..where(_db.messageRows.conversationId.equals(conversationId)))
            .getSingle();
    return (row.read(maxOrder) ?? -1) + 1;
  }

  Future<void> _replaceMcpServers(
    String conversationId,
    List<String> serverIds,
  ) async {
    await (_db.delete(
      _db.conversationMcpServerRows,
    )..where((t) => t.conversationId.equals(conversationId))).go();
    if (serverIds.isEmpty) return;
    await _db.batch((batch) {
      for (var i = 0; i < serverIds.length; i++) {
        batch.insert(
          _db.conversationMcpServerRows,
          ConversationMcpServerRowsCompanion.insert(
            conversationId: conversationId,
            serverId: serverIds[i],
            ordinal: i,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> _rewriteMessageOrder(
    String conversationId,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    if (messageIds.toSet().length != messageIds.length) {
      throw ArgumentError.value(
        messageIds,
        'messageIds',
        'Message IDs must be unique when rewriting order.',
      );
    }

    final maxOrder = _db.messageRows.messageOrder.max();
    final maxRow =
        await (_db.selectOnly(_db.messageRows)
              ..addColumns([maxOrder])
              ..where(_db.messageRows.conversationId.equals(conversationId)))
            .getSingle();
    final temporaryStart = (maxRow.read(maxOrder) ?? -1) + 1;
    for (var i = 0; i < messageIds.length; i++) {
      await (_db.update(_db.messageRows)..where(
            (t) =>
                t.conversationId.equals(conversationId) &
                t.id.equals(messageIds[i]),
          ))
          .write(MessageRowsCompanion(messageOrder: Value(temporaryStart + i)));
    }
    for (var i = 0; i < messageIds.length; i++) {
      await (_db.update(_db.messageRows)..where(
            (t) =>
                t.conversationId.equals(conversationId) &
                t.id.equals(messageIds[i]),
          ))
          .write(MessageRowsCompanion(messageOrder: Value(i)));
    }
  }

  Future<List<String>> _getMcpServerIds(String conversationId) async {
    final mcpRows =
        await (_db.select(_db.conversationMcpServerRows)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([(t) => OrderingTerm.asc(t.ordinal)]))
            .get();
    return mcpRows.map((m) => m.serverId).toList(growable: false);
  }

  Future<Conversation> _conversationFromRow(
    ConversationRow row, {
    bool includeMessageIds = true,
    List<String>? mcpServerIds,
  }) async {
    final resolvedMcpServerIds = mcpServerIds ?? await _getMcpServerIds(row.id);
    final messageRows = includeMessageIds
        ? await (_db.select(_db.messageRows)
                ..where((t) => t.conversationId.equals(row.id))
                ..orderBy([(t) => OrderingTerm.asc(t.messageOrder)]))
              .get()
        : const <MessageRow>[];
    return Conversation(
      id: row.id,
      title: row.title,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      messageIds: messageRows.map((m) => m.id).toList(growable: false),
      isPinned: row.isPinned,
      mcpServerIds: resolvedMcpServerIds,
      assistantId: row.assistantId,
      truncateIndex: row.truncateIndex,
      versionSelections: _decodeStringIntMap(row.versionSelectionsJson),
      summary: row.summary,
      lastSummarizedMessageCount: row.lastSummarizedMessageCount,
      chatSuggestions: _decodeStringList(row.chatSuggestionsJson),
      injectedMemoryHash: row.injectedMemoryHash,
      lastMemoryExtractedOrder: row.lastMemoryExtractedOrder,
    );
  }

  ConversationRowsCompanion _conversationCompanion(
    Conversation conversation, {
    Value<String?>? injectedMemoryHash,
  }) {
    return ConversationRowsCompanion.insert(
      id: conversation.id,
      title: conversation.title,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      isPinned: Value(conversation.isPinned),
      assistantId: Value(conversation.assistantId),
      truncateIndex: Value(conversation.truncateIndex),
      versionSelectionsJson: Value(jsonEncode(conversation.versionSelections)),
      summary: Value(conversation.summary),
      lastSummarizedMessageCount: Value(
        conversation.lastSummarizedMessageCount,
      ),
      chatSuggestionsJson: Value(jsonEncode(conversation.chatSuggestions)),
      injectedMemoryHash:
          injectedMemoryHash ?? Value(conversation.injectedMemoryHash),
      lastMemoryExtractedOrder: Value(conversation.lastMemoryExtractedOrder),
    );
  }

  Future<ChatMessage> _messageFromRowWithParts(MessageRow row) async {
    return (await _messagesFromRowsWithParts([row])).single;
  }

  Future<List<ChatMessage>> _messagesFromRowsWithParts(
    List<MessageRow> rows,
  ) async {
    if (rows.isEmpty) return const [];
    final ids = rows.map((row) => row.id).toSet();
    final parts =
        await (_db.select(_db.messagePartRows)
              ..where((part) => part.revisionId.isIn(ids))
              ..orderBy([(part) => OrderingTerm.asc(part.ordinal)]))
            .get();
    final byRevision = <String, List<MessagePartRow>>{};
    for (final part in parts) {
      byRevision.putIfAbsent(part.revisionId, () => []).add(part);
    }
    return [
      for (final row in rows)
        _messageFromRow(row, authoritativeParts: byRevision[row.id]),
    ];
  }

  /// Parts 仅按序号顺序来自 [authoritativeParts]。缺失或空 parts
  /// 会通过派生的 [ChatMessage.content] 得到空内容。
  ChatMessage _messageFromRow(
    MessageRow row, {
    List<MessagePartRow>? authoritativeParts,
  }) {
    final partRows = authoritativeParts ?? const <MessagePartRow>[];
    final parts = <MessagePart>[
      for (final part in partRows)
        _hydratePart(
          revisionId: part.revisionId,
          ordinal: part.ordinal,
          kind: part.kind,
          payload: part.payload,
        ),
    ];
    final reasoningParts = parts.whereType<ReasoningPart>().toList(
      growable: false,
    );
    return ChatMessage(
      id: row.id,
      role: row.role,
      parts: parts,
      timestamp: row.timestamp,
      modelId: row.modelId,
      providerId: row.providerId,
      totalTokens: row.totalTokens,
      conversationId: row.conversationId,
      isStreaming: row.isStreaming,
      reasoningText: reasoningParts.isEmpty
          ? null
          : reasoningParts.map((part) => part.text).join(),
      reasoningStartAt: row.reasoningStartAt,
      reasoningFinishedAt: row.reasoningFinishedAt,
      translation: row.translation,
      reasoningSegmentsJson: row.reasoningSegmentsJson,
      groupId: row.groupId,
      version: row.version,
      promptTokens: row.promptTokens,
      completionTokens: row.completionTokens,
      cachedTokens: row.cachedTokens,
      durationMs: row.durationMs,
    );
  }

  bool _messageHasAttachmentParts(ChatMessage message) {
    return message.parts.any(
      (part) =>
          part is ImagePart ||
          part is FilePart ||
          (part is MalformedPart && part.isAttachmentKind),
    );
  }

  /// Body parts 在 reasoning/tool_call 行之后持久化。reasoning 和
  /// tool_call 仍从 [ChatMessage.reasoningText] / tool-event 参数获取，以保持流式叠加行为一致。
  List<MessagePart> _bodyPartsForPersistence(ChatMessage message) {
    final body = <MessagePart>[
      for (final part in message.parts)
        if (part is TextPart ||
            part is ImagePart ||
            part is FilePart ||
            part is MalformedPart ||
            part is UnknownPart)
          part,
    ];
    if (body.isEmpty) {
      return <MessagePart>[TextPart(message.content)];
    }
    return body;
  }

  MessagePart _hydratePart({
    required String revisionId,
    required int ordinal,
    required String kind,
    required String payload,
  }) {
    try {
      return MessagePart.fromRow(kind, payload);
    } on FormatException catch (error) {
      final parseError = messagePartParseErrorCategory(error);
      debugPrint(
        'Malformed message part: revisionId=$revisionId ordinal=$ordinal '
        'kind=$kind parseError=$parseError',
      );
      return MalformedPart(
        rawKind: kind,
        rawPayload: payload,
        parseError: parseError,
      );
    }
  }

  DateTime _dateTimeFromSqlite(Object? value) {
    if (value is int) {
      return DateTime.fromMicrosecondsSinceEpoch(value);
    }
    if (value is num) {
      return DateTime.fromMicrosecondsSinceEpoch(value.toInt());
    }
    throw StateError('Invalid SQLite DateTime value: $value.');
  }

  MessageRowsCompanion _messageCompanion(
    ChatMessage message,
    int messageOrder,
  ) {
    return MessageRowsCompanion.insert(
      id: message.id,
      conversationId: message.conversationId,
      role: message.role,
      timestamp: message.timestamp,
      modelId: Value(message.modelId),
      providerId: Value(message.providerId),
      totalTokens: Value(message.totalTokens),
      isStreaming: Value(message.isStreaming),
      reasoningStartAt: Value(message.reasoningStartAt),
      reasoningFinishedAt: Value(message.reasoningFinishedAt),
      translation: Value(message.translation),
      reasoningSegmentsJson: Value(message.reasoningSegmentsJson),
      groupId: Value(message.groupId),
      version: Value(message.version),
      promptTokens: Value(message.promptTokens),
      completionTokens: Value(message.completionTokens),
      cachedTokens: Value(message.cachedTokens),
      durationMs: Value(message.durationMs),
      messageOrder: messageOrder,
    );
  }

  MessageRowsCompanion _messageUpdate(ChatMessage message) {
    return MessageRowsCompanion(
      totalTokens: Value(message.totalTokens),
      isStreaming: Value(message.isStreaming),
      reasoningStartAt: Value(message.reasoningStartAt),
      reasoningFinishedAt: Value(message.reasoningFinishedAt),
      translation: Value(message.translation),
      reasoningSegmentsJson: Value(message.reasoningSegmentsJson),
      promptTokens: Value(message.promptTokens),
      completionTokens: Value(message.completionTokens),
      cachedTokens: Value(message.cachedTokens),
      durationMs: Value(message.durationMs),
    );
  }

  Map<String, int> _decodeStringIntMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      return decoded.map((key, value) {
        final intValue = value is num ? value.toInt() : int.parse('$value');
        return MapEntry(key.toString(), intValue);
      });
    } catch (_) {
      return <String, int>{};
    }
  }

  List<String> _decodeStringList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      return decoded.map((e) => e.toString()).toList(growable: false);
    } catch (_) {
      return <String>[];
    }
  }

  // —— 记忆系统 V1 读取路径（§13.3）——

  /// [assistantId] 的可见记忆：`status='active'`（除非 [includeArchived]）并且
  /// `(scope='global' OR (scope='assistant' AND assistant_id = :aid))`。当
  /// [assistantId] 为 null 时，只有全局行可见。为块内注入排序（§7.2）：
  /// `scope_rank ASC, entry_created_at ASC, id ASC`（全局排在助手之前）。
  Future<List<MemoryEntry>> queryVisibleMemories({
    required String? assistantId,
    MemoryType? type,
    bool includeArchived = false,
    int? limit,
  }) async {
    final clauses = <String>[_memoryVisibilitySql(assistantId)];
    final variables = <Variable<Object>>[
      ..._memoryVisibilityVariables(assistantId),
    ];
    if (!includeArchived) {
      clauses.add("status = 'active'");
    }
    if (type != null) {
      clauses.add('type = ?');
      variables.add(Variable<String>(MemoryEntry.typeToString(type)));
    }
    final limitSql = limit == null ? '' : ' LIMIT ?';
    if (limit != null) {
      variables.add(Variable<int>(limit));
    }
    final rows = await _db
        .customSelect(
          'SELECT payload FROM memory_entry_rows '
          'WHERE ${clauses.join(' AND ')} '
          'ORDER BY CASE WHEN scope = \'global\' THEN 0 ELSE 1 END ASC, '
          'entry_created_at ASC, id ASC'
          '$limitSql;',
          variables: variables,
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    return _memoryEntriesFromPayloadRows(
      rows,
      assistantId: assistantId,
      dropInvisibleRelated: true,
    );
  }

  /// 按 [MemoryType] 统计 [assistantId] 的活动可见记忆数量。
  Future<Map<MemoryType, int>> countVisibleMemoriesByType({
    required String? assistantId,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT type, COUNT(*) AS count FROM memory_entry_rows '
          "WHERE status = 'active' AND ${_memoryVisibilitySql(assistantId)} "
          'GROUP BY type;',
          variables: _memoryVisibilityVariables(assistantId),
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    final result = <MemoryType, int>{
      for (final type in MemoryType.values) type: 0,
    };
    for (final row in rows) {
      final type = MemoryEntry.typeFromString(row.read<String>('type'));
      result[type] = row.read<int>('count');
    }
    return result;
  }

  /// 按预先规范化并经过 LIKE 转义的 [tokens] 搜索记忆。
  ///
  /// 调用方必须将 token 转为小写/规范化，并转义 `%`、`_` 和 `\`，
  /// 再传入这里（例如通过 [MemoryTokenizer.escapeLike]）。
  ///
  /// - [matchAll] `true`（§5.9）：每个词都必须匹配（`AND`），按
  ///   `entry_updated_at DESC, id ASC` 排序。
  /// - [matchAll] `false`（§12.6）：`hits` = 匹配词数量（`OR`），
  ///   筛选 `hits >= 1`，按 `hits DESC, entry_updated_at DESC, id ASC` 排序。
  Future<List<MemoryEntry>> searchMemories({
    required String? assistantId,
    required List<String> tokens,
    MemoryType? type,
    bool matchAll = true,
    int limit = 10,
  }) async {
    if (tokens.isEmpty || limit <= 0) {
      return const <MemoryEntry>[];
    }
    if (!matchAll) {
      return _searchMemoriesMatchAny(
        assistantId: assistantId,
        tokens: tokens,
        type: type,
        limit: limit,
      );
    }

    final clauses = <String>[
      "status = 'active'",
      _memoryVisibilitySql(assistantId),
    ];
    final variables = <Variable<Object>>[
      ..._memoryVisibilityVariables(assistantId),
    ];
    if (type != null) {
      clauses.add('type = ?');
      variables.add(Variable<String>(MemoryEntry.typeToString(type)));
    }
    for (final token in tokens) {
      clauses.add("content_normalized LIKE ? ESCAPE '\\'");
      variables.add(Variable<String>('%$token%'));
    }
    variables.add(Variable<int>(limit));
    final rows = await _db
        .customSelect(
          'SELECT payload FROM memory_entry_rows '
          'WHERE ${clauses.join(' AND ')} '
          'ORDER BY entry_updated_at DESC, id ASC '
          'LIMIT ?;',
          variables: variables,
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    return _memoryEntriesFromPayloadRows(
      rows,
      assistantId: assistantId,
      dropInvisibleRelated: true,
    );
  }

  Future<List<MemoryEntry>> _searchMemoriesMatchAny({
    required String? assistantId,
    required List<String> tokens,
    required MemoryType? type,
    required int limit,
  }) async {
    final hitParts = <String>[
      for (final _ in tokens)
        "CASE WHEN content_normalized LIKE ? ESCAPE '\\' THEN 1 ELSE 0 END",
    ];
    final hitsExpr = hitParts.join(' + ');

    // 变量顺序必须匹配 `?` 的出现顺序：先 SELECT hits，再 WHERE。
    final clauses = <String>[
      "status = 'active'",
      _memoryVisibilitySql(assistantId),
    ];
    final variables = <Variable<Object>>[
      for (final token in tokens) Variable<String>('%$token%'),
      ..._memoryVisibilityVariables(assistantId),
    ];
    if (type != null) {
      clauses.add('type = ?');
      variables.add(Variable<String>(MemoryEntry.typeToString(type)));
    }
    clauses.add('($hitsExpr) >= 1');
    for (final token in tokens) {
      variables.add(Variable<String>('%$token%'));
    }
    variables.add(Variable<int>(limit));

    final rows = await _db
        .customSelect(
          'SELECT payload, ($hitsExpr) AS hits FROM memory_entry_rows '
          'WHERE ${clauses.join(' AND ')} '
          'ORDER BY hits DESC, entry_updated_at DESC, id ASC '
          'LIMIT ?;',
          variables: variables,
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    return _memoryEntriesFromPayloadRows(
      rows,
      assistantId: assistantId,
      dropInvisibleRelated: true,
    );
  }

  Future<List<MemoryEntry>> memoriesByIds(List<String> ids) async {
    if (ids.isEmpty) return const <MemoryEntry>[];
    final unique = ids.toSet().toList(growable: false);
    final placeholders = List.filled(unique.length, '?').join(',');
    final rows = await _db
        .customSelect(
          'SELECT payload FROM memory_entry_rows '
          'WHERE id IN ($placeholders) '
          'ORDER BY id ASC;',
          variables: [for (final id in unique) Variable<String>(id)],
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    return _memoryEntriesFromPayloadRows(
      rows,
      assistantId: null,
      dropInvisibleRelated: false,
    );
  }

  Future<MemoryEntry?> findExactMemory({
    required String? assistantId,
    required MemoryType type,
    required String contentNormalized,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT payload FROM memory_entry_rows '
          "WHERE status = 'active' "
          'AND ${_memoryVisibilitySql(assistantId)} '
          'AND type = ? '
          'AND content_normalized = ? '
          'LIMIT 1;',
          variables: [
            ..._memoryVisibilityVariables(assistantId),
            Variable<String>(MemoryEntry.typeToString(type)),
            Variable<String>(contentNormalized),
          ],
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    if (rows.isEmpty) return null;
    final entries = await _memoryEntriesFromPayloadRows(
      rows,
      assistantId: assistantId,
      dropInvisibleRelated: true,
    );
    return entries.single;
  }

  Future<int> countOrphanAssistantMemories() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS count FROM memory_entry_rows m '
          "WHERE m.scope = 'assistant' "
          'AND NOT EXISTS ('
          'SELECT 1 FROM assistant_rows a WHERE a.id = m.assistant_id'
          ');',
          readsFrom: {_db.memoryEntryRows, _db.assistantRows},
        )
        .getSingle();
    return row.read<int>('count');
  }

  /// 所有助手的所有记忆条目（全局管理 UI §14.4）。
  Future<List<MemoryEntry>> queryAllMemories({
    bool includeArchived = false,
    MemoryType? type,
  }) async {
    final clauses = <String>[];
    final variables = <Variable<Object>>[];
    if (!includeArchived) {
      clauses.add("status = 'active'");
    }
    if (type != null) {
      clauses.add('type = ?');
      variables.add(Variable<String>(MemoryEntry.typeToString(type)));
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')} ';
    final rows = await _db
        .customSelect(
          'SELECT payload FROM memory_entry_rows '
          '$where'
          'ORDER BY entry_updated_at DESC, id ASC;',
          variables: variables,
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    return _memoryEntriesFromPayloadRows(
      rows,
      assistantId: null,
      dropInvisibleRelated: false,
    );
  }

  /// 在所有助手间搜索（§14.4 / §5.9 AND 语义）。
  Future<List<MemoryEntry>> searchAllMemories({
    required List<String> tokens,
    MemoryType? type,
    bool includeArchived = false,
    int limit = 200,
  }) async {
    if (tokens.isEmpty || limit <= 0) {
      return const <MemoryEntry>[];
    }
    final clauses = <String>[];
    final variables = <Variable<Object>>[];
    if (!includeArchived) {
      clauses.add("status = 'active'");
    }
    if (type != null) {
      clauses.add('type = ?');
      variables.add(Variable<String>(MemoryEntry.typeToString(type)));
    }
    for (final token in tokens) {
      clauses.add("content_normalized LIKE ? ESCAPE '\\'");
      variables.add(Variable<String>('%$token%'));
    }
    variables.add(Variable<int>(limit));
    final rows = await _db
        .customSelect(
          'SELECT payload FROM memory_entry_rows '
          'WHERE ${clauses.join(' AND ')} '
          'ORDER BY entry_updated_at DESC, id ASC '
          'LIMIT ?;',
          variables: variables,
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    return _memoryEntriesFromPayloadRows(
      rows,
      assistantId: null,
      dropInvisibleRelated: false,
    );
  }

  Future<List<UserProfileField>> readProfileFields() async {
    final rows = await _db
        .customSelect(
          'SELECT payload FROM user_profile_field_rows '
          'ORDER BY sort_order ASC, id ASC;',
          readsFrom: {_db.userProfileFieldRows},
        )
        .get();
    return [
      for (final row in rows)
        UserProfileField.fromPayload(
          (jsonDecode(row.read<String>('payload')) as Map)
              .cast<String, dynamic>(),
        ),
    ];
  }

  Future<MessagePromptRow?> getMessagePrompt(String revisionId) {
    return (_db.select(
      _db.messagePromptRows,
    )..where((t) => t.revisionId.equals(revisionId))).getSingleOrNull();
  }

  Future<Map<String, MessagePromptRow>> getMessagePrompts(
    Iterable<String> revisionIds,
  ) async {
    final ids = revisionIds.toSet();
    if (ids.isEmpty) return const {};
    final rows = await (_db.select(
      _db.messagePromptRows,
    )..where((row) => row.revisionId.isIn(ids))).get();
    return {for (final row in rows) row.revisionId: row};
  }

  Future<void> putMessagePrompt({
    required String revisionId,
    required String conversationId,
    required String payload,
    required bool carriesMemorySnapshot,
  }) async {
    final now = DateTime.now().toUtc();
    await _db
        .into(_db.messagePromptRows)
        .insertOnConflictUpdate(
          MessagePromptRowsCompanion.insert(
            revisionId: revisionId,
            conversationId: conversationId,
            payload: payload,
            carriesMemorySnapshot: Value(carriesMemorySnapshot),
            createdAt: now,
          ),
        );
  }

  /// 冻结消息的最终提示字符串；如果注入了快照，则在同一个事务中推进会话的
  /// 注入记忆哈希。
  ///
  /// 这两次写入不能拆分：若在其中间崩溃，会留下一个声称已投递快照、
  /// 但没有任何消息实际携带该快照的 hash；一旦自愈机制发现（§8.3），
  /// 将付出额外一次完整重新注入的代价。
  Future<void> freezeMessagePrompt({
    required String revisionId,
    required String conversationId,
    required String payload,
    required bool carriesMemorySnapshot,
    String? injectedMemoryHash,
  }) {
    return _db.transaction(() async {
      await putMessagePrompt(
        revisionId: revisionId,
        conversationId: conversationId,
        payload: payload,
        carriesMemorySnapshot: carriesMemorySnapshot,
      );
      if (carriesMemorySnapshot) {
        await setConversationInjectedMemoryHash(
          conversationId,
          injectedMemoryHash,
        );
      }
    });
  }

  Future<bool> anyPromptCarriesMemorySnapshot(List<String> revisionIds) async {
    if (revisionIds.isEmpty) return false;
    final unique = revisionIds.toSet().toList(growable: false);
    final placeholders = List.filled(unique.length, '?').join(',');
    final row = await _db
        .customSelect(
          'SELECT 1 AS hit FROM message_prompt_rows '
          'WHERE carries_memory_snapshot = 1 '
          'AND revision_id IN ($placeholders) '
          'LIMIT 1;',
          variables: [for (final id in unique) Variable<String>(id)],
          readsFrom: {_db.messagePromptRows},
        )
        .getSingleOrNull();
    return row != null;
  }

  /// 投递给 [conversationId] 的最后一个 memory snapshot hash。
  ///
  /// 请读取此方法而不是缓存的 [Conversation]：该字段由 [freezeMessagePrompt]
  /// 写入，并且永远不会重新载入内存模型，因此缓存副本报告的是其构造时的值。
  Future<String?> getConversationInjectedMemoryHash(
    String conversationId,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT injected_memory_hash FROM conversation_rows '
          'WHERE id = ? LIMIT 1;',
          variables: [Variable<String>(conversationId)],
          readsFrom: {_db.conversationRows},
        )
        .getSingleOrNull();
    return row?.read<String?>('injected_memory_hash');
  }

  Future<void> setConversationInjectedMemoryHash(
    String conversationId,
    String? hash,
  ) async {
    await (_db.update(_db.conversationRows)
          ..where((t) => t.id.equals(conversationId)))
        .write(ConversationRowsCompanion(injectedMemoryHash: Value(hash)));
  }

  Future<void> setConversationLastMemoryExtractedOrder(
    String conversationId,
    int order,
  ) async {
    await (_db.update(
      _db.conversationRows,
    )..where((t) => t.id.equals(conversationId))).write(
      ConversationRowsCompanion(lastMemoryExtractedOrder: Value(order)),
    );
  }

  String _memoryVisibilitySql(String? assistantId) {
    if (assistantId == null) {
      return "scope = 'global'";
    }
    return "(scope = 'global' OR (scope = 'assistant' AND assistant_id = ?))";
  }

  List<Variable<Object>> _memoryVisibilityVariables(String? assistantId) {
    if (assistantId == null) return const <Variable<Object>>[];
    return <Variable<Object>>[Variable<String>(assistantId)];
  }

  Future<List<MemoryEntry>> _memoryEntriesFromPayloadRows(
    List<QueryRow> rows, {
    required String? assistantId,
    required bool dropInvisibleRelated,
  }) async {
    if (rows.isEmpty) return const <MemoryEntry>[];
    final entries = <MemoryEntry>[
      for (final row in rows)
        MemoryEntry.fromPayload(
          (jsonDecode(row.read<String>('payload')) as Map)
              .cast<String, dynamic>(),
        ),
    ];
    final related = <String>{for (final entry in entries) ...entry.relatedIds};
    if (related.isEmpty) return entries;

    final keep = dropInvisibleRelated
        ? await _filterRelatedIdsVisible(related, assistantId)
        : await _filterRelatedIdsExisting(related);
    return [
      for (final entry in entries)
        () {
          final filtered = entry.relatedIds
              .where(keep.contains)
              .toList(growable: false);
          if (filtered.length == entry.relatedIds.length) return entry;
          return entry.copyWith(relatedIds: filtered);
        }(),
    ];
  }

  Future<Set<String>> _filterRelatedIdsExisting(Set<String> ids) async {
    if (ids.isEmpty) return const <String>{};
    final list = ids.toList(growable: false);
    final placeholders = List.filled(list.length, '?').join(',');
    final rows = await _db
        .customSelect(
          'SELECT id FROM memory_entry_rows WHERE id IN ($placeholders);',
          variables: [for (final id in list) Variable<String>(id)],
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    return {for (final row in rows) row.read<String>('id')};
  }

  Future<Set<String>> _filterRelatedIdsVisible(
    Set<String> ids,
    String? assistantId,
  ) async {
    if (ids.isEmpty) return const <String>{};
    final list = ids.toList(growable: false);
    final placeholders = List.filled(list.length, '?').join(',');
    final rows = await _db
        .customSelect(
          'SELECT id FROM memory_entry_rows '
          "WHERE status = 'active' "
          'AND ${_memoryVisibilitySql(assistantId)} '
          'AND id IN ($placeholders);',
          variables: [
            ..._memoryVisibilityVariables(assistantId),
            for (final id in list) Variable<String>(id),
          ],
          readsFrom: {_db.memoryEntryRows},
        )
        .get();
    return {for (final row in rows) row.read<String>('id')};
  }
}

class ConversationSearchMatch {
  const ConversationSearchMatch({
    required this.conversationId,
    required this.conversationTitle,
    required this.updatedAt,
    required this.versionSelections,
    required this.messageId,
    required this.messageContent,
    required this.messageRole,
    required this.groupId,
    required this.version,
    required this.maxVersion,
  });

  final String conversationId;
  final String conversationTitle;
  final DateTime updatedAt;
  final Map<String, int> versionSelections;
  final String? messageId;
  final String? messageContent;
  final String? messageRole;
  final String? groupId;
  final int? version;
  final int? maxVersion;
}

final class ChatStatsTotals {
  const ChatStatsTotals({
    required this.messages,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedTokens,
  });

  final int messages;
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;
}

final class ChatStatsDayCount {
  const ChatStatsDayCount({required this.day, required this.count});
  final DateTime day;
  final int count;
}

final class ChatStatsTrendBucket {
  const ChatStatsTrendBucket({
    required this.day,
    required this.providerId,
    required this.activityCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedTokens,
    required this.uncategorizedTokens,
  });
  final DateTime day;
  final String providerId;
  final int activityCount;
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;
  final int uncategorizedTokens;
}

final class ChatStatsRank {
  const ChatStatsRank({
    required this.id,
    required this.label,
    required this.count,
    this.providerId,
  });
  final String id;
  final String label;
  final int count;
  final String? providerId;
}

final class ChatStatsAggregate {
  const ChatStatsAggregate({
    required this.conversations,
    required this.totals,
    required this.heatmap,
    required this.trend,
    required this.models,
    required this.assistants,
    required this.topics,
  });
  final int conversations;
  final ChatStatsTotals totals;
  final List<ChatStatsDayCount> heatmap;
  final List<ChatStatsTrendBucket> trend;
  final List<ChatStatsRank> models;
  final List<ChatStatsRank> assistants;
  final List<ChatStatsRank> topics;
}

final class AssetGcCandidate {
  const AssetGcCandidate({
    required this.assetId,
    required this.path,
    required this.thumbnailPath,
    required this.byteSize,
    required this.generation,
  });
  final String assetId;
  final String path;
  final String? thumbnailPath;
  final int byteSize;
  final int generation;
}

String _alternateAssetPathForm(String path) {
  if (KelivoFileUri.isKelivoFileUri(path)) {
    final resolved = SandboxPathResolver.fix(path);
    return resolved.isEmpty ? path : resolved;
  }
  final canonical = SandboxPathResolver.canonicalize(path);
  return canonical.isEmpty ? path : canonical;
}

String _jsonEscapedPathForm(String path) {
  final encoded = jsonEncode(path);
  return encoded.substring(1, encoded.length - 1);
}

final class MessageAssetRegistration {
  const MessageAssetRegistration({
    required this.assetId,
    required this.contentHash,
    required this.path,
    required this.byteSize,
    required this.kind,
    this.width,
    this.height,
    this.thumbnailPath,
  });

  final String assetId;
  final String contentHash;
  final String path;
  final int byteSize;
  final String kind;
  final int? width;
  final int? height;
  final String? thumbnailPath;
}

class ChatStorageMetaKeys {
  ChatStorageMetaKeys._();

  static const activeStreamingIds = 'active_streaming_ids';
  static const hiveMigrationComplete = 'hive_migration_complete_v1';
  static const databaseIdentity = 'database_identity_v1';
  static const contextTreeMigrationWarnings =
      AppDatabase.contextTreeMigrationWarningsKey;
  static const sandboxPathVersion = 'sandbox_path_migration_version';
  static const assetReferenceBackfillVersion =
      'asset_reference_backfill_version';
}
