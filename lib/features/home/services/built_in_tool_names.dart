import '../../../core/services/memory/memory_tools.dart';
import '../../../core/services/search/search_tool_service.dart';
import 'local_tools_service.dart';

/// MCP 工具不能占用的客户端内置工具名称。
abstract final class BuiltInToolNames {
  static Set<String> get all => {
    SearchToolService.toolName,
    'builtin_search',
    ...MemoryTools.allToolNames,
    ...MemoryTools.legacyToolNames,
    ...LocalToolNames.all,
  };
}
