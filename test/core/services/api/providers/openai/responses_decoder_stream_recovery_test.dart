import 'dart:convert';

import 'package:Kelivo/core/services/api/providers/openai/responses_decoder.dart';
import 'package:Kelivo/core/services/api/stream/sse_event.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

SseEvent _event(Map<String, dynamic> data) => SseEvent(data: jsonEncode(data));

void main() {
  test('malformed frame keeps parsed chunks and later text still decodes', () {
    final decoder = ResponsesStreamDecoder();
    final first = decoder.accept(
      _event({'type': 'response.output_text.delta', 'delta': 'Hello'}),
    );
    final textId = first.chunks.whereType<TextDelta>().single.id;

    final started = decoder.accept(
      _event({
        'type': 'response.output_item.added',
        'output_index': 0,
        'item': {
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'lookup',
        },
      }),
    );
    expect(started.chunks.whereType<ToolCallStart>().single.id, 'call_1');

    final malformed = decoder.accept(
      _event({
        'type': 'response.function_call_arguments.delta',
        'output_index': 'bad',
        'delta': '{"q":',
      }),
    );
    expect(malformed.completed, isFalse);
    expect(malformed.chunks, isEmpty);

    final later = decoder.accept(
      _event({'type': 'response.output_text.delta', 'delta': ' world'}),
    );
    expect(later.chunks.whereType<TextDelta>().single.text, ' world');
    expect(later.chunks.whereType<TextDelta>().single.id, textId);

    final delta = decoder.accept(
      _event({
        'type': 'response.function_call_arguments.delta',
        'output_index': 0,
        'delta': '{"q":"kelivo"}',
      }),
    );
    expect(delta.chunks.whereType<ToolCallDelta>().single.id, 'call_1');
  });
}
