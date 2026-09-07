import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/memory/memory_prompts.dart';
import 'package:Kelivo/core/services/memory/memory_tools.dart';
import 'package:Kelivo/core/services/search/search_tool_service.dart';
import 'package:Kelivo/core/services/tools/built_in_tool_catalog.dart';
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
