export '../models/model_types.dart';

import 'dart:convert';
import 'dart:io' show HttpException;
import 'package:http/http.dart' as http;
import 'settings_provider.dart';
import '../services/network/dio_http_client.dart';
import '../services/api_key_manager.dart';
import '../services/api/provider_request_headers.dart';
import '../services/model_override_payload_parser.dart';
import '../services/custom_request_merger.dart';
import '../services/api/google_service_account_auth.dart';
import '../models/model_types.dart';

class ModelRegistry {
  // 更新模型分组以反映新系列
  // 支持视觉的模型（文本 + 图像输入）。
  // Qwen 视觉判断是有意且精确的（见 [_isQwenVisionModel]）：并非
  // 每个 Qwen 3.7 Max id 都是多模态。
  static final RegExp vision = RegExp(
    // GPT 系列，包括 4o、4.1、5（排除 gpt-5-chat），以及 OpenAI o* 系列
    r'(gpt-4o|gpt-4\.1|gpt-5(?!-chat)|o\d|gemini|claude|kimi-k2([-.])(?:5|6|7)|kimi-k3(?:$|[/_:@.-])|muse-spark-1\.1(?:$|[/_:@.-])|doubao.+(?:1([-.])(?:6|8)|seed-2|seed-evolving)|grok-4|step-3|intern-s1|minimax-m3(?:$|[/_:@])|mimo-v2(?:-omni(?:$|[/_:@])|\.5(?:$|[/_:@]))|sensenova-6\.7-flash-lite|deepseek.+vision|laguna)',
    caseSensitive: false,
  );
  // 可使用工具的模型
  static final RegExp tool = RegExp(
    (r'(gpt-4o|gpt-4\.1|gpt-oss|gpt-5(?!-chat)|o\d|'
            r'gemini|claude|'
            r'qwen-?3|doubao.+(?:1([-.])(?:6|8)|seed-2|seed-evolving)|grok-4|kimi-k2|'
            r'kimi-k3(?:$|[/_:@.-])|muse-spark-1\.1(?:$|[/_:@.-])|'
            r'step-3|intern-s1|glm-4([-.])(?:5|6|7)|glm-5|minimax-(?:m2|m3)|'
            r'deepseek-(?:r1|v3|chat|v3\.1|v3\.2|v4)|'
            r'deepseek-reasoner|'
            r'mimo-v2|'
            r'sensenova-6\.7-flash-lite|laguna'
            r')')
        .replaceAll(' ', ''),
    caseSensitive: false,
  );
  static final RegExp reasoning = RegExp(
    (r'(gpt-oss|gpt-5(?!-chat)|o\d|'
            r'gemini-(?:2\.5|3).*|gemini-(?:flash-latest|pro-latest)|'
            r'gemini-3-pro-image-preview|'
            r'gemma[-_]?4|'
            r'claude|'
            r'qwen-?3|doubao.+(?:1([-.])(?:6|8)|seed-2|seed-evolving)|grok-4|kimi-k2|'
            r'kimi-k3(?:$|[/_:@.-])|muse-spark-1\.1(?:$|[/_:@.-])|'
            r'step-3|intern-s1|glm-4([-.])(?:5|6|7)|glm-5|minimax-(?:m2|m3)|'
            r'deepseek-(?:r1|v3\.1|v3\.2|v4)|'
            r'deepseek-reasoner|'
            r'mimo-v2|laguna'
            r')')
        .replaceAll(' ', ''),
    caseSensitive: false,
  );

