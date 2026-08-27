import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/features/home/controllers/home_view_model.dart';

ChatMessage _message({
  required String id,
  required String role,
  required String content,
  String? groupId,
  int version = 0,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: 'conversation-1',
    groupId: groupId ?? id,
    version: version,
  );
}

void main() {
  group('buildCompressContextContent', () {
    test('短内容在限制内保持原样', () {
      const joined = 'User: hello\n\nAssistant: hi';

      expect(
        buildCompressContextContent(
          joined,
          const CompressContextOptions(
            mode: CompressContextLimitMode.start,
            maxChars: 6000,
          ),
        ),
        joined,
      );
    });

    test('超长内容可保留开头', () {
      final early = 'User: first round\n\nAssistant: early answer\n\n';
      final middle = 'x' * 6000;
      final latest = '\n\nUser: thirtieth round\n\nAssistant: latest answer';
      final joined = '$early$middle$latest';

      final content = buildCompressContextContent(
        joined,
        const CompressContextOptions(
          mode: CompressContextLimitMode.start,
          maxChars: 6000,
        ),
      );

      expect(content.length, 6000);
      expect(content, contains('first round'));
      expect(content, isNot(contains('thirtieth round')));
    });

    test('超长内容可保留最近尾部', () {
      final early = 'User: first round\n\nAssistant: early answer\n\n';
      final middle = 'x' * 6000;
      final latest = '\n\nUser: thirtieth round\n\nAssistant: latest answer';
      final joined = '$early$middle$latest';

      final content = buildCompressContextContent(
        joined,
        const CompressContextOptions(
          mode: CompressContextLimitMode.recent,
          maxChars: 6000,
        ),
      );

      expect(content.length, 6000);
      expect(content, isNot(contains('first round')));
      expect(content, contains('thirtieth round'));
    });

    test('无限制保留完整内容', () {
      final joined = 'a' * 7000;

      final content = buildCompressContextContent(
        joined,
        const CompressContextOptions(mode: CompressContextLimitMode.unlimited),
      );

      expect(content, joined);
    });
  });

  group('buildConversationTextForCompression', () {
    test('使用完整历史生成压缩文本', () {
      final visibleWindow = [
        _message(id: 'u80', role: 'user', content: 'visible user'),
        _message(id: 'a81', role: 'assistant', content: 'visible assistant'),
      ];
      final completeHistory = [
        _message(id: 'u0', role: 'user', content: 'earliest user'),
        _message(id: 'a1', role: 'assistant', content: 'earliest assistant'),
        ...visibleWindow,
      ];

      final text = buildConversationTextForCompression(completeHistory);

      expect(text, contains('User: earliest user'));
      expect(text, contains('Assistant: earliest assistant'));
      expect(text, contains('User: visible user'));
      expect(text, contains('Assistant: visible assistant'));
    });

    test('压缩文本会忽略空内容消息', () {
      final text = buildConversationTextForCompression([
        _message(id: 'u1', role: 'user', content: '  '),
        _message(id: 'a1', role: 'assistant', content: 'answer'),
      ]);

      expect(text, 'Assistant: answer');
    });
  });

  group('compression safety helpers', () {
    test(
      'keep-recent selects from the last user turn and preserves its tail',
      () {
        final messages = [
          _message(id: 'u1', role: 'user', content: 'old question'),
          _message(id: 'a1', role: 'assistant', content: 'old answer'),
          _message(id: 'u2', role: 'user', content: 'recent question'),
          _message(id: 'a2', role: 'assistant', content: 'recent answer'),
          _message(id: 'tool2', role: 'tool', content: 'tool output'),
        ];

        final kept = selectKeepRecentMessages(messages, 1);

        expect(kept.map((message) => message.id), ['u2', 'a2', 'tool2']);
        expect(countUserMessages(messages), 2);
        expect(defaultKeepUserMessageCountFor(2), 1);
      },
    );

    test('keep-recent token estimate is bounded by original tokens', () {
      final estimate = estimateCompressionTokens(
        totalText: '用户问题很长\n\nAssistant: answer',
        keptText: '用户问题很长',
      );

      expect(estimate.totalTokens, greaterThan(0));
      expect(estimate.keptTokens, lessThanOrEqualTo(estimate.totalTokens));
      expect(
        estimate.minResultTokens,
        lessThanOrEqualTo(estimate.maxResultTokens),
      );
    });

    test('压缩模型按上游优先级解析', () {
      final resolved = resolveCompressContextModel(
        compressProvider: 'OpenAI',
        compressModelId: 'gpt-4o-mini',
        summaryProvider: 'Gemini',
        summaryModelId: 'gemini-2.5-flash',
        currentProvider: 'DeepSeek',
        currentModelId: 'deepseek-chat',
      );
      expect(resolved.providerKey, 'OpenAI');
      expect(resolved.modelId, 'gpt-4o-mini');
    });

    test('未设置压缩模型时按现有回退链解析', () {
      final resolved = resolveCompressContextModel(
        titleProvider: 'OpenAI',
        titleModelId: 'gpt-4o-mini',
        assistantProvider: 'Claude',
        assistantModelId: 'claude-sonnet',
        currentProvider: 'DeepSeek',
        currentModelId: 'deepseek-chat',
      );
      expect(resolved, (providerKey: 'OpenAI', modelId: 'gpt-4o-mini'));
    });

    test('model context override produces a bounded request budget', () {
      expect(parseContextWindow({'context_window': '8192'}), 8192);
      final budget = compressionRequestCharBudget(
        options: const CompressContextOptions(
          mode: CompressContextLimitMode.unlimited,
        ),
        contextWindow: 2048,
      );
      expect(budget, 636);
    });

    test('unlimited input is chunked at message boundaries', () {
      final chunks = buildCompressRequestContents(
        [
          _message(id: 'u1', role: 'user', content: 'a' * 4),
          _message(id: 'a1', role: 'assistant', content: 'b' * 4),
        ],
        options: const CompressContextOptions(
          mode: CompressContextLimitMode.unlimited,
        ),
        maxCodeUnits: 16,
      );
      expect(chunks, ['User: aaaa', 'Assistant: bbbb']);
    });

    test('context length errors are retried with safe halves', () async {
      final seen = <String>[];
      final result = await summarizeWithContextRetry(
        content: 'abcdefgh',
        generate: (content) async {
          seen.add(content);
          if (content.length > 2) throw Exception('maximum context length');
          return content.toUpperCase();
        },
      );
      expect(result, 'AB\n\nCD\n\nEF\n\nGH');
      expect(seen.first, 'abcdefgh');
    });

    test('non-context errors are not swallowed', () async {
      expect(
        () => summarizeWithContextRetry(
          content: 'abcdef',
          generate: (_) async => throw Exception('network unavailable'),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('HomeViewModel.computeClearContextRemainingMessageCount', () {
    test('计数来自持久化总数，与窗口缓存无关', () {
      final count = HomeViewModel.computeClearContextRemainingMessageCount(
        totalMessages: 100,
        truncateIndex: -1,
      );

      expect(count, 100);
    });

    test('已有清空点时从持久化截断位置开始计数', () {
      final count = HomeViewModel.computeClearContextRemainingMessageCount(
        totalMessages: 100,
        truncateIndex: 90,
      );

      expect(count, 10);
    });

    test('截断位置越界时按未清空处理', () {
      final beyond = HomeViewModel.computeClearContextRemainingMessageCount(
        totalMessages: 100,
        truncateIndex: 101,
      );
      final atEnd = HomeViewModel.computeClearContextRemainingMessageCount(
        totalMessages: 100,
        truncateIndex: 100,
      );

      expect(beyond, 100);
      expect(atEnd, 0);
    });
  });
}
