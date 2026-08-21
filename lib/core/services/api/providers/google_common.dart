part of '../chat_api_service.dart';

/// 构建 Gemini tools 数组，处理 Gemini 3 共存与 2.x 互斥。
///
/// Gemini 3：内置工具可与 function_declarations（MCP）共存。
/// Gemini 2.x 及以下：code_execution 独占；search/url_context 会排除 MCP。
List<Map<String, dynamic>> _buildGeminiToolsArray({
  required Set<String> builtIns,
  required bool allowCoexistence,
  List<Map<String, dynamic>>? geminiTools,
}) {
  final toolsArr = <Map<String, dynamic>>[];
  if (allowCoexistence) {
    if (builtIns.contains(BuiltInToolNames.codeExecution)) {
      toolsArr.add({'code_execution': {}});
    }
    if (builtIns.contains(BuiltInToolNames.search)) {
      toolsArr.add({'google_search': {}});
    }
    if (builtIns.contains(BuiltInToolNames.urlContext)) {
      toolsArr.add({'url_context': {}});
    }
    if (geminiTools != null) {
      toolsArr.addAll(geminiTools);
    }
  } else {
    if (builtIns.contains(BuiltInToolNames.codeExecution)) {
      toolsArr.add({'code_execution': {}});
    } else if (builtIns.contains(BuiltInToolNames.search) ||
        builtIns.contains(BuiltInToolNames.urlContext)) {
      if (builtIns.contains(BuiltInToolNames.search)) {
        toolsArr.add({'google_search': {}});
      }
      if (builtIns.contains(BuiltInToolNames.urlContext)) {
        toolsArr.add({'url_context': {}});
      }
    } else if (geminiTools != null) {
      toolsArr.addAll(geminiTools);
    }
  }
  return toolsArr;
}

bool _isGemma4Model(String modelId) {
  return RegExp(
    r'(^|[/:_-])gemma[-_]?4([._-]|$)',
    caseSensitive: false,
  ).hasMatch(modelId);
}

bool _isGemini35FlashModel(String modelId) {
  return modelId.contains(
    RegExp(r'gemini-3\.5-flash([._:@/-]|$)', caseSensitive: false),
  );
}

bool _isGemini35FlashLiteModel(String modelId) {
  return modelId.contains(
    RegExp(r'gemini-3\.5-flash-lite([._:@/-]|$)', caseSensitive: false),
  );
}

bool _isGemini36FlashModel(String modelId) {
  return modelId.contains(
    RegExp(r'gemini-3\.6-flash([._:@/-]|$)', caseSensitive: false),
  );
}

bool _isGemini3TextModel(String modelId) {
  return modelId.contains(
    RegExp(r'gemini-3(?:\.\d+)?-(?!pro-image)', caseSensitive: false),
  );
}

bool _shouldOmitGeminiSamplingParams(String modelId) {
  return _isGemini3TextModel(modelId);
}

Map<String, dynamic> _googleThinkingConfig(
  String upstreamModelId,
  int? budget,
) {
  final off = _isOff(budget);
  if (_isGemma4Model(upstreamModelId)) {
    if (off) return const <String, dynamic>{};
    return const <String, dynamic>{
      'includeThoughts': true,
      'thinkingLevel': 'high',
    };
  }

  // 匹配 gemini-3-pro 或 gemini-3-pro-preview（以及类似变体）
  final isGemini3ProImage = upstreamModelId.contains(
    RegExp(r'gemini-3-pro-image(-preview)?', caseSensitive: false),
  );
  final isGemini31Pro = upstreamModelId.contains(
    RegExp(r'gemini-3\.1-pro(-preview)?', caseSensitive: false),
  );
  final isGemini3Pro = upstreamModelId.contains(
    RegExp(r'gemini-3-pro(-preview)?', caseSensitive: false),
  );
  final isGemini3Flash = upstreamModelId.contains(
    RegExp(r'gemini-3-flash(-preview)?', caseSensitive: false),
  );
  final isGemini35Flash = _isGemini35FlashModel(upstreamModelId);
  final isGemini35FlashLite = _isGemini35FlashLiteModel(upstreamModelId);
  final isGemini36Flash = _isGemini36FlashModel(upstreamModelId);
  if (isGemini3ProImage) {
    return {
      'includeThoughts': true,
      if (budget != null && budget >= 0) 'thinkingBudget': budget,
    };
  }
  // Gemini 3.1 Pro：支持 'low'、'medium'、'high'（不支持 minimal）
  if (isGemini31Pro) {
    String level = 'high';
    if (off) {
      level = 'low';
    } else if (budget != null && budget > 0) {
      if (budget < 8000) {
        level = 'low';
      } else if (budget < 24000) {
        level = 'medium'; // gemini 3.1 pro 支持 medium
      }
    }
    return {'includeThoughts': true, 'thinkingLevel': level};
  }
  // Gemini 3 Pro：仅支持 'low' 和 'high'（不支持 off）
  if (isGemini3Pro) {
    String level = 'high';
    if (off || (budget != null && budget > 0 && budget < 8000)) {
      // Off 或 Light (1024) -> low
      level = 'low';
    }
    return {'includeThoughts': true, 'thinkingLevel': level};
  }
  // Gemini 3 Flash、3.5 Flash/Lite 和 3.6 Flash 支持
  // 'minimal'、'low'、'medium' 和 'high'。
  if (isGemini3Flash || isGemini35Flash || isGemini36Flash) {
    String level = isGemini35FlashLite
        ? 'minimal'
        : (isGemini35Flash || isGemini36Flash ? 'medium' : 'high');
    if (off) {
      level = 'minimal';
    } else if (budget != null && budget > 0) {
      // Light (1024) -> low，Medium (16000) -> medium，Heavy (32000) -> high
      if (budget < 8000) {
        level = 'low';
      } else if (budget < 24000) {
        level = 'medium';
      } else {
        level = 'high';
      }
    }
    return {'includeThoughts': true, 'thinkingLevel': level};
  }
  // Gemini 2.x 及以下：使用 thinkingBudget
  if (off) return {'includeThoughts': false};
  return {
    'includeThoughts': true,
    if (budget != null && budget >= 0) 'thinkingBudget': budget,
  };
}

Map<String, dynamic>? _googleToolMetadata(Map<String, dynamic> message) {
  final metadata = message['metadata'];
  if (metadata is! Map) return null;
  final google = metadata['google'];
  if (google is! Map) return null;
  return google.cast<String, dynamic>();
}

Map<String, dynamic>? _googleFunctionCallPartFromToolCall(Map toolCall) {
  final metadata = toolCall['metadata'];
  if (metadata is Map) {
    final google = metadata['google'];
    if (google is Map) {
      final part = google['part'];
      if (part is Map && part['functionCall'] is Map) {
        // 可变副本：调用方可能需要回填 thought 签名。
        return Map<String, dynamic>.from(part);
      }
    }
  }

  final fn = toolCall['function'];
  if (fn is! Map) return null;
  final name = (fn['name'] ?? '').toString();
  if (name.isEmpty) return null;
  Map<String, dynamic> args = const <String, dynamic>{};
  try {
    args = (jsonDecode((fn['arguments'] ?? '{}').toString()) as Map)
        .cast<String, dynamic>();
  } catch (_) {}
  final part = <String, dynamic>{
    'functionCall': {'name': name, 'args': args},
  };
  final id = (toolCall['id'] ?? '').toString();
  if (id.isNotEmpty) part['id'] = id;
  return part;
}

/// Gemini 3 会校验重放的模型轮次中第一个 functionCall 部分
/// 是否携带思考签名；缺失会导致整个请求失败，
/// 错误为 "Function call is missing a thought_signature in functionCall parts"。
/// 当原始签名未被持久化时（旧历史、非流式响应），
/// 回退到文档规定的占位符，以便旧对话继续正常工作。
void _ensureGeminiFunctionCallThoughtSig(List<Map<String, dynamic>> parts) {
  for (final part in parts) {
    if (part['functionCall'] is! Map) continue;
    final hasSig =
        part.containsKey('thoughtSignature') ||
        part.containsKey('thought_signature');
    if (!hasSig) {
      part['thoughtSignature'] = _geminiDummyThoughtSignature;
    }
    return; // 仅第一个 functionCall 部分会被校验。
  }
}

