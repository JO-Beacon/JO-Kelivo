import '../auth/provider_oauth_service.dart';
import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import '../../providers/settings_provider.dart';
import '../../providers/model_provider.dart';
import '../../models/token_usage.dart';
import '../network/dio_http_client.dart';
import '../../../utils/unicode_sanitizer.dart';
import '../logging/context_log_models.dart';
import '../logging/flutter_logger.dart';
import 'provider_request_headers.dart';
import '../../models/auto_retry_options.dart';
import 'retry_policy.dart';
import 'generation/tool_loop_runner.dart' show StreamRoundRunner;
import 'generation/text_generation_result.dart';
import '../../utils/multimodal_input_utils.dart';
import 'stream/retrying_stream.dart';
import 'chat_api_helpers.dart';
import 'stream/stream_chunk.dart';
import 'stream/stream_chunk_handler.dart';
// `normalizeClaudeImageMime` 等符号由 claude_provider 转出（见它的 export 块），
// 这里不再重复导入 claude_history。
import 'providers/claude/claude_provider.dart';
import 'providers/google/google_provider.dart';
import 'providers/openai/openai_provider.dart';
import 'providers/zhipu_layout_parsing.dart';
import 'providers/openai_images.dart';
import 'providers/openai/openai_tool_transcript.dart'
    show openaiToolCallForRequest;
import 'providers/openai/openai_vendor_compat.dart'
    show isLongCatHost, shouldIncludeStreamingUsageOptions;
import 'tool_call_cancellation.dart';
import 'stream/stream_chunk_emit.dart';

export 'generation/tool_loop_runner.dart';
export 'stream/stream_chunk_emit.dart';

typedef ToolCallHandler =
    Future<dynamic> Function(
      String name,
      Map<String, dynamic> args, {
      String? toolCallId,
    });

class ChatApiService {
  static final Map<String, CancelToken> _activeCancelTokens =
      <String, CancelToken>{};

  @visibleForTesting
  static bool shouldAttachVertexMediaAuthForTest(Uri uri) =>
      shouldAttachVertexMediaAuth(uri);

  @visibleForTesting
  static String normalizeClaudeImageMimeForTest(String mime) =>
      normalizeClaudeImageMime(mime);

  @visibleForTesting
  static int claudeVertexMaxOutputTokensForTest(String modelId) =>
      claudeVertexMaxOutputTokens(modelId);

  @visibleForTesting
  static bool isLongCatHostForTest(String baseUrl) => isLongCatHost(baseUrl);

  @visibleForTesting
  static bool shouldIncludeStreamingUsageOptionsForTest(String host) =>
      shouldIncludeStreamingUsageOptions(host);

  @visibleForTesting
  static Map<String, dynamic> normalizeOpenAIToolCallForTest(
    Map<String, dynamic> toolCall, {
    required bool includeGoogleExtraContent,
  }) => openaiToolCallForRequest(
    toolCall,
    includeGoogleExtraContent: includeGoogleExtraContent,
  );

  static bool supportsOpenAIImagesApiRouting(
    ProviderConfig config,
    String modelId,
  ) {
    final kind = ProviderConfig.classify(
      config.id,
      explicitType: config.providerType,
    );
    return kind == ProviderKind.openai &&
        shouldUseOpenAIImagesApi(config, modelId);
  }

  static void cancelRequest(String requestId) {
    final key = requestId.trim();
    if (key.isEmpty) return;
    final token = _activeCancelTokens.remove(key);
    if (token == null) return;
    try {
      if (!token.isCancelled) token.cancel('cancelled');
    } catch (_) {}
  }

  // 通过遵循按模型覆盖配置解析有效模型信息；回退到推断

  // 用于保存解析后的文本 + 图片引用的简单容器

  static Future<String> _stripImageMarkersFromText(String raw) async {
    final parsed = await parseTextAndImages(
      raw,
      allowRemoteImages: false,
      allowLocalImages: false,
      allowDataImages: false,
      // 纯文本模型眼里远程链接就是普通文字；只丢弃带数据载荷的 data:/本地路径。
      keepRemoteMarkdownText: true,
      keepDisallowedImageText: false,
    );
    return parsed.text;
  }

  static Future<dynamic> _stripImageInputsFromContent(dynamic content) async {
    if (content is String) return _stripImageMarkersFromText(content);
    if (content is List) {
      return _stripImageMarkersFromText(textFromContentParts(content));
    }
    if (content is Map) {
      return _stripImageMarkersFromText(textFromContentParts([content]));
    }
    return content;
  }

