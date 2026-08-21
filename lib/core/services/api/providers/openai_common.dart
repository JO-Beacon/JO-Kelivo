part of '../chat_api_service.dart';

Uri _openAICompatibleUrl(ProviderConfig config) {
  final rawBase = config.baseUrl.endsWith('/')
      ? config.baseUrl.substring(0, config.baseUrl.length - 1)
      : config.baseUrl;
  final baseUri = Uri.parse(rawBase);
  if (config.useResponseApi == true) {
    final normalizedPath = baseUri.path.replaceAll(RegExp(r'/$'), '');
    if (BuiltInToolsHelper.isDashScopeProvider(config) &&
        normalizedPath != '/api/v2/apps/protocols/compatible-mode/v1') {
      return Uri.parse(
        '${baseUri.scheme}://${baseUri.authority}'
        '/api/v2/apps/protocols/compatible-mode/v1/responses',
      );
    }
    return Uri.parse('$rawBase/responses');
  }
  final path = config.chatPath ?? '/chat/completions';
  return Uri.parse('$rawBase$path');
}

Future<String> _saveResponsesImageGenerationMarkdown(
  String imageData, {
  String? outputFormat,
}) async {
  final normalizedFormat = (outputFormat ?? '').trim().toLowerCase();
  var mime = switch (normalizedFormat) {
    'jpeg' || 'jpg' => 'image/jpeg',
    'webp' => 'image/webp',
    _ => 'image/png',
  };
  var imageBase64 = imageData.trim();
  if (imageBase64.startsWith('data:')) {
    final commaIndex = imageBase64.indexOf(',');
    if (commaIndex < 0) return '';
    mime = _mimeFromDataUrl(imageBase64);
    imageBase64 = imageBase64.substring(commaIndex + 1);
  }
  final savedPath = await AppDirectories.saveBase64Image(mime, imageBase64);
  if (savedPath == null || savedPath.isEmpty) return '';
  final uri = SandboxPathResolver.canonicalize(savedPath);
  return '\n![image]($uri)\n';
}

bool _isResponsesImageGenerationType(dynamic type) {
  return type == 'image_generation_call' ||
      type == 'openrouter:image_generation';
}

void _applyCompatibleBuiltInSearch(
  Map<String, dynamic> body, {
  required ProviderConfig config,
  required String modelId,
  required String upstreamModelId,
}) {
  final builtIns = _builtInTools(config, modelId);
  if (!builtIns.contains(BuiltInToolNames.search)) return;

  if (BuiltInToolsHelper.isOpenRouterProvider(config)) {
    if (config.useResponseApi == true) return;
    final plugins = <Map<String, dynamic>>[];
    final existingPlugins = body['plugins'];
    if (existingPlugins is List) {
      for (final plugin in existingPlugins) {
        if (plugin is Map) {
          plugins.add(plugin.cast<String, dynamic>());
        }
      }
    }
    final hasWebPlugin = plugins.any(
      (plugin) => (plugin['id'] ?? '').toString() == 'web',
    );
    if (!hasWebPlugin) {
      plugins.add({'id': 'web'});
    }
    body['plugins'] = plugins;
    return;
  }

  if (BuiltInToolsHelper.isGrokModel(upstreamModelId)) {
    body['search_parameters'] = {'mode': 'auto', 'return_citations': true};
    return;
  }

  if (config.useResponseApi == true) return;

  if (BuiltInToolsHelper.isDashScopeProvider(config)) {
    if (!BuiltInToolsHelper.isDashScopeChatBuiltInSearchSupportedModel(
      upstreamModelId,
    )) {
      return;
    }
    body['enable_search'] = true;
    final options = BuiltInToolsHelper.dashScopeSearchOptionsFromOverride(
      config.modelOverrides[modelId],
    );
    if (options.isNotEmpty) {
      body['search_options'] = options;
    } else {
      body.remove('search_options');
    }
    return;
  }

  // MiMo：原生 chat Completions `web_search` 工具（以及可选的 web_search_usage）。
  if (BuiltInToolsHelper.isMimoProvider(config) &&
      BuiltInToolsHelper.isMimoBuiltInSearchSupportedModel(upstreamModelId)) {
    _appendChatTool(body, {'type': 'web_search'});
    return;
  }

  // GLM / Zhipu：原生 chat web_search 工具结构。
  if (BuiltInToolsHelper.isZhipuProvider(config) &&
      BuiltInToolsHelper.isGlmBuiltInSearchSupportedModel(upstreamModelId)) {
    _appendChatTool(body, {
      'type': 'web_search',
      'web_search': {'enable': true, 'search_result': true},
    });
    return;
  }
}

void _appendChatTool(Map<String, dynamic> body, Map<String, dynamic> tool) {
  final tools = <Map<String, dynamic>>[];
  final existing = body['tools'];
  if (existing is List) {
    for (final t in existing) {
      if (t is Map) tools.add(t.cast<String, dynamic>());
    }
  }
  final type = (tool['type'] ?? '').toString();
  final exists = tools.any((t) => (t['type'] ?? '').toString() == type);
  if (!exists) tools.add(tool);
  body['tools'] = tools;
  body['tool_choice'] ??= 'auto';
}

void _applyCompatibleResponsesReasoning(
  Map<String, dynamic> body, {
  required ProviderConfig config,
  required String modelId,
  required String upstreamModelId,
  required bool isReasoning,
  int? thinkingBudget,
}) {
  if (config.useResponseApi != true) return;

  if (BuiltInToolsHelper.isMimoProvider(config)) {
    body.remove('reasoning');
    if (!isReasoning) return;

    final effort = _isOff(thinkingBudget)
        ? 'none'
        : _openAIEffortForBudget(thinkingBudget, upstreamModelId);
    if (effort != 'auto') {
      body['reasoning'] = {'effort': effort};
    }
    return;
  }

  final host = Uri.tryParse(config.baseUrl)?.host.toLowerCase() ?? '';
  final isDeepSeek =
      host.contains('deepseek') ||
      config.id.toLowerCase().contains('deepseek') ||
      upstreamModelId.toLowerCase().contains('deepseek');
  if (isDeepSeek) {
    if (!isReasoning) {
      body.remove('reasoning');
    } else if (_isOff(thinkingBudget)) {
      body['reasoning'] = {'effort': 'none'};
    }
    return;
  }

  if (!BuiltInToolsHelper.isDashScopeProvider(config)) return;

  body.remove('reasoning');
  if (!isReasoning) {
    body.remove('enable_thinking');
    return;
  }

  final builtInSearchEnabled = _builtInTools(
    config,
    modelId,
  ).contains(BuiltInToolNames.search);
  final forceThinkingForQwen3Max =
      builtInSearchEnabled &&
      upstreamModelId.toLowerCase().startsWith('qwen3-max');
  body['enable_thinking'] = forceThinkingForQwen3Max || !_isOff(thinkingBudget);
}

bool _isKimiK25Model(String upstreamModelId) {
  return upstreamModelId.toLowerCase().contains('kimi-k2.5');
}

bool _isKimiK3Model(String upstreamModelId) {
  return RegExp(
    r'(^|[/_:@])kimi-k3(?:$|[-.:])',
    caseSensitive: false,
  ).hasMatch(upstreamModelId.trim());
}

bool _isKimiPreservedThinkingModel(String upstreamModelId) {
  final normalized = upstreamModelId.trim().toLowerCase();
  return _isKimiK3Model(normalized) ||
      RegExp(r'(^|[/_:@])kimi-k2\.7-code(?:$|[-.:])').hasMatch(normalized);
}

enum _ReasoningContentReplayPolicy { none, toolTurns, all }

bool _isRemoteHttpUrl(String source) {
  final normalized = source.trim().toLowerCase();
  return normalized.startsWith('http://') || normalized.startsWith('https://');
}

bool _isRemoteImageContentPart(dynamic part) {
  if (part is! Map) return false;
  final type = (part['type'] ?? '').toString().trim().toLowerCase();
  if (type != 'image_url' && type != 'input_image') return false;

  final imageUrl = part['image_url'];
  final rawUrl = imageUrl is Map ? imageUrl['url'] : imageUrl;
  return rawUrl is String && _isRemoteHttpUrl(rawUrl);
}

bool _isKimiOmitsSamplingParamsModel(String upstreamModelId) {
  final lower = upstreamModelId.toLowerCase();
  return lower.contains('kimi-k2.5') ||
      lower.contains('kimi-k2.7') ||
      _isKimiK3Model(lower);
}

bool _isKimiThinkingModel(String upstreamModelId) {
  final lower = upstreamModelId.toLowerCase();
  return lower.contains('kimi-k2-thinking') ||
      lower.contains('kimi-k2.5') ||
      lower.contains('kimi-k2.6') ||
      lower.contains('kimi-k2.7') ||
      _isKimiK3Model(lower);
}

void _removeMoonshotKimiUnsupportedSamplingParams(Map<String, dynamic> body) {
  body.remove('temperature');
  body.remove('top_p');
  body.remove('n');
  body.remove('presence_penalty');
  body.remove('frequency_penalty');
}

bool _isZhipuLikeProvider({
  required String providerId,
  required String host,
  required String upstreamModelId,
}) {
  final modelLower = upstreamModelId.toLowerCase();
  return providerId.contains('zhipu') ||
      providerId.contains('智谱') ||
      host.contains('open.bigmodel.cn') ||
      host.contains('bigmodel') ||
      host == 'api.z.ai' ||
      modelLower.startsWith('glm-');
}

void _normalizeMoonshotKimiChatBody(
  Map<String, dynamic> body, {
  required String upstreamModelId,
  required bool isReasoning,
  int? thinkingBudget,
}) {
  if (!_isKimiThinkingModel(upstreamModelId)) return;

  if (_isKimiK3Model(upstreamModelId)) {
    body.remove('thinking');
    _removeMoonshotKimiUnsupportedSamplingParams(body);
    if (!isReasoning) {
      body.remove('reasoning_effort');
      return;
    }
    final rawEffort = body['reasoning_effort'];
    if (rawEffort is! String || rawEffort.trim().isEmpty) {
      body.remove('reasoning_effort');
      return;
    }
    final effort = openAINormalizeReasoningEffort(rawEffort, upstreamModelId);
    if (effort == 'auto') {
      body.remove('reasoning_effort');
    } else {
      body['reasoning_effort'] = effort;
    }
    return;
  }

  body.remove('reasoning_effort');
  if (!isReasoning) {
    body.remove('thinking');
    return;
  }

  if (_isKimiK25Model(upstreamModelId)) {
    body['thinking'] = {
      'type': _isOff(thinkingBudget) ? 'disabled' : 'enabled',
    };
    _removeMoonshotKimiUnsupportedSamplingParams(body);
    return;
  }

  body.remove('thinking');
  if (_isKimiOmitsSamplingParamsModel(upstreamModelId)) {
    _removeMoonshotKimiUnsupportedSamplingParams(body);
  }
}

/// 累积流式传输的 `reasoning_details` 条目。
///
/// OpenRouter 将数组作为有序增量流传输（每个分块可能携带一个
/// 或多个新条目），必须按原始顺序原样拼接并重放，因此默认追加分块，
/// 并保留连续相同的增量。其他一些服务则会在每个分块中重发截至当前的
/// 完整数组；对于这些服务（当设置了 [allowSnapshots] 时），如果某个
/// 分块明显像是这种累积快照（原有条目加上新追加的条目），累加器会
/// 切换到快照模式，后续分块将替换缓冲区，而不是重复追加。对于
/// OpenRouter 本身，[allowSnapshots] 会被清除，因为其文档化语义
/// 始终是按增量拼接。
class _ReasoningDetailsAccumulator {
  _ReasoningDetailsAccumulator({this.allowSnapshots = true});

  /// 是否启用累积快照检测（对于 OpenRouter 为 false，
  /// 因为其文档化语义是增量式拼接）。
  final bool allowSnapshots;
  List<dynamic> _details = const <dynamic>[];
  bool _snapshotMode = false;

  /// 累积的条目；若未捕获任何内容则为 null。
  List<dynamic>? get detailsOrNull => _details.isEmpty ? null : _details;

  void add(List<dynamic> incoming) {
    if (incoming.isEmpty) return;
    if (_details.isEmpty) {
      _details = List<dynamic>.of(incoming);
      return;
    }
    final prefixMatches = allowSnapshots && _hasCurrentAsPrefix(incoming);
    if (prefixMatches && incoming.length > _details.length) {
      // 累积快照的明确证据：前缀相同，但更长。
      _snapshotMode = true;
      _details = List<dynamic>.of(incoming);
      return;
    }
    if (_snapshotMode && prefixMatches) {
      // 对同一数组进行快照式重发；保持缓冲区原样。
      return;
    }
    _details = <dynamic>[..._details, ...incoming];
  }

  bool _hasCurrentAsPrefix(List<dynamic> incoming) {
    if (incoming.length < _details.length) return false;
    for (var i = 0; i < _details.length; i++) {
      if (jsonEncode(_details[i]) != jsonEncode(incoming[i])) return false;
    }
    return true;
  }
}

Map<String, dynamic> _buildAssistantToolCallMessage({
  required List<Map<String, dynamic>> calls,
  dynamic content,
  String? reasoningContent,
  dynamic reasoningDetails,
  bool includeEmptyReasoningContent = false,
}) {
  final normalizedContent = switch (content) {
    String value when value.isNotEmpty => value,
    List<dynamic> value when value.isNotEmpty => value,
    _ => '\n\n',
  };

  final msg = <String, dynamic>{
    'role': 'assistant',
    'content': normalizedContent,
    'tool_calls': calls,
  };
  if (reasoningContent != null &&
      (reasoningContent.isNotEmpty || includeEmptyReasoningContent)) {
    msg['reasoning_content'] = reasoningContent;
  }
  if (reasoningDetails is List && reasoningDetails.isNotEmpty) {
    msg['reasoning_details'] = reasoningDetails;
  }
  return msg;
}

String _openAIEffortForBudget(int? budget, String upstreamModelId) {
  final baseEffort = _effortForBudget(budget);
  var requestedEffort = baseEffort;
  if (baseEffort == 'high' && budget != null) {
    if (budget >= 128000 && openAISupportsMaxReasoning(upstreamModelId)) {
      requestedEffort = 'max';
    } else if (budget >= 64000) {
      requestedEffort = 'xhigh';
    }
  }
  return openAINormalizeReasoningEffort(requestedEffort, upstreamModelId);
}

String _effectiveOpenAIEffort(
  Map<String, dynamic> body, {
  required String fallbackEffort,
}) {
  // 先读取最终载荷结构中的 effort，若没有则回退到
  // 由预算推导出的值。覆盖项可以设置 chat-completions 风格
  // （`reasoning_effort`）或 Responses 风格（`reasoning.effort`）。
  final reasoningEffort = body['reasoning_effort'];
  if (reasoningEffort is String && reasoningEffort.trim().isNotEmpty) {
    return reasoningEffort.trim().toLowerCase();
  }
  final reasoning = body['reasoning'];
  if (reasoning is Map) {
    final effort = reasoning['effort'];
    if (effort is String && effort.trim().isNotEmpty) {
      return effort.trim().toLowerCase();
    }
  }
  return fallbackEffort.toLowerCase();
}

bool _allowsSamplingParamsForOpenAIModel(
  String upstreamModelId, {
  required String effort,
}) {
  // 来源：https://developers.openai.com/api/docs/guides/latest-model
  // 这里仅强制实施文档中记录的按模型兼容性规则。
  return openAIAllowsSamplingParams(upstreamModelId, effort: effort);
}

void _sanitizeOpenAIGpt5SamplingParams(
  Map<String, dynamic> body,
  String upstreamModelId, {
  required String fallbackEffort,
  required bool isOpenRouter,
}) {
  // 必须基于最终请求体运行（在覆盖项合并之后），否则
  // 我们可能依据过期的 effort 假设保留或丢弃采样参数。
  final hasChatFunctionTools =
      body['messages'] is List &&
      body['tools'] is List &&
      (body['tools'] as List).isNotEmpty;
  if (hasChatFunctionTools &&
      openAIChatCompletionsToolsRequireNone(upstreamModelId)) {
    if (isOpenRouter) {
      final reasoning = body['reasoning'];
      final normalized = reasoning is Map
          ? Map<String, dynamic>.from(reasoning)
          : <String, dynamic>{};
      normalized
        ..remove('enabled')
        ..remove('max_tokens')
        ..['effort'] = 'none';
      body['reasoning'] = normalized;
      body.remove('reasoning_effort');
    } else {
      body['reasoning_effort'] = 'none';
    }
  }
  if (!body.containsKey('temperature') &&
      !body.containsKey('top_p') &&
      !body.containsKey('logprobs')) {
    return;
  }
  final effort = _effectiveOpenAIEffort(body, fallbackEffort: fallbackEffort);
  final allowed = _allowsSamplingParamsForOpenAIModel(
    upstreamModelId,
    effort: effort,
  );
  if (!allowed) {
    body.remove('temperature');
    body.remove('top_p');
    body.remove('logprobs');
  }
}

bool _isLongCatHost(String baseUrl) {
  // 调用方可能传入完整 URL 或纯主机名（例如 `api.longcat.chat`）。
  // `Uri.tryParse('api.longcat.chat')?.host` 是 ''（不是 null），因此绝不能仅依赖
  // `??` 回退——必要时通过显式的 https:// 前缀进行规范化。
  final raw = baseUrl.trim().toLowerCase();
  if (raw.isEmpty) return false;
  final parsed = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
  final host = (parsed?.host ?? '').toLowerCase();
  if (host.isNotEmpty) return host.contains('longcat');
  return raw.contains('longcat');
}

bool _shouldIncludeStreamingUsageOptions(String host) {
  if (_isLongCatHost(host)) {
    return false;
  }
  return !host.contains('mistral.ai') && !host.contains('openrouter');
}

bool _isClaudeModelId(String modelId) {
  final normalized = modelId.trim().toLowerCase();
  return normalized.contains('claude') || normalized.contains('anthropic/');
}

bool _shouldCacheClaudeSystemPrompt(
  ProviderConfig config,
  String upstreamModelId,
) {
  return config.claudePromptCachingEnabled == true &&
      BuiltInToolsHelper.isOpenRouterProvider(config) &&
      _isClaudeModelId(upstreamModelId);
}

void _applyOpenRouterClaudePromptCaching(
  Map<String, dynamic> body, {
  required ProviderConfig config,
  required String upstreamModelId,
}) {
  if (!_shouldCacheClaudeSystemPrompt(config, upstreamModelId)) return;
  body['cache_control'] = ProviderConfig.claudePromptCacheControl(
    config.claudePromptCachingTtl,
  );
}

void _maybeAddStreamingUsageOptions(
  Map<String, dynamic> body, {
  required bool stream,
  required ProviderConfig config,
  required String host,
}) {
  if (!stream || config.useResponseApi == true) return;
  if (_shouldIncludeStreamingUsageOptions(host)) {
    body['stream_options'] = {'include_usage': true};
  }
}

int _readOpenAIUsageInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

TokenUsage? _mergeOpenAICompatibleUsage(TokenUsage? current, dynamic rawUsage) {
  if (rawUsage is! Map) return current;

  final details =
      rawUsage['prompt_tokens_details'] ?? rawUsage['input_tokens_details'];
  final cachedTokens = details is Map
      ? _readOpenAIUsageInt(details['cached_tokens'])
      : 0;
  return (current ?? const TokenUsage()).merge(
    TokenUsage(
      promptTokens: _readOpenAIUsageInt(
        rawUsage['prompt_tokens'] ?? rawUsage['input_tokens'],
      ),
      completionTokens: _readOpenAIUsageInt(
        rawUsage['completion_tokens'] ?? rawUsage['output_tokens'],
      ),
      cachedTokens: cachedTokens,
    ),
  );
}

