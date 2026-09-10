import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/services/backup/device_ledger_export_settings.dart';
import 'package:Kelivo/core/services/backup/restore_local_settings_applier.dart';

void main() {
  group('DeviceLedgerExportSettings', () {
    test('首档默认「不带」', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await DeviceLedgerExportSettings.includeLedger(), isFalse);
    });

    test('选择被记住', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await DeviceLedgerExportSettings.setIncludeLedger(true);
      expect(await DeviceLedgerExportSettings.includeLedger(), isTrue);

      await DeviceLedgerExportSettings.setIncludeLedger(false);
      expect(await DeviceLedgerExportSettings.includeLedger(), isFalse);
    });
  });

  group('RestoreLocalSettingsApplier.candidateDirectoryFor', () {
    test('活动目录下的 run 位置', () {
      final appData = Directory('/tmp/appdata');

      final candidate = RestoreLocalSettingsApplier.candidateDirectoryFor(
        appDataDirectory: appData,
        runId: 'run-1',
        runInCompletedDirectory: false,
      );

      expect(
        candidate.path,
        p.join('/tmp/appdata', '.kelivo_restore', 'run_run-1', 'candidate'),
      );
    });

    test('已归档 run 落在 completed 子目录', () {
      final appData = Directory('/tmp/appdata');

      final candidate = RestoreLocalSettingsApplier.candidateDirectoryFor(
        appDataDirectory: appData,
        runId: 'run-2',
        runInCompletedDirectory: true,
      );

      expect(
        candidate.path,
        p.join(
          '/tmp/appdata',
          '.kelivo_restore',
          'completed',
          'run_run-2',
          'candidate',
        ),
      );
    });
  });
}
