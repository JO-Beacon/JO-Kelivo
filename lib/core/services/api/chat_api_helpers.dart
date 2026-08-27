import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../../providers/model_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/api_key_manager.dart';
import '../../utils/multimodal_input_utils.dart';
import '../../utils/openai_model_compat.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../logging/flutter_logger.dart';
import '../model_override_payload_parser.dart';
import '../model_override_resolver.dart';
import '../custom_request_merger.dart';
import 'builtin_tools.dart';
import 'provider_request_headers.dart';

typedef ToolCallHandler =
    Future<String> Function(
      String name,
      Map<String, dynamic> args, {
      String? toolCallId,
    });

String effectiveToolCallId(dynamic rawId, String fallbackPrefix, Object index) {
  final id = rawId?.toString().trim() ?? '';
  if (id.isNotEmpty) return id;
  return '${fallbackPrefix}_${DateTime.now().microsecondsSinceEpoch}_$index';
}

Future<String> decodeUtf8Stream(
  http.ByteStream stream, {
  bool allowMalformed = true,
}) async {
  return utf8.decode(await stream.toBytes(), allowMalformed: allowMalformed);
}

const String _aihubmixAppCode = 'ZKRT3588';

/// 解析逻辑模型键对应的上游/供应商模型 id。
/// 实例覆盖配置指定 `apiModelId` 时用于外发请求和供应商判断，否则使用逻辑 `modelId`。
String apiModelId(ProviderConfig cfg, String modelId) {
  try {
    final ov = _modelOverride(cfg, modelId);
    return resolveApiModelIdOverride(ov, modelId);
  } catch (_) {}
  return modelId;
}

String apiKeyForRequest(ProviderConfig cfg, String modelId) {
  return effectiveApiKey(cfg).trim();
}

String effectiveApiKey(ProviderConfig cfg) {
  try {
    if (cfg.multiKeyEnabled == true && (cfg.apiKeys?.isNotEmpty == true)) {
      final sel = ApiKeyManager().selectForProvider(cfg);
      if (sel.key != null) return sel.key!.key;
    }
  } catch (_) {}
  return cfg.apiKey;
}

// 读取按模型配置的内置工具（例如 ['search', 'url_context']），存储于
// ProviderConfig.modelOverrides[modelId].builtInTools。
Set<String> builtInTools(ProviderConfig cfg, String modelId) {
  try {
    return BuiltInToolNames.parseFromOverride(cfg.modelOverrides[modelId]);
  } catch (_) {}
  return const <String>{};
}

// 从 ProviderConfig 读取按模型覆盖的 headers/body 辅助方法。
Map<String, dynamic> _modelOverride(ProviderConfig cfg, String modelId) {
  return ModelOverridePayloadParser.modelOverride(cfg.modelOverrides, modelId);
}

Map<String, String> customHeaders(
  ProviderConfig cfg,
  String modelId, {
  Map<String, String> baseHeaders = const <String, String>{},
  Map<String, String>? assistantHeaders,
}) {
  final ov = _modelOverride(cfg, modelId);
  final automatic = <String, String>{...providerDefaultHeaders(cfg)};
  // AIhubmix 推广标头（按 provider 选择加入）。
  if (_isAihubmix(cfg) && cfg.aihubmixAppCodeEnabled == true) {
    automatic.putIfAbsent('APP-Code', () => _aihubmixAppCode);
  }
  return CustomRequestMerger.mergeHeaders(
    base: baseHeaders,
    assistant: assistantHeaders,
    providerAutomatic: automatic,
    provider: ModelOverridePayloadParser.customHeadersFromRows(
      cfg.customHeaders,
    ),
    model: ModelOverridePayloadParser.customHeaders(ov),
  );
}

Map<String, dynamic> customBody(
  ProviderConfig cfg,
  String modelId, {
  Map<String, dynamic>? assistantBody,
}) {
  final ov = _modelOverride(cfg, modelId);
  return CustomRequestMerger.mergeBody(
    assistant: assistantBody,
    providerRows: cfg.customBody,
    model: ModelOverridePayloadParser.customBody(ov),
  );
}

