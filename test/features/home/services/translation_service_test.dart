import 'package:Kelivo/core/services/api/retry_policy.dart';
import 'package:Kelivo/features/home/services/translation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('replaced translation run no longer owns side effects', () {
    final oldRun = Object();
    final newRun = Object();

    expect(translationRunIsCurrent(oldRun, newRun), isFalse);
    expect(
      shouldApplyTranslationFailure(
        runToken: oldRun,
        currentToken: newRun,
        error: Exception('HTTP 429: busy'),
      ),
      isFalse,
    );
  });

  test('cancelled translation does not clear a newer result', () {
    final run = Object();

    expect(
      shouldApplyTranslationFailure(
        runToken: run,
        currentToken: run,
        error: http.ClientException('cancelled'),
      ),
      isFalse,
    );
    expect(
      shouldApplyTranslationFailure(
        runToken: run,
        currentToken: run,
        error: Exception('HTTP 500: failed'),
      ),
      isTrue,
    );
    expect(isUserCancelError(http.ClientException('cancelled')), isTrue);
  });

  test('clearing a translation supersedes the old request', () {
    final runs = <String, Object>{};
    final oldRun = Object();
    runs['message-1'] = oldRun;

    final clearToken = supersedeTranslationRun(runs, 'message-1');

    expect(translationRequestId('message-1'), 'translate-msg-message-1');
    expect(identical(runs['message-1'], clearToken), isTrue);
    expect(translationRunIsCurrent(oldRun, runs['message-1']), isFalse);
  });
}
