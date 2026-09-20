import 'dart:convert';

import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/services/api/providers/openai/chat_completions_decoder.dart';
import 'package:Kelivo/core/services/api/stream/sse_event.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk_handler.dart';
import 'package:flutter_test/flutter_test.dart';

SseEvent _event(Map<String, dynamic> data) => SseEvent(data: jsonEncode(data));

Map<String, dynamic> _choice({
  Map<String, dynamic>? delta,
  Map<String, dynamic>? message,
  String? finishReason,
}) {
  return <String, dynamic>{
    'choices': [
      <String, dynamic>{
        if (delta != null) 'delta': delta,
        if (message != null) 'message': message,
        'finish_reason': finishReason,
      },
    ],
  };
}

void main() {
  test('complete message ignores invalid tool indexes', () {
    final decoder = ChatCompletionsStreamDecoder();
    final result = decoder.accept(
      _event(
        _choice(
          message: <String, dynamic>{
            'content': '正文仍然保留。',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 0,
                'id': 'call_lookup',
                'function': <String, dynamic>{
                  'name': 'lookup',
                  'arguments': '{}',
                },
              },
              <String, dynamic>{
                'index': null,
                'id': 'call_notify',
                'function': <String, dynamic>{
                  'name': 'notify',
                  'arguments': '{}',
                },
              },
              <String, dynamic>{
                'index': 0.9,
                'id': 'call_fractional',
                'function': <String, dynamic>{
                  'name': 'fractional',
                  'arguments': '{"unexpected":0.9}',
                },
              },
              <String, dynamic>{
                'index': -1,
                'id': 'call_negative',
                'function': <String, dynamic>{
                  'name': 'negative',
                  'arguments': '{"unexpected":-1}',
                },
              },
            ],
          },
          finishReason: 'tool_calls',
        ),
      ),
    );

    expect(result.chunks.whereType<TextDelta>().single.text, '正文仍然保留。');
    expect(decoder.toolCalls, <int, Map<String, dynamic>>{
      0: <String, dynamic>{
        'id': 'call_lookup',
        'series_id': 'call_lookup',
        'name': 'lookup',
        'args': '{}',
      },
      1: <String, dynamic>{
        'id': 'call_notify',
        'series_id': 'call_notify',
        'name': 'notify',
        'args': '{}',
      },
    });
    expect(
      result.chunks.whereType<ToolCallStart>().map((chunk) => chunk.toolName),
      <String>['lookup', 'notify'],
    );
    expect(result.chunks.whereType<ToolCallEnd>(), hasLength(2));
  });

  test('complete message fallback avoids an earlier sparse index', () {
    for (final explicitNull in <bool>[false, true]) {
      final decoder = ChatCompletionsStreamDecoder();
      final result = decoder.accept(
        _event(
          _choice(
            message: <String, dynamic>{
              'tool_calls': <Map<String, dynamic>>[
                <String, dynamic>{
                  'index': 1,
                  'id': 'call_explicit',
                  'function': <String, dynamic>{
                    'name': 'explicit',
                    'arguments': '{"slot":1}',
                  },
                },
                <String, dynamic>{
                  if (explicitNull) 'index': null,
                  'id': 'call_fallback',
                  'function': <String, dynamic>{
                    'name': 'fallback',
                    'arguments': '{}',
                  },
                },
              ],
            },
            finishReason: 'tool_calls',
          ),
        ),
      );
      final reason = explicitNull ? 'explicit null index' : 'missing index';

      expect(decoder.toolCalls, <int, Map<String, dynamic>>{
        1: <String, dynamic>{
          'id': 'call_explicit',
          'series_id': 'call_explicit',
          'name': 'explicit',
          'args': '{"slot":1}',
        },
        2: <String, dynamic>{
          'id': 'call_fallback',
          'series_id': 'call_fallback',
          'name': 'fallback',
          'args': '{}',
        },
      }, reason: reason);
      expect(
        result.chunks.whereType<ToolCallStart>().map((chunk) => chunk.id),
        <String>['call_explicit', 'call_fallback'],
        reason: reason,
      );
      expect(
        result.chunks.whereType<ToolCallEnd>().map((chunk) => chunk.id),
        <String>['call_explicit', 'call_fallback'],
        reason: reason,
      );
    }
  });

  test('complete message fallback reserves a later explicit index', () {
    for (final explicitNull in <bool>[false, true]) {
      final decoder = ChatCompletionsStreamDecoder();
      final result = decoder.accept(
        _event(
          _choice(
            message: <String, dynamic>{
              'tool_calls': <Map<String, dynamic>>[
                <String, dynamic>{
                  if (explicitNull) 'index': null,
                  'id': 'call_fallback',
                  'function': <String, dynamic>{
                    'name': 'fallback',
                    'arguments': '{}',
                  },
                },
                <String, dynamic>{
                  'index': 0,
                  'id': 'call_explicit',
                  'function': <String, dynamic>{
                    'name': 'explicit',
                    'arguments': '{"slot":0}',
                  },
                },
              ],
            },
            finishReason: 'tool_calls',
          ),
        ),
      );
      final reason = explicitNull ? 'explicit null index' : 'missing index';

      expect(decoder.toolCalls, <int, Map<String, dynamic>>{
        0: <String, dynamic>{
          'id': 'call_explicit',
          'series_id': 'call_explicit',
          'name': 'explicit',
          'args': '{"slot":0}',
        },
        1: <String, dynamic>{
          'id': 'call_fallback',
          'series_id': 'call_fallback',
          'name': 'fallback',
          'args': '{}',
        },
      }, reason: reason);
      expect(
        result.chunks.whereType<ToolCallStart>().map((chunk) => chunk.id),
        <String>['call_fallback', 'call_explicit'],
        reason: reason,
      );
      expect(
        result.chunks.whereType<ToolCallEnd>().map((chunk) => chunk.id),
        <String>['call_fallback', 'call_explicit'],
        reason: reason,
      );
    }
  });

  test('malformed frame keeps parsed chunks and later text still decodes', () {
    final decoder = ChatCompletionsStreamDecoder();
    final first = decoder.accept(
      _event(_choice(delta: <String, dynamic>{'content': 'Hello'})),
    );
    final textId = first.chunks.whereType<TextDelta>().single.id;

    final malformed = decoder.accept(
      _event(
        _choice(
          delta: <String, dynamic>{
            'tool_calls': [
              <String, dynamic>{
                'index': 0,
                'id': 'call_1',
                'function': <String, dynamic>{
                  'name': 'lookup',
                  'arguments': '{}',
                },
              },
              <String, dynamic>{
                'index': 'bad',
                'function': <String, dynamic>{'name': 'x'},
              },
            ],
          },
        ),
      ),
    );
    expect(malformed.completed, isFalse);
    expect(malformed.chunks.whereType<ToolCallStart>().single.id, 'call_1');

    final later = decoder.accept(
      _event(_choice(delta: <String, dynamic>{'content': ' world'})),
    );
    expect(later.chunks.whereType<TextDelta>().single.text, ' world');
    expect(later.chunks.whereType<TextDelta>().single.id, textId);

    final handler = StreamChunkHandler();
    for (final chunk in [
      ...first.chunks,
      ...malformed.chunks,
      ...later.chunks,
    ]) {
      handler.handle(chunk);
    }
    expect(handler.parts.whereType<TextPart>().single.text, 'Hello world');
    expect(handler.parts.whereType<ToolCallPart>(), hasLength(1));
  });

  test('malformed optional tool metadata cannot discard text', () {
    final decoder = ChatCompletionsStreamDecoder();
    final decoded = decoder.accept(
      _event(
        _choice(
          delta: <String, dynamic>{
            'content': '*气音*\n\n……我要吃了。',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 'bad',
                'id': 7,
                'function': <String, dynamic>{
                  'name': 9,
                  'arguments': <String, dynamic>{},
                },
              },
            ],
          },
        ),
      ),
    );

    expect(
      decoded.chunks.whereType<TextDelta>().single.text,
      '*气音*\n\n……我要吃了。',
    );
  });

  test('null streamed tool index uses the fallback slot', () {
    final decoder = ChatCompletionsStreamDecoder();
    final result = decoder.accept(
      _event(
        _choice(
          delta: <String, dynamic>{
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': null,
                'id': 'call_null',
                'function': <String, dynamic>{
                  'name': 'lookup',
                  'arguments': '{}',
                },
              },
            ],
          },
          finishReason: 'tool_calls',
        ),
      ),
    );

    expect(decoder.toolCalls[0], <String, dynamic>{
      'id': 'call_null',
      'series_id': 'call_null',
      'name': 'lookup',
      'args': '{}',
    });
    expect(result.chunks.whereType<ToolCallStart>().single.id, 'call_null');
    expect(result.chunks.whereType<ToolCallEnd>().single.id, 'call_null');
  });

  test('explicitly invalid tool index cannot corrupt an existing call', () {
    final decoder = ChatCompletionsStreamDecoder();
    decoder.accept(
      _event(
        _choice(
          delta: <String, dynamic>{
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 0,
                'id': 'call_1',
                'function': <String, dynamic>{
                  'name': 'lookup',
                  'arguments': '{"q":"kelivo"}',
                },
              },
            ],
          },
        ),
      ),
    );

    final malformed = decoder.accept(
      _event(
        _choice(
          delta: <String, dynamic>{
            'content': '正文仍然保留。',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 'bad',
                'id': 'call_bad',
                'function': <String, dynamic>{
                  'name': 'dangerous',
                  'arguments': '{"unexpected":true}',
                },
              },
            ],
          },
          finishReason: 'tool_calls',
        ),
      ),
    );

    expect(malformed.chunks.whereType<TextDelta>().single.text, '正文仍然保留。');
    expect(malformed.chunks.whereType<ToolCallDelta>(), isEmpty);
    expect(decoder.toolCalls.keys, <int>[0]);
    expect(decoder.toolCalls[0], <String, dynamic>{
      'id': 'call_1',
      'series_id': 'call_1',
      'name': 'lookup',
      'args': '{"q":"kelivo"}',
    });
  });

  test('fractional and negative streamed tool indexes are ignored', () {
    final decoder = ChatCompletionsStreamDecoder();
    decoder.accept(
      _event(
        _choice(
          delta: <String, dynamic>{
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 0,
                'id': 'call_1',
                'function': <String, dynamic>{
                  'name': 'lookup',
                  'arguments': '{"q":"kelivo"}',
                },
              },
            ],
          },
        ),
      ),
    );

    final malformed = decoder.accept(
      _event(
        _choice(
          delta: <String, dynamic>{
            'content': '正文仍然保留。',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'index': 0.9,
                'id': 'call_fractional',
                'function': <String, dynamic>{
                  'name': 'fractional',
                  'arguments': '{"unexpected":0.9}',
                },
              },
              <String, dynamic>{
                'index': -1,
                'id': 'call_negative',
                'function': <String, dynamic>{
                  'name': 'negative',
                  'arguments': '{"unexpected":-1}',
                },
              },
            ],
          },
          finishReason: 'tool_calls',
        ),
      ),
    );

    expect(malformed.chunks.whereType<TextDelta>().single.text, '正文仍然保留。');
    expect(malformed.chunks.whereType<ToolCallDelta>(), isEmpty);
    expect(decoder.toolCalls, <int, Map<String, dynamic>>{
      0: <String, dynamic>{
        'id': 'call_1',
        'series_id': 'call_1',
        'name': 'lookup',
        'args': '{"q":"kelivo"}',
      },
    });
  });
}