  static Future<List<Map<String, dynamic>>> _stripImageInputsFromMessages(
    List<Map<String, dynamic>> messages,
  ) async {
    final out = <Map<String, dynamic>>[];
    for (final message in messages) {
      final copy = Map<String, dynamic>.from(message);
      copy.remove(multimodalInternalMediaPathsKey);
      copy.remove(multimodalInternalRevisionIdKey);
      copy.remove(multimodalInternalDocumentPathsKey);
      copy.remove(multimodalInternalClaudeContainerKey);
      copy.remove(multimodalInternalClaudeTurnKey);
      copy.remove(kelivoContextSegmentsKey);
      if (copy.containsKey('content')) {
        copy['content'] = await _stripImageInputsFromContent(copy['content']);
      }
      out.add(copy);
    }
    return out;
  }

  static bool _supportsImageInput(ProviderConfig config, String modelId) {
    return effectiveModelInfo(config, modelId).input.contains(Modality.image);
  }

  static http.Client _clientFor(ProviderConfig cfg, CancelToken cancelToken) {
    final enabled = cfg.proxyEnabled == true;
    final host = (cfg.proxyHost ?? '').trim();
    final portStr = (cfg.proxyPort ?? '').trim();
    final user = (cfg.proxyUsername ?? '').trim();
    final pass = (cfg.proxyPassword ?? '').trim();
    if (enabled && host.isNotEmpty && portStr.isNotEmpty) {
      final port = int.tryParse(portStr) ?? 8080;
      return DioHttpClient(
        proxy: NetworkProxyConfig(
          enabled: true,
          type: ProviderConfig.resolveProxyType(cfg.proxyType),
          host: host,
          port: port,
          username: user.isEmpty ? null : user,
          password: pass.isEmpty ? null : pass,
        ),
        cancelToken: cancelToken,
      );
    }
    return DioHttpClient(cancelToken: cancelToken);
  }

