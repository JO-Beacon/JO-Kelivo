import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/services/backup/device_local_settings_writer.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('DeviceLocalSettingsWriter.applyMissingOnly', () {
    test('只补本机缺少的键，已有键原样保留', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'window_width_v1': 800.0,
      });

      final written = await DeviceLocalSettingsWriter.applyMissingOnly({
        'window_width_v1': 1280.0,
        'window_height_v1': 720.0,
        'window_maximized_v1': true,
      });

      expect(written, 2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('window_width_v1'), 800.0);
      expect(prefs.getDouble('window_height_v1'), 720.0);
      expect(prefs.getBool('window_maximized_v1'), isTrue);
    });

    test('本机键全都在时不写任何值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'window_width_v1': 800.0,
        'window_height_v1': 600.0,
      });

      final written = await DeviceLocalSettingsWriter.applyMissingOnly({
        'window_width_v1': 1280.0,
        'window_height_v1': 720.0,
      });

      expect(written, 0);
    });
  });

  group('DeviceLocalSettingsWriter.applyOverwrite', () {
    test('本机已有的同名键也被备份值覆盖', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'window_width_v1': 800.0,
      });

      final written = await DeviceLocalSettingsWriter.applyOverwrite({
        'window_width_v1': 1280.0,
      });

      expect(written, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('window_width_v1'), 1280.0);
    });

    test('按真实类型分别写入 double / bool / StringList', () async {
      final written = await DeviceLocalSettingsWriter.applyOverwrite({
        'window_pos_x_v1': 12.5,
        'window_maximized_v1': false,
        'desktop_hotkeys_commands_v1': <Object?>['a', 'b'],
      });

      expect(written, 3);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('window_pos_x_v1'), 12.5);
      expect(prefs.getBool('window_maximized_v1'), isFalse);
      expect(
        prefs.getStringList('desktop_hotkeys_commands_v1'),
        <String>['a', 'b'],
      );
    });

    test('int 形状的窗口值统一落到 double', () async {
      final written = await DeviceLocalSettingsWriter.applyOverwrite({
        'window_width_v1': 1024,
      });

      expect(written, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('window_width_v1'), 1024.0);
    });

    test('不支持的取值类型被跳过且不抛异常', () async {
      final written = await DeviceLocalSettingsWriter.applyOverwrite({
        'window_width_v1': <String, Object?>{'nested': 1},
      });

      expect(written, 0);
    });
  });

  group('CandidateLedgerReader', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('candidate_ledger_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    void writeLedger(String fingerprint, String content) {
      final dir = Directory('${root.path}/device_local_settings');
      dir.createSync(recursive: true);
      File('${dir.path}/$fingerprint.json').writeAsStringSync(content);
    }

    test('读回候选目录里的设备记录', () {
      const fingerprint = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      writeLedger(
        fingerprint,
        '{"fingerprint":"$fingerprint","deviceName":"PC-A",'
        '"platform":"windows","savedAtUtc":"2026-09-10T00:00:00.000Z",'
        '"values":{"window_width_v1":1280.0}}',
      );

      final record = CandidateLedgerReader.readForDevice(
        candidateDirectory: root,
        fingerprint: fingerprint,
      );

      expect(record, isNotNull);
      expect(record!.deviceName, 'PC-A');
      expect(record.values['window_width_v1'], 1280.0);
    });

    test('指纹不匹配的文件返回 null', () {
      final record = CandidateLedgerReader.readForDevice(
        candidateDirectory: root,
        fingerprint: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );

      expect(record, isNull);
    });

    test('文件损坏时返回 null 而不抛异常', () {
      const fingerprint = 'cccccccccccccccccccccccccccccccc';
      writeLedger(fingerprint, '{ not json');

      final record = CandidateLedgerReader.readForDevice(
        candidateDirectory: root,
        fingerprint: fingerprint,
      );

      expect(record, isNull);
    });

    test('isLocalOnlyKey 只认本机设置键', () {
      expect(CandidateLedgerReader.isLocalOnlyKey('window_width_v1'), isTrue);
      expect(
        CandidateLedgerReader.isLocalOnlyKey('restore_something_v1'),
        isFalse,
      );
      expect(CandidateLedgerReader.isLocalOnlyKey('theme_mode'), isFalse);
    });
  });
}
