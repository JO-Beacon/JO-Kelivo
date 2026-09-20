import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/backup/backup_cancel_token.dart';

void main() {
  test(
    'cancel token transitions once and throws a typed cancellation error',
    () {
      final token = BackupCancelToken();
      expect(token.isCancelled, isFalse);
      token.cancel();
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(token.throwIfCancelled, throwsA(isA<BackupCancelledException>()));
      token.dispose();
    },
  );
}
