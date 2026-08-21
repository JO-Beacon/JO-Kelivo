import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/migration/migration_backup_file_name.dart';

void main() {
  test('uses the legacy migration backup filename contract', () {
    expect(
      migrationBackupFileName(
        timestamp: DateTime.utc(2026, 8, 14, 4, 14, 42, 262, 471),
      ),
      'kelivo_migration_backup_2026-08-14T04-14-42-262471Z.zip',
    );
  });
}
