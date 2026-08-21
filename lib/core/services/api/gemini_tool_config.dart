bool shouldAttachGeminiFunctionCallingConfig(List<Map<String, dynamic>> tools) {
  for (final tool in tools) {
    if (!tool.containsKey('function_declarations')) continue;
    final decls = tool['function_declarations'];
    if (decls is List && decls.isNotEmpty) return true;
  }
  return false;
}

/// [tools] 是否同时包含内置工具和非空的 function_declarations。
bool hasBuiltInAndFunctionDeclarations(List<Map<String, dynamic>> tools) {
  bool hasBuiltIn = false;
  bool hasFuncDecls = false;
  for (final tool in tools) {
    if (tool.containsKey('google_search') ||
        tool.containsKey('code_execution') ||
        tool.containsKey('url_context')) {
      hasBuiltIn = true;
    }
    if (tool.containsKey('function_declarations')) {
      final decls = tool['function_declarations'];
      if (decls is List && decls.isNotEmpty) hasFuncDecls = true;
    }
  }
  return hasBuiltIn && hasFuncDecls;
}

/// 为 Gemini API 请求构建 `toolConfig` map。
///
/// 内置工具与自定义工具组合时的 Gemini 3：
///   - VALIDATED 模式（服务端工具调用不支持 AUTO）；includeServerSideToolInvocations: true
///
/// 其他包含 function_declarations 的情况：AUTO 模式（现有行为）。无需 toolConfig 时返回 null。
Map<String, dynamic>? buildGeminiToolConfig({
  required List<Map<String, dynamic>> tools,
  required bool isGemini3,
}) {
  final hasFuncDecls = shouldAttachGeminiFunctionCallingConfig(tools);
  if (!hasFuncDecls) return null;

  if (isGemini3 && hasBuiltInAndFunctionDeclarations(tools)) {
    return {
      'function_calling_config': {'mode': 'VALIDATED'},
      'includeServerSideToolInvocations': true,
    };
  }
  return {
    'function_calling_config': {'mode': 'AUTO'},
  };
}
