import 'dart:convert';

import '../../models/chat_message.dart';
import '../../models/conversation_tree.dart';
import '../../models/message_part.dart';
import '../../utils/multimodal_input_utils.dart';
import '../../../utils/sandbox_path_resolver.dart';
import 'backup_cancel_token.dart';

/// Chatbox 两代备份共用的会话与消息解析。
///
/// 旧版 JSON 与新版 `sessions/<id>/session.json` 的字段同名同义，
/// 因此消息部件转换、分叉重建与内容辅助只保留这一份实现。
abstract final class ChatboxSharedParser {
  static const String legacyIdPrefix = 'chatbox_legacy_1_21_1_';

  /// 两代共用的稳定 ID 生成。
  static String legacyId(String sourceId) => '$legacyIdPrefix$sourceId';

  static ({List<ChatMessage> messages, ConversationTree tree})
  materializeForks({
    required String conversationId,
    required List<ChatMessage> rootMessages,
    required dynamic forkHash,
    required Map<String, String> messageIdMap,
    required DateTime fallbackTime,
    required Map<String, String> providerIdMap,
    BackupCancelToken? cancelToken,
  }) {
    final rootBranchId = legacyId('root_$conversationId');
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
        final pivotId = messageIdMap[sourcePivotId] ?? legacyId(sourcePivotId);
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
            parseEpochMillis(entry.value['createdAt']) ?? fallbackTime;
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
              messageIdMap[sourceMessageId] ?? legacyId(sourceMessageId),
            );
          }

          final isActiveList = listIndex == activeIndex;
          final represented = isListAlreadyMaterialized(pivotId, listIds);
          final shouldCreateBranch =
              !isActiveList || (!represented && listIds.isNotEmpty);
          String? branchId;
          if (shouldCreateBranch) {
            final listId = (list['id'] ?? '$listIndex').toString().trim();
            branchId = legacyId('fork_${pivotId}_$listId');
            if (!branches.containsKey(branchId)) {
              var parentId = pivotId;
              String? tipId;
              for (var index = 0; index < listMessages.length; index++) {
                final messageMap = listMessages[index];
                final messageId = listIds[index];
                var message = byId[messageId];
                if (message == null) {
                  message = convertForkMessage(
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
          // Chatbox writes a position for linear records as well.  A
          // selection is meaningful only when the archive contains multiple
          // candidate lists; otherwise remembering the current continuation
          // creates stale selections on the imported tree.
          if (listsRaw.length > 1 &&
              (directChildCount > 1 ||
                  selectedBranch.tipMessageId == pivotId)) {
            branchSelections[pivotId] = selectedBranchId;
          }
        }
        handledPivots.add(sourcePivotId);
        changed = true;
      }
    }

    // Re-check selections against the completed edge set. Nested fork
    // materialization can reveal that a previously selected pivot is only a
    // shared linear prefix, so it must not be persisted as a fork selection.
    final normalizedSelections = <String, String>{};
    for (final entry in branchSelections.entries) {
      final branch = branches[entry.value];
      if (branch == null || branch.tipMessageId == null) continue;
      final path = <String>[];
      final visited = <String>{};
      String? cursor = branch.tipMessageId;
      while (cursor != null && visited.add(cursor)) {
        final edge = edges[cursor];
        if (edge == null) {
          path.clear();
          break;
        }
        path.add(cursor);
        cursor = edge.parentMessageId;
      }
      if (path.isEmpty && branch.tipMessageId != null) continue;
      final orderedPath = path.reversed.toList(growable: false);
      final index = orderedPath.indexOf(entry.key);
      if (index < 0) continue;
      final directChildren = edges.values
          .where((edge) => edge.parentMessageId == entry.key)
          .map((edge) => edge.messageId)
          .toSet();
      if (index + 1 >= orderedPath.length || directChildren.length >= 2) {
        normalizedSelections[entry.key] = entry.value;
      }
    }

    return (
      messages: messages,
      tree: ConversationTree(
        conversationId: conversationId,
        activeBranchId: rootBranchId,
        branches: branches,
        edges: edges,
        branchSelections: normalizedSelections,
      ),
    );
  }

  static ChatMessage? convertForkMessage(
    Map<String, dynamic> msg, {
    required String conversationId,
    required Map<String, String> messageIdMap,
    required DateTime fallbackTime,
    required Map<String, String> providerIdMap,
  }) {
    final sourceMessageId = (msg['id'] ?? '').toString().trim();
    if (sourceMessageId.isEmpty) return null;
    final messageId = messageIdMap[sourceMessageId] ??= legacyId(
      sourceMessageId,
    );
    final roleRaw = (msg['role'] ?? '').toString();
    final parts = extractMessageParts(msg, roleHint: roleRaw);
    final content = textFromParts(parts);
    final timestamp = parseMessageTimestamp(msg['timestamp']) ?? fallbackTime;
    if (roleRaw == 'tool') {
      final toolPayload = buildToolMessagePayload(msg, fallbackText: content);
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
              chatboxImportedProviderId(sourceProviderId);
    return ChatMessage(
      id: messageId,
      role: role,
      parts: parts.isEmpty ? const <MessagePart>[TextPart('')] : parts,
      timestamp: timestamp,
      modelId: inferModelIdFromChatboxMessage(msg).trim().isEmpty
          ? null
          : inferModelIdFromChatboxMessage(msg),
      providerId: providerId,
      totalTokens:
          (msg['tokenCount'] as num?)?.toInt() ??
          (msg['tokensUsed'] as num?)?.toInt(),
      conversationId: conversationId,
      reasoningText: reasoningTexts.isEmpty ? null : reasoningTexts.join('\n'),
    );
  }

  static String extractDefaultPrompt(Map<String, dynamic> root) {
    final settings = root['settings'];
    if (settings is Map) {
      final p = (settings['defaultPrompt'] ?? '').toString();
      if (p.trim().isNotEmpty) return p;
    }
    return '';
  }

  static String extractSystemPromptFromSession(
    Map<String, dynamic> session, {
    required String fallback,
  }) {
    final msgs = session['messages'];
    if (msgs is List) {
      for (final raw in msgs) {
        if (raw is! Map) continue;
        final m = raw.map((k, v) => MapEntry(k.toString(), v));
        if ((m['role'] ?? '').toString() != 'system') continue;
        final content = textFromParts(
          extractMessageParts(m, roleHint: 'system'),
        );
        if (content.trim().isNotEmpty) return content;
      }
    }
    return fallback;
  }

  static int? extractThinkingBudget(Map<String, dynamic> sessionSettings) {
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

  static DateTime? parseIsoDateTime(String raw) {
    try {
      if (raw.trim().isEmpty) return null;
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  static DateTime? parseEpochMillis(dynamic raw) {
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

  static DateTime? parseMessageTimestamp(dynamic raw) {
    return parseEpochMillis(raw);
  }

  static String textFromParts(List<MessagePart> parts) {
    return parts
        .whereType<TextPart>()
        .map((part) => part.text)
        .join('\n')
        .trim();
  }

  static List<MessagePart> extractMessageParts(
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
            // 新版 ZIP 归档会把资源字节落盘并改写成本地受管 URI，
            // 这类条目内容已随包带来，不是“只有引用”的旧版条目。
            final localResource = part['chatboxLocalResource'] == true;
            final isResolvable =
                localResource ||
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
                      !localResource &&
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

  static String inferModelIdFromChatboxMessage(Map<String, dynamic> msg) {
    final raw = (msg['model'] ?? '').toString().trim();
    if (raw.isEmpty) return '';
    final m = RegExp(r'\(([^)]+)\)\s*$').firstMatch(raw);
    if (m != null) return (m.group(1) ?? '').trim();
    return raw;
  }

  static String buildToolMessagePayload(
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

  static String chatboxImportedProviderId(String sourceId) {
    return legacyId('provider_$sourceId');
  }
}