bool _isAihubmix(ProviderConfig cfg) {
  final base = cfg.baseUrl.toLowerCase();
  return base.contains('aihubmix.com');
}

// 按模型覆盖解析有效模型信息；没有覆盖时回退到推断结果。
ModelInfo effectiveModelInfo(ProviderConfig cfg, String modelId) {
  final upstreamId = apiModelId(cfg, modelId);
  final base = ModelRegistry.infer(
    ModelInfo(id: upstreamId, displayName: upstreamId),
  );
  final ov = _modelOverride(cfg, modelId);
  if (ov.isEmpty) return base;
  try {
    return ModelOverrideResolver.applyModelOverride(base, ov);
  } catch (e, st) {
    FlutterLogger.log(
      '[ModelOverride] applyModelOverride failed: $e\n$st',
      tag: 'ModelOverride',
    );
    return base;
  }
}

String mimeFromPath(String path) {
  return inferMediaMimeFromSource(path, fallbackMime: 'image/png');
}

String mimeFromDataUrl(String dataUrl) {
  try {
    final start = dataUrl.indexOf(':');
    final semi = dataUrl.indexOf(';');
    if (start >= 0 && semi > start) {
      return dataUrl.substring(start + 1, semi);
    }
  } catch (_) {}
  return 'image/png';
}

// 已解析文本和图片引用的简单容器。
Future<bool> _isValidRemoteImageUrl(String url) async {
  try {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return false;
    }
    final client = http.Client();
    try {
      final resp = await client.head(uri).timeout(const Duration(seconds: 5));
      // 标准成功/重定向视为有效，4xx/5xx（例如 404）视为无效。
      final code = resp.statusCode;
      if (code >= 200 && code < 400) return true;
      // 部分服务器不支持 HEAD，可能返回 405/501；将其视为不确定但有效。
      if (code == 405 || code == 501) return true;
      return false;
    } finally {
      client.close();
    }
  } catch (_) {
    // 网络错误/超时视为无效，回退到纯文本。
    return false;
  }
}

