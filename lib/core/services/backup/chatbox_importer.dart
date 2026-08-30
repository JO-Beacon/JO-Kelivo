import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../database/business_data.dart';
import '../../database/business_repository.dart';
import '../../database/business_settings_router.dart';
import '../../database/chat_database_repository.dart'
    show ParsedChatImportBatch;
import '../../models/backup.dart';
import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../models/conversation_tree.dart';
import '../../models/message_part.dart';
import '../../utils/multimodal_input_utils.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../models/backup_task_progress.dart';
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
  static const String _legacyIdPrefix = 'chatbox_legacy_1_21_1_';
  static const String _chatboxStarredGroupId = '${_legacyIdPrefix}starred_';
  static const String _chatboxProviderGroupId =
      '${_legacyIdPrefix}provider_group_';
  static const String _chatboxDeletedProviderGroupId =
      '${_legacyIdPrefix}provider_group_deleted_';
  static const String _chatboxImportGroupName = 'Chatbox 导入（<1.22）';
  static const String _chatboxStarredGroupName = 'Chatbox 导入（<1.22）·置顶';
  static const String _chatboxDeletedProviderGroupName =
      'Chatbox 导入（<1.22）·已删除';

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
    cancelToken?.throwIfCancelled();
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.extracting, value: 0.2),
    );

    // 安全考虑：导出未完成时避免破坏性覆盖。
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
    await chatService.commitParsedImport(
      businessRepository: businessRepository,
      overwrite: mode == RestoreMode.overwrite,
      conversationBatches: assistantConvRes.conversationBatches,
      messagesToAppend: assistantConvRes.messagesToAppend,
      transformBusiness: (current) => _transformBusinessData(
        current: current,
        mode: mode,
        providers: providerPlan.configs,
        deletedProviderIds: providerPlan.deletedProviderIds,
        assistants: assistantConvRes.assistantPayloads,
        assistantIds: assistantConvRes.assistantIds,
        starredAssistantIds: assistantConvRes.starredAssistantIds,
        starredGroupName: starredGroupName ?? _chatboxStarredGroupName,
      ),
    );
    onProgress?.call(
      const ProgressUpdate(phase: BackupPhase.finalizing, value: 1),
    );

    return ChatboxImportResult(
      providers: providerPlan.configs.length,
      assistants: assistantConvRes.assistants,
      conversations: assistantConvRes.conversations,
      messages: assistantConvRes.messages,
    );
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
        onProgress: onProgress,
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
      final targetId = _chatboxImportedProviderId(key);
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
        .map(_chatboxImportedProviderId)
        .toSet();

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
    final existingGroupVersionsByConversation =
        <String, Set<({String groupId, int version})>>{};
    final plannedGroupVersionsByConversation =
        <String, Set<({String groupId, int version})>>{};

    // 在构建完整导入计划期间，现有状态只读。
    if (!chatService.initialized) await chatService.init();

    final existingConvs = chatService.getAllCompleteConversations();
    final existingConvIds = existingConvs.map((c) => c.id).toSet();
    final existingMsgIds = <String>{};
    if (mode == RestoreMode.merge) {
      // 仅取 id：完整加载消息会无意义地冲掉 LRU 缓存。
      for (final c in existingConvs) {
        existingMsgIds.addAll(await chatService.getMessageIds(c.id));
      }
    }

    int convCount = 0;
    int msgCount = 0;

    // 当消息时间戳缺失时，`__exported_at` 是不错的回退时间戳基准。
    final exportedAt =
        _parseIsoDateTime((root['__exported_at'] ?? '').toString()) ??
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

      final thinkingBudget = _extractThinkingBudget(sessionSettings);

      // 将第一条 system 消息作为助手 system prompt。
      final sysPrompt = _extractSystemPromptFromSession(
        session,
        fallback: _extractDefaultPrompt(root),
      );

      final assistantId = _legacyId(id);
      final assistantJson = <String, dynamic>{
        'id': assistantId,
        'name': name,
        'avatar': avatar.isNotEmpty ? avatar : null,
        'useAssistantAvatar': false,
        'useAssistantName': false,
        'chatModelProvider': provider.isEmpty
            ? null
            : providerIdMap[provider] ?? _chatboxImportedProviderId(provider),
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
          'id': _legacyId('default_$id'),
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
                ? _legacyId('thread_$baseId')
                : _legacyId('current_$id');
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
            : _legacyId('thread_$sourceTid');
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
            () => _legacyId(sourceMsgId),
          );
          final hasForkArchive = session['messageForksHash'] is Map;
          if (mode == RestoreMode.merge &&
              !hasForkArchive &&
              existingMsgIds.contains(msgId)) {
            continue;
          }
          final roleRaw = (msg['role'] ?? '').toString();
          final parts = _extractMessageParts(msg, roleHint: roleRaw);
          final content = _textFromParts(parts);

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
              _parseMessageTimestamp(msg['timestamp']) ??
              exportedAt.add(Duration(milliseconds: fallbackIndex++));
          final sourceProviderId = (msg['aiProvider'] ?? '').toString().trim();
          final providerId = sourceProviderId.isEmpty
              ? ''
              : providerIdMap[sourceProviderId] ??
                    _chatboxImportedProviderId(sourceProviderId);

          if (role == 'tool') {
            // 将 tool-result JSON 保留在 TextPart 中以维持工具语义，但不要
            // 丢弃从 contentParts 中提取的 ImagePart/FilePart 附件。
            final toolPayload = _buildToolMessagePayload(
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
                modelId: _inferModelIdFromChatboxMessage(msg).trim().isEmpty
                    ? null
                    : _inferModelIdFromChatboxMessage(msg),
                providerId: sourceProviderId.isEmpty
                    ? null
                    : providerIdMap[sourceProviderId] ??
                          _chatboxImportedProviderId(sourceProviderId),
                totalTokens: null,
                conversationId: tid,
              ),
            );
          } else {
            final inferredModel = _inferModelIdFromChatboxMessage(msg);
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

        final materialized = _materializeChatboxForks(
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
          final created = _parseEpochMillis(createdRaw);
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
          // not by JO-Kelivo conversation pinning.
          isPinned: false,
          assistantId: assistantId,
        );

        final hasForks =
            importedTree.branches.length > 1 ||
            importedTree.branchSelections.isNotEmpty;
        var groupVersionCollision = false;
        if (mode == RestoreMode.merge && existingConvIds.contains(tid)) {
          final existingGroupVersions =
              existingGroupVersionsByConversation[tid] ??= {
                for (final existingMessage
                    in await chatService.loadAllConversationMessages(tid))
                  (
                    groupId: existingMessage.groupId ?? existingMessage.id,
                    version: existingMessage.version,
                  ),
              };
          final plannedGroupVersions = plannedGroupVersionsByConversation
              .putIfAbsent(
                tid,
                () => <({String groupId, int version})>{
                  ...existingGroupVersions,
                },
              );
          groupVersionCollision = messages.any((message) {
            final key = (
              groupId: message.groupId ?? message.id,
              version: message.version,
            );
            return plannedGroupVersions.contains(key) &&
                !existingMsgIds.contains(message.id);
          });
          if (!groupVersionCollision) {
            plannedGroupVersions.addAll(
              messages.map(
                (message) => (
                  groupId: message.groupId ?? message.id,
                  version: message.version,
                ),
              ),
            );
          }
        }
        if (mode == RestoreMode.merge && existingConvIds.contains(tid)) {
          if (!hasForks && !groupVersionCollision) {
            messagesToAppend.putIfAbsent(tid, () => []).addAll(messages);
            msgCount += messages.length;
          } else if (hasForks && messages.every(existingMsgIds.contains)) {
            // 完整树的所有消息都已存在时视为重复导入，不能再追加线性副本。
            continue;
          } else {
            // 合并时如果本地已占用相同的 group/version，保留为独立会话，
            // 与“内容冲突则保留为独立会话”的导入语义一致。
            final remapped = _remapImportedTree(
              conversation: conv,
              messages: messages,
              tree: importedTree,
            );
            conversationBatches.add(remapped);
            convCount += 1;
            msgCount += remapped.messages.length;
          }
        } else {
          conversationBatches.add((
            conversation: conv,
            messages: messages,
            tree: importedTree,
          ));
          convCount += 1;
          msgCount += messages.length;
        }
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

  static ({
    Conversation conversation,
    List<ChatMessage> messages,
    ConversationTree tree,
  })
  _remapImportedTree({
    required Conversation conversation,
    required List<ChatMessage> messages,
    required ConversationTree tree,
  }) {
    final targetConversationId = _legacyId(
      'import_conversation_${const Uuid().v4()}',
    );
    final messageIds = <String, String>{
      for (final message in messages)
        message.id: _legacyId('import_message_${const Uuid().v4()}'),
    };
    final branchIds = <String, String>{
      for (final branch in tree.branches.values)
        branch.id: _legacyId('import_branch_${const Uuid().v4()}'),
    };
    final remappedMessages = [
      for (final message in messages)
        message.copyWith(
          id: messageIds[message.id],
          conversationId: targetConversationId,
        ),
    ];
    final remappedTree = ConversationTree(
      conversationId: targetConversationId,
      activeBranchId: branchIds[tree.activeBranchId]!,
      branches: {
        for (final branch in tree.branches.values)
          branchIds[branch.id]!: ConversationBranch(
            id: branchIds[branch.id]!,
            conversationId: targetConversationId,
            tipMessageId: branch.tipMessageId == null
                ? null
                : messageIds[branch.tipMessageId],
            name: branch.name,
            createdAt: branch.createdAt,
          ),
      },
      edges: {
        for (final edge in tree.edges.values)
          messageIds[edge.messageId]!: MessageTreeEdge(
            messageId: messageIds[edge.messageId]!,
            parentMessageId: edge.parentMessageId == null
                ? null
                : messageIds[edge.parentMessageId],
          ),
      },
      branchSelections: {
        for (final entry in tree.branchSelections.entries)
          if (messageIds[entry.key] != null && branchIds[entry.value] != null)
            messageIds[entry.key]!: branchIds[entry.value]!,
      },
    );
    return (
      conversation: conversation.copyWith(
        id: targetConversationId,
        messageIds: remappedMessages.map((message) => message.id).toList(),
      ),
      messages: remappedMessages,
      tree: remappedTree,
    );
  }

  static ({List<ChatMessage> messages, ConversationTree tree})
  _materializeChatboxForks({
    required String conversationId,
    required List<ChatMessage> rootMessages,
    required dynamic forkHash,
    required Map<String, String> messageIdMap,
    required DateTime fallbackTime,
    required Map<String, String> providerIdMap,
    BackupCancelToken? cancelToken,
  }) {
    final rootBranchId = _legacyId('root_$conversationId');
    final createdAt = rootMessages.isEmpty
        ? fallbackTime
        : rootMessages.first.timestamp;
    final messages = List<ChatMessage>.of(rootMessages);
    final byId = <String, ChatMessage>{
      for (final message in messages) message.id: message,
    };
    final edges = <String, MessageTreeEdge>{};
    final branchByMessage = <String, String>{};
    String? previousId;
    for (final message in rootMessages) {
      edges[message.id] = MessageTreeEdge(
        messageId: message.id,
        parentMessageId: previousId,
      );
      branchByMessage[message.id] = rootBranchId;
      previousId = message.id;
    }

    final branches = <String, ConversationBranch>{
      rootBranchId: ConversationBranch(
        id: rootBranchId,
        conversationId: conversationId,
        tipMessageId: previousId,
        createdAt: createdAt,
      ),
    };
    final branchSelections = <String, String>{};
    if (forkHash is! Map) {
      return (
        messages: messages,
        tree: ConversationTree(
          conversationId: conversationId,
          activeBranchId: rootBranchId,
          branches: branches,
          edges: edges,
        ),
      );
    }

    final entries = <String, Map<String, dynamic>>{};
    for (final rawEntry in forkHash.entries) {
      if (rawEntry.value is! Map) continue;
      entries[rawEntry.key.toString()] = rawEntry.value
          .map((key, value) => MapEntry(key.toString(), value))
          .cast<String, dynamic>();
    }

    bool isListAlreadyMaterialized(String pivotId, List<String> ids) {
      var parentId = pivotId;
      for (final id in ids) {
        final edge = edges[id];
        if (edge == null || edge.parentMessageId != parentId) return false;
        parentId = id;
      }
      return true;
    }

    final handledPivots = <String>{};
    var changed = true;
    while (changed) {
      cancelToken?.throwIfCancelled();
      changed = false;
      for (final entry in entries.entries) {
        cancelToken?.throwIfCancelled();
        final sourcePivotId = entry.key;
        final pivotId = messageIdMap[sourcePivotId] ?? _legacyId(sourcePivotId);
        if (handledPivots.contains(sourcePivotId) ||
            !edges.containsKey(pivotId)) {
          continue;
        }
        final listsRaw = entry.value['lists'];
        if (listsRaw is! List) {
          handledPivots.add(pivotId);
          changed = true;
          continue;
        }
        final position = (entry.value['position'] as num?)?.toInt() ?? 0;
        final activeIndex = position >= 0 && position < listsRaw.length
            ? position
            : 0;
        final parentBranchId = branchByMessage[pivotId] ?? rootBranchId;
        final forkCreatedAt =
            _parseEpochMillis(entry.value['createdAt']) ?? fallbackTime;
        String? selectedBranchId;

        for (var listIndex = 0; listIndex < listsRaw.length; listIndex++) {
          cancelToken?.throwIfCancelled();
          final rawList = listsRaw[listIndex];
          if (rawList is! Map) continue;
          final list = rawList.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final rawMessages = list['messages'];
          if (rawMessages is! List) continue;
          final listMessages = <Map<String, dynamic>>[];
          final listIds = <String>[];
          for (final rawMessage in rawMessages) {
            if (rawMessage is! Map) continue;
            final messageMap = rawMessage.map(
              (key, value) => MapEntry(key.toString(), value),
            );
            final sourceMessageId = (messageMap['id'] ?? '').toString().trim();
            if (sourceMessageId.isEmpty) continue;
            listMessages.add(messageMap.cast<String, dynamic>());
            listIds.add(
              messageIdMap[sourceMessageId] ?? _legacyId(sourceMessageId),
            );
          }

          final isActiveList = listIndex == activeIndex;
          final represented = isListAlreadyMaterialized(pivotId, listIds);
          final shouldCreateBranch =
              !isActiveList || (!represented && listIds.isNotEmpty);
          String? branchId;
          if (shouldCreateBranch) {
            final listId = (list['id'] ?? '$listIndex').toString().trim();
            branchId = _legacyId('fork_${pivotId}_$listId');
            if (!branches.containsKey(branchId)) {
              var parentId = pivotId;
              String? tipId;
              for (var index = 0; index < listMessages.length; index++) {
                final messageMap = listMessages[index];
                final messageId = listIds[index];
                var message = byId[messageId];
                if (message == null) {
                  message = _convertChatboxForkMessage(
                    messageMap,
                    conversationId: conversationId,
                    messageIdMap: messageIdMap,
                    fallbackTime: fallbackTime,
                    providerIdMap: providerIdMap,
                  );
                  if (message == null) continue;
                  byId[message.id] = message;
                  messages.add(message);
                }
                final edge = edges[message.id];
                if (edge == null) {
                  edges[message.id] = MessageTreeEdge(
                    messageId: message.id,
                    parentMessageId: parentId,
                  );
                }
                parentId = message.id;
                tipId = message.id;
                branchByMessage.putIfAbsent(message.id, () => branchId!);
              }
              branches[branchId] = ConversationBranch(
                id: branchId,
                conversationId: conversationId,
                tipMessageId: tipId ?? pivotId,
                name: 'Chatbox fork ${listIndex + 1}',
                createdAt: forkCreatedAt,
              );
              changed = true;
            }
          }

          if (isActiveList) {
            selectedBranchId = branchId ?? parentBranchId;
          }
        }

        if (selectedBranchId != null &&
            branches.containsKey(selectedBranchId)) {
          final selectedBranch = branches[selectedBranchId]!;
          final directChildCount = edges.values
              .where((edge) => edge.parentMessageId == pivotId)
              .length;
          // A single imported list is a linear continuation, not a branch
          // selection. Empty active lists intentionally retain a terminal
          // selection so nested Chatbox fork state can be restored.
          if (directChildCount > 1 || selectedBranch.tipMessageId == pivotId) {
            branchSelections[pivotId] = selectedBranchId;
          }
        }
        handledPivots.add(sourcePivotId);
        changed = true;
      }
    }

    return (
      messages: messages,
      tree: ConversationTree(
        conversationId: conversationId,
        activeBranchId: rootBranchId,
        branches: branches,
        edges: edges,
        branchSelections: branchSelections,
      ),
    );
  }

  static ChatMessage? _convertChatboxForkMessage(
    Map<String, dynamic> msg, {
    required String conversationId,
    required Map<String, String> messageIdMap,
    required DateTime fallbackTime,
    required Map<String, String> providerIdMap,
  }) {
    final sourceMessageId = (msg['id'] ?? '').toString().trim();
    if (sourceMessageId.isEmpty) return null;
    final messageId = messageIdMap[sourceMessageId] ??= _legacyId(
      sourceMessageId,
    );
    final roleRaw = (msg['role'] ?? '').toString();
    final parts = _extractMessageParts(msg, roleHint: roleRaw);
    final content = _textFromParts(parts);
    final timestamp = _parseMessageTimestamp(msg['timestamp']) ?? fallbackTime;
    if (roleRaw == 'tool') {
      final toolPayload = _buildToolMessagePayload(msg, fallbackText: content);
      return ChatMessage(
        id: messageId,
        role: 'tool',
        parts: <MessagePart>[
          TextPart(toolPayload),
          ...parts.where((part) => part is ImagePart || part is FilePart),
        ],
        timestamp: timestamp,
        conversationId: conversationId,
      );
    }
    final role = roleRaw == 'user' ? 'user' : 'assistant';
    final reasoningTexts = parts
        .whereType<ReasoningPart>()
        .map((part) => part.text)
        .where((text) => text.trim().isNotEmpty)
        .toList(growable: false);
    final sourceProviderId = (msg['aiProvider'] ?? '').toString().trim();
    final providerId = sourceProviderId.isEmpty
        ? null
        : providerIdMap[sourceProviderId] ??
              _chatboxImportedProviderId(sourceProviderId);
    return ChatMessage(
      id: messageId,
      role: role,
      parts: parts.isEmpty ? const <MessagePart>[TextPart('')] : parts,
      timestamp: timestamp,
      modelId: _inferModelIdFromChatboxMessage(msg).trim().isEmpty
          ? null
          : _inferModelIdFromChatboxMessage(msg),
      providerId: providerId,
      totalTokens:
          (msg['tokenCount'] as num?)?.toInt() ??
          (msg['tokensUsed'] as num?)?.toInt(),
      conversationId: conversationId,
      reasoningText: reasoningTexts.isEmpty ? null : reasoningTexts.join('\n'),
    );
  }

  // ---------- 原子业务补丁 ----------

  static BusinessSnapshot _transformBusinessData({
    required BusinessSnapshot current,
    required RestoreMode mode,
    required Map<String, Map<String, dynamic>> providers,
    required Set<String> deletedProviderIds,
    required List<Map<String, dynamic>> assistants,
    required List<String> assistantIds,
    required List<String> starredAssistantIds,
    required String starredGroupName,
  }) {
    final settings = BusinessSettingsRouter.exportSnapshot(current);
    final overwrite = mode == RestoreMode.overwrite;

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
      importedProviderIds: providers.keys.toSet(),
      deletedProviderIds: deletedProviderIds,
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
          ? (findGroupId(id: _chatboxStarredGroupId, name: starredGroupName) ??
                _chatboxStarredGroupId)
          : null;
      final regularGroupId = hasRegular
          ? (findGroupId(name: _chatboxImportGroupName) ?? const Uuid().v4())
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
            <String, dynamic>{
              'id': regularGroupId,
              'name': _chatboxImportGroupName,
            },
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
        if (overwrite) {
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

  // ---------- 内容辅助 ----------

  static String _extractDefaultPrompt(Map<String, dynamic> root) {
    final settings = root['settings'];
    if (settings is Map) {
      final p = (settings['defaultPrompt'] ?? '').toString();
      if (p.trim().isNotEmpty) return p;
    }
    return '';
  }

  static String _extractSystemPromptFromSession(
    Map<String, dynamic> session, {
    required String fallback,
  }) {
    final msgs = session['messages'];
    if (msgs is List) {
      for (final raw in msgs) {
        if (raw is! Map) continue;
        final m = raw.map((k, v) => MapEntry(k.toString(), v));
        if ((m['role'] ?? '').toString() != 'system') continue;
        final content = _textFromParts(
          _extractMessageParts(m, roleHint: 'system'),
        );
        if (content.trim().isNotEmpty) return content;
      }
    }
    return fallback;
  }

  static int? _extractThinkingBudget(Map<String, dynamic> sessionSettings) {
    final opts = sessionSettings['providerOptions'];
    if (opts is Map) {
      final claude = opts['claude'];
      if (claude is Map) {
        final thinking = claude['thinking'];
        if (thinking is Map) {
          final type = (thinking['type'] ?? '').toString();
          if (type == 'disabled') return 0;
          final budget = (thinking['budgetTokens'] as num?)?.toInt();
          if (budget != null) return budget;
        }
      }
      final google = opts['google'];
      if (google is Map) {
        final thinkingConfig = google['thinkingConfig'];
        if (thinkingConfig is Map) {
          final budget = (thinkingConfig['thinkingBudget'] as num?)?.toInt();
          if (budget != null) return budget;
        }
      }
    }
    return null;
  }

  static DateTime? _parseIsoDateTime(String raw) {
    try {
      if (raw.trim().isEmpty) return null;
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parseEpochMillis(dynamic raw) {
    if (raw is num) {
      final ms = raw.toInt();
      if (ms <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is String) {
      final n = int.tryParse(raw);
      if (n == null || n <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(n);
    }
    return null;
  }

  static DateTime? _parseMessageTimestamp(dynamic raw) {
    return _parseEpochMillis(raw);
  }

  static String _textFromParts(List<MessagePart> parts) {
    return parts
        .whereType<TextPart>()
        .map((part) => part.text)
        .join('\n')
        .trim();
  }

  static List<MessagePart> _extractMessageParts(
    Map<String, dynamic> msg, {
    required String roleHint,
  }) {
    // 保留 roleHint 以便调用方语义清晰；附件编码与角色无关。
    final _ = roleHint;
    final partsRaw = msg['contentParts'];
    final out = <MessagePart>[];
    final textChunks = <String>[];
    // 当附件分隔文本片段时保留一个换行符，使 TextPart
    // 载荷拼接（无分隔符）得到的是 `before\nafter` 而非 `beforeafter`。
    var pendingContentNewline = false;

    void flushText() {
      if (textChunks.isEmpty) return;
      out.add(TextPart(textChunks.join('\n')));
      textChunks.clear();
    }

    void flushTextForAttachment() {
      flushText();
      pendingContentNewline = out.any((part) => part is TextPart);
    }

    void addText(String s) {
      final t = s.replaceAll('\r\n', '\n');
      if (t.trim().isEmpty) return;
      if (pendingContentNewline && textChunks.isEmpty) {
        textChunks.add('');
      }
      pendingContentNewline = false;
      textChunks.add(t);
    }

    String? mimeFor(String uri, {String? explicit, String? fileName}) {
      final e = explicit?.trim();
      if (e != null && e.isNotEmpty) return e;
      final source = (fileName != null && fileName.isNotEmpty) ? fileName : uri;
      final inferred = inferMediaMimeFromSource(source);
      return inferred.isNotEmpty ? inferred : null;
    }

    if (partsRaw is List) {
      for (final p in partsRaw) {
        if (p is! Map) continue;
        final part = p.map((k, v) => MapEntry(k.toString(), v));
        final type = (part['type'] ?? '').toString();
        switch (type) {
          case 'text':
            addText((part['text'] ?? '').toString());
            break;
          case 'image':
            final url = (part['url'] ?? '').toString().trim();
            final storageKey = (part['storageKey'] ?? '').toString().trim();
            final ref = url.isNotEmpty ? url : storageKey;
            if (ref.isEmpty) break;
            final isResolvable =
                url.startsWith('http://') ||
                url.startsWith('https://') ||
                url.startsWith('data:image') ||
                storageKey.isNotEmpty;
            if (isResolvable) {
              flushTextForAttachment();
              out.add(
                ImagePart(
                  uri: storageKey.isNotEmpty && url.isEmpty
                      ? storageKey
                      : SandboxPathResolver.canonicalize(ref),
                  mime: mimeFor(ref),
                  unavailable:
                      !(url.startsWith('http://') ||
                          url.startsWith('https://') ||
                          url.startsWith('data:image')),
                ),
              );
            } else {
              addText('[Chatbox image: $ref]');
            }
            break;
          case 'info':
            addText((part['text'] ?? '').toString());
            break;
          case 'reasoning':
            final t = (part['text'] ?? '').toString();
            if (t.trim().isNotEmpty) {
              flushText();
              out.add(ReasoningPart(t));
              // 与附件相同的桥接换行符，使 before/reasoning/after
              // 推导出的内容为 `before\nafter`。
              pendingContentNewline = out.any((p) => p is TextPart);
            }
            break;
          case 'tool-call':
            final state = (part['state'] ?? '').toString();
            final toolName = (part['toolName'] ?? '').toString();
            final args = part['args'];
            if (state.isNotEmpty) {
              addText(
                '[tool:$state] ${toolName.isNotEmpty ? toolName : 'tool'} ${args == null ? '' : jsonEncode(args)}'
                    .trim(),
              );
            }
            break;
          default:
            break;
        }
      }
    }

    // 回退到旧版 `content`
    if (out.isEmpty && textChunks.isEmpty) {
      final legacy = (msg['content'] ?? '').toString();
      if (legacy.trim().isNotEmpty) addText(legacy);
    }

    // v1.21.1 仍可能保留已弃用的 reasoningContent；它不能因为
    // contentParts 缺失而随正文一起丢失。旧字段没有交错位置信息，
    // 因此统一放在正文之前，保持 reasoning 与正文的结构化边界。
    final legacyReasoning = (msg['reasoningContent'] ?? '').toString();
    if (legacyReasoning.trim().isNotEmpty &&
        !out.any((part) => part is ReasoningPart)) {
      flushText();
      final existing = List<MessagePart>.of(out);
      out
        ..clear()
        ..add(ReasoningPart(legacyReasoning))
        ..addAll(existing);
    }

    // 链接
    final links = msg['links'];
    if (links is List) {
      for (final l in links) {
        if (l is! Map) continue;
        final url = (l['url'] ?? '').toString().trim();
        if (url.isEmpty) continue;
        final title = (l['title'] ?? '').toString().trim();
        if (title.isNotEmpty) {
          addText('[$title]($url)');
        } else {
          addText(url);
        }
      }
    }

    // 文件——已知附件对象直接转为 FilePart
    final files = msg['files'];
    if (files is List) {
      for (final f in files) {
        if (f is! Map) continue;
        final url = (f['url'] ?? '').toString().trim();
        final storageKey = (f['storageKey'] ?? '').toString().trim();
        final localPath = (f['localPath'] ?? '').toString().trim();
        final ref = url.isNotEmpty
            ? url
            : (storageKey.isNotEmpty ? storageKey : localPath);
        if (ref.isEmpty) continue;
        final name = (f['name'] ?? 'file').toString();
        final type = (f['fileType'] ?? '').toString();
        flushTextForAttachment();
        out.add(
          FilePart(
            uri: storageKey.isNotEmpty && url.isEmpty
                ? storageKey
                : SandboxPathResolver.canonicalize(ref),
            name: name.isNotEmpty ? name : 'file',
            mime:
                mimeFor(ref, explicit: type, fileName: name) ??
                'application/octet-stream',
            unavailable:
                !(url.startsWith('http://') ||
                    url.startsWith('https://') ||
                    url.startsWith('data:')),
          ),
        );
      }
    }

    // 图片（旧版图片列表）
    final pics = msg['pictures'];
    if (pics is List) {
      for (final p in pics) {
        if (p is! Map) continue;
        final url = (p['url'] ?? '').toString().trim();
        final storageKey = (p['storageKey'] ?? '').toString().trim();
        final ref = url.isNotEmpty ? url : storageKey;
        if (ref.isEmpty) continue;
        flushTextForAttachment();
        out.add(
          ImagePart(
            uri: storageKey.isNotEmpty && url.isEmpty
                ? storageKey
                : SandboxPathResolver.canonicalize(ref),
            mime: mimeFor(ref),
            unavailable:
                !(url.startsWith('http://') ||
                    url.startsWith('https://') ||
                    url.startsWith('data:')),
          ),
        );
      }
    }

    // 错误信息
    final err = (msg['error'] ?? '').toString();
    if (err.trim().isNotEmpty) {
      addText('[Error] $err');
    }

    flushText();
    return out;
  }

  static String _inferModelIdFromChatboxMessage(Map<String, dynamic> msg) {
    final raw = (msg['model'] ?? '').toString().trim();
    if (raw.isEmpty) return '';
    final m = RegExp(r'\(([^)]+)\)\s*$').firstMatch(raw);
    if (m != null) return (m.group(1) ?? '').trim();
    return raw;
  }

  static String _buildToolMessagePayload(
    Map<String, dynamic> msg, {
    required String fallbackText,
  }) {
    String toolName = (msg['name'] ?? '').toString().trim();
    Map<String, dynamic> args = const <String, dynamic>{};
    String result = fallbackText;

    final parts = msg['contentParts'];
    if (parts is List) {
      for (final p in parts) {
        if (p is! Map) continue;
        final part = p.map((k, v) => MapEntry(k.toString(), v));
        if ((part['type'] ?? '').toString() != 'tool-call') continue;
        toolName = toolName.isNotEmpty
            ? toolName
            : (part['toolName'] ?? '').toString();
        final a = part['args'];
        if (a is Map) args = a.cast<String, dynamic>();
        final state = (part['state'] ?? '').toString();
        if (state == 'result' && part.containsKey('result')) {
          final rawResult = part['result'];
          result = rawResult is String ? rawResult : jsonEncode(rawResult);
        }
        break;
      }
    }

    final payload = <String, dynamic>{
      'tool': toolName.isNotEmpty ? toolName : 'tool',
      'arguments': args,
      'result': result,
    };
    return jsonEncode(payload);
  }

  static String _chatboxImportedProviderId(String sourceId) {
    return _legacyId('provider_$sourceId');
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
    required Set<String> importedProviderIds,
    required Set<String> deletedProviderIds,
  }) {
    if (importedProviderIds.isEmpty) return;

    final overwrite = mode == RestoreMode.overwrite;
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
          id: _chatboxProviderGroupId,
          name: _chatboxImportGroupName,
        ),
        name: _chatboxImportGroupName,
      ));
    }
    if (deletedProviderIds.isNotEmpty) {
      importedGroups.add((
        id: groupIdFor(
          id: _chatboxDeletedProviderGroupId,
          name: _chatboxDeletedProviderGroupName,
        ),
        name: _chatboxDeletedProviderGroupName,
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

  static String _legacyId(String sourceId) => '$_legacyIdPrefix$sourceId';

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
