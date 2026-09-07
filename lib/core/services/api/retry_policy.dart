import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

import '../../models/auto_retry_options.dart';

/// 由 [SettingsProvider] 同步的进程级聊天请求重试配置。
class AutoRetryConfig {
  static AutoRetryOptions current = const AutoRetryOptions.defaults();
}

const Set<int> retryableHttpStatusCodes = {
  408,
  425,
  429,
  500,
  502,
  503,
  504,
  529,
};

const List<String> _retryKeywords = [
  '并发',
  '稍后',
  '重试',
  '访问量过大',
  '繁忙',
  '限流',
  'rate limit',
  'too many requests',
  'overloaded',
  'try again',
  'timeout',
  '超时',
];

const List<String> _stopKeywords = [
  '余额',
  '不足',
  '额度',
  '欠费',
  'balance',
  'insufficient',
  'quota',
  'invalid api key',
  'unauthorized',
  'permission',
  '未实名',
];

final RegExp _httpStatusPattern = RegExp(
  r'HTTP\s+(\d{3})',
  caseSensitive: false,
);

int? httpStatusFromError(Object error) {
  final match = _httpStatusPattern.firstMatch(error.toString());
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool shouldRetryError(Object error) {
  if (isUserCancelError(error)) return false;
  final text = error.toString();
  if (_containsKeyword(text, _stopKeywords)) return false;

  final status = httpStatusFromError(error);
  if (_isRetryableNetworkError(error, status)) return true;
  if (status != null && retryableHttpStatusCodes.contains(status)) return true;
  return _containsKeyword(text, _retryKeywords);
}

Duration backoffDelay(
  int retryIndex,
  AutoRetryOptions options, {
  Random? random,
}) {
  final exponent = retryIndex <= 0 ? 0 : retryIndex;
  var milliseconds =
      options.initialDelay.inMilliseconds * pow(options.multiplier, exponent);
  final maximum = options.maxDelay.inMilliseconds.toDouble();
  if (!milliseconds.isFinite || milliseconds > maximum) {
    milliseconds = maximum;
  }
  if (milliseconds < 0) milliseconds = 0;
  if (options.jitter) {
    final rng = random ?? Random();
    milliseconds *= 0.8 + rng.nextDouble() * 0.4;
  }
  if (!milliseconds.isFinite || milliseconds > maximum) {
    milliseconds = maximum;
  }
  return Duration(milliseconds: milliseconds.round());
}

bool isUserCancelError(Object error) {
  if (error is DioException && error.type == DioExceptionType.cancel) {
    return true;
  }
  if (error is http.ClientException &&
      error.message.trim().toLowerCase() == 'cancelled') {
    return true;
  }
  final text = error.toString().toLowerCase();
  return text.contains('dioexceptiontype.cancel') ||
      text.contains('dioexception [cancel]');
}

bool _isRetryableNetworkError(Object error, int? status) {
  if (error is SocketException || error is TimeoutException) return true;
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.unknown:
        final inner = error.error;
        if (inner != null) {
          return _isRetryableNetworkError(inner, httpStatusFromError(inner));
        }
        return _isConnectionAbortMessage(error.message ?? error.toString());
      case DioExceptionType.badResponse:
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
        return false;
    }
  }
  if (error is HttpException && _isConnectionAbortMessage(error.message)) {
    return true;
  }
  return error is http.ClientException && status == null;
}

bool _isConnectionAbortMessage(String message) {
  final text = message.toLowerCase();
  return text.contains('connection closed') ||
      text.contains('while receiving data') ||
      text.contains('connection reset') ||
      text.contains('broken pipe');
}

bool _containsKeyword(String text, List<String> keywords) {
  if (text.isEmpty) return false;
  final haystack = text.toLowerCase();
  return keywords.any((raw) {
    final keyword = raw.trim().toLowerCase();
    return keyword.isNotEmpty && haystack.contains(keyword);
  });
}