String _responsesReasoningText(dynamic rawOutput) {
  if (rawOutput is! List) return '';

  final buffer = StringBuffer();
  for (final item in rawOutput) {
    if (item is! Map || item['type'] != 'reasoning') continue;
    final content = item['content'];
    if (content is String) {
      buffer.write(content);
      continue;
    }
    if (content is! List) continue;
    for (final part in content) {
      if (part is String) {
        buffer.write(part);
      } else if (part is Map &&
          (part['type'] == 'reasoning_text' || part['type'] == 'text')) {
        buffer.write((part['text'] ?? part['content'] ?? '').toString());
      }
    }
  }
  return buffer.toString();
}

Future<List<Map<String, dynamic>>> _buildOpenAIChatCompletionMessages(
  List<Map<String, dynamic>> messages, {
  List<String>? userMediaPaths,
  required bool canImageInput,
  required bool allowRemoteImages,
  required _ReasoningContentReplayPolicy reasoningContentReplayPolicy,
  bool stripReasoningContent = false,
}) async {
  final out = <Map<String, dynamic>>[];
  // 助手轮次不能携带 image_url/video_url；暂存到最后一个用户消息
  // （与 Responses 的 shouldAttachAssistantImage 模式相同）。
  // 使用最后一个 *用户* 索引——不是数组末尾——这样追加了
  // 助手 tool_calls / tool 结果的工具后续消息仍能收到暂存的助手媒体。
  int lastUserIndex = -1;
  for (int i = messages.length - 1; i >= 0; i--) {
    if ((messages[i]['role'] ?? '').toString() == 'user') {
      lastUserIndex = i;
      break;
    }
  }
  final pendingAssistantMediaUrls = <String>[];
  final pendingAssistantVideoUrls = <String>{};
  final toolTurnIds = <int>{};
  final messageTurnIds = <int>[];
  var currentTurnId = -1;
  for (final message in messages) {
    final messageRole = (message['role'] ?? 'user').toString();
    if (messageRole == 'user') currentTurnId++;
    messageTurnIds.add(currentTurnId);
    final messageToolCalls = message['tool_calls'];
    if (messageRole == 'tool' ||
        (messageRole == 'assistant' &&
            messageToolCalls is List &&
            messageToolCalls.isNotEmpty)) {
      toolTurnIds.add(currentTurnId);
    }
  }
  for (int i = 0; i < messages.length; i++) {
    final m = messages[i];
    final originalContent = m['content'];
    final raw = originalContent is List
        ? ChatApiService._textFromContentParts(originalContent)
        : (originalContent ?? '').toString();
    final role = (m['role'] ?? 'user').toString();
    final isAssistant = role == 'assistant';
    final internalMediaRefs = parseInternalMediaRefs(
      m[multimodalInternalMediaPathsKey],
    );
    final outMsg = Map<String, dynamic>.from(m);
    outMsg.remove(multimodalInternalMediaPathsKey);
    outMsg.remove(multimodalInternalRevisionIdKey);
    outMsg['role'] = role;

    if (isAssistant) {
      final keepReasoningContent =
          !stripReasoningContent &&
          (reasoningContentReplayPolicy == _ReasoningContentReplayPolicy.all ||
              (reasoningContentReplayPolicy ==
                      _ReasoningContentReplayPolicy.toolTurns &&
                  toolTurnIds.contains(messageTurnIds[i])));
      if (!keepReasoningContent) {
        outMsg.remove('reasoning_content');
        outMsg.remove('reasoning');
      }
    }

    // 裸 userImagePaths 会附加到最后一个 *用户* 轮次（不是数组末尾），所以
    // 追加助手/工具消息的工具后续消息仍会保留它们。
    final hasAttachedImages =
        canImageInput &&
        role == 'user' &&
        i == lastUserIndex &&
        (userMediaPaths?.isNotEmpty == true);
    final shouldAttachAssistantMedia =
        canImageInput &&
        role == 'user' &&
        i == lastUserIndex &&
        pendingAssistantMediaUrls.isNotEmpty;
    final hasInternalMedia = canImageInput && internalMediaRefs.isNotEmpty;

    if (originalContent is List) {
      dynamic content = canImageInput
          ? (allowRemoteImages
                ? originalContent
                : originalContent
                      .where((part) => !_isRemoteImageContentPart(part))
                      .toList(growable: false))
          : raw;
      // 列表形式的内容会在 assistant-media / userImagePaths 附件之前提前返回。
      // 将这些附件合并到最后一个用户回合，同时仍保存助手媒体——包括已内嵌在
      // List 中、没有结构化 sidecar 引用的 image_url/video_url。
      final listHasEmbeddedMedia =
          canImageInput &&
          content is List &&
          content.any((part) {
            if (part is! Map) return false;
            final type = (part['type'] ?? '').toString();
            return type == 'image_url' || type == 'video_url';
          });
      if (canImageInput &&
          (hasInternalMedia ||
              hasAttachedImages ||
              shouldAttachAssistantMedia ||
              (isAssistant && listHasEmbeddedMedia))) {
        final parts = <Map<String, dynamic>>[
          if (content is List)
            for (final part in content)
              if (part is Map)
                part.map((key, value) => MapEntry(key.toString(), value)),
        ];
        final seenSources = <String>{};
        final seenImageUrls = <String>{};
        final seenVideoUrls = <String>{};

        String normalizeSrc(String src) {
          if (src.startsWith('http') || src.startsWith('data:')) return src;
          try {
            return SandboxPathResolver.fix(src);
          } catch (_) {
            return src;
          }
        }

        void addImageUrl(String url) {
          if (url.isEmpty) return;
          if (!allowRemoteImages && _isRemoteHttpUrl(url)) return;
          if (seenImageUrls.add(url)) {
            parts.add({
              'type': 'image_url',
              'image_url': {'url': url},
            });
          }
        }

        void addVideoUrl(String url) {
          if (url.isEmpty) return;
          if (seenVideoUrls.add(url)) {
            parts.add({
              'type': 'video_url',
              'video_url': {'url': url},
            });
          }
        }

        void stashOrAddImageUrl(String url) {
          if (url.isEmpty) return;
          if (!allowRemoteImages && _isRemoteHttpUrl(url)) return;
          if (isAssistant) {
            if (!pendingAssistantMediaUrls.contains(url)) {
              pendingAssistantMediaUrls.add(url);
            }
            return;
          }
          addImageUrl(url);
        }

        void stashOrAddVideoUrl(String url) {
          if (url.isEmpty) return;
          if (isAssistant) {
            if (!pendingAssistantMediaUrls.contains(url)) {
              pendingAssistantMediaUrls.add(url);
            }
            pendingAssistantVideoUrls.add(url);
            return;
          }
          addVideoUrl(url);
        }

        // 索引现有 List 媒体；在助手轮次中还会暂存它们，以便
        // 角色闸门将不受支持的 image_url/video_url 移到最后一个用户。
        for (final part in List<Map<String, dynamic>>.from(parts)) {
          final type = (part['type'] ?? '').toString();
          if (type == 'image_url') {
            final image = part['image_url'];
            final url = image is Map
                ? (image['url'] ?? '').toString()
                : image?.toString() ?? '';
            if (url.isNotEmpty) {
              seenImageUrls.add(url);
              seenSources.add(normalizeSrc(url));
              if (isAssistant) stashOrAddImageUrl(url);
            }
          } else if (type == 'video_url') {
            final video = part['video_url'];
            final url = video is Map
                ? (video['url'] ?? '').toString()
                : video?.toString() ?? '';
            if (url.isNotEmpty) {
              seenVideoUrls.add(url);
              seenSources.add(normalizeSrc(url));
              if (isAssistant) stashOrAddVideoUrl(url);
            }
          }
        }

        final supplementalRefs = _supplementalMediaRefs(
          internalRaw: m[multimodalInternalMediaPathsKey],
          userPaths: userMediaPaths,
          includeUserPaths: hasAttachedImages,
        );
        for (final mediaRef in supplementalRefs) {
          final mediaPath = mediaRef.uri;
          if (!allowRemoteImages && _isRemoteHttpUrl(mediaPath)) {
            final normalized = normalizeSrc(mediaPath);
            if (!seenSources.add(normalized)) continue;
            if (!isAssistant) {
              parts.add({'type': 'text', 'text': mediaPath});
            }
            continue;
          }
          final normalized = normalizeSrc(mediaPath);
          if (!seenSources.add(normalized)) continue;
          final bool isInlineUrl =
              _isRemoteHttpUrl(mediaPath) || mediaPath.startsWith('data:');
          final String mime = _mimeForInternalMediaRef(mediaRef);
          if (isAudioMime(mime)) continue;
          final bool isVideo = isVideoMime(mime);
          final String? dataUrl = isInlineUrl
              ? mediaPath
              : await _tryEncodeBase64DataUrl(
                  mediaPath,
                  explicitMime: mediaRef.mime,
                );
          if (dataUrl == null) continue;
          if (isVideo) {
            stashOrAddVideoUrl(dataUrl);
          } else {
            stashOrAddImageUrl(dataUrl);
          }
        }
        if (shouldAttachAssistantMedia) {
          for (final url in pendingAssistantMediaUrls) {
            if (pendingAssistantVideoUrls.contains(url)) {
              addVideoUrl(url);
            } else {
              addImageUrl(url);
            }
          }
        }
        if (isAssistant) {
          // 保持助手 List 内容不含图片；媒体已在上面暂存。
          content = [
            for (final part in parts)
              if (part['type'] != 'image_url' && part['type'] != 'video_url')
                part,
          ];
          if (content.isEmpty) content = raw;
        } else {
          content = parts;
        }
      }
      outMsg['content'] = content;
      out.add(outMsg);
      continue;
    }

    if (role == 'system') {
      outMsg['content'] = raw;
      out.add(outMsg);
      continue;
    }

    if (role == 'tool' ||
        (role == 'assistant' &&
            outMsg['tool_calls'] is List &&
            (outMsg['tool_calls'] as List).isNotEmpty)) {
      outMsg['content'] = raw;
      out.add(outMsg);
      continue;
    }

    final hasMarkdownImages = raw.contains('![') && raw.contains('](');
    // 仅进行语义媒体检测——自定义附件标记不会被识别。
    // 附件通过结构化 media-path 键 /
    // userMediaPaths 以及 Markdown ![](...) 传入。
    // 消费用户和助手历史轮次中注入的媒体引用。

    if (!hasMarkdownImages &&
        !hasAttachedImages &&
        !hasInternalMedia &&
        !shouldAttachAssistantMedia) {
      outMsg['content'] = raw;
      out.add(outMsg);
      continue;
    }

    final parsed = await _parseTextAndImages(
      raw,
      allowRemoteImages: canImageInput && allowRemoteImages,
      allowLocalImages: canImageInput,
      allowDataImages: canImageInput,
      keepRemoteMarkdownText: true,
      keepDisallowedImageText: canImageInput,
    );
    if (!canImageInput) {
      outMsg['content'] = parsed.text;
      out.add(outMsg);
      continue;
    }

    final parts = <Map<String, dynamic>>[];
    final seenSources = <String>{};
    final seenImageUrls = <String>{};
    final seenVideoUrls = <String>{};

    String normalizeSrc(String src) {
      if (src.startsWith('http') || src.startsWith('data:')) return src;
      try {
        return SandboxPathResolver.fix(src);
      } catch (_) {
        return src;
      }
    }

    void addImageUrl(String url) {
      if (url.isEmpty) return;
      if (!allowRemoteImages && _isRemoteHttpUrl(url)) return;
      if (seenImageUrls.add(url)) {
        parts.add({
          'type': 'image_url',
          'image_url': {'url': url},
        });
      }
    }

    void addVideoUrl(String url) {
      if (url.isEmpty) return;
      if (seenVideoUrls.add(url)) {
        parts.add({
          'type': 'video_url',
          'video_url': {'url': url},
        });
      }
    }

    void stashOrAddImageUrl(String url) {
      if (url.isEmpty) return;
      if (!allowRemoteImages && _isRemoteHttpUrl(url)) return;
      if (isAssistant) {
        if (!pendingAssistantMediaUrls.contains(url)) {
          pendingAssistantMediaUrls.add(url);
        }
        return;
      }
      addImageUrl(url);
    }

    void stashOrAddVideoUrl(String url) {
      if (url.isEmpty) return;
      if (isAssistant) {
        if (!pendingAssistantMediaUrls.contains(url)) {
          pendingAssistantMediaUrls.add(url);
        }
        pendingAssistantVideoUrls.add(url);
        return;
      }
      addVideoUrl(url);
    }

    if (parsed.text.isNotEmpty) {
      parts.add({'type': 'text', 'text': parsed.text});
    }
    for (final ref in parsed.images) {
      final normalized = normalizeSrc(ref.src);
      if (!seenSources.add(normalized)) continue;
      final String? url;
      if (ref.kind == 'data') {
        url = ref.src;
      } else if (ref.kind == 'path') {
        url = await _tryEncodeBase64DataUrl(ref.src);
        if (url == null) continue;
      } else {
        url = ref.src;
      }
      stashOrAddImageUrl(url);
    }
    final supplementalRefs = _supplementalMediaRefs(
      internalRaw: m[multimodalInternalMediaPathsKey],
      userPaths: userMediaPaths,
      includeUserPaths: hasAttachedImages,
    );
    for (final mediaRef in supplementalRefs) {
      final p = mediaRef.uri;
      if (!allowRemoteImages && _isRemoteHttpUrl(p)) {
        // 当该模型（例如 Kimi K3）禁用图片获取/嵌入时，
        // 将远程引用保留为可见文本。
        final normalized = normalizeSrc(p);
        if (!seenSources.add(normalized)) continue;
        parts.add({'type': 'text', 'text': p});
        continue;
      }
      final normalized = normalizeSrc(p);
      if (!seenSources.add(normalized)) continue;
      final bool isInlineUrl = _isRemoteHttpUrl(p) || p.startsWith('data:');
      final String mime = _mimeForInternalMediaRef(mediaRef);
      if (isAudioMime(mime)) continue;
      final bool isVideo = isVideoMime(mime);
      final String? dataUrl = isInlineUrl
          ? p
          : await _tryEncodeBase64DataUrl(p, explicitMime: mediaRef.mime);
      if (dataUrl == null) continue;
      if (isVideo) {
        stashOrAddVideoUrl(dataUrl);
      } else {
        stashOrAddImageUrl(dataUrl);
      }
    }
    // 将暂存的助手媒体附加到最后一个用户消息。
    if (shouldAttachAssistantMedia) {
      for (final url in pendingAssistantMediaUrls) {
        if (pendingAssistantVideoUrls.contains(url)) {
          addVideoUrl(url);
        } else {
          addImageUrl(url);
        }
      }
    }
    // 助手内容保持为字符串或仅多模态文本的部分。
    if (isAssistant) {
      if (parts.isEmpty) {
        outMsg['content'] = raw;
      } else if (parts.length == 1 && parts.first['type'] == 'text') {
        outMsg['content'] = parts.first['text'] ?? raw;
      } else {
        final textOnly = <Map<String, dynamic>>[
          for (final part in parts)
            if (part['type'] == 'text') part,
        ];
        outMsg['content'] = textOnly.isEmpty ? raw : textOnly;
      }
    } else {
      outMsg['content'] = parts.isEmpty ? raw : parts;
    }
    out.add(outMsg);
  }
  return out;
}

String _extractOpenAICompatibleDeltaText(Map? delta) {
  if (delta == null) return '';
  final deltaType = (delta['type'] ?? '').toString();
  if (deltaType == 'response.audio.delta') {
    return '';
  }
  final content = delta['content'];
  if (content is String) {
    return content;
  }
  if (content is List) {
    final buffer = StringBuffer();
    for (final item in content) {
      if (item is! Map) continue;
      final text = (item['text'] ?? item['delta'] ?? '').toString();
      final type = (item['type'] ?? '').toString();
      if (text.isEmpty) continue;
      if (type.isEmpty || type == 'text') {
        buffer.write(text);
      }
    }
    return buffer.toString();
  }
  return '';
}

/// 向 [source] 追加一个尾部换行符，以便在最后一次 `split('\n')` 时
/// 将 SSE 缓冲区中剩余的任何不完整行一并刷新出来。
Stream<String> _ensureTrailingNewline(Stream<String> source) async* {
  await for (final chunk in source) {
    yield chunk;
  }
  yield '\n';
}

/// 后续工具调用响应会在 SSE 解析器的每个事件 catch 中被消费，
/// 该 catch 会容忍格式错误的 JSON。请将其传输失败
/// 预先转换为 [HttpException]，这样 catch 就不会吞掉这些失败，
/// 也不会让无 [DONE] 的回退逻辑把截断的输出当作完成结果持久化。
Stream<String> _rethrowFollowUpStreamErrors(Stream<String> source) {
  return source.transform(
    StreamTransformer<String, String>.fromHandlers(
      handleError:
          (Object error, StackTrace stackTrace, EventSink<String> sink) {
            if (error is HttpException) {
              sink.addError(error, stackTrace);
            } else {
              sink.addError(
                HttpException('Follow-up stream failed: $error'),
                stackTrace,
              );
            }
          },
    ),
  );
}

/// 一些服务提供商（例如 OpenRouter 的限流/审核）会在本应返回 2xx 的流中
/// 以带内 `{"error": ...}` 帧报告失败。请将其
/// 作为流错误暴露出来，以免截断的输出被持久化为完成结果。
///
/// OpenRouter 文档化的流中失败帧会在顶层携带 `error`，同时带有一个非空的
/// `choices` 列表，其条目中的 `finish_reason` 为 "error"，因此存在
/// choices/candidates 不能掩盖非空错误载荷。健康分块要么没有 `error` 键，
/// 要么携带 null/空占位值，而 [_throwOnInBandStreamError]
/// 会忽略这种情况。
void _throwIfInBandStreamError(String data) {
  final mayCarryError =
      data.contains('"error"') ||
      data.contains('response.failed') ||
      data.contains('response.incomplete');
  if (!mayCarryError) return;
  Object? decoded;
  try {
    decoded = jsonDecode(data);
  } catch (_) {
    return;
  }
  if (decoded is! Map) return;
  final type = (decoded['type'] ?? '').toString();
  if (type == 'error') {
    // `event: error` 帧：Anthropic 风格会把负载嵌套在
    // `error` 下，而 Responses API 会把 code/message 放在帧本身
    // （{"type":"error","code":...,"message":...}）。
    final nested = decoded['error'];
    if (nested is Map && nested.isNotEmpty) {
      _throwOnInBandStreamError(nested);
    }
    _throwOnInBandStreamError(decoded);
  }
  if (type == 'response.failed' || type == 'response.incomplete') {
    // Responses API 的终止失败事件会把错误嵌套在 `response` 下。
    final response = decoded['response'];
    if (response is Map) {
      _throwOnInBandStreamError(response['error']);
      final details = response['incomplete_details'];
      if (details is Map && details.isNotEmpty) {
        final reason = (details['reason'] ?? '').toString().trim();
        throw HttpException(
          reason.isEmpty
              ? 'Provider error: response incomplete'
              : 'Provider error: response incomplete ($reason)',
        );
      }
    }
    // 即使失败事件没有可解析的负载，也绝不能让它穿透
    // 并被当作正常完成来处理。
    throw HttpException('Provider error: $type');
  }
  _throwOnInBandStreamError(decoded['error']);
}

