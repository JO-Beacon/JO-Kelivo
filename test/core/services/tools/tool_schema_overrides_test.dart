import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/tool_schema_override.dart';
import 'package:Kelivo/core/services/search/search_tool_service.dart';
import 'package:Kelivo/core/services/tools/tool_schema_overrides.dart';
import 'package:Kelivo/features/home/services/local_tools_service.dart';

void main() {
  group('ToolSchemaOverrides.apply', () {
    test('overrides descriptions without mutating the original schema', () {
      final definitions = <Map<String, dynamic>>[
        SearchToolService.getToolDefinition(),
      ];
      final original = definitions.single;

      final result = ToolSchemaOverrides.apply(definitions, {
        SearchToolService.toolName: const ToolSchemaOverride(
          description: 'Custom search description',
          paramDescriptions: {'query': 'Custom query description'},
        ),
      });

      expect(identical(result.single, original), isFalse);
      final function = result.single['function'] as Map;
      expect(function['description'], 'Custom search description');
      expect(
        function['parameters']['properties']['query']['description'],
        'Custom query description',
      );
      expect(
        (original['function'] as Map)['description'],
        SearchToolService.toolDescription,
      );
    });

    test('ignores unknown tools, paths, and blank descriptions', () {
      final definitions = <Map<String, dynamic>>[
        SearchToolService.getToolDefinition(),
      ];
      final result = ToolSchemaOverrides.apply(definitions, {
        'unknown_mcp_tool': const ToolSchemaOverride(
          description: 'must not apply',
        ),
        SearchToolService.toolName: const ToolSchemaOverride(
          description: '   ',
          paramDescriptions: {'query': '', 'missing.path': 'must not apply'},
        ),
      });

      expect(identical(result, definitions), isTrue);
    });

    test('never applies a configured override to an MCP schema', () {
      final mcp = <String, dynamic>{
        'type': 'function',
        'function': {
          'name': 'echo',
          'description': 'MCP echo',
          'parameters': {
            'type': 'object',
            'properties': {
              'text': {'type': 'string', 'description': 'Text to echo'},
            },
          },
        },
      };

      final result = ToolSchemaOverrides.apply(
        <Map<String, dynamic>>[mcp],
        {
          'echo': const ToolSchemaOverride(
            description: 'must not apply',
            paramDescriptions: {'text': 'must not apply'},
          ),
        },
      );

      expect(identical(result.single, mcp), isTrue);
      expect((mcp['function'] as Map)['description'], 'MCP echo');
    });

    test('supports nested array item parameter paths', () {
      final definition =
          LocalToolsService.buildToolDefinitions(
            assistant: _toolCatalogAssistant,
            supportsTools: true,
          ).firstWhere(
            (item) =>
                (item['function'] as Map)['name'] == LocalToolNames.askUser,
          );

      final result = ToolSchemaOverrides.apply(
        <Map<String, dynamic>>[definition],
        {
          LocalToolNames.askUser: const ToolSchemaOverride(
            paramDescriptions: {
              'questions.items.id': 'Stable question identifier',
            },
          ),
        },
      );
      final items =
          (result.single['function']
                  as Map)['parameters']['properties']['questions']['items']
              as Map;
      expect(
        items['properties']['id']['description'],
        'Stable question identifier',
      );
    });
  });

  test(
    'describeParams lists nested paths without exposing structure editing',
    () {
      final definition =
          LocalToolsService.buildToolDefinitions(
            assistant: _toolCatalogAssistant,
            supportsTools: true,
          ).firstWhere(
            (item) =>
                (item['function'] as Map)['name'] == LocalToolNames.askUser,
          );

      final params = ToolSchemaOverrides.describeParams(definition);
      expect(
        params.map((param) => param.path),
        containsAll(<String>['questions', 'questions.items.id']),
      );
      final id = params.firstWhere(
        (param) => param.path == 'questions.items.id',
      );
      expect(id.type, 'string');
      expect(id.defaultDescription, isNotEmpty);
    },
  );
}

const _toolCatalogAssistant = Assistant(
  id: 'catalog',
  name: 'catalog',
  localToolIds: LocalToolNames.all,
);
