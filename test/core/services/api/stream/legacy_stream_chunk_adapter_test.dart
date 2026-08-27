import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/models/token_usage.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/api/stream/legacy_stream_chunk_adapter.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk_handler.dart';

void main() {
  test(
    'maps interleaved legacy fields to ordered provider-independent parts',
    () {
      final events = legacyChunkToEvents(
        ChatStreamChunk(
          content: 'answer',
          reasoning: 'think',
          isDone: false,
          totalTokens: 0,
          toolCalls: <ToolCallInfo>[
            ToolCallInfo(
              id: 'call-1',
              name: 'lookup',
              arguments: <String, dynamic>{'q': 'value'},
            ),
          ],
          toolResults: <ToolResultInfo>[
            ToolResultInfo(
              id: 'call-1',
              name: 'lookup',
              arguments: <String, dynamic>{'q': 'value'},
              content: 'result',
            ),
          ],
        ),
      );

      final result = StreamChunkHandler.collect(events);

      expect(result.parts, hasLength(3));
      expect(result.parts[0], isA<ReasoningPart>());
      expect(result.parts[1], isA<ToolCallPart>());
      expect(result.parts[2], isA<TextPart>());
      expect((result.parts[0] as ReasoningPart).text, 'think');
      expect((result.parts[2] as TextPart).text, 'answer');
    },
  );

  test('omits empty deltas but preserves usage and finish', () {
    final events = legacyChunkToEvents(
      ChatStreamChunk(
        content: '',
        reasoning: '',
        isDone: true,
        totalTokens: 4,
        usage: const TokenUsage(totalTokens: 4),
      ),
    ).toList();

    expect(events.whereType<TextDelta>(), isEmpty);
    expect(events.whereType<ReasoningDelta>(), isEmpty);
    expect(events.whereType<Usage>(), hasLength(1));
    expect(events.whereType<Finish>(), hasLength(1));
  });

  test('keeps consecutive legacy text chunks in one logical part', () {
    final events = <StreamChunk>[
      ...legacyChunkToEvents(
        ChatStreamChunk(content: 'hel', isDone: false, totalTokens: 0),
      ),
      ...legacyChunkToEvents(
        ChatStreamChunk(content: 'lo', isDone: true, totalTokens: 0),
      ),
    ];

    final result = StreamChunkHandler.collect(events);

    expect(result.parts, hasLength(1));
    expect((result.parts.single as TextPart).text, 'hello');
  });
}
