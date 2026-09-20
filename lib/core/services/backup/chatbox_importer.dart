import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../database/business_data.dart';
import '../../database/business_repository.dart';
import '../../database/business_settings_router.dart';
import '../../database/chat_database_repository.dart'
    show ParsedChatImportBatch;
import '../../../utils/app_directories.dart';
import '../../models/backup.dart';
import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../models/conversation_tree.dart';
import '../../models/message_part.dart';
import 'backup_cancel_token.dart';
import 'chatbox_shared_parser.dart';
import 'chatbox_backup_archive.dart';
import 'data_sync.dart';
import 'backup_task_progress.dart';
import '../../models/progress_update.dart';
import '../../providers/settings_provider.dart'
    show ProviderConfig, ProviderKind;
import '../chat/chat_service.dart';
import 'backup_isolate_runner.dart';

class ChatboxImportException implements Exception {
  final String message;
  const ChatboxImportException(this.message);
  @override
  String toString() => message;
}

class ChatboxImportResult {
  final int providers;
  final int assistants;
  final int conversations;
  final int messages;
  const ChatboxImportResult({
    required this.providers,
    required this.assistants,
    required this.conversations,
    required this.messages,
  });
}

@pragma('vm:entry-point')
Future<Object?> _readChatboxFileWorker(
  BackupIsolateContext context,
  String path,
) async {
  context.throwIfCancelled();
  final file = File(path);
  if (!await file.exists()) {
    throw StateError('chatbox_file_not_found');
  }

  late final String text;
  try {
    text = await file.readAsString();
  } catch (error) {
    throw StateError('chatbox_read_failed:$error');
  }
  context.throwIfCancelled();

  try {
    return jsonDecode(text);
  } on FormatException {
    throw StateError('chatbox_invalid_json');
  }
}

class ChatboxImporter {
  ChatboxImporter._();

  // 业务设置路由使用的已发布备份键。
  static const String _providersKey = 'provider_configs_v1';
  static const String _providersOrderKey = 'providers_order_v1';
  static const String _assistantsKey = 'assistants_v1';
  // Historical settings key retained for backup compatibility.
  static const String _groupsKey = 'assistant_tags_v1';
  static const String _assignKey =
      'assistant_tag_map_v1'; // assistantId -> groupId
  static const String _collapsedKey =
      'assistant_tag_collapsed_v1'; // groupId -> bool
  static const String _providerGroupsKey = 'provider_groups_v1';
  static const String _providerGroupMapKey = 'provider_group_map_v1';
  static const String _providerGroupCollapsedKey =
      'provider_group_collapsed_v1';
  static const String _providerUngroupedPositionKey =
      'provider_ungrouped_position_v1';

  /// 条目级稳定 ID 前缀由 ChatboxSharedParser 提供，
  /// 这里只管分组的 ID 空间：两代导入的产物必须落在
  /// 各自的分组里，不得混同。
  static const String _legacyIdPrefix = 'chatbox_legacy_1_21_1_';
  static const String _archiveIdPrefix = 'chatbox_archive_1_22_';
  static const String _chatboxImportGroupName = 'Chatbox 导入（<1.22）';
  static const String _chatboxStarredGroupName = 'Chatbox 导入（<1.22）·置顶';
  static const String _chatboxDeletedProviderGroupName =
      'Chatbox 导入（<1.22）·已删除';
  static const String _chatboxModernGroupName = 'Chatbox 导入（≥1.22）';
  static const String _chatboxModernStarredGroupName = 'Chatbox 导入（≥1.22）·置顶';
  static const String _chatboxModernDeletedProviderGroupName =
      'Chatbox 导入（≥1.22）·已删除';