// 已解析文本和图片引用的简单容器。
Future<ParsedTextAndImages> parseTextAndImages(
  String raw, {
  required bool allowRemoteImages,
  required bool allowLocalImages,
  bool allowDataImages = true,
  bool keepRemoteMarkdownText = true,
  bool keepDisallowedImageText = true,
}) async {
  if (raw.isEmpty) return const ParsedTextAndImages('', <ImageRef>[]);
  final mdImg = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');
  // 这里有意不识别自定义附件标记；附件通过结构化 parts/媒体路径键传入。
  final images = <ImageRef>[];
  final buf = StringBuffer();
  int i = 0;
  while (i < raw.length) {
    // 跳过围栏代码块（``` 或 ~~~），其中内容不应被识别为图片。
    if ((raw.startsWith('```', i) || raw.startsWith('~~~', i)) &&
        (i == 0 || raw[i - 1] == '\n')) {
      final fence = raw.substring(i, i + 3);
      buf.write(fence);
      i += 3;
      // 跳过开围栏行剩余内容（语言标签等）。
      while (i < raw.length && raw[i] != '\n') {
        buf.write(raw[i]);
        i++;
      }
      // 推进到行首匹配的闭合围栏。
      bool closed = false;
      while (i < raw.length) {
        if (raw[i] == '\n') {
          buf.write(raw[i]);
          i++;
          if (raw.startsWith(fence, i)) {
            buf.write(fence);
            i += 3;
            // 跳过闭合围栏行的尾随内容。
            while (i < raw.length && raw[i] != '\n') {
              buf.write(raw[i]);
              i++;
            }
            closed = true;
            break;
          }
        } else {
          buf.write(raw[i]);
          i++;
        }
      }
      if (!closed) {
        // 围栏未闭合，剩余文本已经按原样写入。
      }
      continue;
    }
    // 跳过行内代码片段（反引号序列）。
    if (raw[i] == '`') {
      // 确定开反引号序列的长度。
      int tickLen = 0;
      while (i + tickLen < raw.length && raw[i + tickLen] == '`') {
        tickLen++;
      }
      final openTicks = raw.substring(i, i + tickLen);
      buf.write(openTicks);
      i += tickLen;
      // 推进到匹配的闭合反引号序列。
      bool closedTick = false;
      while (i < raw.length) {
        if (raw.startsWith(openTicks, i)) {
          buf.write(openTicks);
          i += tickLen;
          closedTick = true;
          break;
        }
        buf.write(raw[i]);
        i++;
      }
      if (!closedTick) {
        // 行内代码未闭合，内容已经按原样写入。
      }
      continue;
    }

    final m1 = mdImg.matchAsPrefix(raw, i);
    if (m1 != null) {
      final full = raw.substring(m1.start, m1.end);
      final url = (m1.group(1) ?? '').trim();
      if (url.isEmpty) {
        // URL 为空时按纯文本处理，不尝试解析为图片。
        buf.write(full);
        i = m1.end;
        continue;
      }
      // 内联 base64/data URL 始终视为图片，但不写入文本。
      if (url.startsWith('data:')) {
        if (allowDataImages) {
          images.add(ImageRef('data', url));
        } else if (keepDisallowedImageText) {
          buf.write(full);
        }
        i = m1.end;
        continue;
      }
      // 远程 http(s) URL。
      if (url.startsWith('http://') || url.startsWith('https://')) {
        if (!allowRemoteImages) {
          // 模型不接受图片输入，或有意跳过 http 图片；保留原始 Markdown 模板。
          if (keepDisallowedImageText) buf.write(full);
          i = m1.end;
          continue;
        }
        final ok = await _isValidRemoteImageUrl(url);
        if (!ok) {
          // 图片 URL 无效或不可访问（例如 404）时保留为纯文本。
          buf.write(full);
          i = m1.end;
          continue;
        }
        images.add(ImageRef('url', url));
        if (keepRemoteMarkdownText) {
          // 保留 Markdown，让模型看到模板语法和 URL。
          buf.write(full);
        }
        i = m1.end;
        continue;
      }
      // 本地/相对路径仅在文件存在时视为图片。
      if (!allowLocalImages) {
        if (keepDisallowedImageText) buf.write(full);
        i = m1.end;
        continue;
      }
      try {
        final resolved = SandboxPathResolver.resolveForIo(url);
        if (resolved == null) {
          buf.write(full);
          i = m1.end;
          continue;
        }
        final file = File(resolved);
        if (!file.existsSync()) {
          // 本地文件缺失时不视为图片，保留原始 Markdown。
          buf.write(full);
          i = m1.end;
          continue;
        }
      } catch (_) {
        // 探测文件发生错误时回退到纯文本。
        buf.write(full);
        i = m1.end;
        continue;
      }
      images.add(ImageRef('path', url));
      // 对真实本地文件保持原行为：仅作为图片附件，不将 Markdown 写入文本。
      i = m1.end;
      continue;
    }
    buf.write(raw[i]);
    i++;
  }
  return ParsedTextAndImages(buf.toString().trim(), images);
}

Future<String> _encodeBase64File(String path, {bool withPrefix = false}) async {
  final resolved = SandboxPathResolver.resolveForIo(path);
  if (resolved == null) {
    throw FileSystemException('rejected local path', path);
  }
  final file = File(resolved);
  final bytes = await file.readAsBytes();
  final b64 = base64Encode(bytes);
  if (withPrefix) {
    final mime = mimeFromPath(resolved);
    return 'data:$mime;base64,$b64';
  }
  return b64;
}

/// 类似 [_encodeBase64File]，但缺失或不可读时返回 null，便于请求构建器跳过不可用附件。
Future<String?> tryEncodeBase64File(
  String path, {
  bool withPrefix = false,
}) async {
  try {
    final resolved = SandboxPathResolver.resolveForIo(path);
    if (resolved == null) return null;
    final file = File(resolved);
    if (!await file.exists()) return null;
    return _encodeBase64File(resolved, withPrefix: withPrefix);
  } catch (_) {
    return null;
  }
}

