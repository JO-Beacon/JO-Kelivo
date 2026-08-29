import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/database/app_database.dart';
import '../../core/database/chat_database_repository.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/conversation.dart';
import '../../core/models/message_part.dart';
import '../../core/services/backup/backup_settings_validator.dart';
import '../../core/services/backup/restore_durability.dart';
import '../../core/services/migration/legacy_message_content_decoder.dart';
import '../../core/services/migration/legacy_record_sanitizer.dart';
import '../../core/services/migration/migration_backup_file_name.dart';
import '../../core/services/migration/migration_chain_state.dart';
import '../../utils/app_directories.dart';
import '../../utils/sandbox_path_resolver.dart';

enum HiveToSqliteMigrationStage {
  intro,
  backupReady,
  backingUp,
  migrating,
  complete,
  failed,
}

enum HiveToSqliteBackupItemState { pending, active, done }

typedef MigrationBackupChunkWriter = Future<void> Function(Uint8List bytes);

class HiveToSqliteBackupItem {
  const HiveToSqliteBackupItem({
    required this.name,
    required this.bytes,
    this.writtenBytes = 0,
    this.state = HiveToSqliteBackupItemState.pending,
  });

  final String name;
  final int bytes;
  final int writtenBytes;
  final HiveToSqliteBackupItemState state;

  HiveToSqliteBackupItem copyWith({
    int? bytes,
    int? writtenBytes,
    HiveToSqliteBackupItemState? state,
  }) {
    return HiveToSqliteBackupItem(
      name: name,
      bytes: bytes ?? this.bytes,
      writtenBytes: writtenBytes ?? this.writtenBytes,
      state: state ?? this.state,
    );
  }
}

class HiveToSqliteMigrationStatus {
  const HiveToSqliteMigrationStatus({
    required this.stage,
    required this.progress,
    required this.title,
    this.detail = '',
    this.backupPath,
    this.error,
    this.log = const <String>[],
    this.conversations = 0,
    this.messages = 0,
    this.converted = 0,
    this.malformed = 0,
    this.missingFiles = 0,
    this.backupItems = const <HiveToSqliteBackupItem>[],
  });

  final HiveToSqliteMigrationStage stage;
  final double progress;
  final String title;
  final String detail;
  final String? backupPath;
  final String? error;
  final List<String> log;
  final int conversations;
  final int messages;

  /// 已成功转换为 parts 的旧附件标记。
  final int converted;

  /// 形似标记但无法解析、因而保留为文本的行。
  final int malformed;

  /// 已转换但磁盘文件缺失的本地附件。
  final int missingFiles;
  final List<HiveToSqliteBackupItem> backupItems;

  HiveToSqliteMigrationStatus copyWith({
    HiveToSqliteMigrationStage? stage,
    double? progress,
    String? title,
    String? detail,
    String? backupPath,
    String? error,
    List<String>? log,
    int? conversations,
    int? messages,
    int? converted,
    int? malformed,
    int? missingFiles,
    List<HiveToSqliteBackupItem>? backupItems,
  }) {
    return HiveToSqliteMigrationStatus(
      stage: stage ?? this.stage,
      progress: progress ?? this.progress,
      title: title ?? this.title,
      detail: detail ?? this.detail,
      backupPath: backupPath ?? this.backupPath,
      error: error ?? this.error,
      log: log ?? this.log,
      conversations: conversations ?? this.conversations,
      messages: messages ?? this.messages,
      converted: converted ?? this.converted,
      malformed: malformed ?? this.malformed,
      missingFiles: missingFiles ?? this.missingFiles,
      backupItems: backupItems ?? this.backupItems,
    );
  }
}

/// 迁移屏幕的共享工作流契约。底层存储引擎不同，但备份闸门、进度报告、
/// 重试和重启行为必须保持一致。
abstract interface class MigrationWorkflow {
  Directory get appDataDirectory;
  Stream<HiveToSqliteMigrationStatus> get statusStream;
  HiveToSqliteMigrationStatus initialStatus();
  bool get canOfferSkip;
  Future<int> loadAttemptState();
  Future<File> backupTo(Directory selectedDirectory);
  Future<File> backupToFile(File file);
  Future<File> backupToTemporaryFile();
  Future<void> migrate({String? backupPath});
  Future<String?> existingBackupPath();
  Future<bool> hasExternallySavedBackup();
  Future<void> recordExternalBackupSaved();
  Future<void> recordFailedAttempt();
  Future<void> skipMigrationAndStartFresh();
  Future<void> dispose();
}

class HiveToSqliteMigrationDecision {
  const HiveToSqliteMigrationDecision({
    required this.needsMigration,
    required this.appDataDir,
    required this.sqliteFile,
    required this.hiveFiles,
  });

  final bool needsMigration;
  final Directory appDataDir;
  final File sqliteFile;
  final List<File> hiveFiles;
}

class HiveToSqliteMigrationService implements MigrationWorkflow {
  HiveToSqliteMigrationService(this.decision, {RestoreDurability? durability})
    : _durability = durability ?? RestorePlatformDurability();

  static const skipAttemptThreshold = 2;
  static const _attemptStateFileName =
      'hive_to_sqlite_migration_attempt_v1.json';
  static const _conversationBoxName = 'conversations';
  static const _messagesBoxName = 'messages';
  static const _toolEventsBoxName = 'tool_events_v1';
  static const _messageBatchSize = 128;
  static const _settingsBackupName = 'settings.json';
  static const _legacyBusinessKeysNeededForRecovery = <String>{
    'instruction_injections_active_id_v1',
    'instruction_injections_active_ids_v1',
  };
  static const _backupPreparationShare = 0.15;
  static const _backupFileShare = 1 - _backupPreparationShare;
  static const _backupDirectories =
      <({String directoryName, String zipPrefix})>[
        (directoryName: 'upload', zipPrefix: 'upload'),
        (directoryName: 'images', zipPrefix: 'images'),
        (directoryName: 'avatars', zipPrefix: 'avatars'),
        (directoryName: 'fonts', zipPrefix: 'fonts'),
      ];

  final HiveToSqliteMigrationDecision decision;

  @override
  Directory get appDataDirectory => decision.appDataDir;

  /// 在所有批次写入完成且即将执行 [_validate] 前调用。
  /// 测试可用此钩子破坏临时数据库并断言回滚。
  @visibleForTesting
  Future<void> Function(ChatDatabaseRepository repo)?
  debugBeforeValidateForTest;

  /// 哪些消息 id 在逐条处理时应抛出异常，用于模拟损坏或无法解码的旧记录。
  /// 测试用此断言单条坏消息会被隔离，而不会让整个迁移失败。
  @visibleForTesting
  Set<String> debugFailMessageIdsForTest = <String>{};
  @visibleForTesting
  Set<String> debugFailConversationKeysForTest = <String>{};
  @visibleForTesting
  Set<String> debugFailPrescanMessageIdsForTest = <String>{};
  final RestoreDurability _durability;
  final _controller = StreamController<HiveToSqliteMigrationStatus>.broadcast();
  final _log = <String>[];
  var _lastBackupItems = const <HiveToSqliteBackupItem>[];
  var _attemptCount = 0;
  var _converted = 0;
  var _malformed = 0;
  var _missingFiles = 0;
  String? _persistedStageBreadcrumb;

  @override
  Stream<HiveToSqliteMigrationStatus> get statusStream => _controller.stream;

  int get attemptCount => _attemptCount;

  @override
  bool get canOfferSkip => _attemptCount >= skipAttemptThreshold;

  String? get lastAttemptStage => _persistedStageBreadcrumb;

  @override
  Future<int> loadAttemptState() async {
    final state = await _readAttemptState();
    _attemptCount = state.attempts;
    _persistedStageBreadcrumb = state.stage;
    return _attemptCount;
  }

