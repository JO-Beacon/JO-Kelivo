import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_history.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_role_normalizer.dart';
import 'package:Kelivo/core/utils/multimodal_input_utils.dart';

/// 首条消息占位是进程级静态开关，用例改动后必须还原，
/// 否则会污染同文件里其他用例。
void _resetPlaceholderConfig() {
  ClaudeFirstTurnPlaceholderConfig.enabled = false;
  ClaudeFirstTurnPlaceholderConfig.text = claudeFirstTurnPlaceholder;
}

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

  test(
    'a history beginning at an assistant reply opens with a placeholder',
    () async {
      // 开关默认关闭（产品决定），这里显式打开才能验证补位逻辑。
      ClaudeFirstTurnPlaceholderConfig.enabled = true;
      addTearDown(_resetPlaceholderConfig);
      final history = ClaudeHistory(
        replayServerToolBlocks: true,
        skipRedactedThinkingBlocks: false,
      );
      // What a conversation cut to start at a reply — a branch root, or a context
      // window that begins after the opening question — hands the API.
      final messages = await history.build([
        {'role': 'assistant', 'content': 'the reply the branch starts on'},
        {'role': 'user', 'content': 'and then?'},
      ]);

      expect(messages.map((message) => message['role']).toList(), [
        'user',
        'assistant',
        'user',
      ]);
      expect(messages.first['content'], claudeFirstTurnPlaceholder);
      expect(messages[1]['content'], 'the reply the branch starts on');
    },
  );

  test('a history already opening at a user turn is left untouched', () async {
    // 开关打开也应当不动：首条已是 user，无需补位。
    ClaudeFirstTurnPlaceholderConfig.enabled = true;
    addTearDown(_resetPlaceholderConfig);
    final history = ClaudeHistory(
      replayServerToolBlocks: true,
      skipRedactedThinkingBlocks: false,
    );
    final messages = await history.build([
      {'role': 'user', 'content': 'one'},
      {'role': 'user', 'content': 'two'},
      {'role': 'assistant', 'content': 'reply'},
    ]);

    // The API merges the run of user turns itself, so no placeholder is added.
    expect(messages.map((message) => message['role']).toList(), [
      'user',
      'user',
      'assistant',
    ]);
  });
}
