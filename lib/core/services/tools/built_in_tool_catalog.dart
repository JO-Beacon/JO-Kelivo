import '../../../features/home/services/local_tools_service.dart';
import '../../models/assistant.dart';
import '../memory/memory_prompts.dart';
import '../memory/memory_tools.dart';
import '../search/search_tool_service.dart';
import '../workspace/workspace_tools_service.dart';

enum BuiltInToolGroup { search, memory, local, workspace }

class BuiltInToolCatalogEntry {
  const BuiltInToolCatalogEntry({
    required this.name,
    required this.defaultDefinition,
    required this.group,
  });

  final String name;
  final Map<String, dynamic> defaultDefinition;
  final BuiltInToolGroup group;

  String? get defaultDescription {
    final function = defaultDefinition['function'];
    final description = function is Map ? function['description'] : null;
    return description is String ? description : null;
  }
}

/// 设置页使用的内置工具目录。MCP 工具名动态变化，因此不在这里出现。
abstract final class BuiltInToolCatalog {
  BuiltInToolCatalog._();

  static List<BuiltInToolCatalogEntry> entries({
    required MemoryPromptLang lang,
    required bool legacyMemoryMode,
  }) {
    final result = <BuiltInToolCatalogEntry>[
      BuiltInToolCatalogEntry(
        name: SearchToolService.toolName,
        defaultDefinition: SearchToolService.getToolDefinition(),
        group: BuiltInToolGroup.search,
      ),
    ];
    final memoryDefinitions = legacyMemoryMode
        ? MemoryTools.legacyDefinitions(lang)
        : MemoryTools.catalogDefinitions(lang);
    for (final definition in memoryDefinitions) {
      final name = _nameOf(definition);
      if (name != null) {
        result.add(
          BuiltInToolCatalogEntry(
            name: name,
            defaultDefinition: definition,
            group: BuiltInToolGroup.memory,
          ),
        );
      }
    }

    final localDefinitions = LocalToolsService.buildToolDefinitions(
      assistant: const Assistant(
        id: 'tool-schema-catalog',
        name: 'tool-schema-catalog',
        localToolIds: LocalToolNames.all,
      ),
      supportsTools: true,
    );
    for (final definition in localDefinitions) {
      final name = _nameOf(definition);
      if (name != null) {
        result.add(
          BuiltInToolCatalogEntry(
            name: name,
            defaultDefinition: definition,
            group: BuiltInToolGroup.local,
          ),
        );
      }
    }
    for (final definition in WorkspaceToolsService.definitions()) {
      final name = _nameOf(definition);
      if (name != null) {
        result.add(
          BuiltInToolCatalogEntry(
            name: name,
            defaultDefinition: definition,
            group: BuiltInToolGroup.workspace,
          ),
        );
      }
    }
    return result;
  }

  static String? _nameOf(Map<String, dynamic> definition) {
    final function = definition['function'];
    final name = function is Map ? function['name'] : null;
    return name is String ? name : null;
  }
}