  static Future<HiveToSqliteMigrationDecision> check() async {
    final appDataDir = await AppDirectories.getAppDataDirectory();
    final sqliteFile = File(
      p.join(appDataDir.path, AppDatabase.databaseFileName),
    );
    final hiveFiles = <File>[
      File(p.join(appDataDir.path, 'conversations.hive')),
      File(p.join(appDataDir.path, 'messages.hive')),
      File(p.join(appDataDir.path, 'tool_events_v1.hive')),
    ].where((file) => file.existsSync()).toList(growable: false);

    if (hiveFiles.isEmpty) {
      return HiveToSqliteMigrationDecision(
        needsMigration: false,
        appDataDir: appDataDir,
        sqliteFile: sqliteFile,
        hiveFiles: hiveFiles,
      );
    }
    if (sqliteFile.existsSync()) {
      // 读取 user_version 不会打开 Drift，因此不会在外部备份闸门保护文件前
      // 执行树结构升级。
      final installedSchema = ChatDatabaseRepository.readInstalledSchemaVersion(
        sqliteFile,
      );
      if (installedSchema >= 1 &&
          installedSchema < AppDatabase.currentSchemaVersion) {
        return HiveToSqliteMigrationDecision(
          needsMigration: false,
          appDataDir: appDataDir,
          sqliteFile: sqliteFile,
          hiveFiles: hiveFiles,
        );
      }
      final repo = ChatDatabaseRepository.open(file: sqliteFile);
      try {
        if (await repo.isMigrationComplete()) {
          await _deleteSqliteFamilyStatic(File('${sqliteFile.path}.previous'));
          return HiveToSqliteMigrationDecision(
            needsMigration: false,
            appDataDir: appDataDir,
            sqliteFile: sqliteFile,
            hiveFiles: hiveFiles,
          );
        }
      } finally {
        await repo.close();
      }
    }

    return HiveToSqliteMigrationDecision(
      needsMigration: true,
      appDataDir: appDataDir,
      sqliteFile: sqliteFile,
      hiveFiles: hiveFiles,
    );
  }

  @override
  HiveToSqliteMigrationStatus initialStatus() {
    return HiveToSqliteMigrationStatus(
      stage: HiveToSqliteMigrationStage.intro,
      progress: 0,
      title: 'intro',
      detail: 'waiting',
      log: List.of(_log),
      backupItems: _backupItemsForDecision(),
    );
  }

  @override
  Future<File> backupTo(Directory selectedDirectory) async {
    await selectedDirectory.create(recursive: true);
    final backupFile = File(
      p.join(selectedDirectory.path, migrationBackupFileName()),
    );
    final result = await _backupToFile(backupFile);
    await MigrationChainStateStore(decision.appDataDir).write(
      MigrationChainState(
        sourceKind: 'hive',
        backupPath: result.path,
        stage: 'backup-verified',
      ),
    );
    return result;
  }

  @override
  Future<File> backupToFile(File file) => _backupToFile(file);

  @override
  Future<File> backupToTemporaryFile() async {
    return _backupToFile(
      File(p.join(Directory.systemTemp.path, migrationBackupFileName())),
    );
  }

  /// 将 ZIP 直接写入平台拥有的目标，避免移动端再创建一份完整临时文件。
  Future<void> backupToWritableSink(MigrationBackupChunkWriter writeChunk) {
    return _backupToDestination(
      createOutput: () async => _MigrationZipOutput.toSink(writeChunk),
      managedOutputFile: null,
      visibleBackupPath: null,
    );
  }

  @override
  Future<String?> existingBackupPath() async {
    final state = await MigrationChainStateStore(decision.appDataDir).read();
    if (state?.sourceKind != 'hive' || state?.backupPath == null) return null;
    final file = File(state!.backupPath!);
    return await file.exists() ? file.path : null;
  }

  @override
  Future<bool> hasExternallySavedBackup() async {
    final state = await MigrationChainStateStore(decision.appDataDir).read();
    return state?.sourceKind == 'hive' && state?.externalBackupSaved == true;
  }

  @override
  Future<void> recordExternalBackupSaved() async {
    final store = MigrationChainStateStore(decision.appDataDir);
    final state = await store.read();
    await store.write(
      MigrationChainState(
        sourceKind: 'hive',
        backupPath: state?.sourceKind == 'hive' ? state?.backupPath : null,
        stage: 'backup-verified',
        externalBackupSaved: true,
      ),
    );
  }

  Future<File> _backupToFile(File backupFile) async {
    await _backupToDestination(
      createOutput: () => _MigrationZipOutput.openFile(backupFile.path),
      managedOutputFile: backupFile,
      visibleBackupPath: backupFile.path,
    );
    return backupFile;
  }

  Future<void> _backupToDestination({
    required Future<_MigrationZipOutput> Function() createOutput,
    required File? managedOutputFile,
    required String? visibleBackupPath,
  }) async {
    Directory? workDir;
    final plannedItems = _updateBackupItem(
      _backupItemsForDecision(),
      _settingsBackupName,
      state: HiveToSqliteBackupItemState.active,
    );
    _lastBackupItems = plannedItems;
    var copiedBytes = 0;
    var totalBytes = 0;
    _emit(
      HiveToSqliteMigrationStage.backingUp,
      0,
      'backup',
      _settingsBackupName,
      backupPath: visibleBackupPath,
      backupItems: plannedItems,
    );

    _MigrationZipWriter? writer;
    try {
      workDir = await Directory.systemTemp.createTemp(
        'kelivo_migration_backup_',
      );
      final manifest = await _buildBackupManifest(
        workDir,
        visibleBackupPath,
        plannedItems,
      );
      _lastBackupItems = manifest.items;
      totalBytes = manifest.totalBytes;

      if (managedOutputFile != null) {
        await managedOutputFile.parent.create(recursive: true);
        if (await managedOutputFile.exists()) {
          await managedOutputFile.delete();
        }
      }
      writer = _MigrationZipWriter(await createOutput());
      for (final entry in manifest.entries) {
        final name = entry.itemName;
        _lastBackupItems = _updateBackupItem(
          _lastBackupItems,
          name,
          bytes: entry.itemBytes,
          state: HiveToSqliteBackupItemState.active,
        );
        _emit(
          HiveToSqliteMigrationStage.backingUp,
          _backupProgress(copiedBytes, totalBytes),
          'backup',
          entry.entryName,
          backupPath: visibleBackupPath,
          backupItems: _lastBackupItems,
        );
        final written = await writer.addFile(
          entry.file,
          entry.entryName,
          onProgress: (fileWritten) {
            final currentTotal = copiedBytes + fileWritten;
            _lastBackupItems = _updateBackupItem(
              _lastBackupItems,
              name,
              bytes: entry.itemBytes,
              writtenBytes: entry.itemStartBytes + fileWritten,
              state: HiveToSqliteBackupItemState.active,
            );
            _emit(
              HiveToSqliteMigrationStage.backingUp,
              _backupProgress(currentTotal, totalBytes),
              'backup',
              entry.entryName,
              backupPath: visibleBackupPath,
              backupItems: _lastBackupItems,
            );
          },
        );
        copiedBytes += written;
        final itemWritten = entry.itemStartBytes + written;
        final itemDone = itemWritten >= entry.itemBytes;
        _lastBackupItems = _updateBackupItem(
          _lastBackupItems,
          name,
          bytes: entry.itemBytes,
          writtenBytes: itemWritten,
          state: itemDone
              ? HiveToSqliteBackupItemState.done
              : HiveToSqliteBackupItemState.active,
        );
      }
      await writer.close();
    } catch (error, stackTrace) {
      _logLine('$error');
      _logLine(stackTrace.toString());
      try {
        await writer?.closeIfNeeded();
      } catch (_) {}
      if (managedOutputFile != null && await managedOutputFile.exists()) {
        await managedOutputFile.delete();
      }
      _controller.add(
        HiveToSqliteMigrationStatus(
          stage: HiveToSqliteMigrationStage.failed,
          progress: totalBytes == 0
              ? 0
              : _backupProgress(copiedBytes, totalBytes).clamp(0, 1).toDouble(),
          title: 'failed',
          detail: 'backup',
          error: '$error',
          log: List.of(_log),
          converted: _converted,
          malformed: _malformed,
          missingFiles: _missingFiles,
          backupItems: _lastBackupItems,
        ),
      );
      rethrow;
    } finally {
      await writer?.closeIfNeeded();
      await _deleteDirectoryQuietly(workDir);
    }

    _emit(
      HiveToSqliteMigrationStage.backupReady,
      1,
      'backup',
      'done',
      backupPath: visibleBackupPath,
      backupItems: _lastBackupItems,
    );
  }

