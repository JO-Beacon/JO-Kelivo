import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/database/chat_database_repository.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/instruction_injection.dart';
import '../../../core/models/memory_entry.dart';
import '../../../core/models/world_book.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/document_text_extractor.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../core/services/chat/prompt_transformer.dart';
import '../../../core/services/logging/context_log_models.dart';
import '../../../core/services/logging/context_logger.dart';
import '../../../core/services/memory/memory_block_builder.dart';
import '../../../core/services/memory/memory_prompts.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../utils/assistant_regex.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import 'ocr_service.dart';

/// §7.6 记忆前缀解析结果。
typedef MemoryPrefixResolution = ({
  String prefix,
  String? hash,
  String? snapshotKind,
});

/// 同一次请求中组装的消息共享的记忆注入状态。
///
/// 持久化会话可以从数据库读回所有这些信息，但临时会话从不写入数据库，
/// 因此如果没有按次请求作用域记录，每条消息看起来都会像第一条，
/// 并重复注入同一快照。
class MemoryInjectionPass {
  /// 本次请求中收到记忆块的修订 ID。
  final Set<String> snapshotCarriers = <String>{};

  /// 本次请求中最近注入的哈希（如有）。
  String? get injectedHash => _injectedHash;
  String? _injectedHash;

  /// [injectedHash] 是否已设置，用于区分“尚未设置”
  /// 和合法的 null 哈希。
  bool get hasInjectedHash => _hasInjectedHash;
  bool _hasInjectedHash = false;

  void recordInjectedHash(String? hash) {
    _injectedHash = hash;
    _hasInjectedHash = true;
  }
}

/// 从会话状态构建 API 消息的服务。
///
/// 此服务负责：
/// - 从聊天历史构建 API 消息列表
/// - 处理用户消息（文档、OCR、模板）
/// - 注入系统提示词
/// - 注入记忆和近期聊天上下文
/// - 注入搜索提示词
/// - 注入指令提示词
/// - 应用上下文限制
/// - 为模型上下文内联本地图片
class MessageBuilderService {
  static const String internalMediaPathsKey = multimodalInternalMediaPathsKey;
  static const String internalRevisionIdKey = multimodalInternalRevisionIdKey;

  MessageBuilderService({
    required this.chatService,
    required this.contextProvider,
    this.chatRepository,
    this.ocrHandler,
    this.ocrPrefetch,
    this.geminiThoughtSignatureHandler,
  });

  final ChatService chatService;

  /// `promptContent` 冻结和 §7.6 注入的可选覆盖。
  /// 为 null 时回退到 [ChatService.chatRepositoryOrNull]。
  final ChatDatabaseRepository? chatRepository;

  ChatDatabaseRepository? get _repo =>
      chatRepository ?? chatService.chatRepositoryOrNull;

  /// 构建上下文（用于通过 context.read 访问提供器）
  final BuildContext contextProvider;

  /// 处理图片的 OCR 处理器（可选，从 home_page 注入）
  final Future<String?> Function(
    List<String> imagePaths, {
    String? revisionId,
    OcrPrepareSession? session,
  })?
  ocrHandler;

  /// 逐消息处理前对持久化 OCR 的可选批量预取。
  final Future<OcrPrepareSession> Function({
    required List<String> revisionIds,
    required List<String> imagePaths,
  })?
  ocrPrefetch;

  /// OCR 文本包装函数
  String Function(String ocrText)? ocrTextWrapper;

  /// 为 API 调用追加 Gemini 思考签名的处理器
  final String Function(ChatMessage message, String content)?
  geminiThoughtSignatureHandler;

  /// 文档文本提取缓存，避免每条消息都重新读取文件。
  /// 按路径索引，通过（修改时间 + 大小）校验以避免复用过期数据。
  final Map<String, _DocTextCacheEntry> _docTextCache =
      <String, _DocTextCacheEntry>{};

  /// 折叠消息版本，每组只显示已选版本。
  List<ChatMessage> collapseVersions(
    List<ChatMessage> items,
    Map<String, int> versionSelections,
  ) {
    final Map<String, List<ChatMessage>> byGroup =
        <String, List<ChatMessage>>{};
    final List<String> order = <String>[];

    for (final m in items) {
      final gid = (m.groupId ?? m.id);
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }

    // 按版本对每个组排序
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }

