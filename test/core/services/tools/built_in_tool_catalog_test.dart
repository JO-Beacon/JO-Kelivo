import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/memory/memory_prompts.dart';
import 'package:Kelivo/core/services/memory/memory_tools.dart';
import 'package:Kelivo/core/services/search/search_tool_service.dart';
import 'package:Kelivo/core/services/tools/built_in_tool_catalog.dart';
import 'package:Kelivo/core/services/tools/tool_schema_overrides.dart';
import 'package:Kelivo/core/models/tool_schema_override.dart';
import 'package:Kelivo/core/services/workspace/workspace_tools_service.dart';
import 'package:Kelivo/features/home/services/local_tools_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog contains all current ungated built-in groups', () {
    final entries = BuiltInToolCatalog.entries(
      lang: MemoryPromptLang.en,
      legacyMemoryMode: false,
    );
    final names = entries.map((entry) => entry.name).toSet();

    expect(names, contains(SearchToolService.toolName));
    expect(names, containsAll(MemoryTools.allToolNames));
    expect(
      names,
      containsAll(<String>{
        LocalToolNames.timeInfo,
        LocalToolNames.clipboard,
        LocalToolNames.textToSpeech,
        LocalToolNames.askUser,
        LocalToolNames.calculate,
      }),
    );
    expect(
      entries.map((entry) => entry.group).toSet(),
      BuiltInToolGroup.values.toSet(),
    );
  });

  setUp(DeviceLocalTools.debugResetIosCapabilities);

  test(
    'workspace catalog includes every executable schema and accepts overrides',
    () {
      final entries = BuiltInToolCatalog.entries(
        lang: MemoryPromptLang.en,
        legacyMemoryMode: false,
      ).where((entry) => entry.group == BuiltInToolGroup.workspace).toList();
      expect(
        entries.map((e) => e.name).toSet(),
        WorkspaceToolsService.toolNames,
      );
      expect(
        entries.map((e) => e.defaultDefinition).toList(),
        WorkspaceToolsService.definitions(),
      );
      final result = ToolSchemaOverrides.apply(
        WorkspaceToolsService.definitions(),
        {
          'read_file': const ToolSchemaOverride(
            description: 'Custom file reader',
          ),
        },
      );
      final read = result.singleWhere(
        (d) => d['function']['name'] == 'read_file',
      );
      expect(read['function']['description'], 'Custom file reader');
      expect(read['function']['parameters']['required'], ['path']);
    },
  );
  tearDown(() {
    DeviceLocalTools.debugResetIosCapabilities();
    debugDefaultTargetPlatformOverride = null;
  });

  test('legacy memory mode exposes only legacy memory tool schemas', () {
    final entries = BuiltInToolCatalog.entries(
      lang: MemoryPromptLang.zh,
      legacyMemoryMode: true,
    );
    final memoryNames = entries
        .where((entry) => entry.group == BuiltInToolGroup.memory)
        .map((entry) => entry.name)
        .toSet();

    expect(memoryNames, <String>{
      'create_memory',
      'edit_memory',
      'delete_memory',
    });
  });
}