  @override
  Future<void> migrate({String? backupPath}) async {
    final chainStore = MigrationChainStateStore(decision.appDataDir);
    final chain = await chainStore.read();
    backupPath ??= chain?.sourceKind == 'hive' ? chain!.backupPath : null;
    if (backupPath != null || chain?.externalBackupSaved == true) {
      await chainStore.write(
        MigrationChainState(
          sourceKind: 'hive',
          backupPath: backupPath,
          stage: 'migrating',
          externalBackupSaved: chain?.externalBackupSaved == true,
        ),
      );
    }
    ChatDatabaseRepository? repo;
    LazyBox<Conversation>? conversationsBox;
    LazyBox<ChatMessage>? messagesBox;
    LazyBox<dynamic>? toolEventsBox;
    var published = false;
    try {
      // 将 canonicalize 绑定到本进程的应用数据根目录
      // （即使之前的测试或会话让 docsDir 指向了其他位置，也会刷新）。
      await SandboxPathResolver.init();
      await _beginAttempt();
      await _recordStageBreadcrumb(
        HiveToSqliteMigrationStage.migrating,
        'schema',
      );
      _emit(
        HiveToSqliteMigrationStage.migrating,
        0,
        'migrate',
        'schema',
        backupPath: backupPath,
        backupItems: _lastBackupItems,
      );
      _registerHiveAdapters();
      await Hive.initFlutter(decision.appDataDir.path);
      conversationsBox = await Hive.openLazyBox<Conversation>(
        _conversationBoxName,
      );
      messagesBox = await Hive.openLazyBox<ChatMessage>(_messagesBoxName);
      final hasToolEventsBox = decision.hiveFiles.any(
        (file) => p.basename(file.path) == 'tool_events_v1.hive',
      );
      if (hasToolEventsBox) {
        toolEventsBox = await Hive.openLazyBox<dynamic>(_toolEventsBoxName);
      }

      final tempFile = File('${decision.sqliteFile.path}.migrating');
      await _deleteSqliteFamily(tempFile);
      repo = ChatDatabaseRepository.open(file: tempFile);

      // 1.1.17 在运行时容忍悬空引用、跨会话复用和重复的 (groupId, version) 对；
      // 批次处理必须修复或跳过这些形态，而不是让整个迁移失败。
      final repairStats = _MigrationRepairStats();
      final conversations = <Conversation>[];
      for (final key in conversationsBox.keys) {
        try {
          assert(() {
            if (debugFailConversationKeysForTest.contains('$key')) {
              throw StateError('debug_forced_conversation_decode_failure');
            }
            return true;
          }());
          final conversation = await conversationsBox.get(key);
          if (conversation != null) conversations.add(conversation);
        } catch (error, stackTrace) {
          // 无法反序列化的会话记录只能影响该会话本身，不能拖垮整个迁移。
          // Hive 源文件会保留，因此不会破坏任何数据。
          repairStats.undecodableConversations++;
          _logLine('legacy-conversation skipped ($key): $error');
          _logLine(stackTrace.toString());
        }
      }
      conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      final totalMessages = conversations.fold<int>(
        0,
        (sum, conversation) => sum + conversation.messageIds.length,
      );
      var migratedMessages = 0;
      var expectedToolCallParts = 0;
      var expectedImageParts = 0;
      var expectedFileParts = 0;
      _converted = 0;
      _malformed = 0;
      _missingFiles = 0;
      final expectedTextContentDigest = Uint8List(32);
      _emit(
        HiveToSqliteMigrationStage.migrating,
        0.04,
        'migrate',
        'schema',
        backupPath: backupPath,
        backupItems: _lastBackupItems,
        conversations: conversations.length,
        messages: totalMessages,
      );

      await repo.clearAllData();
      final seenMessageIds = <String>{};
      await _recordStageBreadcrumb(
        HiveToSqliteMigrationStage.migrating,
        'messages',
      );
      for (final legacyConversation in conversations) {
        final conversation = _sanitizeLegacyConversationFields(
          await _convertLegacyVersionSelections(
            await _convertLegacyTruncateIndex(
              legacyConversation,
              messagesBox,
              seenMessageIds,
            ),
            messagesBox,
            seenMessageIds,
          ),
          repairStats,
        );
        var needsConversationInsert = true;
        var order = 0;
        final seenGroupVersions = <String>{};
        final maxGroupVersions = <String, int>{};
        for (
          var start = 0;
          start < conversation.messageIds.length;
          start += _messageBatchSize
        ) {
          final end = (start + _messageBatchSize)
              .clamp(start, conversation.messageIds.length)
              .toInt();
          final batch = <({ChatMessage message, int messageOrder})>[];
          final toolEventsByMessageId = <String, List<Map<String, dynamic>>>{};
          final geminiSignaturesByMessageId = <String, String>{};
          for (var i = start; i < end; i++) {
            final messageId = conversation.messageIds[i];
            try {
              var message = await messagesBox.get(messageId);
              if (message == null) {
                repairStats.danglingMessageRefs++;
                continue;
              }
              assert(() {
                if (debugFailMessageIdsForTest.contains(message!.id)) {
                  throw StateError('debug_forced_decode_failure');
                }
                return true;
              }());
              if (!seenMessageIds.add(message.id)) {
                repairStats.duplicateMessageIds++;
                continue;
              }
              if (message.conversationId != conversation.id) {
                repairStats.conversationIdMismatches++;
                message = message.copyWith(conversationId: conversation.id);
              }
              // 字段级修复（空 role、负 token 或 duration、越界 version、
              // 反转的推理时间戳）与迁移清理逻辑保持一致。
              final sanitized = sanitizeLegacyMessageFields(message);
              if (!identical(sanitized, message)) {
                repairStats.dirtyNumericFields++;
                message = sanitized;
              }
              final groupId = message.groupId;
              // 空字符串会原样存储，并且对 unique(conversationId, groupId, version)
              // 索引而言是真实值（与 NULL 不同），因此空字符串分组也需要修复 version。
              if (groupId != null) {
                var version = message.version;
                if (!seenGroupVersions.add('$groupId\u0000$version')) {
                  version = (maxGroupVersions[groupId] ?? version) + 1;
                  repairStats.versionConflicts++;
                  message = message.copyWith(version: version);
                  seenGroupVersions.add('$groupId\u0000$version');
                }
                final knownMax = maxGroupVersions[groupId];
                if (knownMax == null || version > knownMax) {
                  maxGroupVersions[groupId] = version;
                }
              }
              final legacyContent = message.content;
              final decodeResult = await decodeLegacyContent(
                legacyContent,
                existingParts: message.parts,
              );
              var parts = List<MessagePart>.of(decodeResult.parts);
              if (parts.isEmpty) {
                // 与仓储持久化保持一致：空正文变成一个空 text part。
                parts = const <MessagePart>[TextPart('')];
              }
              parts = _normalizeAttachmentPartUris(parts);
              message = message.copyWith(parts: parts);
              // 预期摘要来自独立剥离后的旧文本，而不是简单回显解码出的 TextPart。
              // 在提交前计算，以便剥离失败时干净地跳过该消息。
              final textSegments = stripLegacyContentTextSegments(
                legacyContent,
              );
              List<Map<String, dynamic>>? events;
              String? signature;
              if (toolEventsBox != null) {
                final gathered = await _toolEventsFor(
                  toolEventsBox,
                  message.id,
                );
                if (gathered.isNotEmpty) events = gathered;
                signature = await _signatureFor(toolEventsBox, message.id);
              }

              // 只有每个可能失败的步骤都成功后才提交，这样上方抛出的消息会被完全跳过，
              // 不会计入批次、预期数量或摘要。批次写入本身保持在 try 之外：
              // 数据库失败必须显式暴露。
              _converted += decodeResult.converted;
              _malformed += decodeResult.malformed;
              _missingFiles += decodeResult.missingFiles;
              expectedImageParts += parts.whereType<ImagePart>().length;
              expectedFileParts += parts.whereType<FilePart>().length;
              batch.add((message: message, messageOrder: order));
              order++;
              for (final segment in textSegments) {
                ChatDatabaseRepository.mixTextPartContentDigest(
                  expectedTextContentDigest,
                  message.id,
                  segment,
                );
              }
              if (events != null) {
                toolEventsByMessageId[message.id] = events;
                expectedToolCallParts += events.length;
              }
              if (signature != null) {
                geminiSignaturesByMessageId[message.id] = signature;
              }
            } catch (error, stackTrace) {
              // 单条损坏或无法解码的旧记录不应拖垮整个迁移。
              // 跳过并计数后继续；Hive 源文件会保留，因此不会破坏任何数据。
              repairStats.decodeFailures++;
              _logLine('legacy-message skipped ($messageId): $error');
              _logLine(stackTrace.toString());
            }
          }
          await repo.putMigrationBatch(
            conversations: needsConversationInsert
                ? [conversation]
                : const <Conversation>[],
            messages: batch,
            toolEventsByMessageId: toolEventsByMessageId,
            geminiSignaturesByMessageId: geminiSignaturesByMessageId,
          );
          needsConversationInsert = false;
          migratedMessages += batch.length;
          final messageProgress = totalMessages == 0
              ? 0.9
              : 0.04 + (migratedMessages / totalMessages) * 0.86;
          _emit(
            HiveToSqliteMigrationStage.migrating,
            messageProgress,
            'migrate',
            'messages',
            backupPath: backupPath,
            backupItems: _lastBackupItems,
            conversations: conversations.length,
            messages: migratedMessages,
          );
          await Future<void>.delayed(Duration.zero);
        }
        if (needsConversationInsert) {
          await repo.putMigrationBatch(
            conversations: [conversation],
            messages: const <({ChatMessage message, int messageOrder})>[],
            toolEventsByMessageId: const <String, List<Map<String, dynamic>>>{},
            geminiSignaturesByMessageId: const <String, String>{},
          );
        }
      }
      if (repairStats.hasIssues) {
        _logLine('legacy-data repairs: ${repairStats.describe()}');
      }

      await _recordStageBreadcrumb(
        HiveToSqliteMigrationStage.migrating,
        'tool_events',
      );
      _emit(
        HiveToSqliteMigrationStage.migrating,
        0.94,
        'migrate',
        'tool_events',
        backupPath: backupPath,
        backupItems: _lastBackupItems,
        conversations: conversations.length,
        messages: migratedMessages,
      );
      await _recordStageBreadcrumb(
        HiveToSqliteMigrationStage.migrating,
        'validate',
      );
      _emit(
        HiveToSqliteMigrationStage.migrating,
        0.98,
        'migrate',
        'validate',
        backupPath: backupPath,
        backupItems: _lastBackupItems,
        conversations: conversations.length,
        messages: migratedMessages,
      );
      final beforeValidate = debugBeforeValidateForTest;
      if (beforeValidate != null) {
        await beforeValidate(repo);
      }
      _logLine(
        'legacy-content decode: converted=$_converted '
        'malformed=$_malformed missingFiles=$_missingFiles',
      );
      await _validate(
        repo,
        expectedConversations: conversations.length,
        expectedMessages: migratedMessages,
        expectedTextContentDigest:
            ChatDatabaseRepository.textPartContentDigestHex(
              expectedTextContentDigest,
            ),
        expectedToolCallParts: expectedToolCallParts,
        expectedImageParts: expectedImageParts,
        expectedFileParts: expectedFileParts,
        backupPath: backupPath,
        migratedMessages: migratedMessages,
      );
      await repo.markMigrationComplete();
      await repo.checkpoint();
      await repo.close();
      repo = null;
      // WAL 截断可能留下空的 -wal/-shm 文件；在发布断言把任何附属文件
      // 视为意外数据丢失之前先清理它们。
      await _deleteDatabaseSidecars(tempFile);

      await _recordStageBreadcrumb(
        HiveToSqliteMigrationStage.migrating,
        'publish',
      );
      await _replaceSqlite(tempFile, decision.sqliteFile);
      published = true;
      await _clearAttemptState();
      _emit(
        HiveToSqliteMigrationStage.complete,
        1,
        'complete',
        'done',
        backupPath: backupPath,
        backupItems: _lastBackupItems,
        conversations: conversations.length,
        messages: migratedMessages,
      );
    } catch (error, stackTrace) {
      _logLine('$error');
      _logLine(stackTrace.toString());
      _controller.add(
        HiveToSqliteMigrationStatus(
          stage: HiveToSqliteMigrationStage.failed,
          progress: 0,
          title: 'failed',
          detail: 'failed',
          backupPath: backupPath,
          error: '$error',
          log: List.of(_log),
          converted: _converted,
          malformed: _malformed,
          missingFiles: _missingFiles,
          backupItems: _lastBackupItems,
        ),
      );
      rethrow;
    } finally {
      await repo?.close();
      await conversationsBox?.close();
      await messagesBox?.close();
      await toolEventsBox?.close();
      if (!published) {
        // 失败的尝试不能留下半迁移的数据库文件族；
        // 否则启动闸门会持续拒绝它。
        await _deleteSqliteFamily(
          File('${decision.sqliteFile.path}.migrating'),
        );
      }
    }
  }