  /// 兼容入口：把现有供应商流式结果转换为 provider-independent 事件。
  ///
  /// 请求和旧版 `ChatStreamChunk` 管线保持不变，便于下游逐步迁移到
  /// [StreamChunkHandler]，同时保留 JO-AIClient 当前工具循环和上下文树契约。
  /// 向供应商发起一次流式请求，产出与供应商无关的统一事件流。
  ///
  /// 与上游 Kelivo 同名同义：调用方按 [StreamChunk] 消费，
  /// 不再有 [ChatStreamChunk] 这一层 JO 自有的兼容包装。
  static Stream<StreamChunk> sendMessageStream({
    AutoRetryOptions? retryOverride,
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userImagePaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    bool stream = true,
    String? requestId,
    String? conversationId,
    bool allowImagesApiRouting = true,
    bool ocrActive = false,
    bool builtInSearchOnly = false,
    bool parseMarkdownImageLinks = true,
  }) async* {
    final sessionToken = CancelToken();
    final toolCancellation = ToolCallCancellation(
      isCancelled: () => sessionToken.isCancelled,
      cancelled: _whenCancelled(sessionToken),
    );
    final rid = (requestId ?? '').trim();
    if (rid.isNotEmpty) {
      final previous = _activeCancelTokens.remove(rid);
      try {
        previous?.cancel('replaced');
      } catch (_) {}
      _activeCancelTokens[rid] = sessionToken;
    }

    try {
      // 账号登录：先确保令牌有效（可取消），再按供应商约束调整请求形态。
      config = await Future.any<ProviderConfig>([
        ProviderOAuthService.instance.resolve(config),
        _whenCancelled(sessionToken).then(
          (_) => throw const ProviderOAuthException(
            ProviderOAuthFailure.cancelled,
          ),
        ),
      ]);
      if (sessionToken.isCancelled) return;
      if (config.oauthProvider == OAuthProvider.chatgpt) stream = true;
      if (config.oauthProvider == OAuthProvider.kimi &&
          (config.modelOverrides[modelId] as Map?)?['oauthProtocol'] ==
              'anthropic') {
        config = config.copyWith(providerType: ProviderKind.claude);
      }
      final kind = ProviderConfig.classify(
        config.id,
        explicitType: config.providerType,
      );
      final useImagesApi =
          kind == ProviderKind.openai &&
          allowImagesApiRouting &&
          shouldUseOpenAIImagesApi(config, modelId);
      final useZhipuLayoutParsing = shouldUseZhipuLayoutParsing(config, modelId);
      final imageOutput = effectiveModelInfo(
        config,
        modelId,
      ).output.contains(Modality.image);
      final replaySafe = !useImagesApi && !useZhipuLayoutParsing && !imageOutput;
      final options = retryOverride ?? AutoRetryConfig.current;
      final sessionHeaders = providerSessionHeaders(
        config,
        conversationId: conversationId,
        extraHeaders: extraHeaders,
      );

    // 每个工具轮独立重试（U10）：轮内尚未产生任何事件时才重放该轮，
    // 已执行的工具不会重复执行（工具在轮间执行，不在重放范围内）。
    final emitRetryUi = options.enabled && options.maxRetries > 0;
    Stream<StreamChunk> retryRound(Stream<StreamChunk> Function() sendRound) {
      return retryingStream<StreamChunk>(
        options: options,
        isCancelled: () => sessionToken.isCancelled,
        cancelled: _whenCancelled(sessionToken),
        shouldRetry: (error) => replaySafe && shouldRetryError(error, options),
        onRetry: (attempt, delay, error) async {
          FlutterLogger.log(
            'API request retry ${attempt + 1}/${options.maxRetries} '
            'after ${delay.inMilliseconds} ms: $error',
            tag: 'AutoRetry',
          );
        },
        retryEvent: emitRetryUi
            ? (attempt, delay, error) => RetryPending(
                attempt: attempt + 1,
                maxRetries: options.maxRetries,
                delay: delay,
                errorText: error.toString(),
                retryAt: DateTime.now().add(delay),
              )
            : null,
        attemptStartEvent: emitRetryUi ? () => const RetryAttemptStart() : null,
        attempt: (_) => carrySplitSurrogates(sendRound()),
      );
    }

    // 首轮与工具续轮共用同一个 retryRound，保证整条链路只包一层重试：
    // 早先版本外层再套一次 retryingStream，会与轮内重试相乘（3×3 层退避
    // 叠加超过 30s），让 Vertex/HTTP 错误测试超时。
    yield* retryRound(
      () => _sendMessageStreamEventsOnce(
        config: config,
        modelId: modelId,
        messages: messages,
        userImagePaths: userImagePaths,
        thinkingBudget: thinkingBudget,
        temperature: temperature,
        topP: topP,
        maxTokens: maxTokens,
        tools: tools,
        onToolCall: onToolCall == null
            ? null
            : (name, args, {toolCallId}) => toolCancellation.run(
                () => onToolCall(name, args, toolCallId: toolCallId),
              ),
        extraHeaders: sessionHeaders,
        extraBody: extraBody,
        stream: stream,
        allowImagesApiRouting: allowImagesApiRouting,
        ocrActive: ocrActive,
        builtInSearchOnly: builtInSearchOnly,
        skipImageParsing: !parseMarkdownImageLinks,
        sessionToken: sessionToken,
        retryRound: retryRound,
      ),
    );
    } finally {
      if (rid.isNotEmpty) {
        final current = _activeCancelTokens[rid];
        if (identical(current, sessionToken)) {
          _activeCancelTokens.remove(rid);
        }
      }
    }
  }

