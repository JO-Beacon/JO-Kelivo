import 'dart:io';
import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/common.dart' show AllowedArgumentCount;

import '../../utils/app_directories.dart';

part 'app_database.g.dart';

typedef SqliteExecutionIsolateProbeResult = ({
  int samples,
  int openingIsolateCalls,
  int backgroundIsolateCalls,
});

class _LegacyTreeMessage {
  const _LegacyTreeMessage({
    required this.id,
    required this.groupId,
    required this.version,
    required this.messageOrder,
    required this.timestamp,
  });

  final String id;
  final String groupId;
  final int version;
  final int messageOrder;
  final int timestamp;
}

class LegacyTreeMigrationWarning {
  const LegacyTreeMigrationWarning({
    required this.conversationId,
    required this.groupId,
    required this.fallbackVersion,
  });

  final String conversationId;
  final String groupId;
  final int fallbackVersion;

  Map<String, Object> toJson() => {
    'conversationId': conversationId,
    'groupId': groupId,
    'fallbackVersion': fallbackVersion,
  };
}

class MicrosecondDateTimeConverter extends TypeConverter<DateTime, int> {
  const MicrosecondDateTimeConverter();

  @override
  DateTime fromSql(int fromDb) => DateTime.fromMicrosecondsSinceEpoch(fromDb);

  @override
  int toSql(DateTime value) => value.microsecondsSinceEpoch;
}