  /// 委托给共享旧数据清理器，并在迁移统计中记录修复数量。
  /// 脏 Hive 数据中的越界计数器否则会以 SQLITE_CONSTRAINT_CHECK 中止整个迁移。
  Conversation _sanitizeLegacyConversationFields(
    Conversation conversation,
    _MigrationRepairStats stats,
  ) {
    final sanitized = sanitizeLegacyConversationFields(conversation);
    if (!identical(sanitized, conversation)) {
      stats.dirtyNumericFields++;
    }
    return sanitized;
  }

  /// 预扫描安全的消息读取：无法解码的记录会像悬空引用一样处理，而不是中止迁移。
  /// 主循环会再次读取同一条记录，并在修复统计中计数一次。
  Future<ChatMessage?> _tryGetLegacyMessage(
    LazyBox<ChatMessage> messagesBox,
    String messageId,
  ) async {
    try {
      assert(() {
        if (debugFailPrescanMessageIdsForTest.contains(messageId)) {
          throw StateError('debug_forced_prescan_decode_failure');
        }
        return true;
      }());
      return await messagesBox.get(messageId);
    } catch (error) {
      _logLine('legacy-message prescan read failed ($messageId): $error');
      return null;
    }
  }

  Future<Conversation> _convertLegacyTruncateIndex(
    Conversation conversation,
    LazyBox<ChatMessage> messagesBox,
    Set<String> alreadyMigratedMessageIds,
  ) async {
    final truncateIndex = conversation.truncateIndex;
    if (truncateIndex < 0 || truncateIndex > conversation.messageIds.length) {
      return conversation;
    }

    final groupsBeforeTruncate = <String>{};
    for (var i = 0; i < truncateIndex; i++) {
      final message = await _tryGetLegacyMessage(
        messagesBox,
        conversation.messageIds[i],
      );
      if (message == null || alreadyMigratedMessageIds.contains(message.id)) {
        continue;
      }
      groupsBeforeTruncate.add(message.groupId ?? message.id);
    }
    final logicalIndex = groupsBeforeTruncate.length;
    return logicalIndex == truncateIndex
        ? conversation
        : conversation.copyWith(truncateIndex: logicalIndex);
  }

  Future<Conversation> _convertLegacyVersionSelections(
    Conversation conversation,
    LazyBox<ChatMessage> messagesBox,
    Set<String> alreadyMigratedMessageIds,
  ) async {
    if (conversation.versionSelections.isEmpty) return conversation;

    final messagesByGroup = <String, List<ChatMessage>>{
      for (final groupId in conversation.versionSelections.keys)
        groupId: <ChatMessage>[],
    };
    final repairedVersionsByMessageId = <String, int>{};
    final localMessageIds = <String>{};
    final seenGroupVersions = <String>{};
    final maxGroupVersions = <String, int>{};
    for (final messageId in conversation.messageIds) {
      final message = await _tryGetLegacyMessage(messagesBox, messageId);
      if (message == null) continue;
      messagesByGroup[message.groupId ?? message.id]?.add(message);
      if (alreadyMigratedMessageIds.contains(message.id) ||
          !localMessageIds.add(message.id)) {
        continue;
      }

      final groupId = message.groupId;
      if (groupId == null) continue;
      var repairedVersion = message.version;
      if (!seenGroupVersions.add('$groupId\u0000$repairedVersion')) {
        repairedVersion = (maxGroupVersions[groupId] ?? repairedVersion) + 1;
        repairedVersionsByMessageId[message.id] = repairedVersion;
        seenGroupVersions.add('$groupId\u0000$repairedVersion');
      }
      final knownMax = maxGroupVersions[groupId];
      if (knownMax == null || repairedVersion > knownMax) {
        maxGroupVersions[groupId] = repairedVersion;
      }
    }

    final convertedSelections = Map<String, int>.from(
      conversation.versionSelections,
    );
    var changed = false;
    for (final entry in conversation.versionSelections.entries) {
      final messages = messagesByGroup[entry.key]!
        ..sort((left, right) => left.version.compareTo(right.version));
      if (messages.isEmpty) continue;
      final ordinal = entry.value;
      final selectedMessage = ordinal >= 0 && ordinal < messages.length
          ? messages[ordinal]
          : messages.last;
      final version =
          repairedVersionsByMessageId[selectedMessage.id] ??
          selectedMessage.version;
      if (version != ordinal) {
        convertedSelections[entry.key] = version;
        changed = true;
      }
    }

    return changed
        ? conversation.copyWith(versionSelections: convertedSelections)
        : conversation;
  }

