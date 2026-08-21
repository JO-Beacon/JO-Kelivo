import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../../database/business_repository.dart';
import '../../database/business_preferences.dart';
import '../../database/business_restore_service.dart';
import '../../database/business_settings_router.dart';
import '../../database/app_database.dart';
import '../../database/chat_database_repository.dart';
import '../../models/backup.dart';
import '../../models/chat_message.dart';
import '../../models/message_part.dart';
import '../../models/conversation.dart';
import '../../models/progress_update.dart';
import '../chat/chat_service.dart';
import '../migration/legacy_message_content_decoder.dart';
import '../migration/legacy_record_sanitizer.dart';
import '../migration/migration_backup_file_name.dart';
import '../../utils/multimodal_input_utils.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';
import 'backup_settings_validator.dart';
import 'joaiclient_archive.dart';
import 'restore_bundle_preparation.dart';
import 'temporary_restore_file.dart';

typedef _ParsedChatBackup = ({
  List<Conversation> conversations,
  List<ChatMessage> messages,
  Map<String, List<Map<String, dynamic>>> toolEvents,
  Map<String, String> geminiThoughtSigs,
});

typedef _BackupEntryMetadata = ({int bytes, String sha256});
typedef _VersionedBackupInfo = ({
  bool includeChats,
  bool includeFiles,
  bool secretsIncluded,
  Map<String, Object?>? businessEntityRowIds,
  String normalizedManifestSha256,
});

/// 根据当前文件系统重新计算 [ImagePart]/[FilePart.unavailable]。
///
/// Remote/data URI 保持可用。Local URI 使用 [SandboxPathResolver.localFileExists]
/// （仅结构化重映射；不做通用的 images/upload basename 探测）。
/// 用于文件恢复后刷新旧版 chats.json 导入，这些导入在资源复制
/// 之前已经解码。

List<MessagePart> _normalizeAttachmentPartUris(List<MessagePart> parts) {
  var changed = false;
  final out = <MessagePart>[];
  for (final part in parts) {
    if (part is ImagePart) {
      final uri = SandboxPathResolver.canonicalize(part.uri);
      if (uri != part.uri) {
        changed = true;
        out.add(
          ImagePart(
            uri: uri,
            mime: part.mime,
            assetId: part.assetId,
            unavailable: part.unavailable,
          ),
        );
      } else {
        out.add(part);
      }
    } else if (part is FilePart) {
      final uri = SandboxPathResolver.canonicalize(part.uri);
      if (uri != part.uri) {
        changed = true;
        out.add(
          FilePart(
            uri: uri,
            name: part.name,
            mime: part.mime,
            assetId: part.assetId,
            unavailable: part.unavailable,
          ),
        );
      } else {
        out.add(part);
      }
    } else {
      out.add(part);
    }
  }
  return changed ? out : parts;
}

List<MessagePart> _remapRestoredAttachmentPartUris(List<MessagePart> parts) {
  var changed = false;
  final out = <MessagePart>[];
  for (final part in parts) {
    if (part is ImagePart) {
      final uri =
          SandboxPathResolver.tryRemapRestoredManagedAbsolute(part.uri) ??
          part.uri;
      if (uri != part.uri) {
        changed = true;
        out.add(
          ImagePart(
            uri: uri,
            mime: part.mime,
            assetId: part.assetId,
            unavailable: part.unavailable,
          ),
        );
      } else {
        out.add(part);
      }
    } else if (part is FilePart) {
      final uri =
          SandboxPathResolver.tryRemapRestoredManagedAbsolute(part.uri) ??
          part.uri;
      if (uri != part.uri) {
        changed = true;
        out.add(
          FilePart(
            uri: uri,
            name: part.name,
            mime: part.mime,
            assetId: part.assetId,
            unavailable: part.unavailable,
          ),
        );
      } else {
        out.add(part);
      }
    } else {
      out.add(part);
    }
  }
  return changed ? out : parts;
}

List<MessagePart> recomputeAttachmentAvailability(
  List<MessagePart> parts, {
  bool Function(String path)? fileExists,
}) {
  final exists = fileExists ?? _attachmentExistsOnDisk;
  final out = <MessagePart>[];
  var changed = false;
  for (final part in parts) {
    if (part is ImagePart) {
      final unavailable = _unavailableForUri(part.uri, exists);
      if (unavailable != part.unavailable) changed = true;
      out.add(
        ImagePart(
          uri: part.uri,
          mime: part.mime,
          assetId: part.assetId,
          unavailable: unavailable,
        ),
      );
    } else if (part is FilePart) {
      final unavailable = _unavailableForUri(part.uri, exists);
      if (unavailable != part.unavailable) changed = true;
      out.add(
        FilePart(
          uri: part.uri,
          name: part.name,
          mime: part.mime,
          assetId: part.assetId,
          unavailable: unavailable,
        ),
      );
    } else {
      out.add(part);
    }
  }
  return changed ? out : parts;
}

bool _unavailableForUri(String uri, bool Function(String path) exists) {
  if (isRemoteOrDataUri(uri)) return false;
  return !exists(uri);
}

bool _attachmentExistsOnDisk(String path) {
  // 不要使用 fix()：其通用的 `/images/`·基名探测可能将
  // 缺失的外部路径标记为可用，只因存在同名的受管文件。
  return SandboxPathResolver.localFileExists(path);
}

class DataSync {
  static const _backupFormat = 'kelivo-backup';
  static const _backupFormatVersion = 2;
  static const _manifestEntryName = 'manifest.json';
  static const _databaseEntryName = 'database/kelivo.db';
  // 16 MiB 的元数据上限可让清单解析和条目元数据保持有界。
  static const _maxManifestBytes = 16 * 1024 * 1024;
  // 设置会被解析为单个 JSON 对象，因此要保持其解码输入有界。
  static const _maxSettingsBytes = 16 * 1024 * 1024;
  // ZIP64 支持更大的条目。恢复过程保持明确且可诊断的边界。
  static const _maxRestoreEntryBytes = 8 * 1024 * 1024 * 1024;
  static const _maxRestoreTotalBytes = 16 * 1024 * 1024 * 1024;
  static const _maxRestoreEntries = 100000;

  final ChatService chatService;
  final BusinessRepository businessRepository;
  final BusinessPreferences? businessPreferences;
  BackupMergeReport? _lastMergeReport;
  BackupMergeReport? get lastMergeReport => _lastMergeReport;

  DataSync({
    required this.chatService,
    required this.businessRepository,
    this.businessPreferences,
  });

  Future<T> _runLiveBusinessRestore<T>(Future<T> Function() operation) {
    final preferences = businessPreferences;
    return preferences == null
        ? operation()
        : preferences.runWithRestoreWriteFence(operation);
  }

  static Future<void> _prepareRestoreBundle({
    required String appDataPath,
    required String extractedPath,
    required String sourceManifestSha256,
    required bool includeChats,
    required bool includeFiles,
    required bool restoreChats,
    required bool restoreFiles,
  }) => Isolate.run(() async {
    await RestoreBundlePreparation.prepare(
      appDataDirectory: Directory(appDataPath),
      extractedDirectory: Directory(extractedPath),
      sourceManifestSha256: sourceManifestSha256,
      bundleIncludesChats: includeChats,
      bundleIncludesFiles: includeFiles,
      restoreChats: restoreChats,
      restoreFiles: restoreFiles,
    );
  });

  // ===== WebDAV 辅助方法 =====
  Uri _collectionUri(WebDavConfig cfg) {
    String base = cfg.url.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    String pathPart = cfg.path.trim();
    if (pathPart.isNotEmpty) {
      pathPart = '/${pathPart.replaceAll(RegExp(r'^/+'), '')}';
    }
    // 确保集合路径末尾有斜杠
    final full = '$base$pathPart/';
    return Uri.parse(full);
  }

  Uri _fileUri(WebDavConfig cfg, String childName) {
    final base = _collectionUri(cfg).toString();
    final child = childName.replaceAll(RegExp(r'^/+'), '');
    return Uri.parse('$base$child');
  }

  Map<String, String> _authHeaders(WebDavConfig cfg) {
    if (cfg.username.trim().isEmpty) return {};
    final token = base64Encode(utf8.encode('${cfg.username}:${cfg.password}'));
    return {'Authorization': 'Basic $token'};
  }

  Map<String, String> _extraHeaders(WebDavConfig cfg) {
    final h = <String, String>{};
    final ua = cfg.userAgent.trim();
    if (ua.isNotEmpty) h['User-Agent'] = ua;
    return h;
  }

  Future<void> _ensureCollection(WebDavConfig cfg) async {
    final client = http.Client();
    try {
      // 确保每个路径段都存在
      final url = cfg.url.trim().replaceAll(RegExp(r'/+$'), '');
      final segments = cfg.path
          .split('/')
          .where((s) => s.trim().isNotEmpty)
          .toList();
      String acc = url;
      for (final seg in segments) {
        acc = '$acc/$seg';
        // 对此集合执行 PROPFIND depth 0（末尾带斜杠）
        final u = Uri.parse('$acc/');
        final req = http.Request('PROPFIND', u);
        req.headers.addAll({
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
          ..._authHeaders(cfg),
          ..._extraHeaders(cfg),
        });
        req.body =
            '<?xml version="1.0" encoding="utf-8" ?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>';
        final res = await client.send(req).then(http.Response.fromStream);
        if (res.statusCode == 404) {
          // 创建这一层级
          final mk = await client
              .send(
                http.Request('MKCOL', u)
                  ..headers.addAll({
                    ..._authHeaders(cfg),
                    ..._extraHeaders(cfg),
                  }),
              )
              .then(http.Response.fromStream);
          if (mk.statusCode != 201 &&
              mk.statusCode != 200 &&
              mk.statusCode != 405) {
            throw Exception('MKCOL failed at $u: ${mk.statusCode}');
          }
        } else if (res.statusCode == 401) {
          throw Exception('Unauthorized');
        } else if (!(res.statusCode >= 200 && res.statusCode < 400)) {
          // 有些服务器返回 207 Multi-Status；接受 2xx/3xx/207
          if (res.statusCode != 207) {
            throw Exception('PROPFIND error at $u: ${res.statusCode}');
          }
        }
      }
    } finally {
      client.close();
    }
  }

  // ===== 公共 API =====
  Future<void> testWebdav(WebDavConfig cfg) async {
    final uri = _collectionUri(cfg);
    final req = http.Request('PROPFIND', uri);
    req.headers.addAll({
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8',
      ..._authHeaders(cfg),
      ..._extraHeaders(cfg),
    });
    req.body =
        '<?xml version="1.0" encoding="utf-8" ?>\n'
        '<d:propfind xmlns:d="DAV:">\n'
        '  <d:prop>\n'
        '    <d:displayname/>\n'
        '  </d:prop>\n'
        '</d:propfind>';
    final res = await http.Client().send(req).then(http.Response.fromStream);
    if (res.statusCode != 207 &&
        (res.statusCode < 200 || res.statusCode >= 300)) {
      throw Exception('WebDAV test failed: ${res.statusCode}');
    }
  }

