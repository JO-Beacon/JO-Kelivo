import 'dart:convert';
import 'assistant_regex.dart';
import 'preset_message.dart';
import 'avatar_transform.dart';
import 'health_data_type.dart';

enum MemorySmartAddMode { batched, perItem }

enum DefaultWorkspaceSetup { automatic, suggest, completed }

enum MemoryWriteScope {
  alwaysGlobal,
  alwaysAssistant,
  toolDefaultGlobal,
  toolDefaultAssistant,
}

class Assistant {
  static const int defaultRecentChatsSummaryMessageCount = 5;
  static const int defaultMemoryOrganizeEveryNTurns = 1;
  static const int minMemoryOrganizeEveryNTurns = 1;
  static const int maxMemoryOrganizeEveryNTurns = 20;
  static const double defaultTemperature = 1.0;
  static const double defaultGradientBackgroundPhase = 7.0;
  static const int minContextMessageSize = 1;
  static const int maxContextMessageSize = 1024;
  static const List<int> recentChatsSummaryMessageCountOptions = <int>[
    1,
    3,
    5,
    10,
    20,
    50,
  ];

  final String id;
  final String name;
  final String? avatar; // path/url/base64；null 表示使用首字母头像
  final AvatarTransform? avatarTransform;
  final bool useAssistantAvatar; // 在聊天中用助理头像替换模型图标
  final bool useAssistantName; // 在聊天中用助理名称替换模型名称
  final String? chatModelProvider; // null 表示使用全局默认值
  final String? chatModelId; // null 表示使用全局默认值
  final double? temperature; // null 表示禁用；否则为 0.0 - 2.0
  final double? topP; // null 表示禁用；否则为 0.0 - 1.0
  final int contextMessageSize; // 要包含的先前消息数量
  final bool limitContextMessages; // 是否强制执行 contextMessageSize
  final bool streamOutput; // 是否使用流式响应
  final int? thinkingBudget; // null = 使用全局/默认值；0 = 关闭；>0 = token 预算
  final int? maxTokens; // null = 不限制
  final String systemPrompt;

  /// 允许每个会话使用自己的系统提示词，覆盖助手的。
  final bool allowConversationSystemPrompt;

  /// 允许每个会话单独挑选指令注入与世界书。
  final bool allowConversationPromptInjection;
  final String messageTemplate; // 例如 "{{ message }}"
  final bool searchEnabled; // 每个助手的联网搜索开关
  final List<String> mcpServerIds; // 绑定的 MCP 服务器 ID
  final List<String> localToolIds; // 启用的本地工具 ID

  /// 该助手新建会话时默认使用的工作区。
  final String? defaultWorkspaceId;

  /// 新助手会记住第一次绑定；既有助手只提供建议。
  final DefaultWorkspaceSetup defaultWorkspaceSetup;

  /// 默认工作区编辑的运行期标识，包括选中同一个值。
  /// 无关编辑会保留它；该字段不参与序列化。
  final Object? defaultWorkspaceChangeToken;

  /// 启用的技能 ID。`null` 表示所有已安装技能都可用。
  final List<String>? skillIds;

  /// 该助手可读取的 HealthKit 指标 ID。健康总开关关闭时保留选择，
  /// 以便重新开启时恢复。
  final List<String> healthDataTypeIds;
  final String? background; // 聊天背景（颜色/图片引用）
  final bool useGradientBackground;
  final bool gradientBackgroundAnimated;
  final double gradientBackgroundPhase;
  final double gradientBackgroundOffsetX;
  final double gradientBackgroundOffsetY;
  // 自定义请求覆盖（每个助手）
  final List<Map<String, String>>
  customHeaders; // [{name:'X-Header', value:'v'}]
  final List<Map<String, String>> customBody; // [{key:'foo', value:'{"a":1}'}]
  // 记忆功能 (§4.1)
  final bool enableMemory;
  final bool autoOrganizeMemory;
  final int memoryOrganizeEveryNTurns;
  final MemorySmartAddMode memorySmartAddMode;
  final MemoryWriteScope memoryWriteScope;
  final bool allowPastConversationRecall;
  final bool generateConversationSummary;
  final int recentChatsSummaryMessageCount; // 每新增 N 条消息后刷新摘要
  final bool appendCurrentTimeToUserMessage;
  final bool useIso8601TimeFormat;
  // 预设会话消息（有序）
  final List<PresetMessage> presetMessages;
  // 正则替换规则
  final List<AssistantRegex> regexRules;

