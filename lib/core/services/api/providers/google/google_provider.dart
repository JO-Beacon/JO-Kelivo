import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../models/token_usage.dart';
import '../../../../providers/model_provider.dart';
import '../../../../providers/settings_provider.dart';
import '../../../../utils/multimodal_input_utils.dart';
import '../../../../../utils/app_directories.dart';
import '../../../../../utils/markdown_media_sanitizer.dart';
import '../../../../../utils/sandbox_path_resolver.dart';
import '../../builtin_tools.dart';
import '../../chat_api_helpers.dart';
import '../../gemini_tool_config.dart';
import '../../generation/tool_loop_runner.dart';
import '../../google_service_account_auth.dart';
import '../../stream/sse_framing.dart';
import '../../stream/stream_chunk.dart';
import '../../stream/stream_chunk_emit.dart';
import '../../stream/stream_chunk_ids.dart';
import 'google_decoder.dart';

/// 构建 Gemini 工具数组，处理 Gemini 3 共存规则与 2.x 互斥规则。
///
/// Gemini 3 允许内置工具与 function_declarations（MCP）共存；Gemini 2.x 及更早版本中
/// code_execution 互斥，search/url_context 不能与 MCP 同时使用。
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

// 非文本 Gemini 变体不使用文本模型系列的思考协议，因此不能进入 pro/flash 分支。
// 在这里提前排除也能避免下面模型族正则的 `-` 终止符吞掉后缀。
final _gemini3NonTextSuffix = RegExp(
  r'(^|[-_/])(image|tts|live)([-._:@/]|$)',
  caseSensitive: false,
);

// Gemini 3.x Flash Image 和 Flash-Lite Image 支持思考等级，但只有 minimal（默认）和 high。
// 其他图片模型（包括旧版 gemini-3-pro-image）继续使用原始预算分支。
final _gemini3FlashImageId = RegExp(
  r'gemini-3(?:\.\d+)?-flash(-lite)?-image([._:@/-]|$)',
  caseSensitive: false,
);

// Gemini 3 模型族思考协议变化的版本阈值，集中命名便于后续版本调整。
const _gemini3ProMediumMinor = 1; // pro 在 3.1 增加 medium
const _gemini3FlashModernMinor = 5; // flash 从 3.5 起默认 medium，预算上限为 64K
const _gemini3FlashNoMinimalMinor = 7; // flash 在 3.7 移除 minimal

// 设置面板提供的预算档位：1024（轻量）、16000（中等）、32000（重度）。
const _gemini3LowBudgetCeiling = 8000;
const _gemini3MediumBudgetCeiling = 24000;

final _gemini3FlashId = RegExp(
  r'gemini-3(?:\.(?<minor>\d+))?-flash([._:@/-]|$)',
  caseSensitive: false,
);
final _gemini3ProId = RegExp(
  r'gemini-3(?:\.(?<minor>\d+))?-pro(-preview)?([._:@/-]|$)',
  caseSensitive: false,
);
final _gemini3FlashLiteId = RegExp(
  r'gemini-3(?:\.\d+)?-flash-lite([._:@/-]|$)',
  caseSensitive: false,
);

// 获取 Gemini 3 id 后的次版本号；普通 `gemini-3-` 为 0，其他模型返回 null。
// 按版本匹配可让未发布的 3.x 模型继续走 Gemini 3 分支，而不是回退到 Gemini 2.x。
int? _gemini3Minor(String modelId, RegExp family) {
  if (_gemini3NonTextSuffix.hasMatch(modelId)) return null;
  final match = family.firstMatch(modelId);
  if (match == null) return null;
  return int.tryParse(match.namedGroup('minor') ?? '0') ?? 0;
}

int? _gemini3FlashMinor(String modelId) =>
    _gemini3Minor(modelId, _gemini3FlashId);

