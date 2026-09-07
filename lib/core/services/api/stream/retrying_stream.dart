import 'dart:async';

import 'package:http/http.dart' as http;

import '../../../models/auto_retry_options.dart';
import '../retry_policy.dart';

/// 只在当前尝试尚未产生任何事件时重放请求。
Stream<T> retryingStream<T>({
  required Stream<T> Function(int attempt) attempt,
  required AutoRetryOptions options,
  required bool Function() isCancelled,
  required bool Function(Object error) shouldRetry,
  Future<void> Function(int attempt, Duration delay, Object error)? onRetry,
  Future<void>? cancelled,
}) async* {
  final maxRetries = options.enabled ? options.maxRetries : 0;
  Object? lastError;

  for (var index = 0; index <= maxRetries; index++) {
    if (isCancelled()) throw http.ClientException('cancelled');
    var yielded = false;
    try {
      await for (final item in attempt(index)) {
        yielded = true;
        yield item;
      }
      return;
    } catch (error) {
      lastError = error;
      if (isCancelled()) throw http.ClientException('cancelled');
      if (yielded || index >= maxRetries || !shouldRetry(error)) rethrow;

      final delay = backoffDelay(index, options);
      await onRetry?.call(index, delay, error);
      await interruptibleDelay(
        delay,
        isCancelled: isCancelled,
        cancelled: cancelled,
      );
      if (isCancelled()) throw http.ClientException('cancelled');
    }
  }

  throw lastError!;
}

Future<void> interruptibleDelay(
  Duration delay, {
  required bool Function() isCancelled,
  Future<void>? cancelled,
}) async {
  if (delay <= Duration.zero || isCancelled()) return;
  if (cancelled != null) {
    await Future.any<void>([Future<void>.delayed(delay), cancelled]);
    return;
  }

  const slice = Duration(milliseconds: 20);
  var remaining = delay;
  while (remaining > Duration.zero) {
    if (isCancelled()) return;
    final step = remaining < slice ? remaining : slice;
    await Future<void>.delayed(step);
    remaining -= step;
  }
}
