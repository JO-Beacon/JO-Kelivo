import 'dart:convert';

import 'package:Kelivo/core/services/api/providers/google/google_decoder.dart';
import 'package:Kelivo/core/services/api/stream/sse_event.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

SseEvent _event(Map<String, dynamic> data) {
  return SseEvent(data: jsonEncode(data));
}

Map<String, dynamic> _candidate({
  List<Map<String, dynamic>> parts = const <Map<String, dynamic>>[],
  String? finishReason,
  Map<String, dynamic>? grounding,
}) {
  return <String, dynamic>{
    'candidates': [
      <String, dynamic>{
        'content': <String, dynamic>{'parts': parts},
        if (finishReason != null) 'finishReason': finishReason,
        if (grounding != null) 'groundingMetadata': grounding,
      },
    ],
  };
}

void main() {
  test('malformed frame keeps parsed chunks and later text still decodes', () {
    final decoder = GoogleStreamDecoder();
    final first = decoder.accept(
      _event(
        _candidate(
          parts: [
            <String, dynamic>{'text': 'Hello'},
          ],
        ),
      ),
    );
    final textId = first.chunks.whereType<TextDelta>().single.id;

    final malformed = decoder.accept(
      _event(<String, dynamic>{
        'usageMetadata': <String, dynamic>{
          'promptTokenCount': 1,
          'candidatesTokenCount': 1,
          'totalTokens': 2,
        },
        ..._candidate(
          parts: [
            <String, dynamic>{'text': 123},
          ],
        ),
      }),
    );
    expect(malformed.completed, isFalse);
    expect(malformed.chunks.whereType<Usage>(), isNotEmpty);

    final later = decoder.accept(
      _event(
        _candidate(
          parts: [
            <String, dynamic>{'text': ' world'},
          ],
        ),
      ),
    );
    expect(later.chunks.whereType<TextDelta>().single.text, ' world');
    expect(later.chunks.whereType<TextDelta>().single.id, textId);
  });
}
