import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/memory/memory_tools.dart';
import 'package:Kelivo/core/services/search/search_tool_service.dart';
import 'package:Kelivo/features/home/services/built_in_tool_names.dart';
import 'package:Kelivo/features/home/services/local_tools_service.dart';

void main() {
  test('reserves all client built-in tool names', () {
    expect(
      BuiltInToolNames.all,
      containsAll(<String>[
        SearchToolService.toolName,
        'builtin_search',
        ...MemoryTools.allToolNames,
        ...MemoryTools.legacyToolNames,
        ...LocalToolNames.all,
      ]),
    );
  });
}
