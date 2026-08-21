part of '../chat_api_service.dart';

List<Map<String, dynamic>> _toResponsesToolsFormat(
  List<Map<String, dynamic>> tools,
) {
  return tools.map((tool) {
    // 保持非 function 工具（例如 web_search）不变
    if ((tool['type'] ?? '').toString() != 'function') {
      return Map<String, dynamic>.from(tool);
    }

    // 如果已经扁平化（没有嵌套 'function'），原样返回
    if (tool['function'] is! Map) {
      return Map<String, dynamic>.from(tool);
    }

    final fn = Map<String, dynamic>.from(tool['function'] as Map);
    final out = <String, dynamic>{
      'type': 'function',
      if (fn['name'] != null) 'name': fn['name'],
      if (fn['description'] != null) 'description': fn['description'],
    };
    final params = fn['parameters'];
    if (params is Map<String, dynamic>) {
      // 确保 parameters 保持原样（schema）
      out['parameters'] = params;
    }
    // 如果存在 strict 标记则保留（无论位于 tool 级还是 function 级）
    final strict = (tool['strict'] ?? fn['strict']);
    if (strict is bool) {
      out['strict'] = strict;
    }
    return out;
  }).toList();
}

List<Map<String, dynamic>> _withResponsesFunctionCallItems(
  List<Map<String, dynamic>> outputItems,
  Iterable<ToolCallInfo> calls,
) {
  final replayItems = <Map<String, dynamic>>[
    for (final item in outputItems) Map<String, dynamic>.from(item),
  ];
  final presentCallIds = replayItems
      .where((item) => item['type'] == 'function_call')
      .map((item) => (item['call_id'] ?? '').toString())
      .where((callId) => callId.isNotEmpty)
      .toSet();

  for (final call in calls) {
    if (call.id.isEmpty || presentCallIds.contains(call.id)) continue;
    var argumentsJson = '{}';
    try {
      argumentsJson = jsonEncode(call.arguments);
    } catch (_) {}
    replayItems.add({
      'type': 'function_call',
      'call_id': call.id,
      'name': call.name,
      'arguments': argumentsJson,
    });
    presentCallIds.add(call.id);
  }

  return replayItems;
}

Stream<ChatStreamChunk> _sendOpenAIResponsesStream(
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
  final cfg = config.copyWith(useResponseApi: true);
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
