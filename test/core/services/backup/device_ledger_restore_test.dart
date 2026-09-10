import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/business_restore_service.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/backup.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/services/backup/data_sync.dart';
import 'package:Kelivo/core/services/backup/local_device_settings_ledger.dart';
import 'package:Kelivo/core/services/backup/restore_receipt.dart';
import 'package:Kelivo/core/services/backup/restore_startup_gate.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/device/device_identity.dart';

/// 把 path_provider 指向临时目录，业务库与册子库都落在沙箱里。
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

const _localFingerprint = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherFingerprint = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _thirdFingerprint = 'cccccccccccccccccccccccccccccccc';

/// 本功能的 9 键里挑两个真实键做断言载体（一个是 double，一个是 bool）。
const _widthKey = 'window_width_v1';
const _maximizedKey = 'window_maximized_v1';

Future<String> _sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Map<String, Object?> _ledgerPayload({
  required String fingerprint,
  required String deviceName,
  required Map<String, Object?> values,
  String savedAtUtc = '2026-08-01T00:00:00.000Z',
}) {
  return {
    'fingerprint': fingerprint,
    'deviceName': deviceName,
    'platform': 'windows',
    'savedAtUtc': savedAtUtc,
    'values': values,
  };
}

/// 构造一个带册子条目的完整 SQLite 备份包。
///
/// 刻意保持 `includeFiles: false`：册子必须独立于附件开关，这正是要固化的红线。
/// [malformedLedgerFingerprints] 里的条目会写入非法 JSON，用来验证单文件损坏容错。
Future<File> _createLedgerBackupFixture({
  required Directory root,
  required String prefix,
  required Map<String, String> ledgerFiles,
  Set<String> malformedLedgerFingerprints = const {},
  Map<String, dynamic> settings = const {},
}) async {
  final databasePath = '${root.path}/${prefix}_database.sqlite';
  final snapshotInfo = await Isolate.run(() async {
    final databaseFile = File(databasePath);
    final repository = ChatDatabaseRepository.open(file: databaseFile);
    try {
      await repository.ensureReady();
      await repository.putMigrationBatch(
        conversations: [
          Conversation(
            id: 'fixture-conversation',
            title: 'Fixture',
            messageIds: const ['fixture-message'],
          ),
        ],
        messages: [
          (
            message: ChatMessage(
              id: 'fixture-message',
              role: 'assistant',
              content: 'fixture content',
              conversationId: 'fixture-conversation',
            ),
            messageOrder: 0,
          ),
        ],
        toolEventsByMessageId: const {},
        geminiSignaturesByMessageId: const {},
      );
      await repository.checkpoint();
    } finally {
      await repository.close();
    }
    return ChatDatabaseRepository.prepareSnapshotForRestore(databaseFile);
  });

  final settingsFile = File('${root.path}/${prefix}_settings.json');
  await settingsFile.writeAsString(jsonEncode(settings));

  final entries = <String, Map<String, Object>>{
    'settings.json': {
      'bytes': await settingsFile.length(),
      'sha256': await _sha256File(settingsFile),
    },
    'database/kelivo.db': {
      'bytes': await File(databasePath).length(),
      'sha256': await _sha256File(File(databasePath)),
    },
  };

  final ledgerFilesOnDisk = <String, File>{};
  for (final entry in ledgerFiles.entries) {
    final file = File('${root.path}/${prefix}_ledger_${entry.key}');
    await file.writeAsString(
      malformedLedgerFingerprints.contains(entry.key)
          ? '{ this is not json'
          : entry.value,
      flush: true,
    );
    ledgerFilesOnDisk['device_local_settings/${entry.key}.json'] = file;
    entries['device_local_settings/${entry.key}.json'] = {
      'bytes': await file.length(),
      'sha256': await _sha256File(file),
    };
  }

  final manifestFile = File('${root.path}/${prefix}_manifest.json');
  await manifestFile.writeAsString(
    jsonEncode({
      'format': 'kelivo-backup',
      'formatVersion': 2,
      'payloadKind': 'sqlite',
      'createdAtUtc': '2026-08-01T00:00:00.000Z',
      'appVersion': '1.0.0-test+1',
      'includeChats': true,
      // 册子不依赖附件；这里恒为 false，正是要证明解耦。
      'includeFiles': false,
      'secretsIncluded': true,
      'database': {
        'entry': 'database/kelivo.db',
        'schemaVersion': snapshotInfo.schemaVersion,
        'conversationCount': snapshotInfo.conversationCount,
        'messageCount': snapshotInfo.messageCount,
      },
      'entries': entries,
    }),
  );

  final zipFile = File('${root.path}/$prefix.zip');
  final encoder = ZipFileEncoder();
  encoder.create(zipFile.path);
  encoder.addFileSync(manifestFile, 'manifest.json');
  encoder.addFileSync(settingsFile, 'settings.json');
  encoder.addFileSync(File(databasePath), 'database/kelivo.db');
  for (final entry in ledgerFilesOnDisk.entries) {
    encoder.addFileSync(entry.value, entry.key);
  }
  encoder.closeSync();
  return zipFile;
}

