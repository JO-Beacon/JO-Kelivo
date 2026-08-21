import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/business_preferences.dart';
import '../database/business_repository.dart';
import '../models/backup.dart';
import '../models/progress_update.dart';
import '../services/backup/data_sync.dart';
import '../services/backup/s3_client.dart';
import '../services/backup/temporary_restore_file.dart';
import '../services/chat/chat_service.dart';

class S3BackupProvider extends ChangeNotifier {
  final DataSync _dataSync;
  final S3BackupClient _client;

  S3Config _cfg;
  bool _busy = false;
  String? _message;

  S3BackupProvider({
    required ChatService chatService,
    required BusinessRepository businessRepository,
    required BusinessPreferences businessPreferences,
    S3Config? initialConfig,
  }) : _dataSync = DataSync(
         chatService: chatService,
         businessRepository: businessRepository,
         businessPreferences: businessPreferences,
       ),
       _client = const S3BackupClient(),
       _cfg = initialConfig ?? const S3Config();

  S3Config get config => _cfg;
  bool get busy => _busy;
  String? get message => _message;
  int get skippedConversations =>
      _dataSync.lastMergeReport?.skippedConversations ?? 0;

  void updateConfig(S3Config cfg) {
    _cfg = cfg;
    notifyListeners();
  }

  static String _normalizePrefix(String prefix) {
    var s = prefix.trim().replaceAll(RegExp(r'^/+'), '');
    if (s.isEmpty) return '';
    if (!s.endsWith('/')) s = '$s/';
    return s;
  }

  static String _keyFromItem(BackupFileItem item) {
    if (item.href.scheme == 's3') {
      return item.href.pathSegments.join('/');
    }
    var path = item.href.path;
    if (path.startsWith('/')) path = path.substring(1);
    return path;
  }

  Future<Directory> _ensureTempDir() async {
    Directory dir = await getTemporaryDirectory();
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {}
    }
    if (!await dir.exists()) {
      dir = await Directory.systemTemp.createTemp('kelivo_tmp_');
    }
    return dir;
  }

  WebDavConfig _scopeAsWebdavConfig() {
    // DataSync 目前使用 WebDavConfig 获取包含标志；其他字段会被忽略。
    return WebDavConfig(
      includeChats: _cfg.includeChats,
      includeFiles: _cfg.includeFiles,
    );
  }

  Future<void> test() async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      await _client.test(_cfg);
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
    File? file;
    try {
      file = await _dataSync.prepareJoaiclientFile(
        _scopeAsWebdavConfig(),
        onProgress: (update) => onProgress?.call(
          ProgressUpdate(
            value: update.fraction == null ? null : update.fraction! * 0.55,
          ),
        ),
      );
      final prefix = _normalizePrefix(_cfg.prefix);
      final key = '$prefix${p.basename(file.path)}';
      // 使用文件流上传以避免将整个 ZIP 加载到内存中。
      onProgress?.call(const ProgressUpdate(value: 0.6));
      await _client.uploadFile(
        _cfg,
        key: key,
        file: file,
        onProgress: (update) => onProgress?.call(
          ProgressUpdate(
            value: update.fraction == null
                ? null
                : 0.6 + update.fraction! * 0.4,
          ),
        ),
      );
      onProgress?.call(const ProgressUpdate(value: 1));
      _message = 'Backup uploaded';
      return true;
    } catch (e) {
      _message = e.toString();
      return false;
    } finally {
      await DataSync.cleanupTemporaryBackupFile(file);
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<BackupFileItem>> listRemote() async {
    return _client.listObjects(_cfg);
  }

  Future<void> restoreFromItem(
    BackupFileItem item, {
    RestoreMode mode = RestoreMode.overwrite,
    ProgressCallback? onProgress,
  }) async {
    _busy = true;
    _message = null;
    notifyListeners();
    File? file;
    try {
      final key = _keyFromItem(item);
      final tmp = await _ensureTempDir();
      file = await createTemporaryRestoreFile(tmp);
      // 直接下载到文件以避免将整个对象保留在内存中。
      await _client.downloadToFile(
        _cfg,
        key: key,
        destination: file,
        onProgress: (update) => onProgress?.call(
          ProgressUpdate(
            value: update.fraction == null ? null : update.fraction! * 0.3,
          ),
        ),
      );
      onProgress?.call(const ProgressUpdate(value: 0.3));
      await _dataSync.restoreFromLocalFile(
        file,
        _scopeAsWebdavConfig(),
        mode: mode,
        onProgress: (update) => onProgress?.call(
          ProgressUpdate(
            value: update.fraction == null
                ? null
                : 0.3 + update.fraction! * 0.7,
          ),
        ),
      );
      onProgress?.call(const ProgressUpdate(value: 1));
      _message = 'Restored';
    } catch (e) {
      _message = e.toString();
      rethrow;
    } finally {
      try {
        if (file != null && await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<BackupFileItem>> deleteAndReload(BackupFileItem item) async {
    final key = _keyFromItem(item);
    await _client.deleteObject(_cfg, key: key);
    return _client.listObjects(_cfg);
  }
}
