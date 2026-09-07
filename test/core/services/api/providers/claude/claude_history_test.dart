import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_history.dart';
import 'package:Kelivo/core/utils/multimodal_input_utils.dart';

void main() {
  test(
    'replays hosted server tool blocks without an orphan tool result',
    () async {
      final history = ClaudeHistory(
        replayServerToolBlocks: true,
        skipRedactedThinkingBlocks: false,
      );
      final messages = await history.build([
        {'role': 'user', 'content': 'search'},
        {
          'role': 'assistant',
          'content': '\n\n',
          'tool_calls': [
            {
              'id': 'srv_1',
              'function': {'name': 'web_search', 'arguments': '{}'},
              'metadata': {
                'anthropic': {
                  'assistant_blocks': [
                    {
                      'type': 'server_tool_use',
                      'id': 'srv_1',
                      'name': 'web_search',
                      'input': {},
                    },
                    {
                      'type': 'web_search_tool_result',
                      'tool_use_id': 'srv_1',
                      'content': [],
                    },
                  ],
                },
              },
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'srv_1', 'content': 'ignored'},
        {'role': 'user', 'content': 'continue'},
      ]);

      expect(messages.map((message) => message['role']).toList(), [
        'user',
        'assistant',
        'user',
      ]);
      final blocks = (messages[1]['content'] as List).cast<Map>();
      expect(blocks.map((block) => block['type']).toList(), [
        'server_tool_use',
        'web_search_tool_result',
      ]);
      expect((messages[2]['content'] as String), 'continue');
    },
  );

  test(
    'drops a dangling hosted call when its result was never recorded',
    () async {
      final history = ClaudeHistory(
        replayServerToolBlocks: true,
        skipRedactedThinkingBlocks: false,
      );
      final messages = await history.build([
        {'role': 'user', 'content': 'search'},
        {
          'role': 'assistant',
          'content': '\n\n',
          'tool_calls': [
            {
              'id': 'srv_2',
              'function': {'name': 'web_search', 'arguments': '{}'},
              'metadata': {
                'anthropic': {
                  'assistant_blocks': [
                    {
                      'type': 'server_tool_use',
                      'id': 'srv_2',
                      'name': 'web_search',
                      'input': {},
                    },
                  ],
                },
              },
            },
          ],
        },
        {'role': 'user', 'content': 'next'},
      ]);

      expect(messages.map((message) => message['role']).toList(), [
        'user',
        'user',
      ]);
    },
  );

  test('replays multiple recorded responses around a client result', () async {
    final history = ClaudeHistory(
      replayServerToolBlocks: true,
      skipRedactedThinkingBlocks: false,
    );
    final messages = await history.build([
      {'role': 'user', 'content': 'start'},
      {
        'role': 'assistant',
        'content': '\n\n',
        multimodalInternalClaudeTurnKey:
            '[[{"type":"text","text":"first"},{"type":"tool_use","id":"tool_1","name":"lookup","input":{}}],[{"type":"text","text":"second"}]]',
        'tool_calls': [
          {
            'id': 'tool_1',
            'function': {'name': 'lookup', 'arguments': '{}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'tool_1', 'content': 'ok'},
      {'role': 'user', 'content': 'next'},
    ]);

    expect(messages.map((message) => message['role']).toList(), [
      'user',
      'assistant',
      'user',
      'assistant',
      'user',
    ]);
    expect(
      ((messages[2]['content'] as List).first as Map)['tool_use_id'],
      'tool_1',
    );
    expect(messages[3]['content'], [
      {'type': 'text', 'text': 'second'},
    ]);
  });
}