  /// 多次迁移失败后的逃生通道：将旧 Hive 文件重命名为 `<name>.retired`，
  /// 使 [check] 停止请求迁移，下一次启动从空 SQLite 数据库开始。
  /// 退役文件会保留在磁盘上供手动恢复。
  @override
  Future<void> skipMigrationAndStartFresh() async {
    for (final hiveFile in decision.hiveFiles) {
      final lockFile = File('${p.withoutExtension(hiveFile.path)}.lock');
      try {
        if (await lockFile.exists()) {
          await lockFile.rename('${lockFile.path}.retired');
        }
      } catch (error) {
        // 锁文件只是建议性的；残留文件不能阻塞跳过操作。
        _logLine('skip-migration lock rename: $error');
      }
      if (await hiveFile.exists()) {
        await hiveFile.rename('${hiveFile.path}.retired');
      }
    }
    // 失败的尝试可能留下临时数据库文件族。
    await _deleteSqliteFamily(File('${decision.sqliteFile.path}.migrating'));
    await _deleteSqliteFamily(File('${decision.sqliteFile.path}.previous'));
    await _clearAttemptState();
    _logLine('skip-migration: legacy hive files retired');
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }

  List<HiveToSqliteBackupItem> _backupItemsForDecision() {
    return [
      const HiveToSqliteBackupItem(name: _settingsBackupName, bytes: 0),
      for (final file in decision.hiveFiles)
        HiveToSqliteBackupItem(name: p.basename(file.path), bytes: 0),
      for (final directory in _backupDirectories)
        if (_backupDirectoryMayContainFiles(directory.directoryName))
          HiveToSqliteBackupItem(name: '${directory.zipPrefix}/', bytes: 0),
    ];
  }

  bool _backupDirectoryMayContainFiles(String directoryName) {
    final directory = Directory(
      p.join(decision.appDataDir.path, directoryName),
    );
    try {
      if (!directory.existsSync()) return false;
      return directory.listSync(followLinks: false).isNotEmpty;
    } catch (_) {
      return true;
    }
  }

  Future<_MigrationBackupManifest> _buildBackupManifest(
    Directory workDir,
    String? backupPath,
    List<HiveToSqliteBackupItem> plannedItems,
  ) async {
    final files = <_MigrationBackupFile>[];
    var items = plannedItems;

    items = _updateBackupItem(
      items,
      _settingsBackupName,
      state: HiveToSqliteBackupItemState.active,
    );
    _emit(
      HiveToSqliteMigrationStage.backingUp,
      0.02,
      'backup',
      _settingsBackupName,
      backupPath: backupPath,
      backupItems: items,
    );
    final settingsJson = await _exportSettingsJson();
    final settingsFile = await _writeTempText(
      workDir,
      '_migration_settings.json',
      settingsJson,
    );
    final settingsBytes = await settingsFile.length();
    items = _updateBackupItem(
      items,
      _settingsBackupName,
      bytes: settingsBytes,
      writtenBytes: settingsBytes,
      state: HiveToSqliteBackupItemState.done,
    );
    _lastBackupItems = items;
    files.add(
      _MigrationBackupFile(
        file: settingsFile,
        entryName: _settingsBackupName,
        itemName: _settingsBackupName,
        bytes: settingsBytes,
      ),
    );

    // 在任何操作打开 Hive 前快照原始 .hive 文件，确保归档保留
    // 迁移失败时可手动恢复的权威字节。
    final hiveSnapshots = <String, File>{};
    for (final hiveFile in decision.hiveFiles) {
      final snapshot = File(
        p.join(workDir.path, 'raw_${p.basename(hiveFile.path)}'),
      );
      await hiveFile.copy(snapshot.path);
      hiveSnapshots[hiveFile.path] = snapshot;
    }

    for (final hiveFile in decision.hiveFiles) {
      final itemName = p.basename(hiveFile.path);
      // 归档打开前快照，而不是 Hive 在此过程中可能已崩溃恢复（截断）的活动文件。
      final source = hiveSnapshots[hiveFile.path] ?? hiveFile;
      final bytes = await source.length();
      items = _updateBackupItem(items, itemName, bytes: bytes);
      _lastBackupItems = items;
      _emit(
        HiveToSqliteMigrationStage.backingUp,
        0.13,
        'backup',
        itemName,
        backupPath: backupPath,
        backupItems: items,
      );
      files.add(
        _MigrationBackupFile(
          file: source,
          entryName: itemName,
          itemName: itemName,
          bytes: bytes,
        ),
      );
    }

    for (final directory in _backupDirectories) {
      final source = Directory(
        p.join(decision.appDataDir.path, directory.directoryName),
      );
      final itemName = '${directory.zipPrefix}/';
      if (!items.any((item) => item.name == itemName)) continue;
      items = _updateBackupItem(
        items,
        itemName,
        state: HiveToSqliteBackupItemState.active,
      );
      _lastBackupItems = items;
      _emit(
        HiveToSqliteMigrationStage.backingUp,
        0.13,
        'backup',
        itemName,
        backupPath: backupPath,
        backupItems: items,
      );
      final directoryFiles = await _filesInDirectory(
        source,
        directory.zipPrefix,
        itemName,
        onProgress: (bytes) {
          items = _updateBackupItem(
            items,
            itemName,
            bytes: bytes,
            state: HiveToSqliteBackupItemState.active,
          );
          _lastBackupItems = items;
          _emit(
            HiveToSqliteMigrationStage.backingUp,
            0.13,
            'backup',
            itemName,
            backupPath: backupPath,
            backupItems: items,
          );
        },
      );
      if (directoryFiles.isEmpty) {
        items = _updateBackupItem(
          items,
          itemName,
          bytes: 0,
          state: HiveToSqliteBackupItemState.done,
        );
        _lastBackupItems = items;
        _emit(
          HiveToSqliteMigrationStage.backingUp,
          0.13,
          'backup',
          itemName,
          backupPath: backupPath,
          backupItems: items,
        );
        continue;
      }
      final bytes = directoryFiles.fold<int>(
        0,
        (sum, file) => sum + file.bytes,
      );
      items = _updateBackupItem(items, itemName, bytes: bytes);
      _lastBackupItems = items;
      _emit(
        HiveToSqliteMigrationStage.backingUp,
        0.13,
        'backup',
        itemName,
        backupPath: backupPath,
        backupItems: items,
      );
      files.addAll(directoryFiles);
    }

    final itemBytes = <String, int>{};
    for (final item in items) {
      itemBytes[item.name] = item.bytes;
    }
    final itemWritten = <String, int>{};
    final entries = <_MigrationBackupFileEntry>[];
    for (final file in files) {
      final startBytes = itemWritten[file.itemName] ?? 0;
      entries.add(
        _MigrationBackupFileEntry(
          file: file.file,
          entryName: file.entryName,
          itemName: file.itemName,
          bytes: file.bytes,
          itemBytes: itemBytes[file.itemName] ?? file.bytes,
          itemStartBytes: startBytes,
        ),
      );
      itemWritten[file.itemName] = startBytes + file.bytes;
    }

    return _MigrationBackupManifest(
      entries: entries,
      items: [
        for (final item in items)
          item.copyWith(
            writtenBytes: 0,
            state: HiveToSqliteBackupItemState.pending,
          ),
      ],
      totalBytes: files.fold<int>(0, (sum, file) => sum + file.bytes),
    );
  }

