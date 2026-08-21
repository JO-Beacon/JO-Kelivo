import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/logging/context_logger.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import '../controllers/generation_controller.dart';
import 'ask_user_interaction_service.dart';
import 'message_builder_service.dart';
import 'tool_approval_service.dart';

/// MessageGenerationService 用于 UI 更新的回调类型
typedef OnMessagesChanged = void Function();
typedef OnConversationLoadingChanged =
    void Function(String conversationId, bool loading);
typedef OnScrollToBottom = void Function();
typedef OnShowError = void Function(String message);
typedef OnShowWarning = void Function(String message);
typedef OnHapticFeedback = void Function();

const String conversationIdHeaderName = 'X-Conversation-Id';
const String _conversationIdHeaderNameLower = 'x-conversation-id';

Map<String, String>? buildConversationRequestHeaders({
  required String conversationId,
  Map<String, String>? customHeaders,
}) {
  final headers = <String, String>{
    if (customHeaders != null)
      for (final entry in customHeaders.entries)
        if (entry.key.toLowerCase() != _conversationIdHeaderNameLower)
          entry.key: entry.value,
  };
  final normalizedConversationId = conversationId.trim();
  if (normalizedConversationId.isNotEmpty) {
    headers[conversationIdHeaderName] = normalizedConversationId;
  }
  return headers.isEmpty ? null : headers;
}

/// 准备消息生成的结果
class PreparedGeneration {
  final List<Map<String, dynamic>> apiMessages;
  final List<Map<String, dynamic>> toolDefs;
  final ToolCallHandler? onToolCall;
  final bool hasBuiltInSearch;
  final List<String> lastUserImagePaths;

  PreparedGeneration({
    required this.apiMessages,
    required this.toolDefs,
    this.onToolCall,
    required this.hasBuiltInSearch,
    required this.lastUserImagePaths,
  });
}

/// 负责消息生成编排的服务。
///
/// 该服务负责协调：
/// - 创建消息（用户消息 + 助手占位）
/// - 准备 API 消息（含所有注入）
/// - 流式执行与管理
/// - 推理状态初始化
///
/// UI 更新通过回调传递，以保持职责分离。
class MessageGenerationService {
  MessageGenerationService({
    required this.chatService,
    required this.messageBuilderService,
    required this.generationController,
    required this.streamController,
    required this.contextProvider,
  });

  final ChatService chatService;
  final MessageBuilderService messageBuilderService;
  final GenerationController generationController;
  final stream_ctrl.StreamController streamController;
  final BuildContext contextProvider;

  // UI 更新回调（由 home_page 设置）
  OnMessagesChanged? onMessagesChanged;
  OnConversationLoadingChanged? onConversationLoadingChanged;
  OnScrollToBottom? onScrollToBottom;
  OnShowError? onShowError;
  OnShowWarning? onShowWarning;
  OnHapticFeedback? onHapticFeedback;

  /// 文件处理开始时调用。
  VoidCallback? onFileProcessingStarted;

  /// 文件处理结束时调用。
  VoidCallback? onFileProcessingFinished;