String textFromContentParts(dynamic content) {
  if (content is String) return content.trim();
  if (content is! List) return (content ?? '').toString().trim();

  final buffer = StringBuffer();
  for (final part in content) {
    if (part is String) {
      buffer.write(part);
      continue;
    }
    if (part is! Map) continue;
    final type = (part['type'] ?? '').toString();
    if (type.isNotEmpty &&
        type != 'text' &&
        type != 'input_text' &&
        type != 'output_text') {
      continue;
    }
    final text = (part['text'] ?? part['content'] ?? '').toString();
    if (text.isEmpty) continue;
    if (buffer.isNotEmpty) buffer.write('\n');
    buffer.write(text);
  }
  return buffer.toString().trim();
}

bool isOff(int? budget) => (budget != null && budget != -1 && budget < 1024);
String effortForBudget(int? budget) {
  if (budget == null || budget == -1) return 'auto';
  if (isOff(budget)) return 'off';
  if (budget <= 2000) return 'low';
  if (budget <= 20000) return 'medium';
  return 'high';
}

bool isClaudeReasoningEnabled(int? budget) => budget != 0;

bool _isDeepSeekClaudeCompatible(String modelId, {ProviderConfig? config}) {
  final lowerModelId = modelId.trim().toLowerCase();
  if (lowerModelId.contains('deepseek')) return true;
  if (config == null) return false;
  final baseUrl = config.baseUrl.trim().toLowerCase();
  final providerId = config.id.trim().toLowerCase();
  final providerName = config.name.trim().toLowerCase();
  return baseUrl.contains('api.deepseek.com') ||
      providerId.contains('deepseek') ||
      providerName.contains('deepseek');
}

bool _isClaude5AdaptiveThinkingModel(String modelId) {
  return RegExp(
    r'claude-(?:opus|sonnet)-5(?:$|[._:@/-])',
    caseSensitive: false,
  ).hasMatch(modelId.trim());
}

bool _supportsClaudeAdaptiveThinking(String modelId) {
  final lower = modelId.trim().toLowerCase();
  if (!lower.contains('claude-')) return false;
  if (lower.contains('fable') || lower.contains('mythos')) return true;
  if (_isClaude5AdaptiveThinkingModel(lower)) return true;
  final m = RegExp(
    r'claude-(opus|sonnet)-(\d+)[-.](\d+)',
    caseSensitive: false,
  ).firstMatch(lower);
  if (m != null) {
    final major = int.tryParse(m.group(2) ?? '');
    final minor = int.tryParse(m.group(3) ?? '');
    if (major != null && minor != null) {
      return major > 4 || (major == 4 && minor >= 6);
    }
  }
  return lower.contains('4-6') || lower.contains('4.6');
}

bool _isClaudeAdaptiveOnlyThinkingModel(String modelId) {
  final lower = modelId.trim().toLowerCase();
  if (!lower.contains('claude-')) return false;
  if (lower.contains('fable') || lower.contains('mythos')) return true;
  if (_isClaude5AdaptiveThinkingModel(lower)) return true;
  final m = RegExp(
    r'claude-(opus|sonnet)-(\d+)[-.](\d+)',
    caseSensitive: false,
  ).firstMatch(lower);
  if (m == null) {
    return lower.contains('4-7') ||
        lower.contains('4.7') ||
        lower.contains('4-8') ||
        lower.contains('4.8');
  }
  final family = (m.group(1) ?? '').toLowerCase();
  final major = int.tryParse(m.group(2) ?? '');
  final minor = int.tryParse(m.group(3) ?? '');
  if (major == null || minor == null) return false;
  if (major > 4) return true;
  if (major < 4) return false;
  if (family == 'opus' && minor >= 7) return true;
  return false;
}

bool _isClaudeThinkingAlwaysOnModel(String modelId) {
  final lower = modelId.trim().toLowerCase();
  return lower.contains('claude-fable') || lower.contains('claude-mythos');
}

String _claudeEffortForBudget(int? budget) {
  if (budget == null || budget == -1) return 'auto';
  if (isOff(budget)) return 'off';
  if (budget <= 2000) return 'low';
  if (budget <= 20000) return 'medium';
  if (budget <= 32000) return 'high';
  if (budget <= 64000) return 'xhigh';
  return 'max';
}

