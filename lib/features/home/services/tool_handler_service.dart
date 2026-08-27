import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/memory_provider_v2.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/tts_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/mcp/mcp_tool_service.dart';
import '../../../core/services/memory/memory_pipeline.dart';
import '../../../core/services/memory/memory_prompts.dart';
import '../../../core/services/memory/memory_tools.dart';
import '../../../core/services/search/search_tool_service.dart';
import 'ask_user_interaction_service.dart';
import 'built_in_tool_names.dart';
import 'local_tools_service.dart';
import 'tool_approval_service.dart';

/// 工具调用处理服务
///
/// 处理各类工具调用：
/// - MCP 工具
/// - Memory 工具 (§10)
/// - Search 工具
class ToolHandlerService {
  ToolHandlerService({required this.contextProvider});

  /// 构建上下文（用于访问 providers）
  final BuildContext contextProvider;

  // ============================================================================
  // 工具 Schema 清洗
  // ============================================================================

  /// 清洗/转换 JSON Schema 到各供应商接受的子集。
  ///
  /// 不同供应商（Google、OpenAI、Claude）对工具参数 Schema 有不同要求。
  /// 此方法将 Schema 归一化以跨供应商工作。
  static Map<String, dynamic> sanitizeToolParametersForProvider(
    Map<String, dynamic> schema,
    ProviderKind kind,
  ) {
    Map<String, dynamic> clone = _deepCloneMap(schema);
    clone = _sanitizeNode(clone, kind) as Map<String, dynamic>;
    return clone;
  }