  Future<File> prepareBackupFile(WebDavConfig cfg) async {
    final tmp = await _ensureTempDir();
    await _cleanupPreviousBackupTempFiles(tmp);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final workDir = Directory(p.join(tmp.path, 'kelivo_backup_$timestamp'));
    await workDir.create(recursive: true);

    final outPath = p.join(workDir.path, 'kelivo_backup_$timestamp.zip');
    final outFile = File(outPath);
    if (await outFile.exists()) await outFile.delete();

    File? manifestTmp;
    File? settingsTmp;
    File? databaseTmp;
    try {
      // --- 第 1 步：准备需要 ChatService 的临时文件（主 isolate）---
      // settings.json
      final businessExport = await _exportBusinessSettings();
      final settingsFile = await _writeTempText(
        workDir,
        '_bk_settings.json',
        businessExport.settingsJson,
      );
      settingsTmp = settingsFile;

      ChatDatabaseSnapshotInfo? snapshotInfo;
      if (cfg.includeChats) {
        final databaseFile = File(p.join(workDir.path, '_bk_kelivo.db'));
        databaseTmp = databaseFile;
        snapshotInfo = await chatService.createBackupDatabaseSnapshot(
          databaseFile,
        );
      }

      final packageInfo = await PackageInfo.fromPlatform();
      final appVersion = packageInfo.buildNumber.trim().isEmpty
          ? packageInfo.version
          : '${packageInfo.version}+${packageInfo.buildNumber}';
      final manifestFile = File(p.join(workDir.path, '_bk_manifest.json'));
      manifestTmp = manifestFile;

      // 解析目录路径（需要在主 isolate 上使用 AppDirectories）
      final uploadDirPath = (await _getUploadDir()).path;
      final avatarsDirPath = (await _getAvatarsDir()).path;
      final imagesDirPath = (await _getImagesDir()).path;
      final fontsDirPath = (await _getFontsDir()).path;
      final manifestPath = manifestFile.path;
      final settingsPath = settingsFile.path;
      final databasePath = databaseTmp?.path;
      final includeFiles = cfg.includeFiles;
      final verifyDirPath = p.join(workDir.path, '_verify');

      // --- 第 2 步：在独立 isolate 中执行 CPU 密集的 ZIP 打包 ---
      await Isolate.run(() async {
        _packZipSync(
          outPath: outPath,
          manifestPath: manifestPath,
          settingsPath: settingsPath,
          databasePath: databasePath,
          snapshotInfo: snapshotInfo,
          includeChats: cfg.includeChats,
          includeFiles: includeFiles,
          appVersion: appVersion,
          businessEntityRowIds: businessExport.entityRowIds,
          uploadDirPath: uploadDirPath,
          avatarsDirPath: avatarsDirPath,
          imagesDirPath: imagesDirPath,
          fontsDirPath: fontsDirPath,
        );
        final verifyDir = Directory(verifyDirPath);
        try {
          verifyDir.createSync(recursive: true);
          _extractZipSync(outPath, verifyDirPath);
          await _preflightVersionedBackup(
            manifestPath: p.join(verifyDirPath, _manifestEntryName),
            extractDirPath: verifyDirPath,
          );
        } finally {
          if (verifyDir.existsSync()) {
            verifyDir.deleteSync(recursive: true);
          }
        }
      });

      return outFile;
    } catch (_) {
      await _deleteDirectoryQuietly(workDir);
      rethrow;
    } finally {
      // 清理临时中间文件。最终 zip 会返回给调用方，
      // 并由上传/导出调用方在使用完毕后负责删除。
      await _deleteFileQuietly(settingsTmp);
      await _deleteFileQuietly(databaseTmp);
      await _deleteFileQuietly(manifestTmp);
    }
  }