@TableIndex(
  name: 'idx_conversations_updated_at',
  columns: {
    IndexedColumn(#updatedAt, orderBy: OrderingMode.desc),
    IndexedColumn(#id, orderBy: OrderingMode.asc),
  },
)
@TableIndex(name: 'idx_conversations_assistant', columns: {#assistantId})
class ConversationRows extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  TextColumn get assistantId => text().nullable()();
  IntColumn get truncateIndex => integer()
      // ignore: recursive_getters
      .check(truncateIndex.isBiggerOrEqualValue(-1))
      .withDefault(const Constant(-1))();
  TextColumn get versionSelectionsJson =>
      text().withDefault(const Constant('{}'))();
  TextColumn get summary => text().nullable()();
  IntColumn get lastSummarizedMessageCount => integer()
      // ignore: recursive_getters
      .check(lastSummarizedMessageCount.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  TextColumn get chatSuggestionsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get injectedMemoryHash => text().nullable()();
  IntColumn get lastMemoryExtractedOrder => integer()
      // ignore: recursive_getters
      .check(lastMemoryExtractedOrder.isBiggerOrEqualValue(-1))
      .withDefault(const Constant(-1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_message_tree_edges_conversation',
  columns: {#conversationId},
)
class MessageTreeEdgeRows extends Table {
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get messageId => text()();
  TextColumn get parentMessageId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, messageId};
}

@TableIndex(
  name: 'idx_conversation_branches_conversation',
  columns: {#conversationId},
)
class ConversationBranchRows extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get tipMessageId => text().nullable()();
  TextColumn get name => text().withDefault(const Constant(''))();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_conversation_tree_state_conversation',
  columns: {#conversationId},
)
class ConversationTreeStateRows extends Table {
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get activeBranchId => text()();
  TextColumn get branchSelectionsJson =>
      text().withDefault(const Constant('{}'))();

  @override
  Set<Column<Object>> get primaryKey => {conversationId};
}

@TableIndex(
  name: 'idx_messages_conversation_order',
  columns: {#conversationId, #messageOrder, #id},
)
@TableIndex(
  name: 'idx_messages_conversation_timestamp',
  columns: {#conversationId, #timestamp, #id},
)
@TableIndex(
  name: 'idx_messages_group',
  columns: {#conversationId, #groupId, #version, #id},
)
@TableIndex.sql(
  'CREATE INDEX idx_message_rows_streaming '
  'ON message_rows (id) WHERE is_streaming = 1',
)
class MessageRows extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get role =>
      text()
      // ignore: recursive_getters
      .check(role.isNotValue(''))();
  IntColumn get timestamp =>
      integer().map(const MicrosecondDateTimeConverter())();
  TextColumn get modelId => text().nullable()();
  TextColumn get providerId => text().nullable()();
  IntColumn get totalTokens => integer()
      // ignore: recursive_getters
      .check(totalTokens.isBiggerOrEqualValue(0))
      .nullable()();
  BoolColumn get isStreaming => boolean().withDefault(const Constant(false))();
  IntColumn get reasoningStartAt =>
      integer().map(const MicrosecondDateTimeConverter()).nullable()();
  IntColumn get reasoningFinishedAt =>
      integer().map(const MicrosecondDateTimeConverter()).nullable()();
  TextColumn get translation => text().nullable()();
  TextColumn get reasoningSegmentsJson => text().nullable()();
  TextColumn get groupId => text().nullable()();
  IntColumn get version => integer()
      // ignore: recursive_getters
      .check(version.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get promptTokens => integer()
      // ignore: recursive_getters
      .check(promptTokens.isBiggerOrEqualValue(0))
      .nullable()();
  IntColumn get completionTokens => integer()
      // ignore: recursive_getters
      .check(completionTokens.isBiggerOrEqualValue(0))
      .nullable()();
  IntColumn get cachedTokens => integer()
      // ignore: recursive_getters
      .check(cachedTokens.isBiggerOrEqualValue(0))
      .nullable()();
  IntColumn get durationMs => integer()
      // ignore: recursive_getters
      .check(durationMs.isBiggerOrEqualValue(0))
      .nullable()();
  IntColumn get messageOrder =>
      integer()
      // ignore: recursive_getters
      .check(messageOrder.isBiggerOrEqualValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {conversationId, messageOrder},
    {conversationId, groupId, version},
  ];
}

class ConversationMcpServerRows extends Table {
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get serverId => text()();
  IntColumn get ordinal =>
      integer()
      // ignore: recursive_getters
      .check(ordinal.isBiggerOrEqualValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, serverId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {conversationId, ordinal},
  ];
}

class ChatStorageMetaRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@TableIndex(
  name: 'idx_message_parts_revision_ordinal',
  columns: {#conversationId, #revisionId, #ordinal},
)
class MessagePartRows extends Table {
  IntColumn get partId => integer().autoIncrement()();
  TextColumn get conversationId => text()();
  TextColumn get revisionId => text()();
  IntColumn get ordinal =>
      integer()
      // ignore: recursive_getters
      .check(ordinal.isBiggerOrEqualValue(0))();
  TextColumn get kind => text().check(
    // 向前兼容：未知的未来类型将以 UnknownPart 持久化。
    // ignore: recursive_getters
    kind.isNotValue(''),
  )();
  TextColumn get payload => text()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {revisionId, ordinal},
  ];

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (revision_id) '
        'REFERENCES message_rows (id) '
        'ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED',
    'CHECK (updated_at >= created_at)',
  ];
}

@TableIndex(
  name: 'idx_provider_artifacts_revision_kind',
  columns: {#conversationId, #revisionId, #kind},
)
class ProviderArtifactRows extends Table {
  TextColumn get conversationId => text()();
  TextColumn get revisionId => text()();
  TextColumn get kind => text().check(
    // ignore: recursive_getters
    kind.isNotValue(''),
  )();
  TextColumn get payload => text()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {revisionId, kind};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (revision_id) '
        'REFERENCES message_rows (id) '
        'ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED',
    'CHECK (updated_at >= created_at)',
  ];
}

class AssetRows extends Table {
  TextColumn get id => text()();
  TextColumn get contentHash => text().unique()();
  TextColumn get path => text()();
  IntColumn get byteSize =>
      integer()
      // ignore: recursive_getters
      .check(byteSize.isBiggerOrEqualValue(0))();
  IntColumn get width => integer()
      // ignore: recursive_getters
      .check(width.isBiggerThanValue(0))
      .nullable()();
  IntColumn get height => integer()
      // ignore: recursive_getters
      .check(height.isBiggerThanValue(0))
      .nullable()();
  TextColumn get thumbnailPath => text().nullable()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get lastReferencedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(name: 'idx_message_assets_asset', columns: {#assetId, #revisionId})
class MessageAssetRows extends Table {
  TextColumn get conversationId => text()();
  TextColumn get revisionId =>
      text().references(MessageRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get assetId =>
      text().references(AssetRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get kind =>
      text()
      // ignore: recursive_getters
      .check(kind.isNotValue(''))();

  @override
  Set<Column<Object>> get primaryKey => {revisionId, assetId, kind};
}

class AssetGcRows extends Table {
  TextColumn get assetId =>
      text().references(AssetRows, #id, onDelete: KeyAction.cascade)();
  IntColumn get notBefore =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get attempts => integer()
      // ignore: recursive_getters
      .check(attempts.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get generation => integer()
      // ignore: recursive_getters
      .check(generation.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {assetId};
}

class GcAuditRows extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get kind => text()();
  TextColumn get entityId => text()();
  IntColumn get completedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
}

class AssetReferenceDirtyRows extends Table {
  TextColumn get revisionId =>
      text().references(MessageRows, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column<Object>> get primaryKey => {revisionId};
}

@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_generation_runs_active_target '
  'ON generation_run_rows (conversation_id, target_revision_id) '
  "WHERE state IN ('preparing', 'requesting', 'streaming', 'waiting_tool')",
)
@TableIndex(
  name: 'idx_generation_runs_state_updated',
  columns: {#state, #updatedAt, #id},
)
class GenerationRunRows extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get targetRevisionId => text()();
  TextColumn get state => text().check(
    // ignore: recursive_getters
    state.isIn(const [
      'preparing',
      'requesting',
      'streaming',
      'waiting_tool',
      'completed',
      'failed',
      'cancelled',
      'interrupted',
    ]),
  )();
  IntColumn get stateRevision => integer()
      // ignore: recursive_getters
      .check(stateRevision.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get checkpointSeq => integer()
      // ignore: recursive_getters
      .check(checkpointSeq.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  TextColumn get errorCode => text().nullable()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get terminalAt =>
      integer().map(const MicrosecondDateTimeConverter()).nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (target_revision_id) '
        'REFERENCES message_rows (id) '
        'DEFERRABLE INITIALLY DEFERRED',
    'CHECK (updated_at >= created_at)',
    'CHECK (terminal_at IS NULL OR terminal_at >= created_at)',
    "CHECK ((state IN ('preparing', 'requesting', 'streaming', "
        "'waiting_tool') AND terminal_at IS NULL) OR "
        "(state IN ('completed', 'failed', 'cancelled', 'interrupted') "
        'AND terminal_at IS NOT NULL))',
    "CHECK (error_code IS NULL OR (length(error_code) BETWEEN 1 AND 128 "
        "AND state IN ('failed', 'cancelled', 'interrupted')))",
  ];
}

class AssistantRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ProviderRows extends Table {
  TextColumn get providerKey => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {providerKey};
}

class ProviderGroupRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class McpServerRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class WorldBookRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_assistant_memories_assistant',
  columns: {#assistantId, #id},
)
class AssistantMemoryRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get assistantId => text()();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class QuickPhraseRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class SearchServiceRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class TtsServiceRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class InstructionInjectionRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AssistantGroupRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PreferenceRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@TableIndex(
  name: 'idx_memory_entries_visible',
  columns: {#status, #type, #scope, #assistantId},
)
@TableIndex(
  name: 'idx_memory_entries_recent',
  columns: {#status, #type, #entryUpdatedAt, #id},
)
@TableIndex(
  name: 'idx_memory_entries_dedupe',
  columns: {#scope, #assistantId, #type, #contentNormalized},
)
class MemoryEntryRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get scope => text().check(
    // ignore: recursive_getters
    scope.isIn(const ['global', 'assistant']),
  )();
  TextColumn get assistantId => text().nullable()();
  TextColumn get type => text().check(
    // ignore: recursive_getters
    type.isIn(const ['identity', 'workflow', 'voice', 'instruction']),
  )();
  TextColumn get status => text().check(
    // ignore: recursive_getters
    status.isIn(const ['active', 'archived']),
  )();
  TextColumn get content => text()();
  TextColumn get contentNormalized => text()();
  IntColumn get entryCreatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get entryUpdatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK ((scope = 'global' AND assistant_id IS NULL) OR "
        "(scope = 'assistant' AND assistant_id IS NOT NULL))",
    'CHECK (entry_updated_at >= entry_created_at)',
  ];
}

class UserProfileFieldRows extends Table {
  TextColumn get id => text()(); // = 字段键，例如 preferred_name
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_message_prompts_conversation_snapshot',
  columns: {#conversationId, #carriesMemorySnapshot},
)
class MessagePromptRows extends Table {
  TextColumn get revisionId => text()();
  TextColumn get conversationId => text()();
  TextColumn get payload => text()();
  BoolColumn get carriesMemorySnapshot =>
      boolean().withDefault(const Constant(false))();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {revisionId};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (revision_id) '
        'REFERENCES message_rows (id) '
        'ON DELETE CASCADE',
  ];
}

@DriftDatabase(
  tables: [
    ConversationRows,
    MessageRows,
    MessageTreeEdgeRows,
    ConversationBranchRows,
    ConversationTreeStateRows,
    ConversationMcpServerRows,
    ChatStorageMetaRows,
    MessagePartRows,
    ProviderArtifactRows,
    AssetRows,
    MessageAssetRows,
    AssetGcRows,
    GcAuditRows,
    AssetReferenceDirtyRows,
    GenerationRunRows,
    AssistantRows,
    ProviderRows,
    ProviderGroupRows,
    McpServerRows,
    WorldBookRows,
    AssistantMemoryRows,
    QuickPhraseRows,
    SearchServiceRows,
    TtsServiceRows,
    InstructionInjectionRows,
    AssistantGroupRows,
    PreferenceRows,
    MemoryEntryRows,
    UserProfileFieldRows,
    MessagePromptRows,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  static const databaseFileName = 'kelivo.db';
  static const contextTreeMigrationWarningsKey =
      'context_tree_migration_warnings_v1';

  // Schema 1 是第一个发布的 SQLite 契约。模式 2 添加显式消息树边、
  // 分支和活动分支状态，模式 3 存储每个共享树前缀下最后选择的分支，
  // 模式 4 将 Kelivo 的助手标签表迁移为 JO-Kelivo 的助手分组表。
  static const currentSchemaVersion = 4;
  // 保持 SQLite 既定的 1000 页节奏显式声明。按通常 4 KiB 页大小计算，
  // 这大约在 4 MiB 时触发一次检查点，但页大小仍是实际依据。
  static const walAutoCheckpointPages = 1000;
  // 这会限制 reset/checkpoint 之后保留的 journal/WAL 存储；它并不
  // 承诺活跃 WAL 绝不会临时超过 16 MiB。
  static const journalSizeLimitBytes = 16 << 20;
  static const busyTimeoutMillis = 5000;
  // 在 WAL 下，NORMAL 仍然保证崩溃一致性；断电最多只会丢弃自上次
  // 检查点以来的事务，而生成运行恢复路径已经能够容忍这一点。FULL 会
  // 在流式热路径上为每次写事务增加一次 fsync。
  static const synchronousNormal = 1;
  static const _executionIsolateProbeFunction =
      'kelivo_sqlite_on_opening_isolate';
  static const _maxExecutionIsolateProbeSamples = 1000;

  factory AppDatabase.open({File? file}) {
    final databaseFile = file;
    if (databaseFile != null) {
      return AppDatabase(_openExecutor(databaseFile));
    }
    return AppDatabase(
      LazyDatabase(() async {
        final dir = await AppDirectories.getAppDataDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return _openExecutor(File('${dir.path}/$databaseFileName'));
      }),
    );
  }

  static QueryExecutor _openExecutor(File file) {
    final openingIsolatePort = Isolate.current.controlPort;
    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        final installedSchema = database.userVersion;
        if (installedSchema > AppDatabase.currentSchemaVersion) {
          throw StateError('database_schema_too_new');
        }
        // 此回调由 SQLite 在 drift 的 worker isolate 上注册并调用。让它保持
        // 非确定性，以避免 SQLite 将多行 profile 查询折叠为单次回调。
        database.createFunction(
          functionName: _executionIsolateProbeFunction,
          argumentCount: const AllowedArgumentCount(0),
          deterministic: false,
          directOnly: true,
          function: (_) =>
              Isolate.current.controlPort == openingIsolatePort ? 1 : 0,
        );
        database.execute('PRAGMA journal_mode = WAL;');
        database.execute('PRAGMA foreign_keys = ON;');
        database.execute('PRAGMA busy_timeout = $busyTimeoutMillis;');
        database.execute('PRAGMA synchronous = NORMAL;');
        database.execute(
          'PRAGMA wal_autocheckpoint = $walAutoCheckpointPages;',
        );
        database.execute('PRAGMA journal_size_limit = $journalSizeLimitBytes;');
      },
    );
  }

  /// 对在活动 SQLite 连接上执行回调的 isolate 进行采样。
  ///
  /// 在 profile 测试夹具中，打开连接的 isolate 是 Flutter UI isolate。
  Future<SqliteExecutionIsolateProbeResult> probeExecutionIsolate({
    int samples = 64,
  }) async {
    RangeError.checkValueInInterval(
      samples,
      1,
      _maxExecutionIsolateProbeSamples,
      'samples',
    );
    final row = await customSelect(
      '''
WITH RECURSIVE probe(sample) AS (
  VALUES (1)
  UNION ALL
  SELECT sample + 1 FROM probe WHERE sample < ?
)
SELECT
  COUNT(*) AS sample_count,
  COALESCE(SUM($_executionIsolateProbeFunction()), 0)
    AS opening_isolate_calls
FROM probe;
''',
      variables: [Variable.withInt(samples)],
    ).getSingle();
    final sampleCount = row.read<int>('sample_count');
    final openingIsolateCalls = row.read<int>('opening_isolate_calls');
    return (
      samples: sampleCount,
      openingIsolateCalls: openingIsolateCalls,
      backgroundIsolateCalls: sampleCount - openingIsolateCalls,
    );
  }

  Future<List<LegacyTreeMigrationWarning>>
  _populateLegacyConversationTreeBranchRows() async {
    final conversationRows = await customSelect(
      'SELECT id, created_at, version_selections_json '
      'FROM conversation_rows;',
    ).get();
    final messageRows = await customSelect(
      'SELECT id, conversation_id, group_id, version, message_order, timestamp '
      'FROM message_rows '
      'ORDER BY conversation_id, message_order, id;',
    ).get();

    final messagesByConversation = <String, List<_LegacyTreeMessage>>{};
    for (final row in messageRows) {
      final conversationId = row.read<String>('conversation_id');
      final message = _LegacyTreeMessage(
        id: row.read<String>('id'),
        groupId: row.readNullable<String>('group_id') ?? row.read<String>('id'),
        version: row.read<int>('version'),
        messageOrder: row.read<int>('message_order'),
        timestamp: row.read<int>('timestamp'),
      );
      messagesByConversation
          .putIfAbsent(conversationId, () => <_LegacyTreeMessage>[])
          .add(message);
    }

    final warnings = <LegacyTreeMigrationWarning>[];
    for (final conversationRow in conversationRows) {
      final conversationId = conversationRow.read<String>('id');
      final createdAt = conversationRow.read<int>('created_at');
      final decodedSelections = _decodeVersionSelections(
        conversationRow.read<String>('version_selections_json'),
      );
      final selections = <String, int>{};
      for (final entry in decodedSelections.entries) {
        final value = entry.value;
        if (value is num) selections[entry.key] = value.toInt();
      }
      final messages = messagesByConversation[conversationId] ?? const [];

      final groups = <String, List<_LegacyTreeMessage>>{};
      final groupMinOrder = <String, int>{};
      for (final message in messages) {
        final groupId = message.groupId;
        groups.putIfAbsent(groupId, () => <_LegacyTreeMessage>[]).add(message);
        final currentMin = groupMinOrder[groupId];
        if (currentMin == null || message.messageOrder < currentMin) {
          groupMinOrder[groupId] = message.messageOrder;
        }
      }

      final orderedGroupIds = groupMinOrder.keys.toList(growable: false)
        ..sort((left, right) {
          final byOrder = groupMinOrder[left]!.compareTo(groupMinOrder[right]!);
          if (byOrder != 0) return byOrder;
          return left.compareTo(right);
        });

      String? previousSelectedId;
      for (final groupId in orderedGroupIds) {
        final versions =
            List<_LegacyTreeMessage>.of(groups[groupId] ?? const [])
              ..sort((left, right) {
                final byVersion = left.version.compareTo(right.version);
                if (byVersion != 0) return byVersion;
                return left.id.compareTo(right.id);
              });
        if (versions.isEmpty) continue;

        final selectedVersion = selections[groupId];
        _LegacyTreeMessage? selected;
        if (selectedVersion != null) {
          for (final version in versions) {
            if (version.version == selectedVersion) {
              selected = version;
              break;
            }
          }
        }
        if (selected == null && versions.length > 1) {
          selected = versions.last;
          selections[groupId] = selected.version;
          warnings.add(
            LegacyTreeMigrationWarning(
              conversationId: conversationId,
              groupId: groupId,
              fallbackVersion: selected.version,
            ),
          );
        } else {
          selected ??= versions.last;
        }

        for (final version in versions) {
          final parentMessageId = previousSelectedId;
          await customStatement(
            '''
            INSERT INTO message_tree_edge_rows
              (conversation_id, message_id, parent_message_id)
            VALUES (?, ?, ?);
            ''',
            [conversationId, version.id, parentMessageId],
          );
          if (version.id != selected.id) {
            await customStatement(
              '''
              INSERT INTO conversation_branch_rows
                (id, conversation_id, tip_message_id, name, created_at)
              VALUES (?, ?, ?, '', ?);
              ''',
              [
                'legacy-${version.id}',
                conversationId,
                version.id,
                version.timestamp,
              ],
            );
          }
        }
        previousSelectedId = selected.id;
      }

      await customStatement(
        '''
        INSERT INTO conversation_branch_rows
          (id, conversation_id, tip_message_id, name, created_at)
        VALUES (?, ?, ?, '', ?);
        ''',
        ['root-$conversationId', conversationId, previousSelectedId, createdAt],
      );
      await customStatement(
        '''
        INSERT INTO conversation_tree_state_rows
          (conversation_id, active_branch_id)
        VALUES (?, ?);
        ''',
        [conversationId, 'root-$conversationId'],
      );
      await customStatement(
        '''
        UPDATE conversation_rows
        SET version_selections_json = ?
        WHERE id = ?;
        ''',
        [jsonEncode(selections), conversationId],
      );
    }
    await customStatement(
      '''
      INSERT INTO chat_storage_meta_rows (key, value)
      VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value;
      ''',
      [
        AppDatabase.contextTreeMigrationWarningsKey,
        jsonEncode([for (final warning in warnings) warning.toJson()]),
      ],
    );
    return warnings;
  }

  Map<String, dynamic> _decodeVersionSelections(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{};
  }

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.createTable(messageTreeEdgeRows);
        await migrator.createTable(conversationBranchRows);
        await migrator.createTable(conversationTreeStateRows);
        await customStatement(
          'CREATE INDEX idx_message_tree_edges_conversation '
          'ON message_tree_edge_rows (conversation_id);',
        );
        await customStatement(
          'CREATE INDEX idx_conversation_branches_conversation '
          'ON conversation_branch_rows (conversation_id);',
        );
        await customStatement(
          'CREATE INDEX idx_conversation_tree_state_conversation '
          'ON conversation_tree_state_rows (conversation_id);',
        );
        await _populateLegacyConversationTreeBranchRows();
      }
      if (from >= 2 && from < 3) {
        await migrator.addColumn(
          conversationTreeStateRows,
          conversationTreeStateRows.branchSelectionsJson,
        );
      }
      if (from < 4) {
        await _renameLegacyAssistantTagRows();
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON;');
      await customStatement('PRAGMA busy_timeout = 5000;');
    },
  );

  Future<void> _renameLegacyAssistantTagRows() async {
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('assistant_tag_rows', 'assistant_group_rows');",
    ).get();
    final tables = rows.map((row) => row.read<String>('name')).toSet();
    final hasLegacyTable = tables.contains('assistant_tag_rows');
    final hasCurrentTable = tables.contains('assistant_group_rows');
    if (hasLegacyTable && hasCurrentTable) {
      throw StateError('assistant_group_table_conflict');
    }
    if (hasLegacyTable) {
      await customStatement(
        'ALTER TABLE assistant_tag_rows RENAME TO assistant_group_rows;',
      );
    }
  }
}