String _normalizeClaudeEffort(String effort, String modelId) {
  final normalizedEffort = effort.trim().toLowerCase();
  if (normalizedEffort.isEmpty) return effort;
  if (normalizedEffort == 'auto' || normalizedEffort == 'off') {
    return normalizedEffort;
  }

  final lower = modelId.trim().toLowerCase();
  final supportsXhigh =
      _isClaude5AdaptiveThinkingModel(lower) ||
      lower.contains('claude-opus-4-7') ||
      lower.contains('claude-opus-4.7') ||
      lower.contains('claude-opus-4-8') ||
      lower.contains('claude-opus-4.8') ||
      lower.contains('claude-fable') ||
      lower.contains('claude-mythos');
  final supportsMax =
      supportsXhigh ||
      lower.contains('claude-opus-4-6') ||
      lower.contains('claude-opus-4.6') ||
      lower.contains('claude-sonnet-4-6') ||
      lower.contains('claude-sonnet-4.6') ||
      lower.contains('mythos');

  switch (normalizedEffort) {
    case 'max':
      if (supportsMax) return 'max';
      return supportsXhigh ? 'xhigh' : 'high';
    case 'xhigh':
      if (supportsXhigh) return 'xhigh';
      if (supportsMax) return 'max';
      return 'high';
    case 'high':
    case 'medium':
    case 'low':
      return normalizedEffort;
    default:
      return normalizedEffort;
  }
}

Map<String, dynamic>? claudeThinkingConfig(
  String modelId,
  int? budget, {
  ProviderConfig? config,
}) {
  if (_isClaudeThinkingAlwaysOnModel(modelId)) {
    if (!isClaudeReasoningEnabled(budget)) return null;
    return <String, dynamic>{'type': 'adaptive', 'display': 'summarized'};
  }
  if (!isClaudeReasoningEnabled(budget)) {
    return <String, dynamic>{'type': 'disabled'};
  }
  if (_isDeepSeekClaudeCompatible(modelId, config: config)) {
    return <String, dynamic>{'type': 'enabled'};
  }
  if (_supportsClaudeAdaptiveThinking(modelId)) {
    return <String, dynamic>{'type': 'adaptive', 'display': 'summarized'};
  }
  if (budget != null && budget > 0) {
    return <String, dynamic>{'type': 'enabled', 'budget_tokens': budget};
  }
  return <String, dynamic>{'type': 'disabled'};
}

Map<String, dynamic>? claudeOutputConfig(
  String modelId,
  int? budget, {
  ProviderConfig? config,
}) {
  if (_isClaudeThinkingAlwaysOnModel(modelId)) {
    final effort = _normalizeClaudeEffort(
      _claudeEffortForBudget(budget),
      modelId,
    );
    if (effort == 'auto' || effort == 'off') return null;
    return <String, dynamic>{'effort': effort};
  }
  if (_isDeepSeekClaudeCompatible(modelId, config: config)) {
    if (!isClaudeReasoningEnabled(budget)) return null;
    final effort = _claudeEffortForBudget(budget);
    if (effort == 'auto' || effort == 'off') return null;
    return <String, dynamic>{
      'effort': (effort == 'xhigh' || effort == 'max') ? 'max' : 'high',
    };
  }
  if (!_supportsClaudeAdaptiveThinking(modelId) ||
      !isClaudeReasoningEnabled(budget)) {
    return null;
  }
  final effort = _normalizeClaudeEffort(
    _claudeEffortForBudget(budget),
    modelId,
  );
  if (effort == 'auto' || effort == 'off') return null;
  return <String, dynamic>{'effort': effort};
}

bool claudeShouldOmitSamplingParams(String modelId, int? budget) {
  if (_isClaudeThinkingAlwaysOnModel(modelId)) return true;
  final lower = modelId.trim().toLowerCase();
  if (_isClaude5AdaptiveThinkingModel(lower) ||
      lower.contains('claude-opus-4-8') ||
      lower.contains('claude-opus-4.8')) {
    return true;
  }
  return _isClaudeAdaptiveOnlyThinkingModel(modelId) &&
      isClaudeReasoningEnabled(budget);
}