  /// 检查给定预算下是否启用推理
  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true;
    if (budget == -1) return true;
    return budget >= 1024;
  }

  /// 准备应用所有注入后的 API 消息。
  Future<PreparedGeneration> prepareApiMessagesWithInjections({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    required SettingsProvider settings,
    required Assistant? assistant,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
  }) async {
    final cfg = settings.getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      providerKey,
      explicitType: cfg.providerType,
    );
    final includeToolMessages = switch (kind) {
      ProviderKind.openai || ProviderKind.claude || ProviderKind.google => true,
    };

    onFileProcessingStarted?.call();

    // 构建 API 消息
    final apiMessages = messageBuilderService.buildApiMessages(
      messages: messages,
      versionSelections: versionSelections,
      currentConversation: currentConversation,
      includeToolMessages: includeToolMessages,
    );

    // 在发送时应用助手仅替换型正则（显示保持不变）。
    if (assistant != null && assistant.regexRules.isNotEmpty) {
      for (int i = 0; i < apiMessages.length; i++) {
        final role = (apiMessages[i]['role'] ?? '').toString();
        if (role != 'assistant') continue;
        final raw = (apiMessages[i]['content'] ?? '').toString();
        if (raw.isEmpty) continue;
        apiMessages[i]['content'] = applyAssistantRegexes(
          raw,
          assistant: assistant,
          scope: AssistantRegexScope.assistant,
          target: AssistantRegexTransformTarget.send,
        );
      }
    }

    // 先注入 prompts，以便 WorldBook 能扫描未裁剪的完整历史
    // （与 OCR 后裁剪前相同的关键词触发范围）。文档/OCR 处理
    // 仅在下方单次最终上下文裁剪之后执行。
    messageBuilderService.injectSystemPrompt(apiMessages, assistant, modelId);
    await messageBuilderService.injectMemoryAndRecentChats(
      apiMessages,
      assistant,
      settings: settings,
      currentConversationId: currentConversation?.id,
    );

    final hasBuiltInSearch = messageBuilderService.hasBuiltInSearch(
      settings,
      providerKey,
      modelId,
    );
    messageBuilderService.injectSearchPrompt(
      apiMessages,
      settings,
      assistant,
      hasBuiltInSearch,
    );
    await messageBuilderService.injectInstructionPrompts(
      apiMessages,
      assistantId,
    );
    await messageBuilderService.injectWorldBookPrompts(
      apiMessages,
      assistantId,
    );

    // 在 WorldBook TOP/BOTTOM/AT_DEPTH 注入后做单次最终裁剪。OCR 与
    // 文档抽取必须仅对该保留集合执行，确保不会被发送的图片
    // 永不处理 (#769)。
    messageBuilderService.applyContextLimit(apiMessages, assistant);

    final lastUserImagePaths = await messageBuilderService
        .processUserMessagesForApi(
          apiMessages,
          settings,
          assistant,
          conversation: currentConversation,
          sourceMessages: messages,
        );

    onFileProcessingFinished?.call();

    await messageBuilderService.inlineLocalImages(apiMessages);
    if (ContextLogger.enabled) {
      final providerName = cfg.name.trim();
      ContextLogger.logPrepared(
        apiMessages: apiMessages,
        conversationId: currentConversation?.id ?? '',
        assistantName: assistant?.name ?? '',
        provider: providerName.isNotEmpty ? providerName : providerKey,
        model: modelId,
      );
    }
    messageBuilderService.stripInternalRevisionIds(apiMessages);

    // 准备工具
    final mcpRouteSnapshot = generationController.captureMcpToolRoutes(
      assistant,
    );
    final toolDefs = generationController.buildToolDefinitions(
      settings,
      assistant,
      providerKey,
      modelId,
      hasBuiltInSearch,
      mcpRouteSnapshot: mcpRouteSnapshot,
    );
    final onToolCall = toolDefs.isNotEmpty
        ? generationController.buildToolCallHandler(
            settings,
            assistant,
            approvalService: approvalService,
            askUserService: askUserService,
            conversationId: currentConversation?.id,
            mcpRouteSnapshot: mcpRouteSnapshot,
          )
        : null;

    return PreparedGeneration(
      apiMessages: apiMessages,
      toolDefs: toolDefs,
      onToolCall: onToolCall,
      hasBuiltInSearch: hasBuiltInSearch,
      lastUserImagePaths: lastUserImagePaths,
    );
  }

  /// 根据输入数据创建用户消息。
  Future<ChatMessage> createUserMessage({
    required String conversationId,
    required ChatInputData input,
    required Assistant? assistant,
  }) async {
    final parts = await MessageGenerationService.buildPersistedUserMessageParts(
      input,
      assistant: assistant,
    );
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'user',
      parts: parts,
    );
  }

  Future<
    ({ChatMessage userMessage, ChatMessage assistantMessage, String? runId})
  >
  beginSendGeneration({
    required String conversationId,
    required ChatInputData input,
    required Assistant? assistant,
    required String modelId,
    required String providerKey,
  }) async {
    final userParts = await buildPersistedUserMessageParts(
      input,
      assistant: assistant,
    );
    if (chatService.isTemporaryConversation(conversationId)) {
      final userMessage = await chatService.addMessage(
        conversationId: conversationId,
        role: 'user',
        parts: userParts,
      );
      final assistantMessage = await createAssistantPlaceholder(
        conversationId: conversationId,
        modelId: modelId,
        providerKey: providerKey,
      );
      return (
        userMessage: userMessage,
        assistantMessage: assistantMessage,
        runId: null,
      );
    }
    final result = await chatService.beginSendGeneration(
      conversationId: conversationId,
      userParts: userParts,
      modelId: modelId,
      providerId: providerKey,
    );
    return (
      userMessage: result.userMessage!,
      assistantMessage: result.assistantMessage,
      runId: result.run.id,
    );
  }

  Future<({ChatMessage assistantMessage, String? runId})> beginRegeneration({
    required String conversationId,
    required String modelId,
    required String providerKey,
    required String groupId,
    required int version,
    required bool truncateFuture,
    String? parentMessageId,
    String? branchId,
  }) async {
    if (chatService.isTemporaryConversation(conversationId)) {
      final assistantMessage = await createAssistantPlaceholder(
        conversationId: conversationId,
        modelId: modelId,
        providerKey: providerKey,
        groupId: groupId,
        version: version,
      );
      return (assistantMessage: assistantMessage, runId: null);
    }
    final result = await chatService.beginRegeneration(
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerKey,
      groupId: groupId,
      version: version,
      truncateFuture: truncateFuture,
      parentMessageId: parentMessageId,
      branchId: branchId,
    );
    return (assistantMessage: result.assistantMessage, runId: result.run.id);
  }

  Future<({ChatMessage assistantMessage, String? runId})>
  beginAssistantGeneration({
    required String conversationId,
    required String modelId,
    required String providerKey,
    required String anchorGroupId,
    required bool truncateFuture,
    String? parentMessageId,
    String? branchId,
  }) async {
    if (chatService.isTemporaryConversation(conversationId)) {
      final assistantMessage = await createAssistantPlaceholder(
        conversationId: conversationId,
        modelId: modelId,
        providerKey: providerKey,
      );
      return (assistantMessage: assistantMessage, runId: null);
    }
    final result = await chatService.beginAssistantGeneration(
      conversationId: conversationId,
      modelId: modelId,
      providerId: providerKey,
      anchorGroupId: anchorGroupId,
      truncateFuture: truncateFuture,
      parentMessageId: parentMessageId,
      branchId: branchId,
    );
    return (assistantMessage: result.assistantMessage, runId: result.run.id);
  }

  /// 为持久化的用户消息构建结构化 parts。
  ///
  /// 文本始终存在（可能为空）。附件按用户
  /// 选择顺序追加。不生成旧版附件标记。
  static Future<List<MessagePart>> buildPersistedUserMessageParts(
    ChatInputData input, {
    required Assistant? assistant,
  }) async {
    final processedUserText = applyAssistantRegexes(
      input.text.trim(),
      assistant: assistant,
      scope: AssistantRegexScope.user,
      target: AssistantRegexTransformTarget.persist,
    );

    final parts = <MessagePart>[TextPart(processedUserText)];
    for (final path in input.imagePaths) {
      parts.add(
        ImagePart(
          uri: SandboxPathResolver.canonicalize(path),
          mime: await inferAttachmentMime(uri: path),
        ),
      );
    }
    for (final document in input.documents) {
      parts.add(
        FilePart(
          uri: SandboxPathResolver.canonicalize(document.path),
          name: document.fileName,
          mime: await inferAttachmentMime(
            uri: document.path,
            explicitMime: document.mime,
            fileName: document.fileName,
          ),
        ),
      );
    }
    return parts;
  }

  /// 供仍需要纯字符串的调用方使用的派生文本正文。
  static Future<String> buildPersistedUserMessageContent(
    ChatInputData input, {
    required Assistant? assistant,
  }) async {
    final parts = await buildPersistedUserMessageParts(
      input,
      assistant: assistant,
    );
    return parts.whereType<TextPart>().map((part) => part.text).join();
  }

  /// 创建助手消息占位。
  Future<ChatMessage> createAssistantPlaceholder({
    required String conversationId,
    required String modelId,
    required String providerKey,
    String? groupId,
    int version = 0,
  }) async {
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'assistant',
      content: '',
      modelId: modelId,
      providerId: providerKey,
      isStreaming: true,
      groupId: groupId,
      version: version,
      selectVersion: groupId != null,
    );
  }

  /// 若启用推理，则为消息初始化推理状态。
  Future<void> initializeReasoningState({
    required String messageId,
    required bool enableReasoning,
  }) async {
    if (enableReasoning) {
      final rd = stream_ctrl.ReasoningData();
      streamController.reasoning[messageId] = rd;
      await chatService.updateMessage(
        messageId,
        reasoningStartAt: DateTime.now(),
      );
    }
  }

  /// 为流式生成构建 GenerationContext。
  stream_ctrl.GenerationContext buildGenerationContext({
    required ChatMessage assistantMessage,
    required PreparedGeneration prepared,
    required List<String> userImagePaths,
    required bool allowImagesApiRouting,
    required String providerKey,
    required String modelId,
    required Assistant? assistant,
    required SettingsProvider settings,
    required bool supportsReasoning,
    required bool enableReasoning,
    required bool generateTitleOnFinish,
    String? generationRunId,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    return stream_ctrl.GenerationContext(
      assistantMessage: assistantMessage,
      apiMessages: prepared.apiMessages,
      userImagePaths: userImagePaths,
      allowImagesApiRouting: allowImagesApiRouting,
      providerKey: providerKey,
      modelId: modelId,
      assistant: assistant,
      settings: settings,
      config: settings.getProviderConfig(providerKey),
      toolDefs: prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      extraHeaders: buildConversationRequestHeaders(
        conversationId: assistantMessage.conversationId,
        customHeaders: generationController.buildCustomHeaders(assistant),
      ),
      extraBody: generationController.buildCustomBody(assistant),
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      streamOutput: assistant?.streamOutput ?? true,
      ocrActive: ocrActive,
      generateTitleOnFinish: generateTitleOnFinish,
      generationRunId: generationRunId,
    );
  }

  /// 从助手或全局设置获取当前 model 和 provider。
  ({String? providerKey, String? modelId}) getModelConfig(
    SettingsProvider settings,
    Assistant? assistant,
  ) {
    return (
      providerKey:
          assistant?.chatModelProvider ?? settings.currentModelProvider,
      modelId: assistant?.chatModelId ?? settings.currentModelId,
    );
  }

  /// 为重新生成计算版本信息。
  ({String? targetGroupId, int nextVersion, int lastKeep})
  calculateRegenerationVersioning({
    required ChatMessage message,
    required List<ChatMessage> messages,
    required bool assistantAsNewReply,
  }) {
    final idx = messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) {
      return (targetGroupId: null, nextVersion: 0, lastKeep: -1);
    }

    String? targetGroupId;
    int nextVersion = 0;
    int lastKeep;

    if (message.role == 'assistant') {
      lastKeep = idx;
      if (assistantAsNewReply) {
        targetGroupId = null;
        nextVersion = 0;
      } else {
        targetGroupId = message.groupId ?? message.id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      }
    } else {
      // 用户消息
      final userGroupId = message.groupId ?? message.id;
      int userFirst = -1;
      for (int i = 0; i < messages.length; i++) {
        final gid0 = (messages[i].groupId ?? messages[i].id);
        if (gid0 == userGroupId) {
          userFirst = i;
          break;
        }
      }
      if (userFirst < 0) userFirst = idx;

      int aid = -1;
      for (int i = userFirst + 1; i < messages.length; i++) {
        if (messages[i].role == 'assistant') {
          aid = i;
          break;
        }
      }

      if (aid >= 0) {
        lastKeep = aid;
        targetGroupId = messages[aid].groupId ?? messages[aid].id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      } else {
        lastKeep = userFirst;
        targetGroupId = null;
        nextVersion = 0;
      }
    }

    return (
      targetGroupId: targetGroupId,
      nextVersion: nextVersion,
      lastKeep: lastKeep,
    );
  }

  /// 移除重新生成分割点之后的后续消息。
  @visibleForTesting
  static List<String> collectTrailingMessageIdsForRemoval({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) {
    if (lastKeep >= messages.length - 1) {
      return const [];
    }

    final keepGroups = <String>{};
    for (int i = 0; i <= lastKeep && i < messages.length; i++) {
      keepGroups.add(messages[i].groupId ?? messages[i].id);
    }
    if (targetGroupId != null) keepGroups.add(targetGroupId);

    final removeIds = <String>[];
    for (final message in messages.sublist(lastKeep + 1)) {
      final groupId = message.groupId ?? message.id;
      if (!keepGroups.contains(groupId)) {
        removeIds.add(message.id);
      }
    }
    return removeIds;
  }

  /// 移除重新生成分割点之后的后续消息。
  Future<List<String>> removeTrailingMessages({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) async {
    final removeIds = collectTrailingMessageIdsForRemoval(
      messages: messages,
      lastKeep: lastKeep,
      targetGroupId: targetGroupId,
    );

    var deletedIds = removeIds;
    if (removeIds.isNotEmpty && messages.isNotEmpty) {
      final removeIdSet = removeIds.toSet();
      final conversationId = messages.first.conversationId;
      final selectionChanges = <String, int?>{};
      for (final message in messages) {
        if (removeIdSet.contains(message.id)) {
          selectionChanges[message.groupId ?? message.id] = null;
        }
      }
      deletedIds = (await chatService.deleteMessages(
        conversationId: conversationId,
        messageIds: removeIdSet,
        versionSelectionChanges: selectionChanges,
      )).toList(growable: false);
    }
    for (final id in deletedIds) {
      streamController.reasoning.remove(id);
      streamController.toolParts.remove(id);
      streamController.reasoningSegments.remove(id);
    }

    return deletedIds;
  }

  bool _shouldIncludeAudioForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    // 旧的 Omni 音频白名单已移除；OpenAI 兼容 provider 不会
    // 通过此关卡获得特殊音频附件支持。
    return false;
  }

  bool supportsAudioAttachmentsForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    return _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  bool inputContainsAudioAttachments(ChatInputData input) {
    for (final attachment in input.documents) {
      if (isAudioMime(_effectiveAttachmentMime(attachment))) {
        return true;
      }
    }
    return false;
  }

  bool apiMessagesContainAudioAttachments(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      for (final ref in parseInternalMediaRefs(
        message[MessageBuilderService.internalMediaPathsKey],
      )) {
        final mime = (ref.mime != null && ref.mime!.trim().isNotEmpty)
            ? ref.mime!.trim()
            : inferMediaMimeFromSource(ref.uri);
        if (isAudioMime(mime)) {
          return true;
        }
      }
    }
    return false;
  }

  List<String> _filterMediaPathsForProvider(
    List<String> paths, {
    required bool includeAudio,
  }) {
    return paths
        .where((path) {
          final mime = inferMediaMimeFromSource(
            path,
            fallbackMime: 'image/png',
          );
          if (isAudioMime(mime)) return includeAudio;
          return isImageMime(mime) || isVideoMime(mime);
        })
        .toList(growable: false);
  }

  /// 考虑 OCR 模式构建用户图片路径。
  List<String> buildUserImagePaths({
    required ChatInputData? input,
    required List<String> lastUserImagePaths,
    required SettingsProvider settings,
    required String providerKey,
    required String modelId,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    final includeAudio = _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );

    if (input != null) {
      final currentMediaPaths = <String>[];
      for (final d in input.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        if (isVideoMime(effectiveMime) ||
            (includeAudio && isAudioMime(effectiveMime))) {
          currentMediaPaths.add(d.path);
        }
      }
      return _filterMediaPathsForProvider(<String>[
        if (!ocrActive) ...input.imagePaths,
        ...currentMediaPaths,
      ], includeAudio: includeAudio);
    }

    return _filterMediaPathsForProvider(
      lastUserImagePaths
          .where((path) {
            if (!ocrActive) return true;
            return !isImageMime(
              inferMediaMimeFromSource(path, fallbackMime: 'image/png'),
            );
          })
          .toList(growable: false),
      includeAudio: includeAudio,
    );
  }
}
