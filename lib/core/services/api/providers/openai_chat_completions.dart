part of '../chat_api_service.dart';

Map<String, dynamic> _copyChatCompletionMessage(Map<String, dynamic> m) {
  final role = (m['role'] ?? 'user').toString();
  final out = <String, dynamic>{
    'role': role,
    'content': m.containsKey('content') ? (m['content'] ?? '') : '',
  };

  // 保留可选的 name（部分供应商支持在非 tool 角色上使用它）。
  final name = m['name'];
  if (role != 'tool' && name != null && name.toString().isNotEmpty) {
    out['name'] = name;
  }

  // 保留 assistant tool_calls 和供应商推理回显（存在时）。
  if (role == 'assistant') {
    final toolCalls = m['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty) {
      out['tool_calls'] = toolCalls.whereType<Map>().map((toolCall) {
        final copy = toolCall.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        copy.remove('metadata');
        return copy;
      }).toList();
    }
    final functionCall = m['function_call'];
    if (functionCall != null) {
      out['function_call'] = functionCall;
    }
    if (m['reasoning_content'] != null) {
      out['reasoning_content'] = m['reasoning_content'];
    }
    if (m['reasoning_details'] != null) {
      out['reasoning_details'] = m['reasoning_details'];
    }
  }

  // 保留工具关联字段。
  if (role == 'tool') {
    final toolCallId = m['tool_call_id'];
    if (toolCallId != null && toolCallId.toString().isNotEmpty) {
      out['tool_call_id'] = toolCallId;
    }
    if (name != null && name.toString().isNotEmpty) {
      out['name'] = name;
    }
  }

  // 在工具后续重建时保留结构化媒体引用，以便后续
  // Chat Completions 构建器仍可发出 image_url / 多模态部分。
  final mediaPaths = m[multimodalInternalMediaPathsKey];
  if (mediaPaths != null) {
    if (mediaPaths is List) {
      out[multimodalInternalMediaPathsKey] = [
        for (final item in mediaPaths)
          if (item is Map) Map<String, dynamic>.from(item) else item,
      ];
    } else if (mediaPaths is Map) {
      out[multimodalInternalMediaPathsKey] = Map<String, dynamic>.from(
        mediaPaths,
      );
    } else {
      out[multimodalInternalMediaPathsKey] = mediaPaths;
    }
  }
  final revisionId = m[multimodalInternalRevisionIdKey];
  if (revisionId != null) {
    out[multimodalInternalRevisionIdKey] = revisionId;
  }

  return out;
}

List<Map<String, dynamic>> _cleanToolsForCompatibility(
  List<Map<String, dynamic>> tools,
) {
  final cleaned = tools.map((tool) {
    final result = Map<String, dynamic>.from(tool);
    final fn = result['function'];
    if (fn is Map) {
      final fnMap = Map<String, dynamic>.from(fn);
      final params = fnMap['parameters'];
      if (params is Map) {
        fnMap['parameters'] = _cleanSchemaForGemini(
          Map<String, dynamic>.from(params),
        );
      }
      result['function'] = fnMap;
    }
    return result;
  }).toList();
  // print('[ChatApi/Tools] Cleaned ${cleaned.length} tools: ${jsonEncode(cleaned)}');
  return cleaned;
}

Stream<ChatStreamChunk> _sendOpenAIChatCompletionsStream(
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
  final cfg = config.copyWith(useResponseApi: false);
  return _sendOpenAIStream(
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