  /// 使用相同的 payload writer 打包迁移快照。
  /// 这是 0.1.8+8 导出路径。调用方提供快照数据库和已导出的业务设置，
  /// 因为迁移在实时会话服务和当前 schema 数据库接收之前运行。
  static Future<File> prepareMigrationBackupFile({
    required Directory outputDirectory,
    required File snapshotDatabase,
    required ChatDatabaseSnapshotInfo snapshotInfo,
    required String settingsJson,
    required Map<String, List<String>> businessEntityRowIds,
    required Directory uploadDirectory,
    required Directory avatarsDirectory,
    required Directory imagesDirectory,
    required Directory fontsDirectory,
  }) async {
    await outputDirectory.create(recursive: true);
    final workDir = await Directory.systemTemp.createTemp(
      'kelivo_migration_backup_',
    );
    final outFile = File(
      p.join(outputDirectory.path, migrationBackupFileName()),
    );
    final settingsFile = File(p.join(workDir.path, '_bk_settings.json'))
      ..writeAsStringSync(settingsJson, flush: true);
    final manifestFile = File(p.join(workDir.path, '_bk_manifest.json'));
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final appVersion = packageInfo.buildNumber.trim().isEmpty
          ? packageInfo.version
          : '${packageInfo.version}+${packageInfo.buildNumber}';
      await Isolate.run(() {
        _packZipSync(
          outPath: outFile.path,
          manifestPath: manifestFile.path,
          settingsPath: settingsFile.path,
          databasePath: snapshotDatabase.path,
          snapshotInfo: snapshotInfo,
          includeChats: true,
          includeFiles: true,
          appVersion: appVersion,
          businessEntityRowIds: businessEntityRowIds,
          uploadDirPath: uploadDirectory.path,
          avatarsDirPath: avatarsDirectory.path,
          imagesDirPath: imagesDirectory.path,
          fontsDirPath: fontsDirectory.path,
        );
      });
      return outFile;
    } catch (_) {
      if (await outFile.exists()) await outFile.delete();
      rethrow;
    } finally {
      if (await workDir.exists()) await workDir.delete(recursive: true);
    }
  }

  static Future<void> cleanupTemporaryBackupFile(File? file) async {
    if (file == null) return;
    final parent = file.parent;
    await _deleteFileQuietly(file);
    try {
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (_) {}
  }

  static Future<void> _deleteFileQuietly(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<void> _deleteDirectoryQuietly(Directory? directory) async {
    if (directory == null) return;
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// 从 `kelivo_backup_<iso-with-dashes>` 名称中解析出创建时间
  /// （参见 [prepareBackupFile]，该方法会把 ':' 替换为 '-'）。对于
  /// 不包含时间戳的名称返回 null。
  static DateTime? _backupTempTimestampFromName(String name) {
    const prefix = 'kelivo_backup_';
    if (!name.startsWith(prefix)) return null;
    var core = name.substring(prefix.length);
    for (final extension in const ['.joaiclient', '.zip']) {
      if (core.endsWith(extension)) {
        core = core.substring(0, core.length - extension.length);
        break;
      }
    }
    final match = RegExp(
      r'^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})(.*)$',
    ).firstMatch(core);
    if (match == null) return null;
    return DateTime.tryParse(
      '${match[1]}T${match[2]}:${match[3]}:${match[4]}${match[5]}',
    );
  }

  static Future<void> _cleanupPreviousBackupTempFiles(Directory tmp) async {
    try {
      if (!await tmp.exists()) return;
      // 仅回收明确废弃的条目。WebDAV、S3 和本地导出是独立提供者，
      // 没有共享的 busy 标志，因此这里按时间盲目清理会删除仍被另一个提供者
      // 打包或上传中的备份工作目录。
      final cutoff = DateTime.now().subtract(const Duration(hours: 6));
      Future<bool> isStale(FileSystemEntity entity, String name) async {
        final fromName = _backupTempTimestampFromName(name);
        if (fromName != null) return fromName.isBefore(cutoff);
        try {
          return (await entity.stat()).modified.isBefore(cutoff);
        } catch (_) {
          // 年龄未知：保留它，而不是冒着与正在进行的备份竞争的风险。
          return false;
        }
      }

      await for (final ent in tmp.list(followLinks: false)) {
        final name = p.basename(ent.path);
        if (ent is Directory && name.startsWith('kelivo_backup_')) {
          if (await isStale(ent, name)) await _deleteDirectoryQuietly(ent);
        } else if (ent is File &&
            ((name.startsWith('kelivo_backup_') &&
                    (name.endsWith('.zip') || name.endsWith('.joaiclient'))) ||
                name == '_bk_settings.json' ||
                name == '_bk_chats.json' ||
                name == '_bk_manifest.json' ||
                name == '_bk_kelivo.db')) {
          if (await isStale(ent, name)) await _deleteFileQuietly(ent);
        }
      }
    } catch (_) {}
  }

  /// 同步 ZIP 打包 —— 在 Isolate 内运行。
  static void _packZipSync({
    required String outPath,
    required String manifestPath,
    required String settingsPath,
    String? databasePath,
    required ChatDatabaseSnapshotInfo? snapshotInfo,
    required bool includeChats,
    required bool includeFiles,
    required String appVersion,
    required Map<String, List<String>> businessEntityRowIds,
    required String uploadDirPath,
    required String avatarsDirPath,
    required String imagesDirPath,
    required String fontsDirPath,
  }) {
    if (includeChats != (databasePath != null && snapshotInfo != null)) {
      throw StateError('backup_database_component');
    }
    final writer = _StreamingZipWriter(outPath);
    try {
      final entries = <String, _BackupEntryMetadata>{};
      final collisionKeys = <String>{};
      _addFileToZip(
        writer,
        settingsPath,
        'settings.json',
        entries,
        collisionKeys,
      );

      if (databasePath != null) {
        _addFileToZip(
          writer,
          databasePath,
          _databaseEntryName,
          entries,
          collisionKeys,
        );
      }

      if (includeFiles) {
        _addDirectoryToZip(
          writer,
          uploadDirPath,
          'upload',
          entries,
          collisionKeys,
        );
        _addDirectoryToZip(
          writer,
          avatarsDirPath,
          'avatars',
          entries,
          collisionKeys,
        );
        _addDirectoryToZip(
          writer,
          imagesDirPath,
          'images',
          entries,
          collisionKeys,
        );
        _addDirectoryToZip(
          writer,
          fontsDirPath,
          'fonts',
          entries,
          collisionKeys,
        );
      }

      final manifestJson = _buildBackupManifestJson(
        entries: entries,
        snapshotInfo: snapshotInfo,
        includeChats: includeChats,
        includeFiles: includeFiles,
        appVersion: appVersion,
        businessEntityRowIds: businessEntityRowIds,
      );
      final manifestFile = File(manifestPath)
        ..writeAsStringSync(manifestJson, flush: true);
      writer.addFile(manifestFile, _manifestEntryName);
      writer.closeSync();
    } finally {
      writer.closeIfNeededSync();
    }
  }

  static void _addFileToZip(
    _StreamingZipWriter writer,
    String filePath,
    String entryName,
    Map<String, _BackupEntryMetadata> entries,
    Set<String> collisionKeys,
  ) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Backup entry does not exist', filePath);
    }
    final canonicalName = _zipEntryName(entryName);
    final collisionKey = canonicalName.toLowerCase();
    if (!collisionKeys.add(collisionKey)) {
      throw StateError('backup_entry_collision:$canonicalName');
    }
    entries[canonicalName] = writer.addFile(file, canonicalName);
  }

  /// 将 [srcDirPath] 中的所有文件添加到 zip 中的 [zipPrefix] 下。
  static void _addDirectoryToZip(
    _StreamingZipWriter writer,
    String srcDirPath,
    String zipPrefix,
    Map<String, _BackupEntryMetadata> entries,
    Set<String> collisionKeys,
  ) {
    final dir = Directory(srcDirPath);
    if (!dir.existsSync()) return;
    final fileSystemEntries = dir.listSync(recursive: true, followLinks: false);
    for (final ent in fileSystemEntries) {
      if (ent is File) {
        final rel = p.relative(ent.path, from: srcDirPath);
        // ZIP 条目必须使用正斜杠，与平台无关
        final relPosix = rel.replaceAll('\\', '/');
        _addFileToZip(
          writer,
          ent.path,
          '$zipPrefix/$relPosix',
          entries,
          collisionKeys,
        );
      }
    }
  }

  static String _zipEntryName(String name) {
    return name.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
  }

  /// 将 DOS 日期/时间打包值（来自 ZIP 条目的 lastModTime）解码为
  /// [DateTime]。当日期部分为零（未设置）时返回 null。
  static DateTime? _decodeDosDateTime(int packed) {
    final dosDate = packed >> 16;
    final dosTime = packed & 0xFFFF;
    if (dosDate == 0) return null;
    final year = ((dosDate >> 9) & 0x7f) + 1980;
    final month = (dosDate >> 5) & 0x0f;
    final day = dosDate & 0x1f;
    final hour = (dosTime >> 11) & 0x1f;
    final minute = (dosTime >> 5) & 0x3f;
    final second = (dosTime & 0x1f) * 2;
    try {
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _extractZipWithProgress({
    required String zipPath,
    required String extractDirPath,
    required void Function(int processed, int total) onProgress,
  }) async {
    final progressPort = ReceivePort();
    final sendPort = progressPort.sendPort;
    final subscription = progressPort.listen((message) {
      if (message is List && message.length == 2) {
        final processed = message[0];
        final total = message[1];
        if (processed is int && total is int) {
          onProgress(processed, total);
        }
      }
    });
    try {
      await Isolate.run(() {
        _extractZipSync(
          zipPath,
          extractDirPath,
          onProgress: (processed, total) {
            sendPort.send([processed, total]);
          },
        );
      });
    } finally {
      await subscription.cancel();
      progressPort.close();
    }
  }

  /// 同步 ZIP 解压，在 isolate 中运行。
  /// 使用 InputFileStream 按需从磁盘读取 ZIP 字节，
  /// 而不是把整个归档加载到单个字节数组中。
  static void _extractZipSync(
    String zipPath,
    String extractDirPath, {
    void Function(int processed, int total)? onProgress,
  }) {
    final inputStream = InputFileStream(zipPath);
    try {
      final rawEntryNames = <String>[];
      final archive = ZipDecoder().decodeStream(
        inputStream,
        callback: (entry) => rawEntryNames.add(entry.name),
      );
      try {
        if (rawEntryNames.length > _maxRestoreEntries) {
          throw const FormatException('zip_entry_count');
        }
        final seenNames = <String>{};
        for (final rawName in rawEntryNames) {
          final canonical = _validatedZipEntryName(rawName);
          if (!seenNames.add(canonical.toLowerCase())) {
            throw FormatException('duplicate_zip_entry:$canonical');
          }
        }

        final archiveFiles = <String, ArchiveFile>{};
        final allEntryNames = <String>[];
        for (final entry in archive) {
          if (entry.isSymbolicLink) {
            throw FormatException('symbolic_link:${entry.name}');
          }
          final canonical = _validatedZipEntryName(entry.name);
          allEntryNames.add(canonical);
          if (entry.isFile) {
            archiveFiles[canonical] = entry;
          }
        }
        _validateZipPathPrefixes(allEntryNames, archiveFiles.keys);

        final settingsEntry = archiveFiles['settings.json'];
        if (settingsEntry != null &&
            (settingsEntry.size <= 0 ||
                settingsEntry.size > _maxSettingsBytes)) {
          throw const FormatException('settings_size');
        }

        final manifestEntry = archiveFiles[_manifestEntryName];
        Map<String, int>? declaredEntrySizes;
        if (manifestEntry != null) {
          if (manifestEntry.size < 0 ||
              manifestEntry.size > _maxManifestBytes) {
            throw const FormatException('manifest_size');
          }
          final manifestPath = p.join(extractDirPath, _manifestEntryName);
          final manifestOutput = _BoundedOutputFileStream(
            manifestPath,
            expectedBytes: manifestEntry.size,
            maxEntryBytes: _maxManifestBytes,
            budget: _ExtractionBudget(maxTotalBytes: _maxManifestBytes),
          );
          try {
            manifestEntry.writeContent(manifestOutput);
            manifestOutput.verifyComplete();
          } finally {
            manifestOutput.closeSync();
          }
          final manifestBytes = File(manifestPath).readAsBytesSync();
          declaredEntrySizes = _declaredManifestEntrySizes(manifestBytes);
          final actualEntries = archiveFiles.keys.toSet()
            ..remove(_manifestEntryName);
          if (actualEntries.length != declaredEntrySizes.length ||
              !actualEntries.containsAll(declaredEntrySizes.keys)) {
            throw const FormatException('manifest_entries');
          }
          for (final declaredEntry in declaredEntrySizes.entries) {
            if (archiveFiles[declaredEntry.key]!.size != declaredEntry.value) {
              throw FormatException('manifest_entry_size:${declaredEntry.key}');
            }
          }
        } else if (archiveFiles.containsKey(_databaseEntryName)) {
          throw const FormatException('database_manifest');
        }

        var declaredTotalBytes = 0;
        for (final entry in archiveFiles.values) {
          if (entry.size < 0 || entry.size > _maxRestoreEntryBytes) {
            throw FormatException('zip_entry_size:${entry.name}');
          }
          declaredTotalBytes += entry.size;
          if (declaredTotalBytes > _maxRestoreTotalBytes) {
            throw const FormatException('zip_total_size');
          }
        }
        final extractionBudget = _ExtractionBudget(
          maxTotalBytes: _maxRestoreTotalBytes,
        );
        if (manifestEntry != null) {
          extractionBudget.reserve(manifestEntry.size);
        }
        final extractionTotal = declaredTotalBytes - (manifestEntry?.size ?? 0);
        var extractedBytes = 0;
        onProgress?.call(extractedBytes, extractionTotal);
        for (final entry in archive) {
          final canonical = _validatedZipEntryName(entry.name);
          if (canonical == _manifestEntryName) continue;
          final parts = canonical.split('/');
          final outPath = p.joinAll([extractDirPath, ...parts]);
          if (entry.isFile) {
            File(outPath).parent.createSync(recursive: true);
            final output = _BoundedOutputFileStream(
              outPath,
              expectedBytes: declaredEntrySizes?[canonical] ?? entry.size,
              maxEntryBytes: _maxRestoreEntryBytes,
              budget: extractionBudget,
              onWrite: (bytes) {
                extractedBytes += bytes;
                onProgress?.call(extractedBytes, extractionTotal);
              },
            );
            try {
              entry.writeContent(output);
              output.verifyComplete();
            } finally {
              output.closeSync();
            }
            final dt = _decodeDosDateTime(entry.lastModTime);
            if (dt != null) {
              try {
                File(outPath).setLastModifiedSync(dt);
              } catch (_) {}
            }
          } else {
            Directory(outPath).createSync(recursive: true);
          }
        }
        onProgress?.call(extractionTotal, extractionTotal);
      } finally {
        archive.clearSync();
      }
    } finally {
      inputStream.closeSync();
    }
  }

  static String _validatedZipEntryName(String rawName) {
    if (rawName.isEmpty || rawName.contains('\u0000')) {
      throw const FormatException('zip_entry_name');
    }
    final normalized = rawName.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        normalized.startsWith('//') ||
        RegExp(r'^[A-Za-z]:($|/)').hasMatch(normalized)) {
      throw FormatException('absolute_zip_entry:$rawName');
    }
    final parts = normalized.split('/');
    if (parts.isNotEmpty && parts.last.isEmpty) {
      parts.removeLast();
    }
    if (parts.isEmpty ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('invalid_zip_entry:$rawName');
    }
    return parts.join('/');
  }

  static void _validateZipPathPrefixes(
    Iterable<String> allEntries,
    Iterable<String> fileEntries,
  ) {
    final files = fileEntries.map((name) => name.toLowerCase()).toSet();
    for (final entry in allEntries) {
      final parts = entry.toLowerCase().split('/');
      for (var i = 1; i < parts.length; i++) {
        if (files.contains(parts.take(i).join('/'))) {
          throw FormatException('zip_path_prefix:$entry');
        }
      }
    }
  }

  static Map<String, int> _declaredManifestEntrySizes(List<int> manifestBytes) {
    final decoded = jsonDecode(utf8.decode(manifestBytes));
    if (decoded is! Map) {
      throw const FormatException('manifest.json');
    }
    final manifest = decoded.cast<String, dynamic>();
    if (manifest['format'] != _backupFormat ||
        manifest['formatVersion'] != _backupFormatVersion) {
      throw const FormatException('manifest_version');
    }
    final rawEntries = manifest['entries'];
    if (rawEntries is! Map) {
      throw const FormatException('manifest_entries');
    }
    final entries = <String, int>{};
    final caseFolded = <String>{};
    for (final rawEntry in rawEntries.entries) {
      final rawName = rawEntry.key;
      if (rawName is! String || rawEntry.value is! Map) {
        throw const FormatException('manifest_entry_name');
      }
      final canonical = _validatedZipEntryName(rawName);
      if (canonical != rawName || canonical == _manifestEntryName) {
        throw FormatException('manifest_entry_name:$rawName');
      }
      if (!caseFolded.add(canonical.toLowerCase())) {
        throw FormatException('manifest_entry_collision:$canonical');
      }
      final metadata = (rawEntry.value as Map).cast<String, dynamic>();
      final bytes = metadata['bytes'];
      if (bytes is! int || bytes < 0) {
        throw FormatException('manifest_entry_size:$canonical');
      }
      entries[canonical] = bytes;
    }
    return entries;
  }

  Future<void> backupToWebDav(
    WebDavConfig cfg, {
    ProgressCallback? onProgress,
  }) async {
    final file = await prepareJoaiclientFile(
      cfg,
      onProgress: (update) => onProgress?.call(
        ProgressUpdate(
          value: update.fraction == null ? null : update.fraction! * 0.55,
        ),
      ),
    );
    try {
      onProgress?.call(const ProgressUpdate(value: 0.6));
      await _ensureCollection(cfg);
      final target = _fileUri(cfg, p.basename(file.path));
      final fileLen = await file.length();
      // 使用流式请求，以免将整个文件加载到 RAM 中。
      final req = http.StreamedRequest('PUT', target);
      req.headers.addAll({
        'content-type': 'application/octet-stream',
        'content-length': fileLen.toString(),
        ..._authHeaders(cfg),
        ..._extraHeaders(cfg),
      });
      // 将文件流传入请求体。addStream 会遵循 sink 的暂停信号，
      // 使慢速网络节流磁盘读取，而不是在内存中缓存整个 zip
      // （此前曾导致大型移动端上传被 OOM 杀死）。
      var uploaded = 0;
      unawaited(
        req.sink
            .addStream(
              file.openRead().map((chunk) {
                uploaded += chunk.length;
                onProgress?.call(
                  ProgressUpdate(
                    value: fileLen == 0 ? 1 : 0.6 + uploaded / fileLen * 0.4,
                  ),
                );
                return chunk;
              }),
            )
            .then(
              (_) => req.sink.close(),
              onError: (Object error) {
                req.sink.addError(error);
                req.sink.close();
              },
            ),
      );
      final client = http.Client();
      try {
        final res = await client.send(req).then(http.Response.fromStream);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw Exception('Upload failed: ${res.statusCode}');
        }
        onProgress?.call(const ProgressUpdate(value: 1));
      } finally {
        client.close();
      }
    } finally {
      await cleanupTemporaryBackupFile(file);
    }
  }

  Future<List<BackupFileItem>> listBackupFiles(WebDavConfig cfg) async {
    await _ensureCollection(cfg);
    final uri = _collectionUri(cfg);
    final req = http.Request('PROPFIND', uri);
    req.headers.addAll({
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8',
      ..._authHeaders(cfg),
      ..._extraHeaders(cfg),
    });
    req.body =
        '<?xml version="1.0" encoding="utf-8" ?>\n'
        '<d:propfind xmlns:d="DAV:">\n'
        '  <d:prop>\n'
        '    <d:displayname/>\n'
        '    <d:getcontentlength/>\n'
        '    <d:getlastmodified/>\n'
        '  </d:prop>\n'
        '</d:propfind>';
    final res = await http.Client().send(req).then(http.Response.fromStream);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('PROPFIND failed: ${res.statusCode}');
    }
    final doc = XmlDocument.parse(res.body);
    final items = <BackupFileItem>[];
    final baseStr = uri.toString();
    for (final resp in doc.findAllElements('response', namespace: '*')) {
      final href = resp.getElement('href', namespace: '*')?.innerText ?? '';
      if (href.isEmpty) continue;
      // 跳过集合本身
      final abs = Uri.parse(href).isAbsolute
          ? Uri.parse(href).toString()
          : uri.resolve(href).toString();
      if (abs == baseStr) continue;
      final disp = resp
          .findAllElements('displayname', namespace: '*')
          .map((e) => e.innerText)
          .toList();
      final sizeStr = resp
          .findAllElements('getcontentlength', namespace: '*')
          .map((e) => e.innerText)
          .cast<String>()
          .toList();
      final mtimeStr = resp
          .findAllElements('getlastmodified', namespace: '*')
          .map((e) => e.innerText)
          .cast<String>()
          .toList();
      final size = (sizeStr.isNotEmpty) ? int.tryParse(sizeStr.first) ?? 0 : 0;
      DateTime? mtime;
      if (mtimeStr.isNotEmpty) {
        try {
          mtime = DateTime.parse(mtimeStr.first);
        } catch (_) {}
      }
      final name = (disp.isNotEmpty && disp.first.trim().isNotEmpty)
          ? disp.first.trim()
          : Uri.parse(href).pathSegments.last;

      // 如果 mtime 为 null，则尝试从文件名中提取（格式：kelivo_backup_2025-01-19T12-34-56.123456.zip）
      if (mtime == null) {
        final match = RegExp(
          r'kelivo_backup_(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d+)\.(?:joaiclient|zip)$',
        ).firstMatch(name);
        if (match != null) {
          try {
            // 将时间部分中的连字符替换回冒号
            final timestamp = match
                .group(1)!
                .replaceAll(
                  RegExp(r'T(\d{2})-(\d{2})-(\d{2})'),
                  'T\$1:\$2:\$3',
                );
            mtime = DateTime.parse(timestamp);
          } catch (_) {}
        }
      }

      // 跳过目录
      if (abs.endsWith('/')) continue;
      final fullHref = Uri.parse(abs);
      items.add(
        BackupFileItem(
          href: fullHref,
          displayName: name,
          size: size,
          lastModified: mtime,
        ),
      );
    }
    items.sort(
      (a, b) => (b.lastModified ?? DateTime(0)).compareTo(
        a.lastModified ?? DateTime(0),
      ),
    );
    return items;
  }

  Future<void> restoreFromWebDav(
    WebDavConfig cfg,
    BackupFileItem item, {
    RestoreMode mode = RestoreMode.overwrite,
    ProgressCallback? onProgress,
  }) async {
    // 将下载内容流式写入文件，而不是缓冲在内存中。
    final client = http.Client();
    File? file;
    try {
      final req = http.Request('GET', item.href);
      req.headers.addAll({..._authHeaders(cfg), ..._extraHeaders(cfg)});
      final streamed = await client.send(req);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        // 排空响应体，以便客户端能够干净地关闭。
        await streamed.stream.drain<void>();
        throw Exception('Download failed: ${streamed.statusCode}');
      }
      final tmpDir = await _ensureTempDir();
      file = await createTemporaryRestoreFile(tmpDir);
      final sink = file.openWrite();
      final total = streamed.contentLength;
      var downloaded = 0;
      await streamed.stream
          .map((chunk) {
            downloaded += chunk.length;
            onProgress?.call(
              ProgressUpdate(
                value: total == null || total <= 0
                    ? null
                    : downloaded / total * 0.3,
              ),
            );
            return chunk;
          })
          .pipe(sink);
      await _restoreFromBackupFile(
        file,
        cfg,
        mode: mode,
        onProgress: (update) => onProgress?.call(
          ProgressUpdate(
            value: update.fraction == null
                ? null
                : 0.3 + update.fraction! * 0.7,
          ),
        ),
      );
    } finally {
      client.close();
      await _deleteFileQuietly(file);
    }
  }

  Future<void> deleteWebDavBackupFile(
    WebDavConfig cfg,
    BackupFileItem item,
  ) async {
    final req = http.Request('DELETE', item.href);
    req.headers.addAll({..._authHeaders(cfg), ..._extraHeaders(cfg)});
    final res = await http.Client().send(req).then(http.Response.fromStream);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Delete failed: ${res.statusCode}');
    }
  }

  Future<File> exportToFile(WebDavConfig cfg, {ProgressCallback? onProgress}) =>
      prepareJoaiclientFile(cfg, onProgress: onProgress);

  /// 创建本地、WebDAV 和 S3 使用的隐式外部归档备份文件。
  /// [prepareBackupFile] 仍作为旧内部文件和旧测试数据的 ZIP 生产者；
  /// 新导出文件从不暴露 ZIP 文件边界之外的入口名称。
  Future<File> prepareJoaiclientFile(
    WebDavConfig cfg, {
    ProgressCallback? onProgress,
  }) async {
    final zipFile = await prepareBackupFile(
      cfg.copyWith(includeChats: true, includeFiles: true),
    );
    onProgress?.call(const ProgressUpdate(value: 0.5));
    final outputFile = File(
      p.join(
        zipFile.parent.path,
        '${p.basenameWithoutExtension(zipFile.path)}.joaiclient',
      ),
    );
    try {
      await JoaiclientArchive.wrapZipPayload(
        zipFile: zipFile,
        outputFile: outputFile,
        onProgress: (update) => onProgress?.call(
          ProgressUpdate(
            value: update.fraction == null
                ? null
                : 0.5 + update.fraction! * 0.5,
          ),
        ),
      );
      await zipFile.delete();
      onProgress?.call(const ProgressUpdate(value: 1));
      return outputFile;
    } catch (_) {
      await _deleteFileQuietly(outputFile);
      rethrow;
    }
  }

  Future<void> restoreFromLocalFile(
    File file,
    WebDavConfig cfg, {
    RestoreMode mode = RestoreMode.overwrite,
    ProgressCallback? onProgress,
  }) async {
    if (!await file.exists()) throw Exception('备份文件不存在');
    await _restoreFromBackupFile(file, cfg, mode: mode, onProgress: onProgress);
  }

  // ===== 内部辅助方法 =====
  /// 确保临时目录存在（某些 macOS 安装可能直到首次使用才创建缓存文件夹）。
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

  Future<File> _writeTempText(
    Directory directory,
    String name,
    String content,
  ) async {
    final f = File(p.join(directory.path, name));
    await f.writeAsString(content);
    return f;
  }

  static String _buildBackupManifestJson({
    required Map<String, _BackupEntryMetadata> entries,
    required ChatDatabaseSnapshotInfo? snapshotInfo,
    required bool includeChats,
    required bool includeFiles,
    required String appVersion,
    required Map<String, List<String>> businessEntityRowIds,
  }) {
    return jsonEncode({
      'format': _backupFormat,
      'formatVersion': _backupFormatVersion,
      'payloadKind': includeChats ? 'sqlite' : 'settings-only',
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
      'includeChats': includeChats,
      'includeFiles': includeFiles,
      'secretsIncluded': true,
      'businessEntityRowIds': businessEntityRowIds,
      if (snapshotInfo != null)
        'database': {
          'entry': _databaseEntryName,
          'schemaVersion': snapshotInfo.schemaVersion,
          'conversationCount': snapshotInfo.conversationCount,
          'messageCount': snapshotInfo.messageCount,
        },
      'entries': entries.map(
        (name, metadata) => MapEntry(name, {
          'bytes': metadata.bytes,
          'sha256': metadata.sha256,
        }),
      ),
    });
  }

  static Future<_VersionedBackupInfo> _preflightVersionedBackup({
    required String manifestPath,
    required String extractDirPath,
  }) async {
    final manifestFile = File(manifestPath);
    if (!manifestFile.existsSync() ||
        manifestFile.lengthSync() > _maxManifestBytes) {
      throw const FormatException('manifest.json');
    }
    final decoded = jsonDecode(manifestFile.readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException('manifest.json');
    }
    final manifest = decoded.cast<String, dynamic>();
    if (manifest['format'] != _backupFormat ||
        manifest['formatVersion'] != _backupFormatVersion) {
      throw const FormatException('manifest_version');
    }
    final payloadKind = manifest['payloadKind'];
    final includeChats = manifest['includeChats'];
    final includeFiles = manifest['includeFiles'];
    if (payloadKind is! String ||
        includeChats is! bool ||
        includeFiles is! bool ||
        manifest['appVersion'] is! String ||
        manifest['createdAtUtc'] is! String ||
        manifest['secretsIncluded'] != true) {
      throw const FormatException('manifest_fields');
    }
    final businessEntityRowIds = _parseBusinessEntityRowIds(manifest);

    final rawEntries = manifest['entries'];
    if (rawEntries is! Map) {
      throw const FormatException('manifest_entries');
    }
    final entries = <String, _BackupEntryMetadata>{};
    for (final rawEntry in rawEntries.entries) {
      if (rawEntry.key is! String || rawEntry.value is! Map) {
        throw const FormatException('manifest_entry');
      }
      final name = rawEntry.key as String;
      final canonical = _validatedZipEntryName(name);
      if (canonical != name || canonical == _manifestEntryName) {
        throw FormatException('manifest_entry_name:$name');
      }
      final metadata = (rawEntry.value as Map).cast<String, dynamic>();
      final bytes = metadata['bytes'];
      final digest = metadata['sha256'];
      if (bytes is! int ||
          bytes < 0 ||
          digest is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        throw FormatException('manifest_entry_metadata:$name');
      }
      entries[name] = (bytes: bytes, sha256: digest);
    }
    if (!entries.containsKey('settings.json')) {
      throw const FormatException('settings.json');
    }
    for (final name in entries.keys) {
      final knownEntry =
          name == 'settings.json' ||
          name == _databaseEntryName ||
          name.startsWith('upload/') ||
          name.startsWith('avatars/') ||
          name.startsWith('images/') ||
          name.startsWith('fonts/');
      if (!knownEntry) {
        throw FormatException('manifest_entry_scope:$name');
      }
      if (!includeFiles &&
          (name.startsWith('upload/') ||
              name.startsWith('avatars/') ||
              name.startsWith('images/') ||
              name.startsWith('fonts/'))) {
        throw FormatException('manifest_files:$name');
      }
    }

    for (final entry in entries.entries) {
      final file = File(p.joinAll([extractDirPath, ...entry.key.split('/')]));
      if (!file.existsSync() || file.lengthSync() != entry.value.bytes) {
        throw FormatException('manifest_entry_size:${entry.key}');
      }
      if (_sha256FileSync(file) != entry.value.sha256) {
        throw FormatException('manifest_entry_hash:${entry.key}');
      }
    }

    final rawDatabase = manifest['database'];
    if (payloadKind == 'sqlite') {
      if (!includeChats ||
          !entries.containsKey(_databaseEntryName) ||
          rawDatabase is! Map) {
        throw const FormatException('manifest_database');
      }
      final database = rawDatabase.cast<String, dynamic>();
      final schemaVersion = database['schemaVersion'];
      final conversationCount = database['conversationCount'];
      final messageCount = database['messageCount'];
      if (database['entry'] != _databaseEntryName ||
          schemaVersion is! int ||
          conversationCount is! int ||
          conversationCount < 0 ||
          messageCount is! int ||
          messageCount < 0) {
        throw const FormatException('manifest_database');
      }
      final databaseFile = File(
        p.joinAll([extractDirPath, ..._databaseEntryName.split('/')]),
      );
      final installedSchemaVersion =
          ChatDatabaseRepository.readInstalledSchemaVersion(databaseFile);
      if (installedSchemaVersion != schemaVersion) {
        throw const FormatException('manifest_database_metadata');
      }
      if (installedSchemaVersion > AppDatabase.currentSchemaVersion) {
        throw StateError('database_schema_too_new');
      }
      if (installedSchemaVersion < 1) {
        throw StateError('database_schema_version');
      }
      if (installedSchemaVersion < AppDatabase.currentSchemaVersion) {
        await ChatDatabaseRepository.migrateInstalledDatabase(databaseFile);
      }
      final databaseInfo =
          await ChatDatabaseRepository.prepareSnapshotForRestore(databaseFile);
      if (databaseInfo.conversationCount != conversationCount ||
          databaseInfo.messageCount != messageCount) {
        throw const FormatException('manifest_database_metadata');
      }
      manifest['database'] = {
        'entry': _databaseEntryName,
        'schemaVersion': databaseInfo.schemaVersion,
        'conversationCount': databaseInfo.conversationCount,
        'messageCount': databaseInfo.messageCount,
      };
      entries[_databaseEntryName] = (
        bytes: databaseFile.lengthSync(),
        sha256: _sha256FileSync(databaseFile),
      );
    } else if (payloadKind == 'settings-only') {
      if (includeChats ||
          entries.containsKey(_databaseEntryName) ||
          rawDatabase != null) {
        throw const FormatException('manifest_database');
      }
    } else {
      throw const FormatException('manifest_payload_kind');
    }

    final sortedEntryNames = entries.keys.toList()..sort();
    manifest['entries'] = {
      for (final name in sortedEntryNames)
        name: {'bytes': entries[name]!.bytes, 'sha256': entries[name]!.sha256},
    };
    final normalizedManifestBytes = utf8.encode(jsonEncode(manifest));
    if (normalizedManifestBytes.length > _maxManifestBytes) {
      throw const FormatException('manifest_size');
    }
    final normalizedManifestSha256 = sha256
        .convert(normalizedManifestBytes)
        .toString();
    manifestFile.writeAsBytesSync(normalizedManifestBytes, flush: true);

    return (
      includeChats: includeChats,
      includeFiles: includeFiles,
      secretsIncluded: true,
      businessEntityRowIds: businessEntityRowIds,
      normalizedManifestSha256: normalizedManifestSha256,
    );
  }

  static Map<String, Object?>? _parseBusinessEntityRowIds(
    Map<String, dynamic> manifest,
  ) {
    if (!manifest.containsKey('businessEntityRowIds')) return null;
    final raw = manifest['businessEntityRowIds'];
    if (raw is! Map || raw.keys.any((key) => key is! String)) {
      throw const FormatException('manifest_business_entity_row_ids');
    }
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! List || value.any((item) => item is! String)) {
        throw const FormatException('manifest_business_entity_row_ids');
      }
      result[entry.key as String] = List<String>.unmodifiable(
        value.cast<String>(),
      );
    }
    return Map<String, Object?>.unmodifiable(result);
  }

  static Map<String, dynamic> _readSettingsJsonSync(String path) {
    final file = File(path);
    if (!file.existsSync()) throw const FormatException('settings.json');
    final length = file.lengthSync();
    if (length <= 0 || length > _maxSettingsBytes) {
      throw const FormatException('settings_size');
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException('settings.json');
    }
    return decoded.cast<String, dynamic>();
  }

  static String _sha256FileSync(File file) {
    final digestSink = _DigestOutputSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    final input = file.openSync();
    final buffer = Uint8List(1024 * 1024);
    try {
      while (true) {
        final read = input.readIntoSync(buffer);
        if (read == 0) break;
        hashSink.add(Uint8List.sublistView(buffer, 0, read));
      }
      hashSink.close();
    } finally {
      input.closeSync();
    }
    final digest = digestSink.digest;
    if (digest == null) {
      throw StateError('sha256');
    }
    return digest.toString();
  }

  Future<Directory> _getUploadDir() async {
    return await AppDirectories.getUploadDirectory();
  }

  Future<Directory> _getImagesDir() async {
    return await AppDirectories.getImagesDirectory();
  }

  Future<Directory> _getAvatarsDir() async {
    return await AppDirectories.getAvatarsDirectory();
  }

  Future<Directory> _getFontsDir() async {
    return await AppDirectories.getFontsDirectory();
  }

  Future<void> _copyRestoredFile(File source, File target) async {
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    try {
      await target.setLastModified(await source.lastModified());
    } on FileSystemException {
      // 有效负载复制是权威的；时间戳只是可选元数据，
      // 适用于不支持设置时间戳的文件系统。
    }
  }

  /// 将备份的资源负载目录（upload/images/avatars/fonts）复制到实时目录，
  /// 不删除任何已有内容，以便未改动的聊天数据库所引用的文件仍能保留。
  Future<void> _restoreAssetDirectoriesAdditive(
    Directory payloadDirectory,
  ) async {
    final targets =
        <({String entryName, Future<Directory> Function() resolveTarget})>[
          (entryName: 'upload', resolveTarget: _getUploadDir),
          (entryName: 'images', resolveTarget: _getImagesDir),
          (entryName: 'avatars', resolveTarget: _getAvatarsDir),
          (entryName: 'fonts', resolveTarget: _getFontsDir),
        ];
    for (final target in targets) {
      final src = Directory(p.join(payloadDirectory.path, target.entryName));
      if (!await src.exists()) continue;
      final dst = await target.resolveTarget();
      if (!await dst.exists()) {
        await dst.create(recursive: true);
      }
      for (final ent in src.listSync(recursive: true)) {
        if (ent is File) {
          final rel = p.relative(ent.path, from: src.path);
          final targetFile = File(p.join(dst.path, rel));
          if (!await targetFile.exists()) {
            await _copyRestoredFile(ent, targetFile);
          }
        }
      }
    }
  }

  Future<void> _validateOverwriteChatCandidate({
    required Directory stagingDirectory,
    required File chatsFile,
  }) async {
    final candidatePath = p.join(stagingDirectory.path, 'candidate.sqlite');
    final chatsPath = chatsFile.path;
    await _deleteDatabaseFamily(candidatePath);
    try {
      await Isolate.run(() async {
        final parsed = _sanitizeLegacyChatBackup(
          await _parseChatBackup(File(chatsPath)),
        );
        // 经过净化的数据必须满足严格的不变量；此处违反
        // 是净化器的错误，而不是可容忍的旧格式。
        _validateBackupReferences(
          conversations: parsed.conversations,
          messages: parsed.messages,
          toolEvents: parsed.toolEvents,
          geminiThoughtSigs: parsed.geminiThoughtSigs,
        );
        await _buildAndValidateOverwriteChatCandidate(
          candidatePath: candidatePath,
          conversations: parsed.conversations,
          messages: parsed.messages,
          toolEvents: parsed.toolEvents,
          geminiThoughtSigs: parsed.geminiThoughtSigs,
        );
      });
    } finally {
      await _deleteDatabaseFamily(candidatePath);
    }
  }

  Future<void> _deleteDatabaseFamily(String databasePath) async {
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final file = File('$databasePath$suffix');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  static Future<_ParsedChatBackup> _parseChatBackup(File chatsFile) async {
    final chats =
        jsonDecode(await chatsFile.readAsString()) as Map<String, dynamic>;
    final version = chats['version'];
    if (version != null && version != 1) {
      throw const FormatException('version');
    }
    if (chats['conversations'] is! List) {
      throw const FormatException('conversations');
    }
    if (chats['messages'] is! List) {
      throw const FormatException('messages');
    }
    final geminiThoughtSigs = <String, String>{};
    final rawGeminiThoughtSigs =
        (chats['geminiThoughtSigs'] as Map?) ?? const <String, dynamic>{};
    for (final entry in rawGeminiThoughtSigs.entries) {
      if (entry.value is! String) {
        throw const FormatException('geminiThoughtSigs');
      }
      geminiThoughtSigs[entry.key.toString()] = entry.value as String;
    }
    final conversations = (chats['conversations'] as List)
        .map(
          (entry) =>
              Conversation.fromJson((entry as Map).cast<String, dynamic>()),
        )
        .toList();

    // 旧版 chats.json 的导入边界：仅当原始 JSON 缺少 `parts` 列表时，
    // 才将带标记的内容提升为结构化 parts。
    // 新导出的内容已经带有 `parts`（包括字面上形似标记的文本），
    // 必须能够往返而不被再次提升。
    var converted = 0;
    var malformed = 0;
    var missingFiles = 0;
    final messages = <ChatMessage>[];
    for (final entry in chats['messages'] as List) {
      final raw = (entry as Map).cast<String, dynamic>();
      final hasPartsList = raw['parts'] is List;
      var message = ChatMessage.fromJson(raw);
      if (message.isStreaming) {
        message = message.copyWith(isStreaming: false);
      }
      if (!hasPartsList) {
        final decoded = await decodeLegacyContent(
          message.content,
          existingParts: message.parts,
        );
        converted += decoded.converted;
        malformed += decoded.malformed;
        missingFiles += decoded.missingFiles;
        if (decoded.converted > 0) {
          message = message.copyWith(parts: decoded.parts);
        }
      }
      // 导入边界：将受管理的本地附件持久化为 kelivo-file URI。
      final normalized = _normalizeAttachmentPartUris(message.parts);
      if (!identical(normalized, message.parts)) {
        message = message.copyWith(parts: normalized);
      }
      messages.add(message);
    }
    if (converted > 0 || malformed > 0 || missingFiles > 0) {
      debugPrint(
        'legacy chats.json decode: converted=$converted '
        'malformed=$malformed missingFiles=$missingFiles',
      );
    }

    return (
      conversations: conversations,
      messages: messages,
      toolEvents: ((chats['toolEvents'] as Map?) ?? const <String, dynamic>{})
          .map(
            (key, value) => MapEntry(
              key.toString(),
              (value as List)
                  .cast<Map>()
                  .map((entry) => entry.cast<String, dynamic>())
                  .toList(),
            ),
          ),
      geminiThoughtSigs: geminiThoughtSigs,
    );
  }

  /// 旧版（1.1.17）备份可能带有旧运行时静默容忍的形状：悬空或重复的
  /// messageIds 引用、没有任何会话引用的消息，以及 conversationId 与引用
  /// 它们的会话不一致的消息。这里恢复 1.1.17 实际显示的内容，而不是拒绝
  /// 归档：每个会话的 messageIds 顺序是权威顺序；悬空引用会被剪除（SQLite
  /// 从 message_order 推导顺序，因此剪除结果与旧运行时一致）；重复引用只
  /// 保留第一次出现；未被引用的消息从未显示，因此会被跳过。它还会把
  /// 1.1.17 使用的原始消息索引和版本序号转换为 SQLite 使用的逻辑槽位
  /// 索引和具体消息版本。
  static _ParsedChatBackup _sanitizeLegacyChatBackup(_ParsedChatBackup parsed) {
    final conversations = <Conversation>[];
    final conversationIds = <String>{};
    var duplicateConversations = 0;
    for (final conversation in parsed.conversations) {
      if (conversationIds.add(conversation.id)) {
        conversations.add(conversation);
      } else {
        duplicateConversations++;
      }
    }

    final messagesById = <String, ChatMessage>{};
    var duplicateMessages = 0;
    for (final message in parsed.messages) {
      if (messagesById.containsKey(message.id)) {
        duplicateMessages++;
      } else {
        messagesById[message.id] = message;
      }
    }

    final sanitizedConversations = <Conversation>[];
    final sanitizedMessages = <ChatMessage>[];
    final referencedMessageIds = <String>{};
    var danglingReferences = 0;
    var duplicateReferences = 0;
    var rehomedMessages = 0;
    var duplicateMcpServerIds = 0;
    var versionConflicts = 0;
    var dirtyFieldRepairs = 0;
    for (final conversation in conversations) {
      final mcpServerIds = <String>[];
      final seenMcpServerIds = <String>{};
      for (final serverId in conversation.mcpServerIds) {
        if (seenMcpServerIds.add(serverId)) {
          mcpServerIds.add(serverId);
        } else {
          duplicateMcpServerIds++;
        }
      }
      final keptMessageIds = <String>[];
      // SQLite 强制 unique(conversationId, groupId, version)，而
      // 1.1.17 运行时容忍重复的 (groupId, version) 对（并且
      // 上面的重新归属可能产生新的重复）；按照与 Hive 迁移相同的
      // 方式重新分配版本，使 INSERT OR REPLACE 不会吞掉行。
      final seenGroupVersions = <String>{};
      final maxGroupVersions = <String, int>{};
      final legacyGroupIds = <String?>[];
      final versionsBySelectedGroup = <String, List<ChatMessage>>{
        for (final groupId in conversation.versionSelections.keys)
          groupId: <ChatMessage>[],
      };
      final repairedVersionsByMessageId = <String, int>{};
      for (final messageId in conversation.messageIds) {
        var message = messagesById[messageId];
        if (message == null) {
          danglingReferences++;
          continue;
        }
        final groupId = message.groupId ?? message.id;
        versionsBySelectedGroup[groupId]?.add(message);
        final referenceKept = referencedMessageIds.add(messageId);
        legacyGroupIds.add(referenceKept ? groupId : null);
        if (!referenceKept) {
          duplicateReferences++;
          continue;
        }
        keptMessageIds.add(messageId);
        if (message.conversationId != conversation.id) {
          rehomedMessages++;
          message = message.copyWith(conversationId: conversation.id);
        }
        // 字段级修复（空 role、负数的 tokens/duration、超出范围的版本、
        // 顺序颠倒的推理时间戳）与 Hive 迁移共用逻辑；它必须在此处的版本冲突
        // 修复之前运行，因为压缩版本可能引入冲突，而后续修复会解决这些
        // 冲突。
        final fieldSanitized = sanitizeLegacyMessageFields(message);
        if (!identical(fieldSanitized, message)) {
          dirtyFieldRepairs++;
          message = fieldSanitized;
        }
        final explicitGroupId = message.groupId;
        if (explicitGroupId != null) {
          var version = message.version;
          if (!seenGroupVersions.add('$explicitGroupId $version')) {
            version = (maxGroupVersions[explicitGroupId] ?? version) + 1;
            versionConflicts++;
            message = message.copyWith(version: version);
            repairedVersionsByMessageId[message.id] = version;
            seenGroupVersions.add('$explicitGroupId $version');
          }
          final knownMax = maxGroupVersions[explicitGroupId];
          if (knownMax == null || version > knownMax) {
            maxGroupVersions[explicitGroupId] = version;
          }
        }
        sanitizedMessages.add(message);
      }

      var truncateIndex = conversation.truncateIndex;
      if (truncateIndex >= 0 && truncateIndex <= legacyGroupIds.length) {
        truncateIndex = legacyGroupIds
            .take(truncateIndex)
            .whereType<String>()
            .toSet()
            .length;
      }
      final versionSelections = Map<String, int>.from(
        conversation.versionSelections,
      );
      for (final entry in conversation.versionSelections.entries) {
        final versions = versionsBySelectedGroup[entry.key]!
          ..sort((left, right) => left.version.compareTo(right.version));
        if (versions.isEmpty) continue;
        final ordinal = entry.value;
        final selected = ordinal >= 0 && ordinal < versions.length
            ? versions[ordinal]
            : versions.last;
        versionSelections[entry.key] =
            repairedVersionsByMessageId[selected.id] ?? selected.version;
      }
      // 计数器钳制与 Hive 迁移共享逻辑，这样携带越界值
      // （例如负的 truncateIndex）的旧备份在恢复时
      // 就不会触发 conversation_rows 的 CHECK 约束。
      final rebuilt = conversation.copyWith(
        messageIds: keptMessageIds,
        mcpServerIds: mcpServerIds,
        truncateIndex: truncateIndex,
        versionSelections: versionSelections,
      );
      final sanitizedConversation = sanitizeLegacyConversationFields(rebuilt);
      if (!identical(sanitizedConversation, rebuilt)) {
        dirtyFieldRepairs++;
      }
      sanitizedConversations.add(sanitizedConversation);
    }
    final unreferencedMessages =
        messagesById.length - referencedMessageIds.length;

    final toolEvents = <String, List<Map<String, dynamic>>>{};
    var danglingArtifacts = 0;
    for (final entry in parsed.toolEvents.entries) {
      if (referencedMessageIds.contains(entry.key)) {
        toolEvents[entry.key] = entry.value;
      } else {
        danglingArtifacts++;
      }
    }
    final geminiThoughtSigs = <String, String>{};
    for (final entry in parsed.geminiThoughtSigs.entries) {
      if (referencedMessageIds.contains(entry.key)) {
        geminiThoughtSigs[entry.key] = entry.value;
      } else {
        danglingArtifacts++;
      }
    }
    final pruned =
        duplicateConversations +
        duplicateMessages +
        danglingReferences +
        duplicateReferences +
        rehomedMessages +
        duplicateMcpServerIds +
        versionConflicts +
        dirtyFieldRepairs +
        unreferencedMessages +
        danglingArtifacts;
    if (pruned > 0) {
      debugPrint(
        'Legacy backup sanitized: '
        'duplicateConversations=$duplicateConversations '
        'duplicateMessages=$duplicateMessages '
        'danglingReferences=$danglingReferences '
        'duplicateReferences=$duplicateReferences '
        'rehomedMessages=$rehomedMessages '
        'duplicateMcpServerIds=$duplicateMcpServerIds '
        'versionConflicts=$versionConflicts '
        'dirtyFieldRepairs=$dirtyFieldRepairs '
        'unreferencedMessages=$unreferencedMessages '
        'danglingArtifacts=$danglingArtifacts',
      );
    }
    return (
      conversations: sanitizedConversations,
      messages: sanitizedMessages,
      toolEvents: toolEvents,
      geminiThoughtSigs: geminiThoughtSigs,
    );
  }

  static void _validateBackupReferences({
    required List<Conversation> conversations,
    required List<ChatMessage> messages,
    required Map<String, List<Map<String, dynamic>>> toolEvents,
    required Map<String, String> geminiThoughtSigs,
  }) {
    final conversationIds = conversations
        .map((conversation) => conversation.id)
        .toSet();
    if (conversationIds.length != conversations.length) {
      throw StateError('conversation_ids');
    }

    final messagesByConversation = <String, List<String>>{};
    final messageIds = <String>{};
    for (final message in messages) {
      if (!conversationIds.contains(message.conversationId)) {
        throw StateError('message_conversation');
      }
      if (!messageIds.add(message.id)) {
        throw StateError('message_ids');
      }
      (messagesByConversation[message.conversationId] ??= <String>[]).add(
        message.id,
      );
    }
    for (final conversation in conversations) {
      if (conversation.mcpServerIds.toSet().length !=
          conversation.mcpServerIds.length) {
        throw StateError('conversation_mcp_server_ids');
      }
      final actualIds =
          messagesByConversation[conversation.id] ?? const <String>[];
      if (actualIds.length != conversation.messageIds.length) {
        throw StateError('conversation_message_ids');
      }
      for (var i = 0; i < actualIds.length; i++) {
        if (actualIds[i] != conversation.messageIds[i]) {
          throw StateError('conversation_message_order');
        }
      }
    }
    for (final messageId in {...toolEvents.keys, ...geminiThoughtSigs.keys}) {
      if (!messageIds.contains(messageId)) {
        throw StateError('artifact_message');
      }
    }
  }

  static Future<void> _buildAndValidateOverwriteChatCandidate({
    required String candidatePath,
    required List<Conversation> conversations,
    required List<ChatMessage> messages,
    required Map<String, List<Map<String, dynamic>>> toolEvents,
    required Map<String, String> geminiThoughtSigs,
  }) async {
    final nextOrderByConversation = <String, int>{};
    final orderedMessages = <({ChatMessage message, int messageOrder})>[];
    for (final message in messages) {
      final messageOrder = nextOrderByConversation.update(
        message.conversationId,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      orderedMessages.add((message: message, messageOrder: messageOrder));
    }

    final candidateFile = File(candidatePath);
    final repository = ChatDatabaseRepository.open(file: candidateFile);
    try {
      await repository.ensureReady();
      await repository.putMigrationBatch(
        conversations: conversations,
        messages: orderedMessages,
        toolEventsByMessageId: toolEvents,
        geminiSignaturesByMessageId: geminiThoughtSigs,
      );
      await repository.markMigrationComplete();
      await repository.validateIntegrity();
      await repository.checkpoint();
    } finally {
      await repository.close();
    }

    final reopenedRepository = ChatDatabaseRepository.open(file: candidateFile);
    try {
      await reopenedRepository.ensureReady();
      await reopenedRepository.validateIntegrity();
      final storedConversations = await reopenedRepository
          .getAllConversations();
      if (storedConversations.length != conversations.length) {
        throw StateError('conversation_count');
      }
      final storedConversationsById = {
        for (final conversation in storedConversations)
          conversation.id: conversation,
      };
      var storedMessageCount = 0;
      for (final sourceConversation in conversations) {
        final storedConversation =
            storedConversationsById[sourceConversation.id];
        if (storedConversation == null) {
          throw StateError('conversation_ids');
        }
        if (jsonEncode(storedConversation.mcpServerIds) !=
            jsonEncode(sourceConversation.mcpServerIds)) {
          throw StateError('conversation_mcp_server_ids');
        }
        final storedMessages = await reopenedRepository.getMessagesRange(
          sourceConversation.id,
          start: 0,
          limit: sourceConversation.messageIds.length,
        );
        storedMessageCount += storedMessages.length;
        if (jsonEncode(storedMessages.map((message) => message.id).toList()) !=
            jsonEncode(sourceConversation.messageIds)) {
          throw StateError('conversation_message_order');
        }
      }
      if (storedMessageCount != messages.length) {
        throw StateError('message_count');
      }
      for (final entry in toolEvents.entries) {
        final stored = await reopenedRepository.getToolEvents(entry.key);
        if (jsonEncode(stored) != jsonEncode(entry.value)) {
          throw StateError('tool_events');
        }
      }
      for (final entry in geminiThoughtSigs.entries) {
        final stored = await reopenedRepository.getGeminiThoughtSignature(
          entry.key,
        );
        if (stored != entry.value) {
          throw StateError('gemini_thought_signature');
        }
      }
      if (!await reopenedRepository.isMigrationComplete()) {
        throw StateError('migration_receipt');
      }
    } finally {
      await reopenedRepository.close();
    }
  }

  Future<({String settingsJson, Map<String, List<String>> entityRowIds})>
  _exportBusinessSettings() async {
    final exported = BusinessSettingsRouter.exportSnapshotWithRowIds(
      await businessRepository.readSnapshot(),
    );
    final settings = Map<String, Object>.from(exported.settings);
    settings.removeWhere((key, _) => BackupSettingsValidator.shouldIgnore(key));
    BackupSettingsValidator.retainCloudAsrForExport(settings);
    return (
      settingsJson: jsonEncode(settings),
      entityRowIds: exported.entityRowIds,
    );
  }

  Future<void> _restoreFromBackupFile(
    File file,
    WebDavConfig cfg, {
    RestoreMode mode = RestoreMode.overwrite,
    ProgressCallback? onProgress,
  }) async {
    _lastMergeReport = null;
    // 使用文件流解码提取到临时目录，避免将整个 ZIP 加载到
    // RAM（旧方法调用 file.readAsBytes()，对于 600-800 MB 的
    // 文件会分配同样大小的连续字节数组）。
    final tmp = await _ensureTempDir();
    final extractDir = Directory(
      p.join(tmp.path, 'restore_${DateTime.now().millisecondsSinceEpoch}'),
    );
    await extractDir.create(recursive: true);

    File? payloadFile;
    try {
      final isJoaiclient = await JoaiclientArchive.isJoaiclient(file);
      // .joaiclient 是完整快照，其恢复语义刻意独立于
      // provider 的可选旧版标志。
      final effectiveConfig = isJoaiclient
          ? cfg.copyWith(includeChats: true, includeFiles: true)
          : cfg;
      final effectiveMode = isJoaiclient ? RestoreMode.overwrite : mode;
      if (isJoaiclient) {
        payloadFile = File(p.join(extractDir.path, '_payload.zip'));
        await JoaiclientArchive.unwrapToZip(
          sourceFile: file,
          zipFile: payloadFile,
          onProgress: (update) => onProgress?.call(
            ProgressUpdate(
              value: update.fraction == null ? null : update.fraction! * 0.2,
            ),
          ),
        );
      }
      final zipSource = payloadFile ?? file;
      // 在 isolate 中运行 ZIP 解压以保持 UI 响应。
      await _extractZipWithProgress(
        zipPath: zipSource.path,
        extractDirPath: extractDir.path,
        onProgress: (processed, total) => onProgress?.call(
          ProgressUpdate(
            value: total <= 0
                ? null
                : (isJoaiclient ? 0.2 : 0) +
                      processed / total * (isJoaiclient ? 0.35 : 0.55),
          ),
        ),
      );
      onProgress?.call(ProgressUpdate(value: isJoaiclient ? 0.55 : 0.55));

      final manifestFile = File(p.join(extractDir.path, _manifestEntryName));
      final restorePayloadDirectory = extractDir;
      final settingsFile = File(p.join(extractDir.path, 'settings.json'));
      final chatsFile = File(p.join(extractDir.path, 'chats.json'));
      if (!await settingsFile.exists()) {
        throw const FormatException('settings.json');
      }
      final _VersionedBackupInfo? versionedBackup;
      if (await manifestFile.exists()) {
        final manifestPath = manifestFile.path;
        final extractDirPath = extractDir.path;
        versionedBackup = await Isolate.run(
          () => _preflightVersionedBackup(
            manifestPath: manifestPath,
            extractDirPath: extractDirPath,
          ),
        );
      } else {
        versionedBackup = null;
      }
      final settingsPath = settingsFile.path;
      final settings = await Isolate.run(
        () => _readSettingsJsonSync(settingsPath),
      );
      BackupSettingsValidator.normalizeAndValidate(settings);
      final businessRestore = BusinessRestoreService(businessRepository);
      Future<void> Function()? pendingBusinessRestore;
      if (versionedBackup != null) {
        onProgress?.call(const ProgressUpdate(value: 0.65));
        final entityRowIds = versionedBackup.businessEntityRowIds;
        final preserveExplicitEmptyInstructionList = entityRowIds == null;
        final includeChats = versionedBackup.includeChats;
        final includeFiles = versionedBackup.includeFiles;
        if (isJoaiclient && (!includeChats || !includeFiles)) {
          throw const FormatException('joaiclient_not_full_snapshot');
        }
        final restoreChats = effectiveConfig.includeChats && includeChats;
        final restoreFiles = effectiveConfig.includeFiles && includeFiles;
        if (effectiveMode == RestoreMode.merge && restoreChats) {
          // 聊天合并独立提交，因此在修改任何活跃域之前
          // 拒绝不匹配的业务载荷。
          BusinessSettingsRouter.normalizeAndRoute(
            settings,
            preserveExplicitEmptyInstructionList:
                preserveExplicitEmptyInstructionList,
            entityRowIds: entityRowIds,
          );
        }
        if (effectiveMode == RestoreMode.overwrite) {
          if (!restoreChats) {
            if (restoreFiles) {
              // 文件恢复独立于聊天恢复。这里的实时数据库保持不变，因此以
              // 追加方式复制负载（绝不删除它所引用的现有文件），最后再持久化
              // 业务数据，与旧路径保持一致。
              await _restoreAssetDirectoriesAdditive(extractDir);
            }
            await _runLiveBusinessRestore(
              () => businessRestore.overwrite(
                settings,
                preserveExplicitEmptyInstructionList:
                    preserveExplicitEmptyInstructionList,
                entityRowIds: entityRowIds,
              ),
            );
            return;
          }
          final appDataPath = (await AppDirectories.getAppDataDirectory()).path;
          final extractedPath = extractDir.path;
          final sourceManifestSha256 = versionedBackup.normalizedManifestSha256;
          await _prepareRestoreBundle(
            appDataPath: appDataPath,
            extractedPath: extractedPath,
            sourceManifestSha256: sourceManifestSha256,
            includeChats: includeChats,
            includeFiles: includeFiles,
            restoreChats: restoreChats,
            restoreFiles: restoreFiles,
          );
          onProgress?.call(const ProgressUpdate(value: 1));
          return;
        }
        if (restoreChats) {
          _lastMergeReport = await chatService.mergeDatabaseSnapshot(
            File(p.join(extractDir.path, _databaseEntryName)),
          );
          // 仅聊天恢复：在文件未恢复时，绝不让本地附件标记为可用
          // （目标路径冲突不足以证明文件已恢复）。
          if (!restoreFiles && _lastMergeReport != null) {
            await chatService.recomputeImportedAttachmentAvailability(
              conversationIds: _lastMergeReport!.importedConversationIds,
              filesRestored: false,
            );
          }
        }
        pendingBusinessRestore = () => businessRestore.merge(
          settings,
          preserveExplicitEmptyInstructionList:
              preserveExplicitEmptyInstructionList,
          entityRowIds: entityRowIds,
        );
        if (!restoreChats) {
          if (restoreFiles) {
            await _restoreAssetDirectoriesAdditive(extractDir);
          }
          await _runLiveBusinessRestore(pendingBusinessRestore);
          return;
        }
      }
      final restoreChats =
          versionedBackup == null &&
          effectiveConfig.includeChats &&
          await chatsFile.exists();

      var conversations = const <Conversation>[];
      var messages = const <ChatMessage>[];
      var toolEvents = const <String, List<Map<String, dynamic>>>{};
      var geminiThoughtSigs = const <String, String>{};
      if (effectiveMode == RestoreMode.overwrite && restoreChats) {
        await _validateOverwriteChatCandidate(
          stagingDirectory: extractDir,
          chatsFile: chatsFile,
        );
      }
      if (restoreChats) {
        final parsed = _sanitizeLegacyChatBackup(
          await _parseChatBackup(chatsFile),
        );
        conversations = parsed.conversations;
        messages = parsed.messages;
        toolEvents = parsed.toolEvents;
        geminiThoughtSigs = parsed.geminiThoughtSigs;
      }

      if (versionedBackup == null) {
        // 聊天恢复和文件恢复可以独立提交。在更改任一域之前先拒绝完整的
        // 旧业务负载，然后最后持久化业务数据，这样后续失败不会在无重启提示
        // 的情况下搁置恢复后的写入围栏。
        BusinessSettingsRouter.normalizeAndRoute(
          settings,
          preserveExplicitEmptyInstructionList: true,
          assumePreV3EmbeddingMigrationWhenVersionMissing: true,
        );
        pendingBusinessRestore = effectiveMode == RestoreMode.overwrite
            ? () => businessRestore.overwrite(
                settings,
                preserveExplicitEmptyInstructionList: true,
                assumePreV3EmbeddingMigrationWhenVersionMissing: true,
              )
            : () => businessRestore.merge(
                settings,
                preserveExplicitEmptyInstructionList: true,
                assumePreV3EmbeddingMigrationWhenVersionMissing: true,
              );
      }

      // 恢复文件
      if (effectiveConfig.includeFiles) {
        if (effectiveMode == RestoreMode.overwrite) {
          // 覆盖模式：删除现有目录并复制全部
          // 恢复上传目录
          final uploadSrc = Directory(
            p.join(restorePayloadDirectory.path, 'upload'),
          );
          if (await uploadSrc.exists()) {
            final dst = await _getUploadDir();
            if (await dst.exists()) {
              await dst.delete(recursive: true);
            }
            await dst.create(recursive: true);
            for (final ent in uploadSrc.listSync(recursive: true)) {
              if (ent is File) {
                final rel = p.relative(ent.path, from: uploadSrc.path);
                final target = File(p.join(dst.path, rel));
                await _copyRestoredFile(ent, target);
              }
            }
          }

          // 恢复 images 目录
          final imagesSrc = Directory(
            p.join(restorePayloadDirectory.path, 'images'),
          );
          if (await imagesSrc.exists()) {
            final dst = await _getImagesDir();
            if (await dst.exists()) {
              await dst.delete(recursive: true);
            }
            await dst.create(recursive: true);
            for (final ent in imagesSrc.listSync(recursive: true)) {
              if (ent is File) {
                final rel = p.relative(ent.path, from: imagesSrc.path);
                final target = File(p.join(dst.path, rel));
                await _copyRestoredFile(ent, target);
              }
            }
          }

          // 恢复 avatars 目录
          final avatarsSrc = Directory(
            p.join(restorePayloadDirectory.path, 'avatars'),
          );
          if (await avatarsSrc.exists()) {
            final dst = await _getAvatarsDir();
            if (await dst.exists()) {
              await dst.delete(recursive: true);
            }
            await dst.create(recursive: true);
            for (final ent in avatarsSrc.listSync(recursive: true)) {
              if (ent is File) {
                final rel = p.relative(ent.path, from: avatarsSrc.path);
                final target = File(p.join(dst.path, rel));
                await _copyRestoredFile(ent, target);
              }
            }
          }

          // 恢复受管理的本地 fonts 目录
          final fontsSrc = Directory(
            p.join(restorePayloadDirectory.path, 'fonts'),
          );
          if (await fontsSrc.exists()) {
            final dst = await _getFontsDir();
            if (await dst.exists()) {
              await dst.delete(recursive: true);
            }
            await dst.create(recursive: true);
            for (final ent in fontsSrc.listSync(recursive: true)) {
              if (ent is File) {
                final rel = p.relative(ent.path, from: fontsSrc.path);
                final target = File(p.join(dst.path, rel));
                await _copyRestoredFile(ent, target);
              }
            }
          }
        } else {
          // 合并模式：仅复制不存在的文件
          await _restoreAssetDirectoriesAdditive(restorePayloadDirectory);
        }
      }
      // 旧版 chats.json 在资源存在前解码。文件到位后，
      // 将旧绝对根路径定向重映射到恢复的受管相对路径，
      // 然后刷新可用性（不使用全局通用规范化回退）。
      if (restoreChats && effectiveConfig.includeFiles) {
        if (SandboxPathResolver.docsDir == null) {
          await SandboxPathResolver.init();
        }
        final refreshed = <ChatMessage>[];
        for (final message in messages) {
          final remapped = _remapRestoredAttachmentPartUris(message.parts);
          final nextParts = recomputeAttachmentAvailability(remapped);
          refreshed.add(
            identical(nextParts, message.parts)
                ? message
                : message.copyWith(parts: nextParts),
          );
        }
        messages = refreshed;
      } else if (restoreChats && !effectiveConfig.includeFiles) {
        // 仅聊天旧版导入：本地附件默认不可用。
        final refreshed = <ChatMessage>[];
        for (final message in messages) {
          final nextParts = recomputeAttachmentAvailability(
            message.parts,
            fileExists: (_) => false,
          );
          refreshed.add(
            identical(nextParts, message.parts)
                ? message
                : message.copyWith(parts: nextParts),
          );
        }
        messages = refreshed;
      }

      // 恢复聊天
      if (restoreChats) {
        try {
          if (effectiveMode == RestoreMode.overwrite) {
            await chatService.replaceAllDataFromBackup(
              conversations: conversations,
              messages: messages,
              toolEventsByMessageId: toolEvents,
              geminiSignaturesByMessageId: geminiThoughtSigs,
            );
          } else {
            // 合并模式：仅添加不存在的会话和消息
            final existingConvs = chatService.getAllCompleteConversations();
            final existingConvIds = existingConvs.map((c) => c.id).toSet();

            // 创建消息 ID 映射以避免重复（仅使用 id：
            // 完整加载消息会无谓地刷新 LRU 缓存）
            final existingMsgIds = <String>{};
            for (final conv in existingConvs) {
              existingMsgIds.addAll(await chatService.getMessageIds(conv.id));
            }

            // 按会话分组消息
            final byConv = <String, List<ChatMessage>>{};
            for (final m in messages) {
              if (!existingMsgIds.contains(m.id)) {
                (byConv[m.conversationId] ??= <ChatMessage>[]).add(m);
              }
            }

            // 恢复不存在的会话及其消息
            final mergedConvIds = <String>[];
            for (final c in conversations) {
              if (!existingConvIds.contains(c.id)) {
                final list = byConv[c.id] ?? const <ChatMessage>[];
                await chatService.restoreConversation(c, list);
                mergedConvIds.add(c.id);
              } else if (byConv.containsKey(c.id)) {
                // 会话已存在但有新消息
                final newMessages = byConv[c.id]!;
                for (final msg in newMessages) {
                  await chatService.addMessageDirectly(c.id, msg);
                }
                mergedConvIds.add(c.id);
              }
            }

            // 合并工具事件
            for (final entry in toolEvents.entries) {
              final existing = chatService.getToolEvents(entry.key);
              if (existing.isEmpty) {
                await chatService.setToolEvents(entry.key, entry.value);
              }
            }
            for (final entry in geminiThoughtSigs.entries) {
              final existingSig = chatService.getGeminiThoughtSignature(
                entry.key,
              );
              if (existingSig == null || existingSig.isEmpty) {
                await chatService.setGeminiThoughtSignature(
                  entry.key,
                  entry.value,
                );
              }
            }
            // §6.7：恢复的历史记录不得再次触发后台提取，
            // 注入哈希必须清除，以便下一次请求能够自愈。
            await businessRepository.applyPostMergeMemoryConversationState(
              mergedConvIds,
            );
          }
        } catch (_) {
          rethrow;
        }
      }

      final restoreBusiness = pendingBusinessRestore;
      if (restoreBusiness != null) {
        await _runLiveBusinessRestore(restoreBusiness);
      }
    } finally {
      await _deleteDirectoryQuietly(extractDir);
    }
  }
}

class _ExtractionBudget {
  _ExtractionBudget({required this.maxTotalBytes});

  final int maxTotalBytes;
  int _writtenBytes = 0;

  void reserve(int bytes) {
    if (bytes < 0 || _writtenBytes + bytes > maxTotalBytes) {
      throw const FormatException('zip_total_size');
    }
    _writtenBytes += bytes;
  }
}

class _BoundedOutputFileStream extends OutputFileStream {
  _BoundedOutputFileStream(
    String path, {
    required this.expectedBytes,
    required this.maxEntryBytes,
    required this.budget,
    this.onWrite,
  }) : super.withFileHandle(FileHandle(path, mode: FileAccess.write));

  final int expectedBytes;
  final int maxEntryBytes;
  final _ExtractionBudget budget;
  final void Function(int bytes)? onWrite;
  int _entryBytes = 0;

  void _reserve(int bytes) {
    if (bytes < 0 ||
        _entryBytes + bytes > expectedBytes ||
        _entryBytes + bytes > maxEntryBytes) {
      throw const FormatException('zip_entry_size');
    }
    budget.reserve(bytes);
    _entryBytes += bytes;
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final writeLength = length ?? bytes.length;
    if (writeLength < 0 || writeLength > bytes.length) {
      throw RangeError.range(writeLength, 0, bytes.length, 'length');
    }
    _reserve(writeLength);
    super.writeBytes(bytes, length: writeLength);
    onWrite?.call(writeLength);
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final readSize = stream.length < chunkSize ? stream.length : chunkSize;
      final bytes = stream.readBytes(readSize).toUint8List();
      if (bytes.isEmpty) break;
      writeBytes(bytes);
    }
  }

  void verifyComplete() {
    if (_entryBytes != expectedBytes) {
      throw const FormatException('zip_entry_size');
    }
  }
}