double? claudeCompatibleTopP(String modelId, int? budget, double? topP) {
  if (topP == null) return null;
  if (claudeShouldOmitSamplingParams(modelId, budget)) {
    return null;
  }
  if (!isClaudeReasoningEnabled(budget)) {
    return topP;
  }
  if (topP < 0.95 || topP > 1.0) {
    FlutterLogger.log(
      '[ClaudeCompat] Omit top_p=$topP because thinking requires 0.95 <= top_p <= 1.0.',
      tag: 'ChatApiService',
    );
    return null;
  }
  return topP;
}

// 清理 JSON Schema 以满足 Google Gemini 的严格校验；数组类型必须包含 items 字段。
Map<String, dynamic> cleanSchemaForGemini(
  Map<String, dynamic> schema, {
  bool stringEnumOnly = false,
}) {
  final result = Map<String, dynamic>.from(schema);
  if (stringEnumOnly && result['enum'] is List) {
    final values = result['enum'] as List;
    if (values.every((value) => value is String)) {
      result['type'] = 'string';
      result['enum'] = values.map((value) => value.toString()).toList();
    } else {
      result.remove('enum');
    }
  }

  // 递归修复 properties。
  Map<String, dynamic> props = const <String, dynamic>{};
  if (result['properties'] is Map) {
    props = Map<String, dynamic>.from(result['properties'] as Map);
  } else if ((result['type'] ?? '').toString() == 'object') {
    // 确保对象始终带有 properties，以通过 Gemini 校验。
    props = <String, dynamic>{};
  }
  if (props.isNotEmpty || result['type'] == 'object') {
    props.forEach((key, value) {
      if (value is Map) {
        final propMap = Map<String, dynamic>.from(value);
        // 数组类型缺少 items 时补充宽松的元素 schema。
        if (propMap['type'] == 'array' && !propMap.containsKey('items')) {
          propMap['items'] = {'type': 'string'}; // 默认使用字符串数组
        }
        // 递归清理嵌套对象。
        if (propMap['type'] == 'object' && propMap.containsKey('properties')) {
          propMap['properties'] = cleanSchemaForGemini({
            'properties': propMap['properties'],
          }, stringEnumOnly: stringEnumOnly)['properties'];
        }
        props[key] = propMap;
      }
    });

    // Gemini 要求 required 中的每个字段都存在于 properties。
    final req = result['required'];
    if (req is List) {
      for (final r in req) {
        final name = r.toString();
        if (!props.containsKey(name)) {
          props[name] = {'type': 'string'}; // 回退到简单字符串字段
        }
      }
    }
    result['properties'] = props;
  }

  // 递归处理数组 items。
  if (result['items'] is Map) {
    result['items'] = cleanSchemaForGemini(
      result['items'] as Map<String, dynamic>,
      stringEnumOnly: stringEnumOnly,
    );
  }

  return result;
}

bool shouldParseMarkdownImages(String raw, {bool skipImageParsing = false}) {
  if (skipImageParsing) return false;
  return RegExp(r'!\[[^\]]*\]\([^)]+\)').hasMatch(raw);
}

const String geminiDummyThoughtSignature =
    'context_engineering_is_the_way_to_go';
final RegExp _geminiThoughtSigComment = RegExp(
  r'<!--\s*gemini_thought_signatures:(.*?)-->',
  dotAll: true,
);

final class GeminiSignatureMeta {
  const GeminiSignatureMeta({
    required this.cleanedText,
    this.textKey,
    this.textValue,
    this.images = const <Map<String, dynamic>>[],
  });

  final String cleanedText;
  final String? textKey;
  final dynamic textValue;
  final List<Map<String, dynamic>> images;

  bool get hasText => (textKey ?? '').isNotEmpty && textValue != null;
  bool get hasImages => images.isNotEmpty;
  bool get hasAny => hasText || hasImages;
}

