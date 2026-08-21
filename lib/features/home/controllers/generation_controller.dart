import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/model_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/mcp/mcp_tool_service.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../services/message_builder_service.dart';
import '../services/ask_user_interaction_service.dart';
import '../services/tool_handler_service.dart';
import '../services/tool_approval_service.dart';
import 'chat_controller.dart';
import 'stream_controller.dart' as stream_ctrl;

/// 协调消息生成（发送与重新生成）的控制器。
///
/// 该控制器：
/// - 协调消息发送与重新生成流程
/// - 使用 MessageBuilderService 构建 API 消息
/// - 使用 StreamController 处理流式响应
/// - 使用 ToolHandlerService 管理工具定义与处理器
/// - 管理生成状态（加载、流式）
class GenerationController {
  GenerationController({
    required this.chatService,
    required this.chatController,
    required this.streamController,
    required this.messageBuilderService,
    required this.contextProvider,
    required this.onStateChanged,
    required this.getTitleForLocale,
  }) : toolHandlerService = ToolHandlerService(
         contextProvider: contextProvider,
       );

  final ChatService chatService;
  final ChatController chatController;
  final stream_ctrl.StreamController streamController;
  final MessageBuilderService messageBuilderService;

  /// 负责工具定义与工具调用执行的服务
  final ToolHandlerService toolHandlerService;

  /// 构建上下文（用于访问 providers）
  final BuildContext contextProvider;

  /// 状态变化时的回调（在 widget 中触发 setState）
  final VoidCallback onStateChanged;

  /// 获取本地化标题的函数
  final String Function(BuildContext context) getTitleForLocale;

  // ============================================================================
  // 工具 Schema 清洗（委托给 ToolHandlerService）
  // ============================================================================

  /// 将 JSON Schema 清洗/转换为各 provider 接受的子集。
  /// 委托给 ToolHandlerService.sanitizeToolParametersForProvider。
  static Map<String, dynamic> sanitizeToolParametersForProvider(
    Map<String, dynamic> schema,
    ProviderKind kind,
  ) {
    return ToolHandlerService.sanitizeToolParametersForProvider(schema, kind);
  }

  // ============================================================================
  // 模型能力检查
  // ============================================================================

  bool isReasoningModel(String providerKey, String modelId) {
    final settings = contextProvider.read<SettingsProvider>();
    final cfg = settings.getProviderConfig(providerKey);
    final ov = cfg.modelOverrides[modelId] as Map?;
    if (ov != null && ov.containsKey('abilities')) {
      final abilities =
          (ov['abilities'] as List?)
              ?.map((e) => e.toString().toLowerCase())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const [];
      return abilities.contains('reasoning');
    }
    final inferred = ModelRegistry.infer(
      ModelInfo(id: modelId, displayName: modelId),
    );
    return inferred.abilities.contains(ModelAbility.reasoning);
  }