  static dynamic _sanitizeNode(dynamic node, ProviderKind kind) {
    if (node is List) {
      return node.map((e) => _sanitizeNode(e, kind)).toList();
    }
    if (node is! Map) return node;

    final m = Map<String, dynamic>.from(node);
    // 移除 $schema，工具定义中不需要它
    m.remove(r'$schema');

    // 将 'const' 转换为 'enum' 以保持兼容性
    if (m.containsKey('const')) {
      final v = m['const'];
      if (v is String || v is num || v is bool) {
        m['enum'] = [v];
        if (m['type'] == null) {
          m['type'] = switch (v) {
            bool _ => 'boolean',
            int _ => 'integer',
            num _ => 'number',
            _ => 'string',
          };
        }
      }
      m.remove('const');
    }

    // 为简化将 anyOf/oneOf/allOf 展平为首个变体
    for (final key in [
      'anyOf',
      'oneOf',
      'allOf',
      'any_of',
      'one_of',
      'all_of',
    ]) {
      if (m[key] is List && (m[key] as List).isNotEmpty) {
        final first = (m[key] as List).first;
        final flattened = _sanitizeNode(first, kind);
        m.remove(key);
        if (flattened is Map<String, dynamic>) {
          m
            ..remove('type')
            ..remove('properties')
            ..remove('items');
          m.addAll(flattened);
        }
      }
    }

    // 将 type 数组归一化为单一 type
    final t = m['type'];
    if (t is List && t.isNotEmpty) m['type'] = t.first.toString();

    // 将 items 数组归一化为单个 item
    final items = m['items'];
    if (items is List && items.isNotEmpty) m['items'] = items.first;
    if (m['items'] is Map) m['items'] = _sanitizeNode(m['items'], kind);

    // 递归清洗 properties
    if (m['properties'] is Map) {
      final props = Map<String, dynamic>.from(m['properties']);
      final norm = <String, dynamic>{};
      props.forEach((k, v) {
        norm[k] = _sanitizeNode(v, kind);
      });
      m['properties'] = norm;
    }

    // additionalProperties 本身可以是 Schema。
    if (m['additionalProperties'] is Map) {
      m['additionalProperties'] = _sanitizeNode(
        m['additionalProperties'],
        kind,
      );
    }

    // 按供应商只保留允许的键
    Set<String> allowed;
    switch (kind) {
      case ProviderKind.google:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
        };
        break;
      case ProviderKind.openai:
      case ProviderKind.claude:
        allowed = {
          'type',
          'description',
          'properties',
          'required',
          'items',
          'enum',
          'additionalProperties',
        };
        break;
    }
    m.removeWhere((k, v) => !allowed.contains(k));
    return m;
  }

  static Map<String, dynamic> _deepCloneMap(Map<String, dynamic> input) {
    return jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
  }

  static String _toolError({
    required String error,
    required String message,
    required String tool,
    String? instruction,
  }) {
    return jsonEncode({
      'type': 'tool_error',
      'error': error,
      'message': message,
      'tool': tool,
      if (instruction != null) 'instruction': instruction,
    });
  }

  // ============================================================================
  // 工具定义构建器
  // ============================================================================

  McpToolRouteSnapshot captureMcpToolRoutes(Assistant? assistant) {
    return contextProvider.read<McpToolService>().captureRoutesForAssistant(
      contextProvider.read<McpProvider>(),
      contextProvider.read<AssistantProvider>(),
      assistantId: assistant?.id,
      reservedNames: BuiltInToolNames.all,
    );
  }

  /// 为 API 调用构建工具定义。
  ///
  /// 返回工具定义列表，包括：
  /// - 搜索工具（启用且模型支持工具时）
  /// - 记忆工具（助手启用记忆/历史召回时）
  /// - MCP 工具（来自助手选择的服务器）
  /// 正在生成的聊天是否为临时的。
  ///
  /// 工具定义构建时不带会话 id，因此此方法以与工具处理器
  /// 相同的方式读取活动会话。
  bool _isTemporaryConversation() {
    try {
      final chatService = contextProvider.read<ChatService>();
      return chatService.isTemporaryConversation(
        chatService.currentConversationId,
      );
    } catch (_) {
      return false;
    }
  }

  List<Map<String, dynamic>> buildToolDefinitions(
    SettingsProvider settings,
    Assistant? assistant,
    String providerKey,
    String modelId,
    bool hasBuiltInSearch, {
    required bool Function(String providerKey, String modelId) isToolModel,
    McpToolRouteSnapshot? mcpRouteSnapshot,
  }) {
    final List<Map<String, dynamic>> toolDefs = <Map<String, dynamic>>[];
    final supportsTools = isToolModel(providerKey, modelId);

    // Search 工具（当 Gemini 内置搜索启用时跳过）
    if (assistant?.searchEnabled == true &&
        !hasBuiltInSearch &&
        supportsTools) {
      toolDefs.add(SearchToolService.getToolDefinition());
    }

    // Memory 工具 (§10.1)
    if (settings.legacyMemoryMode) {
      if (assistant?.enableMemory == true && supportsTools) {
        toolDefs.addAll(
          _buildLegacyMemoryToolDefinitions(settings.resolvedMemoryPromptLang),
        );
      }
    } else if (supportsTools && assistant != null) {
      toolDefs.addAll(
        MemoryTools.buildDefinitions(
          lang: settings.resolvedMemoryPromptLang,
          writeScope: assistant.memoryWriteScope,
          enableMemory: assistant.enableMemory,
          allowPastConversationRecall: assistant.allowPastConversationRecall,
          allowMemoryWrites: !_isTemporaryConversation(),
        ),
      );
    }

    // 本地工具
    toolDefs.addAll(
      LocalToolsService.buildToolDefinitions(
        assistant: assistant,
        supportsTools: supportsTools,
      ),
    );

    // MCP 工具
    final mcpTools = _buildMcpToolDefinitions(
      settings: settings,
      assistant: assistant,
      providerKey: providerKey,
      supportsTools: supportsTools,
      mcpRouteSnapshot: mcpRouteSnapshot,
    );
    toolDefs.addAll(mcpTools);

    return toolDefs;
  }

  /// 旧版 create/edit/delete_memory 工具 schema（v2 之前的记忆系统）。
  List<Map<String, dynamic>> _buildLegacyMemoryToolDefinitions(
    MemoryPromptLang lang,
  ) {
    final zh = lang == MemoryPromptLang.zh;
    return [
      {
        'type': 'function',
        'function': {
          'name': 'create_memory',
          'description': zh ? '新增一条记忆记录。' : 'Create a memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {
                'type': 'string',
                'description': zh
                    ? '记忆记录的内容。'
                    : 'The content of the memory record.',
              },
            },
            'required': ['content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_memory',
          'description': zh
              ? '更新一条已有的记忆记录。'
              : 'Update an existing memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': zh
                    ? '记忆记录的 id。'
                    : 'The id of the memory record.',
              },
              'content': {
                'type': 'string',
                'description': zh
                    ? '记忆记录的内容。'
                    : 'The content of the memory record.',
              },
            },
            'required': ['id', 'content'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_memory',
          'description': zh ? '删除一条记忆记录。' : 'Delete a memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {
                'type': 'integer',
                'description': zh
                    ? '记忆记录的 id。'
                    : 'The id of the memory record.',
              },
            },
            'required': ['id'],
          },
        },
      },
    ];
  }

  /// 从已连接的服务器构建 MCP 工具定义。
  List<Map<String, dynamic>> _buildMcpToolDefinitions({
    required SettingsProvider settings,
    required Assistant? assistant,
    required String providerKey,
    required bool supportsTools,
    McpToolRouteSnapshot? mcpRouteSnapshot,
  }) {
    if (!supportsTools) return [];

    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    final tools = toolSvc.listAvailableToolsForAssistant(
      mcp,
      contextProvider.read<AssistantProvider>(),
      assistant?.id,
      routeSnapshot: mcpRouteSnapshot,
      reservedNames: BuiltInToolNames.all,
    );

    if (tools.isEmpty) return [];

    final providerCfg = settings.getProviderConfig(providerKey);
    final providerKind = ProviderConfig.classify(
      providerCfg.id,
      explicitType: providerCfg.providerType,
    );

    return tools.map((t) {
      Map<String, dynamic> baseSchema;
      if (t.schema != null && t.schema!.isNotEmpty) {
        baseSchema = Map<String, dynamic>.from(t.schema!);
      } else {
        final props = <String, dynamic>{
          for (final p in t.params) p.name: {'type': (p.type ?? 'string')},
        };
        final required = [
          for (final p in t.params.where((e) => e.required)) p.name,
        ];
        baseSchema = {
          'type': 'object',
          'properties': props,
          if (required.isNotEmpty) 'required': required,
        };
      }
      final sanitized = sanitizeToolParametersForProvider(
        baseSchema,
        providerKind,
      );
      return {
        'type': 'function',
        'function': {
          'name': t.name,
          if ((t.description ?? '').isNotEmpty) 'description': t.description,
          'parameters': sanitized,
        },
      };
    }).toList();
  }

  // ============================================================================
  // 工具调用处理器
  // ============================================================================

  /// 构建工具调用处理函数。
  ///
  /// 返回一个按名称和参数处理工具调用的函数。
  /// 支持：
  /// - Search 工具调用
  /// - Memory 工具调用 (§10)
  /// - MCP 工具调用
  ToolCallHandler? buildToolCallHandler(
    SettingsProvider settings,
    Assistant? assistant, {
    ToolApprovalService? approvalService,
    AskUserInteractionService? askUserService,
    String? conversationId,
    McpToolRouteSnapshot? mcpRouteSnapshot,
  }) {
    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    // 在异步间隙前捕获 AssistantProvider 引用，以避免
    // use_build_context_synchronously 警告
    final assistantProvider = contextProvider.read<AssistantProvider>();
    final routes =
        mcpRouteSnapshot ??
        toolSvc.captureRoutesForAssistant(
          mcp,
          assistantProvider,
          assistantId: assistant?.id,
          reservedNames: BuiltInToolNames.all,
        );

    Future<String> approveAndExecuteMcp(
      String name,
      Map<String, dynamic> args,
    ) async {
      if (approvalService != null &&
          toolSvc.toolNeedsApprovalForAssistant(
            mcp,
            assistantProvider,
            assistantId: assistant?.id,
            toolName: name,
            routeSnapshot: routes,
            reservedNames: BuiltInToolNames.all,
          )) {
        final approvalId = '${name}_${DateTime.now().microsecondsSinceEpoch}';
        final result = await approvalService.requestApproval(
          toolCallId: approvalId,
          toolName: name,
          arguments: args,
          conversationId: conversationId,
        );
        if (!result.approved) {
          return _toolError(
            error: 'approval_denied',
            message: result.denyReason ?? 'User denied the tool call',
            tool: name,
          );
        }
      }
      return toolSvc.callToolTextForAssistant(
        mcp,
        assistantProvider,
        assistantId: assistant?.id,
        toolName: name,
        arguments: args,
        routeSnapshot: routes,
        reservedNames: BuiltInToolNames.all,
      );
    }

    return (name, args, {toolCallId}) async {
      try {
        if (routes.containsExposedName(name)) {
          return await approveAndExecuteMcp(name, args);
        }

        // Search 工具
        if (name == SearchToolService.toolName &&
            assistant?.searchEnabled == true) {
          final q = (args['query'] ?? '').toString();
          return await SearchToolService.executeSearch(q, settings);
        }

        // Memory 工具
        final memoryResult = await _handleMemoryToolCall(
          name,
          args,
          assistant,
          conversationId: conversationId,
        );
        if (memoryResult != null) {
          return memoryResult;
        }

        // 创建日历事件会修改用户数据，因此本地工具运行前
        // 始终需要用户显式批准。
        if (name == LocalToolNames.calendarCreate &&
            assistant != null &&
            assistant.localToolIds.contains(LocalToolNames.calendarCreate) &&
            approvalService != null) {
          final approvalId = (toolCallId?.trim().isNotEmpty == true)
              ? toolCallId!.trim()
              : '${name}_${DateTime.now().microsecondsSinceEpoch}';
          final approval = await approvalService.requestApproval(
            toolCallId: approvalId,
            toolName: name,
            arguments: args,
            conversationId: conversationId,
          );
          if (!approval.approved) {
            return _toolError(
              error: 'approval_denied',
              message: approval.denyReason ?? 'User denied the tool call',
              tool: name,
            );
          }
        }

        // 本地工具
        final localResult = await LocalToolsService.tryHandleToolCall(
          name,
          args,
          assistant,
          onSpeakText: (text) async {
            final tts = contextProvider.read<TtsProvider>();
            if (!tts.isAvailable) {
              throw StateError('Text-to-speech is unavailable.');
            }
            unawaited(
              tts.speak(text).catchError((Object error, StackTrace stack) {
                FlutterError.reportError(
                  FlutterErrorDetails(
                    exception: error,
                    stack: stack,
                    library: 'Kelivo local tools',
                    context: ErrorDescription('while playing text-to-speech'),
                  ),
                );
              }),
            );
          },
        );
        if (localResult != null) {
          return localResult;
        }

        if (name == LocalToolNames.askUser &&
            assistant != null &&
            assistant.localToolIds.contains(LocalToolNames.askUser)) {
          if (askUserService == null) {
            return _toolError(
              error: 'ask_user_unavailable',
              message: 'Ask user interaction service is unavailable.',
              tool: name,
            );
          }
          try {
            final result = await askUserService.requestAnswer(
              toolCallId: (toolCallId?.trim().isNotEmpty == true)
                  ? toolCallId!.trim()
                  : '${name}_${DateTime.now().microsecondsSinceEpoch}',
              arguments: args,
              conversationId: conversationId,
            );
            return result.toJsonString();
          } on AskUserInvalidRequestException catch (e) {
            return _toolError(
              error: 'invalid_ask_user_request',
              message: e.message,
              tool: name,
            );
          }
        }

        // MCP 工具的审批关卡
        if (approvalService != null &&
            toolSvc.toolNeedsApprovalForAssistant(
              mcp,
              assistantProvider,
              assistantId: assistant?.id,
              toolName: name,
              routeSnapshot: routes,
              reservedNames: BuiltInToolNames.all,
            )) {
          // 为本次工具调用审批请求生成唯一 id
          final toolCallId = '${name}_${DateTime.now().microsecondsSinceEpoch}';
          final result = await approvalService.requestApproval(
            toolCallId: toolCallId,
            toolName: name,
            arguments: args,
            conversationId: conversationId,
          );
          if (!result.approved) {
            return _toolError(
              error: 'approval_denied',
              message: result.denyReason ?? 'User denied the tool call',
              tool: name,
            );
          }
        }

        // MCP 工具
        final text = await toolSvc.callToolTextForAssistant(
          mcp,
          assistantProvider,
          assistantId: assistant?.id,
          toolName: name,
          arguments: args,
          routeSnapshot: routes,
          reservedNames: BuiltInToolNames.all,
        );
        return text;
      } catch (e) {
        // 捕获意外异常并向 LLM 返回错误 JSON
        // 这可防止工具失败终止聊天流程
        return _toolError(
          error: 'execution_error',
          message: e.toString(),
          tool: name,
          instruction:
              'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
        );
      }
    };
  }

  /// 处理 memory 工具调用 (§10)。
  ///
  /// 若工具不是 memory 工具或相关门控关闭，则返回 null。
  Future<String?> _handleMemoryToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant, {
    String? conversationId,
  }) async {
    final settings = contextProvider.read<SettingsProvider>();
    if (settings.legacyMemoryMode) {
      if (MemoryTools.allToolNames.contains(name)) return null;
      return _handleLegacyMemoryToolCall(name, args, assistant);
    }

    if (assistant == null) return null;
    if (!MemoryTools.allToolNames.contains(name)) return null;

    final memoryV2 = contextProvider.read<MemoryProviderV2>();
    ChatService? chatService;
    try {
      chatService = contextProvider.read<ChatService>();
    } catch (_) {
      chatService = null;
    }

    MemoryPipelineService? pipeline;
    try {
      pipeline = contextProvider.read<MemoryPipelineService>();
    } catch (_) {
      pipeline = null;
    }

    Future<String> Function(String prompt)? memoryLlmCall;
    final provKey = settings.memoryModelProvider;
    final mdlId = settings.memoryModelId;
    if (provKey != null && mdlId != null) {
      final cfg = settings.getProviderConfig(provKey);
      final budget = settings.memoryModelThinkingEnabled
          ? (assistant.thinkingBudget ?? settings.thinkingBudget)
          : 0;
      memoryLlmCall = (prompt) => ChatApiService.generateText(
        config: cfg,
        modelId: mdlId,
        prompt: prompt,
        thinkingBudget: budget,
      );
    }

    final temporary =
        chatService?.isTemporaryConversation(conversationId) ?? false;
    return MemoryTools.handle(
      name: name,
      args: args,
      assistant: assistant,
      repository: memoryV2.repository,
      chatRepository: memoryV2.chatRepository,
      chatService: chatService,
      conversationId: conversationId,
      // 重新加载，但不改变已打开的记忆 UI 正在显示的助手。
      onMutated: memoryV2.reloadCurrentScope,
      smartAdd: pipeline?.smartAdd,
      promptLang: settings.resolvedMemoryPromptLang,
      memoryLlmCall: memoryLlmCall,
      smartAddPromptZh: settings.memorySmartAddPromptZh,
      smartAddPromptEn: settings.memorySmartAddPromptEn,
      // 临时聊天在退出时丢弃；其工具 trace 不得残留。
      traceRecorder: temporary ? null : pipeline?.traceRecorder,
      conversationTitle: conversationId == null
          ? null
          : chatService?.getConversation(conversationId)?.title,
    );
  }

  /// 通过 [MemoryProvider] 处理旧版 create/edit/delete_memory 调用。
  ///
  /// 若记忆已禁用或 [name] 不是旧版 memory 工具，则返回 null。
  Future<String?> _handleLegacyMemoryToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant,
  ) async {
    if (assistant?.enableMemory != true) return null;
    if (name != 'create_memory' &&
        name != 'edit_memory' &&
        name != 'delete_memory') {
      return null;
    }

    try {
      final mp = contextProvider.read<MemoryProvider>();

      if (name == 'create_memory') {
        final content = (args['content'] ?? '').toString();
        if (content.isEmpty) {
          return _toolError(
            error: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            tool: name,
          );
        }
        final m = await mp.add(assistantId: assistant!.id, content: content);
        return m.content;
      } else if (name == 'edit_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        final content = (args['content'] ?? '').toString();
        if (id <= 0) {
          return _toolError(
            error: 'invalid_memory_id',
            message: 'Memory id must be a positive integer.',
            tool: name,
          );
        }
        if (content.isEmpty) {
          return _toolError(
            error: 'invalid_memory_content',
            message: 'Memory content must not be empty.',
            tool: name,
          );
        }
        final m = await mp.update(id: id, content: content);
        if (m == null) {
          return _toolError(
            error: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            tool: name,
            instruction:
                'Use the available memory records shown in context, or create a new memory instead of editing a missing one.',
          );
        }
        return m.content;
      } else if (name == 'delete_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        if (id <= 0) {
          return _toolError(
            error: 'invalid_memory_id',
            message: 'Memory id must be a positive integer.',
            tool: name,
          );
        }
        final ok = await mp.delete(id: id);
        if (!ok) {
          return _toolError(
            error: 'memory_not_found',
            message: 'No memory record was found for id $id.',
            tool: name,
            instruction:
                'Use the available memory records shown in context, or skip deleting a missing memory.',
          );
        }
        return 'deleted';
      }
    } catch (e) {
      return _toolError(
        error: 'memory_execution_error',
        message: e.toString(),
        tool: name,
        instruction:
            'The memory tool failed. Retry only after correcting the parameters, or inform the user about the issue.',
      );
    }

    return null;
  }
}