int? _gemini3ProMinor(String modelId) => _gemini3Minor(modelId, _gemini3ProId);

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
  final off = isOff(budget);
  if (_isGemma4Model(upstreamModelId)) {
    if (off) return const <String, dynamic>{};
    return const <String, dynamic>{
      'includeThoughts': true,
      'thinkingLevel': 'high',
    };
  }

  if (_gemini3FlashImageId.hasMatch(upstreamModelId)) {
    // 这里只有 minimal 和 high；轻量档位与 off 共用 minimal 下限。
    // minimal 仍会思考，因此 off 只隐藏思考内容。
    final level = !off && budget != null && budget >= _gemini3LowBudgetCeiling
        ? 'high'
        : 'minimal';
    return {'includeThoughts': !off, 'thinkingLevel': level};
  }

  final proMinor = _gemini3ProMinor(upstreamModelId);
  if (proMinor != null) {
    // gemini-3-pro 只有 low 和 high，3.1 才增加 medium。
    final hasMedium = proMinor >= _gemini3ProMediumMinor;
    String level = 'high';
    if (off) {
      level = 'low';
    } else if (budget != null && budget > 0) {
      if (budget < _gemini3LowBudgetCeiling) {
        level = 'low';
      } else if (budget < _gemini3MediumBudgetCeiling && hasMedium) {
        level = 'medium';
      }
    }
    // Gemini 3 始终思考，因此 off 表示使用最低等级但隐藏思考内容。
    return {'includeThoughts': !off, 'thinkingLevel': level};
  }

  final flashMinor = _gemini3FlashMinor(upstreamModelId);
  if (flashMinor != null) {
    // Flash 在 3.7 移除 minimal，因此最低等级改为 low。
    final lowest = flashMinor >= _gemini3FlashNoMinimalMinor
        ? 'low'
        : 'minimal';
    String level = _gemini3FlashLiteId.hasMatch(upstreamModelId)
        ? lowest
        : (flashMinor >= _gemini3FlashModernMinor ? 'medium' : 'high');
    if (off) {
      level = lowest;
    } else if (budget != null && budget > 0) {
      // 轻量（1024）-> low，中等（16000）-> medium，重度（32000）-> high。
      if (budget < _gemini3LowBudgetCeiling) {
        level = 'low';
      } else if (budget < _gemini3MediumBudgetCeiling) {
        level = 'medium';
      } else {
        level = 'high';
      }
    }
    return {'includeThoughts': !off, 'thinkingLevel': level};
  }
  // Gemini 2.x 及更早版本使用 thinkingBudget。
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
        // 使用可变副本，调用方可能需要补写思考签名。
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

