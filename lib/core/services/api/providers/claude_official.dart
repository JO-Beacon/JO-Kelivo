part of '../chat_api_service.dart';

int _defaultClaudeMaxOutputTokens(String modelId) {
  final lower = modelId.trim().toLowerCase();
  if (RegExp(
    r'claude-(?:fable-5|mythos-5|opus-(?:5|4-8)|sonnet-5)(?:$|[._:@/-])',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return 128000;
  }
  return 64000;
}

int _readClaudeUsageInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

TokenUsage _claudeUsageFromMap(Map<String, dynamic> usage) {
  final inTok = _readClaudeUsageInt(usage['input_tokens']);
  final outTok = _readClaudeUsageInt(usage['output_tokens']);
  final cached =
      _readClaudeUsageInt(usage['cache_read_input_tokens']) +
      _readClaudeUsageInt(usage['cache_creation_input_tokens']);
  return TokenUsage(
    promptTokens: inTok,
    completionTokens: outTok,
    cachedTokens: cached,
    totalTokens: inTok + outTok,
  );
}

String _normalizeClaudeImageMime(String mime) {
  final normalized = mime.trim().toLowerCase();
  if (normalized == 'image/jpg') return 'image/jpeg';
  return normalized;
}

bool _isClaudeSupportedImageMime(String mime) {
  switch (_normalizeClaudeImageMime(mime)) {
    case 'image/jpeg':
    case 'image/png':
    case 'image/gif':
    case 'image/webp':
      return true;
    default:
      return false;
  }
}

Stream<ChatStreamChunk> _sendClaudeStream(
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
  // 端点与请求头（各轮次保持不变）
  final base = config.baseUrl.endsWith('/')
      ? config.baseUrl.substring(0, config.baseUrl.length - 1)
      : config.baseUrl;
  final url = Uri.parse('$base/messages');

  final isReasoning = _effectiveModelInfo(
    config,
    modelId,
  ).abilities.contains(ModelAbility.reasoning);
  final skipRedactedThinkingBlocks = BuiltInToolsHelper.isOpenRouterProvider(
    config,
  );

  // 提取 system prompt（Anthropic 使用顶层 `system`）
  String systemPrompt = '';
  final nonSystemMessages = <Map<String, dynamic>>[];
  for (final m in messages) {
    final role = (m['role'] ?? '').toString();
    if (role == 'system') {
      final s = (m['content'] ?? '').toString();
      if (s.isNotEmpty) {
        systemPrompt = systemPrompt.isEmpty ? s : '$systemPrompt\n\n$s';
      }
      continue;
    }
    // 在转换过程中保留 media-paths；它们不会被转发到
    // 最终的 Anthropic 请求体中（下方会重建 role/content）。
    nonSystemMessages.add(
      Map<String, dynamic>.from(m)
        ..remove(multimodalInternalRevisionIdKey)
        ..['role'] = role.isEmpty ? 'user' : role,
    );
  }

  // 按 Anthropic 规范转换最后一条用户消息以包含图片
  final initialMessages = <Map<String, dynamic>>[];
  final pendingToolResults = <Map<String, dynamic>>[];
  void flushPendingToolResults() {
    if (pendingToolResults.isEmpty) return;
    initialMessages.add({
      'role': 'user',
      'content': List<Map<String, dynamic>>.from(pendingToolResults),
    });
    pendingToolResults.clear();
  }

  Map<String, dynamic>? toolUseBlockFromToolCall(Map tc) {
    final id = (tc['id'] ?? '').toString();
    final fn = tc['function'];
    if (id.isEmpty || fn is! Map) return null;
    Map<String, dynamic> input = const <String, dynamic>{};
    try {
      input = (jsonDecode((fn['arguments'] ?? '{}').toString()) as Map)
          .cast<String, dynamic>();
    } catch (_) {}
    return {
      'type': 'tool_use',
      'id': id,
      'name': (fn['name'] ?? '').toString(),
      'input': input,
    };
  }

  Set<String> toolUseIdsInBlocks(List<Map<String, dynamic>> blocks) {
    return blocks
        .where((block) => block['type'] == 'tool_use')
        .map((block) => (block['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Map<String, dynamic>? assistantBlockForClaudeRequest(Map block) {
    final type = (block['type'] ?? '').toString();
    if (skipRedactedThinkingBlocks && type == 'redacted_thinking') {
      return null;
    }
    return block.map((key, value) => MapEntry(key.toString(), value));
  }

  List<Map<String, dynamic>> assistantBlocksForClaudeRequest(
    Iterable<Map> blocks,
  ) {
    return [
      for (final block in blocks)
        if (assistantBlockForClaudeRequest(block) case final sanitized?)
          sanitized,
    ];
  }

  List<Map<String, dynamic>>? anthropicBlocksFromToolCallMetadata(
    List toolCalls,
  ) {
    final expectedIds = toolCalls
        .whereType<Map>()
        .map((tc) => (tc['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    List<Map<String, dynamic>>? bestBlocks;
    var bestMatchCount = -1;

    for (final tc in toolCalls) {
      if (tc is! Map) continue;
      final meta = tc['metadata'];
      if (meta is! Map) continue;
      final anthropic = meta['anthropic'];
      if (anthropic is! Map) continue;
      final blocks = anthropic['assistant_blocks'];
      if (blocks is! List || blocks.isEmpty) continue;
      final candidate = assistantBlocksForClaudeRequest(
        blocks.whereType<Map>(),
      );
      final matchCount = toolUseIdsInBlocks(
        candidate,
      ).where(expectedIds.contains).length;
      if (matchCount > bestMatchCount ||
          (matchCount == bestMatchCount &&
              candidate.length > (bestBlocks?.length ?? 0))) {
        bestBlocks = candidate;
        bestMatchCount = matchCount;
      }
    }
    if (bestBlocks == null) return null;
    if (expectedIds.isEmpty) return bestBlocks;

    final presentIds = toolUseIdsInBlocks(bestBlocks);
    if (presentIds.containsAll(expectedIds)) return bestBlocks;

    final completed = <Map<String, dynamic>>[
      for (final block in bestBlocks) Map<String, dynamic>.from(block),
    ];
    for (final tc in toolCalls.whereType<Map>()) {
      final block = toolUseBlockFromToolCall(tc);
      if (block == null) continue;
      final id = (block['id'] ?? '').toString();
      if (presentIds.contains(id)) continue;
      completed.add(block);
      presentIds.add(id);
    }
    return completed;
  }

  for (int i = 0; i < nonSystemMessages.length; i++) {
    final m = nonSystemMessages[i];
    final isLast = i == nonSystemMessages.length - 1;
    final role = (m['role'] ?? 'user').toString();
    if (role == 'tool') {
      final id = (m['tool_call_id'] ?? '').toString();
      if (id.isNotEmpty) {
        pendingToolResults.add({
          'type': 'tool_result',
          'tool_use_id': id,
          'content': (m['content'] ?? '').toString(),
        });
      }
      continue;
    }
    flushPendingToolResults();

    if (role == 'assistant' && m['tool_calls'] is List) {
      final toolCalls = m['tool_calls'] as List;
      final blocks =
          anthropicBlocksFromToolCallMetadata(toolCalls) ??
          <Map<String, dynamic>>[];
      if (blocks.isEmpty) {
        final text = (m['content'] ?? '').toString();
        if (text.trim().isNotEmpty && text.trim() != '\n\n') {
          blocks.add({'type': 'text', 'text': text});
        }
        for (final tc in toolCalls) {
          if (tc is! Map) continue;
          final block = toolUseBlockFromToolCall(tc);
          if (block != null) blocks.add(block);
        }
      }
      if (blocks.isNotEmpty) {
        initialMessages.add({'role': 'assistant', 'content': blocks});
      }
      continue;
    }
    final raw = (m['content'] ?? '').toString();
    // 仅做语义媒体检测——不识别自定义附件标记。
    // 附件通过结构化 media-path 键 /
    // userImagePaths 以及 Markdown ![](...) 传入。
    final hasMarkdownImages = raw.contains('![') && raw.contains('](');
    final internalMediaRefs = parseInternalMediaRefs(
      m[multimodalInternalMediaPathsKey],
    );
    // 消费注入的媒体引用（针对用户与助手的历史轮次）。
    final hasInternalMedia = internalMediaRefs.isNotEmpty;
    final hasAttachedImages =
        isLast && role == 'user' && (userImagePaths?.isNotEmpty == true);

    if ((role == 'user' || role == 'assistant') &&
        (hasMarkdownImages || hasInternalMedia || hasAttachedImages)) {
      final parts = <Map<String, dynamic>>[];
      final seenSources = <String>{};
      String normalizeSrc(String src) {
        if (src.startsWith('http') || src.startsWith('data:')) return src;
        try {
          return SandboxPathResolver.fix(src);
        } catch (_) {
          return src;
        }
      }

      Future<void> addClaudeImage(String source, {String? explicitMime}) async {
        final normalized = normalizeSrc(source);
        if (!seenSources.add(normalized)) return;
        if (source.startsWith('http://') || source.startsWith('https://')) {
          // 对远程 URL 保留先前官方 Claude 的行为。
          parts.add({'type': 'text', 'text': source});
          return;
        }
        if (source.startsWith('data:')) {
          final mime = _normalizeClaudeImageMime(
            (explicitMime != null && explicitMime.trim().isNotEmpty)
                ? explicitMime.trim()
                : _mimeFromDataUrl(source),
          );
          final idx = source.indexOf('base64,');
          if (idx > 0) {
            parts.add({
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': mime,
                'data': source.substring(idx + 7),
              },
            });
          }
          return;
        }
        final mime = _normalizeClaudeImageMime(
          (explicitMime != null && explicitMime.trim().isNotEmpty)
              ? explicitMime.trim()
              : _mimeFromPath(source),
        );
        final b64 = await _tryEncodeBase64File(source, withPrefix: false);
        if (b64 == null) return;
        parts.add({
          'type': 'image',
          'source': {'type': 'base64', 'media_type': mime, 'data': b64},
        });
      }

      final parsed = await _parseTextAndImages(
        raw,
        allowRemoteImages: true,
        allowLocalImages: true,
        keepRemoteMarkdownText: true,
      );
      if (parsed.text.isNotEmpty) {
        parts.add({'type': 'text', 'text': parsed.text});
      }
      for (final ref in parsed.images) {
        if (ref.kind == 'data' || ref.kind == 'path' || ref.kind == 'url') {
          await addClaudeImage(ref.src);
        }
      }
      final supplementalRefs = _supplementalMediaRefs(
        internalRaw: m[multimodalInternalMediaPathsKey],
        userPaths: userImagePaths,
        includeUserPaths: hasAttachedImages,
      );
      for (final mediaRef in supplementalRefs) {
        final mime = _mimeForInternalMediaRef(mediaRef);
        // 永远不要为视频/音频或其他
        // 非 Claude 图片 MIME 类型（例如 video/mp4）生成 Anthropic 图片块。
        if (isVideoMime(mime) ||
            isAudioMime(mime) ||
            !_isClaudeSupportedImageMime(mime)) {
          final uri = mediaRef.uri;
          final isRemote =
              uri.startsWith('http://') || uri.startsWith('https://');
          if (isRemote) {
            final normalized = normalizeSrc(uri);
            if (seenSources.add(normalized)) {
              parts.add({'type': 'text', 'text': uri});
            }
          }
          continue;
        }
        await addClaudeImage(mediaRef.uri, explicitMime: mediaRef.mime);
      }
      initialMessages.add({
        'role': role,
        'content': parts.isEmpty ? raw : parts,
      });
    } else {
      initialMessages.add({'role': role, 'content': raw});
    }
  }
  flushPendingToolResults();

  // 将 OpenAI 风格的工具映射为 Anthropic 自定义工具（client tools）
  List<Map<String, dynamic>>? anthropicTools;
  if (tools != null && tools.isNotEmpty) {
    anthropicTools = [];
    for (final t in tools) {
      final fn = (t['function'] as Map<String, dynamic>?);
      if (fn == null) continue;
      final name = (fn['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final desc = (fn['description'] ?? '').toString();
      final params =
          (fn['parameters'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{'type': 'object'};
      anthropicTools.add({
        'name': name,
        if (desc.isNotEmpty) 'description': desc,
        'input_schema': params,
      });
    }
  }

  // 收集最终工具列表：client + server + 内置 web_search
  final List<Map<String, dynamic>> allTools = [];
  if (anthropicTools != null && anthropicTools.isNotEmpty) {
    allTools.addAll(anthropicTools);
  }
  if (tools != null && tools.isNotEmpty) {
    for (final t in tools) {
      final type = (t['type'] ?? '').toString();
      if (type.startsWith('web_search_')) {
        allTools.add(t);
      }
    }
  }
  final builtIns = _builtInTools(config, modelId);
  if (builtIns.contains(BuiltInToolNames.search)) {
    Map<String, dynamic> ws = const <String, dynamic>{};
    try {
      final ov = config.modelOverrides[modelId];
      if (ov is Map && ov['webSearch'] is Map) {
        ws = (ov['webSearch'] as Map).cast<String, dynamic>();
      }
    } catch (_) {}
    final searchToolType = BuiltInToolsHelper.claudeBuiltInSearchToolType(
      cfg: config,
      modelId: modelId,
    );
    final entry = <String, dynamic>{
      'type': searchToolType,
      'name': 'web_search',
    };
    if (searchToolType == 'web_search_20260209') {
      allTools.add(<String, dynamic>{
        'type': 'code_execution_20250825',
        'name': 'code_execution',
      });
    }
    if (ws['max_uses'] is int && (ws['max_uses'] as int) > 0) {
      entry['max_uses'] = ws['max_uses'];
    }
    if (ws['allowed_domains'] is List) {
      entry['allowed_domains'] = List<String>.from(
        (ws['allowed_domains'] as List).map((e) => e.toString()),
      );
    }
    if (ws['blocked_domains'] is List) {
      entry['blocked_domains'] = List<String>.from(
        (ws['blocked_domains'] as List).map((e) => e.toString()),
      );
    }
    if (ws['user_location'] is Map) {
      entry['user_location'] = (ws['user_location'] as Map)
          .cast<String, dynamic>();
    }
    allTools.add(entry);
  }

  // 请求头（各轮次保持不变）
  final baseHeaders = _customHeaders(
    config,
    modelId,
    baseHeaders: <String, String>{
      'x-api-key': _effectiveApiKey(config),
      'anthropic-version': '2023-06-01',
      'Content-Type': 'application/json',
      'Accept': stream ? 'text/event-stream' : 'application/json',
    },
    assistantHeaders: extraHeaders,
  );

  // 跨轮次的进行中对话
  List<Map<String, dynamic>> convo = List<Map<String, dynamic>>.from(
    initialMessages,
  );
  TokenUsage? totalUsage;

  while (true) {
    final omitSamplingParams = _claudeShouldOmitSamplingParams(
      upstreamModelId,
      thinkingBudget,
    );
    final compatibleTopP = _claudeCompatibleTopP(
      upstreamModelId,
      thinkingBudget,
      topP,
    );
    final thinking = isReasoning
        ? _claudeThinkingConfig(upstreamModelId, thinkingBudget, config: config)
        : null;
    final outputConfig = isReasoning
        ? _claudeOutputConfig(upstreamModelId, thinkingBudget, config: config)
        : null;

    // 为每轮准备请求体
    final body = <String, dynamic>{
      'model': upstreamModelId,
      'max_tokens': maxTokens ?? _defaultClaudeMaxOutputTokens(upstreamModelId),
      'messages': convo,
      'stream': stream,
      if (systemPrompt.isNotEmpty) 'system': systemPrompt,
      if (config.claudePromptCachingEnabled == true)
        'cache_control': ProviderConfig.claudePromptCacheControl(
          config.claudePromptCachingTtl,
        ),
      if (!omitSamplingParams &&
          !_isClaudeReasoningEnabled(thinkingBudget) &&
          temperature != null)
        'temperature': temperature,
      if (compatibleTopP != null) 'top_p': compatibleTopP,
      if (allTools.isNotEmpty) 'tools': allTools,
      if (allTools.isNotEmpty) 'tool_choice': {'type': 'auto'},
      if (thinking != null) 'thinking': thinking,
      if (outputConfig != null) 'output_config': outputConfig,
    };
    final extraClaude = _customBody(config, modelId, assistantBody: extraBody);
    if (extraClaude.isNotEmpty) {
      body.addAll(extraClaude);
    }

    final request = http.Request('POST', url);
    request.headers.addAll(baseHeaders);
    request.body = jsonEncode(body);

    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBody = await response.stream.bytesToString();
      throw HttpException('HTTP ${response.statusCode}: $errorBody');
    }

    // 非流式路径：解析完整 JSON，处理 tool_use，然后按需继续循环。
    if (!stream) {
      final txt = await response.stream.bytesToString();
      final obj = jsonDecode(txt) as Map;
      // 用量统计
      try {
        final u = (obj['usage'] as Map?)?.cast<String, dynamic>();
        if (u != null) {
          totalUsage = (totalUsage ?? const TokenUsage()).accumulate(
            _claudeUsageFromMap(u),
          );
        }
      } catch (_) {}
      final content = (obj['content'] as List?) ?? const <dynamic>[];
      final List<Map<String, dynamic>> assistantBlocks =
          <Map<String, dynamic>>[];
      final Map<String, Map<String, dynamic>> toolUses =
          <String, Map<String, dynamic>>{}; // id -> {name,args}
      final buf = StringBuffer();
      for (final it in content) {
        if (it is! Map) continue;
        final type = (it['type'] ?? '').toString();
        if (type == 'text') {
          final t = (it['text'] ?? '').toString();
          if (t.isNotEmpty) {
            assistantBlocks.add({'type': 'text', 'text': t});
            buf.write(t);
          }
        } else if (type == 'thinking' ||
            (type == 'redacted_thinking' && !skipRedactedThinkingBlocks)) {
          // 保留 thinking 块原样，用于 tool-use 续接。
          // 启用 thinking 时，下一个请求必须包含上一条助手
          // 消息，且以 thinking/redacted_thinking 块开头。
          try {
            assistantBlocks.add(
              Map<String, dynamic>.from(it.cast<String, dynamic>()),
            );
          } catch (_) {}
        } else if (type == 'tool_use') {
          final id = (it['id'] ?? '').toString();
          final name = (it['name'] ?? '').toString();
          final args =
              (it['input'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          if (id.isNotEmpty) {
            toolUses[id] = {'name': name, 'args': args};
            assistantBlocks.add({
              'type': 'tool_use',
              'id': id,
              'name': name,
              'input': args,
            });
          }
        }
      }
      if (toolUses.isNotEmpty && onToolCall != null) {
        final callInfos = <ToolCallInfo>[];
        for (final e in toolUses.entries) {
          callInfos.add(
            ToolCallInfo(
              id: e.key,
              name: (e.value['name'] ?? '').toString(),
              arguments: (e.value['args'] as Map<String, dynamic>),
              metadata: {
                'anthropic': {'assistant_blocks': assistantBlocks},
              },
            ),
          );
        }
        yield ChatStreamChunk(
          content: '',
          isDone: false,
          totalTokens: (totalUsage?.totalTokens ?? 0),
          usage: totalUsage,
          toolCalls: callInfos,
        );
        final results = <Map<String, dynamic>>[];
        final resultsInfo = <ToolResultInfo>[];
        for (final e in toolUses.entries) {
          final name = (e.value['name'] ?? '').toString();
          final args = (e.value['args'] as Map<String, dynamic>);
          final res = await onToolCall(name, args, toolCallId: e.key);
          results.add({
            'type': 'tool_result',
            'tool_use_id': e.key,
            'content': res,
          });
          resultsInfo.add(
            ToolResultInfo(
              id: e.key,
              name: name,
              arguments: args,
              content: res,
              metadata: {
                'anthropic': {'assistant_blocks': assistantBlocks},
              },
            ),
          );
        }
        if (resultsInfo.isNotEmpty) {
          yield ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: (totalUsage?.totalTokens ?? 0),
            usage: totalUsage,
            toolResults: resultsInfo,
          );
        }
        // 扩展对话：assistant + user tool_result，循环
        final assistantMsg = {'role': 'assistant', 'content': assistantBlocks};
        final userToolMsg = {'role': 'user', 'content': results};
        convo = [...convo, assistantMsg, userToolMsg];
        continue; // 下一轮
      }
      // 无工具调用 -> 返回最终文本
      yield ChatStreamChunk(
        content: buf.toString(),
        isDone: true,
        totalTokens: (totalUsage?.totalTokens ?? 0),
        usage: totalUsage,
      );
      return;
    }

    final sse = response.stream.transform(utf8.decoder);
    String buffer = '';
    int roundTokens = 0;
    TokenUsage? usage;
    String? lastStopReason;

    // 每轮累加
    final Map<String, Map<String, dynamic>> anthToolUse =
        <String, Map<String, dynamic>>{}; // id -> {name, args}
    final Map<int, String> cliIndexToId =
        <int, String>{}; // client tool：index -> id
    final Map<String, String> toolResultsContent =
        <String, String>{}; // id -> 结果文本
    final List<Map<String, dynamic>> assistantBlocks = <Map<String, dynamic>>[];
    final StringBuffer textBuf = StringBuffer();

    // 跟踪 thinking 块，以便在 tool-use 续接时回传。
    final Map<int, int> thinkingIndexToAssistantBlock = <int, int>{};
    final Map<int, StringBuffer> thinkingText = <int, StringBuffer>{};
    final Map<int, StringBuffer> thinkingSig = <int, StringBuffer>{};
    final Map<int, int> redactedThinkingIndexToAssistantBlock = <int, int>{};
    final Map<int, StringBuffer> redactedThinkingData = <int, StringBuffer>{};

    int? parseIndex(dynamic raw) {
      if (raw == null) return null;
      if (raw is int) return raw;
      return int.tryParse(raw.toString());
    }

    void flushTextBlock() {
      final t = textBuf.toString();
      if (t.isNotEmpty) {
        assistantBlocks.add({'type': 'text', 'text': t});
        textBuf.clear();
      }
    }

    // 服务端工具辅助（web_search）
    final Map<int, String> srvIndexToId = <int, String>{};
    final Map<String, String> srvArgsStr = <String, String>{};
    final Map<String, Map<String, dynamic>> srvArgs =
        <String, Map<String, dynamic>>{};

    bool messageStopped = false;

    await for (final chunk in _ensureTrailingNewline(sse)) {
      buffer += chunk;
      final lines = buffer.split('\n');
      buffer = lines.last;

      for (int i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isEmpty || !line.startsWith('data:')) continue;

        final data = line.substring(5).trimLeft();
        // Anthropic 以带内 `event: error` 形式上报失败，
        // 内容为 {type:"error", error:{type,message}}；抢在下方
        // 格式错误分片兜底逻辑吞掉它之前抛出。
        _throwIfInBandStreamError(data);
        try {
          final obj = jsonDecode(data);
          final type = obj['type'];

          if (type == 'content_block_start') {
            final cb = obj['content_block'];
            final idx = parseIndex(obj['index']);
            if (cb is Map && (cb['type'] == 'thinking')) {
              // 保留 thinking 块（含签名）用于 tool-use 续接。
              flushTextBlock();
              if (idx != null) {
                assistantBlocks.add({
                  'type': 'thinking',
                  'thinking': '',
                  'signature': '',
                });
                thinkingIndexToAssistantBlock[idx] = assistantBlocks.length - 1;
                thinkingText[idx] = StringBuffer();
                thinkingSig[idx] = StringBuffer();
              }
            } else if (cb is Map && (cb['type'] == 'redacted_thinking')) {
              flushTextBlock();
              if (!skipRedactedThinkingBlocks && idx != null) {
                assistantBlocks.add({'type': 'redacted_thinking', 'data': ''});
                redactedThinkingIndexToAssistantBlock[idx] =
                    assistantBlocks.length - 1;
                redactedThinkingData[idx] = StringBuffer();
              }
            } else if (cb is Map && (cb['type'] == 'tool_use')) {
              // 在 tool_use 之前刷新文本块
              flushTextBlock();
              final id = (cb['id'] ?? '').toString();
              final name = (cb['name'] ?? '').toString();
              final idx2 = idx ?? -1;
              if (id.isNotEmpty) {
                anthToolUse.putIfAbsent(id, () => {'name': name, 'args': ''});
                assistantBlocks.add({
                  'type': 'tool_use',
                  'id': id,
                  'name': name,
                  'input': {},
                });
                if (idx2 >= 0) cliIndexToId[idx2] = id;
                // 立即输出占位工具调用卡片
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: roundTokens,
                  usage: usage,
                  toolCalls: [
                    ToolCallInfo(
                      id: id,
                      name: name,
                      arguments: const <String, dynamic>{},
                      metadata: {
                        'anthropic': {'assistant_blocks': assistantBlocks},
                      },
                    ),
                  ],
                );
              }
            } else if (cb is Map && (cb['type'] == 'server_tool_use')) {
              final id = (cb['id'] ?? '').toString();
              final name = (cb['name'] ?? '').toString();
              final idx2 = idx ?? -1;
              if (id.isNotEmpty && idx2 >= 0) {
                srvIndexToId[idx2] = id;
                srvArgsStr[id] = '';
              }
              // 为服务端工具输出占位以显示卡片（例如内置 web_search）
              if (id.isNotEmpty && name == 'web_search') {
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: roundTokens,
                  usage: usage,
                  toolCalls: [
                    ToolCallInfo(
                      id: id,
                      name: 'search_web',
                      arguments: const <String, dynamic>{},
                      metadata: {
                        'anthropic': {'assistant_blocks': assistantBlocks},
                      },
                    ),
                  ],
                );
              }
            } else if (cb is Map && (cb['type'] == 'web_search_tool_result')) {
              // 向 UI 输出简化后的搜索结果
              final toolUseId = (cb['tool_use_id'] ?? '').toString();
              final contentBlock = cb['content'];
              final items = <Map<String, dynamic>>[];
              String? errorCode;
              if (contentBlock is List) {
                for (int j = 0; j < contentBlock.length; j++) {
                  final it = contentBlock[j];
                  if (it is Map && (it['type'] == 'web_search_result')) {
                    items.add({
                      'index': j + 1,
                      'title': (it['title'] ?? '').toString(),
                      'url': (it['url'] ?? '').toString(),
                      if ((it['page_age'] ?? '').toString().isNotEmpty)
                        'page_age': (it['page_age'] ?? '').toString(),
                    });
                  }
                }
              } else if (contentBlock is Map &&
                  (contentBlock['type'] == 'web_search_tool_result_error')) {
                errorCode = (contentBlock['error_code'] ?? '').toString();
              }
              Map<String, dynamic> args = const <String, dynamic>{};
              if (srvArgs.containsKey(toolUseId)) args = srvArgs[toolUseId]!;
              final payload = jsonEncode({
                'items': items,
                if ((errorCode ?? '').isNotEmpty) 'error': errorCode,
              });
              yield ChatStreamChunk(
                content: '',
                isDone: false,
                totalTokens: roundTokens,
                usage: usage,
                toolResults: [
                  ToolResultInfo(
                    id: toolUseId.isEmpty ? 'builtin_search' : toolUseId,
                    name: 'search_web',
                    arguments: args,
                    content: payload,
                    metadata: {
                      'anthropic': {'assistant_blocks': assistantBlocks},
                    },
                  ),
                ],
              );
            }
          } else if (type == 'content_block_delta') {
            final delta = obj['delta'];
            if (delta != null) {
              if (delta['type'] == 'text_delta') {
                final content = delta['text'] ?? '';
                if (content is String && content.isNotEmpty) {
                  textBuf.write(content);
                  yield ChatStreamChunk(
                    content: content,
                    isDone: false,
                    totalTokens: roundTokens,
                  );
                }
              } else if (delta['type'] == 'thinking_delta') {
                final idx = parseIndex(obj['index']);
                final thinking =
                    (delta['thinking'] ?? delta['text'] ?? '') as String;
                if (thinking.isNotEmpty) {
                  yield ChatStreamChunk(
                    content: '',
                    reasoning: thinking,
                    isDone: false,
                    totalTokens: roundTokens,
                  );
                  if (idx != null && thinkingText.containsKey(idx)) {
                    thinkingText[idx]!.write(thinking);
                  }
                }
              } else if (delta['type'] == 'signature_delta') {
                final idx = parseIndex(obj['index']);
                final sig = (delta['signature'] ?? '').toString();
                if (sig.isNotEmpty &&
                    idx != null &&
                    thinkingSig.containsKey(idx)) {
                  thinkingSig[idx]!.write(sig);
                }
              } else if (delta['type'] == 'redacted_thinking_delta') {
                final idx = parseIndex(obj['index']);
                final data = (delta['data'] ?? '').toString();
                if (data.isNotEmpty &&
                    idx != null &&
                    redactedThinkingData.containsKey(idx)) {
                  redactedThinkingData[idx]!.write(data);
                }
              } else if (delta['type'] == 'tool_use_delta') {
                // client 工具输入片段在相同的 content_block 索引下流式传输
                final idx = (obj['index'] is int)
                    ? obj['index'] as int
                    : int.tryParse((obj['index'] ?? '').toString());
                final id = (idx != null && cliIndexToId.containsKey(idx))
                    ? cliIndexToId[idx]!
                    : '';
                if (id.isNotEmpty) {
                  final argsDelta =
                      (delta['partial_json'] ??
                              delta['input'] ??
                              delta['text'] ??
                              '')
                          .toString();
                  final entry = anthToolUse.putIfAbsent(
                    id,
                    () => {'name': '', 'args': ''},
                  );
                  if (argsDelta.isNotEmpty) {
                    entry['args'] = (entry['args'] ?? '') + argsDelta;
                  }
                }
              } else if (delta['type'] == 'input_json_delta') {
                final idxRaw = obj['index'];
                final index = (idxRaw is int)
                    ? idxRaw
                    : int.tryParse((idxRaw ?? '').toString());
                final part = (delta['partial_json'] ?? '').toString();
                if (index != null && part.isNotEmpty) {
                  if (cliIndexToId.containsKey(index)) {
                    final id = cliIndexToId[index]!;
                    final entry = anthToolUse.putIfAbsent(
                      id,
                      () => {'name': '', 'args': ''},
                    );
                    entry['args'] = (entry['args'] ?? '') + part;
                  } else if (srvIndexToId.containsKey(index)) {
                    final id = srvIndexToId[index]!;
                    srvArgsStr[id] = (srvArgsStr[id] ?? '') + part;
                  }
                }
              }
            }
          } else if (type == 'content_block_stop') {
            final idx = parseIndex(obj['index']);
            // 收尾 thinking 块，使其能原样回传。
            if (idx != null && thinkingIndexToAssistantBlock.containsKey(idx)) {
              final pos = thinkingIndexToAssistantBlock.remove(idx)!;
              final t = thinkingText.remove(idx)?.toString() ?? '';
              final sig = thinkingSig.remove(idx)?.toString() ?? '';
              assistantBlocks[pos] = {
                'type': 'thinking',
                'thinking': t,
                'signature': sig,
              };
            }
            if (idx != null &&
                redactedThinkingIndexToAssistantBlock.containsKey(idx)) {
              final pos = redactedThinkingIndexToAssistantBlock.remove(idx)!;
              final data = redactedThinkingData.remove(idx)?.toString() ?? '';
              assistantBlocks[pos] = {
                'type': 'redacted_thinking',
                'data': data,
              };
            }
            String id = (obj['content_block']?['id'] ?? obj['id'] ?? '')
                .toString();
            if (id.isEmpty && idx != null && cliIndexToId.containsKey(idx)) {
              id = cliIndexToId[idx]!;
            }
            if (id.isNotEmpty && anthToolUse.containsKey(id)) {
              final name = (anthToolUse[id]!['name'] ?? '').toString();
              Map<String, dynamic> args;
              try {
                args =
                    (jsonDecode((anthToolUse[id]!['args'] ?? '{}') as String)
                            as Map)
                        .cast<String, dynamic>();
              } catch (_) {
                args = <String, dynamic>{};
              }
              // 更新最后一条助手 tool_use 块的输入
              for (int k = assistantBlocks.length - 1; k >= 0; k--) {
                final b = assistantBlocks[k];
                if (b['type'] == 'tool_use' &&
                    (b['id']?.toString() ?? '') == id) {
                  assistantBlocks[k] = {
                    'type': 'tool_use',
                    'id': id,
                    'name': name,
                    'input': args,
                  };
                  break;
                }
              }
              // 向 UI 输出工具结果（开头已输出占位）
              if (onToolCall != null) {
                final res = await onToolCall(name, args, toolCallId: id);
                toolResultsContent[id] = res;
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: roundTokens,
                  toolResults: [
                    ToolResultInfo(
                      id: id,
                      name: name,
                      arguments: args,
                      content: res,
                      metadata: {
                        'anthropic': {'assistant_blocks': assistantBlocks},
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
            } else {
              if (idx != null && srvIndexToId.containsKey(idx)) {
                final sid = srvIndexToId[idx]!;
                Map<String, dynamic> args;
                try {
                  args = jsonDecode(
                    srvArgsStr[sid] ?? '{}',
                  ).cast<String, dynamic>();
                } catch (_) {
                  args = <String, dynamic>{};
                }
                srvArgs[sid] = args;
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: roundTokens,
                  usage: usage,
                  toolCalls: [
                    ToolCallInfo(
                      id: sid,
                      name: 'search_web',
                      arguments: args,
                      metadata: {
                        'anthropic': {'assistant_blocks': assistantBlocks},
                      },
                    ),
                  ],
                );
              }
            }
          } else if (type == 'message_delta') {
            final u = obj['usage'] ?? obj['message']?['usage'];
            if (u is Map) {
              usage = (usage ?? const TokenUsage()).merge(
                _claudeUsageFromMap(u.cast<String, dynamic>()),
              );
              roundTokens = usage.totalTokens;
            }
            // 捕获 stop reason 以处理服务端工具的 pause_turn
            try {
              final d = obj['delta'];
              final sr = (d is Map)
                  ? (d['stop_reason'] ?? d['stopReason'])
                  : null;
              if (sr is String && sr.isNotEmpty) {
                lastStopReason = sr;
              }
            } catch (_) {}
          } else if (type == 'message_stop') {
            // 刷新剩余文本
            final t = textBuf.toString();
            if (t.isNotEmpty) {
              assistantBlocks.add({'type': 'text', 'text': t});
            }
            messageStopped = true;
          }
        } catch (_) {
          // 忽略格式错误的分片
        }
      }
      if (messageStopped) {
        break; // 跳出 await-for
      }
    }

    // 合并各轮用量以得到最终 token 计数
    if (usage != null) {
      totalUsage = (totalUsage ?? const TokenUsage()).accumulate(usage);
    }

    // 若无 client 工具调用，决定是继续（pause_turn/服务端工具）还是结束
    if (anthToolUse.isEmpty) {
      final sr = lastStopReason ?? '';
      if (sr == 'pause_turn') {
        // 仅用助手内容继续本轮
        convo = [
          ...convo,
          {'role': 'assistant', 'content': assistantBlocks},
        ];
        // 进入下一轮
        continue;
      } else {
        yield ChatStreamChunk(
          content: '',
          isDone: true,
          totalTokens: (totalUsage?.totalTokens ?? roundTokens),
          usage: totalUsage ?? usage,
        );
        return;
      }
    }

    // 在单条用户消息中构建 tool_result 块（并行安全）
    final toolResultsBlocks = <Map<String, dynamic>>[];
    for (final entry in anthToolUse.entries) {
      final id = entry.key;
      final name = (entry.value['name'] ?? '').toString();
      Map<String, dynamic> args;
      try {
        args = (jsonDecode((entry.value['args'] ?? '{}') as String) as Map)
            .cast<String, dynamic>();
      } catch (_) {
        args = <String, dynamic>{};
      }
      String res = toolResultsContent[id] ?? '';
      if (res.isEmpty && onToolCall != null) {
        res = await onToolCall(name, args, toolCallId: id);
      }
      toolResultsBlocks.add({
        'type': 'tool_result',
        'tool_use_id': id,
        if (res.isNotEmpty) 'content': res,
      });
    }

    // 扩展对话：助手内容（含 tool_use 块）+ user tool_results
    convo = [
      ...convo,
      {'role': 'assistant', 'content': assistantBlocks},
      {'role': 'user', 'content': toolResultsBlocks},
    ];
    // 进入下一轮；下一次响应会流出更多助手内容
  }
}