  const Assistant({
    required this.id,
    required this.name,
    this.avatar,
    this.avatarTransform,
    this.useAssistantAvatar = false,
    this.useAssistantName = false,
    this.chatModelProvider,
    this.chatModelId,
    this.temperature,
    this.topP,
    this.contextMessageSize = 64,
    this.limitContextMessages = false,
    this.streamOutput = true,
    this.thinkingBudget,
    this.maxTokens,
    this.systemPrompt = '',
    this.allowConversationSystemPrompt = false,
    this.allowConversationPromptInjection = false,
    this.messageTemplate = '{{ message }}',
    this.searchEnabled = false,
    this.mcpServerIds = const <String>[],
    this.localToolIds = const <String>[],
    this.defaultWorkspaceId,
    this.defaultWorkspaceSetup = DefaultWorkspaceSetup.automatic,
    this.defaultWorkspaceChangeToken,
    this.skillIds,
    this.healthDataTypeIds = HealthDataTypeIds.defaultSelected,
    this.background,
    this.useGradientBackground = false,
    this.gradientBackgroundAnimated = true,
    this.gradientBackgroundPhase = defaultGradientBackgroundPhase,
    this.gradientBackgroundOffsetX = 0,
    this.gradientBackgroundOffsetY = 0,
    this.customHeaders = const <Map<String, String>>[],
    this.customBody = const <Map<String, String>>[],
    this.enableMemory = false,
    this.autoOrganizeMemory = false,
    this.memoryOrganizeEveryNTurns = defaultMemoryOrganizeEveryNTurns,
    this.memorySmartAddMode = MemorySmartAddMode.batched,
    this.memoryWriteScope = MemoryWriteScope.alwaysGlobal,
    this.allowPastConversationRecall = false,
    this.generateConversationSummary = false,
    this.recentChatsSummaryMessageCount = defaultRecentChatsSummaryMessageCount,
    this.appendCurrentTimeToUserMessage = false,
    this.useIso8601TimeFormat = false,
    this.presetMessages = const <PresetMessage>[],
    this.regexRules = const <AssistantRegex>[],
  });