class _StreamingZipWriter {
  _StreamingZipWriter(String outPath) : _output = OutputFileStream(outPath);

  static const int _localFileHeaderSignature = 0x04034b50;
  static const int _centralDirectoryHeaderSignature = 0x02014b50;
  static const int _endOfCentralDirectorySignature = 0x06054b50;
  static const int _zip64EndOfCentralDirectorySignature = 0x06064b50;
  static const int _zip64EndOfCentralDirectoryLocatorSignature = 0x07064b50;
  static const int _dataDescriptorSignature = 0x08074b50;
  static const int _versionNeeded = 45;
  static const int _utf8Flag = 1 << 11;
  static const int _dataDescriptorFlag = 1 << 3;
  static const int _deflateMethod = 8;
  static const int _maxZip32 = 0xffffffff;
  static const int _chunkSize = 1024 * 1024;

  final OutputFileStream _output;
  final List<_StreamingZipEntry> _entries = <_StreamingZipEntry>[];
  bool _closed = false;

  _BackupEntryMetadata addFile(File file, String entryName) {
    if (_closed) {
      throw StateError('Cannot add files after the ZIP writer is closed.');
    }
    if (entryName.isEmpty) {
      throw ArgumentError.value(entryName, 'entryName', 'must not be empty');
    }

    final stat = file.statSync();
    final uncompressedSize = stat.size;
    // Deflate 可能会让不可压缩的输入略微变大，所以在 32 位边界之前
    // 预留 ZIP64，而不是等流式写入后才发现溢出。
    final usesZip64Entry = uncompressedSize > _maxZip32 - (16 * 1024 * 1024);

    final modified = stat.modified;
    final modTime = _zipTime(modified);
    final modDate = _zipDate(modified);
    final nameBytes = utf8.encode(entryName);
    if (nameBytes.length > 0xffff) {
      throw FileSystemException('ZIP entry name exceeds ZIP32 limit');
    }
    final localHeaderOffset = _output.length;

    _writeLocalHeader(
      nameBytes: nameBytes,
      modTime: modTime,
      modDate: modDate,
      usesZip64: usesZip64Entry,
    );

    final written = _writeDeflatedFile(file);
    _writeDataDescriptor(written, usesZip64: usesZip64Entry);

    _entries.add(
      _StreamingZipEntry(
        nameBytes: nameBytes,
        modTime: modTime,
        modDate: modDate,
        crc32: written.crc32,
        compressedSize: written.compressedSize,
        uncompressedSize: written.uncompressedSize,
        localHeaderOffset: localHeaderOffset,
        mode: stat.mode,
      ),
    );
    return (bytes: written.uncompressedSize, sha256: written.sha256);
  }

