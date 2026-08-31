import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

import '../../database/business_data.dart';
import '../../database/business_repository.dart';
import '../../database/business_settings_router.dart';
import '../../models/assistant.dart';
import '../../models/backup.dart';
import '../../models/backup_task_progress.dart';
import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../models/conversation_tree.dart';
import '../../models/message_part.dart';
import '../../models/progress_update.dart';
import '../../providers/assistant_group_provider.dart';
import '../../providers/assistant_provider.dart';
import '../chat/chat_service.dart';
import 'backup_isolate_runner.dart';

class DeepSeekImportException implements Exception {
  const DeepSeekImportException(this.code);

  final String code;

  @override
  String toString() => code;
}

class DeepSeekImportResult {
  const DeepSeekImportResult({
    required this.conversations,
    required this.messages,
  });

  final int conversations;
  final int messages;
}

@pragma('vm:entry-point')
Future<Object?> _readDeepSeekFileWorker(
  BackupIsolateContext context,
  String path,
) async {
  context.throwIfCancelled();
  final file = File(path);
  if (!await file.exists()) {
    throw StateError('deepseek_file_not_found');
  }
  final bytes = await file.readAsBytes();
  context.throwIfCancelled();

  dynamic decoded;
  if (_looksLikeZip(bytes)) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      throw StateError('deepseek_invalid_zip:$error');
    }
    ArchiveFile? conversationsEntry;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (entry.name.replaceAll('\\', '/').split('/').last.toLowerCase() ==
          'conversations.json') {
        conversationsEntry = entry;
        break;
      }
    }
    if (conversationsEntry == null) {
      throw StateError('deepseek_conversations_missing');
    }
    try {
      decoded = jsonDecode(utf8.decode(conversationsEntry.content));
    } catch (error) {
      throw StateError('deepseek_invalid_json:$error');
    }
  } else {
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (error) {
      throw StateError('deepseek_invalid_json:$error');
    }
  }
  context.throwIfCancelled();
  if (decoded is List) return <String, dynamic>{'conversations': decoded};
  if (decoded is Map) {
    final map = decoded.map((key, value) => MapEntry(key.toString(), value));
    if (map['conversations'] is List) return map;
  }
  throw StateError('deepseek_conversations_invalid');
}

