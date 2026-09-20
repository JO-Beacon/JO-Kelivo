import 'dart:async';
import 'dart:convert';

import 'package:Kelivo/core/services/api/providers/openai/chat_completions_decoder.dart';
import 'package:Kelivo/core/services/api/stream/sse_decode_loop.dart';
import 'package:Kelivo/core/services/api/stream/sse_framing.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'pending recovered text reaches the handler before a transport error',
    () async {
      final input = StreamController<String>();
      final decoder = ChatCompletionsStreamDecoder();
      final handler = StreamChunkHandler();
      final timeline = <String>[];
      final errorSeen = Completer<void>();
      final transportError = StateError('transport failed');
      final transportStack = StackTrace.current;
      Object? receivedError;
      StackTrace? receivedStack;
      String? textAtError;
      final subscription =
          decodeSseEvents(
            parseSseEventStrings(
              input.stream,
              recoverAdjacentJsonDataRecords: true,
            ),
            decoder,
          ).listen(
            (chunk) {
              handler.handle(chunk);
              timeline.add('data');
            },
            onError: (Object error, StackTrace stackTrace) {
              receivedError = error;
              receivedStack = stackTrace;
              textAtError = handler.toResult().text;
              timeline.add('error');
              errorSeen.complete();
            },
          );
      addTearDown(() async {
        await input.close();
        await subscription.cancel();
      });

      input.add(
        'data: ${jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'delta': <String, dynamic>{'content': '正文仍然保留。'},
              'finish_reason': null,
            },
          ],
        })}\n',
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.toResult().text, isEmpty);

      input.addError(transportError, transportStack);
      await errorSeen.future.timeout(const Duration(seconds: 1));

      expect(textAtError, '正文仍然保留。');
      expect(handler.toResult().text, '正文仍然保留。');
      expect(timeline, <String>['data', 'error']);
      expect(receivedError, same(transportError));
      expect(receivedStack.toString(), transportStack.toString());
    },
  );
}