  List<HiveToSqliteBackupItem> _updateBackupItem(
    List<HiveToSqliteBackupItem> items,
    String name, {
    int? bytes,
    int? writtenBytes,
    HiveToSqliteBackupItemState? state,
  }) {
    return [
      for (final item in items)
        if (item.name == name)
          item.copyWith(bytes: bytes, writtenBytes: writtenBytes, state: state)
        else
          item,
    ];
  }

  Future<List<_MigrationBackupFile>> _filesInDirectory(
    Directory directory,
    String zipPrefix,
    String itemName, {
    required void Function(int bytes) onProgress,
  }) async {
    if (!await directory.exists()) return const <_MigrationBackupFile>[];
    final files = <_MigrationBackupFile>[];
    var totalBytes = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p
          .relative(entity.path, from: directory.path)
          .replaceAll('\\', '/');
      final bytes = await entity.length();
      files.add(
        _MigrationBackupFile(
          file: entity,
          entryName: _zipEntryName('$zipPrefix/$relative'),
          itemName: itemName,
          bytes: bytes,
        ),
      );
      totalBytes += bytes;
      if (files.length == 1 || files.length % 40 == 0) {
        onProgress(totalBytes);
        await Future<void>.delayed(Duration.zero);
      }
    }
    onProgress(totalBytes);
    files.sort((a, b) => a.entryName.compareTo(b.entryName));
    return files;
  }

  Future<String> _exportSettingsJson() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, Object>{};
    for (final key in prefs.getKeys()) {
      if (BackupSettingsValidator.shouldIgnore(key) &&
          !_legacyBusinessKeysNeededForRecovery.contains(key)) {
        continue;
      }
      final value = prefs.get(key);
      if (value != null) map[key] = value;
    }
    return jsonEncode(map);
  }

  Future<File> _writeTempText(
    Directory directory,
    String name,
    String content,
  ) async {
    final file = File(p.join(directory.path, name));
    await file.writeAsString(content);
    return file;
  }

  double _backupProgress(int copiedBytes, int totalBytes) {
    if (totalBytes <= 0) return 1;
    return _backupPreparationShare +
        (copiedBytes / totalBytes) * _backupFileShare;
  }

  static Future<void> _deleteDirectoryQuietly(Directory? directory) async {
    if (directory == null) return;
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }

  static String _zipEntryName(String name) {
    return name.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
  }

  Future<List<Map<String, dynamic>>> _toolEventsFor(
    LazyBox<dynamic> box,
    String messageId,
  ) async {
    final value = await box.get(messageId);
    if (value is! List) return const <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  Future<String?> _signatureFor(LazyBox<dynamic> box, String messageId) async {
    final value = await box.get('sig_$messageId');
    if (value is String && value.trim().isNotEmpty) return value;
    return null;
  }

  Future<void> _validate(
    ChatDatabaseRepository repo, {
    required int expectedConversations,
    required int expectedMessages,
    required String expectedTextContentDigest,
    required int expectedToolCallParts,
    required int expectedImageParts,
    required int expectedFileParts,
    String? backupPath,
    int migratedMessages = 0,
  }) async {
    final conversationCount = await repo.getConversationCount();
    if (conversationCount != expectedConversations) {
      throw StateError(
        'Migration validation failed (conversation count): '
        'expected $expectedConversations, got $conversationCount.',
      );
    }
    final messageCount = await repo.getTotalMessageCount();
    if (messageCount != expectedMessages) {
      throw StateError(
        'Migration validation failed (message count): '
        'expected $expectedMessages, got $messageCount.',
      );
    }
    final toolCallPartCount = await repo.getToolCallPartCount();
    if (toolCallPartCount != expectedToolCallParts) {
      throw StateError(
        'Migration validation failed (tool_call part count): '
        'expected $expectedToolCallParts, got $toolCallPartCount.',
      );
    }
    final imagePartCount = await repo.getImagePartCount();
    if (imagePartCount != expectedImageParts) {
      throw StateError(
        'Migration validation failed (image part count): '
        'expected $expectedImageParts, got $imagePartCount.',
      );
    }
    final filePartCount = await repo.getFilePartCount();
    if (filePartCount != expectedFileParts) {
      throw StateError(
        'Migration validation failed (file part count): '
        'expected $expectedFileParts, got $filePartCount.',
      );
    }
    var lastAttachmentProgressEmit = DateTime.fromMillisecondsSinceEpoch(0);
    await repo.validateAttachmentPartPayloads(
      onProgress: (processed, total) {
        final now = DateTime.now();
        final isDone = total > 0 && processed >= total;
        if (!isDone &&
            now.difference(lastAttachmentProgressEmit) <
                const Duration(milliseconds: 100)) {
          return;
        }
        lastAttachmentProgressEmit = now;
        final fraction = total <= 0 ? 1.0 : (processed / total).clamp(0.0, 1.0);
        _emit(
          HiveToSqliteMigrationStage.migrating,
          0.98 + 0.005 * fraction,
          'migrate',
          'validate',
          backupPath: backupPath,
          backupItems: _lastBackupItems,
          conversations: expectedConversations,
          messages: migratedMessages,
        );
      },
    );
    // 摘要计算在工作 isolate 上扫描数 GB 数据；将字节进度映射到剩余的
    // 校验窗口，使迁移进度条持续前进。
    var lastDigestProgressEmit = DateTime.fromMillisecondsSinceEpoch(0);
    final textContentDigest = await repo.getTextPartContentDigest(
      onProgress: (processedChars, totalChars) {
        final now = DateTime.now();
        final isDone = totalChars > 0 && processedChars >= totalChars;
        if (!isDone &&
            now.difference(lastDigestProgressEmit) <
                const Duration(milliseconds: 100)) {
          return;
        }
        lastDigestProgressEmit = now;
        final fraction = totalChars <= 0
            ? 1.0
            : (processedChars / totalChars).clamp(0.0, 1.0);
        _emit(
          HiveToSqliteMigrationStage.migrating,
          0.985 + 0.01 * fraction,
          'migrate',
          'validate',
          backupPath: backupPath,
          backupItems: _lastBackupItems,
          conversations: expectedConversations,
          messages: migratedMessages,
        );
      },
    );
    if (textContentDigest != expectedTextContentDigest) {
      throw StateError(
        'Migration validation failed (text content digest): '
        'expected $expectedTextContentDigest, got $textContentDigest.',
      );
    }
  }

  @visibleForTesting
  Future<void> replaceSqliteForTest(File tempFile, File sqliteFile) {
    return _replaceSqlite(tempFile, sqliteFile);
  }

  Future<void> _replaceSqlite(File tempFile, File sqliteFile) async {
    final asideFile = File('${sqliteFile.path}.previous');
    final tempType = await FileSystemEntity.type(
      tempFile.path,
      followLinks: false,
    );
    final liveType = await FileSystemEntity.type(
      sqliteFile.path,
      followLinks: false,
    );

    if (tempType == FileSystemEntityType.notFound) {
      if (liveType != FileSystemEntityType.file) {
        throw StateError('migration_publish_missing_temp');
      }
      await _deleteDatabaseSidecars(sqliteFile);
      await _deleteSqliteFamily(asideFile);
      return;
    }
    if (tempType != FileSystemEntityType.file) {
      throw StateError('migration_publish_temp_not_file');
    }
    await _requireNoDatabaseSidecars(tempFile);

    if (liveType == FileSystemEntityType.directory) {
      throw StateError('migration_publish_live_not_file');
    }
    if (liveType == FileSystemEntityType.file) {
      await _deleteDatabaseSidecars(sqliteFile);
      await _deleteSqliteFamily(asideFile);
      await _durability.renameAndSync(
        source: sqliteFile,
        targetPath: asideFile.path,
      );
    }

    final liveAfterAside = await FileSystemEntity.type(
      sqliteFile.path,
      followLinks: false,
    );
    if (liveAfterAside == FileSystemEntityType.notFound) {
      await _durability.renameAndSync(
        source: tempFile,
        targetPath: sqliteFile.path,
      );
    } else if (await tempFile.exists()) {
      throw StateError('migration_publish_split_brain');
    }

    await _durability.syncDirectory(
      Directory(p.dirname(sqliteFile.path)),
      fullBarrier: true,
    );
    await _deleteSqliteFamily(asideFile);
  }

  Future<void> _requireNoDatabaseSidecars(File databaseFile) async {
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final sidecar = File('${databaseFile.path}$suffix');
      if (await FileSystemEntity.type(sidecar.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('database_sidecar:$suffix');
      }
    }
  }

  Future<void> _deleteDatabaseSidecars(File databaseFile) async {
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final sidecar = File('${databaseFile.path}$suffix');
      if (await FileSystemEntity.type(sidecar.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await sidecar.delete();
      }
    }
  }

  Future<void> _deleteSqliteFamily(File file) =>
      _deleteSqliteFamilyStatic(file);

  static Future<void> _deleteSqliteFamilyStatic(File file) async {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final target = File('${file.path}$suffix');
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await target.delete();
      }
    }
  }

  File get _attemptStateFile =>
      File(p.join(decision.appDataDir.path, _attemptStateFileName));

  Future<void> _beginAttempt() async {
    final state = await _readAttemptState();
    _attemptCount = state.attempts + 1;
    _persistedStageBreadcrumb = 'migrating/start';
    await _writeAttemptState(
      attempts: _attemptCount,
      stage: _persistedStageBreadcrumb!,
    );
    _logLine(
      'migration-attempt: $_attemptCount '
      '(${HiveToSqliteMigrationStage.migrating.name}/start)',
    );
  }

  /// 记录在 [migrate] 运行前（即备份创建阶段）失败的尝试。
  /// [migrate] 会通过 [_beginAttempt] 自己递增计数器，因此调用方只能为
  /// 备份阶段失败调用此方法；否则磁盘满或目标不可写的用户永远无法
  /// 到达跳过逃生通道，而会被困在迁移页面。
  @override
  Future<void> recordFailedAttempt() async {
    final state = await _readAttemptState();
    _attemptCount = state.attempts + 1;
    _persistedStageBreadcrumb =
        '${HiveToSqliteMigrationStage.backingUp.name}/failed';
    await _writeAttemptState(
      attempts: _attemptCount,
      stage: _persistedStageBreadcrumb!,
    );
    _logLine(
      'migration-attempt: $_attemptCount '
      '(${HiveToSqliteMigrationStage.backingUp.name}/failed)',
    );
  }

  Future<void> _recordStageBreadcrumb(
    HiveToSqliteMigrationStage stage,
    String detail,
  ) async {
    final breadcrumb = '${stage.name}/$detail';
    if (breadcrumb == _persistedStageBreadcrumb) return;
    _persistedStageBreadcrumb = breadcrumb;
    _logLine('migration-stage: $breadcrumb');
    await _writeAttemptState(attempts: _attemptCount, stage: breadcrumb);
  }

  Future<void> _clearAttemptState() async {
    _attemptCount = 0;
    _persistedStageBreadcrumb = null;
    final file = _attemptStateFile;
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await file.delete();
    }
  }

  Future<({int attempts, String? stage})> _readAttemptState() async {
    final file = _attemptStateFile;
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return (attempts: 0, stage: null);
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return (attempts: 0, stage: null);
      final attempts = decoded['attempts'];
      final stage = decoded['stage'];
      return (
        attempts: attempts is int && attempts > 0 ? attempts : 0,
        stage: stage is String && stage.isNotEmpty ? stage : null,
      );
    } catch (_) {
      return (attempts: 0, stage: null);
    }
  }

  Future<void> _writeAttemptState({
    required int attempts,
    required String stage,
  }) async {
    final file = _attemptStateFile;
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'attempts': attempts, 'stage': stage}),
      flush: true,
    );
    // POSIX rename 会原子地替换现有目标。Windows 要求目标不存在，
    // 这会短暂出现“两边都没有文件”的窗口。
    if (Platform.isWindows && await file.exists()) {
      await file.delete();
    }
    await temporary.rename(file.path);
  }

  void _registerHiveAdapters() {
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ConversationAdapter());
    }
  }

  void _emit(
    HiveToSqliteMigrationStage stage,
    double progress,
    String title,
    String detail, {
    String? backupPath,
    String? error,
    int conversations = 0,
    int messages = 0,
    List<HiveToSqliteBackupItem>? backupItems,
  }) {
    final bounded = progress.clamp(0, 1).toDouble();
    _logLine('$title: $detail ${(bounded * 100).toStringAsFixed(0)}%');
    _controller.add(
      HiveToSqliteMigrationStatus(
        stage: stage,
        progress: bounded,
        title: title,
        detail: detail,
        backupPath: backupPath,
        error: error,
        log: List.of(_log),
        conversations: conversations,
        messages: messages,
        converted: _converted,
        malformed: _malformed,
        missingFiles: _missingFiles,
        backupItems: backupItems ?? _lastBackupItems,
      ),
    );
  }

  void _logLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _log.add(trimmed);
    if (_log.length > 200) {
      _log.removeRange(0, _log.length - 200);
    }
  }
}

