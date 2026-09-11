import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/api/providers/claude/claude_role_normalizer.dart';

void main() {
  tearDown(() {
    ClaudeFirstTurnPlaceholderConfig.enabled = false;
    ClaudeFirstTurnPlaceholderConfig.text = claudeFirstTurnPlaceholder;
  });

  group('normalizeClaudeFirstTurnPlaceholder', () {
    test('去掉首尾空白', () {
      expect(normalizeClaudeFirstTurnPlaceholder('  #  '), '#');
    });

    test('把换行和制表压成单个空格', () {
      expect(normalizeClaudeFirstTurnPlaceholder('a\n\tb'), 'a b');
      expect(normalizeClaudeFirstTurnPlaceholder('\n#\r\n'), '#');
    });

    test('只有空白时返回空串', () {
      expect(normalizeClaudeFirstTurnPlaceholder(''), isEmpty);
      expect(normalizeClaudeFirstTurnPlaceholder('   '), isEmpty);
      expect(normalizeClaudeFirstTurnPlaceholder('\n\t '), isEmpty);
    });

    test('超长内容截到上限', () {
      final long = 'x' * (claudeFirstTurnPlaceholderMaxLength + 10);
      expect(
        normalizeClaudeFirstTurnPlaceholder(long).length,
        claudeFirstTurnPlaceholderMaxLength,
      );
    });
  });

  group('ensureClaudeFirstTurnIsUser', () {
    test('开关打开时，以回复开头的请求补上默认占位', () {
      ClaudeFirstTurnPlaceholderConfig.enabled = true;
      final messages = <Map<String, dynamic>>[
        {'role': 'assistant', 'content': '分支起点'},
        {'role': 'user', 'content': '继续'},
      ];

      ensureClaudeFirstTurnIsUser(messages);

      expect(messages, hasLength(3));
      expect(messages.first['role'], 'user');
      expect(messages.first['content'], claudeFirstTurnPlaceholder);
    });

    test('开关关闭时请求原样发出', () {
      ClaudeFirstTurnPlaceholderConfig.enabled = false;
      final messages = <Map<String, dynamic>>[
        {'role': 'assistant', 'content': '分支起点'},
      ];

      ensureClaudeFirstTurnIsUser(messages);

      expect(messages, hasLength(1));
      expect(messages.single['role'], 'assistant');
    });

    test('自定义内容进入请求', () {
      ClaudeFirstTurnPlaceholderConfig.enabled = true;
      ClaudeFirstTurnPlaceholderConfig.text = '  下划线_  ';
      final messages = <Map<String, dynamic>>[
        {'role': 'assistant', 'content': '分支起点'},
      ];

      ensureClaudeFirstTurnIsUser(messages);

      expect(messages.first['content'], '下划线_');
    });

    test('内容只有空白时等同不补位', () {
      ClaudeFirstTurnPlaceholderConfig.enabled = true;
      ClaudeFirstTurnPlaceholderConfig.text = '   ';
      final messages = <Map<String, dynamic>>[
        {'role': 'assistant', 'content': '分支起点'},
      ];

      ensureClaudeFirstTurnIsUser(messages);

      expect(messages, hasLength(1));
      expect(ClaudeFirstTurnPlaceholderConfig.filler, isNull);
    });

    test('以用户消息开头、或空数组时不改动', () {
      final userFirst = <Map<String, dynamic>>[
        {'role': 'user', 'content': '你好'},
        {'role': 'assistant', 'content': '在的'},
      ];
      ensureClaudeFirstTurnIsUser(userFirst);
      expect(userFirst, hasLength(2));

      final empty = <Map<String, dynamic>>[];
      ensureClaudeFirstTurnIsUser(empty);
      expect(empty, isEmpty);
    });
  });
}
