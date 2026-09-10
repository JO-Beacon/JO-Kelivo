import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import '../database/business_repository.dart';
import '../models/backup.dart';
import '../models/backup_task_progress.dart';
import '../models/progress_update.dart';
import '../services/chat/chat_service.dart';
import '../services/backup/data_sync.dart';
import '../services/backup/backup_activity.dart';
import '../services/backup/device_ledger_export_settings.dart';
import '../services/backup/local_device_settings_ledger.dart';

class BackupProvider extends ChangeNotifier {
  final DataSync _dataSync;
  WebDavConfig _cfg;
  bool _busy = false;
  String? _message;

  BackupProvider({
    required ChatService chatService,
    required BusinessRepository businessRepository,
    required BusinessPreferences businessPreferences,
    WebDavConfig? initialConfig,
  }) : _dataSync = DataSync(
         chatService: chatService,
         businessRepository: businessRepository,
         businessPreferences: businessPreferences,
       ),
       _cfg = initialConfig ?? const WebDavConfig();

  WebDavConfig get config => _cfg;
  bool get busy => _busy;
  String? get message => _message;
  int get skippedConversations =>
      _dataSync.lastMergeReport?.skippedConversations ?? 0;

  void updateConfig(WebDavConfig cfg) {
    _cfg = cfg;
    notifyListeners();
  }

  Future<void> test() async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await _dataSync.testWebdav(_cfg);
      _message = 'OK';
    } catch (e) {
      _message = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> backup({ProgressCallback? onProgress}) async {
    BackupActivity.begin();
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      // 云备份与导出本地备份共用同一「带本机设置」档位。
      final ledgerEntries = await _resolveLedgerEntries(
        await DeviceLedgerExportSettings.includeLedger(),
      );
      await _dataSync.backupToWebDav(
        _cfg,
        onProgress: onProgress,
        ledgerEntries: ledgerEntries,
      );
      _message = 'Backup uploaded';
      return true;
    } catch (e) {
      _message = e.toString();
      return false;
    } finally {
      BackupActivity.end();
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> restoreFromItem(
    BackupFileItem item, {
    RestoreMode mode = RestoreMode.overwrite,
    ProgressCallback? onProgress,
  }) async {
    BackupActivity.begin();
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await _dataSync.restoreFromWebDav(
        _cfg,
        item,
        mode: mode,
        onProgress: onProgress,
      );
      _message = 'Restored';
    } catch (e) {
      _message = e.toString();
      rethrow;
    } finally {
      BackupActivity.end();
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<BackupFileItem>> listRemote() async {
    return _dataSync.listBackupFiles(_cfg);
  }

  Future<List<BackupFileItem>> deleteAndReload(BackupFileItem item) async {
    await _dataSync.deleteWebDavBackupFile(_cfg, item);
    return _dataSync.listBackupFiles(_cfg);
  }

  /// 本机设置最后是否真的被写回（合并保留模式下就地写回；完全覆盖在冷重启后）。
  int get localSettingsApplied => _dataSync.lastLocalSettingsApplied;

  /// 本次恢复吸收进册子的设备记录数。
  int get ledgerAbsorbed => _dataSync.lastLedgerAbsorbed;

  /// 本次恢复从包内解析出的设备记录（供收尾弹窗展示）。
  List<DeviceSettingsRecord> get ledgerRecords => _dataSync.lastLedgerRecords;

  bool _lastLedgerUnrecognized = false;

  /// 最近一次「带」档导出 / 云备份是否因指纹采集失败而没带上本机当前设置。
  ///
  /// 册子为空导致的退化为「不带」包结构不算——那种情况没有任何设备记录，
  /// 提示没有意义。只有「册子非空、但本机值没刷新进包」才需要提醒用户。
  bool get lastLedgerUnrecognized => _lastLedgerUnrecognized;

  Future<File> exportToFile({
    ProgressCallback? onProgress,
    BackupCancelToken? cancelToken,
    bool includeLedger = false,
  }) async {
    BackupActivity.begin();
    try {
      final ledgerEntries = await _resolveLedgerEntries(includeLedger);
      return await _dataSync.prepareJoaiclientFile(
        _cfg,
        onProgress: onProgress,
        cancelToken: cancelToken,
        ledgerEntries: ledgerEntries,
      );
    } finally {
      BackupActivity.end();
    }
  }

  /// 按档位采集要随包携带的册子内容。
  ///
  /// 返回 null 表示退化为「不带」包结构（档位关，或册子为空）。
  /// 同时刷新 [lastLedgerUnrecognized]：指纹采集失败但册子非空时为 true。
  Future<Map<String, String>?> _resolveLedgerEntries(bool include) async {
    if (!include) {
      _lastLedgerUnrecognized = false;
      return null;
    }
    final payload = await DeviceLedgerExportCollector.collect();
    _lastLedgerUnrecognized =
        payload.entries.isNotEmpty && !payload.localDeviceRecognized;
    return payload.entries.isEmpty ? null : payload.entries;
  }

  Future<File> exportKelivoBackupToFile() async {
    BackupActivity.begin();
    try {
      return await _dataSync.prepareBackupFile(_cfg);
    } finally {
      BackupActivity.end();
    }
  }

  Future<void> restoreFromLocalFile(
    File file, {
    RestoreMode mode = RestoreMode.overwrite,
    ProgressCallback? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    BackupActivity.begin();
    try {
      await _dataSync.restoreFromLocalFile(
        file,
        _cfg,
        mode: mode,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } finally {
      BackupActivity.end();
    }
  }
}
