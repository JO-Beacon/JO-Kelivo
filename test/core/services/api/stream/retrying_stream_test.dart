import 'dart:async';

import 'package:Kelivo/core/models/auto_retry_options.dart';
import 'package:Kelivo/core/services/api/stream/retrying_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _fastRetry = AutoRetryOptions(
  enabled: true,
  maxRetries: 2,
  initialDelay: Duration.zero,
  maxDelay: Duration.zero,
  jitter: false,
);

void main() {
  test('retries an empty failed attempt and then succeeds', () async {
    var attempts = 0;
    final values = await retryingStream<int>(
      options: _fastRetry,
      isCancelled: () => false,
      shouldRetry: (_) => true,
      attempt: (index) async* {
        attempts++;
        if (index == 0) throw Exception('HTTP 429: busy');
        yield 7;
      },
    ).toList();
    expect(values, [7]);
    expect(attempts, 2);
  });

  test('throws the final error unchanged after reaching the limit', () async {
    final errors = <Object>[];
    var attempts = 0;
    try {
      await retryingStream<int>(
        options: _fastRetry,
        isCancelled: () => false,
        shouldRetry: (_) => true,
        attempt: (index) async* {
          attempts++;
          final error = Exception('failure $index');
          errors.add(error);
          throw error;
        },
      ).toList();
      fail('expected an error');
    } catch (error) {
      expect(attempts, 3);
      expect(identical(error, errors.last), isTrue);
    }
  });

  test('never retries after an attempt has yielded an event', () async {
    var attempts = 0;
    final stream = retryingStream<int>(
      options: _fastRetry,
      isCancelled: () => false,
      shouldRetry: (_) => true,
      attempt: (_) async* {
        attempts++;
        yield 1;
        throw Exception('HTTP 429: busy');
      },
    );
    await expectLater(stream, emitsInOrder([1, emitsError(isA<Exception>())]));
    expect(attempts, 1);
  });

  test('disabled mode performs only the first attempt', () async {
    var attempts = 0;
    final stream = retryingStream<int>(
      options: _fastRetry.copyWith(enabled: false),
      isCancelled: () => false,
      shouldRetry: (_) => true,
      attempt: (_) async* {
        attempts++;
        throw Exception('HTTP 429: busy');
      },
    );
    await expectLater(stream, emitsError(isA<Exception>()));
    expect(attempts, 1);
  });

  test(
    'cancellation interrupts backoff and prevents another attempt',
    () async {
      var attempts = 0;
      var cancelled = false;
      final gate = Completer<void>();
      const slowRetry = AutoRetryOptions(
        enabled: true,
        maxRetries: 2,
        initialDelay: Duration(seconds: 8),
        maxDelay: Duration(seconds: 8),
        jitter: false,
      );
      final stopwatch = Stopwatch()..start();
      final done = retryingStream<int>(
        options: slowRetry,
        isCancelled: () => cancelled,
        cancelled: gate.future,
        shouldRetry: (_) => true,
        attempt: (_) async* {
          attempts++;
          throw Exception('HTTP 429: busy');
        },
      ).toList();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      cancelled = true;
      gate.complete();
      await expectLater(done, throwsA(isA<http.ClientException>()));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(attempts, 1);
    },
  );
}