GeminiSignatureMeta extractGeminiThoughtMeta(String raw) {
  final match = _geminiThoughtSigComment.firstMatch(raw);
  if (match == null) return GeminiSignatureMeta(cleanedText: raw);
  try {
    final data = (jsonDecode((match.group(1) ?? '').trim()) as Map)
        .cast<String, dynamic>();
    String? textKey;
    dynamic textValue;
    final text = data['text'];
    if (text is Map) {
      textKey = (text['k'] ?? text['key'])?.toString();
      textValue = text['v'] ?? text['val'];
      if (textKey?.trim().isEmpty == true) textKey = null;
    }
    final images = <Map<String, dynamic>>[];
    final imageList = data['images'];
    if (imageList is List) {
      for (final item in imageList) {
        if (item is! Map) continue;
        final key = (item['k'] ?? item['key'])?.toString() ?? '';
        final value = item['v'] ?? item['val'];
        if (key.isNotEmpty && value != null) images.add({'k': key, 'v': value});
      }
    }
    return GeminiSignatureMeta(
      cleanedText: raw.replaceRange(match.start, match.end, '').trimRight(),
      textKey: textKey,
      textValue: textValue,
      images: images,
    );
  } catch (_) {
    return GeminiSignatureMeta(cleanedText: raw);
  }
}

String buildGeminiThoughtSigComment({
  String? textKey,
  dynamic textValue,
  List<Map<String, dynamic>> imageSigs = const <Map<String, dynamic>>[],
}) {
  final images = imageSigs
      .where(
        (item) =>
            (item['k'] ?? '').toString().isNotEmpty && item.containsKey('v'),
      )
      .toList();
  final hasText = (textKey ?? '').isNotEmpty && textValue != null;
  if (!hasText && images.isEmpty) return '';
  final payload = <String, dynamic>{
    if (hasText) 'text': {'k': textKey, 'v': textValue},
    if (images.isNotEmpty) 'images': images,
  };
  return '\n<!-- gemini_thought_signatures:${jsonEncode(payload)} -->';
}

void applyGeminiThoughtSignatures(
  GeminiSignatureMeta meta,
  List<Map<String, dynamic>> parts, {
  bool attachDummyWhenMissing = false,
}) {
  if (meta.hasAny) {
    if (meta.hasText) {
      for (final part in parts) {
        if (part.containsKey('text')) {
          part[meta.textKey!] = meta.textValue;
          break;
        }
      }
    }
    if (meta.hasImages) {
      var index = 0;
      for (final part in parts) {
        if (index >= meta.images.length) break;
        if (part.containsKey('inline_data') || part.containsKey('inlineData')) {
          final signature = meta.images[index++];
          final key = (signature['k'] ?? '').toString();
          if (key.isNotEmpty && signature['v'] != null) {
            part[key] = signature['v'];
          }
        }
      }
    }
  } else if (attachDummyWhenMissing) {
    var inlineFound = false;
    var textTagged = false;
    for (final part in parts) {
      final hasText = part.containsKey('text');
      final hasInline =
          part.containsKey('inline_data') || part.containsKey('inlineData');
      if (!hasInline) continue;
      inlineFound = true;
      part.putIfAbsent('thoughtSignature', () => geminiDummyThoughtSignature);
      if (hasText && !textTagged) textTagged = true;
    }
    if (inlineFound && !textTagged) {
      for (final part in parts) {
        if (part.containsKey('text')) {
          part.putIfAbsent(
            'thoughtSignature',
            () => geminiDummyThoughtSignature,
          );
          break;
        }
      }
    }
  }
}

String collectThoughtSigCommentFromParts(List<dynamic> parts) {
  String? textKey;
  dynamic textValue;
  final images = <Map<String, dynamic>>[];
  for (final part in parts) {
    if (part is! Map) continue;
    String? key;
    dynamic value;
    if (part.containsKey('thoughtSignature')) {
      key = 'thoughtSignature';
      value = part['thoughtSignature'];
    } else if (part.containsKey('thought_signature')) {
      key = 'thought_signature';
      value = part['thought_signature'];
    }
    final hasText = (part['text'] ?? '').toString().isNotEmpty;
    final hasInline =
        part['inlineData'] is Map ||
        part['inline_data'] is Map ||
        part['fileData'] is Map ||
        part['file_data'] is Map;
    if (hasText && key != null && textKey == null) {
      textKey = key;
      textValue = value;
    }
    if (hasInline && key != null && value != null) {
      images.add({'k': key, 'v': value});
    }
  }
  return buildGeminiThoughtSigComment(
    textKey: textKey,
    textValue: textValue,
    imageSigs: images,
  );
}