    // 从每个组中选择合适的版本
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = versionSelections[gid];
      ChatMessage? selected;
      if (sel != null) {
        for (final candidate in vers) {
          if (candidate.version == sel) {
            selected = candidate;
            break;
          }
        }
      }
      out.add(selected ?? vers.last);
    }

    return out;
  }

  /// 从当前会话状态构建 API 消息列表。
  ///
  /// 应用截断。调用方必须传入当前消息树活动路径；附件来自消息部分。
  List<Map<String, dynamic>> buildApiMessages({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    bool includeToolMessages = false,
  }) {
    final tIndex = currentConversation?.truncateIndex ?? -1;
    final List<ChatMessage> sourceAll =
        (tIndex >= 0 && tIndex <= messages.length)
        ? messages.sublist(tIndex)
        : List.of(messages);
    // 版本选择已由 ConversationTree.activePath() 完成。这里不能再按
    // groupId/version 折叠，否则会把树上的兄弟节点重新混入上下文。
    final List<ChatMessage> source = sourceAll;

    final out = <Map<String, dynamic>>[];

    for (final m in source) {
      String? assistantReasoningContent;
      dynamic reasoningDetails;
      if (m.role == 'assistant') {
        assistantReasoningContent = _reasoningContentForToolContinuation(m);
        reasoningDetails = _reasoningDetailsForApi(m);
      }
      if (includeToolMessages && m.role == 'assistant') {
        final events = chatService.getToolEvents(m.id);
        if (events.isNotEmpty) {
          // 只有每个调用都有结果后，工具调用历史才有效。
          final hasPendingToolEvent = events.any((e) => e['content'] == null);
          if (!hasPendingToolEvent) {
            final calls = <Map<String, dynamic>>[];
            final toolMessages = <Map<String, dynamic>>[];

            for (int i = 0; i < events.length; i++) {
              final e = events[i];
              final name = (e['name'] ?? '').toString().trim();
              if (name.isEmpty) continue;
              final rawId = (e['id'] ?? '').toString().trim();
              final id = rawId.isNotEmpty
                  ? rawId
                  : 'call_${m.id.substring(0, m.id.length < 8 ? m.id.length : 8)}_$i';

              Map<String, dynamic> args = const <String, dynamic>{};
              final a = e['arguments'];
              if (a is Map) {
                args = a.map((k, v) => MapEntry(k.toString(), v));
              }
              String argumentsJson = '{}';
              try {
                argumentsJson = jsonEncode(args);
              } catch (_) {}

              calls.add({
                'id': id,
                'type': 'function',
                'function': {'name': name, 'arguments': argumentsJson},
                if (e['metadata'] is Map)
                  'metadata': (e['metadata'] as Map).cast<String, dynamic>(),
              });

              final c = e['content'];
              toolMessages.add({
                'role': 'tool',
                'name': name,
                'tool_call_id': id,
                'content': c.toString(),
                if (e['metadata'] is Map)
                  'metadata': (e['metadata'] as Map).cast<String, dynamic>(),
              });
            }

            if (calls.isNotEmpty) {
              final assistantToolMessage = <String, dynamic>{
                'role': 'assistant',
                'content': '\n\n',
                'tool_calls': calls,
              };
              if (assistantReasoningContent?.isNotEmpty == true) {
                assistantToolMessage['reasoning_content'] =
                    assistantReasoningContent;
              }
              // 持久化的 reasoning_details 属于此消息的最后一轮；
              // 如果也把它们附加到这条合成的工具前助手消息，就会重复
              // 回放同一段推理，而 OpenRouter/Anthropic 会拒绝。
              // 只有下方最终助手消息才携带它们。
              if (ContextLogger.enabled) {
                ContextSegmentTags.replaceWithSingle(
                  assistantToolMessage,
                  source: ContextSource.toolCall,
                  length: (assistantToolMessage['content'] ?? '')
                      .toString()
                      .length,
                );
                for (final toolMessage in toolMessages) {
                  ContextSegmentTags.replaceWithSingle(
                    toolMessage,
                    source: ContextSource.toolResult,
                    length: (toolMessage['content'] ?? '').toString().length,
                  );
                }
              }
              out.add(assistantToolMessage);
              out.addAll(toolMessages);
            }
          }
        }
      }

      var content = m.content;
      if (m.role == 'assistant' && geminiThoughtSignatureHandler != null) {
        content = geminiThoughtSignatureHandler!(m, content);
      }
      final mediaRefs = mediaRefsFromParts(m);
      // 纯附件轮次的文本内容为空，但仍必须发送。
      // 文档 FilePart 不包含在 mediaRefs 中（它们通过文档提取传输），
      // 因此还要保留仍包含可用 ImagePart/FilePart 的消息，
      // 供 processUserMessagesForApi 注入文本。
      if (content.isEmpty &&
          mediaRefs.isEmpty &&
          !_hasUsableAttachmentPart(m)) {
        continue;
      }
      final role = m.role == 'assistant' ? 'assistant' : 'user';
      final message = <String, dynamic>{'role': role, 'content': content};
      if (role == 'user') {
        message[internalRevisionIdKey] = m.id;
      }
      if (mediaRefs.isNotEmpty) {
        message[internalMediaPathsKey] = mediaRefs;
      }
      if (assistantReasoningContent?.isNotEmpty == true) {
        message['reasoning_content'] = assistantReasoningContent;
      }
      if (reasoningDetails != null) {
        message['reasoning_details'] = reasoningDetails;
      }
      if (ContextLogger.enabled) {
        ContextSegmentTags.replaceWithSingle(
          message,
          source: ContextSource.chatHistory,
          length: content.length,
        );
      }
      out.add(message);
    }

    return out;
  }

  /// 从图片/文件部分收集结构化 `_kelivo_media_paths` 条目。
  ///
  /// 跳过不可用部分。文档（非媒体）FilePart 会被省略，
  /// 因为它们通过文档提取传输，而不是媒体路径附件。
  static List<Map<String, dynamic>> mediaRefsFromParts(ChatMessage message) {
    final refs = <Map<String, dynamic>>[];
    for (final part in message.parts) {
      if (part is ImagePart) {
        if (part.unavailable) continue;
        final uri = part.uri.trim();
        if (uri.isEmpty) continue;
        refs.add(encodeInternalMediaRef(uri: uri, mime: part.mime));
      } else if (part is FilePart) {
        if (part.unavailable) continue;
        final uri = part.uri.trim();
        if (uri.isEmpty) continue;
        final effectiveMime = resolveMediaAttachmentMime(
          explicitMime: part.mime ?? '',
          fileName: part.name,
          path: uri,
        );
        if (!(isImageMime(effectiveMime) ||
            isAudioMime(effectiveMime) ||
            isVideoMime(effectiveMime))) {
          continue;
        }
        // 优先使用已解析的媒体 MIME，而不是部分上存储的
        // application/octet-stream 等过期通用类型。
        refs.add(
          encodeInternalMediaRef(
            uri: uri,
            mime: effectiveMime.isEmpty ? null : effectiveMime,
          ),
        );
      }
    }
    return refs;
  }

  /// 当消息仍有非不可用的图片/文件附件且即使没有媒体引用也应
  /// 保留到 API 准备阶段时为 true。
  static bool _hasUsableAttachmentPart(ChatMessage message) {
    for (final part in message.parts) {
      if (part is ImagePart && !part.unavailable) {
        if (part.uri.trim().isNotEmpty) return true;
      } else if (part is FilePart && !part.unavailable) {
        if (part.uri.trim().isNotEmpty) return true;
      }
    }
    return false;
  }

  /// 在供应商请求前移除内部键。
  void stripInternalRevisionIds(List<Map<String, dynamic>> apiMessages) {
    for (final message in apiMessages) {
      message.remove(internalRevisionIdKey);
      message.remove(kelivoContextSegmentsKey);
    }
  }

  void _tagFrozenUserPrompt(
    Map<String, dynamic> message, {
    required String payload,
    required bool carriesMemorySnapshot,
  }) {
    if (!carriesMemorySnapshot) {
      ContextSegmentTags.replaceWithSingle(
        message,
        source: ContextSource.chatHistory,
        length: payload.length,
      );
      return;
    }
    final split = MemoryBlockBuilder.splitInjectedPrefix(payload);
    if (split != null && split.rest.isNotEmpty) {
      ContextSegmentTags.write(message, [
        ContextSegmentTags.item(
          source: ContextSource.memorySnapshot,
          length: split.prefix.length,
          meta: {'kind': split.kind},
        ),
        ContextSegmentTags.item(
          source: ContextSource.chatHistory,
          length: split.rest.length,
        ),
      ]);
      return;
    }
    ContextSegmentTags.replaceWithSingle(
      message,
      source: ContextSource.memorySnapshot,
      length: payload.length,
    );
  }

  ChatMessage? _latestPersistedMessage(ChatMessage message) {
    final persisted = chatService.getMessages(message.conversationId);
    for (final candidate in persisted) {
      if (candidate.id == message.id) return candidate;
    }
    return null;
  }

  String _reasoningContentForToolContinuation(ChatMessage message) {
    String pick(ChatMessage candidate) {
      final direct = (candidate.reasoningText ?? '').trim();
      if (direct.isNotEmpty) return direct;

      final raw = (candidate.reasoningSegmentsJson ?? '').trim();
      if (raw.isEmpty) return '';
      try {
        final decoded = jsonDecode(raw);
        final segmentsRaw = switch (decoded) {
          Map<String, dynamic> map => map['segments'],
          List<dynamic> list => list,
          _ => null,
        };
        if (segmentsRaw is! List) return '';
        final parts = <String>[];
        for (final item in segmentsRaw) {
          if (item is! Map) continue;
          final text = (item['text'] ?? '').toString().trim();
          if (text.isNotEmpty) parts.add(text);
        }
        return parts.join('\n').trim();
      } catch (_) {
        return '';
      }
    }

    final fromMessage = pick(message);
    if (fromMessage.isNotEmpty) return fromMessage;

    final persisted = _latestPersistedMessage(message);
    if (persisted == null) return '';
    return pick(persisted);
  }

  /// 提取持久化的供应商推理详情（OpenRouter 风格 `reasoning_details`，
  /// 可能携带思考签名），以便在后续轮次回传给供应商。
  dynamic _reasoningDetailsForApi(ChatMessage message) {
    dynamic pick(ChatMessage candidate) {
      final raw = (candidate.reasoningSegmentsJson ?? '').trim();
      if (raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return null;
        final details = decoded['reasoningDetails'];
        if (details is List && details.isNotEmpty) return details;
      } catch (_) {}
      return null;
    }

    final fromMessage = pick(message);
    if (fromMessage != null) return fromMessage;

    final persisted = _latestPersistedMessage(message);
    if (persisted == null) return null;
    return pick(persisted);
  }

  /// 从结构化 [ChatMessage.parts] 解析附件。
  ///
  /// 这是 API 请求构建的仅部分约定。此处不执行内容标记解码，
  /// 迁移逻辑通过旧解码器负责该任务。
  ChatInputData parseInputFromMessage(
    ChatMessage message, {
    bool includeMediaFilePathsAsImages = true,
  }) {
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    final textParts = <String>[];
    for (final part in message.parts) {
      if (part is TextPart) {
        textParts.add(part.text);
      } else if (part is ImagePart) {
        // 不可用部分仍保留在持久化历史中用于 UI 占位，
        // 但不得进入 API 媒体路径。
        if (part.unavailable) continue;
        final uri = part.uri.trim();
        if (uri.isNotEmpty) images.add(uri);
      } else if (part is FilePart) {
        if (part.unavailable) continue;
        final doc = DocumentAttachment(
          path: part.uri,
          fileName: part.name,
          mime: part.mime ?? '',
        );
        docs.add(doc);
        final effectiveMime = _effectiveAttachmentMime(doc);
        if (includeMediaFilePathsAsImages &&
            (isImageMime(effectiveMime) ||
                isVideoMime(effectiveMime) ||
                isAudioMime(effectiveMime)) &&
            part.uri.trim().isNotEmpty) {
          images.add(part.uri.trim());
        }
      }
    }
    return ChatInputData(
      text: textParts.join().trim(),
      imagePaths: images,
      documents: docs,
    );
  }

  /// 当没有 [ChatMessage] 可用时，从 API 映射构建 [ChatInputData]。
  ///
  /// 仅使用内容文本和 [internalMediaPathsKey]，不执行标记解码。
  ChatInputData parseInputFromApiMap(
    Map<String, dynamic> message, {
    bool includeMediaFilePathsAsImages = true,
  }) {
    final text = (message['content'] ?? '').toString();
    final mediaRefs = parseInternalMediaRefs(message[internalMediaPathsKey]);
    final mediaPaths = [for (final ref in mediaRefs) ref.uri];
    if (!includeMediaFilePathsAsImages) {
      return ChatInputData(text: text.trim(), imagePaths: mediaPaths);
    }
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    for (final ref in mediaRefs) {
      final path = ref.uri;
      final mime = (ref.mime != null && ref.mime!.trim().isNotEmpty)
          ? ref.mime!.trim()
          : inferMediaMimeFromSource(path);
      if (isAudioMime(mime) || isVideoMime(mime)) {
        final name = path.split(RegExp(r'[\\/]')).last;
        docs.add(
          DocumentAttachment(
            path: path,
            fileName: name.isEmpty ? 'file' : name,
            mime: mime,
          ),
        );
        images.add(path);
      } else {
        images.add(path);
      }
    }
    return ChatInputData(
      text: text.trim(),
      imagePaths: images,
      documents: docs,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  /// 处理 apiMessages 中的用户消息：优先使用已冻结的 `promptContent`，
  /// 否则组装（文档/OCR → 记忆前缀 → 模板 → 时间）并冻结（§8）。
  ///
  /// 返回最后一条用户消息的图片路径（用于 API 调用）。
  Future<List<String>> processUserMessagesForApi(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant, {
    Conversation? conversation,
    List<ChatMessage>? sourceMessages,
  }) async {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    List<String>? lastUserImagePaths;

    // 只有真实持久化用户消息才携带内部修订 ID。
    // WorldBook 背景也可能使用 role=user，不得被当作聊天输入。
    bool isPersistedUserMessage(Map<String, dynamic> message) {
      if (message['role'] != 'user') return false;
      return (message[internalRevisionIdKey] ?? '')
          .toString()
          .trim()
          .isNotEmpty;
    }

    // 查找最后一条真实用户消息索引（跳过注入的背景设定）。
    int lastUserIdx = -1;
    for (int i = apiMessages.length - 1; i >= 0; i--) {
      if (isPersistedUserMessage(apiMessages[i])) {
        lastUserIdx = i;
        break;
      }
    }

    final persistedRevisionIds = <String>[
      for (final message in apiMessages)
        if (isPersistedUserMessage(message))
          (message[internalRevisionIdKey] ?? '').toString().trim(),
    ];
    final frozenPrompts = _repo == null
        ? null
        : await _repo!.getMessagePrompts(persistedRevisionIds);

    // 只为仍需生成（尚未冻结）的消息预取 OCR。
    OcrPrepareSession? ocrSession;
    if (ocrActive && ocrPrefetch != null) {
      final revisionIds = <String>[];
      final allImagePaths = <String>{};
      for (final message in apiMessages) {
        if (!isPersistedUserMessage(message)) continue;
        final revisionId = (message[internalRevisionIdKey] ?? '')
            .toString()
            .trim();
        if (frozenPrompts?.containsKey(revisionId) ?? false) continue;
        final revisionForParse = revisionId;
        final chatForParse = _resolveChatMessage(
          revisionId: revisionForParse,
          conversation: conversation,
          sourceMessages: sourceMessages,
        );
        final parsedUser = chatForParse != null
            ? parseInputFromMessage(chatForParse)
            : parseInputFromApiMap(message);
        final videoPaths = <String>{
          for (final d in parsedUser.documents)
            if (isVideoMime(_effectiveAttachmentMime(d))) d.path.trim(),
        }..removeWhere((p) => p.isEmpty);
        final audioPaths = <String>{
          for (final d in parsedUser.documents)
            if (isAudioMime(_effectiveAttachmentMime(d))) d.path.trim(),
        }..removeWhere((p) => p.isEmpty);
        final ocrTargets = parsedUser.imagePaths
            .map((p) => p.trim())
            .where(
              (p) =>
                  p.isNotEmpty &&
                  !videoPaths.contains(p) &&
                  !audioPaths.contains(p),
            )
            .toSet();
        if (ocrTargets.isEmpty) continue;
        if (revisionId.isNotEmpty) revisionIds.add(revisionId);
        allImagePaths.addAll(ocrTargets);
      }
      if (allImagePaths.isNotEmpty) {
        try {
          ocrSession = await ocrPrefetch!(
            revisionIds: revisionIds,
            imagePaths: allImagePaths.toList(growable: false),
          );
        } catch (_) {
          ocrSession = null;
        }
      }
    }

    Future<String?> readDocument(DocumentAttachment d) async {
      // 只解析一次，使缓存键和提取器共享同一绝对路径。
      // null 表示被拒绝（UNC/SMB），绝不回退到原始路径。
      final resolvedPath = SandboxPathResolver.resolveForIo(d.path);
      if (resolvedPath == null) return null;
      // 使用文件状态检测内容变化，避免哈希计算。
      FileStat? stat;
      try {
        stat = await File(resolvedPath).stat();
      } catch (_) {
        stat = null;
      }
      if (stat != null) {
        final cached = _docTextCache[resolvedPath];
        if (cached != null &&
            cached.modifiedMs == stat.modified.millisecondsSinceEpoch &&
            cached.size == stat.size) {
          return cached.text;
        }
      }
      try {
        final text = await DocumentTextExtractor.extractResolved(
          path: resolvedPath,
          mime: d.mime,
        );
        // 仅在有文件状态时缓存；否则避免过期数据。
        if (stat != null) {
          _docTextCache[resolvedPath] = _DocTextCacheEntry(
            text: text,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
        }
        return text;
      } catch (_) {
        if (stat != null) {
          _docTextCache[resolvedPath] = _DocTextCacheEntry(
            text: null,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
        }
        return null;
      }
    }

    final injectionPass = MemoryInjectionPass();

    for (int i = 0; i < apiMessages.length; i++) {
      if (!isPersistedUserMessage(apiMessages[i])) continue;
      final revisionId = (apiMessages[i][internalRevisionIdKey] ?? '')
          .toString()
          .trim();
      final chatMessageForParts = _resolveChatMessage(
        revisionId: revisionId,
        conversation: conversation,
        sourceMessages: sourceMessages,
      );
      final parsedUser = chatMessageForParts != null
          ? parseInputFromMessage(chatMessageForParts)
          : parseInputFromApiMap(apiMessages[i]);
      final videoPaths = <String>{
        for (final d in parsedUser.documents)
          if (isVideoMime(_effectiveAttachmentMime(d))) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);
      final audioPaths = <String>{
        for (final d in parsedUser.documents)
          if (isAudioMime(_effectiveAttachmentMime(d))) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);

      final mimeByPath = <String, String>{};
      if (chatMessageForParts != null) {
        for (final part in chatMessageForParts.parts) {
          if (part is ImagePart) {
            if (part.unavailable) continue;
            final uri = part.uri.trim();
            if (uri.isEmpty) continue;
            // 优先使用已解析的媒体 MIME，而不是部分上存储的
            // application/octet-stream 等过期通用类型。
            final fileName = uri.split(RegExp(r'[\\/]')).last;
            final effectiveMime = resolveMediaAttachmentMime(
              explicitMime: part.mime ?? '',
              fileName: fileName.isEmpty ? uri : fileName,
              path: uri,
            );
            if (effectiveMime.isNotEmpty) mimeByPath[uri] = effectiveMime;
          } else if (part is FilePart) {
            if (part.unavailable) continue;
            final uri = part.uri.trim();
            if (uri.isEmpty) continue;
            final effectiveMime = _effectiveAttachmentMime(
              DocumentAttachment(
                path: uri,
                fileName: part.name,
                mime: part.mime ?? '',
              ),
            );
            if (effectiveMime.isNotEmpty) mimeByPath[uri] = effectiveMime;
          }
        }
      } else {
        for (final ref in parseInternalMediaRefs(
          apiMessages[i][internalMediaPathsKey],
        )) {
          final uri = ref.uri.trim();
          if (uri.isEmpty) continue;
          final fileName = uri.split(RegExp(r'[\\/]')).last;
          final effectiveMime = resolveMediaAttachmentMime(
            explicitMime: ref.mime ?? '',
            fileName: fileName.isEmpty ? uri : fileName,
            path: uri,
          );
          if (effectiveMime.isNotEmpty) mimeByPath[uri] = effectiveMime;
        }
        for (final d in parsedUser.documents) {
          final path = d.path.trim();
          final mime = _effectiveAttachmentMime(d);
          if (path.isNotEmpty && mime.isNotEmpty) {
            mimeByPath.putIfAbsent(path, () => mime);
          }
        }
      }

      final messageMediaPaths = <Map<String, dynamic>>[];
      final seenPaths = <String>{};
      for (final rawPath in parsedUser.imagePaths) {
        final path = rawPath.trim();
        if (path.isEmpty || !seenPaths.add(path)) continue;
        if (ocrActive &&
            !videoPaths.contains(path) &&
            !audioPaths.contains(path)) {
          continue;
        }
        final mime = mimeByPath[path];
        messageMediaPaths.add(encodeInternalMediaRef(uri: path, mime: mime));
      }
      if (messageMediaPaths.isEmpty) {
        apiMessages[i].remove(internalMediaPathsKey);
      } else {
        apiMessages[i][internalMediaPathsKey] = messageMediaPaths;
      }

      // 从最后一条用户消息（从各部分）捕获图片路径。
      if (i == lastUserIdx &&
          lastUserImagePaths == null &&
          parsedUser.imagePaths.isNotEmpty) {
        lastUserImagePaths = List<String>.of(parsedUser.imagePaths);
      }

      // 优先使用已冻结的 promptContent，绝不重新计算（§8.3）。
      final existing = frozenPrompts?[revisionId];
      if (existing != null) {
        final sendPayload = _legacyAwareFrozenPayload(
          payload: existing.payload,
          carriesMemorySnapshot: existing.carriesMemorySnapshot,
          settings: settings,
        );
        apiMessages[i]['content'] = sendPayload;
        if (ContextLogger.enabled) {
          _tagFrozenUserPrompt(
            apiMessages[i],
            payload: sendPayload,
            carriesMemorySnapshot:
                existing.carriesMemorySnapshot &&
                sendPayload == existing.payload,
          );
        }
        continue;
      }

      // 发送时对用户文本应用仅替换型正则表达式。
      final replacedUserText = applyAssistantRegexes(
        parsedUser.text,
        assistant: assistant,
        scope: AssistantRegexScope.user,
        target: AssistantRegexTransformTarget.send,
      );

      // 附件通过 internalMediaPathsKey / lastUserImagePaths 传输，
      // 绝不把旧版附件标记重新嵌入内容。
      final cleanedUser = replacedUserText.trim();

      final filePrompts = StringBuffer();
      for (final d in parsedUser.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        if (isVideoMime(effectiveMime) || isAudioMime(effectiveMime)) {
          continue;
        }
        final text = await readDocument(d);
        if (text == null || text.trim().isEmpty) continue;
        filePrompts.writeln('## user sent a file: ${d.fileName}');
        filePrompts.writeln('<content>');
        filePrompts.writeln('```');
        filePrompts.writeln(text);
        filePrompts.writeln('```');
        filePrompts.writeln('</content>');
        filePrompts.writeln();
      }

      String merged = (filePrompts.toString() + cleanedUser).trim();
      var canFreezePrompt = true;

      if (ocrActive && ocrHandler != null) {
        final ocrTargets = parsedUser.imagePaths
            .map((p) => p.trim())
            .where(
              (p) =>
                  p.isNotEmpty &&
                  !videoPaths.contains(p) &&
                  !audioPaths.contains(p),
            )
            .toSet()
            .toList();
        if (ocrTargets.isNotEmpty) {
          final ocrText = await ocrHandler!(
            ocrTargets,
            revisionId: revisionId.isEmpty ? null : revisionId,
            session: ocrSession,
          );
          if (ocrText == null) {
            canFreezePrompt = false;
          } else if (ocrText.trim().isNotEmpty) {
            final wrapped = ocrTextWrapper != null
                ? ocrTextWrapper!(ocrText)
                : _defaultWrapOcrBlock(ocrText);
            merged = (wrapped + merged).trim();
          }
        }
      }

      final processedBody = merged.isEmpty ? cleanedUser : merged;
      final chatMessage = _resolveChatMessage(
        revisionId: revisionId,
        conversation: conversation,
        sourceMessages: sourceMessages,
      );

      if (conversation != null && chatMessage != null) {
        apiMessages[i]['content'] = await resolvePromptContent(
          message: chatMessage,
          processedUserBody: processedBody,
          assistant: assistant,
          conversation: conversation,
          settings: settings,
          apiMessages: apiMessages,
          pass: injectionPass,
          readFrozenPrompt: false,
          freezePrompt: canFreezePrompt,
        );
      } else {
        // 没有会话或没有匹配的已存储消息：没有可冻结对象，
        // 因此渲染模板时不带记忆前缀。
        final templ =
            (assistant?.messageTemplate ?? '{{ message }}').trim().isEmpty
            ? '{{ message }}'
            : (assistant?.messageTemplate ?? '{{ message }}');
        final now = chatMessage?.timestamp ?? DateTime.now();
        var content = PromptTransformer.applyMessageTemplate(
          templ,
          role: 'user',
          message: processedBody,
          now: now,
        );
        if (assistant?.appendCurrentTimeToUserMessage == true) {
          content = '$content\n\n${MemoryPrompts.formatCurrentTimeTag(now)}';
        }
        apiMessages[i]['content'] = content;
      }
    }

    return lastUserImagePaths ?? <String>[];
  }

  /// API 负载背后的已存储消息；无法找到时为 null。
  ///
  /// [sourceMessages] 是本次请求 API 负载所基于的列表，会先被检查。
  /// `ChatService.getMessages` 只服务已在其缓存中的会话，
  /// 因此新创建的会话会返回空结果，新消息会静默跳过记忆注入和冻结，
  /// 随后在下一轮才补上，从而重写历史并丢失提示词缓存。
  ///
  /// 合成替代对象必须虚构时间戳，冻结它会将错误的 `{{ time }}`
  /// 永久写入提示词，因此真正未命中时返回 null 并留在未冻结渲染路径。
  ChatMessage? _resolveChatMessage({
    required String revisionId,
    required Conversation? conversation,
    required List<ChatMessage>? sourceMessages,
  }) {
    if (revisionId.isEmpty) return null;
    // 即使 Conversation 不存在也优先使用请求的源消息；
    // 否则结构化 ImagePart/FilePart 附件会被丢弃，
    // 调用方会静默回退到仅内容解析。
    if (sourceMessages != null) {
      for (final candidate in sourceMessages) {
        if (candidate.id == revisionId) return candidate;
      }
    }
    if (conversation == null) return null;
    for (final candidate in chatService.getMessages(conversation.id)) {
      if (candidate.id == revisionId) return candidate;
    }
    return null;
  }

  /// §8.3 不可变性约定：返回已冻结负载，或组装并冻结。
  Future<String> resolvePromptContent({
    required ChatMessage message,
    required String processedUserBody,
    required Assistant? assistant,
    required Conversation conversation,
    required SettingsProvider settings,
    required List<Map<String, dynamic>> apiMessages,
    MemoryInjectionPass? pass,
    bool readFrozenPrompt = true,
    bool freezePrompt = true,
  }) async {
    final repo = _repo;
    final persist =
        repo != null &&
        !chatService.isTemporaryConversation(message.conversationId);
    if (persist && readFrozenPrompt) {
      final existing = await repo.getMessagePrompt(message.id);
      if (existing != null) {
        return _legacyAwareFrozenPayload(
          payload: existing.payload,
          carriesMemorySnapshot: existing.carriesMemorySnapshot,
          settings: settings,
        );
      }
    }

    final memory = assistant == null
        ? (prefix: '', hash: null, snapshotKind: null)
        : await resolveMemoryPrefix(
            conversation: conversation,
            assistant: assistant,
            apiMessages: apiMessages,
            currentMessageId: message.id,
            lang: settings.resolvedMemoryPromptLang,
            pass: pass,
            settings: settings,
          );
    if (memory.prefix.isNotEmpty) {
      pass?.snapshotCarriers.add(message.id);
    }

    final templ = (assistant?.messageTemplate ?? '{{ message }}').trim().isEmpty
        ? '{{ message }}'
        : (assistant!.messageTemplate);
    final templated = PromptTransformer.applyMessageTemplate(
      templ,
      role: 'user',
      message: processedUserBody,
      now: message.timestamp,
    );
    final timeSuffix = (assistant?.appendCurrentTimeToUserMessage ?? false)
        ? '\n\n${MemoryPrompts.formatCurrentTimeTag(message.timestamp)}'
        : '';
    final finalContent = '${memory.prefix}$templated$timeSuffix';

    if (ContextLogger.enabled) {
      for (final apiMessage in apiMessages) {
        if ((apiMessage[internalRevisionIdKey] ?? '').toString() !=
            message.id) {
          continue;
        }
        if (memory.prefix.isNotEmpty) {
          final kind = memory.snapshotKind;
          ContextSegmentTags.write(apiMessage, [
            ContextSegmentTags.item(
              source: ContextSource.memorySnapshot,
              length: memory.prefix.length,
              meta: kind == null ? null : {'kind': kind},
            ),
            ContextSegmentTags.item(
              source: ContextSource.chatHistory,
              length: finalContent.length - memory.prefix.length,
            ),
          ]);
        } else {
          ContextSegmentTags.replaceWithSingle(
            apiMessage,
            source: ContextSource.chatHistory,
            length: finalContent.length,
          );
        }
        break;
      }
    }

    // 临时草稿永远不会进入 message_rows；冻结会违反
    // message_prompt_rows 外键。对这些内容仅做内存组装。
    if (persist && freezePrompt) {
      await repo.freezeMessagePrompt(
        revisionId: message.id,
        conversationId: message.conversationId,
        payload: finalContent,
        carriesMemorySnapshot: memory.prefix.isNotEmpty,
        injectedMemoryHash: memory.hash,
      );
    }

    return finalContent;
  }

  bool _legacyMemoryMode(SettingsProvider? settings) {
    try {
      final resolved = settings ?? contextProvider.read<SettingsProvider>();
      return resolved.legacyMemoryMode;
    } catch (_) {
      return false;
    }
  }

  /// 丢弃在新记忆系统开启时冻结进历史的 v2 快照。
  /// 保留已存储的冻结行，使切换回来时仍命中提示词缓存/哈希门控。
  String _legacyAwareFrozenPayload({
    required String payload,
    required bool carriesMemorySnapshot,
    required SettingsProvider settings,
  }) {
    if (!settings.legacyMemoryMode || !carriesMemorySnapshot) return payload;
    return MemoryBlockBuilder.splitInjectedPrefix(payload)?.rest ?? payload;
  }

  /// §7.6 哈希门控 + 自愈。在写入哈希之前先进行比较。
  Future<MemoryPrefixResolution> resolveMemoryPrefix({
    required Conversation conversation,
    required Assistant assistant,
    required List<Map<String, dynamic>> apiMessages,
    required String currentMessageId,
    required MemoryPromptLang lang,
    MemoryInjectionPass? pass,
    SettingsProvider? settings,
  }) async {
    if (_legacyMemoryMode(settings) || !assistant.enableMemory) {
      return (prefix: '', hash: null, snapshotKind: null);
    }

    final repo = _repo;
    if (repo == null) {
      return (prefix: '', hash: null, snapshotKind: null);
    }

    final fields = await repo.readProfileFields();
    final totalByType = await repo.countVisibleMemoriesByType(
      assistantId: assistant.id,
    );
    final hasAnyMemory = totalByType.values.any((count) => count > 0);
    final hasProfile = fields.any((f) => f.value.trim().isNotEmpty);

    final visible = hasAnyMemory
        ? await repo.queryVisibleMemories(assistantId: assistant.id)
        : const <MemoryEntry>[];
    final profileBlock = MemoryBlockBuilder.buildProfileBlock(
      fields: fields,
      lang: lang,
    );
    final memoryBlock = MemoryBlockBuilder.buildMemoryBlock(
      visible: visible,
      totalByType: totalByType,
      lang: lang,
    );

    final currentHash = MemoryBlockBuilder.hashBlocks(
      profileBlock,
      memoryBlock,
    );

    // 自愈逻辑：本次请求中是否有任何历史用户消息携带快照？
    // 在 stripInternalRevisionIds 前读取修订 ID；排除当前正在组装的消息。
    final historyUserIds = <String>[];
    for (final message in apiMessages) {
      if ((message['role'] ?? '').toString() != 'user') continue;
      final revisionId = (message[internalRevisionIdKey] ?? '')
          .toString()
          .trim();
      if (revisionId.isEmpty || revisionId == currentMessageId) continue;
      historyUserIds.add(revisionId);
    }
    final hasSnapshot =
        historyUserIds.any(
          (id) => pass?.snapshotCarriers.contains(id) ?? false,
        ) ||
        await repo.anyPromptCarriesMemorySnapshot(historyUserIds);

    // 没有先前快照时无需清除。然而一旦快照已发送，
    // 全空状态本身就是最新快照。
    if (!hasProfile && !hasAnyMemory && !hasSnapshot) {
      return (prefix: '', hash: null, snapshotKind: null);
    }

    // 关键：在任何写入之前与先前哈希比较（附录 §6）。
    // 先写入会使 currentHash == injectedMemoryHash，
    // 更新分支将永远不可达。
    //
    // 从数据库读取，而不是从 [conversation] 读取：调用方传给我们的是
    // `conversation.copyWith(...)`，且没有任何逻辑会把此列加载回模型，
    // 因此缓存值会永远过期，每一轮看起来都像发生变化。
    //
    // 同一次请求中早先已注入的哈希优先，因为临时会话从不持久化，
    // 否则每条消息都会读到 null，并重复执行相同的更新块。
    final previousHash = pass != null && pass.hasInjectedHash
        ? pass.injectedHash
        : await repo.getConversationInjectedMemoryHash(conversation.id);

    final String prefix;
    final String snapshotKind;
    if (!hasSnapshot) {
      prefix = MemoryBlockBuilder.buildFullSnapshotPrefix(
        profileBlock,
        memoryBlock,
        lang,
      );
      snapshotKind = 'full';
    } else if (currentHash != previousHash) {
      prefix = MemoryBlockBuilder.buildUpdatePrefix(
        profileBlock,
        memoryBlock,
        lang,
      );
      snapshotKind = 'update';
    } else {
      return (prefix: '', hash: null, snapshotKind: null);
    }

    // 哈希通过 freezeMessagePrompt 在与提示词行相同的事务中写入数据库。
    pass?.recordInjectedHash(currentHash);
    return (prefix: prefix, hash: currentHash, snapshotKind: snapshotKind);
  }

  /// 默认 OCR 文本包装函数
  String _defaultWrapOcrBlock(String ocrText) {
    final buf = StringBuffer();
    buf.writeln(
      "The image_file_ocr tag contains a description of an image that the user uploaded to you, not the user's prompt.",
    );
    buf.writeln('<image_file_ocr>');
    buf.writeln(ocrText.trim());
    buf.writeln('</image_file_ocr>');
    buf.writeln();
    return buf.toString();
  }

  /// 将系统提示词注入 apiMessages。
  void injectSystemPrompt(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
    String modelId,
  ) {
    if ((assistant?.systemPrompt.trim().isNotEmpty ?? false)) {
      final vars = PromptTransformer.buildPlaceholders(
        context: contextProvider,
        assistant: assistant!,
        modelId: modelId,
        modelName: modelId,
        userNickname: contextProvider.read<UserProvider>().name,
      );
      final sys = PromptTransformer.replacePlaceholders(
        assistant.systemPrompt,
        vars,
      );
      final sysMessage = <String, dynamic>{'role': 'system', 'content': sys};
      if (ContextLogger.enabled) {
        ContextSegmentTags.replaceWithSingle(
          sysMessage,
          source: ContextSource.systemPrompt,
          length: sys.length,
        );
      }
      apiMessages.insert(0, sysMessage);
    }
  }

  /// 将 §11 记忆规则注入系统消息。
  ///
  /// 这是 `(enableMemory, allowPastConversationRecall, lang, user template)`
  /// 的纯函数，不得随记忆内容或时钟变化（§11.1）。
  /// 其余系统注入的相对顺序由调用方保持：
  /// （`injectSystemPrompt` → 此方法 → `injectSearchPrompt` →
  /// `injectInstructionPrompts` → `injectWorldBookPrompts`）。
  Future<void> injectMemoryAndRecentChats(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant, {
    SettingsProvider? settings,
    String? currentConversationId,
  }) async {
    try {
      if (assistant == null) return;
      if (_legacyMemoryMode(settings)) {
        await _injectLegacyMemoryAndRecentChats(
          apiMessages,
          assistant,
          currentConversationId: currentConversationId,
        );
        return;
      }
      // 这两个开关相互独立：chat_search 仅由 allowPastConversationRecall
      // 注册，因此其规则不能与长期记忆规则一起附加，
      // 否则该工具会缺少指令。
      final wantsMemoryRules = assistant.enableMemory;
      final wantsRecallRules = assistant.allowPastConversationRecall;
      if (!wantsMemoryRules && !wantsRecallRules) return;

      final resolved = settings ?? contextProvider.read<SettingsProvider>();
      final lang = resolved.resolvedMemoryPromptLang;
      final buf = StringBuffer();
      if (wantsMemoryRules) {
        final rules = lang == MemoryPromptLang.zh
            ? resolved.memoryRulesPromptZh
            : resolved.memoryRulesPromptEn;
        buf.write(rules.trim());
      }
      if (wantsRecallRules) {
        if (buf.isNotEmpty) buf.write('\n\n');
        buf.write(MemoryPrompts.rulesPastConversationRecallFor(lang));
      }
      _appendToSystemMessage(
        apiMessages,
        buf.toString(),
        source: ContextSource.memoryRules,
      );
    } catch (_) {}
  }

  Future<void> _injectLegacyMemoryAndRecentChats(
    List<Map<String, dynamic>> apiMessages,
    Assistant assistant, {
    String? currentConversationId,
  }) async {
    if (assistant.enableMemory) {
      final mp = contextProvider.read<MemoryProvider>();
      await mp.initialize();
      final mems = mp.getForAssistant(assistant.id);
      final currentHour = _formatCurrentHour(DateTime.now());
      final buf = StringBuffer();
      buf.writeln('## Memories');
      buf.writeln(
        'These are memories that you can reference in the future conversations.',
      );
      buf.writeln('<memories>');
      for (final m in mems) {
        buf.writeln('<record>');
        buf.writeln('<id>${m.id}</id>');
        buf.writeln('<content>${m.content}</content>');
        buf.writeln('</record>');
      }
      buf.writeln('</memories>');
      buf.writeln('''
## Memory Tool
你是一个无状态的大模型，你无法存储记忆，因此为了记住信息，你需要使用**记忆工具**。
你可以使用 `create_memory`, `edit_memory`, `delete_memory` 工具创建、更新或删除记忆。
- 如果记忆中没有相关信息，请使用 create_memory 创建一条新的记录。
- 如果已有相关记录，请使用 edit_memory 更新内容。
- 若记忆过时或无用，请使用 delete_memory 删除。
这些记忆会自动包含在未来的对话上下文中，在<memories>标签内。
请勿在记忆中存储敏感信息，敏感信息包括：用户的民族、宗教信仰、性取向、政治观点及党派归属、性生活、犯罪记录等。
在与用户聊天过程中，你可以像一个私人秘书一样**主动的**记录用户相关的信息到记忆里，包括但不限于：
- 用户昵称/姓名
- 年龄/性别/兴趣爱好
- 计划事项等
- 聊天风格偏好
- 工作相关
- 首次聊天时间
- ...
请主动调用工具记录，而不是需要用户要求。
记忆如果包含日期信息，请包含在内，请使用绝对时间格式，并且当前时间是$currentHour。
无需告知用户你已更改记忆记录，也不要在对话中直接显示记忆内容，除非用户主动要求。
相似或相关的记忆应合并为一条记录，而不要重复记录，过时记录应删除。
你可以在和用户闲聊的时候暗示用户你能记住东西。
''');
      _appendToSystemMessage(
        apiMessages,
        buf.toString(),
        source: ContextSource.memoryRules,
      );
    }
    if (assistant.allowPastConversationRecall) {
      final chats = chatService.getAllConversations();
      final excludeId =
          currentConversationId ?? chatService.currentConversationId;
      final relevantChats = chats
          .where((c) => c.assistantId == assistant.id && c.id != excludeId)
          .where((c) => c.title.trim().isNotEmpty)
          .take(10)
          .toList();
      if (relevantChats.isNotEmpty) {
        final sb = StringBuffer();
        sb.writeln('<recent_chats>');
        sb.writeln('这是用户最近的一些对话标题和摘要，你可以参考这些内容了解用户偏好和关注点');
        for (final c in relevantChats) {
          sb.writeln('<conversation>');
          // 格式：时间戳: 标题 || 摘要
          final timestamp = c.updatedAt.toIso8601String().substring(0, 10);
          final title = c.title.trim();
          final summary = (c.summary ?? '').trim();
          if (summary.isNotEmpty) {
            sb.writeln('  $timestamp: $title || $summary');
          } else {
            sb.writeln('  $timestamp: $title');
          }
          sb.writeln('</conversation>');
        }
        sb.writeln('</recent_chats>');
        _appendToSystemMessage(
          apiMessages,
          sb.toString(),
          source: ContextSource.memoryRules,
        );
      }
    }
  }

  String _formatCurrentHour(DateTime now) {
    return '${now.year}年${now.month}月${now.day}日的${now.hour}点';
  }

  /// 将搜索工具使用提示词注入 apiMessages。
  void injectSearchPrompt(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant,
    bool hasBuiltInSearch,
  ) {
    if (assistant?.searchEnabled == true && !hasBuiltInSearch) {
      final prompt = SearchToolService.getSystemPrompt();
      _appendToSystemMessage(
        apiMessages,
        prompt,
        source: ContextSource.searchPrompt,
      );
    }
  }

  /// 将指令注入提示词注入 apiMessages。
  Future<void> injectInstructionPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    try {
      List<InstructionInjection> actives = const <InstructionInjection>[];
      try {
        final ip = contextProvider.read<InstructionInjectionProvider>();
        await ip.initialize();
        actives = ip.activesFor(assistantId);
      } catch (_) {}
      final prompts = actives
          .map((e) => e.prompt.trim())
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
      if (prompts.isNotEmpty) {
        final lp = prompts.join('\n\n');
        _appendToSystemMessage(
          apiMessages,
          lp,
          source: ContextSource.instructionInjection,
        );
      }
    } catch (_) {}
  }

  /// 将 WorldBook（世界书）条目注入 apiMessages。
  Future<void> injectWorldBookPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    try {
      List<WorldBook> all = const <WorldBook>[];
      List<String> activeBookIds = const <String>[];

      try {
        final wb = contextProvider.read<WorldBookProvider>();
        await wb.initialize();
        all = wb.books;
        activeBookIds = wb.activeBookIdsFor(assistantId);
      } catch (_) {}

      if (all.isEmpty || activeBookIds.isEmpty) return;

      final activeSet = activeBookIds.toSet();
      final books = all
          .where((b) => b.enabled && activeSet.contains(b.id))
          .toList(growable: false);
      if (books.isEmpty) return;

      String extractContextForDepth(int scanDepth) {
        final depth = scanDepth <= 0 ? 1 : scanDepth;
        final parts = <String>[];
        for (
          int i = apiMessages.length - 1;
          i >= 0 && parts.length < depth;
          i--
        ) {
          final role = (apiMessages[i]['role'] ?? '').toString();
          if (role != 'user' && role != 'assistant') continue;
          final content = (apiMessages[i]['content'] ?? '').toString().trim();
          if (content.isEmpty) continue;
          parts.add(content);
        }
        return parts.reversed.join('\n');
      }

      bool isTriggered(WorldBookEntry entry, String context) {
        if (!entry.enabled) return false;
        if (entry.constantActive) return true;
        if (entry.keywords.isEmpty) return false;

        for (final raw in entry.keywords) {
          final keyword = raw.trim();
          if (keyword.isEmpty) continue;

          if (entry.useRegex) {
            try {
              final re = RegExp(keyword, caseSensitive: entry.caseSensitive);
              if (re.hasMatch(context)) return true;
            } catch (_) {}
          } else {
            if (entry.caseSensitive) {
              if (context.contains(keyword)) return true;
            } else {
              if (context.toLowerCase().contains(keyword.toLowerCase())) {
                return true;
              }
            }
          }
        }
        return false;
      }

      final contextCache = <int, String>{};
      final triggered = <({WorldBookEntry entry, int seq})>[];
      int seq = 0;

      for (final book in books) {
        for (final entry in book.entries) {
          final depth = (entry.scanDepth <= 0 ? 1 : entry.scanDepth)
              .clamp(1, 200)
              .toInt();
          final ctx = contextCache.putIfAbsent(
            depth,
            () => extractContextForDepth(depth),
          );
          if (isTriggered(entry, ctx)) {
            triggered.add((entry: entry, seq: seq));
          }
          seq++;
        }
      }

      if (triggered.isEmpty) return;

      triggered.sort((a, b) {
        final pa = a.entry.priority;
        final pb = b.entry.priority;
        if (pb != pa) return pb.compareTo(pa);
        return a.seq.compareTo(b.seq);
      });

      String wrapSystemTag(String content) => '<system>\n$content\n</system>';

      String joinContents(Iterable<WorldBookEntry> items) {
        return items
            .map((e) => e.content.trim())
            .where((c) => c.isNotEmpty)
            .join('\n');
      }

      List<Map<String, dynamic>> createMergedInjectionMessages(
        List<WorldBookEntry> injections, {
        required WorldBookInjectionPosition position,
      }) {
        final byRole = <WorldBookInjectionRole, List<WorldBookEntry>>{};
        for (final e in injections) {
          if (e.content.trim().isEmpty) continue;
          byRole.putIfAbsent(e.role, () => <WorldBookEntry>[]).add(e);
        }

        final result = <Map<String, dynamic>>[];
        for (final role in byRole.keys) {
          final group = byRole[role]!;
          final merged = joinContents(group);
          if (merged.isEmpty) continue;
          final message = role == WorldBookInjectionRole.assistant
              ? <String, dynamic>{'role': 'assistant', 'content': merged}
              : <String, dynamic>{
                  'role': 'user',
                  'content': wrapSystemTag(merged),
                };
          if (ContextLogger.enabled) {
            ContextSegmentTags.replaceWithSingle(
              message,
              source: ContextSource.worldBook,
              length: (message['content'] ?? '').toString().length,
              meta: {'position': position.toJson()},
            );
          }
          result.add(message);
        }
        return result;
      }

      int findSafeInsertIndex(List<Map<String, dynamic>> messages, int target) {
        var index = target.clamp(0, messages.length);
        while (index > 0 && index < messages.length) {
          final role = (messages[index]['role'] ?? '').toString();
          if (role != 'tool') break;
          index--;
        }
        return index;
      }

      final byPosition = <WorldBookInjectionPosition, List<WorldBookEntry>>{};
      for (final t in triggered) {
        byPosition
            .putIfAbsent(t.entry.position, () => <WorldBookEntry>[])
            .add(t.entry);
      }

      // BEFORE/AFTER_SYSTEM_PROMPT：合并到系统消息。
      final beforeContent = joinContents(
        byPosition[WorldBookInjectionPosition.beforeSystemPrompt] ??
            const <WorldBookEntry>[],
      );
      final afterContent = joinContents(
        byPosition[WorldBookInjectionPosition.afterSystemPrompt] ??
            const <WorldBookEntry>[],
      );

      if (beforeContent.isNotEmpty || afterContent.isNotEmpty) {
        final systemIndex = apiMessages.indexWhere(
          (m) => (m['role'] ?? '').toString() == 'system',
        );
        if (systemIndex >= 0) {
          final original = (apiMessages[systemIndex]['content'] ?? '')
              .toString();
          final sb = StringBuffer();
          if (beforeContent.isNotEmpty) {
            sb.write(beforeContent);
            sb.write('\n');
          }
          sb.write(original);
          if (afterContent.isNotEmpty) {
            sb.write('\n');
            sb.write(afterContent);
          }
          apiMessages[systemIndex]['content'] = sb.toString();
          if (ContextLogger.enabled) {
            final sysMsg = apiMessages[systemIndex];
            if (beforeContent.isNotEmpty) {
              ContextSegmentTags.prepend(
                sysMsg,
                source: ContextSource.worldBook,
                length: beforeContent.length + 1,
                meta: {
                  'position': WorldBookInjectionPosition.beforeSystemPrompt
                      .toJson(),
                },
              );
            }
            if (afterContent.isNotEmpty) {
              ContextSegmentTags.append(
                sysMsg,
                source: ContextSource.worldBook,
                length: 1 + afterContent.length,
                meta: {
                  'position': WorldBookInjectionPosition.afterSystemPrompt
                      .toJson(),
                },
              );
            }
          }
        } else {
          final sb = StringBuffer();
          if (beforeContent.isNotEmpty) sb.write(beforeContent);
          if (afterContent.isNotEmpty) {
            if (sb.isNotEmpty) sb.write('\n');
            sb.write(afterContent);
          }
          if (sb.isNotEmpty) {
            final created = <String, dynamic>{
              'role': 'system',
              'content': sb.toString(),
            };
            if (ContextLogger.enabled) {
              if (beforeContent.isNotEmpty && afterContent.isNotEmpty) {
                ContextSegmentTags.write(created, [
                  ContextSegmentTags.item(
                    source: ContextSource.worldBook,
                    length: beforeContent.length + 1,
                    meta: {
                      'position': WorldBookInjectionPosition.beforeSystemPrompt
                          .toJson(),
                    },
                  ),
                  ContextSegmentTags.item(
                    source: ContextSource.worldBook,
                    length: afterContent.length,
                    meta: {
                      'position': WorldBookInjectionPosition.afterSystemPrompt
                          .toJson(),
                    },
                  ),
                ]);
              } else if (beforeContent.isNotEmpty) {
                ContextSegmentTags.replaceWithSingle(
                  created,
                  source: ContextSource.worldBook,
                  length: beforeContent.length,
                  meta: {
                    'position': WorldBookInjectionPosition.beforeSystemPrompt
                        .toJson(),
                  },
                );
              } else {
                ContextSegmentTags.replaceWithSingle(
                  created,
                  source: ContextSource.worldBook,
                  length: afterContent.length,
                  meta: {
                    'position': WorldBookInjectionPosition.afterSystemPrompt
                        .toJson(),
                  },
                );
              }
            }
            apiMessages.insert(0, created);
          }
        }
      }

      // TOP_OF_CHAT：插入到第一条用户消息之前。
      final topInjections = byPosition[WorldBookInjectionPosition.topOfChat];
      if (topInjections != null && topInjections.isNotEmpty) {
        var insertIndex = apiMessages.indexWhere(
          (m) => (m['role'] ?? '').toString() == 'user',
        );
        if (insertIndex < 0) insertIndex = apiMessages.length;
        insertIndex = findSafeInsertIndex(apiMessages, insertIndex);
        apiMessages.insertAll(
          insertIndex,
          createMergedInjectionMessages(
            topInjections,
            position: WorldBookInjectionPosition.topOfChat,
          ),
        );
      }

      // BOTTOM_OF_CHAT：插入到最后一条消息之前。
      final bottomInjections =
          byPosition[WorldBookInjectionPosition.bottomOfChat];
      if (bottomInjections != null && bottomInjections.isNotEmpty) {
        var insertIndex = apiMessages.isEmpty ? 0 : (apiMessages.length - 1);
        insertIndex = findSafeInsertIndex(apiMessages, insertIndex);
        apiMessages.insertAll(
          insertIndex,
          createMergedInjectionMessages(
            bottomInjections,
            position: WorldBookInjectionPosition.bottomOfChat,
          ),
        );
      }

      // AT_DEPTH：从末尾按深度插入（depth=1 表示在最后一条消息之前）。
      final atDepthInjections = byPosition[WorldBookInjectionPosition.atDepth];
      if (atDepthInjections != null && atDepthInjections.isNotEmpty) {
        final byDepth = <int, List<WorldBookEntry>>{};
        for (final e in atDepthInjections) {
          final depth = (e.injectDepth <= 0 ? 1 : e.injectDepth)
              .clamp(1, 200)
              .toInt();
          byDepth.putIfAbsent(depth, () => <WorldBookEntry>[]).add(e);
        }

        final depths = byDepth.keys.toList(growable: false)
          ..sort((a, b) => b.compareTo(a));

        for (final depth in depths) {
          final injections = byDepth[depth] ?? const <WorldBookEntry>[];
          var insertIndex = (apiMessages.length - depth).clamp(
            0,
            apiMessages.length,
          );
          insertIndex = findSafeInsertIndex(apiMessages, insertIndex);
          apiMessages.insertAll(
            insertIndex,
            createMergedInjectionMessages(
              injections,
              position: WorldBookInjectionPosition.atDepth,
            ),
          );
        }
      }
    } catch (_) {}
  }

  /// 向系统消息追加内容的辅助方法（缺少时创建一个）。
  void _appendToSystemMessage(
    List<Map<String, dynamic>> apiMessages,
    String content, {
    ContextSource? source,
  }) {
    if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
      apiMessages[0]['content'] =
          '${(apiMessages[0]['content'] ?? '') as String}\n\n$content';
      if (ContextLogger.enabled && source != null) {
        ContextSegmentTags.append(
          apiMessages[0],
          source: source,
          length: 2 + content.length,
        );
      }
    } else {
      final message = <String, dynamic>{'role': 'system', 'content': content};
      if (ContextLogger.enabled && source != null) {
        ContextSegmentTags.append(
          message,
          source: source,
          length: content.length,
        );
      }
      apiMessages.insert(0, message);
    }
  }

  /// 根据助手设置应用上下文消息限制。
  void applyContextLimit(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) {
    if ((assistant?.limitContextMessages ?? false) &&
        (assistant?.contextMessageSize ?? 0) > 0) {
      final int keep = (assistant!.contextMessageSize).clamp(
        Assistant.minContextMessageSize,
        Assistant.maxContextMessageSize,
      );
      int startIdx = 0;
      if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
        startIdx = 1;
      }
      final tail = apiMessages.sublist(startIdx);
      if (tail.length > keep) {
        final trimmed = tail.sublist(tail.length - keep);
        apiMessages
          ..removeRange(startIdx, apiMessages.length)
          ..addAll(trimmed);
      }
      // 上下文裁剪可能切到工具调用三元组中间；避免发送悬空工具消息。
      while (apiMessages.length > startIdx &&
          (apiMessages[startIdx]['role'] ?? '').toString() == 'tool') {
        apiMessages.removeAt(startIdx);
      }
    }
  }

  /// 将本地 Markdown 图片链接转换为模型上下文可用的行内 base64。
  Future<void> inlineLocalImages(List<Map<String, dynamic>> apiMessages) async {
    for (int i = 0; i < apiMessages.length; i++) {
      final s = (apiMessages[i]['content'] ?? '').toString();
      if (s.isNotEmpty) {
        apiMessages[i]['content'] =
            await MarkdownMediaSanitizer.inlineLocalImagesToBase64(s);
      }
    }
  }

  /// 检查给定供应商/模型是否启用了内置搜索。
  bool hasBuiltInSearch(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) {
    try {
      final cfg = settings.getProviderConfig(providerKey);
      return BuiltInToolsHelper.isBuiltInSearchEnabled(
        cfg: cfg,
        modelId: modelId,
      );
    } catch (_) {
      return false;
    }
  }
}

class _DocTextCacheEntry {
  const _DocTextCacheEntry({
    required this.text,
    required this.modifiedMs,
    required this.size,
  });

  final String? text;
  final int modifiedMs;
  final int size;
}
