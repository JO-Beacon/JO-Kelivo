import 'dart:convert';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/builtin_tools.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_decoder.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_files.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_container.dart';
import 'package:Kelivo/core/utils/multimodal_input_utils.dart';
import 'package:Kelivo/core/services/api/stream/sse_event.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

SseEvent _event(String type, Map<String, dynamic> data) =>
    SseEvent(event: type, data: jsonEncode(data));

ProviderConfig _config(String baseUrl) => ProviderConfig(
  id: 'ClaudeServerToolsTest',
  enabled: true,
  name: 'ClaudeServerToolsTest',
  apiKey: 'test-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.claude,
);

void main() {
  test('builds Claude server tools only for the official endpoint', () {
    final enabled = {BuiltInToolNames.webFetch, BuiltInToolNames.codeExecution};
    final official = BuiltInToolsHelper.claudeServerToolEntries(
      cfg: _config('https://api.anthropic.com'),
      modelId: 'claude-sonnet-4-6',
      enabled: enabled,
    );
    expect(
      official.map((tool) => tool['name']),
      containsAll(<String>['web_fetch', 'code_execution']),
    );
    expect(
      BuiltInToolsHelper.claudeServerToolEntries(
        cfg: _config('https://relay.example.test'),
        modelId: 'claude-sonnet-4-6',
        enabled: enabled,
      ),
      isEmpty,
    );
  });

  test('decodes web_fetch result and reports failures', () {
    final decoder = ClaudeStreamDecoder(serverToolNames: const {'web_fetch'});
    final start = decoder.accept(
      _event('content_block_start', {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'server_tool_use',
          'id': 'fetch_1',
          'name': 'web_fetch',
          'input': {},
        },
      }),
    );
    expect(
      start.chunks.whereType<ServerToolStart>().single.toolName,
      'web_fetch',
    );

    final result = decoder.accept(
      _event('content_block_start', {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'web_fetch_tool_result',
          'tool_use_id': 'fetch_1',
          'content': {'type': 'web_fetch_result', 'content': 'page'},
        },
      }),
    );
    expect(
      result.chunks.whereType<ServerToolEnd>().single.status,
      ServerToolStatus.completed,
    );

    final failed = ClaudeStreamDecoder().decodeCompleteServerTools([
      {
        'type': 'server_tool_use',
        'id': 'exec_1',
        'name': 'code_execution',
        'input': {},
      },
      {
        'type': 'code_execution_tool_result',
        'tool_use_id': 'exec_1',
        'content': {
          'type': 'code_execution_tool_result_error',
          'error_code': 'failed',
        },
      },
    ]);
    expect(
      failed.whereType<ServerToolEnd>().single.status,
      ServerToolStatus.failed,
    );
  });

  test('extracts generated file ids and sanitizes provider file names', () {
    expect(
      claudeGeneratedFileIds({
        'content': [
          {'file_id': 'file_1'},
          {'type': 'text', 'text': 'ignored'},
          {'file_id': 'file_2'},
        ],
      }),
      ['file_1', 'file_2'],
    );
    expect(claudeGeneratedFileName(r'..\CON.txt'), '_CON.txt');
    expect(claudeGeneratedFileName('../report?.csv'), 'report_.csv');
    expect(claudeGeneratedFileName('...'), 'download');
  });

  test('recognizes sandbox data files and stale container errors', () {
    expect(isSandboxDataFile(fileName: 'table.csv', mime: 'text/csv'), isTrue);
    expect(
      isSandboxDataFile(fileName: 'notes.txt', mime: 'text/plain'),
      isFalse,
    );
    expect(
      isClaudeStaleContainerError(400, 'container does not exist'),
      isTrue,
    );
    expect(
      isClaudeStaleContainerError(400, 'container_upload is invalid'),
      isFalse,
    );
    expect(isClaudeStaleContainerError(500, 'container expired'), isFalse);
  });
}