List<String> extractYouTubeUrls(String text) {
  final regex = RegExp(
    r'(https?://(?:www\.)?(?:youtube\.com/(?:watch\?v=|shorts/|embed/)|youtu\.be/)[a-zA-Z0-9_-]+(?:[?&][^\s<>()]*)?)',
    caseSensitive: false,
  );
  final result = <String>[];
  final seen = <String>{};
  for (final match in regex.allMatches(text)) {
    var url = (match.group(1) ?? '').trim();
    while (url.isNotEmpty && '.,;:!?)"]}'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isNotEmpty && seen.add(url)) result.add(url);
  }
  return result;
}

class ImageRef {
  final String kind; // 取值为 data、path 或 url。
  final String src;
  final String? mime;
  const ImageRef(this.kind, this.src, {this.mime});
}

class ParsedTextAndImages {
  final String text;
  final List<ImageRef> images;
  const ParsedTextAndImages(this.text, this.images);
}

String mimeForInternalMediaRef(InternalMediaRef ref) {
  final explicit = ref.mime?.trim() ?? '';
  if (explicit.isNotEmpty) return explicit;
  final path = ref.uri;
  if (path.startsWith('data:')) return mimeFromDataUrl(path);
  return mimeFromPath(path);
}

List<InternalMediaRef> supplementalMediaRefs({
  required dynamic internalRaw,
  List<String>? userPaths,
  bool includeUserPaths = false,
}) {
  final refs = List<InternalMediaRef>.of(parseInternalMediaRefs(internalRaw));
  if (!includeUserPaths || userPaths == null || userPaths.isEmpty) {
    return refs;
  }
  final seen = <String>{for (final ref in refs) ref.uri};
  for (final path in userPaths) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) continue;
    refs.add((uri: trimmed, mime: null, unavailable: false));
  }
  return refs;
}

Future<String?> tryEncodeBase64DataUrl(
  String path, {
  String? explicitMime,
}) async {
  final b64 = await tryEncodeBase64File(path, withPrefix: false);
  if (b64 == null) return null;
  final mime = (explicitMime != null && explicitMime.trim().isNotEmpty)
      ? explicitMime.trim()
      : mimeFromPath(path);
  return 'data:$mime;base64,$b64';
}

void logImageFallback({
  required String provider,
  required String model,
  required String reason,
}) {
  final message = 'provider=$provider model=$model reason=$reason';
  debugPrint('[ImageFallback] $message');
  FlutterLogger.log(message, tag: 'ImageFallback');
}

/// 部分 provider（例如 OpenRouter 的限流/审核）会在 2xx 流中以内嵌 `{"error": ...}` 帧报告失败。
/// 将其作为流错误抛出，避免截断输出被持久化为正常完成。
///
/// OpenRouter 文档中的流中失败帧会同时携带顶层 `error` 和非空 choices，不能因为存在候选项就忽略错误。
/// 正常分片没有 error，或只携带 null/空占位值，[_throwOnInBandStreamError] 会忽略后者。
void throwIfInBandStreamError(String data) {
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
    // `event: error` 帧中，Anthropic 风格把内容嵌在 error 下；Responses API 则直接放在帧上。
    final nested = decoded['error'];
    if (nested is Map && nested.isNotEmpty) {
      _throwOnInBandStreamError(nested);
    }
    _throwOnInBandStreamError(decoded);
  }
  if (type == 'response.failed' || type == 'response.incomplete') {
    // Responses API 的终止失败事件把错误嵌在 response 下。
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
    // 即使失败事件没有可解析的内容，也不能继续当作正常结束处理。
    throw HttpException('Provider error: $type');
  }
  _throwOnInBandStreamError(decoded['error']);
}

/// 当 [error] 携带 provider 错误内容时抛出；正常分片的 null/空占位值不处理。
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