bool _looksLikeZip(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4b &&
    bytes[2] == 0x03 &&
    bytes[3] == 0x04;

class DeepSeekImporter {
  DeepSeekImporter._();

  static const _idPrefix = 'deepseek_';
  static const _webProviderId = 'deepseek_web';
  static const String _providersKey = 'provider_configs_v1';
  static const String _providersOrderKey = 'providers_order_v1';

  static Future<DeepSeekImportResult> importFromDeepSeek({
    required File file,
    required RestoreMode mode,
    required BusinessRepository businessRepository,
    required ChatService chatService,
    required AssistantProvider assistantProvider,
    required AssistantGroupProvider assistantGroupProvider,
    required String assistantGroupName,
    required String providerName,
    BackupCancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.preparing, value: 0),
    );
    final root = await _readRoot(file, cancelToken: cancelToken);
    final rawConversations = root['conversations'];
    if (rawConversations is! List) {
      throw const DeepSeekImportException('conversations_missing');
    }

    if (!chatService.initialized) await chatService.init();
    await assistantProvider.loaded;
    final webModels = _collectWebModels(rawConversations);
    final existingBeforeImport = <String, Conversation>{
      for (final conversation in chatService.getAllCompleteConversations())
        conversation.id: conversation,
    };
    final existing = Map<String, Conversation>.of(existingBeforeImport);
    final existingMessageIds = <String, Set<String>>{};
    if (mode == RestoreMode.merge) {
      for (final conversation in existing.values) {
        existingMessageIds[conversation.id] =
            (await chatService.loadAllConversationMessages(
              conversation.id,
            )).map((message) => message.id).toSet();
      }
    }
    final importedAssistants = <String, Assistant>{};
    final batches =
        <
          ({
            Conversation conversation,
            List<ChatMessage> messages,
            ConversationTree tree,
            Assistant assistant,
          })
        >[];
    for (final (index, raw) in rawConversations.indexed) {
      cancelToken?.throwIfCancelled();
      if (raw is! Map) continue;
      final source = _stringMap(raw);
      final built = _buildConversation(source);
      if (built == null) continue;
      importedAssistants[built.assistant.id] = built.assistant;
      var batch = built;
      final canonicalId = batch.conversation.id;
      final placedId = '${canonicalId}_placed';
      if (mode == RestoreMode.merge) {
        final current = existing[canonicalId];
        if (current != null) {
          final localMessages = await chatService.loadAllConversationMessages(
            canonicalId,
          );
          existingMessageIds[canonicalId] = localMessages
              .map((message) => message.id)
              .toSet();
          final merged = await _mergeConversationBatch(
            chatService,
            current,
            batch,
          );
          if (_isUnchangedMerge(
            localMessages: localMessages,
            currentTree: await chatService.loadConversationTree(canonicalId),
            merged: merged,
          )) {
            onProgress?.call(
              ProgressUpdate(
                phase: BackupPhase.extracting,
                processed: index + 1,
                total: rawConversations.length,
              ),
            );
            continue;
          }
          batch = (
            conversation: merged.conversation,
            messages: merged.messages,
            tree: merged.tree,
            assistant: batch.assistant,
          );
        }
      } else {
        final canonical = existing[canonicalId];
        final placed = existing[placedId];
        if ((canonical != null &&
                canonical.assistantId != batch.assistant.id) ||
            (canonical == null && placed != null)) {
          final sourceKey = canonicalId.substring(_idPrefix.length);
          batch = _remap(
            batch,
            suffix: '${sourceKey}_placed',
            assistantId: batch.assistant.id,
            sourceKey: sourceKey,
          );
        }
      }
      batches.add(batch);
      existing[batch.conversation.id] = batch.conversation;
      onProgress?.call(
        ProgressUpdate(
          phase: BackupPhase.extracting,
          processed: index + 1,
          total: rawConversations.length,
        ),
      );
    }

    cancelToken?.throwIfCancelled();
    if (mode == RestoreMode.overwrite && batches.isEmpty) {
      throw const DeepSeekImportException('conversations_invalid');
    }
    final upsertWebProvider = webModels.isEmpty
        ? null
        : (BusinessSnapshot current) => _upsertWebProvider(
            current,
            providerName: providerName,
            models: webModels,
          );
    final assistantGroupId = await assistantGroupProvider.ensureGroup(
      assistantGroupName,
    );
    for (final importedAssistant in importedAssistants.values) {
      cancelToken?.throwIfCancelled();
      final existingAssistant = assistantProvider.getById(importedAssistant.id);
      if (existingAssistant == null) {
        await assistantProvider.addImportedAssistant(importedAssistant);
      } else if (mode == RestoreMode.merge) {
        final mergedAssistant = _mergeAssistant(
          existingAssistant,
          importedAssistant,
        );
        if (!_sameAssistantImportFields(existingAssistant, mergedAssistant)) {
          await assistantProvider.updateAssistant(mergedAssistant);
        }
      }
      if (mode == RestoreMode.overwrite ||
          assistantGroupProvider.groupOfAssistant(importedAssistant.id) ==
              null) {
        await assistantGroupProvider.assignAssistantToGroup(
          importedAssistant.id,
          assistantGroupId,
        );
      }
    }
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.restoring, value: 0.85),
    );
    final parsedBatches = [
      for (final batch in batches)
        (
          conversation: batch.conversation,
          messages: batch.messages,
          tree: batch.tree,
        ),
    ];
    await chatService.commitScopedParsedImport(
      businessRepository: businessRepository,
      replaceExisting: mode == RestoreMode.overwrite,
      conversationBatches: parsedBatches,
      transformBusiness: upsertWebProvider ?? (current) => current,
    );
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.finalizing, value: 1),
    );
    var admittedConversations = 0;
    var admittedMessages = 0;
    for (final batch in batches) {
      final old = existingBeforeImport[batch.conversation.id];
      final oldIds =
          existingMessageIds[batch.conversation.id] ?? const <String>{};
      final added = batch.messages
          .where((message) => !oldIds.contains(message.id))
          .length;
      if (old == null || mode == RestoreMode.overwrite || added > 0) {
        admittedConversations++;
        admittedMessages += mode == RestoreMode.merge && old != null
            ? added
            : batch.messages.length;
      }
    }
    return DeepSeekImportResult(
      conversations: admittedConversations,
      messages: admittedMessages,
    );
  }

  static Future<Map<String, dynamic>> _readRoot(
    File file, {
    BackupCancelToken? cancelToken,
  }) async {
    try {
      final decoded = await runBackupIsolate<Object?, String>(
        body: _readDeepSeekFileWorker,
        payload: file.path,
        cancelToken: cancelToken,
      );
      if (decoded is! Map) {
        throw const DeepSeekImportException('invalid_export');
      }
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on StateError catch (error) {
      switch (error.message.split(':').first) {
        case 'deepseek_file_not_found':
          throw const DeepSeekImportException('file_not_found');
        case 'deepseek_conversations_missing':
          throw const DeepSeekImportException('conversations_missing');
        case 'deepseek_conversations_invalid':
          throw const DeepSeekImportException('conversations_invalid');
        default:
          throw const DeepSeekImportException('read_failed');
      }
    }
  }

  static ({
    Conversation conversation,
    List<ChatMessage> messages,
    ConversationTree tree,
    Assistant assistant,
  })?
  _buildConversation(Map<String, dynamic> source) {
    final sourceId = (source['id'] ?? '').toString().trim();
    final mappingRaw = source['mapping'];
    if (sourceId.isEmpty || mappingRaw is! Map) return null;
    final mapping = <String, Map<String, dynamic>>{};
    for (final entry in mappingRaw.entries) {
      if (entry.value is Map) {
        mapping[entry.key.toString()] = _stringMap(entry.value);
      }
    }
    if (mapping.isEmpty) return null;

    final roots = <String>[];
    final root = mapping['root'];
    if (root != null && root['children'] is List) {
      roots.addAll(_stringList(root['children']));
    }
    roots.addAll(
      mapping.keys.where(
        (id) =>
            id != 'root' &&
            (mapping[id]!['parent']?.toString() ?? '') == 'root' &&
            !roots.contains(id),
      ),
    );
    final order = <String>[];
    final visited = <String>{};
    void visit(String id) {
      if (!visited.add(id)) return;
      final node = mapping[id];
      if (node == null) return;
      order.add(id);
      for (final child in _stringList(node['children'])) {
        if (mapping.containsKey(child)) visit(child);
      }
    }

    for (final id in roots) {
      visit(id);
    }
    for (final id in mapping.keys) {
      if (id != 'root') visit(id);
    }

    final conversationId = '$_idPrefix$sourceId';
    final idFor = <String, String>{
      for (final id in order) id: '$_idPrefix${sourceId}_$id',
    };
    final messages = <ChatMessage>[];
    final edges = <String, MessageTreeEdge>{};
    final childrenById = <String, List<String>>{};
    final timestamps = <String, DateTime>{};
    for (final id in order) {
      final node = mapping[id]!;
      final messageRaw = node['message'];
      final messageMap = messageRaw is Map ? _stringMap(messageRaw) : null;
      if (messageMap != null) {
        final message = _messageFrom(
          messageMap,
          conversationId: conversationId,
          messageId: idFor[id]!,
          sourceNodeId: id,
        );
        messages.add(message);
        timestamps[id] = message.timestamp;
        final parent = node['parent']?.toString();
        edges[message.id] = MessageTreeEdge(
          messageId: message.id,
          parentMessageId:
              parent != null &&
                  idFor[parent] != null &&
                  mapping[parent]?['message'] is Map
              ? idFor[parent]
              : null,
        );
      }
      final children = _stringList(
        node['children'],
      ).where(idFor.containsKey).toList();
      childrenById[id] = children;
    }
    if (messages.isEmpty) return null;

    final leaves = order
        .where((id) => childrenById[id]?.isEmpty ?? true)
        .toList();
    final activeLeaf = leaves.last;
    final activePath = _pathToRoot(activeLeaf, mapping, idFor);
    final branchByLeaf = <String, String>{};
    final branches = <String, ConversationBranch>{};
    for (var index = 0; index < leaves.length; index++) {
      final leaf = leaves[index];
      final branchId = '$_idPrefix${sourceId}_branch_$index';
      branchByLeaf[leaf] = branchId;
      branches[branchId] = ConversationBranch(
        id: branchId,
        conversationId: conversationId,
        tipMessageId: idFor[leaf],
        name: '',
        createdAt: timestamps[leaf] ?? DateTime.now(),
      );
    }
    final activeBranchId = branchByLeaf[activeLeaf]!;
    final selections = <String, String>{};
    for (final pivot in activePath) {
      final children = childrenById[pivot] ?? const <String>[];
      if (children.length < 2) continue;
      final selected = activePath[activePath.indexOf(pivot) + 1];
      String? leaf = selected;
      while ((childrenById[leaf] ?? const <String>[]).isNotEmpty) {
        leaf = childrenById[leaf]!.last;
      }
      final branch = branchByLeaf[leaf];
      if (branch != null && idFor[pivot] != null) {
        selections[idFor[pivot]!] = branch;
      }
    }
    final tree = ConversationTree(
      conversationId: conversationId,
      activeBranchId: activeBranchId,
      branches: branches,
      edges: edges,
      branchSelections: selections,
    );
    final times = messages.map((message) => message.timestamp).toList()..sort();
    final sourceCreatedAt = _parseDate(source['inserted_at']);
    final sourceUpdatedAt = _parseDate(source['updated_at']);
    final title = (source['title'] ?? sourceId).toString().trim();
    final conversationTitle = title.isEmpty ? sourceId : title;
    final modelId = messages
        .map((message) => message.modelId)
        .firstWhere(
          (model) => model != null && model.isNotEmpty,
          orElse: () => null,
        );
    final assistantId = '$_idPrefix${sourceId}_assistant';
    return (
      conversation: Conversation(
        id: conversationId,
        title: conversationTitle,
        assistantId: assistantId,
        createdAt: sourceCreatedAt ?? times.first,
        updatedAt: sourceUpdatedAt ?? times.last,
        messageIds: messages
            .map((message) => message.id)
            .toList(growable: false),
      ),
      messages: messages,
      tree: tree,
      assistant: Assistant(
        id: assistantId,
        name: conversationTitle,
        chatModelProvider: modelId == null ? null : _webProviderId,
        chatModelId: modelId,
      ),
    );
  }

  static ChatMessage _messageFrom(
    Map<String, dynamic> raw, {
    required String conversationId,
    required String messageId,
    required String sourceNodeId,
  }) {
    final fragments = raw['fragments'] is List
        ? raw['fragments'] as List
        : const <dynamic>[];
    final parts = <MessagePart>[];
    var hasRequest = false;
    var hasAssistant = false;
    var hasTool = false;
    final reasoningTexts = <String>[];
    var fileIndex = 0;
    for (final fragmentRaw in fragments) {
      if (fragmentRaw is! Map) continue;
      final fragment = _stringMap(fragmentRaw);
      final type = (fragment['type'] ?? '').toString().toUpperCase();
      switch (type) {
        case 'REQUEST':
          hasRequest = true;
          final content = fragment['content'];
          if (content is String && content.isNotEmpty) {
            parts.add(TextPart(content));
          }
        case 'RESPONSE':
          hasAssistant = true;
          final content = fragment['content'];
          if (content is String && content.isNotEmpty) {
            parts.add(TextPart(content));
          }
        case 'THINK':
          hasAssistant = true;
          final content = fragment['content'];
          if (content is String && content.isNotEmpty) {
            reasoningTexts.add(content);
            parts.add(ReasoningPart(content));
          }
        case 'FILE':
          hasRequest = true;
          final files = fragment['files'] is List
              ? fragment['files'] as List
              : const <dynamic>[];
          for (final fileRaw in files) {
            if (fileRaw is! Map) continue;
            final file = _stringMap(fileRaw);
            final fileId = (file['file_id'] ?? '$sourceNodeId-$fileIndex')
                .toString();
            final name = (file['file_name'] ?? fileId).toString();
            parts.add(
              FilePart(
                uri: 'deepseek://file/$fileId',
                name: name,
                unavailable: true,
              ),
            );
            fileIndex++;
          }
        case 'SEARCH':
        case 'TOOL_SEARCH':
        case 'TOOL_OPEN':
        case 'TOOL_FIND':
          hasTool = true;
          parts.add(
            UnknownPart(
              rawKind: 'deepseek_tool',
              payload: jsonEncode({
                'source': 'deepseek',
                'type': type,
                if (fragment['content'] != null) 'content': fragment['content'],
                if (fragment['results'] != null) 'results': fragment['results'],
              }),
            ),
          );
        default:
          if (type.isNotEmpty) {
            parts.add(
              UnknownPart(
                rawKind: 'deepseek_${type.toLowerCase()}',
                payload: jsonEncode(fragment),
              ),
            );
            hasTool = true;
          }
      }
    }
    if (parts.isEmpty) parts.add(const TextPart(''));
    final role = hasRequest
        ? 'user'
        : (hasAssistant ? 'assistant' : (hasTool ? 'tool' : 'assistant'));
    final timestamp = _parseDate(raw['inserted_at']) ?? DateTime.now();
    return ChatMessage(
      id: messageId,
      role: role,
      parts: parts,
      timestamp: timestamp,
      modelId: (raw['model'] ?? '').toString().trim().isEmpty
          ? null
          : raw['model'].toString(),
      conversationId: conversationId,
      reasoningText: reasoningTexts.isEmpty ? null : reasoningTexts.join('\n'),
    );
  }

  static Assistant _mergeAssistant(Assistant current, Assistant imported) {
    return current.copyWith(
      chatModelProvider: imported.chatModelProvider,
      chatModelId: imported.chatModelId,
    );
  }

  static bool _sameAssistantImportFields(Assistant a, Assistant b) =>
      a.chatModelProvider == b.chatModelProvider &&
      a.chatModelId == b.chatModelId;

  static bool _isUnchangedMerge({
    required List<ChatMessage> localMessages,
    required ConversationTree? currentTree,
    required ({
      Conversation conversation,
      List<ChatMessage> messages,
      ConversationTree tree,
    })
    merged,
  }) {
    if (merged.messages.length != localMessages.length) return false;
    final localById = <String, ChatMessage>{
      for (final message in localMessages) message.id: message,
    };
    for (final message in merged.messages) {
      final local = localById[message.id];
      if (local == null ||
          local.role != message.role ||
          local.semanticContentHash != message.semanticContentHash) {
        return false;
      }
    }
    return currentTree != null && _sameTree(currentTree, merged.tree);
  }

  static bool _sameTree(ConversationTree a, ConversationTree b) {
    if (a.conversationId != b.conversationId ||
        a.activeBranchId != b.activeBranchId ||
        a.branchSelections.length != b.branchSelections.length ||
        a.edges.length != b.edges.length ||
        a.branches.length != b.branches.length) {
      return false;
    }
    for (final entry in a.branchSelections.entries) {
      if (b.branchSelections[entry.key] != entry.value) return false;
    }
    for (final entry in a.edges.entries) {
      final other = b.edges[entry.key];
      if (other == null ||
          other.messageId != entry.value.messageId ||
          other.parentMessageId != entry.value.parentMessageId) {
        return false;
      }
    }
    for (final entry in a.branches.entries) {
      final other = b.branches[entry.key];
      if (other == null ||
          other.id != entry.value.id ||
          other.conversationId != entry.value.conversationId ||
          other.tipMessageId != entry.value.tipMessageId ||
          other.name != entry.value.name ||
          other.createdAt != entry.value.createdAt) {
        return false;
      }
    }
    return true;
  }

  static Future<
    ({
      Conversation conversation,
      List<ChatMessage> messages,
      ConversationTree tree,
    })
  >
  _mergeConversationBatch(
    ChatService chatService,
    Conversation current,
    ({
      Conversation conversation,
      List<ChatMessage> messages,
      ConversationTree tree,
      Assistant assistant,
    })
    incoming,
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
            groupId: _stableId('merge_${current.id}_${message.id}'),
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
          _stableId('conflict_${current.id}_${message.id}'),
          {...localById, ...incomingById},
        );
        idMap[message.id] = conflictId;
        mergedMessages.add(
          message.copyWith(
            id: conflictId,
            groupId: _stableId('merge_${current.id}_${message.id}'),
            version: 0,
          ),
        );
        occupiedGroupVersions.add((
          groupId: _stableId('merge_${current.id}_${message.id}'),
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
    final edges = Map<String, MessageTreeEdge>.from(localTree.edges);
    final branches = Map<String, ConversationBranch>.from(localTree.branches);
    final selections = Map<String, String>.from(localTree.branchSelections);
    for (final edge in incoming.tree.edges.values) {
      var mappedId = idMap[edge.messageId];
      if (mappedId == null) continue;
      var parentId = edge.parentMessageId == null
          ? null
          : idMap[edge.parentMessageId];
      if (parentId == null && edge.parentMessageId != null) {
        parentId = _nearestMessageBefore(
          mergedMessages,
          incomingById[edge.messageId]?.timestamp,
        );
      }
      final existingEdge = edges[mappedId];
      if (existingEdge != null && existingEdge.parentMessageId != parentId) {
        final sourceMessage = incomingById[edge.messageId];
        if (sourceMessage != null && mappedId == edge.messageId) {
          mappedId = _stableUniqueMessageId(
            _stableId('placement_${current.id}_${edge.messageId}'),
            {...localById, ...incomingById},
          );
          idMap[edge.messageId] = mappedId;
          mergedMessages.add(
            sourceMessage.copyWith(
              id: mappedId,
              groupId: _stableId('placement_${current.id}_${edge.messageId}'),
              version: 0,
            ),
          );
        }
      }
      if (existingEdge == null || !edges.containsKey(mappedId)) {
        edges[mappedId] = MessageTreeEdge(
          messageId: mappedId,
          parentMessageId: parentId,
        );
      }
    }
    final branchMap = <String, String>{};
    for (final branch in incoming.tree.branches.values) {
      final mappedTip = branch.tipMessageId == null
          ? null
          : idMap[branch.tipMessageId];
      final existingBranch = branches[branch.id];
      final mappedBranchId =
          existingBranch != null && existingBranch.tipMessageId == mappedTip
          ? branch.id
          : _stableUniqueBranchId(branch.id, branches);
      branchMap[branch.id] = mappedBranchId;
      if (mappedBranchId != branch.id || existingBranch == null) {
        branches[mappedBranchId] = branch.copyWith(
          id: mappedBranchId,
          conversationId: current.id,
          tipMessageId: mappedTip,
        );
      }
    }
    for (final entry in incoming.tree.branchSelections.entries) {
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
      throw StateError('deepseek_merge_tree_message_missing');
    }
    final updatedAt = mergedMessages
        .map((message) => message.timestamp)
        .fold(
          current.updatedAt,
          (latest, value) => value.isAfter(latest) ? value : latest,
        );
    return (
      conversation: current.copyWith(
        updatedAt: updatedAt,
        messageIds: mergedMessages.map((message) => message.id).toList(),
      ),
      messages: mergedMessages,
      tree: ConversationTree(
        conversationId: current.id,
        activeBranchId: localTree.activeBranchId,
        branches: branches,
        edges: edges,
        branchSelections: selections,
      ),
    );
  }

  static String _stableId(String value) =>
      '$_idPrefix${value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}';

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

  static List<String> _pathToRoot(
    String leaf,
    Map<String, Map<String, dynamic>> mapping,
    Map<String, String> idFor,
  ) {
    final path = <String>[];
    final seen = <String>{};
    String? current = leaf;
    while (current != null && current != 'root' && seen.add(current)) {
      if (!idFor.containsKey(current)) break;
      path.add(current);
      current = mapping[current]?['parent']?.toString();
    }
    path.reverse();
    return path;
  }

  static ({
    Conversation conversation,
    List<ChatMessage> messages,
    ConversationTree tree,
    Assistant assistant,
  })
  _remap(
    ({
      Conversation conversation,
      List<ChatMessage> messages,
      ConversationTree tree,
      Assistant assistant,
    })
    batch, {
    required String suffix,
    required String assistantId,
    required String sourceKey,
  }) {
    final conversationId = '$_idPrefix$suffix';
    final messageIds = {
      for (final message in batch.messages)
        message.id:
            '$_idPrefix${suffix}_${message.id.substring('$_idPrefix${sourceKey}_'.length)}',
    };
    final branchIds = {
      for (final (index, branch) in batch.tree.branches.values.indexed)
        branch.id: '$_idPrefix${suffix}_branch_$index',
    };
    final messages = [
      for (final message in batch.messages)
        message.copyWith(
          id: messageIds[message.id],
          conversationId: conversationId,
        ),
    ];
    final tree = ConversationTree(
      conversationId: conversationId,
      activeBranchId: branchIds[batch.tree.activeBranchId]!,
      branches: {
        for (final branch in batch.tree.branches.values)
          branchIds[branch.id]!: ConversationBranch(
            id: branchIds[branch.id]!,
            conversationId: conversationId,
            tipMessageId: branch.tipMessageId == null
                ? null
                : messageIds[branch.tipMessageId],
            name: branch.name,
            createdAt: branch.createdAt,
          ),
      },
      edges: {
        for (final edge in batch.tree.edges.values)
          messageIds[edge.messageId]!: MessageTreeEdge(
            messageId: messageIds[edge.messageId]!,
            parentMessageId: edge.parentMessageId == null
                ? null
                : messageIds[edge.parentMessageId],
          ),
      },
      branchSelections: {
        for (final entry in batch.tree.branchSelections.entries)
          messageIds[entry.key]!: branchIds[entry.value]!,
      },
    );
    return (
      conversation: batch.conversation.copyWith(
        id: conversationId,
        assistantId: assistantId,
        messageIds: messages.map((message) => message.id).toList(),
      ),
      messages: messages,
      tree: tree,
      assistant: batch.assistant.copyWith(id: assistantId),
    );
  }

  static Map<String, dynamic> _stringMap(dynamic raw) =>
      (raw as Map).map((key, value) => MapEntry(key.toString(), value));

  /// 预扫描整个导出包，收集实际出现过的模型值。
  /// 占位供应商只用于展示"这批会话来自哪些模型"，不硬编码官方清单，
  /// 因此以导出文件自身为唯一来源。
  static List<String> _collectWebModels(List<dynamic> rawConversations) {
    final models = <String>{};
    for (final raw in rawConversations) {
      if (raw is! Map) continue;
      final source = _stringMap(raw);
      final mappingRaw = source['mapping'];
      if (mappingRaw is! Map) continue;
      for (final nodeRaw in mappingRaw.values) {
        if (nodeRaw is! Map) continue;
        final messageRaw = nodeRaw['message'];
        if (messageRaw is! Map) continue;
        final model = (messageRaw['model'] ?? '').toString().trim();
        if (model.isNotEmpty) models.add(model);
      }
    }
    return models.toList(growable: false);
  }

  /// 写入或合并展示用占位供应商。已存在时只做模型并集，
  /// 不覆盖 name/enabled/apiKey/baseUrl，避免抹掉用户手动启用的真实配置。
  static BusinessSnapshot _upsertWebProvider(
    BusinessSnapshot current, {
    required String providerName,
    required List<String> models,
  }) {
    final settings = BusinessSettingsRouter.exportSnapshot(current);
    final providers = _jsonObjectMap(settings[_providersKey]);
    final existing = providers[_webProviderId];
    if (existing == null) {
      providers[_webProviderId] = <String, dynamic>{
        'id': _webProviderId,
        'enabled': false,
        'name': providerName,
        'apiKey': '',
        'baseUrl': '',
        'providerType': 'openai',
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
    } else {
      final existingModels = existing['models'];
      final mergedModels = <String>{
        for (final value
            in existingModels is List ? existingModels : const <dynamic>[])
          value.toString(),
      };
      mergedModels.addAll(models);
      existing['models'] = mergedModels.toList(growable: false);
      providers[_webProviderId] = existing;
    }
    settings[_providersKey] = jsonEncode(providers);

    final order = <String>[
      for (final value
          in settings[_providersOrderKey] is List
              ? (settings[_providersOrderKey] as List).cast<dynamic>()
              : const <dynamic>[])
        value.toString(),
    ];
    if (!order.contains(_webProviderId)) order.add(_webProviderId);
    settings[_providersOrderKey] = order;

    return BusinessSettingsRouter.normalizeAndRoute(settings);
  }

  static Map<String, Map<String, dynamic>> _jsonObjectMap(dynamic raw) {
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {}
    } else if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, Map<String, dynamic>>{};
  }

  static List<String> _stringList(dynamic raw) => raw is List
      ? [for (final value in raw) value.toString()]
      : const <String>[];

  static DateTime? _parseDate(dynamic raw) {
    if (raw is num) {
      final value = raw.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
        value < 100000000000 ? value * 1000 : value,
      );
    }
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final iso = DateTime.tryParse(text);
    if (iso != null) return iso;
    final match = RegExp(
      r'^(\d{1,2})/(\d{1,2})/(\d{4})[ T](\d{1,2}):(\d{2}):(\d{2})$',
    ).firstMatch(text);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(3)!),
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }
}

extension on List<String> {
  void reverse() {
    for (var left = 0, right = length - 1; left < right; left++, right--) {
      final value = this[left];
      this[left] = this[right];
      this[right] = value;
    }
  }
}