  Assistant copyWith({
    String? id,
    String? name,
    String? avatar,
    AvatarTransform? avatarTransform,
    bool? useAssistantAvatar,
    bool? useAssistantName,
    String? chatModelProvider,
    String? chatModelId,
    double? temperature,
    double? topP,
    int? contextMessageSize,
    bool? limitContextMessages,
    bool? streamOutput,
    int? thinkingBudget,
    int? maxTokens,
    String? systemPrompt,
    bool? allowConversationSystemPrompt,
    bool? allowConversationPromptInjection,
    String? messageTemplate,
    bool? searchEnabled,
    List<String>? mcpServerIds,
    List<String>? localToolIds,
    String? defaultWorkspaceId,
    DefaultWorkspaceSetup? defaultWorkspaceSetup,
    List<String>? skillIds,
    List<String>? healthDataTypeIds,
    String? background,
    bool? useGradientBackground,
    bool? gradientBackgroundAnimated,
    double? gradientBackgroundPhase,
    double? gradientBackgroundOffsetX,
    double? gradientBackgroundOffsetY,
    List<Map<String, String>>? customHeaders,
    List<Map<String, String>>? customBody,
    bool? enableMemory,
    bool? autoOrganizeMemory,
    int? memoryOrganizeEveryNTurns,
    MemorySmartAddMode? memorySmartAddMode,
    MemoryWriteScope? memoryWriteScope,
    bool? allowPastConversationRecall,
    bool? generateConversationSummary,
    int? recentChatsSummaryMessageCount,
    bool? appendCurrentTimeToUserMessage,
    bool? useIso8601TimeFormat,
    List<PresetMessage>? presetMessages,
    List<AssistantRegex>? regexRules,
    bool clearChatModel = false,
    bool clearDefaultWorkspaceId = false,
    bool clearSkillIds = false,
    bool clearAvatar = false,
    bool clearAvatarTransform = false,
    bool clearTemperature = false,
    bool clearTopP = false,
    bool clearThinkingBudget = false,
    bool clearMaxTokens = false,
    bool clearBackground = false,
  }) {
    return Assistant(
      id: id ?? this.id,
      name: name ?? this.name,
      avatar: clearAvatar ? null : (avatar ?? this.avatar),
      avatarTransform: clearAvatar || clearAvatarTransform
          ? null
          : (avatarTransform ?? this.avatarTransform),
      useAssistantAvatar: useAssistantAvatar ?? this.useAssistantAvatar,
      useAssistantName: useAssistantName ?? this.useAssistantName,
      chatModelProvider: clearChatModel
          ? null
          : (chatModelProvider ?? this.chatModelProvider),
      chatModelId: clearChatModel ? null : (chatModelId ?? this.chatModelId),
      temperature: clearTemperature ? null : (temperature ?? this.temperature),
      topP: clearTopP ? null : (topP ?? this.topP),
      contextMessageSize: contextMessageSize ?? this.contextMessageSize,
      limitContextMessages: limitContextMessages ?? this.limitContextMessages,
      streamOutput: streamOutput ?? this.streamOutput,
      thinkingBudget: clearThinkingBudget
          ? null
          : (thinkingBudget ?? this.thinkingBudget),
      maxTokens: clearMaxTokens ? null : (maxTokens ?? this.maxTokens),
      systemPrompt: systemPrompt ?? this.systemPrompt,
      allowConversationSystemPrompt:
          allowConversationSystemPrompt ?? this.allowConversationSystemPrompt,
      allowConversationPromptInjection:
          allowConversationPromptInjection ??
          this.allowConversationPromptInjection,
      messageTemplate: messageTemplate ?? this.messageTemplate,
      searchEnabled: searchEnabled ?? this.searchEnabled,
      mcpServerIds: mcpServerIds ?? this.mcpServerIds,
      localToolIds: localToolIds ?? this.localToolIds,
      defaultWorkspaceId: clearDefaultWorkspaceId
          ? null
          : (defaultWorkspaceId ?? this.defaultWorkspaceId),
      defaultWorkspaceSetup:
          defaultWorkspaceSetup ??
          (clearDefaultWorkspaceId || defaultWorkspaceId != null
              ? DefaultWorkspaceSetup.completed
              : this.defaultWorkspaceSetup),
      defaultWorkspaceChangeToken:
          clearDefaultWorkspaceId ||
              defaultWorkspaceId != null ||
              defaultWorkspaceSetup != null
          ? Object()
          : defaultWorkspaceChangeToken,
      skillIds: clearSkillIds ? null : (skillIds ?? this.skillIds),
      healthDataTypeIds: healthDataTypeIds ?? this.healthDataTypeIds,
      background: clearBackground ? null : (background ?? this.background),
      useGradientBackground:
          useGradientBackground ?? this.useGradientBackground,
      gradientBackgroundAnimated:
          gradientBackgroundAnimated ?? this.gradientBackgroundAnimated,
      gradientBackgroundPhase:
          gradientBackgroundPhase ?? this.gradientBackgroundPhase,
      gradientBackgroundOffsetX:
          gradientBackgroundOffsetX ?? this.gradientBackgroundOffsetX,
      gradientBackgroundOffsetY:
          gradientBackgroundOffsetY ?? this.gradientBackgroundOffsetY,
      customHeaders: customHeaders ?? this.customHeaders,
      customBody: customBody ?? this.customBody,
      enableMemory: enableMemory ?? this.enableMemory,
      autoOrganizeMemory: autoOrganizeMemory ?? this.autoOrganizeMemory,
      memoryOrganizeEveryNTurns:
          memoryOrganizeEveryNTurns ?? this.memoryOrganizeEveryNTurns,
      memorySmartAddMode: memorySmartAddMode ?? this.memorySmartAddMode,
      memoryWriteScope: memoryWriteScope ?? this.memoryWriteScope,
      allowPastConversationRecall:
          allowPastConversationRecall ?? this.allowPastConversationRecall,
      generateConversationSummary:
          generateConversationSummary ?? this.generateConversationSummary,
      recentChatsSummaryMessageCount:
          recentChatsSummaryMessageCount ?? this.recentChatsSummaryMessageCount,
      appendCurrentTimeToUserMessage:
          appendCurrentTimeToUserMessage ?? this.appendCurrentTimeToUserMessage,
      useIso8601TimeFormat: useIso8601TimeFormat ?? this.useIso8601TimeFormat,
      presetMessages: presetMessages ?? this.presetMessages,
      regexRules: regexRules ?? this.regexRules,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatar': avatar,
    'avatarTransform': avatarTransform?.toJson(),
    'useAssistantAvatar': useAssistantAvatar,
    'useAssistantName': useAssistantName,
    'chatModelProvider': chatModelProvider,
    'chatModelId': chatModelId,
    'temperature': temperature,
    'topP': topP,
    'contextMessageSize': contextMessageSize,
    'limitContextMessages': limitContextMessages,
    'streamOutput': streamOutput,
    'thinkingBudget': thinkingBudget,
    'maxTokens': maxTokens,
    'systemPrompt': systemPrompt,
    'allowConversationSystemPrompt': allowConversationSystemPrompt,
    'allowConversationPromptInjection': allowConversationPromptInjection,
    'messageTemplate': messageTemplate,
    'searchEnabled': searchEnabled,
    'mcpServerIds': mcpServerIds,
    'localToolIds': localToolIds,
    'defaultWorkspaceId': defaultWorkspaceId,
    'defaultWorkspaceSetup': defaultWorkspaceSetup.name,
    'skillIds': skillIds,
    'healthDataTypeIds': healthDataTypeIds,
    'background': background,
    'useGradientBackground': useGradientBackground,
    'gradientBackgroundAnimated': gradientBackgroundAnimated,
    'gradientBackgroundPhase': gradientBackgroundPhase,
    'gradientBackgroundOffsetX': gradientBackgroundOffsetX,
    'gradientBackgroundOffsetY': gradientBackgroundOffsetY,
    'customHeaders': customHeaders,
    'customBody': customBody,
    'enableMemory': enableMemory,
    'autoOrganizeMemory': autoOrganizeMemory,
    'memoryOrganizeEveryNTurns': memoryOrganizeEveryNTurns,
    'memorySmartAddMode': memorySmartAddModeToString(memorySmartAddMode),
    'memoryWriteScope': memoryWriteScopeToString(memoryWriteScope),
    'allowPastConversationRecall': allowPastConversationRecall,
    'generateConversationSummary': generateConversationSummary,
    'recentChatsSummaryMessageCount': recentChatsSummaryMessageCount,
    'appendCurrentTimeToUserMessage': appendCurrentTimeToUserMessage,
    'useIso8601TimeFormat': useIso8601TimeFormat,
    'presetMessages': PresetMessage.encodeList(presetMessages),
    'regexRules': regexRules.map((e) => e.toJson()).toList(),
  };

  static double _readGradientBackgroundPhase(Object? value) =>
      value is num && value.isFinite && value >= 0
      ? value.toDouble()
      : defaultGradientBackgroundPhase;

  static Assistant fromJson(Map<String, dynamic> json) => Assistant(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    avatar: json['avatar'] as String?,
    avatarTransform: AvatarTransform.fromJson(json['avatarTransform']),
    useAssistantAvatar: json['useAssistantAvatar'] as bool? ?? false,
    useAssistantName: json['useAssistantName'] as bool? ?? false,
    chatModelProvider: json['chatModelProvider'] as String?,
    chatModelId: json['chatModelId'] as String?,
    temperature: (json['temperature'] as num?)?.toDouble(),
    topP: (json['topP'] as num?)?.toDouble(),
    contextMessageSize: (json['contextMessageSize'] as num?)?.toInt() ?? 64,
    limitContextMessages: json['limitContextMessages'] as bool? ?? false,
    streamOutput: json['streamOutput'] as bool? ?? true,
    thinkingBudget: (json['thinkingBudget'] as num?)?.toInt(),
    maxTokens: (json['maxTokens'] as num?)?.toInt(),
    systemPrompt: (json['systemPrompt'] as String?) ?? '',
    allowConversationSystemPrompt:
        (json['allowConversationSystemPrompt'] as bool?) ?? false,
    allowConversationPromptInjection:
        (json['allowConversationPromptInjection'] as bool?) ?? false,
    messageTemplate: (json['messageTemplate'] as String?) ?? '{{ message }}',
    searchEnabled: json['searchEnabled'] as bool? ?? false,
    mcpServerIds:
        (json['mcpServerIds'] as List?)?.cast<String>() ?? const <String>[],
    localToolIds:
        (json['localToolIds'] as List?)?.cast<String>() ?? const <String>[],
    defaultWorkspaceId: json['defaultWorkspaceId'] as String?,
    defaultWorkspaceSetup:
        DefaultWorkspaceSetup.values
            .where((value) => value.name == json['defaultWorkspaceSetup'])
            .firstOrNull ??
        ((json['defaultWorkspaceId'] as String?)?.isNotEmpty == true
            ? DefaultWorkspaceSetup.completed
            : DefaultWorkspaceSetup.suggest),
    skillIds: json['skillIds'] == null
        ? null
        : (json['skillIds'] as List).map((e) => e.toString()).toList(),
    healthDataTypeIds: HealthDataTypeIds.parseStoredIds(
      json['healthDataTypeIds'],
    ),
    background: json['background'] as String?,
    useGradientBackground: json['useGradientBackground'] as bool? ?? false,
    gradientBackgroundAnimated:
        json['gradientBackgroundAnimated'] as bool? ?? true,
    gradientBackgroundPhase: _readGradientBackgroundPhase(
      json['gradientBackgroundPhase'],
    ),
    gradientBackgroundOffsetX:
        ((json['gradientBackgroundOffsetX'] as num?)?.toDouble() ?? 0).clamp(
          -1.0,
          1.0,
        ),
    gradientBackgroundOffsetY:
        ((json['gradientBackgroundOffsetY'] as num?)?.toDouble() ?? 0).clamp(
          -1.0,
          1.0,
        ),
    customHeaders: (() {
      final raw = json['customHeaders'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map(
              (e) => {
                'name': (e['name'] ?? e['key'] ?? '').toString(),
                'value': (e['value'] ?? '').toString(),
              },
            )
            .toList();
      }
      return const <Map<String, String>>[];
    })(),
    customBody: (() {
      final raw = json['customBody'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map(
              (e) => {
                'key': (e['key'] ?? e['name'] ?? '').toString(),
                'value': (e['value'] ?? '').toString(),
              },
            )
            .toList();
      }
      return const <Map<String, String>>[];
    })(),
    enableMemory: json['enableMemory'] as bool? ?? false,
    autoOrganizeMemory: json['autoOrganizeMemory'] as bool? ?? false,
    memoryOrganizeEveryNTurns: (() {
      final raw = (json['memoryOrganizeEveryNTurns'] as num?)?.toInt();
      if (raw == null ||
          raw < minMemoryOrganizeEveryNTurns ||
          raw > maxMemoryOrganizeEveryNTurns) {
        return defaultMemoryOrganizeEveryNTurns;
      }
      return raw;
    })(),
    memorySmartAddMode: memorySmartAddModeFromString(
      json['memorySmartAddMode'] as String?,
    ),
    memoryWriteScope: memoryWriteScopeFromString(
      json['memoryWriteScope'] as String?,
    ),
    // 旧版 `enableRecentChatsReference` 会映射到 allowPastConversationRecall。
    allowPastConversationRecall:
        json['allowPastConversationRecall'] as bool? ??
        json['enableRecentChatsReference'] as bool? ??
        false,
    generateConversationSummary:
        json['generateConversationSummary'] as bool? ?? false,
    recentChatsSummaryMessageCount: (() {
      final raw = (json['recentChatsSummaryMessageCount'] as num?)?.toInt();
      if (raw == null || raw < 1) {
        return defaultRecentChatsSummaryMessageCount;
      }
      return raw;
    })(),
    appendCurrentTimeToUserMessage:
        json['appendCurrentTimeToUserMessage'] as bool? ?? false,
    useIso8601TimeFormat: json['useIso8601TimeFormat'] as bool? ?? false,
    presetMessages: (() {
      try {
        return PresetMessage.decodeList(json['presetMessages']);
      } catch (_) {
        return const <PresetMessage>[];
      }
    })(),
    regexRules: (() {
      final raw = json['regexRules'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((e) => AssistantRegex.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
      return const <AssistantRegex>[];
    })(),
  );

  static String memorySmartAddModeToString(MemorySmartAddMode mode) {
    switch (mode) {
      case MemorySmartAddMode.batched:
        return 'batched';
      case MemorySmartAddMode.perItem:
        return 'perItem';
    }
  }

  static MemorySmartAddMode memorySmartAddModeFromString(String? value) {
    switch (value) {
      case 'perItem':
        return MemorySmartAddMode.perItem;
      case 'batched':
      default:
        return MemorySmartAddMode.batched;
    }
  }

  static String memoryWriteScopeToString(MemoryWriteScope scope) {
    switch (scope) {
      case MemoryWriteScope.alwaysGlobal:
        return 'alwaysGlobal';
      case MemoryWriteScope.alwaysAssistant:
        return 'alwaysAssistant';
      case MemoryWriteScope.toolDefaultGlobal:
        return 'toolDefaultGlobal';
      case MemoryWriteScope.toolDefaultAssistant:
        return 'toolDefaultAssistant';
    }
  }

  static MemoryWriteScope memoryWriteScopeFromString(String? value) {
    switch (value) {
      case 'alwaysAssistant':
        return MemoryWriteScope.alwaysAssistant;
      case 'toolDefaultGlobal':
        return MemoryWriteScope.toolDefaultGlobal;
      case 'toolDefaultAssistant':
        return MemoryWriteScope.toolDefaultAssistant;
      case 'alwaysGlobal':
      default:
        return MemoryWriteScope.alwaysGlobal;
    }
  }

  static String encodeList(List<Assistant> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());
  static List<Assistant> decodeList(String raw) {
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in arr) Assistant.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const <Assistant>[];
    }
  }
}