  static Future<ChatboxImportResult> importFromChatbox({
    required File file,
    required RestoreMode mode,
    required BusinessRepository businessRepository,
    required ChatService chatService,
    String? starredGroupName,
    BackupCancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.preparing, value: 0),
    );
    final root = await _readChatboxBackupFile(
      file,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    return _importParsedRoot(
      root: root,
      mode: mode,
      businessRepository: businessRepository,
      chatService: chatService,
      starredGroupName: starredGroupName ?? _chatboxStarredGroupName,
      groupIdPrefix: _legacyIdPrefix,
      regularGroupName: _chatboxImportGroupName,
      deletedProviderGroupName: _chatboxDeletedProviderGroupName,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  /// Chatbox 1.22+ ZIP（`format=chatbox-backup` / `formatVersion=2`）。
  ///
  /// 归档读取与校验由 [ChatboxBackupArchive] 负责：清单、逐条目大小与
  /// SHA-256、解压预算、防目录穿越。它输出的 root 与旧版 JSON 同形状，
  /// 因此会话、消息与分叉树复用本导入器既有的解析管线。
  static Future<ChatboxImportResult> importFromChatboxArchive({
    required File file,
    required RestoreMode mode,
    required BusinessRepository businessRepository,
    required ChatService chatService,
    String? starredGroupName,
    String? regularGroupName,
    String? deletedProviderGroupName,
    BackupCancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.preparing, value: 0),
    );

    final staging = await Directory.systemTemp.createTemp(
      'joaiclient_chatbox_zip_',
    );
    DataSync.registerLiveTempPath(staging.path);
    final upload = await AppDirectories.getUploadDirectory();
    final resourceDestDir = '${upload.path}/chatbox';

    ChatboxBackupReadResult? archive;
    Object? failure;
    try {
      cancelToken?.throwIfCancelled();
      onProgress?.call(
        const ProgressUpdate(phase: BackupPhase.extracting, value: 0.15),
      );
      archive = await ChatboxBackupArchive.readZipV2(
        file: file,
        stagingDir: staging,
        resourceDestDir: resourceDestDir,
      );
      cancelToken?.throwIfCancelled();

      final result = await _importParsedRoot(
        root: _validateArchiveRoot(archive.root),
        mode: mode,
        businessRepository: businessRepository,
        chatService: chatService,
        starredGroupName: starredGroupName ?? _chatboxModernStarredGroupName,
        groupIdPrefix: _archiveIdPrefix,
        regularGroupName: regularGroupName ?? _chatboxModernGroupName,
        deletedProviderGroupName:
            deletedProviderGroupName ?? _chatboxModernDeletedProviderGroupName,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );

      // 提交阶段会先回填一次资产引用、随后清空 upload/。因此资源必须在
      // 提交成功之后再落盘，并重跑一次维护，让刚导入的附件登记进
      // message_asset_rows；否则它们会被当成无主文件，在后续清理中被删掉。
      await ChatboxBackupArchive.publishStagedResources(archive);
      await chatService.runAssetReferenceMaintenance();
      return result;
    } catch (error) {
      failure = error;
      rethrow;
    } finally {
      await DataSync.deleteTempDirectoryWhenIsolateSafe(
        staging,
        error: failure,
      );
    }
  }

  static Map<String, dynamic> _validateArchiveRoot(Map<String, dynamic> root) {
    final sessions = root['chat-sessions-list'];
    final settings = root['settings'];
    final hasProviders = settings is Map && settings['providers'] is Map;
    if (sessions is! List && !hasProviders) {
      throw const ChatboxImportException(
        'Not a Chatbox backup archive (missing sessions and settings.providers).',
      );
    }
    return root;
  }

  /// 把已解析的 Chatbox root 走完导入管线。两代共用。
  static Future<ChatboxImportResult> _importParsedRoot({
    required Map<String, dynamic> root,
    required RestoreMode mode,
    required BusinessRepository businessRepository,
    required ChatService chatService,
    required String starredGroupName,
    required String groupIdPrefix,
    required String regularGroupName,
    required String deletedProviderGroupName,
    BackupCancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    cancelToken?.throwIfCancelled();
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.extracting, value: 0.2),
    );

    if (mode == RestoreMode.overwrite) {
      final sessionsList = root['chat-sessions-list'];
      if (sessionsList is! List || sessionsList.isEmpty) {
        throw const ChatboxImportException(
          'This Chatbox export does not include chat history. Re-export with "Chat History" enabled, or use merge mode.',
        );
      }
      bool hasAnySessionObject = false;
      for (final meta in sessionsList) {
        if (meta is! Map) continue;
        final id = (meta['id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        if (root['session:$id'] is Map) {
          hasAnySessionObject = true;
          break;
        }
      }
      if (!hasAnySessionObject) {
        throw const ChatboxImportException(
          'This Chatbox export is missing session data (no "session:*" entries). Please export again and include chat history.',
        );
      }
    }

    final providerPlan = _parseProviders(root);
    final assistantConvRes = await _parseAssistantsAndConversations(
      root,
      mode,
      chatService,
      providerIdMap: providerPlan.idMap,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    cancelToken?.throwIfCancelled();
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.restoring, value: 0.85),
    );
    final existingBeforeImport = {
      for (final conversation in chatService.getAllCompleteConversations())
        conversation.id: conversation,
    };
    final existingMessageIdsBefore = <String, Set<String>>{};
    if (mode == RestoreMode.merge) {
      for (final conversation in existingBeforeImport.values) {
        existingMessageIdsBefore[conversation.id] =
            (await chatService.loadAllConversationMessages(
              conversation.id,
            )).map((message) => message.id).toSet();
      }
    }
    final preparedBatches = await _prepareConversationBatches(
      chatService,
      assistantConvRes.conversationBatches,
      mode: mode,
    );
    await chatService.commitScopedParsedImport(
      businessRepository: businessRepository,
      replaceExisting: mode == RestoreMode.overwrite,
      conversationBatches: preparedBatches,
      transformBusiness: (current) => _transformBusinessData(
        current: current,
        mode: mode,
        scopedOverwrite: mode == RestoreMode.overwrite,
        providers: providerPlan.configs,
        deletedProviderIds: providerPlan.deletedProviderIds,
        assistants: assistantConvRes.assistantPayloads,
        assistantIds: assistantConvRes.assistantIds,
        starredAssistantIds: assistantConvRes.starredAssistantIds,
        starredGroupName: starredGroupName,
        groupIdPrefix: groupIdPrefix,
        regularGroupName: regularGroupName,
        deletedProviderGroupName: deletedProviderGroupName,
      ),
    );
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.finalizing, value: 1),
    );

    var admittedConversations = 0;
    var admittedMessages = 0;
    for (final batch in preparedBatches) {
      final old = existingBeforeImport[batch.conversation.id];
      final oldIds =
          existingMessageIdsBefore[batch.conversation.id] ?? const <String>{};
      final added = old == null
          ? batch.messages.length
          : batch.messages
                .where((message) => !oldIds.contains(message.id))
                .length;
      if (old == null || mode == RestoreMode.overwrite || added > 0) {
        admittedConversations++;
        admittedMessages += mode == RestoreMode.merge && old != null
            ? added
            : batch.messages.length;
      }
    }
    return ChatboxImportResult(
      providers: providerPlan.configs.length,
      assistants: assistantConvRes.assistants,
      conversations: admittedConversations,
      messages: admittedMessages,
    );
  }

  static Future<List<ParsedChatImportBatch>> _prepareConversationBatches(
    ChatService chatService,
    List<ParsedChatImportBatch> imported, {
    required RestoreMode mode,
  }) async {
    final existing = {
      for (final conversation in chatService.getAllCompleteConversations())
        conversation.id: conversation,
    };
    final result = <ParsedChatImportBatch>[];
    for (final batch in imported) {
      final current = existing[batch.conversation.id];
      if (current == null) {
        result.add(batch);
        continue;
      }
      if (mode == RestoreMode.merge) {
        final localMessages = await chatService.loadAllConversationMessages(
          current.id,
        );
        final localById = <String, ChatMessage>{
          for (final message in localMessages) message.id: message,
        };
        final merged = await _mergeConversationBatch(
          chatService,
          current,
          batch,
        );
        final unchanged =
            merged.messages.length == localMessages.length &&
            merged.messages.every((message) {
              final local = localById[message.id];
              return local != null &&
                  local.semanticContentHash == message.semanticContentHash;
            });
        if (!unchanged) result.add(merged);
        continue;
      }

      // 完全覆盖只覆盖正确助手位置；错误位置保留原会话并写入稳定副本。
      if (current.assistantId == batch.conversation.assistantId) {
        result.add(batch);
      } else {
        final placedId = '${batch.conversation.id}_placed';
        result.add(_remapImportedTreeStable(batch, placedId));
        final placed = existing[placedId];
        if (placed != null) {
          result[result.length - 1] = await _mergeConversationBatch(
            chatService,
            placed,
            result.last,
          );
        }
      }
    }
    return result;
  }

  static ParsedChatImportBatch _remapImportedTreeStable(
    ParsedChatImportBatch batch,
    String targetConversationId,
  ) {
    final messageMap = <String, String>{
      for (final message in batch.messages)
        message.id: ChatboxSharedParser.legacyId(
          'placed_${batch.conversation.id}_${message.id}',
        ),
    };
    final branchMap = <String, String>{
      for (final branch
          in batch.tree?.branches.values ?? const <ConversationBranch>[])
        branch.id: ChatboxSharedParser.legacyId(
          'placed_branch_${batch.conversation.id}_${branch.id}',
        ),
    };
    final messages = [
      for (final message in batch.messages)
        message.copyWith(
          id: messageMap[message.id],
          conversationId: targetConversationId,
        ),
    ];
    final sourceTree = batch.tree;
    final tree = sourceTree == null
        ? null
        : ConversationTree(
            conversationId: targetConversationId,
            activeBranchId: branchMap[sourceTree.activeBranchId]!,
            branches: {
              for (final branch in sourceTree.branches.values)
                branchMap[branch.id]!: ConversationBranch(
                  id: branchMap[branch.id]!,
                  conversationId: targetConversationId,
                  tipMessageId: branch.tipMessageId == null
                      ? null
                      : messageMap[branch.tipMessageId],
                  name: branch.name,
                  createdAt: branch.createdAt,
                ),
            },
            edges: {
              for (final edge in sourceTree.edges.values)
                messageMap[edge.messageId]!: MessageTreeEdge(
                  messageId: messageMap[edge.messageId]!,
                  parentMessageId: edge.parentMessageId == null
                      ? null
                      : messageMap[edge.parentMessageId],
                ),
            },
            branchSelections: {
              for (final entry in sourceTree.branchSelections.entries)
                if (messageMap[entry.key] != null &&
                    branchMap[entry.value] != null)
                  messageMap[entry.key]!: branchMap[entry.value]!,
            },
          );
    return (
      conversation: batch.conversation.copyWith(
        id: targetConversationId,
        assistantId: batch.conversation.assistantId,
        messageIds: messages.map((message) => message.id).toList(),
      ),
      messages: messages,
      tree: tree,
    );
  }

  static Future<ParsedChatImportBatch> _mergeConversationBatch(
    ChatService chatService,
    Conversation current,
    ParsedChatImportBatch incoming,
  ) async {
    final localMessages = await chatService.loadAllConversationMessages(
      current.id,
    );
    final localById = <String, ChatMessage>{
      for (final message in localMessages) message.id: message,
    };
    final incomingById = <String, ChatMessage>{
      for (final message in incoming.messages) message.id: message,
    };
    final idMap = <String, String>{};
    final mergedMessages = List<ChatMessage>.of(localMessages);
    final occupiedGroupVersions = <({String groupId, int version})>{
      for (final message in localMessages)
        (groupId: message.groupId ?? message.id, version: message.version),
    };
    for (final message in incoming.messages) {
      final local = localById[message.id];
      if (local == null) {
        idMap[message.id] = message.id;
        var nextMessage = message;
        final groupId = message.groupId ?? message.id;
        final groupVersion = (groupId: groupId, version: message.version);
        if (occupiedGroupVersions.contains(groupVersion)) {
          nextMessage = message.copyWith(
            groupId: ChatboxSharedParser.legacyId(
              'merge_${current.id}_${message.id}',
            ),
            version: 0,
          );
        }
        mergedMessages.add(nextMessage);
        occupiedGroupVersions.add((
          groupId: nextMessage.groupId ?? nextMessage.id,
          version: nextMessage.version,
        ));
      } else if (local.semanticContentHash == message.semanticContentHash &&
          local.role == message.role) {
        idMap[message.id] = message.id;
      } else {
        final conflictId = _stableUniqueMessageId(
          ChatboxSharedParser.legacyId('conflict_${current.id}_${message.id}'),
          {...localById, ...incomingById},
        );
        idMap[message.id] = conflictId;
        mergedMessages.add(
          message.copyWith(
            id: conflictId,
            groupId: ChatboxSharedParser.legacyId(
              'merge_${current.id}_${message.id}',
            ),
            version: 0,
          ),
        );
        occupiedGroupVersions.add((
          groupId: ChatboxSharedParser.legacyId(
            'merge_${current.id}_${message.id}',
          ),
          version: 0,
        ));
      }
    }

    final localTree =
        await chatService.loadConversationTree(current.id) ??
        ConversationTree.linear(
          conversationId: current.id,
          messageIds: localMessages.map((message) => message.id).toList(),
        );
    final incomingTree =
        incoming.tree ??
        ConversationTree.linear(
          conversationId: current.id,
          messageIds: incoming.messages.map((message) => message.id).toList(),
        );
    final edges = Map<String, MessageTreeEdge>.from(localTree.edges);
    final branches = Map<String, ConversationBranch>.from(localTree.branches);
    final selections = Map<String, String>.from(localTree.branchSelections);
    final branchMap = <String, String>{};
    for (final branch in incomingTree.branches.values) {
      if (branches.containsKey(branch.id)) {
        branchMap[branch.id] = branch.id;
      } else {
        final branchId = _stableUniqueBranchId(branch.id, branches);
        branchMap[branch.id] = branchId;
        branches[branchId] = branch.copyWith(
          id: branchId,
          conversationId: current.id,
          tipMessageId: branch.tipMessageId == null
              ? null
              : idMap[branch.tipMessageId],
        );
      }
    }
    final incomingByMappedId = <String, ChatMessage>{
      for (final message in incoming.messages)
        idMap[message.id]!: message.copyWith(id: idMap[message.id]),
    };
    for (final edge in incomingTree.edges.values) {
      var mappedId = idMap[edge.messageId];
      if (mappedId == null) continue;
      var parentId = edge.parentMessageId == null
          ? null
          : idMap[edge.parentMessageId];
      if (parentId == null && edge.parentMessageId != null) {
        parentId = _nearestMessageBefore(
          mergedMessages,
          incomingByMappedId[mappedId]?.timestamp,
        );
      }
      final existingEdge = edges[mappedId];
      if (existingEdge != null && existingEdge.parentMessageId != parentId) {
        final sourceMessage = incomingById[edge.messageId];
        if (sourceMessage != null && mappedId == edge.messageId) {
          mappedId = _stableUniqueMessageId(
            ChatboxSharedParser.legacyId(
              'placement_${current.id}_${edge.messageId}',
            ),
            {...localById, ...incomingByMappedId},
          );
          idMap[edge.messageId] = mappedId;
          mergedMessages.add(sourceMessage.copyWith(id: mappedId));
        }
      }
      if (existingEdge == null || !edges.containsKey(mappedId)) {
        edges[mappedId] = MessageTreeEdge(
          messageId: mappedId,
          parentMessageId: parentId,
        );
      }
    }
    for (final branch in incomingTree.branches.values) {
      final mappedBranchId = branchMap[branch.id];
      if (mappedBranchId == null) continue;
      final mappedTip = branch.tipMessageId == null
          ? null
          : idMap[branch.tipMessageId];
      final existing = branches[mappedBranchId];
      if (existing != null &&
          existing.tipMessageId == null &&
          mappedTip != null) {
        branches[mappedBranchId] = existing.copyWith(tipMessageId: mappedTip);
      }
    }
    for (final entry in incomingTree.branchSelections.entries) {
      final messageId = idMap[entry.key];
      final branchId = branchMap[entry.value];
      if (messageId != null && branchId != null) {
        selections[messageId] = branchId;
      }
    }
    final mergedMessageIds = mergedMessages
        .map((message) => message.id)
        .toSet();
    if (!edges.keys.every(mergedMessageIds.contains)) {
      throw StateError('chatbox_merge_tree_message_missing');
    }
    final mergedTree = ConversationTree(
      conversationId: current.id,
      activeBranchId: localTree.activeBranchId,
      branches: branches,
      edges: edges,
      branchSelections: selections,
    );
    final updatedAt = mergedMessages
        .map((message) => message.timestamp)
        .fold<DateTime>(
          current.updatedAt,
          (latest, value) => value.isAfter(latest) ? value : latest,
        );
    return (
      conversation: current.copyWith(
        updatedAt: updatedAt,
        messageIds: mergedMessages.map((message) => message.id).toList(),
      ),
      messages: mergedMessages,
      tree: mergedTree,
    );
  }

  static String _stableUniqueMessageId(
    String candidate,
    Map<String, ChatMessage> occupied,
  ) {
    if (!occupied.containsKey(candidate)) return candidate;
    var index = 2;
    while (occupied.containsKey('${candidate}_$index')) {
      index++;
    }
    return '${candidate}_$index';
  }

  static String _stableUniqueBranchId(
    String candidate,
    Map<String, ConversationBranch> occupied,
  ) {
    if (!occupied.containsKey(candidate)) return candidate;
    var index = 2;
    while (occupied.containsKey('${candidate}_$index')) {
      index++;
    }
    return '${candidate}_$index';
  }

  static String? _nearestMessageBefore(
    List<ChatMessage> messages,
    DateTime? timestamp,
  ) {
    if (messages.isEmpty) return null;
    final sorted = List<ChatMessage>.of(messages)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (timestamp == null) return sorted.last.id;
    final candidates = sorted.where(
      (message) => !message.timestamp.isAfter(timestamp),
    );
    return candidates.isEmpty ? sorted.first.id : candidates.last.id;
  }

  // ---------- 解析 ----------

  static Future<Map<String, dynamic>> _readChatboxBackupFile(
    File file, {
    BackupCancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    late final Object? decoded;
    try {
      decoded = await runBackupIsolate<Object?, String>(
        body: _readChatboxFileWorker,
        payload: file.path,
        cancelToken: cancelToken,
        onProgress: adaptProgressCallbackToSink(onProgress),
      );
    } on StateError catch (error) {
      switch (error.message) {
        case 'chatbox_file_not_found':
          throw const ChatboxImportException('Chatbox backup file not found.');
        case 'chatbox_invalid_json':
          throw const ChatboxImportException(
            'Invalid JSON: unable to parse Chatbox backup file.',
          );
        default:
          if (error.message.startsWith('chatbox_read_failed:')) {
            throw ChatboxImportException(
              'Unable to read Chatbox backup file: '
              '${error.message.substring('chatbox_read_failed:'.length)}',
            );
          }
          rethrow;
      }
    }
    cancelToken?.throwIfCancelled();
    if (decoded is! Map) {
      throw const ChatboxImportException(
        'Unsupported data format: expected a JSON object.',
      );
    }

    final root = decoded.map((k, v) => MapEntry(k.toString(), v));

    // 最基本的结构校验：导出数据通常至少包含其中之一。
    final hasSessions = root['chat-sessions-list'] is List;
    final settings = root['settings'];
    final hasProviders = settings is Map && (settings['providers'] is Map);
    if (!hasSessions && !hasProviders) {
      throw const ChatboxImportException(
        'Not a Chatbox export file (missing "chat-sessions-list" and "settings.providers").',
      );
    }

    return root.cast<String, dynamic>();
  }

  // ---------- 供应商 ----------

  static _ChatboxProviderImportPlan _parseProviders(Map<String, dynamic> root) {
    final rawSettings = root['settings'];
    final settings = rawSettings is Map
        ? rawSettings.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};
    final providers = settings['providers'];
    final customProviders = <String, Map<String, dynamic>>{};
    final customProvidersRaw = settings['customProviders'];
    if (customProvidersRaw is List) {
      for (final raw in customProvidersRaw) {
        if (raw is! Map) continue;
        final id = (raw['id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        customProviders[id] = raw
            .map((k, v) => MapEntry(k.toString(), v))
            .cast<String, dynamic>();
      }
    }

    final imported = <String, Map<String, dynamic>>{};
    final sourceIds = <String>{};
    final configuredSourceIds = <String>{};
    final namedConfiguredSourceIds = <String>{};
    if (providers is Map) {
      configuredSourceIds.addAll(
        providers.keys
            .map((key) => key.toString().trim())
            .where((key) => key.isNotEmpty),
      );
      sourceIds.addAll(configuredSourceIds);
    }
    // 历史消息和助手可能仍引用已经从 Chatbox 设置中删除的供应商。
    // 这些引用也必须拥有目标配置行，否则只能在界面上显示裸 provider ID。
    sourceIds.addAll(_collectChatboxProviderReferences(root));
    // chatbox-ai 没有普通 API 配置，但只要存档中实际引用过，就要保留
    // 其供应商身份，避免助手和历史消息断链。
    if (_containsChatboxProviderReference(root, 'chatbox-ai')) {
      sourceIds.add('chatbox-ai');
    }

    final idMap = <String, String>{};
    for (final key in sourceIds) {
      final targetId = ChatboxSharedParser.chatboxImportedProviderId(key);
      idMap[key] = targetId;
    }

    for (final key in sourceIds) {
      if (key.isEmpty) continue;
      if (key == 'chatbox-ai' &&
          !_containsChatboxProviderReference(root, key)) {
        continue;
      }
      final rawCfg = providers is Map ? providers[key] : null;
      final cfg = rawCfg is Map
          ? rawCfg.map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{};
      final customMeta = customProviders[key];

      final apiKey = (cfg['apiKey'] ?? '').toString();
      final apiHost = (cfg['apiHost'] ?? '').toString();
      final apiPath = (cfg['apiPath'] ?? '').toString();
      final endpoint = (cfg['endpoint'] ?? '').toString();

      final kind = _chatboxProviderKind(key, customMeta);
      final normalized = _normalizeHostAndPath(
        providerKey: key,
        kind: kind,
        apiHost: apiHost,
        apiPath: apiPath,
        endpoint: endpoint,
      );
      final models = <String>[];
      final rawModels = cfg['models'];
      if (rawModels is List) {
        for (final m in rawModels) {
          if (m is! Map) continue;
          final mid = (m['modelId'] ?? '').toString().trim();
          if (mid.isNotEmpty) models.add(mid);
        }
      }

      final isChatboxAi = key == 'chatbox-ai';
      final targetId = idMap[key]!;
      final useResponseApi = _chatboxUsesResponseApi(key, customMeta);
      final providerName = _chatboxProviderDisplayName(
        key,
        customMeta,
        configName: (cfg['name'] ?? '').toString().trim(),
      );
      final importedApiKey = isChatboxAi ? '' : apiKey;
      imported[targetId] = <String, dynamic>{
        'id': targetId,
        'enabled': importedApiKey.trim().isNotEmpty,
        'name': providerName,
        'apiKey': importedApiKey,
        'baseUrl': normalized.apiHost.isNotEmpty
            ? normalized.apiHost
            : ProviderConfig.defaultsFor(
                targetId,
                displayName: providerName,
              ).baseUrl,
        'providerType': kind.name,
        'chatPath': kind == ProviderKind.openai ? normalized.apiPath : null,
        'useResponseApi': kind == ProviderKind.openai ? useResponseApi : null,
        'vertexAI': kind == ProviderKind.google ? false : null,
        'location': null,
        'projectId': null,
        'serviceAccountJson': null,
        'models': models,
        'modelOverrides': const <String, dynamic>{},
        'proxyEnabled': false,
        'proxyHost': '',
        'proxyPort': '8080',
        'proxyUsername': '',
        'proxyPassword': '',
        'multiKeyEnabled': false,
        'apiKeys': const <dynamic>[],
        'keyManagement': const <String, dynamic>{},
      };
      if (configuredSourceIds.contains(key) &&
          _chatboxProviderHasDisplayName(key, customMeta, cfg)) {
        namedConfiguredSourceIds.add(key);
      }
    }

    final deletedProviderIds = sourceIds
        .where(
          (sourceId) =>
              sourceId != 'chatbox-ai' &&
              (!configuredSourceIds.contains(sourceId) ||
                  !namedConfiguredSourceIds.contains(sourceId)),
        )
        .map(ChatboxSharedParser.chatboxImportedProviderId)
        .toSet();

    // 归入“已删除”分组的供应商只用于保留历史引用，导入后一律禁用。
    // 旧存档即使残留 apiKey，也不能让这些条目默认处于启用状态。
    for (final providerId in deletedProviderIds) {
      imported[providerId]?['enabled'] = false;
    }

    return _ChatboxProviderImportPlan(
      configs: imported,
      idMap: idMap,
      deletedProviderIds: deletedProviderIds,
    );
  }

  // ---------- 助手与会话 ----------

  static Future<_AssistantsConversationsResult>
  _parseAssistantsAndConversations(
    Map<String, dynamic> root,
    RestoreMode mode,
    ChatService chatService, {
    required Map<String, String> providerIdMap,
    BackupCancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    final sessionsListRaw = root['chat-sessions-list'];
    final sessionsList = sessionsListRaw is List
        ? sessionsListRaw
        : const <dynamic>[];

    // 先收集所有 session id，以便后续打标签。
    final starredAssistants = <Map<String, dynamic>>[];
    final regularAssistants = <Map<String, dynamic>>[];
    final starredAssistantIds = <String>[];
    final regularAssistantIds = <String>[];
    final conversationBatches = <ParsedChatImportBatch>[];
    final messagesToAppend = <String, List<ChatMessage>>{};
    if (!chatService.initialized) await chatService.init();

    int convCount = 0;
    int msgCount = 0;

    // 当消息时间戳缺失时，`__exported_at` 是不错的回退时间戳基准。
    final exportedAt =
        ChatboxSharedParser.parseIsoDateTime(
          (root['__exported_at'] ?? '').toString(),
        ) ??
        DateTime.now();

    for (final (sessionIndex, meta) in sessionsList.indexed) {
      cancelToken?.throwIfCancelled();
      if (meta is! Map) continue;
      final id = (meta['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final name = (meta['name'] ?? id).toString();
      final avatar = (meta['picUrl'] ?? '').toString().trim();
      final starred = meta['starred'] as bool? ?? false;

      final sessionRaw = root['session:$id'];
      final session = sessionRaw is Map
          ? sessionRaw.map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{};
      final sessionSettingsRaw = session['settings'];
      final sessionSettings = sessionSettingsRaw is Map
          ? sessionSettingsRaw.map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{};

      // 推导助手配置字段。
      final provider = (sessionSettings['provider'] ?? '').toString().trim();
      final modelId = (sessionSettings['modelId'] ?? '').toString().trim();
      final temperature = (sessionSettings['temperature'] as num?)?.toDouble();
      final topP = (sessionSettings['topP'] as num?)?.toDouble();
      final maxTokens = (sessionSettings['maxTokens'] as num?)?.toInt();
      final stream = sessionSettings['stream'] as bool?;
      final contextCount = (sessionSettings['maxContextMessageCount'] as num?)
          ?.toInt();

      final thinkingBudget = ChatboxSharedParser.extractThinkingBudget(
        sessionSettings,
      );

      // 将第一条 system 消息作为助手 system prompt。
      final sysPrompt = ChatboxSharedParser.extractSystemPromptFromSession(
        session,
        fallback: ChatboxSharedParser.extractDefaultPrompt(root),
      );

      final assistantId = ChatboxSharedParser.legacyId(id);
      final assistantJson = <String, dynamic>{
        'id': assistantId,
        'name': name,
        'avatar': avatar.isNotEmpty ? avatar : null,
        'useAssistantAvatar': false,
        'useAssistantName': false,
        'chatModelProvider': provider.isEmpty
            ? null
            : providerIdMap[provider] ??
                  ChatboxSharedParser.chatboxImportedProviderId(provider),
        'chatModelId': provider.isEmpty || modelId.isEmpty ? null : modelId,
        'temperature': temperature,
        'topP': topP,
        'contextMessageSize': contextCount ?? 64,
        'limitContextMessages': true,
        'streamOutput': stream ?? true,
        'thinkingBudget': thinkingBudget,
        'maxTokens': maxTokens,
        'systemPrompt': sysPrompt,
        'messageTemplate': '{{ message }}',
        'mcpServerIds': const <String>[],
        'background': null,
        'customHeaders': const <Map<String, String>>[],
        'customBody': const <Map<String, String>>[],
        'enableMemory': false,
        'allowPastConversationRecall': false,
        'presetMessages': const <dynamic>[],
        'regexRules': const <dynamic>[],
      };

      if (starred) {
        starredAssistants.add(assistantJson);
        starredAssistantIds.add(assistantId);
      } else {
        regularAssistants.add(assistantJson);
        regularAssistantIds.add(assistantId);
      }

      // 会话（话题）
      final threadsRaw = session['threads'];
      final threads = threadsRaw is List ? threadsRaw : const <dynamic>[];
      final sessionMessages = (session['messages'] is List)
          ? session['messages'] as List
          : const <dynamic>[];
      List<String> collectIds(dynamic raw) {
        if (raw is! List) return const <String>[];
        final out = <String>[];
        for (final e in raw) {
          if (e is! Map) continue;
          final mid = (e['id'] ?? '').toString().trim();
          if (mid.isNotEmpty) out.add(mid);
        }
        return out;
      }

      final parsedThreads = <Map<String, dynamic>>[
        for (final t in threads)
          if (t is Map)
            t.map((k, v) => MapEntry(k.toString(), v)).cast<String, dynamic>(),
      ];

      final effectiveThreads = <Map<String, dynamic>>[];
      if (parsedThreads.isEmpty) {
        effectiveThreads.add(<String, dynamic>{
          'id': ChatboxSharedParser.legacyId('default_$id'),
          'name': name,
          'createdAt': null,
          'messages': sessionMessages,
        });
      } else {
        effectiveThreads.addAll(parsedThreads);

        // Chatbox 将当前话题消息存于 `session.messages`，历史话题存于 `session.threads`。
        // 两者都导入，但如果当前话题已存在于 threads 中，则避免重复。
        final currentIds = collectIds(sessionMessages);
        if (currentIds.isNotEmpty) {
          final currentSet = currentIds.toSet();
          bool duplicated = false;
          for (final t in parsedThreads) {
            final ids = collectIds(t['messages']);
            if (ids.length != currentIds.length) continue;
            final s = ids.toSet();
            if (s.length == currentSet.length && s.containsAll(currentSet)) {
              duplicated = true;
              break;
            }
          }
          if (!duplicated) {
            final threadName = (session['threadName'] ?? '').toString().trim();
            String systemMessageId(List<dynamic> raw) {
              for (final e in raw) {
                if (e is! Map) continue;
                if ((e['role'] ?? '').toString() != 'system') continue;
                final mid = (e['id'] ?? '').toString().trim();
                if (mid.isNotEmpty) return mid;
              }
              return '';
            }

            final baseId = systemMessageId(sessionMessages);
            final derivedId = baseId.isNotEmpty
                ? ChatboxSharedParser.legacyId('thread_$baseId')
                : ChatboxSharedParser.legacyId('current_$id');
            effectiveThreads.add(<String, dynamic>{
              'id': derivedId,
              'name': threadName.isNotEmpty ? threadName : name,
              'createdAt': null,
              'messages': sessionMessages,
            });
          }
        }
      }

      for (final t in effectiveThreads) {
        cancelToken?.throwIfCancelled();
        final sourceTid = (t['id'] ?? '').toString().trim();
        if (sourceTid.isEmpty) continue;
        final tid = sourceTid.startsWith(_legacyIdPrefix)
            ? sourceTid
            : ChatboxSharedParser.legacyId('thread_$sourceTid');
        final title = ((t['name'] ?? '').toString().trim().isNotEmpty)
            ? (t['name'] ?? '').toString()
            : name;
        final threadMessagesRaw = (t['messages'] is List)
            ? (t['messages'] as List)
            : const <dynamic>[];

        // 转换消息
        final messages = <ChatMessage>[];
        final messageIdMap = <String, String>{};
        bool consumedSystem = false;
        int fallbackIndex = 0;
        for (final rawMsg in threadMessagesRaw) {
          cancelToken?.throwIfCancelled();
          if (rawMsg is! Map) continue;
          final msg = rawMsg.map((k, v) => MapEntry(k.toString(), v));
          final sourceMsgId = (msg['id'] ?? '').toString().trim();
          if (sourceMsgId.isEmpty) continue;
          final msgId = messageIdMap.putIfAbsent(
            sourceMsgId,
            () => ChatboxSharedParser.legacyId(sourceMsgId),
          );
          final roleRaw = (msg['role'] ?? '').toString();
          final parts = ChatboxSharedParser.extractMessageParts(
            msg,
            roleHint: roleRaw,
          );
          final content = ChatboxSharedParser.textFromParts(parts);

          // System 消息：第一条作为助手 prompt，其余转为助手可见备注。
          if (roleRaw == 'system') {
            if (!consumedSystem && content.trim().isNotEmpty) {
              consumedSystem = true;
              continue;
            }
          }

          final role = switch (roleRaw) {
            'user' => 'user',
            'tool' => 'tool',
            _ => 'assistant',
          };

          final ts =
              ChatboxSharedParser.parseMessageTimestamp(msg['timestamp']) ??
              exportedAt.add(Duration(milliseconds: fallbackIndex++));
          final sourceProviderId = (msg['aiProvider'] ?? '').toString().trim();
          final providerId = sourceProviderId.isEmpty
              ? ''
              : providerIdMap[sourceProviderId] ??
                    ChatboxSharedParser.chatboxImportedProviderId(
                      sourceProviderId,
                    );

          if (role == 'tool') {
            // 将 tool-result JSON 保留在 TextPart 中以维持工具语义，但不要
            // 丢弃从 contentParts 中提取的 ImagePart/FilePart 附件。
            final toolPayload = ChatboxSharedParser.buildToolMessagePayload(
              msg,
              fallbackText: content,
            );
            final attachmentParts = parts
                .where((part) => part is ImagePart || part is FilePart)
                .toList(growable: false);
            messages.add(
              ChatMessage(
                id: msgId,
                role: 'tool',
                parts: <MessagePart>[TextPart(toolPayload), ...attachmentParts],
                timestamp: ts,
                modelId:
                    ChatboxSharedParser.inferModelIdFromChatboxMessage(
                      msg,
                    ).trim().isEmpty
                    ? null
                    : ChatboxSharedParser.inferModelIdFromChatboxMessage(msg),
                providerId: sourceProviderId.isEmpty
                    ? null
                    : providerIdMap[sourceProviderId] ??
                          ChatboxSharedParser.chatboxImportedProviderId(
                            sourceProviderId,
                          ),
                totalTokens: null,
                conversationId: tid,
              ),
            );
          } else {
            final inferredModel =
                ChatboxSharedParser.inferModelIdFromChatboxMessage(msg);
            final totalTokens =
                (msg['tokenCount'] as num?)?.toInt() ??
                (msg['tokensUsed'] as num?)?.toInt();
            final messageParts = roleRaw == 'system'
                ? <MessagePart>[
                    TextPart(
                      content.isEmpty ? '[System]' : '[System]\n$content',
                    ),
                    ...parts.where((part) => part is! TextPart),
                  ]
                : parts;
            final reasoningTexts = messageParts
                .whereType<ReasoningPart>()
                .map((part) => part.text)
                .where((text) => text.trim().isNotEmpty)
                .toList(growable: false);
            final reasoningText = reasoningTexts.isEmpty
                ? null
                : reasoningTexts.join('\n');
            messages.add(
              ChatMessage(
                id: msgId,
                role: roleRaw == 'system' ? 'assistant' : role,
                parts: messageParts.isEmpty
                    ? const <MessagePart>[TextPart('')]
                    : messageParts,
                timestamp: ts,
                modelId: inferredModel.isNotEmpty ? inferredModel : null,
                providerId: providerId.isNotEmpty ? providerId : null,
                totalTokens: totalTokens,
                conversationId: tid,
                reasoningText: reasoningText,
              ),
            );
          }
        }

        final materialized = ChatboxSharedParser.materializeForks(
          conversationId: tid,
          rootMessages: messages,
          forkHash: session['messageForksHash'],
          messageIdMap: messageIdMap,
          fallbackTime: exportedAt,
          providerIdMap: providerIdMap,
          cancelToken: cancelToken,
        );
        messages
          ..clear()
          ..addAll(materialized.messages);
        final importedTree = materialized.tree;

        // 确定时间戳
        DateTime createdAt = exportedAt;
        DateTime updatedAt = exportedAt;
        if (messages.isNotEmpty) {
          final times = messages.map((m) => m.timestamp).toList()..sort();
          createdAt = times.first;
          updatedAt = times.last;
        } else {
          // Thread 的 createdAt 可能是数字（毫秒）
          final createdRaw = t['createdAt'];
          final created = ChatboxSharedParser.parseEpochMillis(createdRaw);
          if (created != null) {
            createdAt = created;
            updatedAt = created;
          }
        }

        final conv = Conversation(
          id: tid,
          title: title,
          createdAt: createdAt,
          updatedAt: updatedAt,
          // Chatbox starred is represented by the imported assistant group,
          // not by JO-AIClient conversation pinning.
          isPinned: false,
          assistantId: assistantId,
        );

        conversationBatches.add((
          conversation: conv,
          messages: messages,
          tree: importedTree,
        ));
        convCount += 1;
        msgCount += messages.length;
      }
      onProgress?.call(
        ProgressUpdate(
          phase: BackupPhase.extracting,
          processed: sessionIndex + 1,
          total: sessionsList.length,
        ),
      );
    }

    // Chatbox stores legacy sessions oldest-first. Its visible list keeps
    // starred entries in source order and reverses the remaining entries.
    final importedAssistants = <Map<String, dynamic>>[
      ...starredAssistants,
      ...regularAssistants.reversed,
    ];
    final importedAssistantIds = <String>[
      ...starredAssistantIds,
      ...regularAssistantIds.reversed,
    ];

    return _AssistantsConversationsResult(
      assistants: importedAssistantIds.toSet().length,
      conversations: convCount,
      messages: msgCount,
      assistantIds: importedAssistantIds,
      assistantPayloads: importedAssistants,
      starredAssistantIds: starredAssistantIds,
      conversationBatches: conversationBatches,
      messagesToAppend: messagesToAppend,
    );
  }

  // ---------- 原子业务补丁 ----------

  static BusinessSnapshot _transformBusinessData({
    required BusinessSnapshot current,
    required RestoreMode mode,
    bool scopedOverwrite = false,
    required Map<String, Map<String, dynamic>> providers,
    required Set<String> deletedProviderIds,
    required List<Map<String, dynamic>> assistants,
    required List<String> assistantIds,
    required List<String> starredAssistantIds,
    required String starredGroupName,
    required String groupIdPrefix,
    required String regularGroupName,
    required String deletedProviderGroupName,
  }) {
    final settings = BusinessSettingsRouter.exportSnapshot(current);
    final overwrite = mode == RestoreMode.overwrite && !scopedOverwrite;

    if (overwrite) {
      // 历史上不含 providers 的 Chatbox 导出会保留本地 providers
      // 完整，因此沿用该导入器专属行为。
      if (providers.isNotEmpty) {
        settings[_providersKey] = jsonEncode(providers);
        settings[_providersOrderKey] = providers.keys.toList();
      }
      settings[_assistantsKey] = jsonEncode(assistants);
    } else {
      final currentProviders = _jsonObjectMap(
        settings[_providersKey],
        _providersKey,
      );
      for (final entry in providers.entries) {
        final local = currentProviders[entry.key];
        if (local is! Map) {
          currentProviders[entry.key] = entry.value;
          continue;
        }
        final next = local.map((key, value) => MapEntry(key.toString(), value));
        for (final importedField in entry.value.entries) {
          if (importedField.key == 'name') continue;
          // “已删除”供应商的启停状态只属于本次导入，不得反向覆盖
          // 本地已有条目；本地记录存在时始终保留其 enabled 状态。
          if (importedField.key == 'enabled' &&
              deletedProviderIds.contains(entry.key)) {
            continue;
          }
          final value = importedField.value;
          if (value == null || (value is String && value.trim().isEmpty)) {
            continue;
          }
          next[importedField.key] = value;
        }
        currentProviders[entry.key] = next;
      }
      settings[_providersKey] = jsonEncode(currentProviders);

      final order = List<String>.from(
        (settings[_providersOrderKey] as List).cast<String>(),
      );
      for (final providerId in providers.keys) {
        if (!order.contains(providerId)) order.add(providerId);
      }
      settings[_providersOrderKey] = order;

      final currentAssistants = _jsonObjectList(
        settings[_assistantsKey],
        _assistantsKey,
      );
      final assistantsById = <String, Map<String, dynamic>>{
        for (final assistant in currentAssistants)
          if (assistant['id'] != null) assistant['id'].toString(): assistant,
      };
      for (final assistant in assistants) {
        final id = (assistant['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final local = assistantsById[id];
        if (local == null) {
          assistantsById[id] = assistant;
          continue;
        }
        final prompt = (assistant['systemPrompt'] as String?)?.trim() ?? '';
        if (prompt.isNotEmpty) local['systemPrompt'] = prompt;
        for (final key in const [
          'chatModelProvider',
          'chatModelId',
          'temperature',
          'topP',
          'maxTokens',
          'thinkingBudget',
        ]) {
          final value = assistant[key];
          if (value != null) local[key] = value;
        }
      }
      settings[_assistantsKey] = jsonEncode(assistantsById.values.toList());
    }

    _applyImportedProviderGroups(
      settings: settings,
      mode: mode,
      scopedOverwrite: scopedOverwrite,
      importedProviderIds: providers.keys.toSet(),
      deletedProviderIds: deletedProviderIds,
      groupIdPrefix: groupIdPrefix,
      regularGroupName: regularGroupName,
      deletedProviderGroupName: deletedProviderGroupName,
    );

    if (assistantIds.isNotEmpty) {
      final groups = overwrite
          ? <Map<String, dynamic>>[]
          : _jsonObjectList(settings[_groupsKey], _groupsKey);
      final assignment = overwrite
          ? <String, dynamic>{}
          : _jsonMap(settings[_assignKey], _assignKey);
      final collapsed = overwrite
          ? <String, dynamic>{}
          : _jsonMap(settings[_collapsedKey], _collapsedKey);

      final starredIds = starredAssistantIds.toSet();
      final hasStarred = starredIds.isNotEmpty;
      final hasRegular = assistantIds.any((id) => !starredIds.contains(id));

      String? findGroupId({String? id, required String name}) {
        for (final group in groups) {
          final groupId = (group['id'] ?? '').toString().trim();
          if ((id != null && groupId == id) ||
              (group['name'] ?? '').toString().trim().toLowerCase() ==
                  name.trim().toLowerCase()) {
            if (groupId.isNotEmpty) return groupId;
          }
        }
        return null;
      }

      final starredGroupId = hasStarred
          ? (findGroupId(
                  id: '${groupIdPrefix}starred_',
                  name: starredGroupName,
                ) ??
                '${groupIdPrefix}starred_')
          : null;
      final regularGroupId = hasRegular
          ? (findGroupId(name: regularGroupName) ?? const Uuid().v4())
          : null;

      // Keep local groups and the ungrouped section untouched. Within the
      // imported block, the starred group must precede the regular group.
      final importedGroupIds = <String>[
        if (starredGroupId != null) starredGroupId,
        if (regularGroupId != null) regularGroupId,
      ];
      if (importedGroupIds.isNotEmpty) {
        final existingPositions = <int>[];
        for (var index = 0; index < groups.length; index++) {
          if (importedGroupIds.contains(
            (groups[index]['id'] ?? '').toString(),
          )) {
            existingPositions.add(index);
          }
        }
        final insertionIndex = existingPositions.isEmpty
            ? groups.length
            : existingPositions.reduce((a, b) => a < b ? a : b);
        groups.removeWhere(
          (group) => importedGroupIds.contains((group['id'] ?? '').toString()),
        );
        final importedGroups = <Map<String, dynamic>>[
          if (starredGroupId != null)
            <String, dynamic>{'id': starredGroupId, 'name': starredGroupName},
          if (regularGroupId != null)
            <String, dynamic>{'id': regularGroupId, 'name': regularGroupName},
        ];
        groups.insertAll(
          insertionIndex.clamp(0, groups.length),
          importedGroups,
        );
      }

      final nextAssignment = <String, String>{
        for (final entry in assignment.entries)
          entry.key: entry.value.toString(),
      };
      for (final assistantId in assistantIds) {
        final id = assistantId.trim();
        if (id.isEmpty) continue;
        final targetGroupId = starredIds.contains(id)
            ? starredGroupId
            : regularGroupId;
        if (targetGroupId == null) continue;
        if (overwrite || scopedOverwrite) {
          nextAssignment[id] = targetGroupId;
        } else {
          nextAssignment.putIfAbsent(id, () => targetGroupId);
        }
      }
      final nextCollapsed = <String, bool>{
        for (final entry in collapsed.entries)
          entry.key: entry.value is bool
              ? entry.value as bool
              : entry.value.toString() == 'true',
      };
      for (final groupId in importedGroupIds) {
        nextCollapsed.putIfAbsent(groupId, () => false);
      }

      settings[_groupsKey] = jsonEncode(groups);
      settings[_assignKey] = jsonEncode(nextAssignment);
      settings[_collapsedKey] = jsonEncode(nextCollapsed);
    }

    return BusinessSettingsRouter.normalizeAndRoute(settings);
  }

  static Map<String, dynamic> _jsonObjectMap(Object? raw, String key) {
    final decoded = _jsonMap(raw, key);
    if (decoded.values.any((value) => value is! Map)) {
      throw FormatException(key);
    }
    return decoded;
  }

  static List<Map<String, dynamic>> _jsonObjectList(Object? raw, String key) {
    if (raw is! String) throw FormatException(key);
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.any((value) => value is! Map)) {
      throw FormatException(key);
    }
    return decoded
        .cast<Map>()
        .map(
          (value) => value.map(
            (field, fieldValue) => MapEntry(field.toString(), fieldValue),
          ),
        )
        .toList();
  }

  static Map<String, dynamic> _jsonMap(Object? raw, String key) {
    if (raw == null || raw == '') return <String, dynamic>{};
    if (raw is! String) throw FormatException(key);
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw FormatException(key);
    return decoded.map((field, value) => MapEntry(field.toString(), value));
  }

  static Set<String> _collectChatboxProviderReferences(dynamic value) {
    final result = <String>{};
    void visit(dynamic current) {
      if (current is Map) {
        for (final entry in current.entries) {
          final field = entry.key.toString();
          if (field == 'provider' || field == 'aiProvider') {
            final providerId = entry.value.toString().trim();
            if (providerId.isNotEmpty) result.add(providerId);
          }
          visit(entry.value);
        }
      } else if (current is List) {
        for (final item in current) {
          visit(item);
        }
      }
    }

    visit(value);
    return result;
  }

  static void _applyImportedProviderGroups({
    required Map<String, Object> settings,
    required RestoreMode mode,
    bool scopedOverwrite = false,
    required Set<String> importedProviderIds,
    required Set<String> deletedProviderIds,
    required String groupIdPrefix,
    required String regularGroupName,
    required String deletedProviderGroupName,
  }) {
    if (importedProviderIds.isEmpty) return;

    final overwrite = mode == RestoreMode.overwrite && !scopedOverwrite;
    final groups = overwrite
        ? <Map<String, dynamic>>[]
        : _jsonObjectList(settings[_providerGroupsKey], _providerGroupsKey);
    final assignment = overwrite
        ? <String, dynamic>{}
        : _jsonMap(settings[_providerGroupMapKey], _providerGroupMapKey);
    final collapsed = overwrite
        ? <String, dynamic>{}
        : _jsonMap(
            settings[_providerGroupCollapsedKey],
            _providerGroupCollapsedKey,
          );

    String groupIdFor({required String id, required String name}) {
      for (final group in groups) {
        final existingId = (group['id'] ?? '').toString().trim();
        final existingName = (group['name'] ?? '').toString().trim();
        if (existingId == id ||
            existingName.toLowerCase() == name.trim().toLowerCase()) {
          if (existingId.isNotEmpty) return existingId;
        }
      }
      return id;
    }

    final importedGroups = <({String id, String name})>[];
    if (importedProviderIds.any((id) => !deletedProviderIds.contains(id))) {
      importedGroups.add((
        id: groupIdFor(
          id: '${groupIdPrefix}provider_group_',
          name: regularGroupName,
        ),
        name: regularGroupName,
      ));
    }
    if (deletedProviderIds.isNotEmpty) {
      importedGroups.add((
        id: groupIdFor(
          id: '${groupIdPrefix}provider_group_deleted_',
          name: deletedProviderGroupName,
        ),
        name: deletedProviderGroupName,
      ));
    }
    if (importedGroups.isEmpty) return;

    final importedIds = importedGroups.map((group) => group.id).toSet();
    final oldUngroupedPosition = overwrite
        ? groups.length
        : ((settings[_providerUngroupedPositionKey] as num?)?.toInt() ??
              groups.length);
    final insertionIndex = overwrite
        ? 0
        : oldUngroupedPosition.clamp(0, groups.length);
    final removedBeforeInsertion = groups
        .take(insertionIndex)
        .where((group) => importedIds.contains((group['id'] ?? '').toString()))
        .length;
    groups.removeWhere(
      (group) => importedIds.contains((group['id'] ?? '').toString()),
    );
    final normalizedInsertionIndex = (insertionIndex - removedBeforeInsertion)
        .clamp(0, groups.length);
    groups.insertAll(
      normalizedInsertionIndex,
      importedGroups
          .map(
            (group) => <String, dynamic>{
              'id': group.id,
              'name': group.name,
              'createdAt': DateTime.now().millisecondsSinceEpoch,
            },
          )
          .toList(),
    );

    for (final providerId in importedProviderIds) {
      assignment[providerId] = deletedProviderIds.contains(providerId)
          ? importedGroups.last.id
          : importedGroups.first.id;
    }
    for (final group in importedGroups) {
      collapsed.putIfAbsent(group.id, () => false);
    }

    settings[_providerGroupsKey] = jsonEncode(groups);
    settings[_providerGroupMapKey] = jsonEncode(assignment);
    settings[_providerGroupCollapsedKey] = jsonEncode(collapsed);
    settings[_providerUngroupedPositionKey] = overwrite
        ? groups.length
        : (oldUngroupedPosition -
                  removedBeforeInsertion +
                  importedGroups.length)
              .clamp(0, groups.length);
  }

  static ProviderKind _chatboxProviderKind(
    String sourceId,
    Map<String, dynamic>? customMeta,
  ) {
    final rawType = (customMeta?['type'] ?? '').toString().trim().toLowerCase();
    if (rawType == 'anthropic' || rawType == 'claude') {
      return ProviderKind.claude;
    }
    if (rawType == 'google' || rawType == 'gemini') {
      return ProviderKind.google;
    }
    return ProviderConfig.classify(sourceId);
  }

  static bool _chatboxUsesResponseApi(
    String sourceId,
    Map<String, dynamic>? customMeta,
  ) {
    final rawType = (customMeta?['type'] ?? '').toString().trim().toLowerCase();
    return sourceId.toLowerCase() == 'openai-responses' ||
        rawType == 'openai-responses';
  }

  static String _chatboxProviderDisplayName(
    String sourceId,
    Map<String, dynamic>? customMeta, {
    String configName = '',
  }) {
    final customName = (customMeta?['name'] ?? '').toString().trim();
    if (customName.isNotEmpty) return customName;
    if (configName.isNotEmpty) return configName;

    switch (sourceId.toLowerCase()) {
      case 'chatbox-ai':
        return 'Chatbox AI';
      case 'openai':
        return 'OpenAI';
      case 'openai-responses':
        return 'OpenAI Responses';
      case 'azure':
        return 'Azure OpenAI';
      case 'chatglm-6b':
        return 'ChatGLM';
      case 'claude':
        return 'Claude';
      case 'gemini':
        return 'Gemini';
      case 'qwen':
        return 'Qwen';
      case 'qwen-portal':
        return 'Qwen Portal';
      case 'minimax':
        return 'MiniMax';
      case 'minimax-cn':
        return 'MiniMax CN';
      case 'moonshot':
        return 'Moonshot';
      case 'moonshot-cn':
        return 'Moonshot CN';
      case 'ollama':
        return 'Ollama';
      case 'groq':
        return 'Groq';
      case 'deepseek':
        return 'DeepSeek';
      case 'siliconflow':
        return 'SiliconFlow';
      case 'volcengine':
        return 'VolcEngine';
      case 'mistral-ai':
        return 'Mistral AI';
      case 'lm-studio':
        return 'LM Studio';
      case 'perplexity':
        return 'Perplexity';
      case 'xai':
        return 'xAI';
      case 'openrouter':
        return 'OpenRouter';
      case 'bedrock':
        return 'AWS Bedrock';
      case 'vercel-ai-gateway':
        return 'Vercel AI Gateway';
      default:
        return sourceId;
    }
  }

  static bool _chatboxProviderHasDisplayName(
    String sourceId,
    Map<String, dynamic>? customMeta,
    Map<String, dynamic> config,
  ) {
    final customName = (customMeta?['name'] ?? '').toString().trim();
    if (customName.isNotEmpty) return true;
    if ((config['name'] ?? '').toString().trim().isNotEmpty) return true;

    // Built-in Chatbox providers do not carry a name in the settings map;
    // their stable names come from the provider registry and the switch above.
    switch (sourceId.toLowerCase()) {
      case 'chatbox-ai':
      case 'openai':
      case 'openai-responses':
      case 'azure':
      case 'chatglm-6b':
      case 'claude':
      case 'gemini':
      case 'qwen':
      case 'qwen-portal':
      case 'minimax':
      case 'minimax-cn':
      case 'moonshot':
      case 'moonshot-cn':
      case 'ollama':
      case 'groq':
      case 'deepseek':
      case 'siliconflow':
      case 'volcengine':
      case 'mistral-ai':
      case 'lm-studio':
      case 'perplexity':
      case 'xai':
      case 'openrouter':
      case 'bedrock':
      case 'vercel-ai-gateway':
        return true;
      default:
        return false;
    }
  }

  static bool _containsChatboxProviderReference(
    dynamic value,
    String providerId,
  ) {
    if (value is Map) {
      for (final entry in value.entries) {
        final field = entry.key.toString();
        if ((field == 'provider' || field == 'aiProvider') &&
            entry.value.toString().trim() == providerId) {
          return true;
        }
        if (_containsChatboxProviderReference(entry.value, providerId)) {
          return true;
        }
      }
      return false;
    }
    if (value is List) {
      for (final item in value) {
        if (_containsChatboxProviderReference(item, providerId)) return true;
      }
    }
    return false;
  }

  static _NormalizedHostAndPath _normalizeHostAndPath({
    required String providerKey,
    required ProviderKind kind,
    required String apiHost,
    required String apiPath,
    required String endpoint,
  }) {
    String host = apiHost.trim();
    String path = apiPath.trim();

    // Azure 设置：若存在 endpoint 则优先使用。
    if (host.isEmpty && endpoint.trim().isNotEmpty) {
      host = endpoint.trim();
    }

    if (host.isNotEmpty && host.endsWith('/')) {
      host = host.substring(0, host.length - 1);
    }

    // 若用户存的是裸域名，则补全 scheme
    if (host.isNotEmpty &&
        !(host.startsWith('http://') || host.startsWith('https://'))) {
      host = 'https://$host';
    }

    if (kind == ProviderKind.openai) {
      if (path.isNotEmpty && !path.startsWith('/')) path = '/$path';
      // 若 host 已包含完整路径，则拆分出来。
      if (host.toLowerCase().endsWith('/chat/completions')) {
        host = host.substring(0, host.length - '/chat/completions'.length);
        path = '/chat/completions';
      }
      // 当 host 已包含已知版本段时，避免再追加 '/v1'。
      final lower = host.toLowerCase();
      final hasKnownVersionSuffix =
          lower.endsWith('/v1') ||
          lower.endsWith('/v1beta') ||
          RegExp(r'/api/v\d+$').hasMatch(lower) ||
          lower.endsWith('/api/paas/v4') ||
          lower.endsWith('/compatible-mode/v1');
      if (path.isEmpty) {
        path = '/chat/completions';
      }
      if (host.isNotEmpty && !hasKnownVersionSuffix && !path.contains('/v1')) {
        host = '$host/v1';
      }
      // 对 OpenAI 与 OpenRouter 做规范化特例处理（尽力而为）
      if (lower.endsWith('://api.openai.com') ||
          lower.endsWith('://api.openai.com/v1')) {
        host = 'https://api.openai.com/v1';
        path = '/chat/completions';
      }
      if (lower.endsWith('://openrouter.ai') ||
          lower.endsWith('://openrouter.ai/api')) {
        host = 'https://openrouter.ai/api/v1';
        path = '/chat/completions';
      }
      return _NormalizedHostAndPath(apiHost: host, apiPath: path);
    }

    if (kind == ProviderKind.claude) {
      // 与 Anthropic 对齐：base 应以 /v1 结尾
      final lower = host.toLowerCase();
      if (host.isNotEmpty && lower == 'https://api.anthropic.com') {
        host = '$host/v1';
      } else if (host.isNotEmpty &&
          !lower.endsWith('/v1') &&
          !RegExp(r'/v\d+$').hasMatch(lower)) {
        host = '$host/v1';
      }
      return _NormalizedHostAndPath(apiHost: host, apiPath: '');
    }

    if (kind == ProviderKind.google) {
      // Chatbox 使用 /v1beta；若已存在则保留。
      final lower = host.toLowerCase();
      if (host.isNotEmpty && !lower.endsWith('/v1beta')) {
        host = '$host/v1beta';
      }
      return _NormalizedHostAndPath(apiHost: host, apiPath: '');
    }

    return _NormalizedHostAndPath(apiHost: host, apiPath: path);
  }
}

class _NormalizedHostAndPath {
  final String apiHost;
  final String apiPath;
  const _NormalizedHostAndPath({required this.apiHost, required this.apiPath});
}

class _ChatboxProviderImportPlan {
  final Map<String, Map<String, dynamic>> configs;
  final Map<String, String> idMap;
  final Set<String> deletedProviderIds;

  const _ChatboxProviderImportPlan({
    required this.configs,
    required this.idMap,
    required this.deletedProviderIds,
  });
}

class _AssistantsConversationsResult {
  final int assistants;
  final int conversations;
  final int messages;
  final List<String> assistantIds;
  final List<Map<String, dynamic>> assistantPayloads;
  final List<String> starredAssistantIds;
  final List<ParsedChatImportBatch> conversationBatches;
  final Map<String, List<ChatMessage>> messagesToAppend;
  const _AssistantsConversationsResult({
    required this.assistants,
    required this.conversations,
    required this.messages,
    required this.assistantIds,
    required this.assistantPayloads,
    required this.starredAssistantIds,
    required this.conversationBatches,
    required this.messagesToAppend,
  });
}