  /// 精确的 Qwen 视觉矩阵：
  /// - `qwen3.5*` (existing)
  /// - `qwen3.7-plus` / `qwen3.7-flash`（+ 快照）
  /// - 仅限 vision Max 快照 `qwen3.7-max-2026-06-08` 及之后
  /// - `qwen3.8-max`（+ 快照）
  /// 纯文本 / 更早的 `qwen3.7-max` 文本型 SKU 被有意排除。
  static bool _isQwenVisionModel(String id) {
    final lower = id.toLowerCase();
    if (RegExp(r'qwen-?3([-.])5').hasMatch(lower)) return true;
    if (RegExp(r'qwen-?3([-.])7-(?:plus|flash)').hasMatch(lower)) {
      return true;
    }
    if (RegExp(r'qwen-?3([-.])8-max').hasMatch(lower)) return true;
    final maxSnap = RegExp(
      r'qwen-?3([-.])7-max-(\d{4}-\d{2}-\d{2})',
    ).firstMatch(lower);
    if (maxSnap == null) return false;
    final date = DateTime.tryParse(maxSnap.group(2)!);
    if (date == null) return false;
    return !date.isBefore(DateTime(2026, 6, 8));
  }

  static bool isLikelyEmbeddingId(String rawId) {
    final id = rawId.toLowerCase();
    return id.contains('embedding') ||
        RegExp(r'(^|[-_/])embed(?:dings?)?([-.]|$)').hasMatch(id);
  }

  static bool _isGemini35Flash(String id) {
    return RegExp(
      r'(^|[/:_-])gemini-3\.5-flash([._:@/-]|$)',
      caseSensitive: false,
    ).hasMatch(id);
  }

  static ModelInfo infer(ModelInfo base) {
    final id = base.id.toLowerCase();
    final inMods = <Modality>[...base.input];
    final outMods = <Modality>[...base.output];
    final ab = <ModelAbility>[...base.abilities];
    final bool inferEmbeddingById = isLikelyEmbeddingId(id);
    if (base.type == ModelType.embedding || inferEmbeddingById) {
      if (!inMods.contains(Modality.text)) inMods.add(Modality.text);
      outMods
        ..clear()
        ..add(Modality.text);
      ab.clear();
      return base.copyWith(
        type: ModelType.embedding,
        input: inMods,
        output: outMods,
        abilities: ab,
      );
    }
    // 如果模型 id 包含 'image'，则将其视为图像模型：
    // - 输入和输出都包含图像
    // - 不具备工具或推理能力
    if (id.contains('image')) {
      if (!inMods.contains(Modality.image)) inMods.add(Modality.image);
      if (!outMods.contains(Modality.image)) outMods.add(Modality.image);
      ab.removeWhere(
        (x) => x == ModelAbility.tool || x == ModelAbility.reasoning,
      );
      return base.copyWith(input: inMods, output: outMods, abilities: ab);
    }
    if (_isGemini35Flash(id)) {
      if (!inMods.contains(Modality.image)) inMods.add(Modality.image);
      outMods
        ..clear()
        ..add(Modality.text);
      if (!ab.contains(ModelAbility.tool)) ab.add(ModelAbility.tool);
      if (!ab.contains(ModelAbility.reasoning)) {
        ab.add(ModelAbility.reasoning);
      }
      return base.copyWith(input: inMods, output: outMods, abilities: ab);
    }
    if (vision.hasMatch(id) || _isQwenVisionModel(id)) {
      if (!inMods.contains(Modality.image)) inMods.add(Modality.image);
    }
    if (tool.hasMatch(id) && !ab.contains(ModelAbility.tool)) {
      ab.add(ModelAbility.tool);
    }
    if (reasoning.hasMatch(id) && !ab.contains(ModelAbility.reasoning)) {
      ab.add(ModelAbility.reasoning);
    }
    return base.copyWith(input: inMods, output: outMods, abilities: ab);
  }
}

abstract class BaseProvider {
  Future<List<ModelInfo>> listModels(ProviderConfig cfg);
}

class _Http {
  static http.Client clientFor(ProviderConfig cfg) {
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
      );
    }
    return DioHttpClient();
  }
}

String _appendPath(String baseUrl, String path) {
  final base = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  return '$base/$path';
}

String _responseErrorSummary(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return 'empty response body';
  const maxLength = 4096;
  if (trimmed.length <= maxLength) return trimmed;
  return '${trimmed.substring(0, maxLength)}...';
}

Never _throwForNon2xx(http.Response response) {
  throw HttpException(
    'HTTP ${response.statusCode}: ${_responseErrorSummary(response.body)}',
  );
}

