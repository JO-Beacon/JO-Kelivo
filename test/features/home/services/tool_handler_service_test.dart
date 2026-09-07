import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/tool_schema_override.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/mcp_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/mcp/mcp_tool_service.dart';
import 'package:Kelivo/core/services/search/search_tool_service.dart';
import 'package:Kelivo/features/home/services/tool_handler_service.dart';

import '../../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ToolHandlerService tool schema sanitization', () {
    for (final kind in const [ProviderKind.openai, ProviderKind.claude]) {
      test('preserves and sanitizes additionalProperties for $kind', () {
        final input = <String, dynamic>{
          'type': 'object',
          'additionalProperties': true,
          'properties': {
            'config': {
              'type': 'object',
              'additionalProperties': {
                r'$schema': 'https://json-schema.org/draft/2020-12/schema',
                'type': 'string',
                'const': 'enabled',
              },
            },
            'entries': {
              'type': 'array',
              'items': {'type': 'object', 'additionalProperties': false},
            },
          },
        };

        final output = ToolHandlerService.sanitizeToolParametersForProvider(
          input,
          kind,
        );

        expect(output['additionalProperties'], isTrue);
        final properties = output['properties'] as Map<String, dynamic>;
        expect(
          (properties['config'] as Map)['additionalProperties'],
          <String, dynamic>{
            'type': 'string',
            'enum': ['enabled'],
          },
        );
        expect(
          ((properties['entries'] as Map)['items']
              as Map)['additionalProperties'],
          isFalse,
        );
      });
    }

    test('continues to drop additionalProperties for Google', () {
      final output = ToolHandlerService.sanitizeToolParametersForProvider({
        'type': 'object',
        'additionalProperties': true,
        'properties': {
          'config': {'type': 'object', 'additionalProperties': true},
        },
      }, ProviderKind.google);

      expect(output, isNot(contains('additionalProperties')));
      expect(
        output['properties']['config'],
        isNot(contains('additionalProperties')),
      );
    });

    test('preserves scalar types when converting const to enum', () {
      final output = ToolHandlerService.sanitizeToolParametersForProvider({
        'type': 'object',
        'properties': {
          'enabled': {'const': true},
          'retries': {'const': 2},
        },
      }, ProviderKind.google);

      final properties = output['properties'] as Map<String, dynamic>;
      expect(properties['enabled'], {
        'type': 'boolean',
        'enum': [true],
      });
      expect(properties['retries'], {
        'type': 'integer',
        'enum': [2],
      });
    });
  });

  testWidgets(
    'buildToolDefinitions applies built-in description overrides at the final outlet',
    (tester) async {
      final settings = SettingsProvider(createBusinessTestPreferences());
      final assistants = AssistantProvider(
        preferences: createBusinessTestPreferences(),
      );
      final mcp = McpProvider(preferences: createBusinessTestPreferences());
      final mcpTools = McpToolService();
      addTearDown(settings.dispose);
      addTearDown(assistants.dispose);
      addTearDown(mcp.dispose);
      addTearDown(mcpTools.dispose);
      await settings.loaded;
      await assistants.loaded;
      await settings.setToolSchemaOverride(
        SearchToolService.toolName,
        const ToolSchemaOverride(
          description: 'Search only when fresh sources are required.',
          paramDescriptions: {'query': 'Use a precise source-oriented query.'},
        ),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
            ChangeNotifierProvider<McpProvider>.value(value: mcp),
            ChangeNotifierProvider<McpToolService>.value(value: mcpTools),
          ],
          child: const SizedBox.shrink(),
        ),
      );
      final service = ToolHandlerService(
        contextProvider: tester.element(find.byType(SizedBox)),
      );
      final definitions = service.buildToolDefinitions(
        settings,
        const Assistant(
          id: 'assistant',
          name: 'Assistant',
          searchEnabled: true,
        ),
        'OpenAI',
        'gpt-5',
        false,
        isToolModel: (_, __) => true,
      );
      final search = definitions.firstWhere(
        (definition) =>
            (definition['function'] as Map)['name'] ==
            SearchToolService.toolName,
      );
      final function = search['function'] as Map;

      expect(
        function['description'],
        'Search only when fresh sources are required.',
      );
      expect(
        function['parameters']['properties']['query']['description'],
        'Use a precise source-oriented query.',
      );
      expect(function['name'], SearchToolService.toolName);
      expect(function['parameters']['required'], <String>['query']);
    },
  );
}
