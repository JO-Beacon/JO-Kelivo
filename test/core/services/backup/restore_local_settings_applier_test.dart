import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/database/device_ledger_database.dart';
import 'package:Kelivo/core/services/backup/restore_local_settings_applier.dart';
import 'package:Kelivo/core/services/device/device_identity.dart';

const _fp = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tempDir;
  late Directory candidateDirectory;
  late DeviceLedgerDatabase database;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DeviceIdentityService.resetCache();
    DeviceIdentityService.debugCollectorOverride = () async =>
        const DeviceIdentity(
          fingerprintHash: _fp,
          displayName: 'PC-A',
          platform: 'windows',
        );
    tempDir = await Directory.systemTemp.createTemp('applier_test_');
    candidateDirectory = Directory('${tempDir.path}/candidate');
    database = DeviceLedgerDatabase(
      NativeDatabase(File('${tempDir.path}/ledger.sqlite')),
    );
  });

  tearDown(() async {
    DeviceIdentityService.debugCollectorOverride = null;
    DeviceIdentityService.resetCache();
    await database.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  void writeCandidate(Map<String, Object?> values, {String fp = _fp}) {
    final dir = Directory(
      '${candidateDirectory.path}/device_local_settings',
    );
    dir.createSync(recursive: true);
    File('${dir.path}/$fp.json').writeAsStringSync(
      jsonEncode({
        'fingerprint': fp,
        'deviceName': 'PC-A',
        'platform': 'windows',
        'savedAtUtc': '2026-09-10T00:00:00.000Z',
        'values': values,
      }),
    );
  }

  test('已 committed 但写回未执行时补做，重复启动不会二次覆盖', () async {
    writeCandidate({'window_width_v1': 1280.0});

    final first = await RestoreLocalSettingsApplier.applyIfNeeded(
      candidateDirectory: candidateDirectory,
      runId: 'run-a',
      database: database,
    );
    expect(first, 1);
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('window_width_v1'), 1280.0);
    expect(
      await database.readState(DeviceLedgerDatabase.lastAppliedRunKey),
      'run-a',
    );

    // 用户之后又改了本机值；同一 run 再次冷启动不应把它覆盖回去。
    await prefs.setDouble('window_width_v1', 999.0);
    final second = await RestoreLocalSettingsApplier.applyIfNeeded(
      candidateDirectory: candidateDirectory,
      runId: 'run-a',
      database: database,
    );
    expect(second, 0);
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('window_width_v1'), 999.0);
  });

  test('完全覆盖语义：本机已有同名键也被备份值覆盖', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'window_width_v1': 800.0,
    });
    writeCandidate({'window_width_v1': 1280.0});

    final written = await RestoreLocalSettingsApplier.applyIfNeeded(
      candidateDirectory: candidateDirectory,
      runId: 'run-b',
      database: database,
    );

    expect(written, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('window_width_v1'), 1280.0);
  });

  test('包里没有本机记录时返回 0 但仍记位，避免每次启动重复探测', () async {
    candidateDirectory.createSync(recursive: true);

    final written = await RestoreLocalSettingsApplier.applyIfNeeded(
      candidateDirectory: candidateDirectory,
      runId: 'run-c',
      database: database,
    );

    expect(written, 0);
    expect(
      await database.readState(DeviceLedgerDatabase.lastAppliedRunKey),
      'run-c',
    );
  });

  test('不同 run 各自执行一次（状态位按 run 区分）', () async {
    writeCandidate({'window_height_v1': 720.0});

    expect(
      await RestoreLocalSettingsApplier.applyIfNeeded(
        candidateDirectory: candidateDirectory,
        runId: 'run-d1',
        database: database,
      ),
      1,
    );
    expect(
      await RestoreLocalSettingsApplier.applyIfNeeded(
        candidateDirectory: candidateDirectory,
        runId: 'run-d2',
        database: database,
      ),
      1,
    );
  });

  test('候选文件损坏时静默失败且不记位（留给下次冷启动重试）', () async {
    final dir = Directory(
      '${candidateDirectory.path}/device_local_settings',
    )..createSync(recursive: true);
    File('${dir.path}/$_fp.json').writeAsStringSync('{ not json');

    final written = await RestoreLocalSettingsApplier.applyIfNeeded(
      candidateDirectory: candidateDirectory,
      runId: 'run-e',
      database: database,
    );

    // 记录解析不出来 → 视作「无本机记录」，记位并返回 0。
    expect(written, 0);
    expect(
      await database.readState(DeviceLedgerDatabase.lastAppliedRunKey),
      'run-e',
    );
  });
}
