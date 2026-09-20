import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/providers/mcp_provider.dart';
import 'package:Kelivo/core/services/mcp/mcp_config_import.dart';
import '../../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Claude Desktop and Cursor configs preserve arguments and infer HTTP',
    () {
      final servers = parseMcpConfigImport(
        jsonEncode({
          'mcpServers': {
            'local': {
              'command': 'uvx',
              'args': ['mcp-server-time', '', 'line1\nline2'],
              'env': {'KEY': '  value  '},
              'cwd': '/root',
            },
            'remote': {
              'url': 'https://example.com/mcp',
              'headers': {'Authorization': 'Bearer token'},
            },
            'events': {'type': 'sse', 'url': 'https://example.com/sse'},
          },
        }),
      );
      expect(servers[0].args, ['mcp-server-time', '', 'line1\nline2']);
      expect(servers[0].env['KEY'], '  value  ');
      expect(servers[0].workingDirectory, '/root');
      expect(servers[1].transport, McpTransportType.http);
      expect(servers[1].headers['Authorization'], 'Bearer token');
      expect(servers[2].transport, McpTransportType.sse);
    },
  );
  test('invalid entries reject the whole import', () {
    for (final invalid in [
      {
        'command': 'node',
        'args': [4],
      },
      {'type': 'stdio'},
      {'url': 'file:///secret'},
      {
        'command': 'npx',
        'env': {'TOKEN': 42},
      },
      {'type': 'unsupported', 'url': 'https://example.com'},
    ]) {
      expect(
        () => parseMcpConfigImport(
          jsonEncode({
            'mcpServers': {'invalid': invalid},
          }),
        ),
        throwsFormatException,
      );
    }
  });
  test(
    'import appends duplicate names and keeps saved servers intact',
    () async {
      final harness = await createBusinessTestHarness();
      final provider = McpProvider(preferences: harness.preferences);
      addTearDown(provider.dispose);
      await provider.replaceAllFromJson(
        jsonEncode({
          'mcpServers': {
            'existing': {'command': 'sh', 'isActive': false},
          },
        }),
      );
      final previous = provider.exportServersAsUiJson();
      final imported = parseMcpConfigImport(
        jsonEncode({
          'mcpServers': {
            'existing': {'command': 'node', 'disabled': true},
          },
        }),
      );
      await provider.importServers(imported);
      expect(provider.getById('existing')!.command, 'sh');
      expect(provider.getById(imported.single.id)!.command, 'node');
      final after = jsonDecode(provider.exportServersAsUiJson())['mcpServers'];
      for (final entry in (jsonDecode(previous)['mcpServers'] as Map).entries) {
        expect(after[entry.key], entry.value);
      }
    },
  );
  test('导入中出现重复 ID 时不写入前面的有效配置', () async {
    final harness = await createBusinessTestHarness();
    final provider = McpProvider(preferences: harness.preferences);
    addTearDown(provider.dispose);
    await provider.loaded;
    await provider.importServers([
      McpServerConfig(
        id: 'saved',
        enabled: false,
        name: 'Saved',
        transport: McpTransportType.stdio,
        command: 'sh',
      ),
    ]);
    final before = provider.exportServersAsUiJson();
    await expectLater(
      provider.importServers([
        McpServerConfig(
          id: 'new',
          enabled: false,
          name: 'New',
          transport: McpTransportType.stdio,
          command: 'node',
        ),
        McpServerConfig(
          id: 'saved',
          enabled: false,
          name: 'Overwrite',
          transport: McpTransportType.stdio,
          command: 'other',
        ),
      ]),
      throwsFormatException,
    );
    expect(provider.exportServersAsUiJson(), before);
    expect(provider.getById('new'), isNull);
    await provider.importServers([]);
    expect(provider.exportServersAsUiJson(), before);
  });
}