/// 当 [error] 携带服务提供商错误负载时抛出异常；对于某些服务提供商在健康分块中
/// 发出的 null 或空占位符则不执行任何操作。
void _throwOnInBandStreamError(Object? error) {
  if (error is Map && error.isNotEmpty) {
    final message = (error['message'] ?? '').toString().trim();
    final code = (error['code'] ?? error['type'] ?? '').toString().trim();
    final detail = message.isNotEmpty ? message : jsonEncode(error);
    throw HttpException(
      code.isEmpty
          ? 'Provider error: $detail'
          : 'Provider error ($code): $detail',
    );
  }
  if (error is String && error.trim().isNotEmpty) {
    throw HttpException('Provider error: ${error.trim()}');
  }
}

class _OpenAIProviderInfo {
  final String host;
  final String providerId;
  final String upstreamModelId;

  const _OpenAIProviderInfo({
    required this.host,
    required this.providerId,
    required this.upstreamModelId,
  });

  bool get isZhipu => _isZhipuLikeProvider(
    providerId: providerId,
    host: host,
    upstreamModelId: upstreamModelId,
  );
  bool get isMimo =>
      host.contains('xiaomimimo') ||
      upstreamModelId.toLowerCase().startsWith('mimo-') ||
      upstreamModelId.toLowerCase().contains('/mimo-');
  bool get isSiliconFlow =>
      providerId.contains('siliconflow') || host.contains('siliconflow');
  bool get isAzureOpenAI => host.contains('openai.azure.com');
  bool get isOpenRouter =>
      providerId.contains('openrouter') || host.contains('openrouter.ai');
  bool get isDeepSeek =>
      host.contains('deepseek') ||
      upstreamModelId.toLowerCase().contains('deepseek');
  bool get isDashScope => host.contains('dashscope') || host.contains('aliyun');
  bool get isVolc =>
      host.contains('ark.cn-beijing.volces.com') ||
      host.contains('volc') ||
      host.contains('ark');
  bool get isIntern =>
      host.contains('intern-ai') ||
      host.contains('intern') ||
      host.contains('chat.intern-ai.org.cn');
  bool get isKimiThinkingModel => _isKimiThinkingModel(upstreamModelId);

  bool get needsReasoningEcho =>
      isDeepSeek || isMimo || isZhipu || isKimiThinkingModel;
  _ReasoningContentReplayPolicy get reasoningContentReplayPolicy {
    if (_isKimiPreservedThinkingModel(upstreamModelId)) {
      return _ReasoningContentReplayPolicy.all;
    }
    if (needsReasoningEcho) {
      return _ReasoningContentReplayPolicy.toolTurns;
    }
    return _ReasoningContentReplayPolicy.none;
  }

  String get completionTokensKey =>
      (isAzureOpenAI || isMimo) ? 'max_completion_tokens' : 'max_tokens';
}

void _applyVendorReasoningKnobs(
  Map<String, dynamic> body, {
  required _OpenAIProviderInfo info,
  required bool isReasoning,
  int? thinkingBudget,
}) {
  final off = _isOff(thinkingBudget);
  if (info.isOpenRouter) {
    if (isReasoning) {
      final support = openAIReasoningSupport(info.upstreamModelId);
      final requestedEffort = body['reasoning_effort'];
      if (support?.offFallback != null && requestedEffort is String) {
        body['reasoning'] = {'effort': requestedEffort};
      } else if (off) {
        body['reasoning'] = {'enabled': false};
      } else {
        final obj = <String, dynamic>{'enabled': true};
        if (thinkingBudget != null && thinkingBudget > 0) {
          obj['max_tokens'] = thinkingBudget;
        }
        body['reasoning'] = obj;
      }
      body.remove('reasoning_effort');
    } else {
      body.remove('reasoning');
      body.remove('reasoning_effort');
    }
  } else if (info.isDashScope) {
    if (isReasoning) {
      body['enable_thinking'] = !off;
      if (!off && thinkingBudget != null && thinkingBudget > 0) {
        body['thinking_budget'] = thinkingBudget;
      } else {
        body.remove('thinking_budget');
      }
    } else {
      body.remove('enable_thinking');
      body.remove('thinking_budget');
    }
    body.remove('reasoning_effort');
  } else if (info.isZhipu || info.isMimo) {
    if (isReasoning) {
      body['thinking'] = {'type': off ? 'disabled' : 'enabled'};
    } else {
      body.remove('thinking');
    }
    body.remove('reasoning_effort');
  } else if (info.isVolc) {
    if (isReasoning) {
      body['thinking'] = {'type': off ? 'disabled' : 'enabled'};
    } else {
      body.remove('thinking');
    }
    body.remove('reasoning_effort');
  } else if (info.isIntern) {
    if (isReasoning) {
      body['thinking_mode'] = !off;
    } else {
      body.remove('thinking_mode');
    }
    body.remove('reasoning_effort');
  } else if (info.isSiliconFlow) {
    if (isReasoning) {
      if (off) {
        body['enable_thinking'] = false;
        body.remove('thinking_budget');
      } else {
        body.remove('enable_thinking');
        if (thinkingBudget != null && thinkingBudget > 0) {
          body['thinking_budget'] = thinkingBudget;
        } else {
          body.remove('thinking_budget');
        }
      }
    } else {
      body.remove('enable_thinking');
      body.remove('thinking_budget');
    }
    body.remove('reasoning_effort');
  } else if (info.isDeepSeek) {
    if (isReasoning) {
      body['thinking'] = {'type': off ? 'disabled' : 'enabled'};
    } else {
      body.remove('thinking');
      body.remove('reasoning_effort');
    }
  }
}

