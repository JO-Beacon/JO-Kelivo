import '../../providers/settings_provider.dart';

/// 用于 API 集成的内置工具名称常量。
/// 请使用这些常量而不是原始字符串，以确保一致性。
abstract class BuiltInToolNames {
  // 通用
  static const search = 'search';

  // Google/Gemini 专用
  static const urlContext = 'url_context';
  static const codeExecution = 'code_execution';
  static const youtube = 'youtube';

  // OpenAI 专用
  static const codeInterpreter = 'code_interpreter';
  static const imageGeneration = 'image_generation';

  /// 将工具名称规范化为 snake_case 格式。
  /// 为向后兼容处理旧版 camelCase 格式。
  static String normalize(String name) {
    final lower = name.trim().toLowerCase();
    switch (lower) {
      case 'urlcontext':
        return urlContext;
      case 'codeexecution':
        return codeExecution;
      case 'codeinterpreter':
        return codeInterpreter;
      case 'imagegeneration':
        return imageGeneration;
      default:
        return lower;
    }
  }

  /// 从持久化设置中解析工具名称并规范化。
  ///
  /// 防御性地接受旧版/未知类型（例如 null、非可迭代类型）。
  /// 即使为空也返回可变的 Set，以避免只读修改导致崩溃。
  static Set<String> parseAndNormalize(Object? raw) {
    if (raw == null) return <String>{};
    if (raw is! Iterable) return <String>{};
    final out = <String>{};
    for (final e in raw) {
      final v = normalize(e.toString());
      if (v.isNotEmpty) out.add(v);
    }
    return out;
  }

  /// 从每个模型的覆盖映射中解析内置工具。
  ///
  /// 支持：
  /// - `builtInTools`：`List<String>`（当前格式）
  /// - `built_in_tools`：`List<String>`（旧版格式）
  /// - `tools`：`Map<String, bool>`（旧版布尔标志，例如 `urlContext=true`）
  static Set<String> parseFromOverride(Object? rawOverride) {
    final ov = rawOverride is Map ? rawOverride : null;
    final builtInSet = parseAndNormalize(
      ov?['builtInTools'] ?? ov?['built_in_tools'],
    );

    final legacyTools = ov?['tools'];
    if (legacyTools is Map) {
      for (final entry in legacyTools.entries) {
        if (entry.value == true) {
          final v = normalize(entry.key.toString());
          if (v.isNotEmpty) builtInSet.add(v);
        }
      }
    }
    return builtInSet;
  }

  /// 为持久化工具列表提供稳定排序（使 UI 差异最小化）。
  static List<String> orderedForStorage(Iterable<String> tools) {
    final remaining = Set<String>.from(tools);
    const preferredOrder = <String>[
      BuiltInToolNames.search,
      BuiltInToolNames.urlContext,
      BuiltInToolNames.codeExecution,
      BuiltInToolNames.youtube,
      BuiltInToolNames.codeInterpreter,
      BuiltInToolNames.imageGeneration,
    ];
    final out = <String>[
      for (final k in preferredOrder)
        if (remaining.remove(k)) k,
      ...remaining,
    ];
    return out;
  }

  /// 解析实际将发送给供应商的上游模型 id。
  static String effectiveModelId({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    final fallback = (modelId ?? '').trim();
    if (cfg == null || fallback.isEmpty) return fallback;
    final rawOverride = cfg.modelOverrides[fallback];
    final ov = rawOverride is Map ? rawOverride : null;
    final rawApiModelId = (ov?['apiModelId'] ?? ov?['api_model_id'])
        ?.toString()
        .trim();
    if (rawApiModelId != null && rawApiModelId.isNotEmpty) {
      return rawApiModelId;
    }
    return fallback;
  }
}

/// 用于检查特定提供商内置工具支持的实用类。
abstract class BuiltInToolsHelper {
  static const String _dashScopeHost = 'dashscope.aliyuncs.com';

  static bool _isDashScopeHost(String host) {
    return host == _dashScopeHost;
  }

  static String _normalizedModelId(String? modelId) {
    return modelId?.trim().toLowerCase() ?? '';
  }

