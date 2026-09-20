import 'dart:convert';

import 'package:Kelivo/core/services/api/providers/claude/claude_decoder.dart';
import 'package:Kelivo/core/services/api/stream/sse_event.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

SseEvent _event(String type, Map<String, dynamic> data) {
  return SseEvent(event: type, data: jsonEncode(data));
}

void main() {
  test('malformed frame keeps parsed chunks and later text still decodes', () {
    final decoder = ClaudeStreamDecoder();
    decoder.accept(
      _event('content_block_start', {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text', 'text': ''},
      }),
    );
    final first = decoder.accept(
      _event('content_block_delta', {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'Hello'},
      }),
    );
    final textId = first.chunks.whereType<TextDelta>().single.id;

    decoder.accept(
      _event('content_block_start', {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {'type': 'tool_use', 'id': 'call_1', 'name': 'lookup'},
      }),
    );

    final malformed = decoder.accept(const SseEvent(data: '{not-json'));
    expect(malformed.completed, isFalse);
    expect(malformed.chunks, isEmpty);

    final later = decoder.accept(
      _event('content_block_delta', {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': ' world'},
      }),
    );
    expect(later.chunks.whereType<TextDelta>().single.text, ' world');
    expect(later.chunks.whereType<TextDelta>().single.id, textId);

    final toolDelta = decoder.accept(
      _event('content_block_delta', {
        'type': 'content_block_delta',
        'index': 1,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"q":'},
      }),
    );
    expect(toolDelta.chunks.whereType<ToolCallDelta>().single.id, 'call_1');
    expect(decoder.clientTools['call_1']!.input.toString(), '{"q":');
  });
}