bool _isDeepSeekProvider(ProviderConfig cfg) {
  return ProviderConfig.isDeepSeek(cfg);
}

Uri _modelListUri(ProviderConfig cfg, {required bool anthropic}) {
  if (anthropic && _isDeepSeekProvider(cfg)) {
    final baseUri = Uri.parse(cfg.baseUrl.trim());
    return baseUri.replace(path: '/models', query: null, fragment: '');
  }
  return Uri.parse(_appendPath(cfg.baseUrl, 'models'));
}

class OpenAIProvider extends BaseProvider {
  @override
  Future<List<ModelInfo>> listModels(ProviderConfig cfg) async {
    final key = ProviderManager._effectiveApiKey(cfg);
    final client = _Http.clientFor(cfg);
    try {
      final uri = _modelListUri(cfg, anthropic: false);
      final headers = <String, String>{};
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
      final res = await client.get(uri, headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = (jsonDecode(res.body)['data'] as List?) ?? [];
        return [
          for (final e in data)
            if (e is Map && e['id'] is String)
              ModelRegistry.infer(
                ModelInfo(
                  id: e['id'] as String,
                  displayName: e['id'] as String,
                ),
              ),
        ];
      }
      _throwForNon2xx(res);
    } finally {
      client.close();
    }
  }
}

class ClaudeProvider extends BaseProvider {
  static const String anthropicVersion = '2023-06-01';
  @override
  Future<List<ModelInfo>> listModels(ProviderConfig cfg) async {
    final key = ProviderManager._effectiveApiKey(cfg);
    final client = _Http.clientFor(cfg);
    try {
      final isDeepSeek = _isDeepSeekProvider(cfg);
      final uri = _modelListUri(cfg, anthropic: true);
      final headers = <String, String>{};
      if (isDeepSeek) {
        if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
      } else {
        headers['anthropic-version'] = anthropicVersion;
        if (key.isNotEmpty) headers['x-api-key'] = key;
      }
      final res = await client.get(uri, headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final obj = jsonDecode(res.body) as Map<String, dynamic>;
        final data = (obj['data'] as List?) ?? [];
        return [
          for (final e in data)
            if (e is Map && e['id'] is String)
              ModelRegistry.infer(
                ModelInfo(
                  id: e['id'] as String,
                  displayName:
                      (e['display_name'] as String?) ?? (e['id'] as String),
                ),
              ),
        ];
      }
      _throwForNon2xx(res);
    } finally {
      client.close();
    }
  }
}

class GoogleProvider extends BaseProvider {
  String _buildUrl(ProviderConfig cfg) {
    if (cfg.vertexAI == true &&
        (cfg.location?.isNotEmpty == true) &&
        (cfg.projectId?.isNotEmpty == true)) {
      final loc = cfg.location!;
      final proj = cfg.projectId!;
      return 'https://aiplatform.googleapis.com/v1/projects/$proj/locations/$loc/publishers/google/models';
    }
    final base = cfg.baseUrl.endsWith('/')
        ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
        : cfg.baseUrl;
    return '$base/models';
  }