  static DateTime? _snapshotDate(String normalizedModelId) {
    final m = RegExp(r'-(\d{4}-\d{2}-\d{2})$').firstMatch(normalizedModelId);
    if (m == null) return null;
    try {
      return DateTime.parse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  static bool _matchesExactOrSnapshot(
    String normalizedModelId, {
    required String alias,
    String? minSnapshot,
    List<String> extraExact = const <String>[],
  }) {
    if (normalizedModelId == alias) return true;
    if (extraExact.contains(normalizedModelId)) return true;
    if (minSnapshot == null || !normalizedModelId.startsWith('$alias-')) {
      return false;
    }
    final date = _snapshotDate(normalizedModelId);
    if (date == null) return false;
    return !date.isBefore(DateTime.parse(minSnapshot));
  }

  static int? _readIntish(Object? raw) {
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  static bool isDashScopeProvider(ProviderConfig? cfg) {
    if (cfg == null) return false;
    final host = Uri.tryParse(cfg.baseUrl)?.host.toLowerCase() ?? '';
    return _isDashScopeHost(host);
  }

  static bool isGrokModel(String? modelId) {
    return _normalizedModelId(modelId).contains('grok');
  }

  static bool isClaudeBuiltInSearchSupportedModel(String? modelId) {
    final normalized = _normalizedModelId(modelId);
    if (normalized.contains('mythos')) return true;
    const supported = <String>{
      'claude-fable-5',
      'claude-opus-5',
      'claude-opus-4-8',
      'claude-opus-4-7',
      'claude-opus-4-6',
      'claude-sonnet-5',
      'claude-sonnet-4-5-20250929',
      'claude-sonnet-4-20250514',
      'claude-3-7-sonnet-20250219',
      'claude-haiku-4-5-20251001',
      'claude-3-5-haiku-latest',
      'claude-sonnet-4-6',
      'claude-opus-4-1-20250805',
      'claude-opus-4-20250514',
    };
    return supported.contains(normalized);
  }

  static bool isClaudeDynamicWebSearchSupportedModel(String? modelId) {
    final normalized = _normalizedModelId(modelId);
    return normalized.contains('mythos') ||
        normalized == 'claude-fable-5' ||
        normalized == 'claude-opus-5' ||
        normalized == 'claude-opus-4-8' ||
        normalized == 'claude-opus-4-7' ||
        normalized == 'claude-opus-4-6' ||
        normalized == 'claude-sonnet-5' ||
        normalized == 'claude-sonnet-4-6';
  }

  static bool isOpenAIResponsesBuiltInSearchSupportedModel(String? modelId) {
    final m = _normalizedModelId(modelId);
    return m.startsWith('gpt-4o') ||
        m.startsWith('gpt-4.1') ||
        m.startsWith('o4-mini') ||
        m == 'o3' ||
        m.startsWith('o3-') ||
        m.startsWith('gpt-5');
  }

  static bool isOpenRouterProvider(ProviderConfig? cfg) {
    if (cfg == null) return false;
    final host = Uri.tryParse(cfg.baseUrl)?.host.toLowerCase() ?? '';
    final providerId = cfg.id.toLowerCase();
    return host.contains('openrouter.ai') || providerId.contains('openrouter');
  }

  static bool isDeepSeekProvider(ProviderConfig? cfg) {
    if (cfg == null) return false;
    final host = Uri.tryParse(cfg.baseUrl)?.host.toLowerCase() ?? '';
    final providerId = cfg.id.toLowerCase();
    final providerName = cfg.name.toLowerCase();
    return host.contains('deepseek.com') ||
        providerId.contains('deepseek') ||
        providerName.contains('deepseek');
  }

  static bool isDashScopeChatBuiltInSearchSupportedModel(String? modelId) {
    final m = _normalizedModelId(modelId);
    return _matchesExactOrSnapshot(
          m,
          alias: 'qwen-max',
          minSnapshot: '2024-09-19',
          extraExact: const <String>['qwen-max-latest'],
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3-max',
          minSnapshot: '2025-09-23',
          extraExact: const <String>['qwen3-max-preview'],
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen-plus',
          minSnapshot: '2025-07-14',
          extraExact: const <String>['qwen-plus-latest'],
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3.5-plus',
          minSnapshot: '2026-02-15',
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen-flash',
          minSnapshot: '2025-07-28',
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3.5-flash',
          minSnapshot: '2026-02-23',
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen-turbo',
          minSnapshot: '2025-07-15',
          extraExact: const <String>['qwen-turbo-latest'],
        ) ||
        m == 'qwq-plus';
  }

  static bool isDashScopeResponsesBuiltInSearchSupportedModel(String? modelId) {
    final m = _normalizedModelId(modelId);
    return _matchesExactOrSnapshot(
          m,
          alias: 'qwen3.6-plus',
          minSnapshot: '2026-04-02',
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3.6-flash',
          minSnapshot: '2026-04-16',
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3.5-plus',
          minSnapshot: '2026-02-15',
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3.5-flash',
          minSnapshot: '2026-02-23',
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3-max',
          minSnapshot: '2026-01-23',
        ) ||
        // 官方 Responses web_search 白名单新增：
        // Qwen3.7 Max / Plus。请勿猜测式启用 3.7 Flash。
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3.7-max',
          minSnapshot: '2026-05-17',
          extraExact: const <String>['qwen3.7-max-preview'],
        ) ||
        _matchesExactOrSnapshot(
          m,
          alias: 'qwen3.7-plus',
          minSnapshot: '2026-05-26',
        ) ||
        // Token Plan / Responses 仅用于预览 SKU。普通的
        // `qwen3.8-max` 在未进行 Key 验证时有意不开放。
        m == 'qwen3.8-max-preview';
  }

  static bool isArkProvider(ProviderConfig? cfg) {
    if (cfg == null) return false;
    final host = Uri.tryParse(cfg.baseUrl)?.host.toLowerCase() ?? '';
    final providerId = cfg.id.toLowerCase();
    final providerName = cfg.name.toLowerCase();
    return host.contains('ark.cn-beijing.volces.com') ||
        host.contains('volces.com') ||
        ((host.contains('ark') || host.contains('volc')) &&
            (providerId.contains('doubao') ||
                providerId.contains('volc') ||
                providerId.contains('ark') ||
                providerName.contains('doubao') ||
                providerName.contains('火山') ||
                providerName.contains('方舟')));
  }

  static bool isMimoProvider(ProviderConfig? cfg) {
    if (cfg == null) return false;
    final host = Uri.tryParse(cfg.baseUrl)?.host.toLowerCase() ?? '';
    final providerId = cfg.id.toLowerCase();
    final providerName = cfg.name.toLowerCase();
    return host.contains('xiaomimimo') ||
        host.contains('mimo') ||
        providerId.contains('mimo') ||
        providerName.contains('mimo') ||
        providerName.contains('小米');
  }

  static bool isMoonshotProvider(ProviderConfig? cfg) {
    if (cfg == null) return false;
    final host = Uri.tryParse(cfg.baseUrl)?.host.toLowerCase() ?? '';
    final providerId = cfg.id.toLowerCase();
    final providerName = cfg.name.toLowerCase();
    return host.contains('moonshot') ||
        host.contains('kimi.ai') ||
        providerId.contains('moonshot') ||
        providerId.contains('kimi') ||
        providerName.contains('moonshot') ||
        providerName.contains('kimi') ||
        providerName.contains('月之暗面');
  }

  static bool isZhipuProvider(ProviderConfig? cfg) {
    if (cfg == null) return false;
    final host = Uri.tryParse(cfg.baseUrl)?.host.toLowerCase() ?? '';
    final providerId = cfg.id.toLowerCase();
    final providerName = cfg.name.toLowerCase();
    return host.contains('open.bigmodel.cn') ||
        host.contains('bigmodel') ||
        host == 'api.z.ai' ||
        providerId.contains('zhipu') ||
        providerId.contains('智谱') ||
        providerName.contains('zhipu') ||
        providerName.contains('智谱');
  }

  static bool isMimoBuiltInSearchSupportedModel(String? modelId) {
    final m = _normalizedModelId(modelId);
    return m.startsWith('mimo-v2') || m.contains('/mimo-v2');
  }

  static bool isKimiK3Model(String? modelId) {
    return RegExp(
      r'(^|[/_:@])kimi-k3(?:$|[-.])',
      caseSensitive: false,
    ).hasMatch(_normalizedModelId(modelId));
  }

  static bool isGlmBuiltInSearchSupportedModel(String? modelId) {
    final m = _normalizedModelId(modelId);
    return RegExp(r'(^|[/_:@])glm-').hasMatch(m) || m.startsWith('glm');
  }

  static bool isDoubaoResponsesBuiltInSearchSupportedModel(String? modelId) {
    final m = _normalizedModelId(modelId);
    return m.contains('doubao') ||
        m.contains('seed-1') ||
        m.contains('seed-2') ||
        m.contains('seed-evolving');
  }

  static bool supportsBuiltInSearchForModel({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    if (cfg == null || (modelId ?? '').trim().isEmpty) return false;
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    final upstreamModelId = BuiltInToolNames.effectiveModelId(
      cfg: cfg,
      modelId: modelId,
    );
    switch (kind) {
      case ProviderKind.google:
        return true;
      case ProviderKind.claude:
        if (isDeepSeekProvider(cfg)) return true;
        return isClaudeBuiltInSearchSupportedModel(upstreamModelId);
      case ProviderKind.openai:
        if (isOpenRouterProvider(cfg)) {
          return cfg.useResponseApi != true;
        }
        if (isGrokModel(upstreamModelId)) return true;
        if (cfg.useResponseApi == true) {
          if (isOpenAIResponsesBuiltInSearchSupportedModel(upstreamModelId)) {
            return true;
          }
          if (isDashScopeProvider(cfg)) {
            return isDashScopeResponsesBuiltInSearchSupportedModel(
              upstreamModelId,
            );
          }
          if (isArkProvider(cfg)) {
            return isDoubaoResponsesBuiltInSearchSupportedModel(
              upstreamModelId,
            );
          }
          return false;
        }
        if (isDashScopeProvider(cfg)) {
          return isDashScopeChatBuiltInSearchSupportedModel(upstreamModelId);
        }
        if (isMimoProvider(cfg)) {
          return isMimoBuiltInSearchSupportedModel(upstreamModelId);
        }
        if (isMoonshotProvider(cfg) && isKimiK3Model(upstreamModelId)) {
          return true;
        }
        if (isZhipuProvider(cfg)) {
          return isGlmBuiltInSearchSupportedModel(upstreamModelId);
        }
        return false;
    }
  }

  static bool isBuiltInSearchEnabled({
    required ProviderConfig? cfg,
    required String? modelId,
    bool requireSupport = true,
  }) {
    if (cfg == null || modelId == null || modelId.trim().isEmpty) {
      return false;
    }
    final rawOv = cfg.modelOverrides[modelId];
    final builtInSet = BuiltInToolNames.parseFromOverride(rawOv);
    if (!builtInSet.contains(BuiltInToolNames.search)) return false;
    if (!requireSupport) return true;
    return supportsBuiltInSearchForModel(cfg: cfg, modelId: modelId);
  }

  static bool supportsClaudeDynamicWebSearchForModel({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    if (cfg == null || (modelId ?? '').trim().isEmpty) return false;
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    if (kind != ProviderKind.claude) return false;
    final upstreamModelId = BuiltInToolNames.effectiveModelId(
      cfg: cfg,
      modelId: modelId,
    );
    return !isDeepSeekProvider(cfg) &&
        isClaudeDynamicWebSearchSupportedModel(upstreamModelId);
  }

  static bool isClaudeDynamicWebSearchEnabled({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    if (!supportsClaudeDynamicWebSearchForModel(cfg: cfg, modelId: modelId)) {
      return false;
    }
    if (cfg == null || modelId == null || modelId.trim().isEmpty) {
      return false;
    }
    final rawOv = cfg.modelOverrides[modelId];
    final ov = rawOv is Map ? rawOv : null;
    final rawWs = ov?['webSearch'];
    if (rawWs is! Map) return false;
    final ws = rawWs.cast<String, dynamic>();
    return ws['toolVersion'] == 'web_search_20260209' ||
        ws['tool_version'] == 'web_search_20260209';
  }

  static String claudeBuiltInSearchToolType({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    return isClaudeDynamicWebSearchEnabled(cfg: cfg, modelId: modelId)
        ? 'web_search_20260209'
        : 'web_search_20250305';
  }

  static Map<String, dynamic> dashScopeSearchOptionsFromOverride(
    Object? rawOverride,
  ) {
    final ov = rawOverride is Map ? rawOverride : null;
    final rawWs = ov?['webSearch'];
    if (rawWs is! Map) return const <String, dynamic>{};
    final ws = rawWs.cast<String, dynamic>();
    final out = <String, dynamic>{};

    final strategy = ws['search_strategy']?.toString().trim();
    if (strategy != null && strategy.isNotEmpty) {
      out['search_strategy'] = strategy;
    }

    if (ws['forced_search'] is bool) {
      out['forced_search'] = ws['forced_search'];
    }
    if (ws['enable_search_extension'] is bool) {
      out['enable_search_extension'] = ws['enable_search_extension'];
    }

    final freshness = _readIntish(ws['freshness']);
    if (freshness != null) {
      out['freshness'] = freshness;
    }

    final assignedSites = ws['assigned_site_list'] ?? ws['allowed_domains'];
    if (assignedSites is List && assignedSites.isNotEmpty) {
      out['assigned_site_list'] = List<String>.from(
        assignedSites
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty),
      );
    }

    if (ws['intention_options'] is Map) {
      out['intention_options'] = (ws['intention_options'] as Map)
          .cast<String, dynamic>();
    } else {
      final promptIntervene = ws['prompt_intervene']?.toString().trim();
      if (promptIntervene != null && promptIntervene.isNotEmpty) {
        out['intention_options'] = {'prompt_intervene': promptIntervene};
      }
    }

    return out;
  }

  /// 检查提供商是否支持内置工具配置。
  static bool supportsBuiltInTools(ProviderKind kind) {
    return kind == ProviderKind.google || kind == ProviderKind.openai;
  }

  /// 检查提供商/模型组合是否支持搜索工具。
  static bool supportsSearch({
    required ProviderKind kind,
    required bool useResponseApi,
    String? modelId,
  }) {
    switch (kind) {
      case ProviderKind.google:
        return true;
      case ProviderKind.claude:
        return true;
      case ProviderKind.openai:
        // OpenAI 需要 Responses API，或 Grok 模型
        if (useResponseApi &&
            isOpenAIResponsesBuiltInSearchSupportedModel(modelId)) {
          return true;
        }
        if (useResponseApi &&
            isDashScopeResponsesBuiltInSearchSupportedModel(modelId)) {
          return true;
        }
        if (useResponseApi &&
            isDoubaoResponsesBuiltInSearchSupportedModel(modelId)) {
          return true;
        }
        if (isGrokModel(modelId)) return true;
        if (isDashScopeChatBuiltInSearchSupportedModel(modelId)) return true;
        if (isMimoBuiltInSearchSupportedModel(modelId)) return true;
        if (isKimiK3Model(modelId)) return true;
        if (isGlmBuiltInSearchSupportedModel(modelId)) return true;
        return false;
    }
  }

  /// 从模型覆盖中获取当前启用的内置工具。
  static BuiltInToolsState getActiveTools({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    if (cfg == null || modelId == null) {
      return const BuiltInToolsState();
    }

    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    final rawOv = cfg.modelOverrides[modelId];
    final builtInSet = BuiltInToolNames.parseFromOverride(rawOv);

    final bool searchActive = isBuiltInSearchEnabled(
      cfg: cfg,
      modelId: modelId,
    );
    bool codeExecutionActive = false;
    bool urlContextActive = false;
    bool youtubeActive = false;
    bool codeInterpreterActive = false;
    bool imageGenerationActive = false;

    if (kind == ProviderKind.google) {
      codeExecutionActive = builtInSet.contains(BuiltInToolNames.codeExecution);
      urlContextActive = builtInSet.contains(BuiltInToolNames.urlContext);
      youtubeActive = builtInSet.contains(BuiltInToolNames.youtube);
    } else if (kind == ProviderKind.openai) {
      codeInterpreterActive = builtInSet.contains(
        BuiltInToolNames.codeInterpreter,
      );
      imageGenerationActive = builtInSet.contains(
        BuiltInToolNames.imageGeneration,
      );
    }

    return BuiltInToolsState(
      searchActive: searchActive,
      codeExecutionActive: codeExecutionActive,
      urlContextActive: urlContextActive,
      youtubeActive: youtubeActive,
      codeInterpreterActive: codeInterpreterActive,
      imageGenerationActive: imageGenerationActive,
    );
  }
}

/// 表示当前启用内置工具的状态类。
class BuiltInToolsState {
  final bool searchActive;
  final bool codeExecutionActive;
  final bool urlContextActive;
  final bool youtubeActive;
  final bool codeInterpreterActive;
  final bool imageGenerationActive;

  const BuiltInToolsState({
    this.searchActive = false,
    this.codeExecutionActive = false,
    this.urlContextActive = false,
    this.youtubeActive = false,
    this.codeInterpreterActive = false,
    this.imageGenerationActive = false,
  });

  /// 如果有任何 Gemini 专用内置工具处于启用状态，则返回 true。
  bool get anyGeminiToolActive =>
      codeExecutionActive || urlContextActive || youtubeActive;
}