/// 读取正本册子里的全部设备记录。
Future<List<DeviceSettingsRecord>> _readLedger() async {
  final ledger = LocalDeviceSettingsLedger();
  try {
    return await ledger.getAll();
  } finally {
    await ledger.close();
  }
}

Future<DeviceSettingsRecord?> _readLedgerFor(String fingerprint) async {
  final ledger = LocalDeviceSettingsLedger();
  try {
    return await ledger.findByFingerprint(fingerprint);
  } finally {
    await ledger.close();
  }
}

void main() {
  group('本机设置随备份流转：恢复流程', () {
    late Directory root;
    late AppDatabase businessDatabase;
    late BusinessRepository businessRepository;

    /// 当前测试里活的 ChatService。它持有 `appDataDir/kelivo.db` 的独占连接，
    /// 冷重启模拟前必须先释放，否则 cutover 的 journal_mode 切换会被锁。
    ChatService? liveChatService;
    var liveChatServiceClosed = false;

    /// 模拟冷重启：生产里这是新进程，旧连接必然已经不存在。
    Future<void> simulateColdRestart() async {
      if (liveChatServiceClosed) return;
      liveChatServiceClosed = true;
      await liveChatService?.close();
    }

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      root = await Directory.systemTemp.createTemp('ledger_restore_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
      PackageInfo.setMockInitialValues(
        appName: 'JO-AIClient',
        packageName: 'JO-AIClient',
        version: '1.0.0-test',
        buildNumber: '1',
        buildSignature: 'test',
      );
      SharedPreferences.setMockInitialValues({});
      liveChatService = null;
      liveChatServiceClosed = false;
      DeviceIdentityService.resetCache();
      DeviceIdentityService.debugCollectorOverride = () async =>
          const DeviceIdentity(
            fingerprintHash: _localFingerprint,
            displayName: 'This PC',
            platform: 'windows',
          );

      businessDatabase = AppDatabase.open(
        file: File('${root.path}/business_test.sqlite'),
      );
      businessRepository = BusinessRepository(businessDatabase);
      await BusinessRestoreService(
        businessRepository,
      ).overwrite({'backup_test_key': 'value'});
    });

    tearDown(() async {
      DeviceIdentityService.debugCollectorOverride = null;
      DeviceIdentityService.resetCache();
      await simulateColdRestart();
      await businessDatabase.close();
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });

    Future<DataSync> restoreWith(
      File archive, {
      required RestoreMode mode,
    }) async {
      final chatService = ChatService();
      liveChatService = chatService;
      await chatService.init();
      final sync = DataSync(
        businessRepository: businessRepository,
        chatService: chatService,
      );
      await sync.restoreFromLocalFile(
        archive,
        const WebDavConfig(includeChats: true, includeFiles: false),
        mode: mode,
      );
      return sync;
    }

    test('合并保留：本机缺失的键按逐键补缺写回，记录同时并入册子', () async {
      final archive = await _createLedgerBackupFixture(
        root: root,
        prefix: 'merge_missing_key',
        ledgerFiles: {
          _localFingerprint: jsonEncode(
            _ledgerPayload(
              fingerprint: _localFingerprint,
              deviceName: 'This PC',
              values: {_widthKey: 1234.0, _maximizedKey: true},
            ),
          ),
        },
      );

      await restoreWith(archive, mode: RestoreMode.merge);

      // 本机原本没有这些键 → 补上备份值。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_widthKey), 1234.0);
      expect(prefs.getBool(_maximizedKey), true);

      // 记录无条件并入正本册子。
      final record = await _readLedgerFor(_localFingerprint);
      expect(record, isNotNull);
      expect(record!.values[_widthKey], 1234.0);
    });

    test('合并保留：本机已有该键时一字不动，记录仍然并入', () async {
      SharedPreferences.setMockInitialValues({_widthKey: 500.0});

      final archive = await _createLedgerBackupFixture(
        root: root,
        prefix: 'merge_existing_key',
        ledgerFiles: {
          _localFingerprint: jsonEncode(
            _ledgerPayload(
              fingerprint: _localFingerprint,
              deviceName: 'This PC',
              values: {_widthKey: 1234.0},
            ),
          ),
        },
      );

      await restoreWith(archive, mode: RestoreMode.merge);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getDouble(_widthKey),
        500.0,
        reason: '逐键补缺不得倒退本机已有的值',
      );
      expect(await _readLedgerFor(_localFingerprint), isNotNull);
    });

    test('非匹配设备的记录静默并入，且不写回本机设置', () async {
      final archive = await _createLedgerBackupFixture(
        root: root,
        prefix: 'merge_other_device',
        ledgerFiles: {
          _otherFingerprint: jsonEncode(
            _ledgerPayload(
              fingerprint: _otherFingerprint,
              deviceName: 'Other PC',
              values: {_widthKey: 777.0},
            ),
          ),
        },
      );

      await restoreWith(archive, mode: RestoreMode.merge);

      expect(
        (await _readLedgerFor(_otherFingerprint))?.values[_widthKey],
        777.0,
        reason: '别的设备的记录也要累积进册子',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_widthKey), isNull, reason: '认领不到就不能写本机');
    });

    test('旧包（无册子条目）恢复不报错，册子保持原样', () async {
      final archive = await _createLedgerBackupFixture(
        root: root,
        prefix: 'legacy_no_ledger',
        ledgerFiles: const {},
      );

      await restoreWith(archive, mode: RestoreMode.merge);

      expect(await _readLedger(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_widthKey), isNull);
    });

    test('单台设备文件损坏只跳过该台，其余照常并入', () async {
      final archive = await _createLedgerBackupFixture(
        root: root,
        prefix: 'one_broken_file',
        ledgerFiles: {
          _otherFingerprint: jsonEncode(
            _ledgerPayload(
              fingerprint: _otherFingerprint,
              deviceName: 'Good PC',
              values: {_widthKey: 111.0},
            ),
          ),
          _thirdFingerprint: jsonEncode(
            _ledgerPayload(
              fingerprint: _thirdFingerprint,
              deviceName: 'Broken PC',
              values: {_widthKey: 222.0},
            ),
          ),
        },
        malformedLedgerFingerprints: {_thirdFingerprint},
      );

      await restoreWith(archive, mode: RestoreMode.merge);

      final records = await _readLedger();
      expect(records.map((item) => item.fingerprint), [_otherFingerprint]);
      expect(records.single.values[_widthKey], 111.0);
    });

    test('完全覆盖：恢复流程内不写回，冷重启提交成功后才写回', () async {
      final archive = await _createLedgerBackupFixture(
        root: root,
        prefix: 'overwrite_deferred',
        ledgerFiles: {
          _localFingerprint: jsonEncode(
            _ledgerPayload(
              fingerprint: _localFingerprint,
              deviceName: 'This PC',
              values: {_widthKey: 1234.0},
            ),
          ),
        },
      );

      final sync = await restoreWith(archive, mode: RestoreMode.overwrite);
      expect(sync.lastLedgerRecords, hasLength(1));
      expect(sync.lastLocalSettingsApplied, 0);

      // 流程内先不写：切库失败会回滚，设置一旦先改就会出现
      // “设置变了、数据退回去”的不一致。
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_widthKey), isNull);

      // 记录无条件并入册子，与模式无关。
      expect(await _readLedgerFor(_localFingerprint), isNotNull);

      // 冷重启后 cutover 提交成功，写回才发生。
      await simulateColdRestart();
      final terminal = await RestoreStartupGate.recoverAndRequireBusinessReady(
        appDataDirectory: root,
      );
      expect(terminal?.state, RestoreReceiptState.committed);

      prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_widthKey), 1234.0);

      // 候选目录里那份册子文件在提交后仍被用作写回来源：
      // 再跑一次启动门（幂等路径）不应重复写、也不应改动已有值。
      await prefs.setDouble(_widthKey, 4321.0);
      expect(
        await RestoreStartupGate.recoverAndRequireBusinessReady(
          appDataDirectory: root,
        ),
        isNull,
      );
      expect((await SharedPreferences.getInstance()).getDouble(_widthKey), 4321.0);
    });

    test('完全覆盖：包内没有本机记录时不写回，但别的设备记录照样并入', () async {
      final archive = await _createLedgerBackupFixture(
        root: root,
        prefix: 'overwrite_other_device',
        ledgerFiles: {
          _otherFingerprint: jsonEncode(
            _ledgerPayload(
              fingerprint: _otherFingerprint,
              deviceName: 'Other PC',
              values: {_widthKey: 999.0},
            ),
          ),
        },
      );

      await restoreWith(archive, mode: RestoreMode.overwrite);
      await simulateColdRestart();
      final terminal = await RestoreStartupGate.recoverAndRequireBusinessReady(
        appDataDirectory: root,
      );
      expect(terminal?.state, RestoreReceiptState.committed);

      expect(
        (await _readLedgerFor(_otherFingerprint))?.values[_widthKey],
        999.0,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_widthKey), isNull);
    });
  });
}