  void closeSync() {
    if (_closed) return;
    final centralDirectoryOffset = _output.length;
    for (final entry in _entries) {
      _writeCentralDirectoryHeader(entry);
    }
    final centralDirectorySize = _output.length - centralDirectoryOffset;
    _writeEndOfCentralDirectory(
      centralDirectoryOffset: centralDirectoryOffset,
      centralDirectorySize: centralDirectorySize,
    );
    _output.closeSync();
    _closed = true;
  }

  void closeIfNeededSync() {
    if (!_closed) {
      _output.closeSync();
      _closed = true;
    }
  }

  void _writeLocalHeader({
    required List<int> nameBytes,
    required int modTime,
    required int modDate,
    required bool usesZip64,
  }) {
    _output.writeUint32(_localFileHeaderSignature);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_utf8Flag | _dataDescriptorFlag);
    _output.writeUint16(_deflateMethod);
    _output.writeUint16(modTime);
    _output.writeUint16(modDate);
    _output.writeUint32(0);
    _output.writeUint32(usesZip64 ? _maxZip32 : 0);
    _output.writeUint32(usesZip64 ? _maxZip32 : 0);
    _output.writeUint16(nameBytes.length);
    _output.writeUint16(usesZip64 ? 20 : 0);
    _output.writeBytes(nameBytes);
    if (usesZip64) {
      _output.writeUint16(0x0001);
      _output.writeUint16(16);
      // 大小由 ZIP64 数据描述符和中央目录最终确定。
      _output.writeUint64(0);
      _output.writeUint64(0);
    }
  }

  _StreamingZipWrittenFile _writeDeflatedFile(File file) {
    final compressedSink = _CountingOutputSink(_output);
    final inputSink = ZLibCodec(
      level: ZLibOption.defaultLevel,
      raw: true,
    ).encoder.startChunkedConversion(compressedSink);
    final digestSink = _DigestOutputSink();
    final hashSink = sha256.startChunkedConversion(digestSink);

    final raf = file.openSync();
    final buffer = Uint8List(_chunkSize);
    var crc32 = 0;
    var uncompressedSize = 0;
    try {
      while (true) {
        final read = raf.readIntoSync(buffer);
        if (read == 0) break;
        final chunk = Uint8List.sublistView(buffer, 0, read);
        crc32 = getCrc32(chunk, crc32);
        uncompressedSize += read;
        hashSink.add(chunk);
        inputSink.add(chunk);
      }
      hashSink.close();
      inputSink.close();
    } finally {
      raf.closeSync();
    }

    return _StreamingZipWrittenFile(
      crc32: crc32,
      compressedSize: compressedSink.bytesWritten,
      uncompressedSize: uncompressedSize,
      sha256: digestSink.digest?.toString() ?? (throw StateError('sha256')),
    );
  }

  void _writeDataDescriptor(
    _StreamingZipWrittenFile written, {
    required bool usesZip64,
  }) {
    _output.writeUint32(_dataDescriptorSignature);
    _output.writeUint32(written.crc32);
    if (usesZip64) {
      _output.writeUint64(written.compressedSize);
      _output.writeUint64(written.uncompressedSize);
    } else {
      _output.writeUint32(written.compressedSize);
      _output.writeUint32(written.uncompressedSize);
    }
  }

  void _writeCentralDirectoryHeader(_StreamingZipEntry entry) {
    final usesZip64 =
        entry.compressedSize > _maxZip32 ||
        entry.uncompressedSize > _maxZip32 ||
        entry.localHeaderOffset > _maxZip32;
    _output.writeUint32(_centralDirectoryHeaderSignature);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_utf8Flag | _dataDescriptorFlag);
    _output.writeUint16(_deflateMethod);
    _output.writeUint16(entry.modTime);
    _output.writeUint16(entry.modDate);
    _output.writeUint32(entry.crc32);
    _output.writeUint32(usesZip64 ? _maxZip32 : entry.compressedSize);
    _output.writeUint32(usesZip64 ? _maxZip32 : entry.uncompressedSize);
    _output.writeUint16(entry.nameBytes.length);
    _output.writeUint16(usesZip64 ? 28 : 0);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint32(entry.mode << 16);
    _output.writeUint32(usesZip64 ? _maxZip32 : entry.localHeaderOffset);
    _output.writeBytes(entry.nameBytes);
    if (usesZip64) {
      _output.writeUint16(0x0001);
      _output.writeUint16(24);
      _output.writeUint64(entry.uncompressedSize);
      _output.writeUint64(entry.compressedSize);
      _output.writeUint64(entry.localHeaderOffset);
    }
  }

  void _writeEndOfCentralDirectory({
    required int centralDirectoryOffset,
    required int centralDirectorySize,
  }) {
    final zip64EocdOffset = _output.length;
    _output.writeUint32(_zip64EndOfCentralDirectorySignature);
    _output.writeUint64(44);
    _output.writeUint16(_versionNeeded);
    _output.writeUint16(_versionNeeded);
    _output.writeUint32(0);
    _output.writeUint32(0);
    _output.writeUint64(_entries.length);
    _output.writeUint64(_entries.length);
    _output.writeUint64(centralDirectorySize);
    _output.writeUint64(centralDirectoryOffset);

    _output.writeUint32(_zip64EndOfCentralDirectoryLocatorSignature);
    _output.writeUint32(0);
    _output.writeUint64(zip64EocdOffset);
    _output.writeUint32(1);

    _output.writeUint32(_endOfCentralDirectorySignature);
    _output.writeUint16(0);
    _output.writeUint16(0xffff);
    _output.writeUint16(0xffff);
    _output.writeUint16(0xffff);
    _output.writeUint32(_maxZip32);
    _output.writeUint32(_maxZip32);
    _output.writeUint16(0);
  }

  static int _zipTime(DateTime value) {
    return ((value.hour & 0x1f) << 11) |
        ((value.minute & 0x3f) << 5) |
        ((value.second ~/ 2) & 0x1f);
  }

  static int _zipDate(DateTime value) {
    final year = value.year < 1980 ? 1980 : value.year;
    return (((year - 1980) & 0x7f) << 9) |
        ((value.month & 0x0f) << 5) |
        (value.day & 0x1f);
  }
}

class _CountingOutputSink implements Sink<List<int>> {
  _CountingOutputSink(this._output);

  final OutputFileStream _output;
  int bytesWritten = 0;

  @override
  void add(List<int> data) {
    if (data.isEmpty) return;
    _output.writeBytes(data);
    bytesWritten += data.length;
  }

  @override
  void close() {}
}

class _DigestOutputSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    if (digest != null) {
      throw StateError('Digest sink received more than one value');
    }
    digest = data;
  }

  @override
  void close() {}
}

class _StreamingZipEntry {
  const _StreamingZipEntry({
    required this.nameBytes,
    required this.modTime,
    required this.modDate,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.mode,
  });

  final List<int> nameBytes;
  final int modTime;
  final int modDate;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final int mode;
}

class _StreamingZipWrittenFile {
  const _StreamingZipWrittenFile({
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.sha256,
  });

  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final String sha256;
}