List<MessagePart> _normalizeAttachmentPartUris(List<MessagePart> parts) {
  var changed = false;
  final out = <MessagePart>[];
  for (final part in parts) {
    if (part is ImagePart) {
      final uri = SandboxPathResolver.canonicalize(part.uri);
      if (uri != part.uri) {
        changed = true;
        out.add(
          ImagePart(
            uri: uri,
            mime: part.mime,
            assetId: part.assetId,
            unavailable: part.unavailable,
          ),
        );
      } else {
        out.add(part);
      }
    } else if (part is FilePart) {
      final uri = SandboxPathResolver.canonicalize(part.uri);
      if (uri != part.uri) {
        changed = true;
        out.add(
          FilePart(
            uri: uri,
            name: part.name,
            mime: part.mime,
            assetId: part.assetId,
            unavailable: part.unavailable,
          ),
        );
      } else {
        out.add(part);
      }
    } else {
      out.add(part);
    }
  }
  return changed ? out : parts;
}

class _MigrationRepairStats {
  int danglingMessageRefs = 0;
  int duplicateMessageIds = 0;
  int conversationIdMismatches = 0;
  int versionConflicts = 0;
  int decodeFailures = 0;
  int dirtyNumericFields = 0;
  int undecodableConversations = 0;

  bool get hasIssues =>
      danglingMessageRefs > 0 ||
      duplicateMessageIds > 0 ||
      conversationIdMismatches > 0 ||
      versionConflicts > 0 ||
      decodeFailures > 0 ||
      dirtyNumericFields > 0 ||
      undecodableConversations > 0;

  String describe() {
    return 'dangling=$danglingMessageRefs duplicates=$duplicateMessageIds '
        'conversationIdMismatches=$conversationIdMismatches '
        'versionConflicts=$versionConflicts '
        'decodeFailures=$decodeFailures '
        'dirtyNumericFields=$dirtyNumericFields '
        'undecodableConversations=$undecodableConversations';
  }
}

class _MigrationBackupManifest {
  const _MigrationBackupManifest({
    required this.entries,
    required this.items,
    required this.totalBytes,
  });

  final List<_MigrationBackupFileEntry> entries;
  final List<HiveToSqliteBackupItem> items;
  final int totalBytes;
}

class _MigrationBackupFile {
  const _MigrationBackupFile({
    required this.file,
    required this.entryName,
    required this.itemName,
    required this.bytes,
  });

  final File file;
  final String entryName;
  final String itemName;
  final int bytes;
}

class _MigrationBackupFileEntry {
  const _MigrationBackupFileEntry({
    required this.file,
    required this.entryName,
    required this.itemName,
    required this.bytes,
    required this.itemBytes,
    required this.itemStartBytes,
  });

  final File file;
  final String entryName;
  final String itemName;
  final int bytes;
  final int itemBytes;
  final int itemStartBytes;
}

class _MigrationZipWriter {
  _MigrationZipWriter(this._output);

  static const int _localFileHeaderSignature = 0x04034b50;
  static const int _centralDirectoryHeaderSignature = 0x02014b50;
  static const int _endOfCentralDirectorySignature = 0x06054b50;
  static const int _dataDescriptorSignature = 0x08074b50;
  static const int _versionNeeded = 20;
  static const int _utf8Flag = 1 << 11;
  static const int _dataDescriptorFlag = 1 << 3;
  static const int _deflateMethod = 8;
  static const int _maxZip32 = 0xffffffff;
  static const int _maxZipEntries = 0xffff;
  static const int _chunkSize = 1024 * 1024;

