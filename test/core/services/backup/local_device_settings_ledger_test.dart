import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/device_ledger_database.dart';
import 'package:Kelivo/core/services/backup/local_device_settings_ledger.dart';
import 'package:Kelivo/core/services/device/device_identity.dart';

DeviceIdentity _identity(String fingerprint, {String name = 'PC'}) {
  return DeviceIdentity(
    fingerprintHash: fingerprint,
    displayName: name,
    platform: 'windows',
  );
}

const _fpA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _fpB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _fpC = 'cccccccccccccccccccccccccccccccc';

void main() {
  // 本文件会同时打开两个库实例（含"缺失时自建"用例），属于测试内的预期行为。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tempDir;
  late DeviceLedgerDatabase database;
  late LocalDeviceSettingsLedger ledger;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ledger_test_');
    database = DeviceLedgerDatabase(
      NativeDatabase(File('${tempDir.path}/ledger.sqlite')),
    );
    ledger = LocalDeviceSettingsLedger(database: database);
  });

  tearDown(() async {
    await database.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('写入与去重', () {
    test('upsertCurrent 写入后可读回，且用到的是 localOnlyKeys 成员', () async {
      await ledger.upsertCurrent(_identity(_fpA, name: 'My PC'), {
        'window_width_v1': 1280.5,
        'window_height_v1': 720.0,
        'window_maximized_v1': true,
        'display_chat_font_scale_v1': 1.25,
        'desktop_hotkeys_commands_v1': ['ctrl+k'],
        // 非 localOnly 键必须被丢弃
        'providers_order_v1': ['x'],
        'restore_internal_v1': 'leak',
      });

      final record = await ledger.findByFingerprint(_fpA);
      expect(record, isNotNull);
      expect(record!.deviceName, 'My PC');
      expect(record.platform, 'windows');
      expect(record.values.keys, isNot(contains('providers_order_v1')));
      expect(record.values.keys, isNot(contains('restore_internal_v1')));
      expect(record.values['window_width_v1'], 1280.5);
      expect(record.values['window_maximized_v1'], true);
      expect(record.values['desktop_hotkeys_commands_v1'], ['ctrl+k']);
    });

    test('同指纹重复写入只保留一条，较新的覆盖较旧的', () async {
      await ledger.upsertCurrent(_identity(_fpA, name: 'Old'), {
        'window_width_v1': 100.0,
      }, savedAtUtc: DateTime.utc(2026, 1, 1));
      await ledger.upsertCurrent(_identity(_fpA, name: 'New'), {
        'window_width_v1': 200.0,
      }, savedAtUtc: DateTime.utc(2026, 6, 1));

      final all = await ledger.getAll();
      expect(all, hasLength(1));
      expect(all.single.deviceName, 'New');
      expect(all.single.values['window_width_v1'], 200.0);
    });

    test('较旧的记录不会倒退覆盖较新的本机记录', () async {
      await ledger.upsertCurrent(_identity(_fpA, name: 'Local'), {
        'window_width_v1': 200.0,
      }, savedAtUtc: DateTime.utc(2026, 6, 1));
      await ledger.upsertCurrent(_identity(_fpA, name: 'StaleArchive'), {
        'window_width_v1': 100.0,
      }, savedAtUtc: DateTime.utc(2026, 1, 1));

      final record = await ledger.findByFingerprint(_fpA);
      expect(record!.deviceName, 'Local');
      expect(record.values['window_width_v1'], 200.0);
    });
  });

  group('并入追加', () {
    test('不同指纹追加为多条', () async {
      await ledger.mergeFromArchive([
        DeviceSettingsRecord(
          fingerprint: _fpA,
          deviceName: 'A',
          platform: 'windows',
          savedAtUtc: DateTime.utc(2026, 1, 1),
          values: const {'window_width_v1': 1.0},
        ),
        DeviceSettingsRecord(
          fingerprint: _fpB,
          deviceName: 'B',
          platform: 'macos',
          savedAtUtc: DateTime.utc(2026, 2, 1),
          values: const {'window_width_v1': 2.0},
        ),
      ]);

      expect(await ledger.countAll(), 2);
      expect((await ledger.findByFingerprint(_fpA))!.deviceName, 'A');
      expect((await ledger.findByFingerprint(_fpB))!.platform, 'macos');
    });

    test('并入不触碰其他设备（累积语义）', () async {
      await ledger.upsertCurrent(_identity(_fpC, name: 'C'), {
        'window_width_v1': 3.0,
      });
      await ledger.mergeFromArchive([
        DeviceSettingsRecord(
          fingerprint: _fpA,
          deviceName: 'A',
          platform: 'windows',
          savedAtUtc: DateTime.utc(2026, 1, 1),
          values: const {'window_width_v1': 1.0},
        ),
      ]);

      expect(await ledger.countAll(), 2);
      expect(await ledger.findByFingerprint(_fpC), isNotNull);
      expect(await ledger.findByFingerprint(_fpA), isNotNull);
    });
  });

  group('分页与删除', () {
    test('getAll 支持 limit/offset，按时间倒序', () async {
      for (var i = 0; i < 5; i++) {
        await ledger.upsertCurrent(
          _identity('${_fpA.substring(0, 31)}$i', name: 'dev$i'),
          {'window_width_v1': i.toDouble()},
          savedAtUtc: DateTime.utc(2026, 1, 1 + i),
        );
      }
      final page1 = await ledger.getAll(limit: 2, offset: 0);
      final page2 = await ledger.getAll(limit: 2, offset: 2);
      expect(page1, hasLength(2));
      expect(page2, hasLength(2));
      expect(page1.first.deviceName, 'dev4');
      expect(page2.first.deviceName, 'dev2');
    });

    test('removeDevice 只删指定设备', () async {
      await ledger.upsertCurrent(_identity(_fpA), {'window_width_v1': 1.0});
      await ledger.upsertCurrent(_identity(_fpB), {'window_width_v1': 2.0});
      await ledger.removeDevice(_fpA);
      expect(await ledger.findByFingerprint(_fpA), isNull);
      expect(await ledger.findByFingerprint(_fpB), isNotNull);
    });

    test('clearAll 清空全部', () async {
      await ledger.upsertCurrent(_identity(_fpA), {'window_width_v1': 1.0});
      await ledger.upsertCurrent(_identity(_fpB), {'window_width_v1': 2.0});
      await ledger.clearAll();
      expect(await ledger.countAll(), 0);
    });
  });

  group('导出', () {
    test('exportPerDevice 按设备拆成独立条目，文件名等于指纹散列', () async {
      await ledger.upsertCurrent(_identity(_fpA), {'window_width_v1': 1.0});
      await ledger.upsertCurrent(_identity(_fpB), {'window_width_v1': 2.0});
      final exported = await ledger.exportPerDevice();

      expect(exported.keys, hasLength(2));
      expect(exported.keys, contains('device_local_settings/$_fpA.json'));
      expect(exported.keys, contains('device_local_settings/$_fpB.json'));
      expect(exported['device_local_settings/$_fpA.json'], contains(_fpA));
    });
  });

  group('容错', () {
    test('values_json 损坏时该条被跳过而非抛异常', () async {
      await database.upsert(
        DeviceLocalSettingsLedgerRowsCompanion.insert(
          fingerprint: _fpA,
          deviceName: 'Broken',
          platform: 'windows',
          savedAtUtc: DateTime.utc(2026, 1, 1),
          valuesJson: '{ not json',
        ),
      );
      await ledger.upsertCurrent(_identity(_fpB), {'window_width_v1': 2.0});

      final all = await ledger.getAll();
      expect(all, hasLength(1));
      expect(all.single.fingerprint, _fpB);
      expect(await ledger.hasFingerprint(_fpA), isTrue);
    });

    test('库文件缺失时自动新建（默认打开路径）', () async {
      // 直接用默认构造在临时目录不可行（走 path_provider），
      // 这里验证 NativeDatabase 在文件不存在时能自建表。
      final path = '${tempDir.path}/fresh.sqlite';
      final fresh = DeviceLedgerDatabase(NativeDatabase(File(path)));
      final freshLedger = LocalDeviceSettingsLedger(database: fresh);
      await freshLedger.upsertCurrent(_identity(_fpA), {
        'window_width_v1': 1.0,
      });
      expect(await freshLedger.countAll(), 1);
      expect(await File(path).exists(), isTrue);
      await fresh.close();
    });
  });

  group('包内文件解析', () {
    test('合法文件可解析，文件名即指纹', () {
      final record = LocalDeviceSettingsLedger.parseArchiveFile(
        'device_local_settings/$_fpA.json',
        '{"fingerprint":"$_fpA","deviceName":"A","platform":"windows",'
            '"savedAtUtc":"2026-01-01T00:00:00.000Z",'
            '"values":{"window_width_v1":800.0,"window_maximized_v1":false}}',
      );
      expect(record, isNotNull);
      expect(record!.fingerprint, _fpA);
      expect(record.deviceName, 'A');
      expect(record.values['window_width_v1'], 800.0);
      expect(record.values['window_maximized_v1'], false);
    });

    test('非 JSON / 形状错误 / 非法文件名一律返回 null', () {
      expect(
        LocalDeviceSettingsLedger.parseArchiveFile(
          'device_local_settings/$_fpA.json',
          'not json',
        ),
        isNull,
      );
      expect(
        LocalDeviceSettingsLedger.parseArchiveFile(
          'device_local_settings/$_fpA.json',
          '{"values":"not a map"}',
        ),
        isNull,
      );
      expect(
        LocalDeviceSettingsLedger.parseArchiveFile(
          'device_local_settings/short.json',
          '{"values":{}}',
        ),
        isNull,
      );
    });

    test('文件里的非 localOnly 键在解析时被剔除', () {
      final record = LocalDeviceSettingsLedger.parseArchiveFile(
        'device_local_settings/$_fpA.json',
        '{"values":{"window_width_v1":1.0,"restore_x":"leak",'
            '"providers_order_v1":["a"]}}',
      );
      expect(record!.values.keys, ['window_width_v1']);
    });
  });

  group('filterValues', () {
    test('保留合法类型，丢弃不合法类型', () {
      final filtered = LocalDeviceSettingsLedger.filterValues({
        'window_width_v1': 100.0,
        'window_maximized_v1': true,
        'desktop_hotkeys_commands_v1': ['a', 'b'],
        'flutter_log_enabled_v1': false,
        // 类型不合法：应为 double 却给了 Map
        'display_chat_font_scale_v1': {'bad': true},
        'unknown_key_v1': 1,
      });
      expect(filtered.keys, isNot(contains('display_chat_font_scale_v1')));
      expect(filtered.keys, isNot(contains('unknown_key_v1')));
      expect(filtered['window_width_v1'], 100.0);
      expect(filtered['flutter_log_enabled_v1'], false);
    });
  });
}
