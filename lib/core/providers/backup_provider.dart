import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import '../database/business_repository.dart';
import '../models/backup.dart';
import '../models/progress_update.dart';
import '../services/chat/chat_service.dart';
import '../services/backup/data_sync.dart';

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
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await _dataSync.backupToWebDav(_cfg, onProgress: onProgress);
      _message = 'Backup uploaded';
      return true;
    } catch (e) {
      _message = e.toString();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> restoreFromItem(
    BackupFileItem item, {
    RestoreMode mode = RestoreMode.overwrite,
    ProgressCallback? onProgress,
  }) async {
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

  Future<File> exportToFile({ProgressCallback? onProgress}) =>
      _dataSync.exportToFile(_cfg, onProgress: onProgress);

  Future<File> exportKelivoBackupToFile() => _dataSync.prepareBackupFile(_cfg);

  Future<void> restoreFromLocalFile(
    File file, {
    RestoreMode mode = RestoreMode.overwrite,
    ProgressCallback? onProgress,
  }) => _dataSync.restoreFromLocalFile(
    file,
    _cfg,
    mode: mode,
    onProgress: onProgress,
  );
}