Map<String, dynamic> _googleFunctionResponsePartFromToolMessage(
  Map<String, dynamic> message,
) {
  final name = (message['name'] ?? '').toString();
  final content = (message['content'] ?? '').toString();
  Map<String, dynamic> response;
  try {
    response = (jsonDecode(content) as Map).cast<String, dynamic>();
  } catch (_) {
    response = {'result': content};
  }
  final part = <String, dynamic>{
    'functionResponse': {'name': name, 'response': response},
  };
  final google = _googleToolMetadata(message);
  final rawPart = google?['part'];
  final rawFunctionCall = rawPart is Map ? rawPart['functionCall'] : null;
  final id = rawFunctionCall is Map ? rawFunctionCall['id']?.toString() : null;
  if (id != null && id.isNotEmpty) {
    (part['functionResponse'] as Map<String, dynamic>)['id'] = id;
  }
  return part;
}

List<Map<String, dynamic>> _googleApiContents(
  List<Map<String, dynamic>> contents,
) {
  return [
    for (final content in contents)
      {
        ...content,
        if (content['parts'] is List)
          'parts': [
            for (final part in content['parts'] as List)
              part is Map ? _googleApiPart(part) : part,
          ],
      },
  ];
}

Map<String, dynamic> _googleApiPart(Map part) {
  final out = Map<String, dynamic>.from(part);
  out.remove('id');
  return out;
}

int? _defaultGeminiMaxOutputTokens(String upstreamModelId) {
  if (_isGemini35FlashModel(upstreamModelId) ||
      _isGemini36FlashModel(upstreamModelId)) {
    return 65536;
  }
  return null;
}

bool _shouldRequestGoogleThoughts(
  ProviderConfig config,
  String modelId,
  ModelInfo effective,
) {
  if (effective.abilities.contains(ModelAbility.reasoning)) return true;
  final kind = ProviderConfig.classify(
    config.id,
    explicitType: config.providerType,
  );
  if (kind != ProviderKind.google) return false;
  return _apiModelId(config, modelId).toLowerCase().contains('gemini');
}

/// Gemini 会在没有候选结果的帧中以内联方式报告提示词级别的拦截（安全过滤器等），
/// 即 `promptFeedback.blockReason`；应将这些情况作为流错误抛出，
/// 而不是返回一个空的“正常”完成。
void _throwIfGeminiPromptBlocked(String data) {
  if (!data.contains('blockReason')) return;
  Object? decoded;
  try {
    decoded = jsonDecode(data);
  } catch (_) {
    return;
  }
  if (decoded is! Map) return;
  final candidates = decoded['candidates'];
  if (candidates is List && candidates.isNotEmpty) return;
  final feedback = decoded['promptFeedback'];
  if (feedback is! Map) return;
  final reason = (feedback['blockReason'] ?? '').toString().trim();
  if (reason.isEmpty || reason == 'BLOCK_REASON_UNSPECIFIED') return;
  final message = (feedback['blockReasonMessage'] ?? '').toString().trim();
  throw HttpException(
    message.isEmpty
        ? 'Prompt blocked ($reason)'
        : 'Prompt blocked ($reason): $message',
  );
}

/// 输出侧内容过滤会让候选回复以这些 `finishReason` 值之一结束，
/// 然后像正常完成一样关闭流，否则生成中途的拦截看起来只是一条很短的回复。
const Set<String> _geminiBlockedFinishReasons = {
  'SAFETY',
  'RECITATION',
  'BLOCKLIST',
  'PROHIBITED_CONTENT',
  'SPII',
  'IMAGE_SAFETY',
};

/// 将候选级别的内容过滤（如 `finishReason: SAFETY`）作为流错误抛出，
/// 这样被截断的输出就不会被当作正常完成持久化。
void _throwIfGeminiCandidateBlocked(String data) {
  if (!data.contains('finishReason')) return;
  Object? decoded;
  try {
    decoded = jsonDecode(data);
  } catch (_) {
    return;
  }
  if (decoded is! Map) return;
  final candidates = decoded['candidates'];
  if (candidates is! List) return;
  for (final cand in candidates) {
    if (cand is! Map) continue;
    final reason = (cand['finishReason'] ?? '').toString().trim();
    if (!_geminiBlockedFinishReasons.contains(reason)) continue;
    final message = (cand['finishMessage'] ?? '').toString().trim();
    throw HttpException(
      message.isEmpty
          ? 'Response blocked ($reason)'
          : 'Response blocked ($reason): $message',
    );
  }
}

