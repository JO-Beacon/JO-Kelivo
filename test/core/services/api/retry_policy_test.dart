import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:Kelivo/core/models/auto_retry_options.dart';
import 'package:Kelivo/core/services/api/retry_policy.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('shouldRetryError', () {
    test('retries transient status, throttling, and network errors', () {
      expect(shouldRetryError(const HttpException('HTTP 429: busy')), isTrue);
      expect(
        shouldRetryError(const HttpException('HTTP 502: bad gateway')),
        isTrue,
      );
      expect(shouldRetryError(Exception('Rate Limit exceeded')), isTrue);
      expect(shouldRetryError(const SocketException('reset')), isTrue);
      expect(shouldRetryError(TimeoutException('timed out')), isTrue);
    });

    test('does not retry authentication, quota, or cancellation errors', () {
      expect(
        shouldRetryError(const HttpException('HTTP 401: unauthorized')),
        isFalse,
      );
      expect(shouldRetryError(Exception('余额不足，请充值')), isFalse);
      expect(
        shouldRetryError(Exception('HTTP 429: insufficient quota')),
        isFalse,
      );
      expect(shouldRetryError(http.ClientException('cancelled')), isFalse);
      expect(
        shouldRetryError(
          DioException(
            requestOptions: RequestOptions(path: '/'),
            type: DioExceptionType.cancel,
          ),
        ),
        isFalse,
      );
    });
  });

  test('backoff grows exponentially, jitters, and stays capped', () {
    const steady = AutoRetryOptions(
      enabled: true,
      maxRetries: 5,
      initialDelay: Duration(seconds: 1),
      multiplier: 2,
      maxDelay: Duration(seconds: 8),
      jitter: false,
    );
    expect(backoffDelay(0, steady), const Duration(seconds: 1));
    expect(backoffDelay(1, steady), const Duration(seconds: 2));
    expect(backoffDelay(2, steady), const Duration(seconds: 4));
    expect(backoffDelay(3, steady), const Duration(seconds: 8));
    expect(backoffDelay(4, steady), const Duration(seconds: 8));

    final jittered = AutoRetryOptions(
      enabled: true,
      maxRetries: steady.maxRetries,
      initialDelay: steady.initialDelay,
      multiplier: steady.multiplier,
      maxDelay: steady.maxDelay,
    );
    for (var seed = 0; seed < 20; seed++) {
      expect(
        backoffDelay(0, jittered, random: Random(seed)).inMilliseconds,
        inInclusiveRange(800, 1200),
      );
    }
  });
}