  static Stream<StreamChunk> _sendMessageStreamEventsOnce({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userImagePaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    required bool stream,
    required bool allowImagesApiRouting,
    required bool builtInSearchOnly,
    required bool ocrActive,
    required bool skipImageParsing,
    required CancelToken sessionToken,
    StreamRoundRunner? retryRound,
  }) async* {
    final kind = ProviderConfig.classify(
      config.id,
      explicitType: config.providerType,
    );
    final useImagesApi =
        kind == ProviderKind.openai &&
        allowImagesApiRouting &&
        shouldUseOpenAIImagesApi(config, modelId);
    final useZhipuLayoutParsing = shouldUseZhipuLayoutParsing(config, modelId);

    // Images 和 GLM-OCR 是一次性 JSON 特殊路由，直接转换为统一事件。
    if ((kind == ProviderKind.openai && useImagesApi) ||
        useZhipuLayoutParsing) {
      final cancelToken = CancelToken();
      _bridgeCancel(sessionToken, cancelToken);
      final safeMessages = _sanitizeMessages(messages);
      // 账号登录的请求要带上有效的令牌（失效时自动续期）。
      final client = ProviderOAuthService.instance.authenticatedClient(
        _clientFor(config, cancelToken),
        config,
      );
      try {
        if (useZhipuLayoutParsing) {
          yield* sendZhipuLayoutParsingStream(
            client,
            config,
            modelId,
            safeMessages,
            userImagePaths: userImagePaths,
            extraHeaders: extraHeaders,
          );
        } else {
          yield* sendOpenAIImagesStream(
            client,
            config,
            modelId,
            safeMessages,
            userImagePaths: userImagePaths,
            extraHeaders: extraHeaders,
            extraBody: extraBody,
          );
        }
      } finally {
        client.close();
      }
      return;
    }

    // 标准 OpenAI 请求已经直接产出 provider-independent 事件。
    // Images API、智谱布局解析和仍依赖旧契约的特殊 provider 继续走旧桥接。
    if (kind == ProviderKind.openai &&
        !useImagesApi &&
        !useZhipuLayoutParsing) {
      final cancelToken = CancelToken();
      _bridgeCancel(sessionToken, cancelToken);

      final unicodeSafeMessages = _sanitizeMessages(messages);
      final stripUnsupportedImageInputs =
          !ocrActive && !_supportsImageInput(config, modelId);
      final safeMessages = stripUnsupportedImageInputs
          ? await _stripImageInputsFromMessages(unicodeSafeMessages)
          : unicodeSafeMessages;
      final safeUserImagePaths = stripUnsupportedImageInputs
          ? const <String>[]
          : userImagePaths;
      // 账号登录的请求要带上有效的令牌（失效时自动续期）。
      final client = ProviderOAuthService.instance.authenticatedClient(
        _clientFor(config, cancelToken),
        config,
      );
      try {
        yield* sendOpenAIStream(
          client,
          config,
          modelId,
          safeMessages,
          userImagePaths: safeUserImagePaths,
          thinkingBudget: thinkingBudget,
          temperature: temperature,
          topP: topP,
          maxTokens: maxTokens,
          tools: tools,
          onToolCall: onToolCall,
          extraHeaders: extraHeaders,
          extraBody: extraBody,
          stream: stream,
          builtInSearchOnly: builtInSearchOnly,
          skipImageParsing: skipImageParsing,
          retryRound: retryRound,
        );
      } finally {
        client.close();
      }
      return;
    }

    // 标准 Claude/Gemini 以及 Vertex Claude/Gemini 均直接产出统一事件。
    final upstreamModelId = apiModelId(config, modelId).toLowerCase();
    final isVertexClaude =
        kind == ProviderKind.google &&
        config.vertexAI == true &&
        upstreamModelId.startsWith('claude-');
    final useClaudeEvents = kind == ProviderKind.claude || isVertexClaude;
    final useGoogleEvents = kind == ProviderKind.google && !isVertexClaude;
    if (useClaudeEvents || useGoogleEvents) {
      final cancelToken = CancelToken();
      _bridgeCancel(sessionToken, cancelToken);

      final unicodeSafeMessages = _sanitizeMessages(messages);
      final stripUnsupportedImageInputs =
          !ocrActive && !_supportsImageInput(config, modelId);
      final safeMessages = stripUnsupportedImageInputs
          ? await _stripImageInputsFromMessages(unicodeSafeMessages)
          : unicodeSafeMessages;
      final safeUserImagePaths = stripUnsupportedImageInputs
          ? const <String>[]
          : userImagePaths;
      // 账号登录的请求要带上有效的令牌（失效时自动续期）。
      final client = ProviderOAuthService.instance.authenticatedClient(
        _clientFor(config, cancelToken),
        config,
      );
      try {
        if (useClaudeEvents) {
          yield* sendClaudeStreamEvents(
            client,
            config,
            modelId,
            safeMessages,
            userImagePaths: safeUserImagePaths,
            thinkingBudget: thinkingBudget,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            tools: tools,
            onToolCall: onToolCall,
            extraHeaders: extraHeaders,
            extraBody: extraBody,
            stream: stream,
            builtInSearchOnly: builtInSearchOnly,
            skipImageParsing: skipImageParsing,
            retryRound: retryRound,
          );
        } else {
          yield* sendGoogleStreamEvents(
            client,
            config,
            modelId,
            safeMessages,
            userImagePaths: safeUserImagePaths,
            thinkingBudget: thinkingBudget,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            tools: tools,
            onToolCall: onToolCall,
            extraHeaders: extraHeaders,
            extraBody: extraBody,
            stream: stream,
            skipImageParsing: skipImageParsing,
            retryRound: retryRound,
          );
        }
      } finally {
        client.close();
      }
      return;
    }
  }

  static Future<void> _whenCancelled(CancelToken token) async {
    try {
      await token.whenCancel;
    } catch (_) {}
  }