  @override
  Future<List<ModelInfo>> listModels(ProviderConfig cfg) async {
    final client = _Http.clientFor(cfg);
    try {
      final url = _buildUrl(cfg);
      final headers = <String, String>{};
      if (cfg.vertexAI == true) {
        final jsonStr = (cfg.serviceAccountJson ?? '').trim();
        if (jsonStr.isNotEmpty) {
          try {
            final token = await GoogleServiceAccountAuth.getAccessTokenFromJson(
              jsonStr,
            );
            headers['Authorization'] = 'Bearer $token';
            final proj = (cfg.projectId ?? '').trim();
            if (proj.isNotEmpty) headers['X-Goog-User-Project'] = proj;
          } catch (_) {}
        } else {
          final key = ProviderManager._effectiveApiKey(cfg);
          if (key.isNotEmpty) {
            // 回退：如果用户粘贴了 apiKey，则将其视为 bearer token
            headers['Authorization'] = 'Bearer $key';
          }
        }
      } else {
        final key = ProviderManager._effectiveApiKey(cfg);
        if (key.isNotEmpty) {
          headers['x-goog-api-key'] = key;
        }
      }
      final out = <ModelInfo>[];
      final res = await client.get(Uri.parse(url), headers: headers);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _throwForNon2xx(res);
      }
      final obj = jsonDecode(res.body) as Map<String, dynamic>;
      final arr = (obj['models'] as List?) ?? [];
      for (final e in arr) {
        if (e is Map) {
          final name = (e['name'] as String?) ?? '';
          final id = name.startsWith('models/')
              ? name.substring('models/'.length)
              : name;
          final displayName = (e['displayName'] as String?) ?? id;
          final methods =
              (e['supportedGenerationMethods'] as List?)
                  ?.map((m) => m.toString())
                  .toSet() ??
              {};
          if (!(methods.contains('generateContent') ||
              methods.contains('embedContent'))) {
            continue;
          }
          out.add(
            ModelRegistry.infer(
              ModelInfo(
                id: id,
                displayName: displayName,
                type: methods.contains('generateContent')
                    ? ModelType.chat
                    : ModelType.embedding,
              ),
            ),
          );
        }
      }

      // 如果是 Vertex AI，则补充已知的 Anthropic 模型
      // 由于 Google listModels API 在 publishers/google 下通常只返回 Gemini 模型，
      // 为方便起见，我们手动注入已知受支持的 Claude 模型。
      if (cfg.vertexAI == true) {
        final knownClaude = [
          'claude-fable-5',
          'claude-opus-5',
          'claude-opus-4-8',
          'claude-opus-4-7',
          'claude-opus-4-6',
          'claude-opus-4-5@20251101',
          'claude-opus-4-1@20250805',
          'claude-opus-4@20250514',
          'claude-sonnet-5',
          'claude-sonnet-4-6',
          'claude-sonnet-4-5@20250929',
          'claude-sonnet-4@20250514',
          'claude-3-7-sonnet@20250219',
          'claude-3-5-sonnet-v2@20241022',
          'claude-haiku-4-5@20251001',
          'claude-3-5-haiku@20241022',
          'claude-3-5-sonnet@20240620',
          'claude-3-opus@20240229',
          'claude-3-haiku@20240307',
        ];
        for (final id in knownClaude) {
          if (!out.any((m) => m.id == id)) {
            out.add(ModelRegistry.infer(ModelInfo(id: id, displayName: id)));
          }
        }
      }
      return out;
    } finally {
      client.close();
    }
  }
}

class ProviderManager {
  static String _effectiveApiKey(ProviderConfig cfg) {
    try {
      if (cfg.multiKeyEnabled == true && (cfg.apiKeys?.isNotEmpty == true)) {
        final sel = ApiKeyManager().selectForProvider(cfg);
        if (sel.key != null) return sel.key!.key;
      }
    } catch (_) {}
    return cfg.apiKey;
  }

  // 每模型覆盖辅助方法（逻辑与 ChatApiService 重复）
  static Map<String, dynamic> _modelOverride(
    ProviderConfig cfg,
    String modelId,
  ) {
    return ModelOverridePayloadParser.modelOverride(
      cfg.modelOverrides,
      modelId,
    );
  }

  static Map<String, String> _customHeaders(
    ProviderConfig cfg,
    String modelId,
  ) {
    final ov = _modelOverride(cfg, modelId);
    return CustomRequestMerger.mergeHeaders(
      providerAutomatic: providerDefaultHeaders(cfg),
      provider: ModelOverridePayloadParser.customHeadersFromRows(
        cfg.customHeaders,
      ),
      model: ModelOverridePayloadParser.customHeaders(ov),
    );
  }

  static Map<String, dynamic> _customBody(ProviderConfig cfg, String modelId) {
    final ov = _modelOverride(cfg, modelId);
    return CustomRequestMerger.mergeBody(
      providerRows: cfg.customBody,
      model: ModelOverridePayloadParser.customBody(ov),
    );
  }

