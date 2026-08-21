part of '../chat_api_service.dart';

Stream<ChatStreamChunk> _sendGoogleVertexStream(
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
}) {
  final cfg = config.copyWith(vertexAI: true);
  return _sendGoogleStream(
    client,
    cfg,
    modelId,
    messages,
    userImagePaths: userImagePaths,
    thinkingBudget: thinkingBudget,
    temperature: temperature,
    topP: topP,
    maxTokens: maxTokens,
    tools: tools,
    onToolCall: onToolCall,
    extraHeaders: extraHeaders,
    extraBody: extraBody,
    stream: stream,
  );
}

/// Vertex 媒体下载是否可以附带 Bearer / X-Goog-User-Project。
///
/// 仅使用严格的 Google 主机白名单，绝不使用宽泛的 *.google.com。
/// 认证头仅用于 HTTPS，因此令牌绝不会在
/// `http://storage.googleapis.com/...`（或任何其他已白名单的 HTTP URL）上以明文发送。
bool _shouldAttachVertexMediaAuth(Uri uri) {
  if (uri.scheme.toLowerCase() != 'https') return false;
  final host = uri.host.trim().toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'googleapis.com' || host.endsWith('.googleapis.com')) {
    return true;
  }
  if (host == 'googleusercontent.com' ||
      host.endsWith('.googleusercontent.com')) {
    return true;
  }
  if (host == 'storage.cloud.google.com') return true;
  return false;
}

Future<String> _downloadRemoteAsBase64(
  http.Client client,
  ProviderConfig config,
  String url,
) async {
  final uri = Uri.parse(url);
  final req = http.Request('GET', uri);
  // 仅对已白名单的 Google 媒体主机附加 Vertex 认证。
  if (config.vertexAI == true && _shouldAttachVertexMediaAuth(uri)) {
    try {
      final token = await _maybeVertexAccessToken(config);
      if (token != null && token.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
    } catch (_) {}
    final proj = (config.projectId ?? '').trim();
    if (proj.isNotEmpty) {
      req.headers['X-Goog-User-Project'] = proj;
    }
  }
  final resp = await client.send(req);
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    final err = await resp.stream.bytesToString();
    throw HttpException('HTTP ${resp.statusCode}: $err');
  }
  final bytes = await resp.stream.fold<List<int>>(<int>[], (acc, b) {
    acc.addAll(b);
    return acc;
  });
  return base64Encode(bytes);
}

// 当配置了 serviceAccountJson 时，返回 Vertex AI 的 OAuth 令牌；否则返回 null。
Future<String?> _maybeVertexAccessToken(ProviderConfig cfg) async {
  if (cfg.vertexAI == true) {
    final jsonStr = (cfg.serviceAccountJson ?? '').trim();
    if (jsonStr.isEmpty) {
      // 回退：部分用户可能会将临时 OAuth 令牌粘贴到 apiKey 中
      if (cfg.apiKey.isNotEmpty) return cfg.apiKey;
      return null;
    }
    try {
      return await GoogleServiceAccountAuth.getAccessTokenFromJson(jsonStr);
    } catch (_) {
      // 失败时不要中断流式处理；让服务器返回 401，并将错误向上游抛出
      return null;
    }
  }
  return null;
}

int _getMaxOutputTokensForClaudeModel(String modelId) {
  // 限制依据 Google Vertex AI 文档
  switch (modelId) {
    case 'claude-fable-5':
    case 'claude-opus-5':
    case 'claude-opus-4-8':
    case 'claude-opus-4-7':
    case 'claude-opus-4-6':
    case 'claude-sonnet-5':
    case 'claude-sonnet-4-6':
      return 128000;
    case 'claude-opus-4-5@20251101':
    case 'claude-sonnet-4-5@20250929':
    case 'claude-haiku-4-5@20251001':
    case 'claude-sonnet-4@20250514':
      return 64000;
    case 'claude-opus-4-1@20250805':
    case 'claude-opus-4@20250514':
      return 32000;
    case 'claude-3-haiku@20240307':
      return 8000;
    case 'claude-3-5-sonnet@20240620':
    case 'claude-3-5-sonnet-v2@20241022':
      return 8192;
    default:
      // 旧模型的回退方案
      return 4096;
  }
}

