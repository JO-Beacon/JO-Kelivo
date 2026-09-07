import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/services/backup/backup_activity.dart';

void main() {
  test('活动计数支持嵌套并在结束后归零', () {
    expect(BackupActivity.isActive, isFalse);
    BackupActivity.begin();
    BackupActivity.begin();
    expect(BackupActivity.isActive, isTrue);
    BackupActivity.end();
    expect(BackupActivity.isActive, isTrue);
    BackupActivity.end();
    BackupActivity.end();
    expect(BackupActivity.isActive, isFalse);
  });
}