  bool isToolModel(String providerKey, String modelId) {
    final settings = contextProvider.read<SettingsProvider>();
    final cfg = settings.getProviderConfig(providerKey);
    final ov = cfg.modelOverrides[modelId] as Map?;
    if (ov != null && ov.containsKey('abilities')) {
      final abilities =
          (ov['abilities'] as List?)
              ?.map((e) => e.toString().toLowerCase())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const [];
      return abilities.contains('tool');
    }
    final inferred = ModelRegistry.infer(
      ModelInfo(id: modelId, displayName: modelId),
    );
    return inferred.abilities.contains(ModelAbility.tool);
  }

  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true; // 将 null 视为默认/自动 -> 启用
    if (budget == -1) return true; // 自动
    return budget >= 1024;
  }

  // ============================================================================
  // 工具定义构建器（委托给 ToolHandlerService）
  // ============================================================================

  McpToolRouteSnapshot captureMcpToolRoutes(Assistant? assistant) {
    return toolHandlerService.captureMcpToolRoutes(assistant);
  }

  /// 为 API 调用准备工具定义。
  /// 委托给 ToolHandlerService.buildToolDefinitions。
  List<Map<String, dynamic>> buildToolDefinitions(
    SettingsProvider settings,
    Assistant? assistant,
    String providerKey,
    String modelId,
    bool hasBuiltInSearch, {
    McpToolRouteSnapshot? mcpRouteSnapshot,
  }) {
    return toolHandlerService.buildToolDefinitions(
      settings,
      assistant,
      providerKey,
      modelId,
      hasBuiltInSearch,
      isToolModel: isToolModel,
      mcpRouteSnapshot: mcpRouteSnapshot,
    );
  }

  /// 构建工具调用处理函数。
  /// 委托给 ToolHandlerService.buildToolCallHandler。
  ToolCallHandler? buildToolCallHandler(
    SettingsProvider settings,
    Assistant? assistant, {
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
    String? conversationId,
    McpToolRouteSnapshot? mcpRouteSnapshot,
  }) {
    return toolHandlerService.buildToolCallHandler(
      settings,
      assistant,
      approvalService: approvalService,
      askUserService: askUserService,
      conversationId: conversationId,
      mcpRouteSnapshot: mcpRouteSnapshot,
    );
  }

  // ============================================================================
  // 自定义请求头/请求体构建器
  // ============================================================================

  /// 根据助手设置构建自定义请求头。
  Map<String, String>? buildCustomHeaders(Assistant? assistant) {
    if ((assistant?.customHeaders.isNotEmpty ?? false)) {
      final headers = <String, String>{
        for (final e in assistant!.customHeaders)
          if ((e['name'] ?? '').trim().isNotEmpty)
            (e['name']!.trim()): (e['value'] ?? ''),
      };
      return headers.isEmpty ? null : headers;
    }
    return null;
  }

  /// 根据助手设置构建自定义请求体。
  Map<String, dynamic>? buildCustomBody(Assistant? assistant) {
    if ((assistant?.customBody.isNotEmpty ?? false)) {
      final body = <String, dynamic>{
        for (final e in assistant!.customBody)
          if ((e['key'] ?? '').trim().isNotEmpty)
            (e['key']!.trim()): (e['value'] ?? ''),
      };
      return body.isEmpty ? null : body;
    }
    return null;
  }

  // ============================================================================
  // 助手内容转换
  // ============================================================================

  /// 使用助手正则转换原始内容。
  String transformAssistantContent(String raw, Assistant? assistant) {
    return applyAssistantRegexes(
      raw,
      assistant: assistant,
      scope: AssistantRegexScope.assistant,
      target: AssistantRegexTransformTarget.persist,
    );
  }

  // ============================================================================
  // 生成上下文构建器
  // ============================================================================

  /// 构建流式生成所需的包含全部必要数据的生成上下文。
  stream_ctrl.GenerationContext buildGenerationContext({
    required ChatMessage assistantMessage,
    required List<Map<String, dynamic>> apiMessages,
    required List<String> userImagePaths,
    required bool allowImagesApiRouting,
    required String providerKey,
    required String modelId,
    required Assistant? assistant,
    required SettingsProvider settings,
    required ProviderConfig config,
    required List<Map<String, dynamic>> toolDefs,
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    required bool supportsReasoning,
    required bool enableReasoning,
    required bool streamOutput,
    bool generateTitleOnFinish = true,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    return stream_ctrl.GenerationContext(
      assistantMessage: assistantMessage,
      apiMessages: apiMessages,
      userImagePaths: userImagePaths,
      allowImagesApiRouting: allowImagesApiRouting,
      providerKey: providerKey,
      modelId: modelId,
      assistant: assistant,
      settings: settings,
      config: config,
      toolDefs: toolDefs,
      onToolCall: onToolCall,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      streamOutput: streamOutput,
      ocrActive: ocrActive,
      generateTitleOnFinish: generateTitleOnFinish,
    );
  }
}