Stream<ChatStreamChunk> _sendGoogleVertexClaudeStream({
  required http.Client client,
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
}) async* {
  final upstreamId = _apiModelId(config, modelId);
  final loc = (config.location ?? 'us-central1').trim();
  final proj = (config.projectId ?? '').trim();
  final endpoint = stream ? 'streamRawPredict' : 'rawPredict';
  // Vertex AI Anthropic 地址
  final host = (loc.toLowerCase() == 'global')
      ? 'aiplatform.googleapis.com'
      : '$loc-aiplatform.googleapis.com';
  final url = Uri.parse(
    'https://$host/v1/projects/$proj/locations/$loc/publishers/anthropic/models/$upstreamId:$endpoint',
  );

  final isReasoning = _effectiveModelInfo(
    config,
    modelId,
  ).abilities.contains(ModelAbility.reasoning);

  // 根据模型能力确定有效的 max_tokens
  int effectiveMaxTokens =
      maxTokens ?? _getMaxOutputTokensForClaudeModel(upstreamId);

  // 确保 thinking_budget < max_tokens（API 要求）
  int? effectiveThinkingBudget = thinkingBudget;
  if (isReasoning &&
      effectiveThinkingBudget != null &&
      effectiveThinkingBudget > 0) {
    if (effectiveThinkingBudget >= effectiveMaxTokens) {
      // 至少为响应内容预留 1k 个 token
      effectiveThinkingBudget = effectiveMaxTokens - 1024;
      if (effectiveThinkingBudget < 1024) {
        effectiveThinkingBudget = 1024; // 下限
      }
    }
  }

  final requestHeaders = <String, String>{'Content-Type': 'application/json'};
  final token = await _maybeVertexAccessToken(config);
  if (token != null && token.isNotEmpty) {
    requestHeaders['Authorization'] = 'Bearer $token';
  }
  final headers = _customHeaders(
    config,
    modelId,
    baseHeaders: requestHeaders,
    assistantHeaders: extraHeaders,
  );

  // 提取系统提示词
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
    // 让 media-paths 在转换过程中保留；最终请求只输出 role/content。
    nonSystemMessages.add(
      Map<String, dynamic>.from(m)
        ..remove(multimodalInternalRevisionIdKey)
        ..['role'] = role.isEmpty ? 'user' : role,
    );
  }

  // 转换消息与图像（对 Vertex 强制使用 Base64）
  final initialMessages = <Map<String, dynamic>>[];
  for (int i = 0; i < nonSystemMessages.length; i++) {
    final m = nonSystemMessages[i];
    final isLast = i == nonSystemMessages.length - 1;
    final roleName = (m['role'] ?? 'user').toString();
    final raw = (m['content'] ?? '').toString();
    // 仅做语义媒体检测，不识别自定义附件标记。附件通过结构化 media-path 键 /
    // userImagePaths 以及 Markdown ![](...) 到达。
    final hasMarkdownImages = raw.contains('![') && raw.contains('](');
    final internalMediaRefs = parseInternalMediaRefs(
      m[multimodalInternalMediaPathsKey],
    );
    // 消费已注入的媒体引用，用于用户和助手的历史轮次。
    final hasInternalMedia = internalMediaRefs.isNotEmpty;
    final hasAttachedImages =
        isLast && roleName == 'user' && (userImagePaths?.isNotEmpty == true);

    if ((roleName == 'user' || roleName == 'assistant') &&
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

      Future<void> addVertexClaudeImage(
        String source, {
        String? explicitMime,
      }) async {
        final normalized = normalizeSrc(source);
        if (!seenSources.add(normalized)) return;
        // Vertex AI Claude 通常不支持 'image' 块中的远程 URL，必须下载并编码。
        String mime;
        String b64;
        if (source.startsWith('http://') || source.startsWith('https://')) {
          try {
            b64 = await _downloadRemoteAsBase64(client, config, source);
            mime = (explicitMime != null && explicitMime.trim().isNotEmpty)
                ? explicitMime.trim()
                : 'image/png'; // TODO：从响应或 URL 检测 MIME 类型
            if (explicitMime == null || explicitMime.trim().isEmpty) {
              final lower = source.toLowerCase();
              if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
                mime = 'image/jpeg';
              }
              if (lower.endsWith('.webp')) mime = 'image/webp';
              if (lower.endsWith('.gif')) mime = 'image/gif';
            }
          } catch (_) {
            parts.add({
              'type': 'text',
              'text': '(image failed to download) $source',
            });
            return;
          }
        } else if (source.startsWith('data:')) {
          mime = (explicitMime != null && explicitMime.trim().isNotEmpty)
              ? explicitMime.trim()
              : _mimeFromDataUrl(source);
          final idx = source.indexOf('base64,');
          if (idx > 0) {
            b64 = source.substring(idx + 7);
          } else {
            return;
          }
        } else {
          mime = (explicitMime != null && explicitMime.trim().isNotEmpty)
              ? explicitMime.trim()
              : _mimeFromPath(source);
          final encoded = await _tryEncodeBase64File(source, withPrefix: false);
          if (encoded == null) return;
          b64 = encoded;
        }
        if (b64.isNotEmpty) {
          parts.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': _normalizeClaudeImageMime(mime),
              'data': b64,
            },
          });
        }
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
        await addVertexClaudeImage(ref.src);
      }
      final supplementalRefs = _supplementalMediaRefs(
        internalRaw: m[multimodalInternalMediaPathsKey],
        userPaths: userImagePaths,
        includeUserPaths: hasAttachedImages,
      );
      for (final mediaRef in supplementalRefs) {
        final mime = _mimeForInternalMediaRef(mediaRef);
        // 切勿为视频/音频或其他非 Claude 图像 MIME 类型
        // （例如 video/mp4）输出 Anthropic 图像块。
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
        await addVertexClaudeImage(mediaRef.uri, explicitMime: mediaRef.mime);
      }
      initialMessages.add({
        'role': roleName,
        'content': parts.isEmpty ? raw : parts,
      });
    } else {
      initialMessages.add({'role': roleName, 'content': raw});
    }
  }

  // 工具设置（沿用 Claude 的逻辑）
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
  final List<Map<String, dynamic>> allTools = [];
  if (anthropicTools != null && anthropicTools.isNotEmpty) {
    allTools.addAll(anthropicTools);
  }
  if (tools != null && tools.isNotEmpty) {
    for (final t in tools) {
      if (t['type'] is String &&
          (t['type'] as String).startsWith('web_search_')) {
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
    final entry = <String, dynamic>{
      'type': 'web_search_20250305',
      'name': 'web_search',
    };
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

  List<Map<String, dynamic>> convo = List<Map<String, dynamic>>.from(
    initialMessages,
  );
  TokenUsage? totalUsage;

  while (true) {
    final omitSamplingParams = _claudeShouldOmitSamplingParams(
      upstreamId,
      effectiveThinkingBudget,
    );
    final compatibleTopP = _claudeCompatibleTopP(
      upstreamId,
      effectiveThinkingBudget,
      topP,
    );
    final thinking = isReasoning
        ? _claudeThinkingConfig(upstreamId, effectiveThinkingBudget)
        : null;
    final outputConfig = isReasoning
        ? _claudeOutputConfig(upstreamId, effectiveThinkingBudget)
        : null;
    final body = <String, dynamic>{
      'anthropic_version': 'vertex-2023-10-16',
      'messages': convo,
      'stream': stream,
      'max_tokens': effectiveMaxTokens,
      if (systemPrompt.isNotEmpty) 'system': systemPrompt,
      if (!omitSamplingParams &&
          !_isClaudeReasoningEnabled(effectiveThinkingBudget) &&
          temperature != null)
        'temperature': temperature,
      if (compatibleTopP != null) 'top_p': compatibleTopP,
      if (allTools.isNotEmpty) 'tools': allTools,
      if (allTools.isNotEmpty) 'tool_choice': {'type': 'auto'},
      if (thinking != null) 'thinking': thinking,
      if (outputConfig != null) 'output_config': outputConfig,
    };
    body.addAll(_customBody(config, modelId, assistantBody: extraBody));

    final request = http.Request('POST', url);
    request.headers.addAll(headers);
    request.body = jsonEncode(body);

    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBody = await response.stream.bytesToString();
      throw HttpException('HTTP ${response.statusCode}: $errorBody');
    }

    if (!stream) {
      // Vertex rawPredict 响应与 Anthropic 非流式响应相同
      final txt = await response.stream.bytesToString();
      final obj = jsonDecode(txt) as Map;
      // 用量
      try {
        final u = (obj['usage'] as Map?)?.cast<String, dynamic>();
        if (u != null) {
          totalUsage = (totalUsage ?? const TokenUsage()).merge(
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
        } else if (type == 'thinking' || type == 'redacted_thinking') {
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
        // 扩展对话：助手 + 用户 tool_result，然后循环
        final assistantMsg = {'role': 'assistant', 'content': assistantBlocks};
        final userToolMsg = {'role': 'user', 'content': results};
        convo = [...convo, assistantMsg, userToolMsg];
        continue; // 下一轮
      }
      // 未使用工具 -> 返回最终文本
      yield ChatStreamChunk(
        content: buf.toString(),
        isDone: true,
        totalTokens: (totalUsage?.totalTokens ?? 0),
        usage: totalUsage,
      );
      return;
    }

    // 流式路径
    final sse = response.stream.transform(utf8.decoder);
    String buffer = '';
    int roundTokens = 0;
    TokenUsage? usage;
    String? lastStopReason;

    final Map<String, Map<String, dynamic>> anthToolUse =
        <String, Map<String, dynamic>>{};
    final Map<int, String> cliIndexToId = <int, String>{};
    final Map<String, String> toolResultsContent = <String, String>{};
    final List<Map<String, dynamic>> assistantBlocks = <Map<String, dynamic>>[];
    final StringBuffer textBuf = StringBuffer();

    // 服务端工具辅助函数（web_search）
    final Map<int, String> srvIndexToId = <int, String>{};
    final Map<String, String> srvArgsStr = <String, String>{};
    final Map<String, Map<String, dynamic>> srvArgs =
        <String, Map<String, dynamic>>{};

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

    bool messageStopped = false;

    await for (final chunk in _ensureTrailingNewline(sse)) {
      buffer += chunk;
      final lines = buffer.split('\n');
      buffer = lines.last;

      for (int i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isEmpty || !line.startsWith('data:')) continue;

        final data = line.substring(5).trimLeft();
        // Anthropic-on-Vertex 会以 `event: error` 在带内报告失败，
        // 并携带 {type:"error", error:{type,message}}；请在下方
        // 格式错误分块保护逻辑吞掉它之前抛出异常。
        _throwIfInBandStreamError(data);
        try {
          final obj = jsonDecode(data);
          final type = obj['type'];

          if (type == 'content_block_start') {
            final cb = obj['content_block'];
            final idx = parseIndex(obj['index']);
            if (cb is Map && (cb['type'] == 'thinking')) {
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
              if (idx != null) {
                assistantBlocks.add({'type': 'redacted_thinking', 'data': ''});
                redactedThinkingIndexToAssistantBlock[idx] =
                    assistantBlocks.length - 1;
                redactedThinkingData[idx] = StringBuffer();
              }
            } else if (cb is Map && (cb['type'] == 'tool_use')) {
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
                if (idx2 >= 0) {
                  cliIndexToId[idx2] = id;
                }
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
                    ),
                  ],
                );
              }
            } else if (cb is Map && (cb['type'] == 'server_tool_use')) {
              final id = (cb['id'] ?? '').toString();
              final idx2 = idx ?? -1;
              if (id.isNotEmpty && idx2 >= 0) {
                srvIndexToId[idx2] = id;
                srvArgsStr[id] = '';
              }
              // 为服务端工具发出占位符，以显示卡片（例如内置的 web_search）
              if (id.isNotEmpty) {
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
                    ),
                  ],
                );
              }
            } else if (cb is Map && (cb['type'] == 'web_search_tool_result')) {
              // 向 UI 输出简化的搜索结果
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
              if (srvArgs.containsKey(toolUseId)) {
                args = srvArgs[toolUseId]!;
              }
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
              // 更新最后一个助手 tool_use 块的输入
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
                  args = (jsonDecode((srvArgsStr[sid] ?? '{}')) as Map)
                      .cast<String, dynamic>();
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
                    ToolCallInfo(id: sid, name: 'search_web', arguments: args),
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
            flushTextBlock();
            messageStopped = true;
          }
        } catch (_) {}
      }
      if (messageStopped) break;
    }

    if (usage != null) {
      totalUsage = (totalUsage ?? const TokenUsage()).merge(usage);
    }

    if (anthToolUse.isEmpty) {
      final sr = lastStopReason ?? '';
      if (sr == 'pause_turn') {
        // 本轮继续只使用助手内容（Vertex streamRawPredict 目前尚未完全支持，
        // 但可为未来兼容预留）
        convo = [
          ...convo,
          {'role': 'assistant', 'content': assistantBlocks},
        ];
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

    // 构建 tool_result 块
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

    convo = [
      ...convo,
      {'role': 'assistant', 'content': assistantBlocks},
      {'role': 'user', 'content': toolResultsBlocks},
    ];
  }
}