Stream<ChatStreamChunk> _sendGoogleStream(
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
  // 检查 Vertex AI Claude 模型（前缀为 "claude-"）
  // 如果它是 Vertex 上的 Claude 模型，则路由到特殊处理
  if ((config.vertexAI == true) &&
      modelId.toLowerCase().startsWith('claude-')) {
    yield* _sendGoogleVertexClaudeStream(
      client: client,
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
      stream: stream,
    );
    return;
  }

  final upstreamModelId = _apiModelId(config, modelId);
  final bool isGemini3 = upstreamModelId.toLowerCase().contains('gemini-3');
  final bool persistGeminiThoughtSigs = isGemini3;
  final builtIns = _builtInTools(config, modelId);
  final enableYoutube = builtIns.contains(BuiltInToolNames.youtube);
  // 生效的模型功能（包含用户覆写）
  final effective = _effectiveModelInfo(config, modelId);
  final isReasoning = _shouldRequestGoogleThoughts(config, modelId, effective);
  // 非流式路径：使用 generateContent
  if (!stream) {
    final isVertex = config.vertexAI == true;
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    String url;
    if (isVertex &&
        (config.projectId?.isNotEmpty == true) &&
        (config.location?.isNotEmpty == true)) {
      url =
          'https://aiplatform.googleapis.com/v1/projects/${config.projectId}/locations/${config.location}/publishers/google/models/$upstreamModelId:generateContent';
    } else {
      url = '$base/models/$upstreamModelId:generateContent';
    }

    // 将系统消息提取到 systemInstruction 中（Google Gemini API 最佳实践）
    String systemPrompt = '';
    final contents = <Map<String, dynamic>>[];
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final roleRaw = (msg['role'] ?? 'user').toString();
      if (roleRaw == 'system') {
        final s = (msg['content'] ?? '').toString();
        if (s.isNotEmpty) {
          systemPrompt = systemPrompt.isEmpty ? s : '$systemPrompt\n\n$s';
        }
        continue;
      }
      final role = roleRaw == 'assistant' ? 'model' : 'user';
      if (roleRaw == 'tool') {
        contents.add({
          'role': 'user',
          'parts': [_googleFunctionResponsePartFromToolMessage(msg)],
        });
        continue;
      }
      if (roleRaw == 'assistant' && msg['tool_calls'] is List) {
        final parts = <Map<String, dynamic>>[];
        final raw = _extractGeminiThoughtMeta(
          (msg['content'] ?? '').toString(),
        ).cleanedText;
        if (raw.trim().isNotEmpty && raw.trim() != '\n\n') {
          parts.add({'text': raw});
        }
        for (final tc in msg['tool_calls'] as List) {
          if (tc is! Map) continue;
          final part = _googleFunctionCallPartFromToolCall(tc);
          if (part != null) parts.add(part);
        }
        if (persistGeminiThoughtSigs) {
          _ensureGeminiFunctionCallThoughtSig(parts);
        }
        if (parts.isNotEmpty) contents.add({'role': 'model', 'parts': parts});
        continue;
      }
      final isLast = i == messages.length - 1;
      final parts = <Map<String, dynamic>>[];
      final meta = _extractGeminiThoughtMeta((msg['content'] ?? '').toString());
      final raw = meta.cleanedText;
      final seenSources = <String>{};
      String normalizeSrc(String src) {
        if (src.startsWith('http') || src.startsWith('data:')) return src;
        try {
          return SandboxPathResolver.fix(src);
        } catch (_) {
          return src;
        }
      }

      // 仅进行语义媒体检测：自定义附件标记不会被识别。
      // 附件通过结构化 media-path 键 / userImagePaths 以及
      // Markdown ![](...) 传入。
      final hasMarkdownImages = raw.contains('![') && raw.contains('](');
      final internalMediaRefs = parseInternalMediaRefs(
        msg[multimodalInternalMediaPathsKey],
      );
      // 消费为 user 和 assistant 历史轮次注入的媒体引用。
      final hasInternalMedia = internalMediaRefs.isNotEmpty;
      final hasAttachedImages =
          isLast && role == 'user' && (userImagePaths?.isNotEmpty == true);
      if (hasMarkdownImages || hasAttachedImages || hasInternalMedia) {
        final parsed = await _parseTextAndImages(
          raw,
          // Gemini API 目前无法直接拉取远程 http(s) 图片
          allowRemoteImages: false,
          allowLocalImages: true,
          keepRemoteMarkdownText: true,
        );
        if (parsed.text.isNotEmpty) parts.add({'text': parsed.text});
        for (final ref in parsed.images) {
          final normalized = normalizeSrc(ref.src);
          if (!seenSources.add(normalized)) continue;
          if (ref.kind == 'data') {
            final mime = _mimeFromDataUrl(ref.src);
            final idx = ref.src.indexOf('base64,');
            if (idx > 0) {
              final b64 = ref.src.substring(idx + 7);
              parts.add({
                'inline_data': {'mime_type': mime, 'data': b64},
              });
            } else {
              parts.add({'text': ref.src});
            }
          } else if (ref.kind == 'path') {
            final mime = _mimeFromPath(ref.src);
            final b64 = await _tryEncodeBase64File(ref.src, withPrefix: false);
            if (b64 == null) continue;
            parts.add({
              'inline_data': {'mime_type': mime, 'data': b64},
            });
          } else {
            parts.add({'text': '(image) ${ref.src}'});
          }
        }
        final supplementalRefs = _supplementalMediaRefs(
          internalRaw: msg[multimodalInternalMediaPathsKey],
          userPaths: userImagePaths,
          includeUserPaths: hasAttachedImages,
        );
        if (supplementalRefs.isNotEmpty) {
          for (final mediaRef in supplementalRefs) {
            final p = mediaRef.uri;
            final normalized = normalizeSrc(p);
            if (!seenSources.add(normalized)) continue;
            if (p.startsWith('data:')) {
              final mime = _mimeForInternalMediaRef(mediaRef);
              final idx = p.indexOf('base64,');
              if (idx > 0) {
                final b64 = p.substring(idx + 7);
                parts.add({
                  'inline_data': {'mime_type': mime, 'data': b64},
                });
              }
            } else if (!(p.startsWith('http://') || p.startsWith('https://'))) {
              final mime = _mimeForInternalMediaRef(mediaRef);
              final b64 = await _tryEncodeBase64File(p, withPrefix: false);
              if (b64 == null) continue;
              parts.add({
                'inline_data': {'mime_type': mime, 'data': b64},
              });
            } else {
              parts.add({'text': '(image) $p'});
            }
          }
        }
      } else {
        if (raw.isNotEmpty) parts.add({'text': raw});
      }
      // 将 YouTube URL 作为 file_data 部分摄取（Gemini 官方 API）
      // 仅在本次请求的最后一条 user 消息中注入。
      if (role == 'user' && isLast && enableYoutube) {
        final urls = _extractYouTubeUrls(raw);
        for (final u in urls) {
          // Vertex AI 要求 file_data 提供 mime_type
          if (isVertex) {
            parts.add({
              'file_data': {'file_uri': u, 'mime_type': 'video/*'},
            });
          } else {
            parts.add({
              'file_data': {'file_uri': u},
            });
          }
        }
      }
      if (role == 'model') {
        _applyGeminiThoughtSignatures(
          meta,
          parts,
          attachDummyWhenMissing: persistGeminiThoughtSigs,
        );
      }
      contents.add({'role': role, 'parts': parts});
    }

    // 将 OpenAI 风格的工具映射为 Gemini functionDeclarations（MCP）
    List<Map<String, dynamic>>? geminiTools;
    if (tools != null && tools.isNotEmpty) {
      final decls = <Map<String, dynamic>>[];
      for (final t in tools) {
        final fn = (t['function'] as Map<String, dynamic>?);
        if (fn == null) continue;
        final name = (fn['name'] ?? '').toString();
        if (name.isEmpty) continue;
        final desc = (fn['description'] ?? '').toString();
        final params = (fn['parameters'] as Map?)?.cast<String, dynamic>();
        final d = <String, dynamic>{
          'name': name,
          if (desc.isNotEmpty) 'description': desc,
        };
        if (params != null) d['parameters'] = _cleanSchemaForGemini(params);
        decls.add(d);
      }
      if (decls.isNotEmpty) {
        geminiTools = [
          {'function_declarations': decls},
        ];
      }
    }

    final requestHeaders = <String, String>{'Content-Type': 'application/json'};
    if (isVertex) {
      final token = await GoogleServiceAccountAuth.getAccessTokenFromJson(
        config.serviceAccountJson ?? '',
      );
      requestHeaders['Authorization'] = 'Bearer $token';
      final proj = (config.projectId ?? '').trim();
      if (proj.isNotEmpty) {
        requestHeaders['X-Goog-User-Project'] = proj;
      }
    } else {
      final apiKey = _effectiveApiKey(config);
      if (apiKey.isNotEmpty) {
        requestHeaders['x-goog-api-key'] = apiKey;
      }
    }
    final headers = _customHeaders(
      config,
      modelId,
      baseHeaders: requestHeaders,
      assistantHeaders: extraHeaders,
    );

    final toolsArr = _buildGeminiToolsArray(
      builtIns: builtIns,
      allowCoexistence: isGemini3,
      geminiTools: geminiTools,
    );
    final geminiToolConfig = buildGeminiToolConfig(
      tools: toolsArr,
      isGemini3: isGemini3 && !isVertex,
    );

    final thinkingConfig = isReasoning
        ? _googleThinkingConfig(upstreamModelId, thinkingBudget)
        : const <String, dynamic>{};
    final defaultMaxOutputTokens = _defaultGeminiMaxOutputTokens(
      upstreamModelId,
    );
    final omitSamplingParams = _shouldOmitGeminiSamplingParams(upstreamModelId);
    final generationConfig = <String, dynamic>{
      if (maxTokens ?? defaultMaxOutputTokens case final resolvedMaxTokens?)
        'maxOutputTokens': resolvedMaxTokens,
      if (thinkingConfig.isNotEmpty) 'thinkingConfig': thinkingConfig,
    };

    Map<String, dynamic> baseBody = {
      'contents': contents,
      if (systemPrompt.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
      if (!omitSamplingParams && temperature != null)
        'temperature': temperature,
      if (!omitSamplingParams && topP != null) 'topP': topP,
      if (generationConfig.isNotEmpty) 'generationConfig': generationConfig,
      if (toolsArr.isNotEmpty) 'tools': toolsArr,
      if (geminiToolConfig != null) 'toolConfig': geminiToolConfig,
    };
    final extraG = _customBody(config, modelId, assistantBody: extraBody);
    if (extraG.isNotEmpty) baseBody.addAll(extraG);

    TokenUsage? totalUsage;
    List<Map<String, dynamic>> currentContents =
        List<Map<String, dynamic>>.from(contents);
    while (true) {
      final req = http.Request('POST', Uri.parse(url));
      req.headers.addAll(headers);
      final body = Map<String, dynamic>.from(baseBody);
      body['contents'] = _googleApiContents(currentContents);
      req.body = jsonEncode(body);
      final resp = await client.send(req);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final errorBody = await resp.stream.bytesToString();
        throw HttpException('HTTP ${resp.statusCode}: $errorBody');
      }
      final txt = await resp.stream.bytesToString();
      final obj = jsonDecode(txt) as Map<String, dynamic>;
      try {
        final u = (obj['usageMetadata'] as Map?)?.cast<String, dynamic>();
        if (u != null) {
          final prompt = (u['promptTokenCount'] ?? 0) as int? ?? 0;
          final completion = (u['candidatesTokenCount'] ?? 0) as int? ?? 0;
          totalUsage = (totalUsage ?? const TokenUsage()).merge(
            TokenUsage(
              promptTokens: prompt,
              completionTokens: completion,
              cachedTokens: 0,
            ),
          );
        }
      } catch (_) {}
      final candidates = (obj['candidates'] as List?) ?? const <dynamic>[];
      if (candidates.isEmpty) {
        yield ChatStreamChunk(
          content: '',
          isDone: true,
          totalTokens: totalUsage?.totalTokens ?? 0,
          usage: totalUsage,
        );
        return;
      }
      final cand = (candidates.first as Map).cast<String, dynamic>();
      final parts = (cand['content']?['parts'] as List?) ?? const <dynamic>[];
      final functionCallParts = parts
          .where((e) => e is Map && e.containsKey('functionCall'))
          .toList();
      if (functionCallParts.isNotEmpty && onToolCall != null) {
        final responseParts = <Map<String, dynamic>>[];
        for (int idx = 0; idx < functionCallParts.length; idx++) {
          final fc = functionCallParts[idx] as Map;
          final call = (fc['functionCall'] as Map).cast<String, dynamic>();
          final name = (call['name'] ?? '').toString();
          final args =
              (call['args'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          // 优先使用 API 提供的 functionCall id，否则回退到合成值。
          final partId = _effectiveToolCallId(call['id'], 'fn', idx);
          // 保留原始 part（包括 thoughtSignature），以便工具事件元数据
          // 能在后续请求中精确重放该模型轮次。
          final rawPart = fc.cast<String, dynamic>();
          String? thoughtSigKey;
          dynamic thoughtSigVal;
          if (fc.containsKey('thoughtSignature')) {
            thoughtSigKey = 'thoughtSignature';
            thoughtSigVal = fc['thoughtSignature'];
          } else if (fc.containsKey('thought_signature')) {
            thoughtSigKey = 'thought_signature';
            thoughtSigVal = fc['thought_signature'];
          }
          final googleMetadata = <String, dynamic>{
            'google': {
              'part': rawPart,
              if (thoughtSigKey != null && thoughtSigVal != null)
                'thoughtSigKey': thoughtSigKey,
              if (thoughtSigKey != null && thoughtSigVal != null)
                'thoughtSigVal': thoughtSigVal,
            },
          };
          yield ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: totalUsage?.totalTokens ?? 0,
            usage: totalUsage,
            toolCalls: [
              ToolCallInfo(
                id: partId,
                name: name,
                arguments: args,
                metadata: googleMetadata,
              ),
            ],
          );
          final res = await onToolCall(name, args, toolCallId: partId);
          yield ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: totalUsage?.totalTokens ?? 0,
            usage: totalUsage,
            toolResults: [
              ToolResultInfo(
                id: partId,
                name: name,
                arguments: args,
                content: res,
                metadata: googleMetadata,
              ),
            ],
          );
          final frPart = <String, dynamic>{
            'functionResponse': {
              'name': name,
              'response': {'result': res},
              if (call.containsKey('id')) 'id': call['id'],
            },
          };
          responseParts.add(frPart);
        }
        currentContents = [
          ...currentContents,
          // 传递模型响应中的所有 part（保留服务端工具 part、
          // thought 签名以及其他字段）
          {'role': 'model', 'parts': parts},
          {'role': 'user', 'parts': responseParts},
        ];
        continue;
      }
      // 将服务端代码执行部分作为工具卡片发出。假设 executableCode 和 codeExecutionResult
      // 按 1:1 成对交替出现（与当前 Gemini API 行为一致）。
      int codeExecIdx = 0;
      for (final p in parts) {
        if (p is! Map) continue;
        final ec = p['executableCode'] ?? p['executable_code'];
        if (ec is Map) {
          final lang = (ec['language'] ?? '').toString().toLowerCase();
          final code = (ec['code'] ?? '').toString();
          if (code.isNotEmpty) {
            final ceId = 'code_exec_$codeExecIdx';
            codeExecIdx++;
            yield ChatStreamChunk(
              content: '',
              isDone: false,
              totalTokens: totalUsage?.totalTokens ?? 0,
              usage: totalUsage,
              toolCalls: [
                ToolCallInfo(
                  id: ceId,
                  name: 'code_execution',
                  arguments: {'language': lang, 'code': code},
                ),
              ],
            );
          }
        }
        final cr = p['codeExecutionResult'] ?? p['code_execution_result'];
        if (cr is Map) {
          final outcome = (cr['outcome'] ?? '').toString();
          final output = (cr['output'] ?? '').toString();
          final resultId = codeExecIdx > 0
              ? 'code_exec_${codeExecIdx - 1}'
              : 'code_exec_0';
          yield ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: totalUsage?.totalTokens ?? 0,
            usage: totalUsage,
            toolResults: [
              ToolResultInfo(
                id: resultId,
                name: 'code_execution',
                arguments: const <String, dynamic>{},
                content: output.isEmpty ? outcome : output,
              ),
            ],
          );
        }
      }
      final buf = StringBuffer();
      final reasoningBuf = StringBuffer();
      for (final p in parts) {
        if (p is! Map) continue;
        final text = p['text'];
        if (text is! String || text.isEmpty) continue;
        final thought = p['thought'] as bool? ?? false;
        if (thought) {
          reasoningBuf.write(text);
        } else {
          buf.write(text);
        }
      }
      final reasoningStr = reasoningBuf.toString();
      if (reasoningStr.isNotEmpty) {
        yield ChatStreamChunk(
          content: '',
          reasoning: reasoningStr,
          isDone: false,
          totalTokens: totalUsage?.totalTokens ?? 0,
          usage: totalUsage,
        );
      }
      var contentStr = buf.toString();
      if (persistGeminiThoughtSigs) {
        final metaComment = _collectThoughtSigCommentFromParts(parts);
        if (metaComment.isNotEmpty) contentStr += metaComment;
      }
      yield ChatStreamChunk(
        content: contentStr,
        isDone: true,
        totalTokens: totalUsage?.totalTokens ?? 0,
        usage: totalUsage,
      );
      return;
    }
  }

  // 通过 :streamGenerateContent 并使用 alt=sse 实现 SSE 流式传输
  // 根据 Vertex 与 Gemini 分别构建端点
  String baseUrl;
  if (config.vertexAI == true &&
      (config.location?.isNotEmpty == true) &&
      (config.projectId?.isNotEmpty == true)) {
    final loc = config.location!.trim();
    final proj = config.projectId!.trim();
    baseUrl =
        'https://aiplatform.googleapis.com/v1/projects/$proj/locations/$loc/publishers/google/models/$upstreamModelId:streamGenerateContent';
  } else {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    baseUrl = '$base/models/$upstreamModelId:streamGenerateContent';
  }

  // 使用 alt=sse 构建查询
  final uriBase = Uri.parse(baseUrl);
  final qp = Map<String, String>.from(uriBase.queryParameters);
  qp['alt'] = 'sse';
  final uri = uriBase.replace(queryParameters: qp);
  final isVertex = config.vertexAI == true;

  // 将系统消息提取到 systemInstruction（Google Gemini API 最佳实践）
  String systemPrompt = '';
  final contents = <Map<String, dynamic>>[];
  for (int i = 0; i < messages.length; i++) {
    final msg = messages[i];
    final roleRaw = (msg['role'] ?? 'user').toString();
    if (roleRaw == 'system') {
      final s = (msg['content'] ?? '').toString();
      if (s.isNotEmpty) {
        systemPrompt = systemPrompt.isEmpty ? s : '$systemPrompt\n\n$s';
      }
      continue;
    }
    final role = roleRaw == 'assistant' ? 'model' : 'user';
    if (roleRaw == 'tool') {
      contents.add({
        'role': 'user',
        'parts': [_googleFunctionResponsePartFromToolMessage(msg)],
      });
      continue;
    }
    if (roleRaw == 'assistant' && msg['tool_calls'] is List) {
      final parts = <Map<String, dynamic>>[];
      final raw = _extractGeminiThoughtMeta(
        (msg['content'] ?? '').toString(),
      ).cleanedText;
      if (raw.trim().isNotEmpty && raw.trim() != '\n\n') {
        parts.add({'text': raw});
      }
      for (final tc in msg['tool_calls'] as List) {
        if (tc is! Map) continue;
        final part = _googleFunctionCallPartFromToolCall(tc);
        if (part != null) parts.add(part);
      }
      if (persistGeminiThoughtSigs) _ensureGeminiFunctionCallThoughtSig(parts);
      if (parts.isNotEmpty) contents.add({'role': 'model', 'parts': parts});
      continue;
    }
    final isLast = i == messages.length - 1;
    final parts = <Map<String, dynamic>>[];
    final meta = _extractGeminiThoughtMeta((msg['content'] ?? '').toString());
    final raw = meta.cleanedText;
    final seenSources = <String>{};
    String normalizeSrc(String src) {
      if (src.startsWith('http') || src.startsWith('data:')) return src;
      try {
        return SandboxPathResolver.fix(src);
      } catch (_) {
        return src;
      }
    }

    // 仅在有图像需要处理时解析图像。
    // 仅做语义媒体检测，不识别自定义附件标记。附件通过结构化 media-path 键 /
    // userImagePaths 以及 Markdown ![](...) 到达。
    final hasMarkdownImages = raw.contains('![') && raw.contains('](');
    final internalMediaRefs = parseInternalMediaRefs(
      msg[multimodalInternalMediaPathsKey],
    );
    // 消费为用户与助手历史轮次注入的媒体引用。
    final hasInternalMedia = internalMediaRefs.isNotEmpty;
    final hasAttachedImages =
        isLast && role == 'user' && (userImagePaths?.isNotEmpty == true);

    if (hasMarkdownImages || hasAttachedImages || hasInternalMedia) {
      final parsed = await _parseTextAndImages(
        raw,
        // Gemini API 目前无法直接拉取远程 http(s) 图片
        allowRemoteImages: false,
        allowLocalImages: true,
        keepRemoteMarkdownText: true,
      );
      if (parsed.text.isNotEmpty) parts.add({'text': parsed.text});
      // 从此消息文本中提取的图像
      for (final ref in parsed.images) {
        final normalized = normalizeSrc(ref.src);
        if (!seenSources.add(normalized)) continue;
        if (ref.kind == 'data') {
          final mime = _mimeFromDataUrl(ref.src);
          final idx = ref.src.indexOf('base64,');
          if (idx > 0) {
            final b64 = ref.src.substring(idx + 7);
            parts.add({
              'inline_data': {'mime_type': mime, 'data': b64},
            });
          } else {
            // 如果数据 URL 格式不正确，则作为纯文本回退包含
            parts.add({'text': ref.src});
          }
        } else if (ref.kind == 'path') {
          final mime = _mimeFromPath(ref.src);
          final b64 = await _tryEncodeBase64File(ref.src, withPrefix: false);
          if (b64 == null) continue;
          parts.add({
            'inline_data': {'mime_type': mime, 'data': b64},
          });
        } else {
          // 远程 URL：Gemini 官方 API 不会在此处抓取 http(s)；保留简短引用
          parts.add({'text': '(image) ${ref.src}'});
        }
      }
      final supplementalRefs = _supplementalMediaRefs(
        internalRaw: msg[multimodalInternalMediaPathsKey],
        userPaths: userImagePaths,
        includeUserPaths: hasAttachedImages,
      );
      if (supplementalRefs.isNotEmpty) {
        for (final mediaRef in supplementalRefs) {
          final p = mediaRef.uri;
          final normalized = normalizeSrc(p);
          if (!seenSources.add(normalized)) continue;
          if (p.startsWith('data:')) {
            final mime = _mimeForInternalMediaRef(mediaRef);
            final idx = p.indexOf('base64,');
            if (idx > 0) {
              final b64 = p.substring(idx + 7);
              parts.add({
                'inline_data': {'mime_type': mime, 'data': b64},
              });
            }
          } else if (!(p.startsWith('http://') || p.startsWith('https://'))) {
            final mime = _mimeForInternalMediaRef(mediaRef);
            final b64 = await _tryEncodeBase64File(p, withPrefix: false);
            if (b64 == null) continue;
            parts.add({
              'inline_data': {'mime_type': mime, 'data': b64},
            });
          } else {
            // http url 回退引用文本
            parts.add({'text': '(image) $p'});
          }
        }
      }
    } else {
      // 无图像，使用简单文本内容
      if (raw.isNotEmpty) parts.add({'text': raw});
    }
    // 将 YouTube URL 作为 file_data 部件摄取（Gemini 官方 API），
    // 仅注入到本请求的最后一条用户消息中。
    if (role == 'user' && isLast && enableYoutube) {
      final urls = _extractYouTubeUrls(raw);
      for (final u in urls) {
        // Vertex AI 要求 file_data 提供 mime_type
        if (isVertex) {
          parts.add({
            'file_data': {'file_uri': u, 'mime_type': 'video/*'},
          });
        } else {
          parts.add({
            'file_data': {'file_uri': u},
          });
        }
      }
    }
    if (role == 'model') {
      _applyGeminiThoughtSignatures(
        meta,
        parts,
        attachDummyWhenMissing: persistGeminiThoughtSigs,
      );
    }
    contents.add({'role': role, 'parts': parts});
  }

  final wantsImageOutput = effective.output.contains(Modality.image);
  bool expectImage = wantsImageOutput;
  bool receivedImage = false;

  // 将 OpenAI 风格的工具映射到 Gemini functionDeclarations（MCP）
  List<Map<String, dynamic>>? geminiTools;
  if (tools != null && tools.isNotEmpty) {
    final decls = <Map<String, dynamic>>[];
    for (final t in tools) {
      final fn = (t['function'] as Map<String, dynamic>?);
      if (fn == null) continue;
      final name = (fn['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final desc = (fn['description'] ?? '').toString();
      final params = (fn['parameters'] as Map?)?.cast<String, dynamic>();
      final d = <String, dynamic>{
        'name': name,
        if (desc.isNotEmpty) 'description': desc,
      };
      if (params != null) {
        // Google Gemini 要求严格符合 JSON Schema
        // 修复缺少 'items' 字段的数组属性
        final cleanedParams = _cleanSchemaForGemini(params);
        d['parameters'] = cleanedParams;
      }
      decls.add(d);
    }
    if (decls.isNotEmpty) {
      geminiTools = [
        {'function_declarations': decls},
      ];
    }
  }
  final toolsArr = _buildGeminiToolsArray(
    builtIns: builtIns,
    allowCoexistence: isGemini3,
    geminiTools: geminiTools,
  );
  final geminiToolConfig = buildGeminiToolConfig(
    tools: toolsArr,
    isGemini3: isGemini3 && !isVertex,
  );

  // 为多轮工具调用维护滚动对话
  List<Map<String, dynamic>> convo = List<Map<String, dynamic>>.from(contents);
  TokenUsage? usage;
  int totalTokens = 0;

  // 跨流式轮次累积内置搜索引用
  final List<Map<String, dynamic>> builtinCitations = <Map<String, dynamic>>[];
  int malformedResponseRetryCount = 0;

  List<Map<String, dynamic>> parseCitations(dynamic gm) {
    final out = <Map<String, dynamic>>[];
    if (gm is! Map) return out;
    final chunks = gm['groundingChunks'] as List? ?? const <dynamic>[];
    int idx = 1;
    final seen = <String>{};
    for (final ch in chunks) {
      if (ch is! Map) continue;
      final web =
          ch['web'] as Map? ?? ch['webSite'] as Map? ?? ch['webPage'] as Map?;
      if (web is! Map) continue;
      final uri = (web['uri'] ?? web['url'] ?? '').toString();
      if (uri.isEmpty) continue;
      // 按 uri 去重
      if (seen.contains(uri)) continue;
      seen.add(uri);
      final title = (web['title'] ?? web['name'] ?? uri).toString();
      final id = 'c${idx.toString().padLeft(2, '0')}';
      out.add({'id': id, 'index': idx, 'title': title, 'url': uri});
      idx++;
    }
    return out;
  }

  while (true) {
    final defaultMaxOutputTokens = _defaultGeminiMaxOutputTokens(
      upstreamModelId,
    );
    final omitSamplingParams = _shouldOmitGeminiSamplingParams(upstreamModelId);
    final gen = <String, dynamic>{
      if (!omitSamplingParams && temperature != null)
        'temperature': temperature,
      if (!omitSamplingParams && topP != null) 'topP': topP,
      if (maxTokens ?? defaultMaxOutputTokens case final resolvedMaxTokens?)
        'maxOutputTokens': resolvedMaxTokens,
      // 当模型配置为输出图像时启用 IMAGE+TEXT 输出模态
      if (wantsImageOutput) 'responseModalities': ['TEXT', 'IMAGE'],
      if (isReasoning)
        ...() {
          final thinkingConfig = _googleThinkingConfig(
            upstreamModelId,
            thinkingBudget,
          );
          if (thinkingConfig.isEmpty) return const <String, dynamic>{};
          return {'thinkingConfig': thinkingConfig};
        }(),
    };
    final body = <String, dynamic>{
      'contents': convo,
      if (systemPrompt.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
      if (gen.isNotEmpty) 'generationConfig': gen,
      if (toolsArr.isNotEmpty) 'tools': toolsArr,
      if (geminiToolConfig != null) 'toolConfig': geminiToolConfig,
    };

    final request = http.Request('POST', uri);
    final requestHeaders = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    };
    if (config.vertexAI == true) {
      final token = await _maybeVertexAccessToken(config);
      if (token != null && token.isNotEmpty) {
        requestHeaders['Authorization'] = 'Bearer $token';
      }
      final proj = (config.projectId ?? '').trim();
      if (proj.isNotEmpty) requestHeaders['X-Goog-User-Project'] = proj;
    } else {
      final apiKey = _effectiveApiKey(config);
      if (apiKey.isNotEmpty) {
        requestHeaders['x-goog-api-key'] = apiKey;
      }
    }
    final headers = _customHeaders(
      config,
      modelId,
      baseHeaders: requestHeaders,
      assistantHeaders: extraHeaders,
    );
    request.headers.addAll(headers);
    final extra = _customBody(config, modelId, assistantBody: extraBody);
    if (extra.isNotEmpty) {
      body.addAll(extra);
    }
    body['contents'] = _googleApiContents(convo);
    request.body = jsonEncode(body);

    final resp = await client.send(request);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final errorBody = await resp.stream.bytesToString();
      throw HttpException('HTTP ${resp.statusCode}: $errorBody');
    }

    final sse = resp.stream.transform(utf8.decoder);
    String buffer = '';
    // 收集本轮中的任何函数调用
    final List<Map<String, dynamic>> calls =
        <Map<String, dynamic>>[]; // {id,name,args,res}
    // 按接收到的原始顺序保留模型轮次部件。
    final List<Map<String, dynamic>> roundModelParts = <Map<String, dynamic>>[];
    // 用于服务端代码执行工具卡片的计数器
    int codeExecCounter = 0;
    bool retryMalformedResponse = false;

    // 捕获思考签名用于历史记录（Gemini 3 图像/编辑）
    String? responseTextThoughtSigKey;
    dynamic responseTextThoughtSigVal;
    final List<Map<String, dynamic>> responseImageThoughtSigs =
        <Map<String, dynamic>>[];

    // 跟踪流式内联图像；缓冲分块，完成后仅发出最新帧
    String imageMime = 'image/png';
    String pendingImageData = '';
    String pendingImageTrailingText = '';
    bool bufferingInlineImage = false;

    bool looksLikeImageStart(String data) {
      const prefixes = <String>[
        '/9j/', // jpeg
        'iVBOR', // png
        'R0lGOD', // gif
        'UklGR', // webp
        'Qk', // bmp variants
        'SUkq', // tiff
      ];
      for (final p in prefixes) {
        if (data.startsWith(p)) return true;
      }
      return false;
    }

    Future<String> sanitizeTextIfNeeded(String input) async {
      if (input.isEmpty) return input;
      if (input.contains('data:image') && input.contains('base64,')) {
        try {
          return await MarkdownMediaSanitizer.replaceInlineBase64Images(input);
        } catch (_) {
          return input;
        }
      }
      return input;
    }

    void bufferInlineImageChunk(String mime, String data) {
      imageMime = mime.isNotEmpty ? mime : 'image/png';
      final hasExisting = pendingImageData.isNotEmpty;
      // Gemini 图像预览流通常发送完整预览帧而非增量。
      // 如果上一个分块已看似完整（含 padding）或出现新帧头，则替换它。
      final prevLooksComplete = hasExisting && pendingImageData.endsWith('=');
      final newFrame = hasExisting && looksLikeImageStart(data);
      if (prevLooksComplete || newFrame) {
        pendingImageData = data;
      } else {
        pendingImageData += data;
      }
      bufferingInlineImage = true;
      receivedImage = true;
    }

    Future<String> takeBufferedImageMarkdown() async {
      if (!bufferingInlineImage || pendingImageData.isEmpty) return '';
      final trailing = pendingImageTrailingText;
      final path = await AppDirectories.saveBase64Image(
        imageMime,
        pendingImageData,
      );
      bufferingInlineImage = false;
      pendingImageData = '';
      pendingImageTrailingText = '';
      if (path == null || path.isEmpty) return '';
      final uri = SandboxPathResolver.canonicalize(path);
      final sb = StringBuffer()
        ..write('\n\n![image](')
        ..write(uri)
        ..write(')');
      if (trailing.isNotEmpty) {
        sb.write(trailing);
      }
      return sb.toString();
    }

    await for (final chunk in _ensureTrailingNewline(sse)) {
      buffer += chunk;
      final lines = buffer.split('\n');
      buffer = lines.last; // 保留不完整的行

      for (int i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim(); // 位于 'data:' 之后
        if (data.isEmpty) continue;
        // Gemini 可能会在 2xx 流中以带内方式返回 {"error":{code,message,status}}、提示级
        // 阻止，或候选级内容过滤完成信号；应在下方畸形分块保护
        // 可能吞掉它之前抛出。
        _throwIfInBandStreamError(data);
        _throwIfGeminiPromptBlocked(data);
        _throwIfGeminiCandidateBlocked(data);
        try {
          final obj = jsonDecode(data) as Map<String, dynamic>;
          final um = obj['usageMetadata'];
          if (um is Map<String, dynamic>) {
            usage = (usage ?? const TokenUsage()).merge(
              TokenUsage(
                promptTokens: (um['promptTokenCount'] ?? 0) as int,
                completionTokens: (um['candidatesTokenCount'] ?? 0) as int,
                totalTokens: (um['totalTokenCount'] ?? 0) as int,
              ),
            );
            totalTokens = usage.totalTokens;
          }

          final candidates = obj['candidates'];
          if (candidates is List && candidates.isNotEmpty) {
            String textDelta = '';
            String reasoningDelta = '';
            String? finishReason; // 检测来自服务器的流完成
            for (final cand in candidates) {
              if (cand is! Map) continue;
              final content = cand['content'];
              if (content is! Map) continue;
              final parts = content['parts'];
              if (parts is! List) continue;
              for (final p in parts) {
                if (p is! Map) continue;
                String? partThoughtSigKey;
                dynamic partThoughtSigVal;
                if (p.containsKey('thoughtSignature')) {
                  partThoughtSigKey = 'thoughtSignature';
                  partThoughtSigVal = p['thoughtSignature'];
                } else if (p.containsKey('thought_signature')) {
                  partThoughtSigKey = 'thought_signature';
                  partThoughtSigVal = p['thought_signature'];
                }
                final t = (p['text'] ?? '') as String? ?? '';
                final thought = p['thought'] as bool? ?? false;
                final fc = p['functionCall'];
                final rawPart = Map<String, dynamic>.from(p);

                if (isGemini3 && !thought && rawPart.isNotEmpty) {
                  roundModelParts.add(rawPart);
                }

                // 为文本部件捕获思考签名（Gemini 3 图像/编辑）
                if (persistGeminiThoughtSigs &&
                    !thought &&
                    partThoughtSigKey != null &&
                    partThoughtSigVal != null) {
                  if (t.isNotEmpty && responseTextThoughtSigKey == null) {
                    responseTextThoughtSigKey = partThoughtSigKey;
                    responseTextThoughtSigVal = partThoughtSigVal;
                  }
                }

                if (t.isNotEmpty) {
                  if (thought) {
                    reasoningDelta += t;
                  } else if (bufferingInlineImage) {
                    pendingImageTrailingText += t;
                  } else {
                    textDelta += t;
                  }
                }
                // 解析来自 Gemini 的内联图像数据（inlineData），
                // 响应形状：{ inlineData: { mimeType: 'image/png', data: '...base64...' } }
                final inline = (p['inlineData'] ?? p['inline_data']);
                if (inline is Map) {
                  final mime =
                      (inline['mimeType'] ?? inline['mime_type'] ?? 'image/png')
                          .toString();
                  final data = (inline['data'] ?? '').toString();
                  if (data.isNotEmpty) {
                    if (persistGeminiThoughtSigs &&
                        partThoughtSigKey != null &&
                        partThoughtSigVal != null) {
                      final exists = responseImageThoughtSigs.any(
                        (e) =>
                            e['k'] == partThoughtSigKey &&
                            e['v'] == partThoughtSigVal,
                      );
                      if (!exists) {
                        responseImageThoughtSigs.add({
                          'k': partThoughtSigKey,
                          'v': partThoughtSigVal,
                        });
                      }
                    }
                    bufferInlineImageChunk(mime, data);
                  }
                }
                // 解析 fileData：{ fileUri: 'https://...', mimeType: 'image/png' }
                final fileData = (p['fileData'] ?? p['file_data']);
                if (fileData is Map) {
                  final mime =
                      (fileData['mimeType'] ??
                              fileData['mime_type'] ??
                              'image/png')
                          .toString();
                  final uri =
                      (fileData['fileUri'] ??
                              fileData['file_uri'] ??
                              fileData['uri'] ??
                              '')
                          .toString();
                  if (uri.startsWith('http')) {
                    try {
                      final b64 = await _downloadRemoteAsBase64(
                        client,
                        config,
                        uri,
                      );
                      if (persistGeminiThoughtSigs &&
                          partThoughtSigKey != null &&
                          partThoughtSigVal != null) {
                        final exists = responseImageThoughtSigs.any(
                          (e) =>
                              e['k'] == partThoughtSigKey &&
                              e['v'] == partThoughtSigVal,
                        );
                        if (!exists) {
                          responseImageThoughtSigs.add({
                            'k': partThoughtSigKey,
                            'v': partThoughtSigVal,
                          });
                        }
                      }
                      bufferInlineImageChunk(mime, b64);
                    } catch (_) {}
                  }
                }
                // 将服务端代码执行部分作为工具卡片发出。假设 executableCode 和
                // codeExecutionResult 按 1:1 成对交替出现（与当前 Gemini API 行为一致）。
                final codeExec = p['executableCode'] ?? p['executable_code'];
                if (codeExec is Map) {
                  final lang = (codeExec['language'] ?? '')
                      .toString()
                      .toLowerCase();
                  final code = (codeExec['code'] ?? '').toString();
                  if (code.isNotEmpty) {
                    final ceId = 'code_exec_$codeExecCounter';
                    codeExecCounter++;
                    yield ChatStreamChunk(
                      content: '',
                      isDone: false,
                      totalTokens: totalTokens,
                      usage: usage,
                      toolCalls: [
                        ToolCallInfo(
                          id: ceId,
                          name: 'code_execution',
                          arguments: {'language': lang, 'code': code},
                        ),
                      ],
                    );
                  }
                }
                final codeResult =
                    p['codeExecutionResult'] ?? p['code_execution_result'];
                if (codeResult is Map) {
                  final outcome = (codeResult['outcome'] ?? '').toString();
                  final output = (codeResult['output'] ?? '').toString();
                  final resultId = codeExecCounter > 0
                      ? 'code_exec_${codeExecCounter - 1}'
                      : 'code_exec_0';
                  yield ChatStreamChunk(
                    content: '',
                    isDone: false,
                    totalTokens: totalTokens,
                    usage: usage,
                    toolResults: [
                      ToolResultInfo(
                        id: resultId,
                        name: 'code_execution',
                        arguments: const <String, dynamic>{},
                        content: output.isEmpty ? outcome : output,
                      ),
                    ],
                  );
                }
                if (fc is Map) {
                  final name = (fc['name'] ?? '').toString();
                  Map<String, dynamic> args = const <String, dynamic>{};
                  final rawArgs = fc['args'];
                  if (rawArgs is Map) {
                    args = rawArgs.cast<String, dynamic>();
                  } else if (rawArgs is String && rawArgs.isNotEmpty) {
                    try {
                      args = (jsonDecode(rawArgs) as Map)
                          .cast<String, dynamic>();
                    } catch (_) {}
                  }
                  // 优先使用 API 提供的 functionCall id，否则回退到合成值
                  final apiId = fc['id']?.toString();
                  final id = _effectiveToolCallId(apiId, 'call', p.hashCode);

                  // 捕获思考签名（Gemini 3 Pro 要求）
                  // 按收到的内容原样保留 key/value
                  String? thoughtSigKey;
                  dynamic thoughtSigVal;
                  if (p.containsKey('thoughtSignature')) {
                    thoughtSigKey = 'thoughtSignature';
                    thoughtSigVal = p['thoughtSignature'];
                  } else if (p.containsKey('thought_signature')) {
                    thoughtSigKey = 'thought_signature';
                    thoughtSigVal = p['thought_signature'];
                  }

                  // 立即输出占位符
                  yield ChatStreamChunk(
                    content: '',
                    isDone: false,
                    totalTokens: totalTokens,
                    usage: usage,
                    toolCalls: [
                      ToolCallInfo(
                        id: id,
                        name: name,
                        arguments: args,
                        metadata: {
                          'google': {
                            'part': rawPart,
                            if (thoughtSigKey != null && thoughtSigVal != null)
                              'thoughtSigKey': thoughtSigKey,
                            if (thoughtSigKey != null && thoughtSigVal != null)
                              'thoughtSigVal': thoughtSigVal,
                          },
                        },
                      ),
                    ],
                  );
                  String resText = '';
                  if (onToolCall != null) {
                    resText = await onToolCall(name, args, toolCallId: id);
                    yield ChatStreamChunk(
                      content: '',
                      isDone: false,
                      totalTokens: totalTokens,
                      usage: usage,
                      toolResults: [
                        ToolResultInfo(
                          id: id,
                          name: name,
                          arguments: args,
                          content: resText,
                          metadata: {
                            'google': {
                              'part': rawPart,
                              if (thoughtSigKey != null &&
                                  thoughtSigVal != null)
                                'thoughtSigKey': thoughtSigKey,
                              if (thoughtSigKey != null &&
                                  thoughtSigVal != null)
                                'thoughtSigVal': thoughtSigVal,
                            },
                          },
                        ),
                      ],
                    );
                  }
                  final call = <String, dynamic>{
                    'id': id,
                    'apiId': apiId,
                    'name': name,
                    'args': args,
                    'result': resText,
                    'thoughtSigKey': thoughtSigKey,
                    'thoughtSigVal': thoughtSigVal,
                    'part': rawPart,
                  };
                  calls.add(call);
                }
              }
              // 如果存在，则捕获明确的结束原因
              final fr = cand['finishReason'];
              if (fr is String && fr.isNotEmpty) finishReason = fr;

              // 如果存在，则解析用于引用的 grounding 元数据
              final gm = cand['groundingMetadata'] ?? obj['groundingMetadata'];
              final cite = parseCitations(gm);
              if (cite.isNotEmpty) {
                // 按 url 去重合并
                final existingUrls = builtinCitations
                    .map((e) => e['url']?.toString() ?? '')
                    .toSet();
                for (final it in cite) {
                  final u = it['url']?.toString() ?? '';
                  if (u.isEmpty || existingUrls.contains(u)) continue;
                  builtinCitations.add(it);
                  existingUrls.add(u);
                }
                // 输出工具结果分块，以便 UI 渲染引用卡片
                final payload = jsonEncode({'items': builtinCitations});
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: totalTokens,
                  usage: usage,
                  toolResults: [
                    ToolResultInfo(
                      id: 'builtin_search',
                      name: 'builtin_search',
                      arguments: const <String, dynamic>{},
                      content: payload,
                    ),
                  ],
                );
              }
            }

            if (finishReason == 'MALFORMED_RESPONSE' && calls.isEmpty) {
              retryMalformedResponse = true;
            }

            // 结束时一次性发出所有缓冲的内联图像（以及尾部文本），
            // 避免流式传输过程中出现不完整的 base64。
            if (finishReason != null && !retryMalformedResponse) {
              final pendingImage = await takeBufferedImageMarkdown();
              if (pendingImage.isNotEmpty) {
                textDelta += pendingImage;
              }
            }

            if (reasoningDelta.isNotEmpty) {
              yield ChatStreamChunk(
                content: '',
                reasoning: reasoningDelta,
                isDone: false,
                totalTokens: totalTokens,
                usage: usage,
              );
            }
            if (textDelta.isNotEmpty) {
              textDelta = await sanitizeTextIfNeeded(textDelta);
              yield ChatStreamChunk(
                content: textDelta,
                isDone: false,
                totalTokens: totalTokens,
                usage: usage,
              );
            }

            // 如果服务端已发出结束信号，则立即结束流
            if (finishReason != null &&
                !retryMalformedResponse &&
                calls.isEmpty &&
                (!expectImage || receivedImage)) {
              // 如果还有未输出的最终引用，则输出它们
              if (builtinCitations.isNotEmpty) {
                final payload = jsonEncode({'items': builtinCitations});
                yield ChatStreamChunk(
                  content: '',
                  isDone: false,
                  totalTokens: totalTokens,
                  usage: usage,
                  toolResults: [
                    ToolResultInfo(
                      id: 'builtin_search',
                      name: 'builtin_search',
                      arguments: const <String, dynamic>{},
                      content: payload,
                    ),
                  ],
                );
              }
              if (persistGeminiThoughtSigs) {
                final metaComment = _buildGeminiThoughtSigComment(
                  textKey: responseTextThoughtSigKey,
                  textValue: responseTextThoughtSigVal,
                  imageSigs: responseImageThoughtSigs,
                );
                if (metaComment.isNotEmpty) {
                  yield ChatStreamChunk(
                    content: metaComment,
                    isDone: false,
                    totalTokens: totalTokens,
                    usage: usage,
                  );
                }
              }
              yield ChatStreamChunk(
                content: '',
                isDone: true,
                totalTokens: totalTokens,
                usage: usage,
              );
              return;
            }
          }
        } catch (_) {
          // 忽略格式错误的分块
        }
      }
    }

    if (retryMalformedResponse) {
      // 这是短暂的模型生成失败，因此原样重试该轮一次，
      // 不将格式错误的候选内容加入对话。
      if (malformedResponseRetryCount == 0) {
        malformedResponseRetryCount++;
        continue;
      }
      throw const HttpException(
        'Gemini response generation failed (MALFORMED_RESPONSE)',
      );
    }

    // 刷新任何缓冲的内联图片（例如，当流在没有明确 finishReason 的情况下结束时）
    final pendingImage = await takeBufferedImageMarkdown();
    if (pendingImage.isNotEmpty) {
      final sanitized = await sanitizeTextIfNeeded(pendingImage);
      yield ChatStreamChunk(
        content: sanitized,
        isDone: false,
        totalTokens: totalTokens,
        usage: usage,
      );
    }

    if (calls.isEmpty) {
      // 没有工具调用；本轮已完成
      if (persistGeminiThoughtSigs) {
        final metaComment = _buildGeminiThoughtSigComment(
          textKey: responseTextThoughtSigKey,
          textValue: responseTextThoughtSigVal,
          imageSigs: responseImageThoughtSigs,
        );
        if (metaComment.isNotEmpty) {
          yield ChatStreamChunk(
            content: metaComment,
            isDone: false,
            totalTokens: totalTokens,
            usage: usage,
          );
        }
      }
      yield ChatStreamChunk(
        content: '',
        isDone: true,
        totalTokens: totalTokens,
        usage: usage,
      );
      return;
    }

    // 将模型的 functionCall(s) 和用户的 functionResponse(s) 追加到对话中，然后循环
    malformedResponseRetryCount = 0;
    if (isGemini3) {
      // Gemini 3：精确保留原始模型 parts 的顺序。
      convo.add({'role': 'model', 'parts': roundModelParts});

      // 4. 所有 functionResponses 放在一个用户轮次中
      final responseParts = <Map<String, dynamic>>[];
      for (final c in calls) {
        final name = (c['name'] ?? '').toString();
        final resText = (c['result'] ?? '').toString();
        final apiId = c['apiId'] as String?;
        Map<String, dynamic> responseObj;
        try {
          responseObj = (jsonDecode(resText) as Map).cast<String, dynamic>();
        } catch (_) {
          responseObj = {'result': resText};
        }
        responseParts.add({
          'functionResponse': {
            'name': name,
            'response': responseObj,
            if (apiId != null) 'id': apiId,
          },
        });
      }
      convo.add({'role': 'user', 'parts': responseParts});
    } else {
      // Gemini 2.x：现有的逐调用重建
      for (final c in calls) {
        final name = (c['name'] ?? '').toString();
        final args =
            (c['args'] as Map<String, dynamic>? ?? const <String, dynamic>{});
        final resText = (c['result'] ?? '').toString();
        final thoughtSigKey = c['thoughtSigKey'] as String?;
        final thoughtSigVal = c['thoughtSigVal'];

        final part = <String, dynamic>{
          'functionCall': {'name': name, 'args': args},
        };
        if (thoughtSigKey != null && thoughtSigVal != null) {
          part[thoughtSigKey] = thoughtSigVal;
        }

        convo.add({
          'role': 'model',
          'parts': [part],
        });
        Map<String, dynamic> responseObj;
        try {
          responseObj = (jsonDecode(resText) as Map).cast<String, dynamic>();
        } catch (_) {
          responseObj = {'result': resText};
        }
        convo.add({
          'role': 'user',
          'parts': [
            {
              'functionResponse': {'name': name, 'response': responseObj},
            },
          ],
        });
      }
    }
    // 继续 while(true) 以进行下一轮
  }
}