  static BaseProvider forConfig(ProviderConfig cfg) {
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    switch (kind) {
      case ProviderKind.google:
        return GoogleProvider();
      case ProviderKind.claude:
        return ClaudeProvider();
      case ProviderKind.openai:
        return OpenAIProvider();
    }
  }

  static Future<List<ModelInfo>> listModels(ProviderConfig cfg) {
    return forConfig(cfg).listModels(cfg);
  }

  static Future<void> testConnection(
    ProviderConfig cfg,
    String modelId, {
    bool useStream = false,
  }) async {
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    final client = _Http.clientFor(cfg);
    try {
      if (kind == ProviderKind.openai) {
        final base = cfg.baseUrl.endsWith('/')
            ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
            : cfg.baseUrl;
        final path = (cfg.useResponseApi == true)
            ? '/responses'
            : (cfg.chatPath ?? '/chat/completions');
        final url = Uri.parse('$base$path');
        final ov = _modelOverride(cfg, modelId);
        String upstreamId = modelId;
        try {
          final raw = (ov['apiModelId'] ?? ov['api_model_id'])
              ?.toString()
              .trim();
          if (raw != null && raw.isNotEmpty) upstreamId = raw;
        } catch (_) {}
        final Map<String, dynamic> body = cfg.useResponseApi == true
            ? <String, dynamic>{
                'model': upstreamId,
                'input': [
                  {'role': 'user', 'content': 'hello'},
                ],
                if (useStream) 'stream': true,
              }
            : <String, dynamic>{
                'model': upstreamId,
                'messages': [
                  {'role': 'user', 'content': 'hello'},
                ],
                if (useStream) 'stream': true,
              };
        // 合并自定义 body 覆盖项
        final extra = _customBody(cfg, modelId);
        if (extra.isNotEmpty) body.addAll(extra);
        // 合并自定义 headers 覆盖项
        final apiKey = _effectiveApiKey(cfg);
        final headers = <String, String>{
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        };
        headers.addAll(_customHeaders(cfg, modelId));
        final res = await client.post(
          url,
          headers: headers,
          body: jsonEncode(body),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('HTTP ${res.statusCode}: ${res.body}');
        }
        // 对于流式请求，验证响应包含 SSE 数据
        if (useStream) {
          final contentType = res.headers['content-type'] ?? '';
          if (!contentType.contains('text/event-stream') && res.body.isEmpty) {
            throw HttpException('Stream response expected but not received');
          }
        }
        return;
      } else if (kind == ProviderKind.claude) {
        final base = cfg.baseUrl.endsWith('/')
            ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
            : cfg.baseUrl;
        final url = Uri.parse('$base/messages');
        final ov = _modelOverride(cfg, modelId);
        String upstreamId = modelId;
        try {
          final raw = (ov['apiModelId'] ?? ov['api_model_id'])
              ?.toString()
              .trim();
          if (raw != null && raw.isNotEmpty) upstreamId = raw;
        } catch (_) {}
        final body = <String, dynamic>{
          'model': upstreamId,
          'max_tokens': 8,
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
          if (useStream) 'stream': true,
        };
        final extra = _customBody(cfg, modelId);
        if (extra.isNotEmpty) body.addAll(extra);
        final headers = <String, String>{
          'x-api-key': _effectiveApiKey(cfg),
          'anthropic-version': ClaudeProvider.anthropicVersion,
          'Content-Type': 'application/json',
        };
        headers.addAll(_customHeaders(cfg, modelId));
        final res = await client.post(
          url,
          headers: headers,
          body: jsonEncode(body),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('HTTP ${res.statusCode}: ${res.body}');
        }
        // 对于流式请求，验证响应包含 SSE 数据
        if (useStream) {
          final contentType = res.headers['content-type'] ?? '';
          if (!contentType.contains('text/event-stream') && res.body.isEmpty) {
            throw HttpException('Stream response expected but not received');
          }
        }
        return;
      } else if (kind == ProviderKind.google) {
        // Generative Language API（默认）或当 vertexAI == true 时使用 Vertex AI
        final ov = _modelOverride(cfg, modelId);
        // 当存在时，为此逻辑 key 解析上游/API 模型 id。
        String upstreamId = modelId;
        try {
          final raw = (ov['apiModelId'] ?? ov['api_model_id'])
              ?.toString()
              .trim();
          if (raw != null && raw.isNotEmpty) upstreamId = raw;
        } catch (_) {}

        String url;
        final endpoint = useStream
            ? 'streamGenerateContent'
            : 'generateContent';
        final bool isVertex =
            cfg.vertexAI == true &&
            (cfg.location?.isNotEmpty == true) &&
            (cfg.projectId?.isNotEmpty == true);
        final bool isVertexClaude =
            isVertex && upstreamId.toLowerCase().startsWith('claude-');
        if (isVertex) {
          final loc = cfg.location!;
          final proj = cfg.projectId!;
          if (isVertexClaude) {
            final ep = useStream ? 'streamRawPredict' : 'rawPredict';
            url =
                'https://aiplatform.googleapis.com/v1/projects/$proj/locations/$loc/publishers/anthropic/models/$upstreamId:$ep';
          } else {
            url =
                'https://aiplatform.googleapis.com/v1/projects/$proj/locations/$loc/publishers/google/models/$upstreamId:$endpoint';
          }
        } else {
          final base = cfg.baseUrl.endsWith('/')
              ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
              : cfg.baseUrl;
          url = '$base/models/$upstreamId:$endpoint';
        }
        // 确定模型是否输出图像（覆盖项优先；否则推断）
        bool wantsImageOutput = false;
        if (ov['output'] is List) {
          final outList = (ov['output'] as List)
              .map((e) => e.toString().toLowerCase())
              .toList();
          wantsImageOutput = outList.contains('image');
        } else {
          wantsImageOutput = ModelRegistry.infer(
            ModelInfo(id: upstreamId, displayName: upstreamId),
          ).output.contains(Modality.image);
        }
        final Map<String, dynamic> body = isVertexClaude
            ? <String, dynamic>{
                'anthropic_version': 'vertex-2023-10-16',
                'messages': [
                  {'role': 'user', 'content': 'hello'},
                ],
                'max_tokens': 32,
                if (useStream) 'stream': true,
              }
            : <String, dynamic>{
                'contents': [
                  {
                    'role': 'user',
                    'parts': [
                      {'text': 'hello'},
                    ],
                  },
                ],
                if (wantsImageOutput)
                  'generationConfig': {
                    'responseModalities': ['TEXT', 'IMAGE'],
                  },
              };
        final headers = <String, String>{'Content-Type': 'application/json'};
        final effectiveKey = _effectiveApiKey(cfg);
        if (cfg.vertexAI == true) {
          final jsonStr = (cfg.serviceAccountJson ?? '').trim();
          if (jsonStr.isNotEmpty) {
            try {
              final token =
                  await GoogleServiceAccountAuth.getAccessTokenFromJson(
                    jsonStr,
                  );
              headers['Authorization'] = 'Bearer $token';
            } catch (_) {}
          } else if (effectiveKey.isNotEmpty) {
            headers['Authorization'] = 'Bearer $effectiveKey';
          }
        } else {
          if (effectiveKey.isNotEmpty) {
            headers['x-goog-api-key'] = effectiveKey;
          }
        }
        headers.addAll(_customHeaders(cfg, modelId));
        final extra = _customBody(cfg, modelId);
        if (extra.isNotEmpty) body.addAll(extra);
        final res = await client.post(
          Uri.parse(url),
          headers: headers,
          body: jsonEncode(body),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('HTTP ${res.statusCode}: ${res.body}');
        }
        // 对于流式请求，验证响应不为空
        if (useStream && res.body.isEmpty) {
          throw HttpException('Stream response expected but not received');
        }
        return;
      }
    } finally {
      client.close();
    }
  }
}