  static void _bridgeCancel(CancelToken parent, CancelToken child) {
    if (parent.isCancelled) {
      if (!child.isCancelled) child.cancel('cancelled');
      return;
    }
    parent.whenCancel.then(
      (_) {
        if (!child.isCancelled) child.cancel('cancelled');
      },
      onError: (_) {
        if (!child.isCancelled) child.cancel('cancelled');
      },
    );
  }

  /// 非流式生成：经统一流式入口产出事件后，由 [StreamChunkHandler] 聚合。
  static Future<TextGenerationResult> generateMessage({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userImagePaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    String? requestId,
    String? conversationId,
    bool allowImagesApiRouting = true,
    bool ocrActive = false,
    bool builtInSearchOnly = false,
    bool skipImageParsing = false,
    AutoRetryOptions? retryOverride,
    void Function(RetryPending? pending)? onRetry,
  }) async {
    final handler = StreamChunkHandler(
      onRetry: onRetry == null ? null : (pending) => onRetry(pending),
    );
    await for (final chunk in sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      userImagePaths: userImagePaths,
      thinkingBudget: thinkingBudget,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      tools: tools,
      onToolCall: onToolCall,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      stream: false,
      requestId: requestId,
      conversationId: conversationId,
      allowImagesApiRouting: allowImagesApiRouting,
      ocrActive: ocrActive,
      builtInSearchOnly: builtInSearchOnly,
      parseMarkdownImageLinks: !skipImageParsing,
      retryOverride: retryOverride,
    )) {
      if (chunk is RetryAttemptStart) {
        onRetry?.call(null);
      }
      handler.handle(chunk);
    }
    return handler.toResult();
  }

  // 用于标题摘要等工具的非流式文本生成
  static Future<String> generateText({
    AutoRetryOptions? retryOverride,
    required ProviderConfig config,
    required String modelId,
    required String prompt,
    String? conversationId,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    int? thinkingBudget,

    /// 工具提示（标题、摘要、压缩）只处理文本；保留 Markdown 图片语法，不执行媒体发现。
    bool skipImageParsing = false,
  }) async {
    final result = await generateMessage(
      config: config,
      modelId: modelId,
      conversationId: conversationId,
      messages: [
        {'role': 'user', 'content': prompt},
      ],
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      thinkingBudget: thinkingBudget,
      // 工具类调用只需要搜索：绝不需要图片生成或代码解释器。
      builtInSearchOnly: true,
      skipImageParsing: skipImageParsing,
      allowImagesApiRouting: !skipImageParsing,
      retryOverride: retryOverride,
    );
    return result.text;
  }

  static List<Map<String, dynamic>> _sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    List<Map<String, dynamic>>? out;
    for (int i = 0; i < messages.length; i++) {
      final m = messages[i];
      final content = m['content'];
      if (content is String) {
        final cleaned = UnicodeSanitizer.sanitize(content);
        if (cleaned != content) {
          out ??= <Map<String, dynamic>>[
            for (int j = 0; j < i; j++) Map<String, dynamic>.from(messages[j]),
          ];
          final copy = Map<String, dynamic>.from(m);
          copy['content'] = cleaned;
          out.add(copy);
          continue;
        }
      }
      if (out != null) out.add(Map<String, dynamic>.from(m));
    }
    return out ?? messages;
  }
}

class ChatStreamChunk {
  final String content;
  // 可选推理增量（当模型支持推理时）
  final String? reasoning;
  // 可选的供应商推理详情（OpenRouter 风格的 `reasoning_details` 数组，
  // 可能携带思考签名）。以累积快照形式发出，便于持久化并在后续请求中回传。
  final dynamic reasoningDetails;
  final bool isDone;
  final int totalTokens;
  final TokenUsage? usage;
  final List<ToolCallInfo>? toolCalls;
  final List<ToolResultInfo>? toolResults;

  ChatStreamChunk({
    required this.content,
    this.reasoning,
    this.reasoningDetails,
    required this.isDone,
    required this.totalTokens,
    this.usage,
    this.toolCalls,
    this.toolResults,
  });
}

class ToolCallInfo {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final Map<String, dynamic>? metadata;
  ToolCallInfo({
    required this.id,
    required this.name,
    required this.arguments,
    this.metadata,
  });
}

class ToolResultInfo {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String content;
  final Map<String, dynamic>? metadata;
  ToolResultInfo({
    required this.id,
    required this.name,
    required this.arguments,
    required this.content,
    this.metadata,
  });
}
