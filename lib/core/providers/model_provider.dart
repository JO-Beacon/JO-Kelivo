import '../services/auth/provider_oauth_service.dart';
export '../models/model_spec.dart';

import 'dart:convert';
import 'dart:io' show HttpException;
import 'package:http/http.dart' as http;
import 'settings_provider.dart';
import '../services/network/provider_http_client.dart';
import '../services/api_key_manager.dart';
import '../services/api/provider_request_headers.dart';
import '../services/model_override_payload_parser.dart';
import '../services/model_spec/model_spec_resolver.dart';
import '../services/custom_request_merger.dart';
import '../services/api/google_service_account_auth.dart';
import '../services/api/embedding/embedding_api_service.dart';
import '../models/model_spec.dart';

abstract class BaseProvider {
  Future<List<ModelSpec>> listModels(ProviderConfig cfg);
}

class _Http {
  /// 拉取模型列表时把供应商的自定义请求头也带上。
  ///
  /// 只并供应商一层：模型级覆盖需要具体的模型 id，
  /// 而列模型时还没有可选的模型，因此不参与合并。
  static Map<String, String> modelListHeaders(
    ProviderConfig cfg,
    Map<String, String> base,
  ) {
    return CustomRequestMerger.mergeHeaders(
      base: base,
      provider: ModelOverridePayloadParser.customHeadersFromRows(
        cfg.customHeaders,
      ),
    );
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
  Future<List<ModelSpec>> listModels(ProviderConfig cfg) async {
    final key = ProviderManager._effectiveApiKey(cfg);
    final client = providerHttpClient(cfg);
    try {
      final uri = _modelListUri(cfg, anthropic: false);
      final headers = <String, String>{};
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
      final res = await client.get(
        uri,
        headers: _Http.modelListHeaders(cfg, headers),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = (jsonDecode(res.body)['data'] as List?) ?? [];
        return [
          for (final e in data)
            if (e is Map && e['id'] is String)
              ModelSpecResolver.instance
                  .resolve(
                    cfg,
                    e['id'] as String,
                    displayName: e['id'] as String,
                  )
                  .spec,
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
  Future<List<ModelSpec>> listModels(ProviderConfig cfg) async {
    final key = ProviderManager._effectiveApiKey(cfg);
    final client = providerHttpClient(cfg);
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
      final res = await client.get(
        uri,
        headers: _Http.modelListHeaders(cfg, headers),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final obj = jsonDecode(res.body) as Map<String, dynamic>;
        final data = (obj['data'] as List?) ?? [];
        return [
          for (final e in data)
            if (e is Map && e['id'] is String)
              ModelSpecResolver.instance
                  .resolve(
                    cfg,
                    e['id'] as String,
                    displayName:
                        (e['display_name'] as String?) ?? (e['id'] as String),
                  )
                  .spec,
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
  Future<List<ModelSpec>> listModels(ProviderConfig cfg) async {
    final client = providerHttpClient(cfg);
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
      final out = <ModelSpec>[];
      final res = await client.get(
        Uri.parse(url),
        headers: _Http.modelListHeaders(cfg, headers),
      );
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
            ModelSpecResolver.instance
                .resolve(cfg, id, displayName: displayName)
                .spec,
          );
        }
      }

      // 如果是 Vertex AI，则补充已知的 Anthropic 模型
      // 由于 Google listModels API 在 publishers/google 下通常只返回 Gemini 模型，
      // 为方便起见，我们手动注入已知受支持的 Claude 模型。
      if (cfg.vertexAI == true) {
        final knownClaude = [
          'claude-fable-5-1',
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
            out.add(
              ModelSpecResolver.instance.resolve(cfg, id, displayName: id).spec,
            );
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

  static Future<List<ModelSpec>> listModels(ProviderConfig cfg) {
    // 账号登录的供应商由登录服务负责取模型目录。
    if (cfg.isOAuth) return ProviderOAuthService.instance.models(cfg);
    return forConfig(cfg).listModels(cfg);
  }

  static Future<void> testConnection(
    ProviderConfig cfg,
    String modelId, {
    bool useStream = false,
  }) async {
    // 向量模型没有聊天接口，连接测试改走供应商的 embeddings 端点。
    final embeddingOverride = _modelOverride(cfg, modelId);
    final modelType =
        ModelSpecOverride.fromJson(embeddingOverride).type ??
        ModelSpecResolver.instance.spec(cfg, modelId).type;
    if (modelType == ModelType.embedding) {
      await EmbeddingApiService.embed(
        config: cfg,
        modelId: modelId,
        inputs: const ['hello'],
      );
      return;
    }
    // 账号登录：先确保令牌有效，再按供应商约束调整请求形态。
    cfg = await ProviderOAuthService.instance.resolve(cfg);
    if (cfg.oauthProvider == OAuthProvider.chatgpt) useStream = true;
    if (cfg.oauthProvider == OAuthProvider.kimi &&
        (cfg.modelOverrides[modelId] as Map?)?['oauthProtocol'] ==
            'anthropic') {
      cfg = cfg.copyWith(providerType: ProviderKind.claude);
    }
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    final client = ProviderOAuthService.instance.authenticatedClient(
      providerHttpClient(cfg),
      cfg,
    );
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
          ...?providerSessionHeaders(cfg),
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
          wantsImageOutput = ModelSpecResolver.instance
              .spec(cfg, upstreamId)
              .output
              .contains(Modality.image);
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