  final _MigrationZipOutput _output;
  final List<_MigrationZipEntry> _entries = <_MigrationZipEntry>[];
  bool _closed = false;

  Future<int> addFile(
    File file,
    String entryName, {
    required void Function(int writtenBytes) onProgress,
  }) async {
    if (_closed) {
      throw StateError('Cannot add files after the ZIP writer is closed.');
    }
    if (entryName.isEmpty) return 0;

    final stat = await file.stat();
    final modified = stat.modified;
    final modTime = _zipTime(modified);
    final modDate = _zipDate(modified);
    final nameBytes = utf8.encode(entryName.replaceAll('\\', '/'));
    final localHeaderOffset = _output.length;

    _writeLocalHeader(nameBytes: nameBytes, modTime: modTime, modDate: modDate);

    final written = await _writeDeflatedFile(file, onProgress: onProgress);
    _checkZip32(written.compressedSize, 'compressed size');
    _checkZip32(written.uncompressedSize, 'uncompressed size');

    _writeDataDescriptor(written);
    if (_output.shouldFlush) await _output.flush();

    _entries.add(
      _MigrationZipEntry(
        nameBytes: nameBytes,
        modTime: modTime,
        modDate: modDate,
        crc32: written.crc32,
        compressedSize: written.compressedSize,
        uncompressedSize: written.uncompressedSize,
        localHeaderOffset: localHeaderOffset,
        mode: stat.mode,
      ),
    );
    return written.uncompressedSize;
  }

  Future<void> close() async {
    if (_closed) return;
    _checkEntryCount();

    final centralDirectoryOffset = _output.length;
    _checkZip32(centralDirectoryOffset, 'central directory offset');
    for (final entry in _entries) {
      _writeCentralDirectoryHeader(entry);
    }
    final centralDirectorySize = _output.length - centralDirectoryOffset;
    _checkZip32(centralDirectorySize, 'central directory size');

    _writeEndOfCentralDirectory(
      centralDirectoryOffset: centralDirectoryOffset,
      centralDirectorySize: centralDirectorySize,
    );
    await _output.close();
    _closed = true;
  }

  Future<void> closeIfNeeded() async {
    if (!_closed) {
      await _output.close(discardPending: true);
      _closed = true;
    }
  }

  void _writeLocalHeader({
    required List<int> nameBytes,
    required int modTime,
    required int modDate,
  }) {
    _output.writeUint32(_localFileHeaderSignature);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_utf8Flag | _dataDescriptorFlag);
    _output.writeUint16(_deflateMethod);
    _output.writeUint16(modTime);
    _output.writeUint16(modDate);
    _output.writeUint32(0);
    _output.writeUint32(0);
    _output.writeUint32(0);
    _output.writeUint16(nameBytes.length);
    _output.writeUint16(0);
    _output.writeBytes(nameBytes);
  }

  Future<_MigrationZipWrittenFile> _writeDeflatedFile(
    File file, {
    required void Function(int writtenBytes) onProgress,
  }) async {
    var crc32 = 0;
    var compressedSize = 0;
    var uncompressedSize = 0;

    Stream<List<int>> sourceChunks() async* {
      final raf = await file.open();
      try {
        while (true) {
          final chunk = await raf.read(_chunkSize);
          if (chunk.isEmpty) break;
          crc32 = getCrc32(chunk, crc32);
          uncompressedSize += chunk.length;
          onProgress(uncompressedSize);
          yield chunk;
        }
      } finally {
        await raf.close();
      }
    }

    final compressed = sourceChunks().transform(
      ZLibCodec(level: 1, raw: true).encoder,
    );
    await for (final chunk in compressed) {
      if (chunk.isNotEmpty) {
        compressedSize += chunk.length;
        _output.writeBytes(chunk);
        if (_output.shouldFlush) await _output.flush();
      }
    }

    return _MigrationZipWrittenFile(
      crc32: crc32,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
    );
  }

  void _writeDataDescriptor(_MigrationZipWrittenFile written) {
    _output.writeUint32(_dataDescriptorSignature);
    _output.writeUint32(written.crc32);
    _output.writeUint32(written.compressedSize);
    _output.writeUint32(written.uncompressedSize);
  }

  void _writeCentralDirectoryHeader(_MigrationZipEntry entry) {
    _output.writeUint32(_centralDirectoryHeaderSignature);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_utf8Flag | _dataDescriptorFlag);
    _output.writeUint16(_deflateMethod);
    _output.writeUint16(entry.modTime);
    _output.writeUint16(entry.modDate);
    _output.writeUint32(entry.crc32);
    _output.writeUint32(entry.compressedSize);
    _output.writeUint32(entry.uncompressedSize);
    _output.writeUint16(entry.nameBytes.length);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint32(entry.mode << 16);
    _output.writeUint32(entry.localHeaderOffset);
    _output.writeBytes(entry.nameBytes);
  }

  void _writeEndOfCentralDirectory({
    required int centralDirectoryOffset,
    required int centralDirectorySize,
  }) {
    _output.writeUint32(_endOfCentralDirectorySignature);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint16(_entries.length);
    _output.writeUint16(_entries.length);
    _output.writeUint32(centralDirectorySize);
    _output.writeUint32(centralDirectoryOffset);
    _output.writeUint16(0);
  }

  static int _zipTime(DateTime value) {
    return ((value.hour & 0x1f) << 11) |
        ((value.minute & 0x3f) << 5) |
        ((value.second ~/ 2) & 0x1f);
  }

  static int _zipDate(DateTime value) {
    final year = value.year < 1980 ? 1980 : value.year;
    return (((year - 1980) & 0x7f) << 9) |
        ((value.month & 0x0f) << 5) |
        (value.day & 0x1f);
  }

  static void _checkZip32(int value, String field) {
    if (value > _maxZip32) {
      throw FileSystemException('ZIP entry exceeds ZIP32 limit: $field');
    }
  }

  void _checkEntryCount() {
    if (_entries.length > _maxZipEntries) {
      throw FileSystemException('ZIP entry count exceeds ZIP32 limit');
    }
  }
}

/// 缓冲顺序输出，每达到 1 MiB 才等待平台 sink，保持大文件回压。
class _MigrationZipOutput {
  _MigrationZipOutput.toSink(this._writeChunk) : _closeSink = null;

  _MigrationZipOutput._(this._writeChunk, this._closeSink);

  static Future<_MigrationZipOutput> openFile(String path) async {
    final file = await File(path).open(mode: FileMode.write);
    return _MigrationZipOutput._(
      (bytes) async {
        await file.writeFrom(bytes);
      },
      () async {
        await file.close();
      },
    );
  }

  static const _flushThreshold = 1024 * 1024;

  final MigrationBackupChunkWriter _writeChunk;
  final Future<void> Function()? _closeSink;
  final BytesBuilder _pending = BytesBuilder(copy: true);
  var length = 0;
  var _closed = false;

  bool get shouldFlush => _pending.length >= _flushThreshold;

  void writeByte(int value) {
    _pending.addByte(value);
    length++;
  }

  void writeBytes(List<int> bytes) {
    if (bytes.isEmpty) return;
    _pending.add(bytes);
    length += bytes.length;
  }

  void writeUint16(int value) {
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  void writeUint32(int value) {
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
  }

  Future<void> flush() async {
    if (_pending.isEmpty) return;
    await _writeChunk(_pending.takeBytes());
  }

  Future<void> close({bool discardPending = false}) async {
    if (_closed) return;
    _closed = true;
    Object? firstError;
    StackTrace? firstStack;
    try {
      if (discardPending) {
        _pending.clear();
      } else {
        await flush();
      }
    } catch (error, stackTrace) {
      firstError = error;
      firstStack = stackTrace;
    }
    try {
      await _closeSink?.call();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStack ??= stackTrace;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }
}

class _MigrationZipEntry {
  const _MigrationZipEntry({
    required this.nameBytes,
    required this.modTime,
    required this.modDate,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.mode,
  });

  final List<int> nameBytes;
  final int modTime;
  final int modDate;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final int mode;
}

class _MigrationZipWrittenFile {
  const _MigrationZipWrittenFile({
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
  });

  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
}
