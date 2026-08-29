import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/backup/associated_backup_path.dart';

void main() {
  test('selects a joaiclient path from Windows launch arguments', () {
    expect(
      associatedJoaiclientPathFromArguments([
        '--some-runner-flag',
        r'C:\Backups\joaiclient_backup_2026.joaiclient',
      ]),
      r'C:\Backups\joaiclient_backup_2026.joaiclient',
    );
  });

  test('accepts the extension case-insensitively and trims whitespace', () {
    expect(
      associatedJoaiclientPathFromArguments([
        '  C:\\Backups\\backup.JOAICLIENT  ',
      ]),
      r'C:\Backups\backup.JOAICLIENT',
    );
  });

  test('ignores empty, non-backup, and double-extension arguments', () {
    expect(
      associatedJoaiclientPathFromArguments([
        '',
        '--verbose',
        r'C:\Backups\backup.joaiclient.zip',
        r'C:\Backups\backup.zip',
      ]),
      isNull,
    );
  });
}