Stream<ChatStreamChunk> _sendOpenAIStream(
  http.Client client,
  ProviderConfig config,
  String modelId,
  List<Map<String, dynamic>> messages, {
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
}) async* {
  final upstreamModelId = _apiModelId(config, modelId);
  final url = _openAICompatibleUrl(config);
  // 通过 OpenAI 兼容代理提供的 Claude 模型需要经过签名的
  // thinking 块；未签名的推理回声会在发送前被剥离。
  final isClaudeUpstream = upstreamModelId.toLowerCase().contains('claude');

  final effectiveInfo = _effectiveModelInfo(config, modelId);
  final isReasoning = effectiveInfo.abilities.contains(ModelAbility.reasoning);
  final wantsImageOutput = effectiveInfo.output.contains(Modality.image);
  final bool canImageInput = effectiveInfo.input.contains(Modality.image);
  final bool allowRemoteImages =
      canImageInput && !_isKimiK3Model(upstreamModelId);

  final effort = _openAIEffortForBudget(thinkingBudget, upstreamModelId);
  final info = _OpenAIProviderInfo(
    host: Uri.tryParse(config.baseUrl)?.host.toLowerCase() ?? '',
    providerId: config.id.toLowerCase(),
    upstreamModelId: upstreamModelId,
  );
  // OpenRouter 文档定义的是必须按顺序拼接的增量式 `reasoning_details` 分块，
  // 因此对其禁用累积快照检测；其他服务可能在每个分块中重发截至当前的完整数组。
  final reasoningDetailsAllowSnapshots =
      !BuiltInToolsHelper.isOpenRouterProvider(config);
  final bool needsReasoningEcho = info.needsReasoningEcho && isReasoning;
  void setMaxTokens(Map<String, dynamic> map) {
    if (maxTokens != null) map[info.completionTokensKey] = maxTokens;
  }

  // Kimi K3 Formula 网络搜索：获取工具声明，然后通过 fiber 执行调用。
  // 仅派发去重解析后实际插入的名称。
  final formulaToolNames = <String>{};
  List<Map<String, dynamic>> kimiFormulaTools = const <Map<String, dynamic>>[];
  final builtInSearchEnabled = _builtInTools(
    config,
    modelId,
  ).contains(BuiltInToolNames.search);
  if (config.useResponseApi != true &&
      BuiltInToolsHelper.isMoonshotProvider(config) &&
      BuiltInToolsHelper.isKimiK3Model(upstreamModelId) &&
      builtInSearchEnabled) {
    try {
      kimiFormulaTools = await KimiFormulaSearch.fetchTools(
        client: client,
        config: config,
      );
    } catch (_) {
      kimiFormulaTools = const <Map<String, dynamic>>[];
    }
  }
  Future<String> resolveToolCall(
    String name,
    Map<String, dynamic> args, {
    String? toolCallId,
  }) async {
    if (formulaToolNames.contains(name)) {
      return KimiFormulaSearch.executeFiber(
        client: client,
        config: config,
        name: name,
        arguments: jsonEncode(args),
      );
    }
    if (onToolCall != null) {
      return onToolCall(name, args, toolCallId: toolCallId);
    }
    throw Exception('No tool handler for $name');
  }

  final ToolCallHandler? effectiveOnToolCall =
      (onToolCall != null || kimiFormulaTools.isNotEmpty)
      ? resolveToolCall
      : null;

  Map<String, dynamic> body;
  // 保留初始 Responses 请求上下文，以便工具被调用时能够执行后续请求
  List<Map<String, dynamic>> responsesInitialInput =
      const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> responsesToolsSpec =
      const <Map<String, dynamic>>[];
  String responsesInstructions = '';
  List<dynamic>? responsesIncludeParam;
  if (config.useResponseApi == true) {
    final input = <Map<String, dynamic>>[];
    // 将系统消息提取到 `instructions` 中（Responses API 的最佳实践）
    String instructions = '';
    // 准备 Responses 路径的工具列表（可能会补充内置网络搜索）
    final List<Map<String, dynamic>> toolList = [];
    if (tools != null && tools.isNotEmpty) {
      for (final t in tools) {
        toolList.add(Map<String, dynamic>.from(t));
      }
    }

    final builtIns = _builtInTools(config, modelId);
    void addResponsesBuiltInTool(Map<String, dynamic> entry) {
      final type = (entry['type'] ?? '').toString();
      if (type.isEmpty) return;
      final exists = toolList.any((e) => (e['type'] ?? '').toString() == type);
      if (!exists) toolList.add(entry);
    }

    // OpenAI 内置工具（Responses API）
    if (builtIns.contains(BuiltInToolNames.codeInterpreter)) {
      addResponsesBuiltInTool({
        'type': 'code_interpreter',
        'container': {'type': 'auto', 'memory_limit': '4g'},
      });
    }
    if (builtIns.contains(BuiltInToolNames.imageGeneration)) {
      addResponsesBuiltInTool({'type': 'image_generation'});
    }

    // 在支持的模型上启用时，用于 Responses API 的内置网络搜索
    bool isResponsesWebSearchSupported(String id) {
      if (BuiltInToolsHelper.isOpenAIResponsesBuiltInSearchSupportedModel(id)) {
        return true;
      }
      if (BuiltInToolsHelper.isDashScopeProvider(config)) {
        return BuiltInToolsHelper.isDashScopeResponsesBuiltInSearchSupportedModel(
          id,
        );
      }
      if (BuiltInToolsHelper.isArkProvider(config)) {
        return BuiltInToolsHelper.isDoubaoResponsesBuiltInSearchSupportedModel(
          id,
        );
      }
      return false;
    }

    if (isResponsesWebSearchSupported(upstreamModelId)) {
      if (builtIns.contains(BuiltInToolNames.search)) {
        if (BuiltInToolsHelper.isDashScopeProvider(config) ||
            BuiltInToolsHelper.isArkProvider(config)) {
          addResponsesBuiltInTool({'type': 'web_search'});
        } else {
          // modelOverrides[modelId]['webSearch'] 下的可选按模型配置
          Map<String, dynamic> ws = const <String, dynamic>{};
          try {
            final ov = config.modelOverrides[modelId];
            if (ov is Map && ov['webSearch'] is Map) {
              ws = (ov['webSearch'] as Map).cast<String, dynamic>();
            }
          } catch (_) {}
          final usePreview =
              (ws['preview'] == true) ||
              ((ws['tool'] ?? '').toString() == 'preview');
          final entry = <String, dynamic>{
            'type': usePreview ? 'web_search_preview' : 'web_search',
          };
          // 域名过滤
          if (ws['allowed_domains'] is List &&
              (ws['allowed_domains'] as List).isNotEmpty) {
            entry['filters'] = {
              'allowed_domains': List<String>.from(
                (ws['allowed_domains'] as List).map((e) => e.toString()),
              ),
            };
          }
          // 用户位置
          if (ws['user_location'] is Map) {
            entry['user_location'] = (ws['user_location'] as Map)
                .cast<String, dynamic>();
          }
          // 搜索上下文大小（仅预览工具）
          if (usePreview && ws['search_context_size'] is String) {
            entry['search_context_size'] = ws['search_context_size'];
          }
          addResponsesBuiltInTool(entry);
          // 可选择在输出中请求来源
          if (ws['include_sources'] == true) {
            // 合并/追加 include 数组，
            // 构建请求体时将在输入循环后添加此项
          }
        }
      }
    }
    // 收集助手图片，以附加到最后一条用户消息。
    // 使用最后一条 *用户* 消息的索引，确保工具后续调用仍能收到暂存媒体。
    final List<String> lastAssistantImageUrls = <String>[];
    int lastResponsesUserIndex = -1;
    for (int i = messages.length - 1; i >= 0; i--) {
      if ((messages[i]['role'] ?? '').toString() == 'user') {
        lastResponsesUserIndex = i;
        break;
      }
    }
    for (int i = 0; i < messages.length; i++) {
      final m = messages[i];
      final originalContent = m['content'];
      final raw = originalContent is List
          ? ChatApiService._textFromContentParts(originalContent)
          : (originalContent ?? '').toString();
      final roleRaw = (m['role'] ?? 'user').toString();

      // Responses API 支持顶层 `instructions` 字段，其优先级更高
      if (roleRaw == 'system') {
        if (raw.isNotEmpty) {
          instructions = instructions.isEmpty ? raw : ('$instructions\n\n$raw');
        }
        continue;
      }

      // 处理工具结果消息（role: 'tool'），转换为 function_call_output 格式
      if (roleRaw == 'tool') {
        final toolCallId = (m['tool_call_id'] ?? '').toString();
        final content = (m['content'] ?? '').toString();
        if (toolCallId.isNotEmpty) {
          input.add({
            'type': 'function_call_output',
            'call_id': toolCallId,
            'output': content,
          });
        }
        continue;
      }

      final isAssistant = roleRaw == 'assistant';

      // 处理带 tool_calls 的助手消息，转换为 function_call 格式
      if (isAssistant && m['tool_calls'] is List) {
        final toolCalls = m['tool_calls'] as List;
        for (final tc in toolCalls) {
          if (tc is! Map) continue;
          final callId = (tc['id'] ?? '').toString();
          final fn = tc['function'];
          if (fn is! Map) continue;
          final name = (fn['name'] ?? '').toString();
          final arguments = (fn['arguments'] ?? '{}').toString();
          if (callId.isNotEmpty && name.isNotEmpty) {
            input.add({
              'type': 'function_call',
              'call_id': callId,
              'name': name,
              'arguments': arguments,
            });
          }
        }
        // 如果助手消息内容仅包含工具调用，则跳过添加
        if (raw.trim().isEmpty || raw.trim() == '\n\n') continue;
      }

      // 仅当有图片需要处理时才解析图片。
      // 仅进行语义媒体检测，无法识别自定义附件标记。
      // 附件通过结构化 media-path 键 /
      // userImagePaths，以及 Markdown 的 ![](...) 传入。
      final hasMarkdownImages = raw.contains('![') && raw.contains('](');
      final internalMediaRefs = parseInternalMediaRefs(
        m[multimodalInternalMediaPathsKey],
      );
      // 消费为用户与助手历史轮次注入的媒体引用。
      final hasInternalMedia = canImageInput && internalMediaRefs.isNotEmpty;
      final hasAttachedImages =
          canImageInput &&
          (m['role'] == 'user') &&
          i == lastResponsesUserIndex &&
          (userImagePaths?.isNotEmpty == true);
      // 对于最后一条用户消息，如有可用，还附加最后一张助手图片
      final shouldAttachAssistantImage =
          canImageInput &&
          (m['role'] == 'user') &&
          i == lastResponsesUserIndex &&
          lastAssistantImageUrls.isNotEmpty;

      if (hasMarkdownImages ||
          hasAttachedImages ||
          hasInternalMedia ||
          shouldAttachAssistantImage) {
        final parsed = await _parseTextAndImages(
          raw,
          allowRemoteImages: allowRemoteImages,
          allowLocalImages: canImageInput,
          allowDataImages: canImageInput,
          keepRemoteMarkdownText: true,
          keepDisallowedImageText: canImageInput,
        );
        if (!canImageInput) {
          if (isAssistant) {
            input.add({
              'type': 'message',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': parsed.text},
              ],
            });
          } else {
            input.add({'role': roleRaw, 'content': parsed.text});
          }
          continue;
        }

        final parts = <Map<String, dynamic>>[];
        final seenImageSources = <String>{};
        final seenImageUrls = <String>{};
        String normalizeSrc(String src) {
          if (src.startsWith('http') || src.startsWith('data:')) return src;
          try {
            return SandboxPathResolver.fix(src);
          } catch (_) {
            return src;
          }
        }

        void addImage(String url) {
          if (url.isEmpty) return;
          if (!allowRemoteImages && _isRemoteHttpUrl(url)) return;
          if (seenImageUrls.add(url)) {
            parts.add({'type': 'input_image', 'image_url': url});
          }
        }

        if (parsed.text.isNotEmpty) {
          // 助手使用 output_text，用户使用 input_text
          parts.add({
            'type': isAssistant ? 'output_text' : 'input_text',
            'text': parsed.text,
          });
        }
        // 从此消息文本中提取的图片
        for (final ref in parsed.images) {
          final normalized = normalizeSrc(ref.src);
          if (!seenImageSources.add(normalized)) continue;
          final String? url;
          if (ref.kind == 'data') {
            url = ref.src;
          } else if (ref.kind == 'path') {
            url = await _tryEncodeBase64DataUrl(ref.src);
            if (url == null) continue;
          } else {
            url = ref.src; // http(s)
          }
          // 对于助手消息，收集图片；对于用户消息，直接添加
          if (isAssistant) {
            if (!lastAssistantImageUrls.contains(url)) {
              lastAssistantImageUrls.add(url);
            }
          } else {
            addImage(url);
          }
        }
        // 结构化 / 附加的媒体引用（用户与助手历史轮次）
        final supplementalRefs = _supplementalMediaRefs(
          internalRaw: m[multimodalInternalMediaPathsKey],
          userPaths: userImagePaths,
          includeUserPaths: hasAttachedImages,
        );
        for (final mediaRef in supplementalRefs) {
          final p = mediaRef.uri;
          final String mime = _mimeForInternalMediaRef(mediaRef);
          final bool isAv = isAudioMime(mime) || isVideoMime(mime);
          if (isAv) {
            // 此处的 Responses 路径没有一等 A/V 输入部件；切勿
            // 将视频/音频编码为 input_image。为远程和本地路径
            // 都保留文本引用，以免纯 A/V 附件变成
            // content: []（API 拒绝 / 静默丢弃）。
            final normalized = normalizeSrc(p);
            if (seenImageSources.add(normalized)) {
              parts.add({
                'type': isAssistant ? 'output_text' : 'input_text',
                'text': p,
              });
            }
            continue;
          }
          if (!allowRemoteImages && _isRemoteHttpUrl(p)) {
            // 当图片嵌入关闭时，将远程引用以文本形式保持可见。
            final normalized = normalizeSrc(p);
            if (!seenImageSources.add(normalized)) continue;
            parts.add({
              'type': isAssistant ? 'output_text' : 'input_text',
              'text': p,
            });
            continue;
          }
          final normalized = normalizeSrc(p);
          if (!seenImageSources.add(normalized)) continue;
          final dataUrl = (_isRemoteHttpUrl(p) || p.startsWith('data:'))
              ? p
              : await _tryEncodeBase64DataUrl(p, explicitMime: mediaRef.mime);
          if (dataUrl == null) continue;
          // 助手 Responses 消息只能包含 output_text/refusal。
          // 与 Markdown 路径保持一致：暂存到下一轮用户消息。
          if (isAssistant) {
            if (!lastAssistantImageUrls.contains(dataUrl)) {
              lastAssistantImageUrls.add(dataUrl);
            }
          } else {
            addImage(dataUrl);
          }
        }
        // 将所有暂存的助手图片附加到最后一条用户消息
        if (shouldAttachAssistantImage) {
          for (final url in lastAssistantImageUrls) {
            addImage(url);
          }
        }
        // 为助手消息使用正确的消息对象格式
        if (isAssistant) {
          // 绝不在助手完成输出中生成 input_image。
          final assistantContent = <Map<String, dynamic>>[
            for (final part in parts)
              if (part['type'] == 'output_text' || part['type'] == 'refusal')
                part,
          ];
          if (assistantContent.isEmpty) {
            assistantContent.add({'type': 'output_text', 'text': parsed.text});
          }
          input.add({
            'type': 'message',
            'role': 'assistant',
            'status': 'completed',
            'content': assistantContent,
          });
        } else {
          input.add({'role': roleRaw, 'content': parts});
        }
      } else {
        // 无图片
        if (isAssistant) {
          // 为助手消息使用正确的消息对象格式
          input.add({
            'type': 'message',
            'role': 'assistant',
            'status': 'completed',
            'content': [
              {'type': 'output_text', 'text': raw},
            ],
          });
        } else {
          input.add({'role': roleRaw, 'content': raw});
        }
      }
    }
    body = {
      'model': upstreamModelId,
      'input': input,
      'stream': stream,
      if (instructions.isNotEmpty) 'instructions': instructions,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      if (maxTokens != null) 'max_output_tokens': maxTokens,
      if (toolList.isNotEmpty) 'tools': _toResponsesToolsFormat(toolList),
      if (toolList.isNotEmpty) 'tool_choice': 'auto',
      if (isReasoning && effort != 'off')
        'reasoning': {
          'summary': 'auto',
          if (effort != 'auto') 'effort': effort,
        },
    };
    _applyCompatibleResponsesReasoning(
      body,
      config: config,
      modelId: modelId,
      upstreamModelId: upstreamModelId,
      isReasoning: isReasoning,
      thinkingBudget: thinkingBudget,
    );
    // 如果通过覆盖配置启用了来源，则追加 include 参数
    if (!BuiltInToolsHelper.isDashScopeProvider(config)) {
      try {
        final ov = config.modelOverrides[modelId];
        final ws = (ov is Map ? ov['webSearch'] : null);
        if (ws is Map && ws['include_sources'] == true) {
          body['include'] = ['web_search_call.action.sources'];
        }
      } catch (_) {}
    }
    // 保存初始 Responses 上下文
    try {
      responsesInitialInput = List<Map<String, dynamic>>.from(
        (body['input'] as List).map((e) => (e as Map).cast<String, dynamic>()),
      );
    } catch (_) {
      responsesInitialInput = const <Map<String, dynamic>>[];
    }
    try {
      if (body['tools'] is List) {
        responsesToolsSpec = List<Map<String, dynamic>>.from(
          (body['tools'] as List).map(
            (e) => (e as Map).cast<String, dynamic>(),
          ),
        );
      }
    } catch (_) {
      responsesToolsSpec = const <Map<String, dynamic>>[];
    }
    try {
      responsesInstructions = (body['instructions'] ?? '').toString();
    } catch (_) {
      responsesInstructions = '';
    }
    try {
      responsesIncludeParam = body['include'] as List?;
    } catch (_) {
      responsesIncludeParam = null;
    }
  } else {
    final mm = await _buildOpenAIChatCompletionMessages(
      messages,
      userMediaPaths: userImagePaths,
      canImageInput: canImageInput,
      allowRemoteImages: allowRemoteImages,
      reasoningContentReplayPolicy: info.reasoningContentReplayPolicy,
      stripReasoningContent: isClaudeUpstream,
    );
    body = {
      'model': upstreamModelId,
      'messages': mm,
      'stream': stream,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      if (isReasoning && effort != 'off' && effort != 'auto')
        'reasoning_effort': effort,
      if (tools != null && tools.isNotEmpty)
        'tools': _cleanToolsForCompatibility(tools),
      if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
    };
    setMaxTokens(body);
  }

  // 针对兼容 chat-completions 的主机的供应商特定推理调节项
  if (config.useResponseApi != true) {
    _applyVendorReasoningKnobs(
      body,
      info: info,
      isReasoning: isReasoning,
      thinkingBudget: thinkingBudget,
    );
    if (info.isKimiThinkingModel) {
      _normalizeMoonshotKimiChatBody(
        body,
        upstreamModelId: upstreamModelId,
        isReasoning: isReasoning,
        thinkingBudget: thinkingBudget,
      );
    }
  }

  final request = http.Request('POST', url);
  final headers = _customHeaders(
    config,
    modelId,
    baseHeaders: <String, String>{
      'Authorization': 'Bearer ${_apiKeyForRequest(config, modelId)}',
      'Content-Type': 'application/json',
      'Accept': stream ? 'text/event-stream' : 'application/json',
    },
    assistantHeaders: extraHeaders,
  );
  request.headers.addAll(headers);
  _maybeAddStreamingUsageOptions(
    body,
    stream: stream,
    config: config,
    host: info.host,
  );
  _applyCompatibleBuiltInSearch(
    body,
    config: config,
    modelId: modelId,
    upstreamModelId: upstreamModelId,
  );
  if (config.useResponseApi != true) {
    formulaToolNames.addAll(
      KimiFormulaSearch.mergeTools(body, kimiFormulaTools),
    );
  }
  _applyOpenRouterClaudePromptCaching(
    body,
    config: config,
    upstreamModelId: upstreamModelId,
  );

  // 合并自定义 body 键（覆盖优先）
  final extraBodyCfg = _customBody(config, modelId, assistantBody: extraBody);
  if (extraBodyCfg.isNotEmpty) {
    body.addAll(extraBodyCfg);
  }
  _sanitizeOpenAIGpt5SamplingParams(
    body,
    upstreamModelId,
    fallbackEffort: effort,
    isOpenRouter: info.isOpenRouter,
  );
  _normalizeMoonshotKimiChatBody(
    body,
    upstreamModelId: upstreamModelId,
    isReasoning: isReasoning,
    thinkingBudget: thinkingBudget,
  );
  request.body = jsonEncode(body);

  final response = await client.send(request);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final errorBody = await response.stream.bytesToString();
    throw HttpException('HTTP ${response.statusCode}: $errorBody');
  }

  // 非流式路径：解析一次性 JSON，并在需要时继续处理工具调用。
  if (!stream) {
    final txt = await response.stream.bytesToString();
    try {
      final obj = jsonDecode(txt);
      // Responses API 非流式
      if (config.useResponseApi == true) {
        String outText = '';
        final rawOutput = obj['output'] ?? obj['response']?['output'];
        final reasoningText = _responsesReasoningText(rawOutput);
        try {
          outText = (obj['output_text'] ?? '').toString();
        } catch (_) {}
        if (outText.isEmpty) {
          try {
            outText = (obj['response']?['output_text'] ?? '').toString();
          } catch (_) {}
        }
        final shouldReadOutputText = outText.isEmpty;
        try {
          final out = rawOutput as List?;
          if (out != null) {
            final buf = StringBuffer(outText);
            for (final it in out) {
              if (it is! Map) continue;
              if (_isResponsesImageGenerationType(it['type'])) {
                final b64 = (it['result'] ?? '').toString();
                if (b64.isNotEmpty) {
                  final mdImg = await _saveResponsesImageGenerationMarkdown(
                    b64,
                    outputFormat: (it['output_format'] ?? '').toString(),
                  );
                  if (mdImg.isNotEmpty) buf.write(mdImg);
                }
                continue;
              }
              if (!shouldReadOutputText) continue;
              if (it['type'] == 'output_text') {
                final c = (it['content'] ?? '').toString();
                if (c.isNotEmpty) buf.write(c);
              } else if (it['type'] == 'message') {
                final content = it['content'] as List?;
                if (content != null) {
                  for (final part in content) {
                    if (part is Map &&
                        (part['type'] == 'output_text' ||
                            part['type'] == 'text')) {
                      final t = (part['text'] ?? part['content'] ?? '')
                          .toString();
                      if (t.isNotEmpty) buf.write(t);
                    }
                  }
                }
              }
            }
            outText = buf.toString();
          }
        } catch (_) {}
        final usage = _mergeOpenAICompatibleUsage(
          null,
          obj['usage'] ?? obj['response']?['usage'],
        );
        yield ChatStreamChunk(
          content: outText,
          reasoning: reasoningText.isEmpty ? null : reasoningText,
          isDone: true,
          totalTokens: usage?.totalTokens ?? 0,
          usage: usage,
        );
        return;
      }

      // Chat Completions 非流式，并包含工具调用后续处理
      TokenUsage? aggUsage;
      Map<String, dynamic> lastObj = obj is Map
          ? Map<String, dynamic>.from(obj)
          : <String, dynamic>{};
      while (true) {
        Map<String, dynamic>? c0;
        try {
          final choices = lastObj['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            c0 = (choices.first as Map).cast<String, dynamic>();
          }
        } catch (_) {}
        if (c0 == null) {
          final s = (lastObj['output_text'] ?? '').toString();
          yield ChatStreamChunk(
            content: s,
            isDone: true,
            totalTokens: aggUsage?.totalTokens ?? 0,
            usage: aggUsage,
          );
          return;
        }
        // usage
        try {
          final u = lastObj['usage'];
          if (u is Map) {
            final prompt = (u['prompt_tokens'] ?? 0) as int? ?? 0;
            final completion = (u['completion_tokens'] ?? 0) as int? ?? 0;
            final cached =
                (u['prompt_tokens_details']?['cached_tokens'] ?? 0) as int? ??
                0;
            final round = TokenUsage(
              promptTokens: prompt,
              completionTokens: completion,
              cachedTokens: cached,
              totalTokens: prompt + completion,
            );
            aggUsage = (aggUsage ?? const TokenUsage()).merge(round);
          }
        } catch (_) {}

        final msg =
            (c0['message'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        final reasoningForTools =
            (msg['reasoning_content'] ?? msg['reasoning'])?.toString() ?? '';
        final reasoningDetailsForTools = msg['reasoning_details'];
        final tcs = (msg['tool_calls'] as List?) ?? const <dynamic>[];
        if (tcs.isNotEmpty && effectiveOnToolCall != null) {
          final calls = <Map<String, dynamic>>[];
          final callInfos = <ToolCallInfo>[];
          for (int i = 0; i < tcs.length; i++) {
            final t = (tcs[i] as Map).cast<String, dynamic>();
            final id = _effectiveToolCallId(t['id'], 'call', i);
            final f =
                (t['function'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{};
            final name = (f['name'] ?? '').toString();
            Map<String, dynamic> args;
            try {
              args = (jsonDecode((f['arguments'] ?? '{}').toString()) as Map)
                  .cast<String, dynamic>();
            } catch (_) {
              args = <String, dynamic>{};
            }
            callInfos.add(ToolCallInfo(id: id, name: name, arguments: args));
            calls.add({
              'id': id,
              'type': 'function',
              'function': {'name': name, 'arguments': jsonEncode(args)},
            });
          }
          if (callInfos.isNotEmpty) {
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: aggUsage?.totalTokens ?? 0,
              usage: aggUsage,
              toolCalls: callInfos,
            );
          }
          final results = <Map<String, dynamic>>[];
          final resultsInfo = <ToolResultInfo>[];
          for (final c in callInfos) {
            final res = await effectiveOnToolCall(
              c.name,
              c.arguments,
              toolCallId: c.id,
            );
            results.add({'tool_call_id': c.id, 'content': res});
            resultsInfo.add(
              ToolResultInfo(
                id: c.id,
                name: c.name,
                arguments: c.arguments,
                content: res,
              ),
            );
          }
          if (resultsInfo.isNotEmpty) {
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: aggUsage?.totalTokens ?? 0,
              usage: aggUsage,
              toolResults: resultsInfo,
            );
          }
          // 后续请求
          final req = http.Request('POST', url);
          final headers2 = _customHeaders(
            config,
            modelId,
            baseHeaders: <String, String>{
              'Authorization': 'Bearer ${_apiKeyForRequest(config, modelId)}',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            assistantHeaders: extraHeaders,
          );
          req.headers.addAll(headers2);
          final next = <Map<String, dynamic>>[];
          for (final m in messages) {
            next.add(_copyChatCompletionMessage(m));
          }
          final assistantToolCallMsg = _buildAssistantToolCallMessage(
            calls: calls,
            content: msg['content'],
            reasoningContent: needsReasoningEcho ? reasoningForTools : null,
            includeEmptyReasoningContent: needsReasoningEcho,
            reasoningDetails: reasoningDetailsForTools,
          );
          next.add(assistantToolCallMsg);
          for (final r in results) {
            final id = r['tool_call_id'];
            final name = calls.firstWhere(
              (c) => c['id'] == id,
              orElse: () => const {
                'function': {'name': ''},
              },
            )['function']['name'];
            next.add({
              'role': 'tool',
              'tool_call_id': id,
              'name': name,
              'content': r['content'],
            });
          }
          final reqBody = Map<String, dynamic>.from(body);
          reqBody['messages'] = await _buildOpenAIChatCompletionMessages(
            next,
            userMediaPaths: userImagePaths,
            canImageInput: canImageInput,
            allowRemoteImages: allowRemoteImages,
            reasoningContentReplayPolicy: info.reasoningContentReplayPolicy,
            stripReasoningContent: isClaudeUpstream,
          );
          reqBody.remove('stream');
          req.body = jsonEncode(reqBody);
          final resp2 = await client.send(req);
          if (resp2.statusCode < 200 || resp2.statusCode >= 300) {
            final errorBody = await resp2.stream.bytesToString();
            throw HttpException('HTTP ${resp2.statusCode}: $errorBody');
          }
          final txt2 = await resp2.stream.bytesToString();
          lastObj = jsonDecode(txt2) as Map<String, dynamic>;
          messages = next; // 更新下一轮的对话记录
          continue;
        }

        // 没有工具调用 -> 最终内容
        String content = '';
        final cmsg = (c0['message'] as Map?)?.cast<String, dynamic>();
        if (cmsg != null) {
          final cc = cmsg['content'];
          if (cc is String) {
            content = cc;
          } else if (cc is List) {
            final buf = StringBuffer();
            for (final it in cc) {
              if (it is Map && (it['type'] == 'text')) {
                final t = (it['text'] ?? '').toString();
                if (t.isNotEmpty) buf.write(t);
              } else if (it is Map &&
                  (it['type'] == 'image_url' || it['type'] == 'image')) {
                dynamic iu = it['image_url'];
                String? url;
                if (iu is String) {
                  url = iu;
                } else if (iu is Map) {
                  final u2 = iu['url'];
                  if (u2 is String) url = u2;
                }
                if (url != null && url.isNotEmpty) {
                  buf.write('\n\n![image]($url)');
                }
              }
            }
            content = buf.toString();
          }
        }
        yield ChatStreamChunk(
          content: content,
          reasoningDetails: cmsg?['reasoning_details'],
          isDone: true,
          totalTokens: aggUsage?.totalTokens ?? 0,
          usage: aggUsage,
        );
        return;
      }
    } catch (e) {
      throw HttpException('Invalid JSON: $e');
    }
  }

  // 流式路径
  final sse = response.stream.transform(utf8.decoder);
  String buffer = '';
  int totalTokens = 0;
  TokenUsage? usage;
  // 当提供方未返回 usage 时，采用近似的 token 回退计算
  int approxTokensFromChars(int chars) => (chars / 4).round();
  final int approxPromptChars = messages.fold<int>(
    0,
    (acc, m) => acc + ((m['content'] ?? '').toString().length),
  );
  final int approxPromptTokens = approxTokensFromChars(approxPromptChars);
  int approxCompletionChars = 0;
  String reasoningBuffer = '';
  final reasoningDetailsBuffer = _ReasoningDetailsAccumulator(
    allowSnapshots: reasoningDetailsAllowSnapshots,
  );
  String assistantContentBuffer = '';

  // 跟踪潜在工具调用（OpenAI Chat Completions）
  final Map<int, Map<String, String>> toolAcc =
      <int, Map<String, String>>{}; // index -> {id,name,args}
  // 跟踪潜在工具调用（OpenAI Responses API）
  final Map<String, Map<String, String>> toolAccResp =
      <String, Map<String, String>>{}; // id/name -> {name,args}
  // Responses API：按 output_index 跟踪，以便可靠地捕获 call_id
  final Map<int, Map<String, String>> respToolCallsByIndex =
      <int, Map<String, String>>{}; // index -> {call_id,name,args}
  final Map<int, _ResponsesImageGenerationResult> responsesImagesByIndex =
      <int, _ResponsesImageGenerationResult>{};
  List<Map<String, dynamic>> lastResponseOutputItems =
      const <Map<String, dynamic>>[];
  String? finishReason;

  await for (final chunk in _ensureTrailingNewline(sse)) {
    buffer += chunk;
    final lines = buffer.split('\n');
    buffer = lines.last;

    for (int i = 0; i < lines.length - 1; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || !line.startsWith('data:')) continue;

      final data = line.substring(5).trimLeft();
      if (data == '[DONE]') {
        // 如果模型已流式返回 tool_calls，但之前的分块中没有包含 finish_reason，
        // 则现在执行工具流程并启动后续请求。
        if (effectiveOnToolCall != null && toolAcc.isNotEmpty) {
          final calls = <Map<String, dynamic>>[];
          final callInfos = <ToolCallInfo>[];
          final toolMsgs = <Map<String, dynamic>>[];
          toolAcc.forEach((idx, m) {
            final id = _effectiveToolCallId(m['id'], 'call', idx);
            final name = (m['name'] ?? '');
            Map<String, dynamic> args;
            try {
              args = (jsonDecode(m['args'] ?? '{}') as Map)
                  .cast<String, dynamic>();
            } catch (_) {
              args = <String, dynamic>{};
            }
            callInfos.add(ToolCallInfo(id: id, name: name, arguments: args));
            calls.add({
              'id': id,
              'type': 'function',
              'function': {'name': name, 'arguments': jsonEncode(args)},
            });
            toolMsgs.add({'__name': name, '__id': id, '__args': args});
          });

          if (callInfos.isNotEmpty) {
            final approxTotal =
                approxPromptTokens +
                approxTokensFromChars(approxCompletionChars);
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: usage?.totalTokens ?? approxTotal,
              usage: usage,
              toolCalls: callInfos,
            );
          }

          // 执行工具并发出结果
          final results = <Map<String, dynamic>>[];
          final resultsInfo = <ToolResultInfo>[];
          for (final m in toolMsgs) {
            final name = m['__name'] as String;
            final id = m['__id'] as String;
            final args = (m['__args'] as Map<String, dynamic>);
            final res = await effectiveOnToolCall(name, args, toolCallId: id);
            results.add({'tool_call_id': id, 'content': res});
            resultsInfo.add(
              ToolResultInfo(id: id, name: name, arguments: args, content: res),
            );
          }
          if (resultsInfo.isNotEmpty) {
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: usage?.totalTokens ?? 0,
              usage: usage,
              toolResults: resultsInfo,
            );
          }

          // 构建后续消息
          final mm2 = <Map<String, dynamic>>[];
          for (final m in messages) {
            mm2.add(_copyChatCompletionMessage(m));
          }
          final assistantToolCallMsg = _buildAssistantToolCallMessage(
            calls: calls,
            content: assistantContentBuffer,
            reasoningContent: needsReasoningEcho ? reasoningBuffer : null,
            includeEmptyReasoningContent: needsReasoningEcho,
            reasoningDetails: reasoningDetailsBuffer.detailsOrNull,
          );
          mm2.add(assistantToolCallMsg);
          for (final r in results) {
            final id = r['tool_call_id'];
            final name = calls.firstWhere(
              (c) => c['id'] == id,
              orElse: () => const {
                'function': {'name': ''},
              },
            )['function']['name'];
            mm2.add({
              'role': 'tool',
              'tool_call_id': id,
              'name': name,
              'content': r['content'],
            });
          }

          // 包含多轮工具调用的后续请求
          var currentMessages = mm2;
          while (true) {
            final Map<String, dynamic> body2 = {
              'model': upstreamModelId,
              'messages': await _buildOpenAIChatCompletionMessages(
                currentMessages,
                userMediaPaths: userImagePaths,
                canImageInput: canImageInput,
                allowRemoteImages: allowRemoteImages,
                reasoningContentReplayPolicy: info.reasoningContentReplayPolicy,
                stripReasoningContent: isClaudeUpstream,
              ),
              'stream': true,
              if (temperature != null) 'temperature': temperature,
              if (topP != null) 'top_p': topP,
              if (isReasoning && effort != 'off' && effort != 'auto')
                'reasoning_effort': effort,
              if (tools != null && tools.isNotEmpty)
                'tools': _cleanToolsForCompatibility(tools),
              if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
            };
            setMaxTokens(body2);

            _applyVendorReasoningKnobs(
              body2,
              info: info,
              isReasoning: isReasoning,
              thinkingBudget: thinkingBudget,
            );

            // 在流式模式下请求 usage（受支持时）
            _applyCompatibleBuiltInSearch(
              body2,
              config: config,
              modelId: modelId,
              upstreamModelId: upstreamModelId,
            );
            _maybeAddStreamingUsageOptions(
              body2,
              stream: true,
              config: config,
              host: info.host,
            );

            // 应用自定义 body 覆盖配置
            if (extraBodyCfg.isNotEmpty) {
              body2.addAll(extraBodyCfg);
            }

            _sanitizeOpenAIGpt5SamplingParams(
              body2,
              upstreamModelId,
              fallbackEffort: effort,
              isOpenRouter: info.isOpenRouter,
            );
            _normalizeMoonshotKimiChatBody(
              body2,
              upstreamModelId: upstreamModelId,
              isReasoning: isReasoning,
              thinkingBudget: thinkingBudget,
            );

            final req2 = http.Request('POST', url);
            final headers2 = _customHeaders(
              config,
              modelId,
              baseHeaders: <String, String>{
                'Authorization': 'Bearer ${_apiKeyForRequest(config, modelId)}',
                'Content-Type': 'application/json',
                'Accept': 'text/event-stream',
              },
              assistantHeaders: extraHeaders,
            );
            req2.headers.addAll(headers2);
            req2.body = jsonEncode(body2);
            final resp2 = await client.send(req2);
            if (resp2.statusCode < 200 || resp2.statusCode >= 300) {
              final errorBody = await resp2.stream.bytesToString();
              throw HttpException('HTTP ${resp2.statusCode}: $errorBody');
            }
            final s2 = resp2.stream.transform(utf8.decoder);
            String buf2 = '';
            // 跟踪可能出现的后续工具调用
            final Map<int, Map<String, String>> toolAcc2 =
                <int, Map<String, String>>{};
            String? finishReason2;
            String contentAccum = ''; // 累积本轮内容
            String reasoningAccum = '';
            final reasoningDetailsAccum = _ReasoningDetailsAccumulator(
              allowSnapshots: reasoningDetailsAllowSnapshots,
            );
            await for (final ch in _ensureTrailingNewline(s2)) {
              buf2 += ch;
              final lines2 = buf2.split('\n');
              buf2 = lines2.last;
              for (int j = 0; j < lines2.length - 1; j++) {
                final l = lines2[j].trim();
                if (l.isEmpty || !l.startsWith('data:')) continue;
                final d = l.substring(5).trimLeft();
                if (d == '[DONE]') {
                  // 本轮已完成；在下方处理
                  continue;
                }
                _throwIfInBandStreamError(d);
                try {
                  final o = jsonDecode(d);
                  if (o is Map) {
                    usage = _mergeOpenAICompatibleUsage(usage, o['usage']);
                    if (usage != null) totalTokens = usage.totalTokens;
                  }
                  if (o is Map &&
                      o['choices'] is List &&
                      (o['choices'] as List).isNotEmpty) {
                    final c0 = (o['choices'] as List).first;
                    finishReason2 = c0['finish_reason'] as String?;
                    final delta = c0['delta'] as Map?;
                    final message = c0['message'] as Map?;
                    final txt = _extractOpenAICompatibleDeltaText(delta);
                    final rc =
                        delta?['reasoning_content'] ?? delta?['reasoning'];
                    // 捕获 Grok 引用
                    final gCitations = o['citations'];
                    if (gCitations is List && gCitations.isNotEmpty) {
                      final items = <Map<String, dynamic>>[];
                      for (int k = 0; k < gCitations.length; k++) {
                        final u = gCitations[k].toString();
                        items.add({'index': k + 1, 'url': u, 'title': u});
                      }
                      if (items.isNotEmpty) {
                        final payload = jsonEncode({'items': items});
                        yield ChatStreamChunk(
                          content: '',
                          isDone: false,
                          totalTokens: usage?.totalTokens ?? 0,
                          usage: usage,
                          toolResults: [
                            ToolResultInfo(
                              id: 'builtin_search',
                              name: 'search_web',
                              arguments: const <String, dynamic>{},
                              content: payload,
                            ),
                          ],
                        );
                      }
                    }
                    if (rc is String && rc.isNotEmpty) {
                      if (needsReasoningEcho) reasoningAccum += rc;
                      yield ChatStreamChunk(
                        content: '',
                        reasoning: rc,
                        isDone: false,
                        totalTokens: 0,
                        usage: usage,
                      );
                    }
                    if (txt.isNotEmpty) {
                      contentAccum += txt; // 累积内容
                      yield ChatStreamChunk(
                        content: txt,
                        isDone: false,
                        totalTokens: 0,
                        usage: usage,
                      );
                    }
                    // 回退/合并：同一分块中的 message.content（如果存在）
                    if (message != null && message['content'] != null) {
                      final mc = message['content'];
                      if (mc is String && mc.isNotEmpty) {
                        contentAccum += mc;
                        yield ChatStreamChunk(
                          content: mc,
                          isDone: false,
                          totalTokens: 0,
                          usage: usage,
                        );
                      }
                    }
                    if (message != null) {
                      final rcMsg =
                          message['reasoning_content'] ?? message['reasoning'];
                      if (rcMsg is String &&
                          rcMsg.isNotEmpty &&
                          needsReasoningEcho) {
                        reasoningAccum += rcMsg;
                      }
                    }
                    final rd = delta?['reasoning_details'];
                    if (rd is List && rd.isNotEmpty) {
                      reasoningDetailsAccum.add(rd);
                    }
                    final rdMsg = message?['reasoning_details'];
                    if (rdMsg is List && rdMsg.isNotEmpty) {
                      reasoningDetailsAccum.add(rdMsg);
                    }
                    // 处理 OpenRouter 风格 deltas 中的图片输出，
                    // 可能的格式：
                    // - delta['images']: [ { type: 'image_url', image_url: { url: 'data:...' }, index: 0 }, ... ]
                    // - delta['content']: [ { type: 'image_url', image_url: { url: '...' } }, { type: 'text', text: '...' } ]
                    // - 直接使用 delta['image_url']（较少见）
                    if (wantsImageOutput) {
                      final List<dynamic> imageItems = <dynamic>[];
                      final imgs = delta?['images'];
                      if (imgs is List) imageItems.addAll(imgs);
                      final contentArr = delta?['content'] as List?;
                      if (contentArr is List) {
                        for (final it in contentArr) {
                          if (it is Map &&
                              (it['type'] == 'image_url' ||
                                  it['type'] == 'image')) {
                            imageItems.add(it);
                          }
                        }
                      }
                      final singleImage = delta?['image_url'];
                      if (singleImage is Map || singleImage is String) {
                        imageItems.add({
                          'type': 'image_url',
                          'image_url': singleImage,
                        });
                      }
                      if (imageItems.isNotEmpty) {
                        final buf = StringBuffer();
                        for (final it in imageItems) {
                          if (it is! Map) continue;
                          dynamic iu = it['image_url'];
                          String? url;
                          if (iu is String) {
                            url = iu;
                          } else if (iu is Map) {
                            final u2 = iu['url'];
                            if (u2 is String) url = u2;
                          }
                          if (url != null && url.isNotEmpty) {
                            final md = '\n\n![image]($url)';
                            buf.write(md);
                            contentAccum += md;
                          }
                        }
                        final out = buf.toString();
                        if (out.isNotEmpty) {
                          yield ChatStreamChunk(
                            content: out,
                            isDone: false,
                            totalTokens: 0,
                            usage: usage,
                          );
                        }
                      }
                    }
                    final tcs = delta?['tool_calls'] as List?;
                    if (tcs != null) {
                      for (final t in tcs) {
                        final idx = (t['index'] as int?) ?? 0;
                        final id = t['id'] as String?;
                        final func = t['function'] as Map<String, dynamic>?;
                        final name = func?['name'] as String?;
                        final argsDelta = func?['arguments'] as String?;
                        final entry = toolAcc2.putIfAbsent(
                          idx,
                          () => {'id': '', 'name': '', 'args': ''},
                        );
                        if (id != null) entry['id'] = id;
                        if (name != null && name.isNotEmpty) {
                          entry['name'] = name;
                        }
                        if (argsDelta != null && argsDelta.isNotEmpty) {
                          entry['args'] = (entry['args'] ?? '') + argsDelta;
                        }
                      }
                    }
                  }
                } catch (_) {}
              }
            }

            // 本轮后续处理完成后：如果再次出现工具调用，则执行并循环
            if (finishReason2 == 'tool_calls' || toolAcc2.isNotEmpty) {
              final calls2 = <Map<String, dynamic>>[];
              final callInfos2 = <ToolCallInfo>[];
              final toolMsgs2 = <Map<String, dynamic>>[];
              toolAcc2.forEach((idx, m) {
                final id = _effectiveToolCallId(m['id'], 'call', idx);
                final name = (m['name'] ?? '');
                Map<String, dynamic> args;
                try {
                  args = (jsonDecode(m['args'] ?? '{}') as Map)
                      .cast<String, dynamic>();
                } catch (_) {
                  args = <String, dynamic>{};
                }
                callInfos2.add(
                  ToolCallInfo(id: id, name: name, arguments: args),
                );
                calls2.add({
                  'id': id,
                  'type': 'function',
                  'function': {'name': name, 'arguments': jsonEncode(args)},
                });
                toolMsgs2.add({'__name': name, '__id': id, '__args': args});
              });
              if (callInfos2.isNotEmpty) {
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: usage?.totalTokens ?? 0,
                  usage: usage,
                  toolCalls: callInfos2,
                );
              }
              final results2 = <Map<String, dynamic>>[];
              final resultsInfo2 = <ToolResultInfo>[];
              for (final m in toolMsgs2) {
                final name = m['__name'] as String;
                final id = m['__id'] as String;
                final args = (m['__args'] as Map<String, dynamic>);
                final res = await effectiveOnToolCall(
                  name,
                  args,
                  toolCallId: id,
                );
                results2.add({'tool_call_id': id, 'content': res});
                resultsInfo2.add(
                  ToolResultInfo(
                    id: id,
                    name: name,
                    arguments: args,
                    content: res,
                  ),
                );
              }
              if (resultsInfo2.isNotEmpty) {
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: usage?.totalTokens ?? 0,
                  usage: usage,
                  toolResults: resultsInfo2,
                );
              }
              // 追加供下一轮循环使用——包括本轮累积的任何内容
              final nextAssistantToolCall = _buildAssistantToolCallMessage(
                calls: calls2,
                content: contentAccum,
                reasoningContent: needsReasoningEcho ? reasoningAccum : null,
                includeEmptyReasoningContent: needsReasoningEcho,
                reasoningDetails: reasoningDetailsAccum.detailsOrNull,
              );
              currentMessages = [
                ...currentMessages,
                nextAssistantToolCall,
                for (final r in results2)
                  {
                    'role': 'tool',
                    'tool_call_id': r['tool_call_id'],
                    'name': calls2.firstWhere(
                      (c) => c['id'] == r['tool_call_id'],
                      orElse: () => const {
                        'function': {'name': ''},
                      },
                    )['function']['name'],
                    'content': r['content'],
                  },
              ];
              // 继续循环
              continue;
            } else {
              // 没有更多工具调用；结束
              final approxTotal =
                  approxPromptTokens +
                  approxTokensFromChars(approxCompletionChars);
              yield ChatStreamChunk(
                content: '',
                reasoningDetails: reasoningDetailsAccum.detailsOrNull,
                isDone: true,
                totalTokens: usage?.totalTokens ?? approxTotal,
                usage: usage,
              );
              return;
            }
          }
        }

        final approxTotal =
            approxPromptTokens + approxTokensFromChars(approxCompletionChars);
        yield ChatStreamChunk(
          content: '',
          reasoningDetails: reasoningDetailsBuffer.detailsOrNull,
          isDone: true,
          totalTokens: usage?.totalTokens ?? approxTotal,
          usage: usage,
        );
        return;
      }

      _throwIfInBandStreamError(data);
      try {
        final json = jsonDecode(data);
        String content = '';
        String? reasoning;

        if (config.useResponseApi == true) {
          // OpenAI /responses 的 SSE 类型
          final type = json['type'];
          if (type == 'response.output_text.delta') {
            final delta = json['delta'];
            if (delta is String) {
              content = delta;
              approxCompletionChars += content.length;
            }
          } else if (type == 'response.reasoning_summary_text.delta' ||
              type == 'response.reasoning_text.delta') {
            final delta = json['delta'];
            if (delta is String) reasoning = delta;
          } else if (type == 'response.output_item.added') {
            try {
              final item = json['item'];
              final idx = (json['output_index'] ?? 0) as int;
              if (item is Map && (item['type'] ?? '') == 'function_call') {
                final name = (item['name'] ?? '').toString();
                final callId = (item['call_id'] ?? '').toString();
                respToolCallsByIndex[idx] = {
                  'call_id': callId,
                  'name': name,
                  'args': '',
                };
              } else if (item is Map &&
                  _isResponsesImageGenerationType(item['type'])) {
                responsesImagesByIndex.putIfAbsent(
                  idx,
                  () => const _ResponsesImageGenerationResult(),
                );
              }
            } catch (_) {}
          } else if (type == 'response.image_generation_call.partial_image') {
            try {
              final b64 = (json['partial_image_b64'] ?? '').toString();
              if (b64.isNotEmpty) {
                final idx = (json['output_index'] ?? 0) as int;
                responsesImagesByIndex[idx] = _ResponsesImageGenerationResult(
                  base64: b64,
                  outputFormat: (json['output_format'] ?? '').toString(),
                );
              }
            } catch (_) {}
          } else if (type == 'response.function_call_arguments.delta') {
            try {
              final idx = (json['output_index'] ?? 0) as int;
              final delta = (json['delta'] ?? '').toString();
              final entry = respToolCallsByIndex.putIfAbsent(
                idx,
                () => {'call_id': '', 'name': '', 'args': ''},
              );
              if (delta.isNotEmpty) {
                entry['args'] = (entry['args'] ?? '') + delta;
              }
            } catch (_) {}
          } else if (type == 'response.output_item.done') {
            try {
              final item = json['item'];
              final idx = (json['output_index'] ?? 0) as int;
              if (item is Map && (item['type'] ?? '') == 'function_call') {
                final args = (item['arguments'] ?? '').toString();
                final entry = respToolCallsByIndex.putIfAbsent(
                  idx,
                  () => {
                    'call_id': (item['call_id'] ?? '').toString(),
                    'name': (item['name'] ?? '').toString(),
                    'args': '',
                  },
                );
                if (args.isNotEmpty) entry['args'] = args;
              } else if (item is Map &&
                  _isResponsesImageGenerationType(item['type'])) {
                final b64 = (item['result'] ?? '').toString();
                if (b64.isNotEmpty) {
                  responsesImagesByIndex[idx] = _ResponsesImageGenerationResult(
                    base64: b64,
                    outputFormat: (item['output_format'] ?? '').toString(),
                  );
                }
              }
            } catch (_) {}
          } else if (type is String && type.contains('function_call')) {
            // 为 Responses API 累积函数调用参数
            final id = (json['id'] ?? json['call_id'] ?? '').toString();
            final name = (json['name'] ?? json['function']?['name'] ?? '')
                .toString();
            final argsDelta =
                (json['arguments'] ??
                        json['arguments_delta'] ??
                        json['delta'] ??
                        '')
                    .toString();
            if (id.isNotEmpty || name.isNotEmpty) {
              final key = id.isNotEmpty ? id : name;
              final entry = toolAccResp.putIfAbsent(
                key,
                () => {'name': name, 'args': ''},
              );
              if (name.isNotEmpty) entry['name'] = name;
              if (argsDelta.isNotEmpty) {
                entry['args'] = (entry['args'] ?? '') + argsDelta;
              }
            }
          } else if (type == 'response.completed') {
            final u = json['response']?['usage'];
            if (u != null) {
              usage = _mergeOpenAICompatibleUsage(usage, u);
              totalTokens = usage?.totalTokens ?? totalTokens;
            }
            // 从最终输出中提取网页搜索引用（Responses API）
            try {
              final output = json['response']?['output'];
              final items = <Map<String, dynamic>>[];
              final completedImageIndexes = <int>{};
              // 保存输出项，作为可能的后续调用输入
              lastResponseOutputItems = const <Map<String, dynamic>>[];
              if (output is List) {
                lastResponseOutputItems = [
                  for (final it in output)
                    if (it is Map) (it.cast<String, dynamic>()),
                ];
              }
              if (output is List) {
                int idx = 1;
                final seen = <String>{};
                for (
                  int outputIndex = 0;
                  outputIndex < output.length;
                  outputIndex++
                ) {
                  final it = output[outputIndex];
                  if (it is! Map) continue;
                  if (it['type'] == 'message') {
                    final content = it['content'] as List? ?? const <dynamic>[];
                    for (final block in content) {
                      if (block is! Map) continue;
                      final anns =
                          block['annotations'] as List? ?? const <dynamic>[];
                      for (final an in anns) {
                        if (an is! Map) continue;
                        if ((an['type'] ?? '') == 'url_citation') {
                          final url = (an['url'] ?? '').toString();
                          if (url.isEmpty || seen.contains(url)) continue;
                          final title = (an['title'] ?? '').toString();
                          items.add({
                            'index': idx,
                            'url': url,
                            if (title.isNotEmpty) 'title': title,
                          });
                          seen.add(url);
                          idx += 1;
                        }
                      }
                    }
                  } else if (_isResponsesImageGenerationType(it['type'])) {
                    // 处理来自 OpenAI Responses API 的图像生成输出，
                    // it['result'] 包含 base64 图像数据或 data URL。
                    final b64 = (it['result'] ?? '').toString();
                    if (b64.isNotEmpty) {
                      completedImageIndexes.add(outputIndex);
                      final mdImg = await _saveResponsesImageGenerationMarkdown(
                        b64,
                        outputFormat: (it['output_format'] ?? '').toString(),
                      );
                      if (mdImg.isNotEmpty) {
                        yield ChatStreamChunk(
                          content: mdImg,
                          isDone: false,
                          totalTokens: totalTokens,
                          usage: usage,
                        );
                      }
                    }
                  }
                }
              }
              if (responsesImagesByIndex.isNotEmpty) {
                final sortedIndexes = responsesImagesByIndex.keys.toList()
                  ..sort();
                for (final index in sortedIndexes) {
                  if (completedImageIndexes.contains(index)) continue;
                  final image = responsesImagesByIndex[index];
                  if (image == null || image.base64.isEmpty) continue;
                  final mdImg = await _saveResponsesImageGenerationMarkdown(
                    image.base64,
                    outputFormat: image.outputFormat,
                  );
                  if (mdImg.isNotEmpty) {
                    yield ChatStreamChunk(
                      content: mdImg,
                      isDone: false,
                      totalTokens: totalTokens,
                      usage: usage,
                    );
                  }
                }
                responsesImagesByIndex.clear();
              }
              if (items.isNotEmpty) {
                final payload = jsonEncode({'items': items});
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: totalTokens,
                  usage: usage,
                  toolResults: [
                    ToolResultInfo(
                      id: 'builtin_search',
                      name: 'search_web',
                      arguments: const <String, dynamic>{},
                      content: payload,
                    ),
                  ],
                );
              }
            } catch (_) {}
            // Responses 工具调用的后续处理
            final bool hasRespCalls =
                respToolCallsByIndex.isNotEmpty || toolAccResp.isNotEmpty;
            if (effectiveOnToolCall != null && hasRespCalls) {
              // 优先使用带索引的调用（含 call_id）；回退到 toolAccResp
              final callInfos = <ToolCallInfo>[];
              final msgs = <Map<String, dynamic>>[]; // 用于执行工具
              if (respToolCallsByIndex.isNotEmpty) {
                final sorted = respToolCallsByIndex.keys.toList()..sort();
                for (final idx in sorted) {
                  final m = respToolCallsByIndex[idx]!;
                  final callId = (m['call_id'] ?? '').toString();
                  final name = (m['name'] ?? '').toString();
                  Map<String, dynamic> args;
                  try {
                    args = (jsonDecode(m['args'] ?? '{}') as Map)
                        .cast<String, dynamic>();
                  } catch (_) {
                    args = <String, dynamic>{};
                  }
                  final id = _effectiveToolCallId(callId, 'call', idx);
                  callInfos.add(
                    ToolCallInfo(id: id, name: name, arguments: args),
                  );
                  msgs.add({'__id': id, '__name': name, '__args': args});
                }
              } else {
                int idx = 0;
                toolAccResp.forEach((key, m) {
                  Map<String, dynamic> args;
                  try {
                    args = (jsonDecode(m['args'] ?? '{}') as Map)
                        .cast<String, dynamic>();
                  } catch (_) {
                    args = <String, dynamic>{};
                  }
                  final id2 = _effectiveToolCallId(key, 'call', idx);
                  callInfos.add(
                    ToolCallInfo(
                      id: id2,
                      name: (m['name'] ?? ''),
                      arguments: args,
                    ),
                  );
                  msgs.add({
                    '__id': id2,
                    '__name': (m['name'] ?? ''),
                    '__args': args,
                  });
                  idx += 1;
                });
              }
              if (callInfos.isNotEmpty) {
                final approxTotal =
                    approxPromptTokens +
                    approxTokensFromChars(approxCompletionChars);
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: usage?.totalTokens ?? approxTotal,
                  usage: usage,
                  toolCalls: callInfos,
                );
              }
              final responseOutputItems = _withResponsesFunctionCallItems(
                lastResponseOutputItems,
                callInfos,
              );
              final resultsInfo = <ToolResultInfo>[];
              final followUpOutputs = <Map<String, dynamic>>[];
              for (final m in msgs) {
                final nm = m['__name'] as String;
                final id2 = m['__id'] as String;
                final args = (m['__args'] as Map<String, dynamic>);
                final res = await effectiveOnToolCall(
                  nm,
                  args,
                  toolCallId: id2,
                );
                resultsInfo.add(
                  ToolResultInfo(
                    id: id2,
                    name: nm,
                    arguments: args,
                    content: res,
                  ),
                );
                followUpOutputs.add({
                  'type': 'function_call_output',
                  'call_id': id2,
                  'output': res,
                });
              }
              if (resultsInfo.isNotEmpty) {
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: usage?.totalTokens ?? 0,
                  usage: usage,
                  toolResults: resultsInfo,
                );
              }

              // 构建后续 Responses 请求输入
              List<Map<String, dynamic>> currentInput = <Map<String, dynamic>>[
                ...responsesInitialInput,
              ];
              if (responseOutputItems.isNotEmpty) {
                currentInput.addAll(responseOutputItems);
              }
              currentInput.addAll(followUpOutputs);

              // 迭代请求，直到模型停止发出工具调用，
              // 这与 Claude、Gemini 和 OpenAI Chat Completions
              // 提供程序处理工具调用循环的方式一致（while-true 直到完成）。
              // 防护：如果完全相同的工具调用集合连续重复 3 次，
              // 则中断循环，因为这表明模型陷入了循环。
              const int maxConsecutiveDupes = 3;
              String? lastToolSignature;
              int consecutiveDupeCount = 0;
              while (true) {
                final body2 = <String, dynamic>{
                  'model': upstreamModelId,
                  'input': currentInput,
                  'stream': true,
                  if (responsesToolsSpec.isNotEmpty)
                    'tools': responsesToolsSpec,
                  if (responsesToolsSpec.isNotEmpty) 'tool_choice': 'auto',
                  if (responsesInstructions.isNotEmpty)
                    'instructions': responsesInstructions,
                  if (temperature != null) 'temperature': temperature,
                  if (topP != null) 'top_p': topP,
                  if (maxTokens != null) 'max_output_tokens': maxTokens,
                  if (isReasoning && effort != 'off')
                    'reasoning': {
                      'summary': 'auto',
                      if (effort != 'auto') 'effort': effort,
                    },
                  if (responsesIncludeParam != null)
                    'include': responsesIncludeParam,
                };
                _applyCompatibleResponsesReasoning(
                  body2,
                  config: config,
                  modelId: modelId,
                  upstreamModelId: upstreamModelId,
                  isReasoning: isReasoning,
                  thinkingBudget: thinkingBudget,
                );

                // 应用覆盖项
                final extraCfg = _customBody(
                  config,
                  modelId,
                  assistantBody: extraBody,
                );
                if (extraCfg.isNotEmpty) body2.addAll(extraCfg);
                // 确保工具已展平
                try {
                  if (body2['tools'] is List) {
                    final raw = (body2['tools'] as List).cast<dynamic>();
                    body2['tools'] = _toResponsesToolsFormat(
                      raw
                          .map((e) => (e as Map).cast<String, dynamic>())
                          .toList(),
                    );
                  }
                } catch (_) {}

                _sanitizeOpenAIGpt5SamplingParams(
                  body2,
                  upstreamModelId,
                  fallbackEffort: effort,
                  isOpenRouter: info.isOpenRouter,
                );

                final req2 = http.Request('POST', url);
                final headers2 = _customHeaders(
                  config,
                  modelId,
                  baseHeaders: <String, String>{
                    'Authorization':
                        'Bearer ${_apiKeyForRequest(config, modelId)}',
                    'Content-Type': 'application/json',
                    'Accept': 'text/event-stream',
                  },
                  assistantHeaders: extraHeaders,
                );
                req2.headers.addAll(headers2);
                req2.body = jsonEncode(body2);
                final http.StreamedResponse resp2;
                try {
                  resp2 = await client.send(req2);
                  if (resp2.statusCode < 200 || resp2.statusCode >= 300) {
                    final errorBody = await resp2.stream.bytesToString();
                    throw HttpException('HTTP ${resp2.statusCode}: $errorBody');
                  }
                } on HttpException {
                  rethrow;
                } catch (e) {
                  // 保留为 HttpException，以便下面的逐事件捕获逻辑（它会
                  // 容忍格式错误的 JSON）无法吞掉此失败。
                  throw HttpException('Follow-up request failed: $e');
                }
                final s2 = _rethrowFollowUpStreamErrors(
                  resp2.stream.transform(utf8.decoder),
                );
                String buf2 = '';
                final Map<int, Map<String, String>> respCalls2 =
                    <int, Map<String, String>>{};
                List<Map<String, dynamic>> outItems2 =
                    const <Map<String, dynamic>>[];
                await for (final ch in _ensureTrailingNewline(s2)) {
                  buf2 += ch;
                  final lines2 = buf2.split('\n');
                  buf2 = lines2.last;
                  for (int j = 0; j < lines2.length - 1; j++) {
                    final l = lines2[j].trim();
                    if (l.isEmpty || !l.startsWith('data:')) continue;
                    final d = l.substring(5).trimLeft();
                    if (d == '[DONE]') continue;
                    _throwIfInBandStreamError(d);
                    try {
                      final o = jsonDecode(d);
                      if (o is Map &&
                          (o['type'] ?? '') == 'response.output_text.delta') {
                        final delta = (o['delta'] ?? '').toString();
                        if (delta.isNotEmpty) {
                          approxCompletionChars += delta.length;
                          yield ChatStreamChunk(
                            content: delta,
                            isDone: false,
                            totalTokens: 0,
                            usage: usage,
                          );
                        }
                      } else if (o is Map &&
                          (o['type'] ?? '') == 'response.output_item.added') {
                        final item = o['item'];
                        final idx2 = (o['output_index'] ?? 0) as int;
                        if (item is Map &&
                            (item['type'] ?? '') == 'function_call') {
                          respCalls2[idx2] = {
                            'call_id': (item['call_id'] ?? '').toString(),
                            'name': (item['name'] ?? '').toString(),
                            'args': '',
                          };
                        }
                      } else if (o is Map &&
                          (o['type'] ?? '') ==
                              'response.function_call_arguments.delta') {
                        final idx2 = (o['output_index'] ?? 0) as int;
                        final delta = (o['delta'] ?? '').toString();
                        final entry = respCalls2.putIfAbsent(
                          idx2,
                          () => {'call_id': '', 'name': '', 'args': ''},
                        );
                        if (delta.isNotEmpty) {
                          entry['args'] = (entry['args'] ?? '') + delta;
                        }
                      } else if (o is Map &&
                          (o['type'] ?? '') == 'response.output_item.done') {
                        final item = o['item'];
                        final idx2 = (o['output_index'] ?? 0) as int;
                        if (item is Map &&
                            (item['type'] ?? '') == 'function_call') {
                          final args = (item['arguments'] ?? '').toString();
                          final entry = respCalls2.putIfAbsent(
                            idx2,
                            () => {
                              'call_id': (item['call_id'] ?? '').toString(),
                              'name': (item['name'] ?? '').toString(),
                              'args': '',
                            },
                          );
                          if (args.isNotEmpty) entry['args'] = args;
                        }
                      } else if (o is Map &&
                          (o['type'] ?? '') == 'response.completed') {
                        // 用量
                        final u2 = o['response']?['usage'];
                        if (u2 != null) {
                          usage = _mergeOpenAICompatibleUsage(usage, u2);
                          totalTokens = usage?.totalTokens ?? totalTokens;
                        }
                        // 捕获输出项
                        final out2 = o['response']?['output'];
                        if (out2 is List) {
                          outItems2 = [
                            for (final it in out2)
                              if (it is Map) (it.cast<String, dynamic>()),
                          ];
                        }
                      }
                    } catch (_) {}
                  }
                }

                if (respCalls2.isEmpty) {
                  // 没有更多工具调用；完成收尾
                  final approxTotal2 =
                      approxPromptTokens +
                      approxTokensFromChars(approxCompletionChars);
                  yield ChatStreamChunk(
                    content: '',
                    reasoning: null,
                    isDone: true,
                    totalTokens: usage?.totalTokens ?? approxTotal2,
                    usage: usage,
                  );
                  return;
                }

                // 检测连续重复的工具调用模式
                final sorted2 = respCalls2.keys.toList()..sort();
                final sigParts = <String>[];
                for (final idx2 in sorted2) {
                  final m2 = respCalls2[idx2]!;
                  sigParts.add('${m2['name'] ?? ''}:${m2['args'] ?? ''}');
                }
                final currentSig = sigParts.join('|');
                if (currentSig == lastToolSignature) {
                  consecutiveDupeCount += 1;
                  if (consecutiveDupeCount >= maxConsecutiveDupes) {
                    // 跳出循环：模型卡在重复执行相同调用
                    break;
                  }
                } else {
                  lastToolSignature = currentSig;
                  consecutiveDupeCount = 1;
                }

                // 执行下一轮工具调用
                final callInfos2 = <ToolCallInfo>[];
                final msgs2 = <Map<String, dynamic>>[];
                for (final idx2 in sorted2) {
                  final m2 = respCalls2[idx2]!;
                  final callId2 = (m2['call_id'] ?? '').toString();
                  final name2 = (m2['name'] ?? '').toString();
                  Map<String, dynamic> args2;
                  try {
                    args2 = (jsonDecode(m2['args'] ?? '{}') as Map)
                        .cast<String, dynamic>();
                  } catch (_) {
                    args2 = <String, dynamic>{};
                  }
                  final id2 = _effectiveToolCallId(callId2, 'call', idx2);
                  callInfos2.add(
                    ToolCallInfo(id: id2, name: name2, arguments: args2),
                  );
                  msgs2.add({'__id': id2, '__name': name2, '__args': args2});
                }
                if (callInfos2.isNotEmpty) {
                  final approxTotal =
                      approxPromptTokens +
                      approxTokensFromChars(approxCompletionChars);
                  yield ChatStreamChunk(
                    content: '',
                    isDone: false,
                    totalTokens: usage?.totalTokens ?? approxTotal,
                    usage: usage,
                    toolCalls: callInfos2,
                  );
                }
                final responseOutputItems2 = _withResponsesFunctionCallItems(
                  outItems2,
                  callInfos2,
                );
                final resultsInfo2 = <ToolResultInfo>[];
                final followUpOutputs2 = <Map<String, dynamic>>[];
                for (final m in msgs2) {
                  final nm = m['__name'] as String;
                  final id2 = m['__id'] as String;
                  final args2 = (m['__args'] as Map<String, dynamic>);
                  final res2 = await effectiveOnToolCall(
                    nm,
                    args2,
                    toolCallId: id2,
                  );
                  resultsInfo2.add(
                    ToolResultInfo(
                      id: id2,
                      name: nm,
                      arguments: args2,
                      content: res2,
                    ),
                  );
                  followUpOutputs2.add({
                    'type': 'function_call_output',
                    'call_id': id2,
                    'output': res2,
                  });
                }
                if (resultsInfo2.isNotEmpty) {
                  yield ChatStreamChunk(
                    content: '',
                    isDone: false,
                    totalTokens: usage?.totalTokens ?? 0,
                    usage: usage,
                    toolResults: resultsInfo2,
                  );
                }
                // 使用本轮的模型输出和我们的输出来扩展当前输入
                if (responseOutputItems2.isNotEmpty) {
                  currentInput.addAll(responseOutputItems2);
                }
                currentInput.addAll(followUpOutputs2);
              }

              // 安全保护
              final approxTotal =
                  approxPromptTokens +
                  approxTokensFromChars(approxCompletionChars);
              yield ChatStreamChunk(
                content: '',
                reasoning: null,
                isDone: true,
                totalTokens: usage?.totalTokens ?? approxTotal,
                usage: usage,
              );
              return;
            }

            final approxTotal =
                approxPromptTokens +
                approxTokensFromChars(approxCompletionChars);
            yield ChatStreamChunk(
              content: '',
              reasoning: null,
              isDone: true,
              totalTokens: usage?.totalTokens ?? approxTotal,
              usage: usage,
            );
            return;
          } else {
            // 为内联输出的提供程序提供回退方案
            final output = json['output'];
            if (output != null) {
              content = (output['content'] ?? '').toString();
              approxCompletionChars += content.length;
              final u = json['usage'];
              if (u != null) {
                usage = _mergeOpenAICompatibleUsage(usage, u);
                totalTokens = usage?.totalTokens ?? totalTokens;
              }
            }
          }
        } else {
          // 处理标准 OpenAI Chat Completions 格式
          final choices = json['choices'];
          if (choices != null && choices.isNotEmpty) {
            final c0 = choices[0];
            finishReason = c0['finish_reason'] as String?;
            // if (finishReason != null) {
            //   print('[ChatApi] Received finishReason from choices: $finishReason');
            // }

            // 某些提供程序可能在 SSE 分块中同时包含 delta 和 message.content。
            // 优先使用 delta，然后回退到 message.content；如果两者都存在则合并。
            final message = c0['message'];
            final delta = c0['delta'];

            // 1) 首先解析 delta
            if (delta != null) {
              // 流式格式：choices[0].delta.content
              final dc = delta['content'];
              final deltaContent = _extractOpenAICompatibleDeltaText(delta);
              if (deltaContent.isNotEmpty) {
                content += deltaContent;
                approxCompletionChars += deltaContent.length;
              }

              // reasoning_content 处理（保持不变）
              final rc =
                  (delta['reasoning_content'] ?? delta['reasoning']) as String?;
              if (rc != null && rc.isNotEmpty) {
                reasoning = rc;
                if (needsReasoningEcho) reasoningBuffer += rc;
              }
              // 从发送这些信息的任何提供方捕获供应商推理详情（可能带有思考
              // 签名）。
              final rdDelta = delta['reasoning_details'];
              if (rdDelta is List && rdDelta.isNotEmpty) {
                reasoningDetailsBuffer.add(rdDelta);
              }

              // 来自 delta 的 images 处理（保持不变）
              if (wantsImageOutput) {
                final List<dynamic> imageItems = <dynamic>[];
                final imgs = delta['images'];
                if (imgs is List) imageItems.addAll(imgs);
                if (dc is List) {
                  for (final it in dc) {
                    if (it is Map &&
                        (it['type'] == 'image_url' || it['type'] == 'image')) {
                      imageItems.add(it);
                    }
                  }
                }
                final singleImage = delta['image_url'];
                if (singleImage is Map || singleImage is String) {
                  imageItems.add({
                    'type': 'image_url',
                    'image_url': singleImage,
                  });
                }
                if (imageItems.isNotEmpty) {
                  final buf = StringBuffer();
                  for (final it in imageItems) {
                    if (it is! Map) continue;
                    dynamic iu = it['image_url'];
                    String? url;
                    if (iu is String) {
                      url = iu;
                    } else if (iu is Map) {
                      final u2 = iu['url'];
                      if (u2 is String) url = u2;
                    }
                    if (url != null && url.isNotEmpty) {
                      buf.write('\n\n![image]($url)');
                    }
                  }
                  if (buf.isNotEmpty) content = content + buf.toString();
                }
              }

              // 来自 delta 的 tool_calls 处理（保持不变）
              final tcs = delta['tool_calls'] as List?;
              if (tcs != null) {
                for (final t in tcs) {
                  final idx = (t['index'] as int?) ?? 0;
                  final id = t['id'] as String?;
                  final func = t['function'] as Map<String, dynamic>?;
                  final name = func?['name'] as String?;
                  final argsDelta = func?['arguments'] as String?;
                  final entry = toolAcc.putIfAbsent(
                    idx,
                    () => {'id': '', 'name': '', 'args': ''},
                  );
                  if (id != null) entry['id'] = id;
                  if (name != null && name.isNotEmpty) entry['name'] = name;
                  if (argsDelta != null && argsDelta.isNotEmpty) {
                    entry['args'] = (entry['args'] ?? '') + argsDelta;
                  }
                }
              }
            }

            if (message != null) {
              final rdMsg = message['reasoning_details'];
              if (rdMsg is List && rdMsg.isNotEmpty) {
                reasoningDetailsBuffer.add(rdMsg);
              }
            }

            // 2) 回退并合并：解析 choices[0].message.content
            if (message != null && message['content'] != null) {
              final mc = message['content'];
              String messageContent = '';
              if (mc is String) {
                messageContent = mc;
              } else if (mc is List) {
                final sb = StringBuffer();
                for (final it in mc) {
                  if (it is Map) {
                    final t = (it['text'] ?? '') as String? ?? '';
                    if (t.isNotEmpty &&
                        (it['type'] == null || it['type'] == 'text')) {
                      sb.write(t);
                    }
                  }
                }
                messageContent = sb.toString();
              } else {
                messageContent = (mc ?? '').toString();
              }
              if (messageContent.isNotEmpty) {
                content += messageContent;
                approxCompletionChars += messageContent.length;
              }

              // 如果仅存在于 message 对象上，则捕获 reasoning_content
              if (message != null) {
                final rcMsg =
                    message['reasoning_content'] ?? message['reasoning'];
                if (rcMsg is String && rcMsg.isNotEmpty) {
                  if (needsReasoningEcho) reasoningBuffer += rcMsg;
                  reasoning ??= rcMsg;
                }
              }

              // 来自 message content 的 images 处理（保持不变）
              if (wantsImageOutput && mc is List) {
                final List<dynamic> imageItems = <dynamic>[];
                for (final it in mc) {
                  if (it is Map &&
                      (it['type'] == 'image_url' || it['type'] == 'image')) {
                    imageItems.add(it);
                  }
                }
                if (imageItems.isNotEmpty) {
                  final buf = StringBuffer();
                  for (final it in imageItems) {
                    if (it is! Map) continue;
                    dynamic iu = it['image_url'];
                    String? url;
                    if (iu is String) {
                      url = iu;
                    } else if (iu is Map) {
                      final u2 = iu['url'];
                      if (u2 is String) url = u2;
                    }
                    if (url != null && url.isNotEmpty) {
                      buf.write('\n\n![image]($url)');
                    }
                  }
                  if (buf.isNotEmpty) content = content + buf.toString();
                }
              }
            }
          }
          // XinLiu（iflow.cn）兼容：tool_calls 位于根级别而不是 delta
          final rootToolCalls = json['tool_calls'] as List?;
          if (rootToolCalls != null) {
            // print('[ChatApi/XinLiu] Detected root-level tool_calls, count: ${rootToolCalls.length}, original finishReason: $finishReason');
            // print('[ChatApi/XinLiu] Full JSON keys: ${json.keys.toList()}');
            // print('[ChatApi/XinLiu] Full JSON: ${jsonEncode(json)}');
            for (final t in rootToolCalls) {
              if (t is! Map) continue;
              final id = (t['id'] ?? '').toString();
              final type = (t['type'] ?? 'function').toString();
              if (type != 'function') continue;
              final func = t['function'] as Map<String, dynamic>?;
              if (func == null) continue;
              final name = (func['name'] ?? '').toString();
              final argsStr = (func['arguments'] ?? '').toString();
              if (name.isEmpty) continue;
              // print('[ChatApi/XinLiu] Tool call: id=$id, name=$name, args=${argsStr.length} chars');
              final idx = toolAcc.length;
              final entry = toolAcc.putIfAbsent(
                idx,
                () => {
                  'id': _effectiveToolCallId(id, 'call', idx),
                  'name': name,
                  'args': argsStr,
                },
              );
              if (id.isNotEmpty) entry['id'] = id;
              entry['name'] = name;
              entry['args'] = argsStr;
            }
            // 当存在根级别 tool_calls 时，始终视为 tool_calls 结束原因
            // （覆盖提供方返回的任何其他 finish_reason）
            if (rootToolCalls.isNotEmpty) {
              // print('[ChatApi/XinLiu] Overriding finishReason from "$finishReason" to "tool_calls"');
              finishReason = 'tool_calls';
            }
          }
          usage = _mergeOpenAICompatibleUsage(usage, json['usage']);
          if (usage != null) totalTokens = usage.totalTokens;
        }

        if (content.isNotEmpty || (reasoning?.isNotEmpty ?? false)) {
          final approxTotal =
              approxPromptTokens + approxTokensFromChars(approxCompletionChars);
          if (content.isNotEmpty) {
            assistantContentBuffer += content;
          }
          yield ChatStreamChunk(
            content: content,
            reasoning: reasoning,
            isDone: false,
            totalTokens: totalTokens > 0 ? totalTokens : approxTotal,
            usage: usage,
          );
        }

        // 一些提供方（例如 OpenRouter）可能会省略 [DONE] 哨兵标记，
        // 并且只在最后一个 delta 上发送 finish_reason。如果我们看到
        // 一个不是 tool_calls 的明确结束，则立即结束流，以便
        // UI 可以持久化消息。
        // XinLiu 兼容：如果 finish_reason='tool_calls' 且已累积调用，则立即执行工具
        if (config.useResponseApi != true &&
            finishReason == 'tool_calls' &&
            toolAcc.isNotEmpty &&
            effectiveOnToolCall != null) {
          // print('[ChatApi/XinLiu] Executing tools immediately (finishReason=tool_calls, toolAcc.size=${toolAcc.length})');
          // 一些提供方（如 XinLiu）返回 tool_calls 且 finish_reason='tool_calls'，但没有 [DONE]
          // 这种情况下立即执行工具
          final calls = <Map<String, dynamic>>[];
          final callInfos = <ToolCallInfo>[];
          final toolMsgs = <Map<String, dynamic>>[];
          toolAcc.forEach((idx, m) {
            final id = _effectiveToolCallId(m['id'], 'call', idx);
            final name = (m['name'] ?? '');
            Map<String, dynamic> args;
            try {
              args = (jsonDecode(m['args'] ?? '{}') as Map)
                  .cast<String, dynamic>();
            } catch (_) {
              args = <String, dynamic>{};
            }
            callInfos.add(ToolCallInfo(id: id, name: name, arguments: args));
            calls.add({
              'id': id,
              'type': 'function',
              'function': {'name': name, 'arguments': jsonEncode(args)},
            });
            toolMsgs.add({'__name': name, '__id': id, '__args': args});
          });
          if (callInfos.isNotEmpty) {
            final approxTotal =
                approxPromptTokens +
                approxTokensFromChars(approxCompletionChars);
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: usage?.totalTokens ?? approxTotal,
              usage: usage,
              toolCalls: callInfos,
            );
          }
          // 执行工具并发出结果
          final results = <Map<String, dynamic>>[];
          final resultsInfo = <ToolResultInfo>[];
          for (final m in toolMsgs) {
            final name = m['__name'] as String;
            final id = m['__id'] as String;
            final args = (m['__args'] as Map<String, dynamic>);
            final res = await effectiveOnToolCall(name, args, toolCallId: id);
            results.add({'tool_call_id': id, 'content': res});
            resultsInfo.add(
              ToolResultInfo(id: id, name: name, arguments: args, content: res),
            );
          }
          if (resultsInfo.isNotEmpty) {
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: usage?.totalTokens ?? 0,
              usage: usage,
              toolResults: resultsInfo,
            );
          }
          // 构建后续消息
          final mm2 = <Map<String, dynamic>>[];
          for (final m in messages) {
            mm2.add(_copyChatCompletionMessage(m));
          }
          final assistantToolCallMsg = _buildAssistantToolCallMessage(
            calls: calls,
            content: assistantContentBuffer,
            reasoningContent: needsReasoningEcho ? reasoningBuffer : null,
            includeEmptyReasoningContent: needsReasoningEcho,
            reasoningDetails: reasoningDetailsBuffer.detailsOrNull,
          );
          mm2.add(assistantToolCallMsg);
          for (final r in results) {
            final id = r['tool_call_id'];
            final name = calls.firstWhere(
              (c) => c['id'] == id,
              orElse: () => const {
                'function': {'name': ''},
              },
            )['function']['name'];
            mm2.add({
              'role': 'tool',
              'tool_call_id': id,
              'name': name,
              'content': r['content'],
            });
          }
          // 使用后续请求继续流式传输
          var currentMessages = mm2;
          while (true) {
            final Map<String, dynamic> body2 = {
              'model': upstreamModelId,
              'messages': await _buildOpenAIChatCompletionMessages(
                currentMessages,
                userMediaPaths: userImagePaths,
                canImageInput: canImageInput,
                allowRemoteImages: allowRemoteImages,
                reasoningContentReplayPolicy: info.reasoningContentReplayPolicy,
                stripReasoningContent: isClaudeUpstream,
              ),
              'stream': true,
              if (temperature != null) 'temperature': temperature,
              if (topP != null) 'top_p': topP,
              if (isReasoning && effort != 'off' && effort != 'auto')
                'reasoning_effort': effort,
              if (tools != null && tools.isNotEmpty)
                'tools': _cleanToolsForCompatibility(tools),
              if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
            };
            setMaxTokens(body2);
            _applyVendorReasoningKnobs(
              body2,
              info: info,
              isReasoning: isReasoning,
              thinkingBudget: thinkingBudget,
            );
            _applyCompatibleBuiltInSearch(
              body2,
              config: config,
              modelId: modelId,
              upstreamModelId: upstreamModelId,
            );
            _maybeAddStreamingUsageOptions(
              body2,
              stream: true,
              config: config,
              host: info.host,
            );
            if (extraBodyCfg.isNotEmpty) {
              body2.addAll(extraBodyCfg);
            }
            _sanitizeOpenAIGpt5SamplingParams(
              body2,
              upstreamModelId,
              fallbackEffort: effort,
              isOpenRouter: info.isOpenRouter,
            );
            _normalizeMoonshotKimiChatBody(
              body2,
              upstreamModelId: upstreamModelId,
              isReasoning: isReasoning,
              thinkingBudget: thinkingBudget,
            );
            final req2 = http.Request('POST', url);
            final headers2 = _customHeaders(
              config,
              modelId,
              baseHeaders: <String, String>{
                'Authorization': 'Bearer ${_apiKeyForRequest(config, modelId)}',
                'Content-Type': 'application/json',
                'Accept': 'text/event-stream',
              },
              assistantHeaders: extraHeaders,
            );
            req2.headers.addAll(headers2);
            req2.body = jsonEncode(body2);
            final http.StreamedResponse resp2;
            try {
              resp2 = await client.send(req2);
              if (resp2.statusCode < 200 || resp2.statusCode >= 300) {
                final errorBody = await resp2.stream.bytesToString();
                throw HttpException('HTTP ${resp2.statusCode}: $errorBody');
              }
            } on HttpException {
              rethrow;
            } catch (e) {
              // 保持为 HttpException，以便下面逐事件捕获（它
              // 容忍格式错误的 JSON）不能吞掉此失败。
              throw HttpException('Follow-up request failed: $e');
            }
            final s2 = _rethrowFollowUpStreamErrors(
              resp2.stream.transform(utf8.decoder),
            );
            String buf2 = '';
            final Map<int, Map<String, String>> toolAcc2 =
                <int, Map<String, String>>{};
            String? finishReason2;
            String contentAccum = '';
            String reasoningAccum = '';
            final reasoningDetailsAccum = _ReasoningDetailsAccumulator(
              allowSnapshots: reasoningDetailsAllowSnapshots,
            );
            await for (final ch in _ensureTrailingNewline(s2)) {
              buf2 += ch;
              final lines2 = buf2.split('\n');
              buf2 = lines2.last;
              for (int j = 0; j < lines2.length - 1; j++) {
                final l = lines2[j].trim();
                if (l.isEmpty || !l.startsWith('data:')) continue;
                final d = l.substring(5).trimLeft();
                if (d == '[DONE]') {
                  continue;
                }
                _throwIfInBandStreamError(d);
                try {
                  final o = jsonDecode(d);
                  if (o is Map) {
                    usage = _mergeOpenAICompatibleUsage(usage, o['usage']);
                    if (usage != null) totalTokens = usage.totalTokens;
                  }
                  if (o is Map &&
                      o['choices'] is List &&
                      (o['choices'] as List).isNotEmpty) {
                    final c0 = (o['choices'] as List).first;
                    finishReason2 = c0['finish_reason'] as String?;
                    final delta = c0['delta'] as Map?;
                    final txt = _extractOpenAICompatibleDeltaText(delta);
                    final rc =
                        delta?['reasoning_content'] ?? delta?['reasoning'];
                    // 捕获 Grok 引用
                    final gCitations = o['citations'];
                    if (gCitations is List && gCitations.isNotEmpty) {
                      final items = <Map<String, dynamic>>[];
                      for (int k = 0; k < gCitations.length; k++) {
                        final u = gCitations[k].toString();
                        items.add({'index': k + 1, 'url': u, 'title': u});
                      }
                      if (items.isNotEmpty) {
                        final payload = jsonEncode({'items': items});
                        yield ChatStreamChunk(
                          content: '',
                          isDone: false,
                          totalTokens: usage?.totalTokens ?? 0,
                          usage: usage,
                          toolResults: [
                            ToolResultInfo(
                              id: 'builtin_search',
                              name: 'search_web',
                              arguments: const <String, dynamic>{},
                              content: payload,
                            ),
                          ],
                        );
                      }
                    }
                    if (rc is String && rc.isNotEmpty) {
                      if (needsReasoningEcho) reasoningAccum += rc;
                      yield ChatStreamChunk(
                        content: '',
                        reasoning: rc,
                        isDone: false,
                        totalTokens: 0,
                        usage: usage,
                      );
                    }
                    if (txt.isNotEmpty) {
                      contentAccum += txt;
                      yield ChatStreamChunk(
                        content: txt,
                        isDone: false,
                        totalTokens: 0,
                        usage: usage,
                      );
                    }
                    if (wantsImageOutput) {
                      final List<dynamic> imageItems = <dynamic>[];
                      final imgs = delta?['images'];
                      if (imgs is List) imageItems.addAll(imgs);
                      final contentArr = delta?['content'] as List?;
                      if (contentArr is List) {
                        for (final it in contentArr) {
                          if (it is Map &&
                              (it['type'] == 'image_url' ||
                                  it['type'] == 'image')) {
                            imageItems.add(it);
                          }
                        }
                      }
                      final singleImage = delta?['image_url'];
                      if (singleImage is Map || singleImage is String) {
                        imageItems.add({
                          'type': 'image_url',
                          'image_url': singleImage,
                        });
                      }
                      if (imageItems.isNotEmpty) {
                        final buf = StringBuffer();
                        for (final it in imageItems) {
                          if (it is! Map) continue;
                          dynamic iu = it['image_url'];
                          String? url;
                          if (iu is String) {
                            url = iu;
                          } else if (iu is Map) {
                            final u2 = iu['url'];
                            if (u2 is String) url = u2;
                          }
                          if (url != null && url.isNotEmpty) {
                            final md = '\n\n![image]($url)';
                            buf.write(md);
                            contentAccum += md;
                          }
                        }
                        final out = buf.toString();
                        if (out.isNotEmpty) {
                          yield ChatStreamChunk(
                            content: out,
                            isDone: false,
                            totalTokens: 0,
                            usage: usage,
                          );
                        }
                      }
                    }
                    final tcs = delta?['tool_calls'] as List?;
                    if (tcs != null) {
                      for (final t in tcs) {
                        final idx = (t['index'] as int?) ?? 0;
                        final id = t['id'] as String?;
                        final func = t['function'] as Map<String, dynamic>?;
                        final name = func?['name'] as String?;
                        final argsDelta = func?['arguments'] as String?;
                        final entry = toolAcc2.putIfAbsent(
                          idx,
                          () => {'id': '', 'name': '', 'args': ''},
                        );
                        if (id != null) entry['id'] = id;
                        if (name != null && name.isNotEmpty) {
                          entry['name'] = name;
                        }
                        if (argsDelta != null && argsDelta.isNotEmpty) {
                          entry['args'] = (entry['args'] ?? '') + argsDelta;
                        }
                      }
                    }

                    // 回退/合并：同一块中的 message.content（如有）
                    final message = c0['message'] as Map?;
                    if (message != null && message['content'] != null) {
                      final mc = message['content'];
                      if (mc is String && mc.isNotEmpty) {
                        contentAccum += mc;
                        yield ChatStreamChunk(
                          content: mc,
                          isDone: false,
                          totalTokens: 0,
                          usage: usage,
                        );
                      }
                    }
                    if (message != null) {
                      final rcMsg =
                          message['reasoning_content'] ?? message['reasoning'];
                      if (rcMsg is String &&
                          rcMsg.isNotEmpty &&
                          needsReasoningEcho) {
                        reasoningAccum += rcMsg;
                      }
                    }
                    final rd = delta?['reasoning_details'];
                    if (rd is List && rd.isNotEmpty) {
                      reasoningDetailsAccum.add(rd);
                    }
                    final rdMsg = message?['reasoning_details'];
                    if (rdMsg is List && rdMsg.isNotEmpty) {
                      reasoningDetailsAccum.add(rdMsg);
                    }
                  }
                  // 后续请求也同样兼容 XinLiu
                  final rootToolCalls2 = o['tool_calls'] as List?;
                  if (rootToolCalls2 != null) {
                    for (final t in rootToolCalls2) {
                      if (t is! Map) continue;
                      final id = (t['id'] ?? '').toString();
                      final type = (t['type'] ?? 'function').toString();
                      if (type != 'function') continue;
                      final func = t['function'] as Map<String, dynamic>?;
                      if (func == null) continue;
                      final name = (func['name'] ?? '').toString();
                      final argsStr = (func['arguments'] ?? '').toString();
                      if (name.isEmpty) continue;
                      final idx = toolAcc2.length;
                      final entry = toolAcc2.putIfAbsent(
                        idx,
                        () => {
                          'id': _effectiveToolCallId(id, 'call', idx),
                          'name': name,
                          'args': argsStr,
                        },
                      );
                      if (id.isNotEmpty) entry['id'] = id;
                      entry['name'] = name;
                      entry['args'] = argsStr;
                    }
                    if (rootToolCalls2.isNotEmpty) {
                      finishReason2 = 'tool_calls';
                    }
                  }
                } catch (_) {}
              }
            }
            if (finishReason2 == 'tool_calls' || toolAcc2.isNotEmpty) {
              final calls2 = <Map<String, dynamic>>[];
              final callInfos2 = <ToolCallInfo>[];
              final toolMsgs2 = <Map<String, dynamic>>[];
              toolAcc2.forEach((idx, m) {
                final id = _effectiveToolCallId(m['id'], 'call', idx);
                final name = (m['name'] ?? '');
                Map<String, dynamic> args;
                try {
                  args = (jsonDecode(m['args'] ?? '{}') as Map)
                      .cast<String, dynamic>();
                } catch (_) {
                  args = <String, dynamic>{};
                }
                callInfos2.add(
                  ToolCallInfo(id: id, name: name, arguments: args),
                );
                calls2.add({
                  'id': id,
                  'type': 'function',
                  'function': {'name': name, 'arguments': jsonEncode(args)},
                });
                toolMsgs2.add({'__name': name, '__id': id, '__args': args});
              });
              if (callInfos2.isNotEmpty) {
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: usage?.totalTokens ?? 0,
                  usage: usage,
                  toolCalls: callInfos2,
                );
              }
              final results2 = <Map<String, dynamic>>[];
              final resultsInfo2 = <ToolResultInfo>[];
              for (final m in toolMsgs2) {
                final name = m['__name'] as String;
                final id = m['__id'] as String;
                final args = (m['__args'] as Map<String, dynamic>);
                final res = await effectiveOnToolCall(
                  name,
                  args,
                  toolCallId: id,
                );
                results2.add({'tool_call_id': id, 'content': res});
                resultsInfo2.add(
                  ToolResultInfo(
                    id: id,
                    name: name,
                    arguments: args,
                    content: res,
                  ),
                );
              }
              if (resultsInfo2.isNotEmpty) {
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: usage?.totalTokens ?? 0,
                  usage: usage,
                  toolResults: resultsInfo2,
                );
              }
              final nextAssistantToolCall = _buildAssistantToolCallMessage(
                calls: calls2,
                content: contentAccum,
                reasoningContent: needsReasoningEcho ? reasoningAccum : null,
                includeEmptyReasoningContent: needsReasoningEcho,
                reasoningDetails: reasoningDetailsAccum.detailsOrNull,
              );
              currentMessages = [
                ...currentMessages,
                nextAssistantToolCall,
                for (final r in results2)
                  {
                    'role': 'tool',
                    'tool_call_id': r['tool_call_id'],
                    'name': calls2.firstWhere(
                      (c) => c['id'] == r['tool_call_id'],
                      orElse: () => const {
                        'function': {'name': ''},
                      },
                    )['function']['name'],
                    'content': r['content'],
                  },
              ];
              continue;
            } else {
              final approxTotal =
                  approxPromptTokens +
                  approxTokensFromChars(approxCompletionChars);
              yield ChatStreamChunk(
                content: '',
                reasoningDetails: reasoningDetailsAccum.detailsOrNull,
                isDone: true,
                totalTokens: usage?.totalTokens ?? approxTotal,
                usage: usage,
              );
              return;
            }
          }
        }
        // XinLiu 兼容：如果已累积工具调用，不要提前结束
        if (config.useResponseApi != true &&
            finishReason != null &&
            finishReason != 'tool_calls') {
          final bool hasPendingToolCalls =
              toolAcc.isNotEmpty || toolAccResp.isNotEmpty;
          if (hasPendingToolCalls) {
            // 一些提供方（如 XinLiu/iflow.cn）可能返回 finish_reason='stop' 的 tool_calls，
            // 并且可能不发送 [DONE] 标记。这种情况下立即执行工具。
            if (effectiveOnToolCall != null && toolAcc.isNotEmpty) {
              final calls = <Map<String, dynamic>>[];
              final callInfos = <ToolCallInfo>[];
              final toolMsgs = <Map<String, dynamic>>[];
              toolAcc.forEach((idx, m) {
                final id = _effectiveToolCallId(m['id'], 'call', idx);
                final name = (m['name'] ?? '');
                Map<String, dynamic> args;
                try {
                  args = (jsonDecode(m['args'] ?? '{}') as Map)
                      .cast<String, dynamic>();
                } catch (_) {
                  args = <String, dynamic>{};
                }
                callInfos.add(
                  ToolCallInfo(id: id, name: name, arguments: args),
                );
                calls.add({
                  'id': id,
                  'type': 'function',
                  'function': {'name': name, 'arguments': jsonEncode(args)},
                });
                toolMsgs.add({'__name': name, '__id': id, '__args': args});
              });
              if (callInfos.isNotEmpty) {
                final approxTotal =
                    approxPromptTokens +
                    approxTokensFromChars(approxCompletionChars);
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: usage?.totalTokens ?? approxTotal,
                  usage: usage,
                  toolCalls: callInfos,
                );
              }
              // 执行工具并发出结果
              final results = <Map<String, dynamic>>[];
              final resultsInfo = <ToolResultInfo>[];
              for (final m in toolMsgs) {
                final name = m['__name'] as String;
                final id = m['__id'] as String;
                final args = (m['__args'] as Map<String, dynamic>);
                final res = await effectiveOnToolCall(
                  name,
                  args,
                  toolCallId: id,
                );
                results.add({'tool_call_id': id, 'content': res});
                resultsInfo.add(
                  ToolResultInfo(
                    id: id,
                    name: name,
                    arguments: args,
                    content: res,
                  ),
                );
              }
              if (resultsInfo.isNotEmpty) {
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: usage?.totalTokens ?? 0,
                  usage: usage,
                  toolResults: resultsInfo,
                );
              }
              // 构建后续消息
              final mm2 = <Map<String, dynamic>>[];
              for (final m in messages) {
                mm2.add(_copyChatCompletionMessage(m));
              }
              final assistantToolCallMsg = _buildAssistantToolCallMessage(
                calls: calls,
                content: assistantContentBuffer,
                reasoningContent: needsReasoningEcho ? reasoningBuffer : null,
                includeEmptyReasoningContent: needsReasoningEcho,
                reasoningDetails: reasoningDetailsBuffer.detailsOrNull,
              );
              mm2.add(assistantToolCallMsg);
              for (final r in results) {
                final id = r['tool_call_id'];
                final name = calls.firstWhere(
                  (c) => c['id'] == id,
                  orElse: () => const {
                    'function': {'name': ''},
                  },
                )['function']['name'];
                mm2.add({
                  'role': 'tool',
                  'tool_call_id': id,
                  'name': name,
                  'content': r['content'],
                });
              }
              // 使用后续请求继续流式传输 - 复用 [DONE] 处理器中现有的多轮逻辑
              var currentMessages = mm2;
              while (true) {
                final Map<String, dynamic> body2 = {
                  'model': upstreamModelId,
                  'messages': await _buildOpenAIChatCompletionMessages(
                    currentMessages,
                    userMediaPaths: userImagePaths,
                    canImageInput: canImageInput,
                    allowRemoteImages: allowRemoteImages,
                    reasoningContentReplayPolicy:
                        info.reasoningContentReplayPolicy,
                    stripReasoningContent: isClaudeUpstream,
                  ),
                  'stream': true,
                  if (temperature != null) 'temperature': temperature,
                  if (topP != null) 'top_p': topP,
                  if (isReasoning && effort != 'off' && effort != 'auto')
                    'reasoning_effort': effort,
                  if (tools != null && tools.isNotEmpty)
                    'tools': _cleanToolsForCompatibility(tools),
                  if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
                };
                setMaxTokens(body2);
                _applyVendorReasoningKnobs(
                  body2,
                  info: info,
                  isReasoning: isReasoning,
                  thinkingBudget: thinkingBudget,
                );
                _applyCompatibleBuiltInSearch(
                  body2,
                  config: config,
                  modelId: modelId,
                  upstreamModelId: upstreamModelId,
                );
                _maybeAddStreamingUsageOptions(
                  body2,
                  stream: true,
                  config: config,
                  host: info.host,
                );
                if (extraBodyCfg.isNotEmpty) {
                  body2.addAll(extraBodyCfg);
                }
                _sanitizeOpenAIGpt5SamplingParams(
                  body2,
                  upstreamModelId,
                  fallbackEffort: effort,
                  isOpenRouter: info.isOpenRouter,
                );
                _normalizeMoonshotKimiChatBody(
                  body2,
                  upstreamModelId: upstreamModelId,
                  isReasoning: isReasoning,
                  thinkingBudget: thinkingBudget,
                );
                final req2 = http.Request('POST', url);
                final headers2 = _customHeaders(
                  config,
                  modelId,
                  baseHeaders: <String, String>{
                    'Authorization':
                        'Bearer ${_apiKeyForRequest(config, modelId)}',
                    'Content-Type': 'application/json',
                    'Accept': 'text/event-stream',
                  },
                  assistantHeaders: extraHeaders,
                );
                req2.headers.addAll(headers2);
                req2.body = jsonEncode(body2);
                final http.StreamedResponse resp2;
                try {
                  resp2 = await client.send(req2);
                  if (resp2.statusCode < 200 || resp2.statusCode >= 300) {
                    final errorBody = await resp2.stream.bytesToString();
                    throw HttpException('HTTP ${resp2.statusCode}: $errorBody');
                  }
                } on HttpException {
                  rethrow;
                } catch (e) {
                  // 保持为 HttpException，以便下面逐事件捕获（它
                  // 容忍格式错误的 JSON）不能吞掉此失败。
                  throw HttpException('Follow-up request failed: $e');
                }
                final s2 = _rethrowFollowUpStreamErrors(
                  resp2.stream.transform(utf8.decoder),
                );
                String buf2 = '';
                final Map<int, Map<String, String>> toolAcc2 =
                    <int, Map<String, String>>{};
                String? finishReason2;
                String contentAccum = '';
                String reasoningAccum = '';
                final reasoningDetailsAccum = _ReasoningDetailsAccumulator(
                  allowSnapshots: reasoningDetailsAllowSnapshots,
                );
                await for (final ch in _ensureTrailingNewline(s2)) {
                  buf2 += ch;
                  final lines2 = buf2.split('\n');
                  buf2 = lines2.last;
                  for (int j = 0; j < lines2.length - 1; j++) {
                    final l = lines2[j].trim();
                    if (l.isEmpty || !l.startsWith('data:')) continue;
                    final d = l.substring(5).trimLeft();
                    if (d == '[DONE]') {
                      continue;
                    }
                    _throwIfInBandStreamError(d);
                    try {
                      final o = jsonDecode(d);
                      if (o is Map) {
                        usage = _mergeOpenAICompatibleUsage(usage, o['usage']);
                        if (usage != null) totalTokens = usage.totalTokens;
                      }
                      if (o is Map &&
                          o['choices'] is List &&
                          (o['choices'] as List).isNotEmpty) {
                        final c0 = (o['choices'] as List).first;
                        finishReason2 = c0['finish_reason'] as String?;
                        final delta = c0['delta'] as Map?;
                        final txt = _extractOpenAICompatibleDeltaText(delta);
                        final rc =
                            delta?['reasoning_content'] ?? delta?['reasoning'];
                        if (rc is String && rc.isNotEmpty) {
                          if (needsReasoningEcho) reasoningAccum += rc;
                          yield ChatStreamChunk(
                            content: '',
                            reasoning: rc,
                            isDone: false,
                            totalTokens: 0,
                            usage: usage,
                          );
                        }
                        if (txt.isNotEmpty) {
                          contentAccum += txt;
                          yield ChatStreamChunk(
                            content: txt,
                            isDone: false,
                            totalTokens: 0,
                            usage: usage,
                          );
                        }
                        if (wantsImageOutput) {
                          final List<dynamic> imageItems = <dynamic>[];
                          final imgs = delta?['images'];
                          if (imgs is List) imageItems.addAll(imgs);
                          final contentArr = delta?['content'] as List?;
                          if (contentArr is List) {
                            for (final it in contentArr) {
                              if (it is Map &&
                                  (it['type'] == 'image_url' ||
                                      it['type'] == 'image')) {
                                imageItems.add(it);
                              }
                            }
                          }
                          final singleImage = delta?['image_url'];
                          if (singleImage is Map || singleImage is String) {
                            imageItems.add({
                              'type': 'image_url',
                              'image_url': singleImage,
                            });
                          }
                          if (imageItems.isNotEmpty) {
                            final buf = StringBuffer();
                            for (final it in imageItems) {
                              if (it is! Map) continue;
                              dynamic iu = it['image_url'];
                              String? url;
                              if (iu is String) {
                                url = iu;
                              } else if (iu is Map) {
                                final u2 = iu['url'];
                                if (u2 is String) url = u2;
                              }
                              if (url != null && url.isNotEmpty) {
                                final md = '\n\n![image]($url)';
                                buf.write(md);
                                contentAccum += md;
                              }
                            }
                            final out = buf.toString();
                            if (out.isNotEmpty) {
                              yield ChatStreamChunk(
                                content: out,
                                isDone: false,
                                totalTokens: 0,
                                usage: usage,
                              );
                            }
                          }
                        }
                        final tcs = delta?['tool_calls'] as List?;
                        if (tcs != null) {
                          for (final t in tcs) {
                            final idx = (t['index'] as int?) ?? 0;
                            final id = t['id'] as String?;
                            final func = t['function'] as Map<String, dynamic>?;
                            final name = func?['name'] as String?;
                            final argsDelta = func?['arguments'] as String?;
                            final entry = toolAcc2.putIfAbsent(
                              idx,
                              () => {'id': '', 'name': '', 'args': ''},
                            );
                            if (id != null) entry['id'] = id;
                            if (name != null && name.isNotEmpty) {
                              entry['name'] = name;
                            }
                            if (argsDelta != null && argsDelta.isNotEmpty) {
                              entry['args'] = (entry['args'] ?? '') + argsDelta;
                            }
                          }
                        }

                        // 回退/合并：同一块中的 message.content（如有）
                        final message = c0['message'] as Map?;
                        if (message != null && message['content'] != null) {
                          final mc = message['content'];
                          if (mc is String && mc.isNotEmpty) {
                            contentAccum += mc;
                            yield ChatStreamChunk(
                              content: mc,
                              isDone: false,
                              totalTokens: 0,
                              usage: usage,
                            );
                          }
                        }
                        if (message != null) {
                          final rcMsg =
                              message['reasoning_content'] ??
                              message['reasoning'];
                          if (rcMsg is String &&
                              rcMsg.isNotEmpty &&
                              needsReasoningEcho) {
                            reasoningAccum += rcMsg;
                          }
                        }
                        final rd = delta?['reasoning_details'];
                        if (rd is List && rd.isNotEmpty) {
                          reasoningDetailsAccum.add(rd);
                        }
                        final rdMsg = message?['reasoning_details'];
                        if (rdMsg is List && rdMsg.isNotEmpty) {
                          reasoningDetailsAccum.add(rdMsg);
                        }
                      }
                      // 后续请求也同样兼容 XinLiu
                      final rootToolCalls2 = o['tool_calls'] as List?;
                      if (rootToolCalls2 != null) {
                        for (final t in rootToolCalls2) {
                          if (t is! Map) continue;
                          final id = (t['id'] ?? '').toString();
                          final type = (t['type'] ?? 'function').toString();
                          if (type != 'function') continue;
                          final func = t['function'] as Map<String, dynamic>?;
                          if (func == null) continue;
                          final name = (func['name'] ?? '').toString();
                          final argsStr = (func['arguments'] ?? '').toString();
                          if (name.isEmpty) continue;
                          final idx = toolAcc2.length;
                          final entry = toolAcc2.putIfAbsent(
                            idx,
                            () => {
                              'id': _effectiveToolCallId(id, 'call', idx),
                              'name': name,
                              'args': argsStr,
                            },
                          );
                          if (id.isNotEmpty) entry['id'] = id;
                          entry['name'] = name;
                          entry['args'] = argsStr;
                        }
                        if (rootToolCalls2.isNotEmpty &&
                            finishReason2 == null) {
                          finishReason2 = 'tool_calls';
                        }
                      }
                    } catch (_) {}
                  }
                }
                if (finishReason2 == 'tool_calls' || toolAcc2.isNotEmpty) {
                  final calls2 = <Map<String, dynamic>>[];
                  final callInfos2 = <ToolCallInfo>[];
                  final toolMsgs2 = <Map<String, dynamic>>[];
                  toolAcc2.forEach((idx, m) {
                    final id = _effectiveToolCallId(m['id'], 'call', idx);
                    final name = (m['name'] ?? '');
                    Map<String, dynamic> args;
                    try {
                      args = (jsonDecode(m['args'] ?? '{}') as Map)
                          .cast<String, dynamic>();
                    } catch (_) {
                      args = <String, dynamic>{};
                    }
                    callInfos2.add(
                      ToolCallInfo(id: id, name: name, arguments: args),
                    );
                    calls2.add({
                      'id': id,
                      'type': 'function',
                      'function': {'name': name, 'arguments': jsonEncode(args)},
                    });
                    toolMsgs2.add({'__name': name, '__id': id, '__args': args});
                  });
                  if (callInfos2.isNotEmpty) {
                    yield ChatStreamChunk(
                      content: '',
                      isDone: false,
                      totalTokens: usage?.totalTokens ?? 0,
                      usage: usage,
                      toolCalls: callInfos2,
                    );
                  }
                  final results2 = <Map<String, dynamic>>[];
                  final resultsInfo2 = <ToolResultInfo>[];
                  for (final m in toolMsgs2) {
                    final name = m['__name'] as String;
                    final id = m['__id'] as String;
                    final args = (m['__args'] as Map<String, dynamic>);
                    final res = await effectiveOnToolCall(
                      name,
                      args,
                      toolCallId: id,
                    );
                    results2.add({'tool_call_id': id, 'content': res});
                    resultsInfo2.add(
                      ToolResultInfo(
                        id: id,
                        name: name,
                        arguments: args,
                        content: res,
                      ),
                    );
                  }
                  if (resultsInfo2.isNotEmpty) {
                    yield ChatStreamChunk(
                      content: '',
                      isDone: false,
                      totalTokens: usage?.totalTokens ?? 0,
                      usage: usage,
                      toolResults: resultsInfo2,
                    );
                  }
                  final nextAssistantToolCall = _buildAssistantToolCallMessage(
                    calls: calls2,
                    content: contentAccum,
                    reasoningContent: needsReasoningEcho
                        ? reasoningAccum
                        : null,
                    includeEmptyReasoningContent: needsReasoningEcho,
                    reasoningDetails: reasoningDetailsAccum.detailsOrNull,
                  );
                  currentMessages = [
                    ...currentMessages,
                    nextAssistantToolCall,
                    for (final r in results2)
                      {
                        'role': 'tool',
                        'tool_call_id': r['tool_call_id'],
                        'name': calls2.firstWhere(
                          (c) => c['id'] == r['tool_call_id'],
                          orElse: () => const {
                            'function': {'name': ''},
                          },
                        )['function']['name'],
                        'content': r['content'],
                      },
                  ];
                  continue;
                } else {
                  final approxTotal =
                      approxPromptTokens +
                      approxTokensFromChars(approxCompletionChars);
                  yield ChatStreamChunk(
                    content: '',
                    isDone: true,
                    totalTokens: usage?.totalTokens ?? approxTotal,
                    usage: usage,
                  );
                  return;
                }
              }
            }
          } else if (info.isOpenRouter) {
          } else {
            // final approxTotal = approxPromptTokens + _approxTokensFromChars(approxCompletionChars);
            // yield ChatStreamChunk(
            //   content: '',
            //   isDone: false,
            //   totalTokens: usage?.totalTokens ?? approxTotal,
            //   usage: usage,
            // );
            // return;
          }
        }
      } on HttpException {
        // 此块内抛出的带内错误帧（后续工具调用流会在这里调用
        // _throwIfInBandStreamError）以及失败的后续请求必须作为流错误暴露；吞掉它们会让
        // 下方无 [DONE] 的回退逻辑把截断输出当作正常完成持久化。
        rethrow;
      } catch (e) {
        // 跳过格式错误的 JSON
      }
    }
  }

  // 回退：提供方在没有发送 [DONE] 的情况下关闭了 SSE
  final approxTotal =
      usage?.totalTokens ??
      (approxPromptTokens + approxTokensFromChars(approxCompletionChars));
  yield ChatStreamChunk(
    content: '',
    reasoningDetails: reasoningDetailsBuffer.detailsOrNull,
    isDone: true,
    totalTokens: approxTotal,
    usage: usage,
  );
}