/// Gemini 3 会校验重放模型回合的首个 functionCall 分片必须携带思考签名；缺失时整个请求失败。
/// 对没有持久化原始签名的旧历史或非流式响应，使用文档规定的占位签名保持兼容。
void _ensureGeminiFunctionCallThoughtSig(List<Map<String, dynamic>> parts) {
  for (final part in parts) {
    if (part['functionCall'] is! Map) continue;
    final hasSig =
        part.containsKey('thoughtSignature') ||
        part.containsKey('thought_signature');
    if (!hasSig) {
      part['thoughtSignature'] = geminiDummyThoughtSignature;
    }
    return; // 只校验第一个 functionCall 分片。
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
  final flashMinor = _gemini3FlashMinor(upstreamModelId);
  if (flashMinor != null && flashMinor >= _gemini3FlashModernMinor) {
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
  return apiModelId(config, modelId).toLowerCase().contains('gemini');
}

/// Gemini 会在没有 candidates 的帧中通过 `promptFeedback.blockReason` 报告提示级拦截。
/// 将其作为流错误抛出，而不是当作空的正常完成。
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

/// 输出内容过滤会以这些 `finishReason` 值结束候选并关闭流；否则生成中途拦截会看起来像短回复。
const Set<String> _geminiBlockedFinishReasons = {
  'SAFETY',
  'RECITATION',
  'BLOCKLIST',
  'PROHIBITED_CONTENT',
  'SPII',
  'IMAGE_SAFETY',
};

/// 将候选级内容过滤（例如 `finishReason: SAFETY`）作为流错误抛出，避免截断输出被正常持久化。
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

Stream<StreamChunk> sendGoogleStreamEvents(
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
  bool skipImageParsing = false,
}) async* {
  final upstreamModelId = apiModelId(config, modelId);
  final bool isGemini3 = upstreamModelId.toLowerCase().contains('gemini-3');
  final bool persistGeminiThoughtSigs = isGemini3;
  final builtIns = builtInTools(config, modelId);
  final enableYoutube = builtIns.contains(BuiltInToolNames.youtube);
  // 解析模型有效能力（包含模型覆盖配置）。
  final effective = effectiveModelInfo(config, modelId);
  final isReasoning = _shouldRequestGoogleThoughts(config, modelId, effective);
  // 非流式路径使用 generateContent。
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

    // 将系统消息提取到 systemInstruction（Google Gemini API 推荐格式）。
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
        final raw = extractGeminiThoughtMeta(
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
      final meta = extractGeminiThoughtMeta((msg['content'] ?? '').toString());
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

      // 只做语义媒体检测，不识别自定义附件标记；附件来自结构化媒体路径、userImagePaths 或 Markdown 图片。
      final hasMarkdownImages = shouldParseMarkdownImages(
        raw,
        skipImageParsing: skipImageParsing,
      );
      final internalMediaRefs = parseInternalMediaRefs(
        msg[multimodalInternalMediaPathsKey],
      );
      // 消费用户与 assistant 历史消息中注入的媒体引用。
      final hasInternalMedia = internalMediaRefs.isNotEmpty;
      final hasAttachedImages =
          isLast && role == 'user' && (userImagePaths?.isNotEmpty == true);
      if (hasMarkdownImages || hasAttachedImages || hasInternalMedia) {
        final parsed = await parseTextAndImages(
          raw,
          // Gemini API 目前无法直接拉取远程 http(s) 图片。
          allowRemoteImages: false,
          allowLocalImages: true,
          keepRemoteMarkdownText: true,
        );
        if (parsed.text.isNotEmpty) parts.add({'text': parsed.text});
        for (final ref in parsed.images) {
          final normalized = normalizeSrc(ref.src);
          if (!seenSources.add(normalized)) continue;
          if (ref.kind == 'data') {
            final mime = mimeFromDataUrl(ref.src);
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
            final mime = mimeFromPath(ref.src);
            final b64 = await tryEncodeBase64File(ref.src, withPrefix: false);
            if (b64 == null) continue;
            parts.add({
              'inline_data': {'mime_type': mime, 'data': b64},
            });
          } else {
            parts.add({'text': '(image) ${ref.src}'});
          }
        }
        final supplementalRefs = supplementalMediaRefs(
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
              final mime = mimeForInternalMediaRef(mediaRef);
              final idx = p.indexOf('base64,');
              if (idx > 0) {
                final b64 = p.substring(idx + 7);
                parts.add({
                  'inline_data': {'mime_type': mime, 'data': b64},
                });
              }
            } else if (!(p.startsWith('http://') || p.startsWith('https://'))) {
              final mime = mimeForInternalMediaRef(mediaRef);
              final b64 = await tryEncodeBase64File(p, withPrefix: false);
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
      // 按 Gemini 官方 API 格式将 YouTube URL 注入为 file_data，仅处理本次请求最后一条用户消息。
      if (role == 'user' && isLast && enableYoutube) {
        final urls = extractYouTubeUrls(raw);
        for (final u in urls) {
          // Vertex AI 的 file_data 需要 mime_type。
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
        applyGeminiThoughtSignatures(
          meta,
          parts,
          attachDummyWhenMissing: persistGeminiThoughtSigs,
        );
      }
      contents.add({'role': role, 'parts': parts});
    }

    // 将 OpenAI 风格工具映射为 Gemini functionDeclarations（MCP）。
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
          d['parameters'] = cleanSchemaForGemini(params, stringEnumOnly: true);
        }
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
      final apiKey = effectiveApiKey(config);
      if (apiKey.isNotEmpty) {
        requestHeaders['x-goog-api-key'] = apiKey;
      }
    }
    final headers = customHeaders(
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
    final extraG = customBody(config, modelId, assistantBody: extraBody);
    if (extraG.isNotEmpty) baseBody.addAll(extraG);

    TokenUsage? totalUsage;
    List<Map<String, dynamic>> currentContents =
        List<Map<String, dynamic>>.from(contents);
    var pendingCalls = <EmitToolCall>[];
    var lastParts = <dynamic>[];
    var lastFunctionCallParts = <dynamic>[];
    var lastText = '';

    yield* runProviderToolRounds(
      sendRound: () async* {
        pendingCalls = [];
        lastParts = [];
        lastFunctionCallParts = [];
        lastText = '';
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
        final txt = await decodeUtf8Stream(resp.stream);
        final obj = jsonDecode(txt) as Map<String, dynamic>;
        try {
          final u = (obj['usageMetadata'] as Map?)?.cast<String, dynamic>();
          if (u != null) {
            final prompt = (u['promptTokenCount'] ?? 0) as int? ?? 0;
            final completion = (u['candidatesTokenCount'] ?? 0) as int? ?? 0;
            totalUsage = (totalUsage ?? const TokenUsage()).accumulate(
              TokenUsage(
                promptTokens: prompt,
                completionTokens: completion,
                cachedTokens: 0,
              ),
            );
          }
        } catch (_) {}
        final candidates = (obj['candidates'] as List?) ?? const <dynamic>[];
        if (candidates.isEmpty) return;
        final cand = (candidates.first as Map).cast<String, dynamic>();
        final parts = (cand['content']?['parts'] as List?) ?? const <dynamic>[];
        final functionCallParts = parts
            .where((e) => e is Map && e.containsKey('functionCall'))
            .toList();
        lastParts = parts;
        lastFunctionCallParts = functionCallParts;
        if (functionCallParts.isNotEmpty && onToolCall != null) {
          pendingCalls = [
            for (var idx = 0; idx < functionCallParts.length; idx++)
              () {
                final fc = functionCallParts[idx] as Map;
                final call = (fc['functionCall'] as Map)
                    .cast<String, dynamic>();
                String? thoughtSigKey;
                dynamic thoughtSigVal;
                if (fc.containsKey('thoughtSignature')) {
                  thoughtSigKey = 'thoughtSignature';
                  thoughtSigVal = fc['thoughtSignature'];
                } else if (fc.containsKey('thought_signature')) {
                  thoughtSigKey = 'thought_signature';
                  thoughtSigVal = fc['thought_signature'];
                }
                return emitToolCall(
                  id: effectiveToolCallId(call['id'], 'fn', idx),
                  name: (call['name'] ?? '').toString(),
                  arguments:
                      (call['args'] as Map?)?.cast<String, dynamic>() ??
                      const <String, dynamic>{},
                  metadata: {
                    'google': {
                      'part': fc.cast<String, dynamic>(),
                      if (thoughtSigKey != null && thoughtSigVal != null)
                        'thoughtSigKey': thoughtSigKey,
                      if (thoughtSigKey != null && thoughtSigVal != null)
                        'thoughtSigVal': thoughtSigVal,
                    },
                  },
                );
              }(),
          ];
          return;
        }
        // provider 托管的代码执行使用 ServerTool*，不使用 ToolCallResult。
        var codeExecIdx = 0;
        for (final p in parts) {
          if (p is! Map) continue;
          final ec = p['executableCode'] ?? p['executable_code'];
          if (ec is Map) {
            final lang = (ec['language'] ?? '').toString().toLowerCase();
            final code = (ec['code'] ?? '').toString();
            if (code.isNotEmpty) {
              final ceId = 'code_exec_$codeExecIdx';
              codeExecIdx++;
              yield ToolCallStart(id: ceId, toolName: 'code_execution');
              yield ToolCallDelta(
                id: ceId,
                inputDelta: jsonEncode({'language': lang, 'code': code}),
              );
              yield ToolCallEnd(ceId);
            }
          }
          final cr = p['codeExecutionResult'] ?? p['code_execution_result'];
          if (cr is Map) {
            final outcome = (cr['outcome'] ?? '').toString();
            final output = (cr['output'] ?? '').toString();
            final resultId = codeExecIdx > 0
                ? 'code_exec_${codeExecIdx - 1}'
                : 'code_exec_0';
            yield ServerToolStart(id: resultId, toolName: 'code_execution');
            yield ServerToolEnd(
              id: resultId,
              output: output.isEmpty ? outcome : output,
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
          yield* emitDelta(
            ids: StreamChunkIds('round-${currentContents.length}'),
            reasoning: reasoningStr,
            usage: totalUsage,
            totalTokens: totalUsage?.totalTokens ?? 0,
          );
        }
        var contentStr = buf.toString();
        if (persistGeminiThoughtSigs) {
          final metaComment = collectThoughtSigCommentFromParts(parts);
          if (metaComment.isNotEmpty) contentStr += metaComment;
        }
        lastText = contentStr;
      },
      takeCalls: () => pendingCalls,
      continueWithoutCalls: () => false,
      executeAfterRound: true,
      emitCalls: true,
      onToolCall: onToolCall,
      append: (executed) {
        currentContents = [
          ...currentContents,
          {'role': 'model', 'parts': lastParts},
          {
            'role': 'user',
            'parts': [
              for (var i = 0; i < executed.length; i++)
                <String, dynamic>{
                  'functionResponse': {
                    'name': executed[i].call.name,
                    'response': {'result': executed[i].content},
                    if (i < lastFunctionCallParts.length &&
                        lastFunctionCallParts[i] is Map &&
                        ((lastFunctionCallParts[i] as Map)['functionCall']
                                    as Map?)
                                ?.containsKey('id') ==
                            true)
                      'id':
                          ((lastFunctionCallParts[i] as Map)['functionCall']
                              as Map)['id'],
                  },
                },
            ],
          },
        ];
      },
      finish: () => emitDone(
        ids: StreamChunkIds('finish'),
        content: lastText,
        usage: totalUsage,
        totalTokens: totalUsage?.totalTokens ?? 0,
      ),
      usageOf: () => totalUsage,
    );
    return;
  }

  // 通过带 alt=sse 的 :streamGenerateContent 实现 SSE 流式响应，并按 Vertex/Gemini 构建端点。
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

  // 构建 alt=sse 查询参数。
  final uriBase = Uri.parse(baseUrl);
  final qp = Map<String, String>.from(uriBase.queryParameters);
  qp['alt'] = 'sse';
  final uri = uriBase.replace(queryParameters: qp);
  final isVertex = config.vertexAI == true;

  // 将系统消息提取到 systemInstruction（Google Gemini API 推荐格式）。
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
      final raw = extractGeminiThoughtMeta(
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
    final meta = extractGeminiThoughtMeta((msg['content'] ?? '').toString());
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

    // 仅在存在媒体时解析图片；只做语义媒体检测，不识别自定义附件标记。
    final hasMarkdownImages = shouldParseMarkdownImages(raw);
    final internalMediaRefs = parseInternalMediaRefs(
      msg[multimodalInternalMediaPathsKey],
    );
    // 消费用户与 assistant 历史消息中注入的媒体引用。
    final hasInternalMedia = internalMediaRefs.isNotEmpty;
    final hasAttachedImages =
        isLast && role == 'user' && (userImagePaths?.isNotEmpty == true);

    if (hasMarkdownImages || hasAttachedImages || hasInternalMedia) {
      final parsed = await parseTextAndImages(
        raw,
        // Gemini API 目前无法直接拉取远程 http(s) 图片。
        allowRemoteImages: false,
        allowLocalImages: true,
        keepRemoteMarkdownText: true,
      );
      if (parsed.text.isNotEmpty) parts.add({'text': parsed.text});
      // 处理从当前消息文本中提取的图片。
      for (final ref in parsed.images) {
        final normalized = normalizeSrc(ref.src);
        if (!seenSources.add(normalized)) continue;
        if (ref.kind == 'data') {
          final mime = mimeFromDataUrl(ref.src);
          final idx = ref.src.indexOf('base64,');
          if (idx > 0) {
            final b64 = ref.src.substring(idx + 7);
            parts.add({
              'inline_data': {'mime_type': mime, 'data': b64},
            });
          } else {
            // data URL 格式异常时回退为普通文本。
            parts.add({'text': ref.src});
          }
        } else if (ref.kind == 'path') {
          final mime = mimeFromPath(ref.src);
          final b64 = await tryEncodeBase64File(ref.src, withPrefix: false);
          if (b64 == null) continue;
          parts.add({
            'inline_data': {'mime_type': mime, 'data': b64},
          });
        } else {
          // Gemini 官方 API 不会在这里抓取 http(s) 远程 URL，保留简短引用文本。
          parts.add({'text': '(image) ${ref.src}'});
        }
      }
      final supplementalRefs = supplementalMediaRefs(
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
            final mime = mimeForInternalMediaRef(mediaRef);
            final idx = p.indexOf('base64,');
            if (idx > 0) {
              final b64 = p.substring(idx + 7);
              parts.add({
                'inline_data': {'mime_type': mime, 'data': b64},
              });
            }
          } else if (!(p.startsWith('http://') || p.startsWith('https://'))) {
            final mime = mimeForInternalMediaRef(mediaRef);
            final b64 = await tryEncodeBase64File(p, withPrefix: false);
            if (b64 == null) continue;
            parts.add({
              'inline_data': {'mime_type': mime, 'data': b64},
            });
          } else {
            // http URL 的回退引用文本。
            parts.add({'text': '(image) $p'});
          }
        }
      }
    } else {
      // 没有图片时使用简单文本内容。
      if (raw.isNotEmpty) parts.add({'text': raw});
    }
    // 按 Gemini 官方 API 将 YouTube URL 注入为 file_data，仅处理本次请求最后一条用户消息。
    if (role == 'user' && isLast && enableYoutube) {
      final urls = extractYouTubeUrls(raw);
      for (final u in urls) {
        // Vertex AI 的 file_data 需要 mime_type。
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
      applyGeminiThoughtSignatures(
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

  // 将 OpenAI 风格工具映射为 Gemini functionDeclarations（MCP）。
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
        // Google Gemini 要求严格符合 JSON Schema，修复缺少 items 字段的数组属性。
        final cleanedParams = cleanSchemaForGemini(
          params,
          stringEnumOnly: true,
        );
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

  // 为多轮工具调用维护滚动会话。
  List<Map<String, dynamic>> convo = List<Map<String, dynamic>>.from(contents);
  TokenUsage? usage;
  int totalTokens = 0;

  // 累积各流式轮次中的内置搜索引用。
  final List<Map<String, dynamic>> builtinCitations = <Map<String, dynamic>>[];
  int malformedResponseRetryCount = 0;
  var streamRound = 0;
  var pendingCalls = <EmitToolCall>[];
  var lastRoundCalls = <Map<String, dynamic>>[];
  var lastRoundModelParts = <dynamic>[];
  var retryMalformed = false;

  yield* runProviderToolRounds(
    sendRound: () async* {
      pendingCalls = [];
      lastRoundCalls = [];
      lastRoundModelParts = [];
      retryMalformed = false;
      final defaultMaxOutputTokens = _defaultGeminiMaxOutputTokens(
        upstreamModelId,
      );
      final omitSamplingParams = _shouldOmitGeminiSamplingParams(
        upstreamModelId,
      );
      final gen = <String, dynamic>{
        if (!omitSamplingParams && temperature != null)
          'temperature': temperature,
        if (!omitSamplingParams && topP != null) 'topP': topP,
        if (maxTokens ?? defaultMaxOutputTokens case final resolvedMaxTokens?)
          'maxOutputTokens': resolvedMaxTokens,
        // 模型配置为输出图片时启用 IMAGE+TEXT 模态。
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
        final token = await maybeVertexAccessToken(config);
        if (token != null && token.isNotEmpty) {
          requestHeaders['Authorization'] = 'Bearer $token';
        }
        final proj = (config.projectId ?? '').trim();
        if (proj.isNotEmpty) requestHeaders['X-Goog-User-Project'] = proj;
      } else {
        final apiKey = effectiveApiKey(config);
        if (apiKey.isNotEmpty) {
          requestHeaders['x-goog-api-key'] = apiKey;
        }
      }
      final headers = customHeaders(
        config,
        modelId,
        baseHeaders: requestHeaders,
        assistantHeaders: extraHeaders,
      );
      request.headers.addAll(headers);
      final extra = customBody(config, modelId, assistantBody: extraBody);
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
      final sourceId = 'round-${streamRound++}';
      final decoder = GoogleStreamDecoder(
        isGemini3: isGemini3,
        persistThoughtSigs: persistGeminiThoughtSigs,
        expectImage: expectImage,
        receivedImage: receivedImage,
        initialUsage: usage,
        citations: builtinCitations,
        sourceId: sourceId,
      );
      Future<String> sanitizeTextIfNeeded(String input) async {
        if (input.isEmpty) return input;
        if (input.contains('data:image') && input.contains('base64,')) {
          try {
            return await MarkdownMediaSanitizer.replaceInlineBase64Images(
              input,
            );
          } catch (_) {
            return input;
          }
        }
        return input;
      }

      Future<String> takeBufferedImageMarkdown() async {
        final pending = decoder.takeBufferedImage();
        if (pending == null) return '';
        final path = await AppDirectories.saveBase64Image(
          pending.mimeType,
          pending.data,
        );
        if (path == null || path.isEmpty) return '';
        final uri = SandboxPathResolver.canonicalize(path);
        final sb = StringBuffer()
          ..write('\n\n![image](')
          ..write(uri)
          ..write(')');
        if (pending.trailingText.isNotEmpty) {
          sb.write(pending.trailingText);
        }
        return sb.toString();
      }

      await for (final event in parseSseEventStrings(sse)) {
        final data = event.data;
        if (data.isEmpty) continue;
        // Gemini 可能在 2xx 流中内嵌错误、提示级拦截或候选级内容过滤结束信号；
        // 必须先抛出，避免被下面的异常分片保护逻辑吞掉。
        throwIfInBandStreamError(data);
        _throwIfGeminiPromptBlocked(data);
        _throwIfGeminiCandidateBlocked(data);
        final decoded = decoder.accept(event);
        for (final remote in decoder.takePendingRemoteImages()) {
          try {
            final b64 = await downloadRemoteAsBase64(
              client,
              config,
              remote.uri,
            );
            for (final chunk in decoder.ingestImageData(
              remote.mimeType,
              b64,
              thoughtSigKey: remote.thoughtSigKey,
              thoughtSigVal: remote.thoughtSigVal,
            )) {
              yield await sanitizeStreamChunk(chunk, sanitizeTextIfNeeded);
            }
          } catch (_) {}
        }
        for (final chunk in decoder.takeOrphanedTrailingText()) {
          yield await sanitizeStreamChunk(chunk, sanitizeTextIfNeeded);
        }
        for (final chunk in decoded.chunks) {
          yield await sanitizeStreamChunk(chunk, sanitizeTextIfNeeded);
          if (chunk is ToolCallEnd &&
              decoder.isClientFunctionCall(chunk.id) &&
              onToolCall != null) {
            final call = decoder.functionCallById(chunk.id)!;
            if (call.result.isEmpty) {
              final emitCall = emitToolCall(
                id: call.id,
                name: call.name,
                arguments: call.args,
                metadata: {
                  'google': {
                    'part': call.part,
                    if (call.thoughtSigKey != null &&
                        call.thoughtSigVal != null)
                      'thoughtSigKey': call.thoughtSigKey,
                    if (call.thoughtSigKey != null &&
                        call.thoughtSigVal != null)
                      'thoughtSigVal': call.thoughtSigVal,
                  },
                },
              );
              await for (final resultChunk in executeClientTools(
                calls: [emitCall],
                onToolCall: onToolCall,
                usage: decoder.usage,
                totalTokens: decoder.usage?.totalTokens ?? 0,
              )) {
                if (resultChunk is ToolCallResult) {
                  call.result = (resultChunk.output ?? '').toString();
                }
                yield resultChunk;
              }
            }
          }
        }
        if (decoded.completed || decoder.canFinishNow) break;
      }
      for (final chunk in decoder.onClosed()) {
        yield await sanitizeStreamChunk(chunk, sanitizeTextIfNeeded);
      }

      receivedImage = decoder.receivedImage;
      usage = decoder.usage ?? usage;
      totalTokens = usage?.totalTokens ?? totalTokens;
      final calls = [
        for (final call in decoder.functionCalls)
          <String, dynamic>{
            'id': call.id,
            'apiId': call.apiId,
            'name': call.name,
            'args': call.args,
            'result': call.result,
            'thoughtSigKey': call.thoughtSigKey,
            'thoughtSigVal': call.thoughtSigVal,
            'part': call.part,
          },
      ];
      final roundModelParts = decoder.roundModelParts;
      final retryMalformedResponse = decoder.retryMalformedResponse;
      final responseTextThoughtSigKey = decoder.textThoughtSigKey;
      final responseTextThoughtSigVal = decoder.textThoughtSigVal;
      final responseImageThoughtSigs = decoder.imageThoughtSigs;

      if (retryMalformedResponse) {
        // 这是暂时性的模型生成失败；不把异常候选加入会话，原样重试当前轮次一次。
        if (malformedResponseRetryCount == 0) {
          malformedResponseRetryCount++;
          retryMalformed = true;
          return;
        }
        throw const HttpException(
          'Gemini response generation failed (MALFORMED_RESPONSE)',
        );
      }

      // 刷出尚未转成 Image* 事件的缓存内联图片。
      if (!decoder.emittedImageEvents) {
        final pendingImage = await takeBufferedImageMarkdown();
        if (pendingImage.isNotEmpty) {
          logImageFallback(
            provider: config.id,
            model: modelId,
            reason: 'google_decoder_missed_image',
          );
          final sanitized = await sanitizeTextIfNeeded(pendingImage);
          yield* emitDelta(
            ids: StreamChunkIds(sourceId),
            content: sanitized,
            usage: usage,
            totalTokens: totalTokens,
          );
        }
      }

      if (calls.isEmpty) {
        // 没有工具调用，本轮完成；引用已经由 decoder 发出。
        if (persistGeminiThoughtSigs) {
          final metaComment = buildGeminiThoughtSigComment(
            textKey: responseTextThoughtSigKey,
            textValue: responseTextThoughtSigVal,
            imageSigs: responseImageThoughtSigs,
          );
          if (metaComment.isNotEmpty) {
            yield* emitDelta(
              ids: StreamChunkIds(sourceId),
              content: metaComment,
              usage: usage,
              totalTokens: totalTokens,
            );
          }
        }
        return;
      }

      malformedResponseRetryCount = 0;
      lastRoundCalls = calls;
      lastRoundModelParts = roundModelParts;
      pendingCalls = [
        for (final c in calls)
          emitToolCall(
            id: (c['id'] ?? '').toString(),
            name: (c['name'] ?? '').toString(),
            arguments:
                (c['args'] as Map<String, dynamic>?) ??
                const <String, dynamic>{},
          ),
      ];
    },
    takeCalls: () => pendingCalls,
    continueWithoutCalls: () => retryMalformed,
    executeAfterRound: false,
    onToolCall: onToolCall,
    append: (executed) {
      if (retryMalformed) return;
      if (isGemini3) {
        convo.add({'role': 'model', 'parts': lastRoundModelParts});
        final responseParts = <Map<String, dynamic>>[];
        for (final c in lastRoundCalls) {
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
        return;
      }
      for (final c in lastRoundCalls) {
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
    },
    finish: () => emitDone(
      ids: StreamChunkIds('finish'),
      usage: usage,
      totalTokens: totalTokens,
    ),
    usageOf: () => usage,
  );
}

Future<String?> maybeVertexAccessToken(ProviderConfig cfg) async {
  if (cfg.vertexAI != true) return null;
  final jsonStr = (cfg.serviceAccountJson ?? '').trim();
  if (jsonStr.isEmpty) {
    // 兼容把临时 OAuth token 直接填入 apiKey 的配置。
    final key = cfg.apiKey.trim();
    return key.isEmpty ? null : key;
  }
  return GoogleServiceAccountAuth.getAccessTokenFromJson(jsonStr);
}

Future<String> downloadRemoteAsBase64(
  http.Client client,
  ProviderConfig config,
  String url,
) async {
  final uri = Uri.parse(url);
  final request = http.Request('GET', uri);
  if (config.vertexAI == true && _shouldAttachVertexMediaAuthForEvents(uri)) {
    final token = await maybeVertexAccessToken(config);
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    final projectId = (config.projectId ?? '').trim();
    if (projectId.isNotEmpty) {
      request.headers['X-Goog-User-Project'] = projectId;
    }
  }
  final response = await client.send(request);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final body = await response.stream.bytesToString();
    throw HttpException('HTTP ${response.statusCode}: $body');
  }
  final bytes = await response.stream.fold<List<int>>(<int>[], (all, chunk) {
    all.addAll(chunk);
    return all;
  });
  return base64Encode(bytes);
}

bool _shouldAttachVertexMediaAuthForEvents(Uri uri) {
  if (uri.scheme.toLowerCase() != 'https') return false;
  final host = uri.host.trim().toLowerCase();
  return host == 'googleapis.com' ||
      host.endsWith('.googleapis.com') ||
      host == 'googleusercontent.com' ||
      host.endsWith('.googleusercontent.com') ||
      host == 'storage.cloud.google.com';
}
