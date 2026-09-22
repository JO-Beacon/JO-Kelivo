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
import '../../database/schema_migrations.dart';
import '../../models/backup.dart';
import '../../models/chat_message.dart';
import '../../models/message_part.dart';
import '../../models/conversation.dart';
import '../../models/progress_update.dart';
import '../chat/chat_service.dart';
import '../device/device_identity.dart';
import '../migration/migration_backup_file_name.dart';
import '../migration/legacy_message_content_decoder.dart';
import '../migration/legacy_record_sanitizer.dart';
import '../../utils/multimodal_input_utils.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../database/backup_portability.dart';
import 'backup_settings_validator.dart';
import 'device_local_settings_writer.dart';
import 'joaiclient_archive.dart';
import 'local_device_settings_ledger.dart';
import 'restore_bundle_preparation.dart';
import 'restore_workspace_lock.dart';
import 'restore_business_lease.dart';
import 'temporary_restore_file.dart';
import 'backup_cancel_token.dart';
import 'backup_isolate_runner.dart';
import 'backup_task_progress.dart';

typedef _ParsedChatBackup = ({
  List<Conversation> conversations,
  List<ChatMessage> messages,
  Map<String, List<Map<String, dynamic>>> toolEvents,
  Map<String, String> geminiThoughtSigs,
});

typedef _BackupEntryMetadata = ({int bytes, String sha256});

/// 打包好的归档，外加打包过程中得到的统计信息。
typedef PreparedBackupArchive = ({
  File file,
  ChatDatabaseSnapshotInfo? info,
  String appVersion,
});

/// 恢复某个备份文件对本构建意味着什么，仅依据该文件的
/// 清单判定。
///
/// 本地文件会先经 [DataSync.inspectBackupCompatibility] 检查，
/// 因此在恢复开始之前就能问到用户。远程备份只有在
/// 下载完之后才存在于磁盘上，所以那几条路径改为通过
/// [ForwardCompatibilityPrompt] 询问。
typedef BackupCompatibility = ({
  int schemaVersion,
  BackupSchemaVerdict verdict,
});

/// 调用方对 [ForwardCompatibilityPrompt] 的回答。
enum ForwardCompatibilityAnswer {
  /// 正常恢复。
  proceed,

  /// 备份比本构建更新，且没有做出兼容性承诺，
  /// 但用户仍然接受风险继续。
  proceedUnverified,

  /// 不恢复。调用方负责向用户说明原因。
  refuse,
}

/// 在备份已经落到磁盘、尚未读取任何内容之前询问一次。
///
/// 专为 WebDAV 与 S3 恢复而设，因为那两条路径在下载之前
/// 无法检查归档。它运行在调用方的 isolate 上，因此可以显示界面。
typedef ForwardCompatibilityPrompt =
    Future<ForwardCompatibilityAnswer> Function(BackupCompatibility);

typedef _VersionedBackupInfo = ({
  bool includeChats,
  bool includeFiles,
  bool secretsIncluded,
  Map<String, Object?>? businessEntityRowIds,
  String normalizedManifestSha256,
});

/// 依据实时文件系统重新计算 [ImagePart]／[FilePart.unavailable]。
///
/// 远程与 data URI 保持可用。本地 URI 使用
/// [SandboxPathResolver.localFileExists]（仅做结构化重映射，不做通用的
/// images／upload 同名探测）。
/// 用于文件恢复之后，刷新那些在资源复制之前就已解码的旧版
/// chats.json 导入。

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
  // 不要用 fix()：它那套通用的 `/images/`·同名探测会把一个已经缺失的
  // 外部路径标成可用，只要存在同名受管文件。
  return SandboxPathResolver.localFileExists(path);
}

/// 提供备份归档中携带的业务设置。
typedef _BackupSettingsSource =
    Future<({String settingsJson, Map<String, List<String>> entityRowIds})>
    Function();

/// 把正在备份的数据库一致性副本写入 [destination]。
typedef _BackupDatabaseSource =
    Future<ChatDatabaseSnapshotInfo> Function(File destination);

/// 把带单位的 [BackupProgressSink] 适配成本仓库老管线的 [ProgressCallback]。
///
/// 两套进度类型暂时并存：导入器与备份流水线仍上报 [ProgressUpdate]（只有一个
/// 0..1 的比值），而新的本地副本界面用的是上游的 [BackupProgress]（带单位、
/// 可取消标记与明细）。这里把比值放大成千分比交给进度条，阶段字段原样透传，
/// 所以阶段图标与文案都是真的。明细副标题只在 [BackupProgress.total] 非空时
/// 才显示，因此不填明细不会出现编造的文案。
ProgressCallback? adaptBackupProgressSink(BackupProgressSink? sink) {
  if (sink == null) return null;
  return (update) {
    final value = update.value;
    // 直接带 processed／total 的上报优先原样透传（真实字节数），
    // 只有老式比值型上报才按 0..1000 折算，避免丢掉真实总量。
    final hasCounts = update.processed != null && update.total != null;
    sink(
      BackupProgress(
        phase: update.phase ?? BackupPhase.preparing,
        processed: hasCounts
            ? update.processed!
            : (value == null ? 0 : (value.clamp(0, 1) * 1000).round()),
        total: hasCounts ? update.total : (value == null ? null : 1000),
        unit: hasCounts ? BackupProgressUnit.bytes : BackupProgressUnit.none,
      ),
    );
  };
}

class DataSync {
  static const _backupFormat = 'kelivo-backup';
  static const _backupFormatVersion = 2;

  /// 清单键：声明还能读取本构建所写备份的最旧归档格式。
  ///
  static const backupMinimumReadableFormatKey = 'minimumReadableFormatVersion';

  /// 这是 [SchemaMigrations.minimumReadableSchemaVersion]
  /// 在归档格式维度上的对应物。
  ///
  /// [_backupFormatVersion] 管归档 —— 条目名与清单字段；
  /// 数据库 schema 管 SQLite 载荷；两者各自演进，
  /// 因此一个构建可以只新增一个可忽略的目录而不动 schema，
  /// 反之亦然。
  ///
  /// 只要归档的改动**不是纯新增**，就要与 [_backupFormatVersion] 同步抬高此值：
  /// 重命名或改用途的条目、清单字段，以及其他会被旧构建**误读**
  ///（而不只是认不出来）的东西。纯新增时保持原值不动，
  /// 正是这样才能让明天的备份仍能恢复到今天的构建里。
  ///
  static const _minimumReadableFormatVersion = 2;
  static const _manifestEntryName = 'manifest.json';
  static const _databaseEntryName = 'database/kelivo.db';

  /// 本机设置册子在备份包内的目录前缀。每台设备一个独立 JSON 文件。
  static const ledgerEntryPrefix = 'device_local_settings/';

  /// `includeFiles` 为真时会复制的文件根目录声明。
  ///
  /// 在此新增名字属纯新增：更旧的包因为本来就没有该目录，
  /// 仍可恢复。暂存阶段会把空根目录实体化，与当前包里的空 `upload/`
  /// 保持一致。`environment/` 是刻意不列入的 —— Linux rootfs 有数百 MB，
  /// 并不是备份数据。
  ///
  static const _assetRootNames = [
    'upload',
    'images',
    'avatars',
    'fonts',
    'skills',
    'workspaces',
    'sessions',
  ];
  // 16 MiB 的元数据上限让清单解析与条目元数据都有界。
  static const _maxManifestBytes = 16 * 1024 * 1024;
  // 设置按单个 JSON 对象解析，因此其解码输入必须有界。
  static const _maxSettingsBytes = 1024 * 1024 * 1024;
  // ZIP64 支持更大的条目；恢复侧保留显式且可诊断的上限。
  static const _maxRestoreEntryBytes = 8 * 1024 * 1024 * 1024;
  static const _maxRestoreTotalBytes = 16 * 1024 * 1024 * 1024;
  static const _maxRestoreEntries = 100000;

  /// 恢复开始前中断全部进行中的生成。
  ///
  /// 恢复要么就地改写聊天库与设置，要么在收尾冷重启时替换整个数据库
  /// 文件，都不能与流式检查点的写入并发。本服务位于 core 层，取不到
  /// 界面层的取消能力，因此由界面层（ChatActions）在构造时注入。
  /// 为 null 表示尚未注入，恢复流程照常进行。
  static Future<void> Function()? onBeforeRestore;

  final ChatService chatService;
  final BusinessRepository businessRepository;
  final BusinessPreferences? businessPreferences;
  BackupMergeReport? _lastMergeReport;
  BackupMergeReport? get lastMergeReport => _lastMergeReport;

  /// 本次恢复吸收进册子的设备记录数（0 表示包内没有册子或全部损坏）。
  int _lastLedgerAbsorbed = 0;
  int get lastLedgerAbsorbed => _lastLedgerAbsorbed;

  /// 本次恢复从包内解析出的设备记录（含所有设备，不只本机）。
  ///
  /// 供恢复收尾弹窗展示“本机设置记录”区块——恢复流程结束时解包目录会被
  /// 删除，所以必须在流程内就留一把，不能等界面再去读包。
  List<DeviceSettingsRecord> _lastLedgerRecords = const [];
  List<DeviceSettingsRecord> get lastLedgerRecords => _lastLedgerRecords;

  /// 本次恢复真正写回本机的设置键数。
  ///
  /// 完全覆盖模式下写在冷重启后的启动门里，因此该值在本进程内通常为 0；
  /// 合并保留模式是就地写回，这里会如实反映写入的键数。收尾提示
  /// 只在“确实写入了键”时才弹（用户 2026-09-10 拍板）。
  int _lastLocalSettingsApplied = 0;
  int get lastLocalSettingsApplied => _lastLocalSettingsApplied;

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
    Map<String, dynamic>? validatedSettings,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) => RestoreBundlePreparation.prepare(
    appDataDirectory: Directory(appDataPath),
    extractedDirectory: Directory(extractedPath),
    sourceManifestSha256: sourceManifestSha256,
    bundleIncludesChats: includeChats,
    bundleIncludesFiles: includeFiles,
    restoreChats: restoreChats,
    restoreFiles: restoreFiles,
    validatedSettings: validatedSettings,
    onProgress: onProgress,
    cancelToken: cancelToken,
  );

  /// 在不打开实时数据库与各提供方的情况下准备一份本地快照。
  /// 常规启动门禁会在重启时安装持久候选，同时保留原有数据
  /// 以便回滚。源归档在任何情况下都不会被修改。
  /// 在尚未打开业务数据库的启动恢复阶段，将一个完整备份暂存为恢复工作区。
  ///
  /// 该入口只做文件解包、清单校验和候选工作区发布；业务设置会写进候选
  /// 数据库，真正切换由启动闸门完成。因此调用方不需要构造 ChatService
  /// 或 BusinessRepository。
  ///
  /// 与上游的差别：本仓库的备份是 `.joaiclient` 容器（zip 外面还包了一层
  /// 头部），所以解包前先拆出内层 zip；返回值也保留成
  /// [PreparedRestoreBundle]，供调用方断言与收尾使用。
  static Future<PreparedRestoreBundle> prepareStartupSnapshotRestore({
    required Directory appDataDirectory,
    required File snapshot,
    RestoreBusinessLease? businessLease,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    final ownedLease = businessLease == null
        ? await RestoreBusinessLease.acquire(appDataDirectory: appDataDirectory)
        : null;
    final lease = businessLease ?? ownedLease!;
    Directory? extractDir;
    Object? restoreError;
    try {
      final expectedLeasePath = p.join(
        appDataDirectory.absolute.path,
        RestoreBusinessLease.leaseDirectoryName,
        RestoreBusinessLease.lockFileName,
      );
      if (lease.isClosed ||
          !p.equals(lease.lockFile.absolute.path, expectedLeasePath)) {
        throw StateError('restore_startup_business_lease');
      }
      if (!await snapshot.exists()) {
        throw const FormatException('startup_recovery_snapshot_missing');
      }
      extractDir = await Directory.systemTemp.createTemp(
        'joaiclient-startup-restore-',
      );
      registerLiveTempPath(extractDir.path);
      // 本仓库的备份是 .joaiclient 容器。判断只看文件头、不认扩展名，
      // 所以改过名字的包也能正确还原。
      File? payloadFile;
      if (await JoaiclientArchive.isJoaiclient(snapshot)) {
        payloadFile = File(p.join(extractDir.parent.path, 'payload.zip'));
        registerLiveTempPath(payloadFile.path);
        await JoaiclientArchive.unwrapToZip(
          sourceFile: snapshot,
          zipFile: payloadFile,
          cancelToken: cancelToken,
        );
      }
      final zipSource = payloadFile ?? snapshot;
      await runBackupIsolate<void, _BackupExtractArgs>(
        body: _extractZipInIsolate,
        payload: _BackupExtractArgs(
          zipPath: zipSource.path,
          extractDirPath: extractDir.path,
        ),
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      final info =
          await runBackupIsolate<_VersionedBackupInfo, _BackupPreflightArgs>(
            body: _preflightVersionedBackupInIsolate,
            payload: _BackupPreflightArgs(
              manifestPath: p.join(extractDir.path, _manifestEntryName),
              extractDirPath: extractDir.path,
              allowUnverifiedForwardCompatible: false,
            ),
            cancelToken: cancelToken,
            onProgress: onProgress,
          );
      if (!info.includeChats) {
        throw const FormatException('restore_preparation_database_required');
      }
      final settings = await runBackupIsolate<Map<String, dynamic>, String>(
        body: _readSettingsJsonInIsolate,
        payload: p.join(extractDir.path, 'settings.json'),
        onProgress: onProgress,
      );
      BackupSettingsValidator.normalizeAndValidate(settings);
      final workspaceLock = RestoreWorkspaceLock(
        appDataDirectory: appDataDirectory,
      );
      await workspaceLock.synchronized(
        workspaceLock.beginSnapshotRecoveryWhileLocked,
      );
      final prepared = await RestoreBundlePreparation.prepare(
        appDataDirectory: appDataDirectory,
        extractedDirectory: extractDir,
        sourceManifestSha256: info.normalizedManifestSha256,
        bundleIncludesChats: info.includeChats,
        bundleIncludesFiles: info.includeFiles,
        restoreChats: true,
        restoreFiles: false,
        useExistingLocalAttachments: true,
        validatedSettings: settings,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      await workspaceLock.synchronized(
        workspaceLock.finishSnapshotRecoveryWhileLocked,
      );
      return prepared;
    } catch (error) {
      restoreError = error;
      rethrow;
    } finally {
      try {
        if (extractDir != null) {
          await deleteTempDirectoryWhenIsolateSafe(
            extractDir,
            error: restoreError,
          );
        }
      } finally {
        await ownedLease?.close();
      }
    }
  }

  // ===== WebDAV 辅助函数 =====
  Uri _collectionUri(WebDavConfig cfg) {
    String base = cfg.url.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    String pathPart = cfg.path.trim();
    if (pathPart.isNotEmpty) {
      pathPart = '/${pathPart.replaceAll(RegExp(r'^/+'), '')}';
    }
    // 确保集合路径以斜杠结尾
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

  Future<void> _ensureCollection(
    WebDavConfig cfg, {
    BackupCancelToken? cancelToken,
  }) async {
    final client = http.Client();
    StreamSubscription<void>? cancelSub;
    try {
      cancelSub = cancelToken?.whenCancelled.asStream().listen((_) {
        client.close();
      });
      if (cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      // 确保每一级路径都存在
      final url = cfg.url.trim().replaceAll(RegExp(r'/+$'), '');
      final segments = cfg.path
          .split('/')
          .where((s) => s.trim().isNotEmpty)
          .toList();
      String acc = url;
      for (final seg in segments) {
        acc = '$acc/$seg';
        // 对该集合做深度 0 的 PROPFIND（带尾斜杠）
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
          // 创建这一层
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
          // 有些服务器返回 207 Multi-Status；2xx／3xx／207 都接受
          if (res.statusCode != 207) {
            throw Exception('PROPFIND error at $u: ${res.statusCode}');
          }
        }
        if (cancelToken?.isCancelled == true) {
          throw const BackupCancelledException();
        }
      }
    } catch (error) {
      if (error is BackupCancelledException ||
          cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      rethrow;
    } finally {
      await cancelSub?.cancel();
      client.close();
    }
  }

  // ===== 公开 API =====
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

  Future<File> prepareBackupFile(
    WebDavConfig cfg, {
    Map<String, String>? ledgerEntries,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async => (await _prepareBackupArchive(
    includeChats: cfg.includeChats,
    includeFiles: cfg.includeFiles,
    exportSettings: _exportBusinessSettings,
    snapshotDatabase: (destination) => chatService.createBackupDatabaseSnapshot(
      destination,
      onProgress: onProgress,
      cancelToken: cancelToken,
    ),
    ledgerEntries: ledgerEntries,
    onProgress: onProgress,
    cancelToken: cancelToken,
  )).file;

  /// 创建本地、WebDAV 和 S3 使用的隐式外部归档备份文件。
  /// [prepareBackupFile] 仍作为旧内部文件和旧测试数据的 ZIP 生产者；
  /// 新导出文件从不暴露 ZIP 文件边界之外的入口名称。
  ///
  /// 进度回调沿用旧的比值型（[ProgressCallback]），内部适配成 core 层
  /// 统一使用的 [BackupProgressSink]。
  Future<File> prepareJoaiclientFile(
    WebDavConfig cfg, {
    ProgressCallback? onProgress,
    BackupCancelToken? cancelToken,
    Map<String, String>? ledgerEntries,
  }) async {
    final zipFile = await prepareBackupFile(
      cfg.copyWith(includeChats: true, includeFiles: true),
      onProgress: adaptProgressCallbackToSink(onProgress),
      cancelToken: cancelToken,
      ledgerEntries: ledgerEntries,
    );
    cancelToken?.throwIfCancelled();
    final zipLength = await zipFile.length();
    onProgress?.call(
      ProgressUpdate(
        phase: BackupPhase.wrapping,
        processed: 0,
        total: zipLength > 0 ? zipLength : null,
      ),
    );
    final zipBaseName = p.basenameWithoutExtension(zipFile.path);
    const kelivoBackupPrefix = 'kelivo_backup_';
    final timestampPart = zipBaseName.startsWith(kelivoBackupPrefix)
        ? zipBaseName.substring(kelivoBackupPrefix.length)
        : zipBaseName;
    final outputFile = File(
      p.join(
        zipFile.parent.path,
        'joaiclient_backup_$timestampPart.joaiclient',
      ),
    );
    final stagingFile = File('${outputFile.path}.part');
    try {
      await JoaiclientArchive.wrapZipPayload(
        zipFile: zipFile,
        outputFile: stagingFile,
        onProgress: (update) => onProgress?.call(
          ProgressUpdate(
            phase: BackupPhase.wrapping,
            processed: update.processed,
            total: update.total,
          ),
        ),
        cancelToken: cancelToken,
      );
      // 只有完整头部与载荷都关闭之后才发布。这能避免并发扫描或清理逻辑
      // 在文件系统可见性有延迟的平台上看到半个 .joaiclient 文件。
      if (await outputFile.exists()) await outputFile.delete();
      await stagingFile.rename(outputFile.path);
      await zipFile.delete();
      onProgress?.call(const ProgressUpdate(value: 1));
      return outputFile;
    } catch (_) {
      await _deleteFileQuietly(stagingFile);
      await _deleteFileQuietly(outputFile);
      rethrow;
    }
  }

  /// 使用相同的 payload writer 打包迁移快照。
  ///
  /// 这是 0.1.8+8 起的导出路径。调用方提供快照数据库和已导出的业务设置，
  /// 因为迁移在实时会话服务和当前 schema 数据库接收之前运行。
  ///
  /// 资源目录与普通备份一致：按 [appDataDirectory] 下的 7 个同名子目录解析
  /// （迁移前 skills／workspaces／sessions 通常不存在，此时按空目录处理）。
  static Future<File> prepareMigrationBackupFile({
    required Directory outputDirectory,
    required File snapshotDatabase,
    required ChatDatabaseSnapshotInfo snapshotInfo,
    required String settingsJson,
    required Map<String, List<String>> businessEntityRowIds,
    required Directory appDataDirectory,
  }) async {
    await outputDirectory.create(recursive: true);
    final workDir = await Directory.systemTemp.createTemp(
      'kelivo_migration_backup_',
    );
    registerLiveTempPath(workDir.path);
    Object? migrationError;
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
      final assetRootPaths = {
        for (final name in _assetRootNames)
          name: p.join(appDataDirectory.path, name),
      };
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
          assetRootPaths: assetRootPaths,
        );
      });
      return outFile;
    } catch (error) {
      if (await outFile.exists()) await outFile.delete();
      migrationError = error;
      rethrow;
    } finally {
      await deleteTempDirectoryWhenIsolateSafe(workDir, error: migrationError);
    }
  }

  /// 为本地副本库打包实时数据库。
  ///
  /// 与普通备份相同的归档，只是不含资源文件；它会把打包器已经算出的
  /// 行数回传，好让保留策略不必重新打开就能判断每份副本
  /// 持有多少数据。
  Future<PreparedBackupArchive> prepareLocalSnapshotArchive({
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) => _prepareBackupArchive(
    includeChats: true,
    includeFiles: false,
    exportSettings: _exportBusinessSettings,
    snapshotDatabase: (destination) => chatService.createBackupDatabaseSnapshot(
      destination,
      onProgress: onProgress,
      cancelToken: cancelToken,
    ),
    onProgress: onProgress,
    cancelToken: cancelToken,
  );

  /// 用调用方给定的数据库与设置打包一份备份归档。
  ///
  ///
  /// 从 [prepareBackupFile] 中拆出，使非实时数据库 —— 例如崩溃恢复
  /// 搁置下来的副本 —— 也能变成普通备份，
  /// 而不必为它单独准备一条恢复路径。
  Future<PreparedBackupArchive> _prepareBackupArchive({
    required bool includeChats,
    required bool includeFiles,
    required _BackupSettingsSource exportSettings,
    required _BackupDatabaseSource snapshotDatabase,
    Map<String, String>? ledgerEntries,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    final tmp = await _ensureTempDir();
    await _cleanupPreviousBackupTempFiles(tmp);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final workDir = Directory(p.join(tmp.path, 'kelivo_backup_$timestamp'));
    await workDir.create(recursive: true);
    registerLiveTempPath(workDir.path);

    final outPath = p.join(workDir.path, 'kelivo_backup_$timestamp.zip');
    final outFile = File(outPath);
    if (await outFile.exists()) await outFile.delete();

    File? manifestTmp;
    File? settingsTmp;
    File? databaseTmp;
    var abandonWorkDir = false;
    try {
      onProgress?.call(
        const BackupProgress(
          phase: BackupPhase.preparing,
          processed: 0,
          cancellable: true,
        ),
      );
      if (cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      // --- 第 1 步：准备需要主 isolate 的临时文件 ---
      // settings.json
      final businessExport = await exportSettings();
      final settingsFile = await _writeTempText(
        workDir,
        '_bk_settings.json',
        businessExport.settingsJson,
      );
      settingsTmp = settingsFile;

      ChatDatabaseSnapshotInfo? snapshotInfo;
      if (includeChats) {
        final databaseFile = File(p.join(workDir.path, '_bk_kelivo.db'));
        databaseTmp = databaseFile;
        onProgress?.call(
          const BackupProgress(
            phase: BackupPhase.snapshottingDatabase,
            processed: 0,
            cancellable: true,
          ),
        );
        snapshotInfo = await snapshotDatabase(databaseFile);
        await _sanitizeBackupDatabase(databaseFile);
      }

      final packageInfo = await PackageInfo.fromPlatform();
      final appVersion = packageInfo.buildNumber.trim().isEmpty
          ? packageInfo.version
          : '${packageInfo.version}+${packageInfo.buildNumber}';
      final manifestFile = File(p.join(workDir.path, '_bk_manifest.json'));
      manifestTmp = manifestFile;

      // 本机设置册子（“带”档）：把每台设备的记录逐台写成独立文件。
      // 放在 workDir 下的临时目录里，随 workDir 一起在 finally 清掉。
      String? ledgerDirectoryPath;
      if (ledgerEntries != null && ledgerEntries.isNotEmpty) {
        final ledgerDir = Directory(p.join(workDir.path, '_bk_ledger'));
        await ledgerDir.create(recursive: true);
        var written = 0;
        for (final entry in ledgerEntries.entries) {
          // entry.key 形如 device_local_settings/<指纹>.json；
          // 写入时只取文件名，目录部分由 _addDirectoryToZip 的 zipPrefix 承担。
          final fileName = p.basename(entry.key);
          if (fileName.isEmpty || fileName == '.' || fileName == '..') {
            continue;
          }
          await File(
            p.join(ledgerDir.path, fileName),
          ).writeAsString(entry.value, flush: true);
          written++;
        }
        if (written > 0) ledgerDirectoryPath = ledgerDir.path;
      }

      // 解析目录路径（需要主 isolate 上的 AppDirectories）。
      // 拼接应用数据根目录，而不是用会顺带创建的辅助函数，
      // 免得备份动作把空的实时根目录也 mkdir 出来。
      final appData = await AppDirectories.getAppDataDirectory();
      final assetRootPaths = {
        for (final name in _assetRootNames) name: p.join(appData.path, name),
      };
      final manifestPath = manifestFile.path;
      final settingsPath = settingsFile.path;
      final databasePath = databaseTmp?.path;

      // --- 第 2 步：在独立 isolate 里执行 CPU 密集的 ZIP 打包 ---
      await runBackupIsolate<void, _BackupPackArgs>(
        body: _packAndVerifyInIsolate,
        payload: _BackupPackArgs(
          outPath: outPath,
          manifestPath: manifestPath,
          settingsPath: settingsPath,
          databasePath: databasePath,
          snapshotInfo: snapshotInfo,
          includeChats: includeChats,
          includeFiles: includeFiles,
          appVersion: appVersion,
          businessEntityRowIds: businessExport.entityRowIds,
          assetRootPaths: assetRootPaths,
          ledgerDirectoryPath: ledgerDirectoryPath,
        ),
        cancelToken: cancelToken,
        onProgress: onProgress,
      );

      return (
        file: takePreparedBackupFile(outFile, cancelToken),
        info: snapshotInfo,
        appVersion: appVersion,
      );
    } catch (error) {
      if (shouldDeleteTempPathsAfterIsolateError(error)) {
        unregisterLiveTempPath(workDir.path);
        await _deleteDirectoryQuietly(workDir);
      } else {
        abandonWorkDir = true;
        await deleteTempDirectoryWhenIsolateSafe(workDir, error: error);
      }
      rethrow;
    } finally {
      // 清理临时中间文件。最终 zip 会返回给调用方，
      // 由上传／导出方在使用完之后负责删除。
      // 若快照／打包 isolate 仍存活，就不要动这个目录。
      if (!abandonWorkDir) {
        await _deleteFileQuietly(settingsTmp);
        await _deleteFileQuietly(databaseTmp);
        await _deleteFileQuietly(manifestTmp);
      }
    }
  }

  /// 把非实时数据库转换成一份普通备份。
  ///
  /// 崩溃恢复搁置下来的副本是裸 SQLite 文件，可能处于更旧的 schema，
  /// 也可能还带着未重放的日志。与其给恢复流程再加一种输入形态 ——
  /// 那恰恰是本代码库里最不该出现第二套实现的地方 ——
  /// 不如把它们转成恢复流程本就接受的归档，
  /// 这样导出与恢复都收敛到既有实现上。
  ///
  ///
  /// 资源文件是刻意排除的：它们就在实时数据库旁边，与之共享，
  /// 复制它们只会多占若干 GB，却保护不了这份副本
  /// 本来就没保护到的任何东西。
  Future<File> prepareBackupFileFromDatabase(
    File sourceDatabase, {
    bool allowForwardCompatible = false,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    if (!await sourceDatabase.exists()) {
      throw FileSystemException(
        'Database copy does not exist',
        sourceDatabase.path,
      );
    }
    final tmp = await _ensureTempDir();
    final stagingDirectory = await Directory(
      p.join(tmp.path, 'kelivo_adopt_${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true);
    registerLiveTempPath(stagingDirectory.path);
    try {
      final working = File(
        p.join(stagingDirectory.path, AppDatabase.databaseFileName),
      );
      // 是整个文件族，不只是数据库本身：写入进行中取到的副本
      // 会把已提交事务留在日志里，
      // 不带日志打开数据库会静默丢掉它们。
      for (final suffix in const ['', '-wal', '-shm', '-journal']) {
        final sidecar = File('${sourceDatabase.path}$suffix');
        if (await FileSystemEntity.type(sidecar.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await sidecar.copy('${working.path}$suffix');
        }
      }

      // 重放日志、把较旧的 schema 前推，并校验产出结果 ——
      // 与恢复备份所走的准备流程一致。
      await ChatDatabaseRepository.prepareSnapshotForRestore(
        working,
        allowForwardCompatible: allowForwardCompatible,
      );

      final database = AppDatabase.open(file: working);
      final ({String settingsJson, Map<String, List<String>> entityRowIds})
      businessExport;
      try {
        businessExport = await exportBusinessSettingsFrom(
          BusinessRepository(database),
        );
      } finally {
        await database.close();
      }

      return (await _prepareBackupArchive(
        includeChats: true,
        includeFiles: false,
        exportSettings: () async => businessExport,
        snapshotDatabase: (destination) =>
            ChatDatabaseRepository.createConsistentSnapshot(
              sourceFile: working,
              destinationFile: destination,
            ),
        onProgress: onProgress,
        cancelToken: cancelToken,
      )).file;
    } finally {
      unregisterLiveTempPath(stagingDirectory.path);
      await _deleteDirectoryQuietly(stagingDirectory);
    }
  }

  static Future<void> cleanupTemporaryBackupFile(File? file) async {
    if (file == null) return;
    final parent = file.parent;
    unregisterLiveTempPath(file.path);
    unregisterLiveTempPath(parent.path);
    await _deleteFileQuietly(file);
    try {
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (_) {}
  }

  @visibleForTesting
  static Future<void> completeLocalFileExport({
    required File exported,
    required Future<void> Function(File exported) persist,
  }) async {
    try {
      await persist(exported);
    } finally {
      await cleanupTemporaryBackupFile(exported);
    }
  }

  @visibleForTesting
  static File takePreparedBackupFile(
    File outFile,
    BackupCancelToken? cancelToken,
  ) {
    if (cancelToken?.isCancelled == true) {
      throw const BackupCancelledException();
    }
    return outFile;
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

  @visibleForTesting
  static bool shouldDeleteTempPathsAfterIsolateError(Object? error) {
    if (error is BackupIsolateTimeoutException) return error.isolateExited;
    if (error is BackupCancelledException) return error.isolateExited;
    return true;
  }

  static Future<void> deleteTempDirectoryWhenIsolateSafe(
    Directory directory, {
    Object? error,
  }) async {
    if (shouldDeleteTempPathsAfterIsolateError(error)) {
      unregisterLiveTempPath(directory.path);
      await _deleteDirectoryQuietly(directory);
      return;
    }
    final isolateExit = error == null ? null : backupIsolateExitFuture(error);
    if (isolateExit == null) return;
    unawaited(
      isolateExit.then((_) {
        unregisterLiveTempPath(directory.path);
        return _deleteDirectoryQuietly(directory);
      }),
    );
  }

  static final Set<String> _liveTempPaths = {};

  static void registerLiveTempPath(String path) {
    _liveTempPaths.add(p.normalize(p.absolute(path)));
  }

  static void unregisterLiveTempPath(String path) {
    _liveTempPaths.remove(p.normalize(p.absolute(path)));
  }

  static bool _isLiveTempPath(String path) {
    final normalized = p.normalize(p.absolute(path));
    for (final live in _liveTempPaths) {
      if (normalized == live ||
          p.isWithin(live, normalized) ||
          p.isWithin(normalized, live)) {
        return true;
      }
    }
    return false;
  }

  @visibleForTesting
  static Future<void> debugCleanupPreviousBackupTempFiles(Directory tmp) {
    return _cleanupPreviousBackupTempFiles(tmp);
  }

  /// 从 `kelivo_backup_<带短横线的 ISO 时间>` 形式的文件名里解析创建时间
  /// （见 [prepareBackupFile]，它把 ':' 换成 '-'）。名字里不带时间戳时
  /// 返回 null。
  static DateTime? _backupTempTimestampFromName(String name) {
    const prefix = 'kelivo_backup_';
    if (!name.startsWith(prefix)) return null;
    var core = name.substring(prefix.length);
    if (core.endsWith('.zip')) {
      core = core.substring(0, core.length - 4);
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
      // 只回收那些明确已被遗弃的条目。WebDAV、S3 与本地导出是彼此独立
      // 的提供方，没有共享的忙碌标记，因此在这里做不看年龄的清扫
      // 会删掉另一个提供方仍在打包或上传的备份工作目录。
      //
      final cutoff = DateTime.now().subtract(const Duration(hours: 6));
      Future<bool> isStale(FileSystemEntity entity, String name) async {
        final fromName = _backupTempTimestampFromName(name);
        if (fromName != null) return fromName.isBefore(cutoff);
        try {
          return (await entity.stat()).modified.isBefore(cutoff);
        } catch (_) {
          // 年龄未知：留着，别去冒与正在进行的备份相撞的风险。
          return false;
        }
      }

      await for (final ent in tmp.list(followLinks: false)) {
        if (_isLiveTempPath(ent.path)) continue;
        final name = p.basename(ent.path);
        if (ent is Directory && name.startsWith('kelivo_backup_')) {
          if (await isStale(ent, name)) await _deleteDirectoryQuietly(ent);
        } else if (ent is File &&
            ((name.startsWith('kelivo_backup_') && name.endsWith('.zip')) ||
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
  static void _packAndVerifyInIsolate(
    BackupIsolateContext ctx,
    _BackupPackArgs args,
  ) {
    final expectedEntries = _packZipSync(
      outPath: args.outPath,
      manifestPath: args.manifestPath,
      settingsPath: args.settingsPath,
      databasePath: args.databasePath,
      snapshotInfo: args.snapshotInfo,
      includeChats: args.includeChats,
      includeFiles: args.includeFiles,
      appVersion: args.appVersion,
      businessEntityRowIds: args.businessEntityRowIds,
      assetRootPaths: args.assetRootPaths,
      ledgerDirectoryPath: args.ledgerDirectoryPath,
      ctx: ctx,
    );
    _verifyPackedBackupSync(
      zipPath: args.outPath,
      expectedEntries: expectedEntries,
      ctx: ctx,
    );
  }

  static int _fileSizeSync(String? path) {
    if (path == null) return 0;
    final file = File(path);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  static List<File> _listFilesSync(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];
    return [
      for (final entity in dir.listSync(recursive: true, followLinks: false))
        if (entity is File) entity,
    ];
  }

  static Map<String, _BackupEntryMetadata> _packZipSync({
    required String outPath,
    required String manifestPath,
    required String settingsPath,
    String? databasePath,
    required ChatDatabaseSnapshotInfo? snapshotInfo,
    required bool includeChats,
    required bool includeFiles,
    required String appVersion,
    required Map<String, List<String>> businessEntityRowIds,
    required Map<String, String> assetRootPaths,
    String? ledgerDirectoryPath,
    BackupIsolateContext? ctx,
  }) {
    if (includeChats != (databasePath != null && snapshotInfo != null)) {
      throw StateError('backup_database_component');
    }
    if (includeFiles &&
        (assetRootPaths.length != _assetRootNames.length ||
            !_assetRootNames.every(assetRootPaths.containsKey))) {
      throw StateError('backup_asset_roots');
    }
    final assetFiles = includeFiles
        ? {
            for (final name in _assetRootNames)
              name: _listFilesSync(assetRootPaths[name]!),
          }
        : const <String, List<File>>{};
    var totalBytes = _fileSizeSync(settingsPath) + _fileSizeSync(databasePath);
    for (final files in assetFiles.values) {
      for (final file in files) {
        totalBytes += file.lengthSync();
      }
    }
    final meter = _BackupByteMeter(
      ctx: ctx,
      phase: BackupPhase.packing,
      total: totalBytes,
    );
    meter.report();
    final writer = _StreamingZipWriter(outPath, meter: meter);
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
        for (final name in _assetRootNames) {
          _addDirectoryToZip(
            writer,
            assetRootPaths[name]!,
            name,
            entries,
            collisionKeys,
            files: assetFiles[name],
          );
        }
      }

      // 本机设置册子：**独立于 includeFiles**。册子是数据而不是附件，
      // 它的存亡不能绑在“这次备份带不带附件”上；判断条件只看调用方是否
      // 提供了册子目录（即用户是否选了“带”档）。
      if (ledgerDirectoryPath != null) {
        _addDirectoryToZip(
          writer,
          ledgerDirectoryPath,
          // 目录名固定；条目最终形如 device_local_settings/<指纹>.json
          'device_local_settings',
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
      entries[_manifestEntryName] = writer.addFile(
        manifestFile,
        _manifestEntryName,
      );
      writer.closeSync();
      return entries;
    } finally {
      writer.closeIfNeededSync();
    }
  }

  static void _verifyPackedBackupSync({
    required String zipPath,
    required Map<String, _BackupEntryMetadata> expectedEntries,
    BackupIsolateContext? ctx,
  }) {
    final expectedNames = {...expectedEntries.keys, _manifestEntryName};
    final inputStream = InputFileStream(zipPath);
    try {
      final rawEntryNames = <String>[];
      final archive = ZipDecoder().decodeStream(
        inputStream,
        callback: (entry) => rawEntryNames.add(entry.name),
      );
      try {
        final actualNames = <String>{};
        for (final rawName in rawEntryNames) {
          final canonical = _zipEntryName(rawName);
          if (!actualNames.add(canonical)) {
            throw FormatException('duplicate_zip_entry:$canonical');
          }
        }
        if (actualNames.length != expectedNames.length ||
            !actualNames.containsAll(expectedNames)) {
          throw const FormatException('backup_entries');
        }

        final verifyTotal = expectedEntries.values.fold<int>(
          0,
          (sum, metadata) => sum + metadata.bytes,
        );
        final meter = _BackupByteMeter(
          ctx: ctx,
          phase: BackupPhase.verifying,
          total: verifyTotal,
        );
        meter.report();
        for (final entry in archive) {
          if (!entry.isFile) continue;
          final canonical = _zipEntryName(entry.name);
          ctx?.throwIfCancelled();
          final digest = _NullDigestOutputStream(
            onBytes: (bytes) => meter.add(bytes, detail: canonical),
          );
          try {
            entry.writeContent(digest);
            final actualSha256 = digest.closeAndDigest();
            final expected = expectedEntries[canonical];
            if (expected == null) {
              throw FormatException('backup_entry_unexpected:$canonical');
            }
            if (digest.bytesWritten != expected.bytes) {
              throw FormatException('manifest_entry_size:$canonical');
            }
            if (actualSha256 != expected.sha256) {
              throw FormatException('manifest_entry_hash:$canonical');
            }
          } finally {
            digest.closeSync();
          }
        }
      } finally {
        archive.clearSync();
      }
    } finally {
      inputStream.closeSync();
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

  /// 把 [srcDirPath] 下的所有文件以 [zipPrefix] 为前缀加入 zip。
  static void _addDirectoryToZip(
    _StreamingZipWriter writer,
    String srcDirPath,
    String zipPrefix,
    Map<String, _BackupEntryMetadata> entries,
    Set<String> collisionKeys, {
    List<File>? files,
  }) {
    final fileSystemEntries =
        files ??
        [
          for (final entity
              in Directory(srcDirPath).existsSync()
                  ? Directory(
                      srcDirPath,
                    ).listSync(recursive: true, followLinks: false)
                  : const <FileSystemEntity>[])
            if (entity is File) entity,
        ];
    for (final ent in fileSystemEntries) {
      final rel = p.relative(ent.path, from: srcDirPath);
      // ZIP 条目不区分平台，一律使用正斜杠
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

  static String _zipEntryName(String name) {
    return name.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
  }

  /// 把 DOS 打包的日期／时间值（来自 ZIP 条目的 lastModTime）解码成
  /// [DateTime]。日期部分为零（未设置）时返回 null。
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

  /// 同步 ZIP 解包 —— 在 Isolate 内运行。
  /// 使用 InputFileStream，按需从磁盘读取 ZIP 字节，
  /// 而不是把整个归档读成单个字节数组。
  static void _extractZipInIsolate(
    BackupIsolateContext ctx,
    _BackupExtractArgs args,
  ) {
    _extractZipSync(args.zipPath, args.extractDirPath, ctx: ctx);
  }

  static void _extractZipSync(
    String zipPath,
    String extractDirPath, {
    BackupIsolateContext? ctx,
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
        final extractTotal = archiveFiles.entries
            .where((entry) => entry.key != _manifestEntryName)
            .fold<int>(0, (sum, entry) => sum + entry.value.size);
        final meter = _BackupByteMeter(
          ctx: ctx,
          phase: BackupPhase.extracting,
          total: extractTotal,
        );
        meter.report();
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
              meter: meter,
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
        if (extractTotal > 0 && meter.processed != extractTotal) {
          meter.processed = extractTotal;
        }
        if (extractTotal > 0) {
          meter.report();
        }
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
        !_acceptsArchiveFormat(manifest)) {
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
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
    Map<String, String>? ledgerEntries,
  }) async {
    // 云备份与其他导出口径一致：上传 .joaiclient 容器，用户把它下载回来
    // 就能直接导入，不必再关心 zip 边界。
    final file = await prepareJoaiclientFile(
      cfg,
      onProgress: adaptBackupProgressSink(onProgress),
      cancelToken: cancelToken,
      ledgerEntries: ledgerEntries,
    );
    try {
      await _ensureCollection(cfg, cancelToken: cancelToken);
      if (cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      final target = _fileUri(cfg, p.basename(file.path));
      final fileLen = await file.length();
      // 用流式请求，避免把整个文件读进内存。
      final req = http.StreamedRequest('PUT', target);
      req.headers.addAll({
        'content-type': 'application/zip',
        'content-length': fileLen.toString(),
        ..._authHeaders(cfg),
        ..._extraHeaders(cfg),
      });
      // 把文件流接入请求体。addStream 会响应 sink 的暂停信号，
      // 因此网络慢时磁盘读取会被限速，
      // 而不是把整个 zip 缓存在内存里（那曾让移动端的大文件上传 OOM 被杀）。
      unawaited(
        req.sink
            .addStream(
              _watchedByteStream(
                file.openRead(),
                phase: BackupPhase.uploading,
                total: fileLen,
                onProgress: onProgress,
                cancelToken: cancelToken,
              ),
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
      StreamSubscription<void>? cancelSub;
      try {
        cancelSub = cancelToken?.whenCancelled.asStream().listen((_) {
          client.close();
        });
        final res = await client.send(req).then(http.Response.fromStream);
        if (cancelToken?.isCancelled == true) {
          throw const BackupCancelledException();
        }
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw Exception('Upload failed: ${res.statusCode}');
        }
      } catch (error) {
        if (error is BackupCancelledException ||
            cancelToken?.isCancelled == true) {
          await _deleteRemoteQuietly(cfg, target);
          throw const BackupCancelledException();
        }
        rethrow;
      } finally {
        await cancelSub?.cancel();
        client.close();
      }
    } finally {
      await cleanupTemporaryBackupFile(file);
    }
  }

  Future<List<BackupFileItem>> listBackupFiles(
    WebDavConfig cfg, {
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    onProgress?.call(
      const BackupProgress(
        phase: BackupPhase.listingRemote,
        processed: 0,
        cancellable: true,
      ),
    );
    await _ensureCollection(cfg, cancelToken: cancelToken);
    if (cancelToken?.isCancelled == true) {
      throw const BackupCancelledException();
    }
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
    final client = http.Client();
    StreamSubscription<void>? cancelSub;
    final http.Response res;
    try {
      cancelSub = cancelToken?.whenCancelled.asStream().listen((_) {
        client.close();
      });
      if (cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      res = await client.send(req).then(http.Response.fromStream);
    } catch (error) {
      if (error is BackupCancelledException ||
          cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      rethrow;
    } finally {
      await cancelSub?.cancel();
      client.close();
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('PROPFIND failed: ${res.statusCode}');
    }
    final doc = XmlDocument.parse(res.body);
    final items = <BackupFileItem>[];
    final baseStr = uri.toString();
    for (final resp in doc.findAllElements('response', namespace: '*')) {
      final href = resp.getElement('href', namespace: '*')?.innerText ?? '';
      if (href.isEmpty) continue;
      // 跳过集合自身
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

      // mtime 为空时改从文件名解析（形如 kelivo_backup_2025-01-19T12-34-56.123456.zip）
      if (mtime == null) {
        final match = RegExp(
          r'kelivo_backup_(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d+)\.zip',
        ).firstMatch(name);
        if (match != null) {
          try {
            // 把时间部分的短横线换回冒号
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

  /// 本构建能否读取清单所声明格式版本的归档。
  ///
  /// 完全相等即可，另放宽一种：更新的归档若通过
  /// [backupMinimumReadableFormatKey] 为我们背书，也接受。未声明背书的更新归档
  /// 一律拒绝 —— 与数据库那一侧不同，现实中不存在未声明的更新归档，
  /// 因为凡能写出更新格式的构建都会同时写下该声明，
  /// 所以拒绝不付代价，还能保住
  /// 严格默认。
  static bool _acceptsArchiveFormat(Map<String, dynamic> manifest) {
    final formatVersion = manifest['formatVersion'];
    if (formatVersion is! int) return false;
    if (formatVersion == _backupFormatVersion) return true;
    // 更旧的归档格式过去不支持，现在依然不支持。
    if (formatVersion < _backupFormatVersion) return false;
    final declared = manifest[backupMinimumReadableFormatKey];
    return declared is int && declared >= 1 && declared <= _backupFormatVersion;
  }

  /// 清单是否由比本构建更新的构建所写 —— 两个维度都算：
  /// 更新的归档格式，或更新的数据库 schema。
  ///
  /// 它决定了能容忍多少无法识别的内容。两个维度都重要且各自演进 ——
  /// 更新的构建可以新增一个可忽略的目录而不动 schema，
  /// 而只有设置的备份压根没有 schema ——
  /// 所以只看数据库会让本构建拒收那些
  /// 其实读得了的官方备份。
  ///
  /// 走到这里的更新格式版本，已经通过了
  /// [_acceptsArchiveFormat]，也就是说它是为我们背过书的那一类。
  static bool _declaresNewerBuild(Map<String, dynamic> manifest) {
    final formatVersion = manifest['formatVersion'];
    if (formatVersion is int && formatVersion > _backupFormatVersion) {
      return true;
    }
    final database = manifest['database'];
    if (database is! Map) return false;
    final schemaVersion = database['schemaVersion'];
    return schemaVersion is int &&
        schemaVersion > AppDatabase.currentSchemaVersion;
  }

  /// 本构建认识的清单键。声明了更新 schema 的备份中，多余键会被丢弃；
  /// 其他备份中出现多余键则直接拒收。
  static const _knownManifestKeys = <String>{
    'format',
    'formatVersion',
    'payloadKind',
    'createdAtUtc',
    'appVersion',
    'includeChats',
    'includeFiles',
    'secretsIncluded',
    'businessEntityRowIds',
    'database',
    'entries',
  };

  static const _knownManifestDatabaseKeys = <String>{
    'entry',
    'schemaVersion',
    SchemaMigrations.minimumReadableManifestKey,
    'conversationCount',
    'messageCount',
  };

  /// 把更新构建的清单裁剪到本构建认识的字段。
  ///
  /// 下游每个校验器都刻意只认单一版本，且
  /// RestoreBundleStaging 会严格比对根键集合，因此一个无法识别的字段
  /// 会在用户已经同意之后很久才让恢复失败。
  /// 在此裁剪，既保住了那份严格，又不必去放松
  /// 每个校验器。同版本或更旧的备份不动，因此其中出现的意外字段
  /// 仍然会失败。
  static void _stripUnknownManifestKeys(Map<String, dynamic> manifest) {
    if (!_declaresNewerBuild(manifest)) return;
    manifest.removeWhere((key, _) => !_knownManifestKeys.contains(key));
    final database = manifest['database'];
    if (database is Map) {
      database.removeWhere(
        (key, _) => !_knownManifestDatabaseKeys.contains(key),
      );
    }
    // 更新格式新增的内容现已全部移除，所以剩下的
    // 确实就是本构建格式的归档。若不这么说，
    // 暂存候选就会卡在 RestoreBundleStaging 的严格比对校验上。
    manifest['formatVersion'] = _backupFormatVersion;
  }

  /// 用 [file] 求解 [prompt]，返回
  /// `allowUnverifiedForwardCompatible` 的有效值。
  ///
  /// 拒绝按取消上报：解释由弹窗自己给出，
  /// 恢复流程无需再说什么。
  static Future<bool> _askForwardCompatibility(
    File file, {
    required ForwardCompatibilityPrompt? prompt,
    required bool allowUnverifiedForwardCompatible,
  }) async {
    if (prompt == null) return allowUnverifiedForwardCompatible;
    final compatibility = await inspectBackupCompatibility(file);
    // 没有清单或没有 SQLite 载荷：没什么可问的，
    // 真有毛病恢复流程自己会报。
    if (compatibility == null) return allowUnverifiedForwardCompatible;
    switch (await prompt(compatibility)) {
      case ForwardCompatibilityAnswer.refuse:
        throw const BackupCancelledException();
      case ForwardCompatibilityAnswer.proceedUnverified:
        return true;
      case ForwardCompatibilityAnswer.proceed:
        return allowUnverifiedForwardCompatible;
    }
  }

  Future<void> restoreFromWebDav(
    WebDavConfig cfg,
    BackupFileItem item, {
    RestoreMode mode = RestoreMode.overwrite,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
    bool allowUnverifiedForwardCompatible = false,
    ForwardCompatibilityPrompt? onForwardCompatibility,
  }) async {
    // 把下载流写入文件，不在内存里缓冲。
    final client = http.Client();
    File? file;
    StreamSubscription<void>? cancelSub;
    try {
      cancelSub = cancelToken?.whenCancelled.asStream().listen((_) {
        client.close();
      });
      if (cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      final req = http.Request('GET', item.href);
      req.headers.addAll({..._authHeaders(cfg), ..._extraHeaders(cfg)});
      final streamed = await client.send(req);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        // 抽干响应体，好让客户端干净关闭。
        await streamed.stream.drain<void>();
        throw Exception('Download failed: ${streamed.statusCode}');
      }
      final tmpDir = await _ensureTempDir();
      file = await createTemporaryRestoreFile(tmpDir);
      final knownLength = item.size > 0 ? item.size : streamed.contentLength;
      final sink = file.openWrite();
      try {
        await _watchedByteStream(
          streamed.stream,
          phase: BackupPhase.downloading,
          total: (knownLength != null && knownLength > 0) ? knownLength : null,
          onProgress: onProgress,
          cancelToken: cancelToken,
        ).pipe(sink);
      } catch (error) {
        await _deleteFileQuietly(file);
        file = null;
        if (error is BackupCancelledException ||
            cancelToken?.isCancelled == true) {
          throw const BackupCancelledException();
        }
        rethrow;
      }
      // 归档此刻才存在于本地，所以这是最早能向用户
      // 提出该问题的时机。
      final allowUnverified = await _askForwardCompatibility(
        file,
        prompt: onForwardCompatibility,
        allowUnverifiedForwardCompatible: allowUnverifiedForwardCompatible,
      );
      await _restoreFromBackupFile(
        file,
        cfg,
        mode: mode,
        onProgress: onProgress,
        cancelToken: cancelToken,
        allowUnverifiedForwardCompatible: allowUnverified,
      );
    } catch (error) {
      if (error is BackupCancelledException ||
          cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      rethrow;
    } finally {
      await cancelSub?.cancel();
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

  Future<File> exportToFile(
    WebDavConfig cfg, {
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) =>
      prepareBackupFile(cfg, onProgress: onProgress, cancelToken: cancelToken);

  @visibleForTesting
  static void verifyPackedBackupSync({
    required String zipPath,
    required Map<String, ({int bytes, String sha256})> expectedEntries,
  }) {
    _verifyPackedBackupSync(zipPath: zipPath, expectedEntries: expectedEntries);
  }

  @visibleForTesting
  static ({String digest, List<int> sliceSizes}) debugHashBackReference({
    required List<int> prefix,
    required int distance,
    required int count,
  }) {
    final sliceSizes = <int>[];
    final stream = _NullDigestOutputStream(onBytes: sliceSizes.add);
    stream.writeBytes(prefix);
    sliceSizes.clear();
    stream.writeBackReference(distance, count);
    return (digest: stream.closeAndDigest(), sliceSizes: sliceSizes);
  }

  Future<void> restoreFromLocalFile(
    File file,
    WebDavConfig cfg, {
    RestoreMode mode = RestoreMode.overwrite,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
    bool allowUnverifiedForwardCompatible = false,
    ForwardCompatibilityPrompt? onForwardCompatibility,
  }) async {
    if (!await file.exists()) throw Exception('备份文件不存在');
    // 通常调用方早就问过了（文件一直在它手里）；
    // 这里的弹窗是为 S3 准备的，它从这个入口下载。
    final allowUnverified = await _askForwardCompatibility(
      file,
      prompt: onForwardCompatibility,
      allowUnverifiedForwardCompatible: allowUnverifiedForwardCompatible,
    );
    await _restoreFromBackupFile(
      file,
      cfg,
      mode: mode,
      onProgress: onProgress,
      cancelToken: cancelToken,
      allowUnverifiedForwardCompatible: allowUnverified,
    );
  }

  // ===== 内部辅助函数 =====
  static Stream<List<int>> _watchedByteStream(
    Stream<List<int>> source, {
    required BackupPhase phase,
    required int? total,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async* {
    var processed = 0;
    onProgress?.call(
      BackupProgress(
        phase: phase,
        processed: 0,
        total: total,
        unit: total == null
            ? BackupProgressUnit.none
            : BackupProgressUnit.bytes,
        cancellable: true,
      ),
    );
    await for (final chunk in source) {
      if (cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      processed += chunk.length;
      onProgress?.call(
        BackupProgress(
          phase: phase,
          processed: processed,
          total: total,
          unit: BackupProgressUnit.bytes,
          cancellable: true,
        ),
      );
      yield chunk;
    }
  }

  Future<void> _deleteRemoteQuietly(WebDavConfig cfg, Uri target) async {
    final client = http.Client();
    try {
      final req = http.Request('DELETE', target);
      req.headers.addAll({..._authHeaders(cfg), ..._extraHeaders(cfg)});
      await client.send(req).then(http.Response.fromStream);
    } catch (_) {
    } finally {
      client.close();
    }
  }

  /// 确保临时目录存在（某些 macOS 安装要等到首次使用才创建缓存目录）。
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
      backupMinimumReadableFormatKey: _minimumReadableFormatVersion,
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
          // 让更旧的构建通过丢弃自己不认识的东西来决定
          // 能否恢复这份备份，而不是一拒了之。
          SchemaMigrations.minimumReadableManifestKey:
              // 该键声明的是“读这份备份至少需要多新的 schema”，不能高于
              // 备份自身的 schema —— 否则自相矛盾（迁移备份就是这种情况：
              // 它的库恒为 schema 1，而本构建的声明值是 2）。取两者较小者。
              snapshotInfo.schemaVersion <
                  SchemaMigrations.minimumReadableSchemaVersion
              ? snapshotInfo.schemaVersion
              : SchemaMigrations.minimumReadableSchemaVersion,
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

  static Future<_VersionedBackupInfo> _preflightVersionedBackupInIsolate(
    BackupIsolateContext ctx,
    _BackupPreflightArgs args,
  ) => _preflightVersionedBackup(
    manifestPath: args.manifestPath,
    extractDirPath: args.extractDirPath,
    allowUnverifiedForwardCompatible: args.allowUnverifiedForwardCompatible,
    ctx: ctx,
  );

  static Future<_VersionedBackupInfo> _preflightVersionedBackup({
    required String manifestPath,
    required String extractDirPath,
    bool allowUnverifiedForwardCompatible = false,
    BackupIsolateContext? ctx,
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
        !_acceptsArchiveFormat(manifest)) {
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
    // 本构建用不上的条目。只有当备份来自更新的构建时才容忍它们 ——
    // 那时它们相当于归档层面上的
    // 数据库归一化器所丢弃的未知表与未知列；
    // 若来自同版本或更旧的构建，则说明归档已损坏。下面的判定仍然
    // 决定这份备份究竟能否恢复 —— 这里只决定
    // 一个无法识别的条目本身是否致命。
    final unknownEntryNames = <String>[];
    for (final name in entries.keys) {
      final isFileEntry = _assetRootNames.any(
        (root) => name.startsWith('$root/'),
      );
      // 册子条目是本仓库独有的：它既不是 settings/数据库，也不是附件，
      // 因此必须单独放行，且不受 includeFiles 约束。
      final knownEntry =
          name == 'settings.json' ||
          name == _databaseEntryName ||
          isFileEntry ||
          name.startsWith(ledgerEntryPrefix);
      if (!knownEntry) {
        unknownEntryNames.add(name);
        continue;
      }
      if (!includeFiles && isFileEntry) {
        throw FormatException('manifest_files:$name');
      }
    }
    if (unknownEntryNames.isNotEmpty) {
      if (!_declaresNewerBuild(manifest)) {
        throw FormatException(
          'manifest_entry_scope:${unknownEntryNames.first}',
        );
      }
      for (final name in unknownEntryNames) {
        entries.remove(name);
        // 也一并从磁盘删除，免遭下游捡走：
        // 下面重写过的清单已不再提及它们，而暂存
        // 候选只能包含其清单声明的内容。
        final file = File(p.joinAll([extractDirPath, ...name.split('/')]));
        if (file.existsSync()) file.deleteSync();
      }
    }
    // 同样的道理再往上一层：更新的构建可能用本构建从未听过的清单
    // 字段来描述自己。
    _stripUnknownManifestKeys(manifest);

    final validateTotal = entries.values.fold<int>(
      0,
      (sum, metadata) => sum + metadata.bytes,
    );
    final meter = _BackupByteMeter(
      ctx: ctx,
      phase: BackupPhase.validating,
      total: validateTotal,
    );
    meter.report();
    for (final entry in entries.entries) {
      ctx?.throwIfCancelled();
      final file = File(p.joinAll([extractDirPath, ...entry.key.split('/')]));
      if (!file.existsSync() || file.lengthSync() != entry.value.bytes) {
        throw FormatException('manifest_entry_size:${entry.key}');
      }
      if (_sha256FileSync(file, ctx: ctx) != entry.value.sha256) {
        throw FormatException('manifest_entry_hash:${entry.key}');
      }
      meter.add(entry.value.bytes, detail: entry.key);
    }

    ctx?.reportProgress(
      const BackupProgress(
        phase: BackupPhase.validating,
        processed: 0,
        cancellable: true,
      ),
    );

    final rawDatabase = manifest['database'];
    if (payloadKind == 'sqlite') {
      if (!includeChats ||
          !entries.containsKey(_databaseEntryName) ||
          rawDatabase is! Map) {
        throw const FormatException('manifest_database');
      }
      final database = rawDatabase.cast<String, dynamic>();
      final schemaVersion = database['schemaVersion'];
      final declaredMinimumReadable =
          database[SchemaMigrations.minimumReadableManifestKey];
      final conversationCount = database['conversationCount'];
      final messageCount = database['messageCount'];
      if (database['entry'] != _databaseEntryName ||
          schemaVersion is! int ||
          schemaVersion < 1 ||
          (declaredMinimumReadable != null &&
              (declaredMinimumReadable is! int ||
                  declaredMinimumReadable < 1 ||
                  declaredMinimumReadable > schemaVersion)) ||
          conversationCount is! int ||
          conversationCount < 0 ||
          messageCount is! int ||
          messageCount < 0) {
        throw const FormatException('manifest_database');
      }
      final verdict = SchemaMigrations.classifyBackup(
        schemaVersion: schemaVersion,
        declaredMinimumReadable: declaredMinimumReadable as int?,
      );
      switch (verdict) {
        case BackupSchemaVerdict.unreadable:
          throw const FormatException('manifest_database_schema_too_new');
        case BackupSchemaVerdict.forwardUndeclared:
          // 调用方必须先取得用户的知情同意；
          // 否则无从判断这份备份读起来是否安全。
          if (!allowUnverifiedForwardCompatible) {
            throw const FormatException('manifest_database_schema_too_new');
          }
        case BackupSchemaVerdict.current:
        case BackupSchemaVerdict.needsUpgrade:
        case BackupSchemaVerdict.forwardCompatible:
          break;
      }
      final databaseFile = File(
        p.joinAll([extractDirPath, ..._databaseEntryName.split('/')]),
      );
      final databaseInfo =
          await ChatDatabaseRepository.prepareSnapshotForRestore(
            databaseFile,
            allowForwardCompatible:
                verdict == BackupSchemaVerdict.forwardCompatible ||
                verdict == BackupSchemaVerdict.forwardUndeclared,
          );
      // 清单记录的是备份**写就时**的 schema；info 记录的是
      // prepareSnapshotForRestore 迁移之后的 schema，
      // 因此对较旧的备份而言两者本就不同。真正的不变量是
      // 行数：迁移绝不能增删行。
      if (databaseInfo.conversationCount != conversationCount ||
          databaseInfo.messageCount != messageCount) {
        throw const FormatException('manifest_database_metadata');
      }
      entries[_databaseEntryName] = (
        bytes: databaseFile.lengthSync(),
        sha256: _sha256FileSync(databaseFile, ctx: ctx),
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

    ctx?.reportProgress(
      const BackupProgress(
        phase: BackupPhase.finalizing,
        processed: 0,
        cancellable: true,
      ),
    );

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

  static Map<String, dynamic> _readSettingsJsonInIsolate(
    BackupIsolateContext ctx,
    String path,
  ) {
    ctx.throwIfCancelled();
    ctx.reportProgress(
      const BackupProgress(
        phase: BackupPhase.readingSettings,
        processed: 0,
        cancellable: true,
      ),
    );
    final settings = _readSettingsJsonSync(path);
    ctx.throwIfCancelled();
    return settings;
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

  static String _sha256FileSync(File file, {BackupIsolateContext? ctx}) {
    final digestSink = _DigestOutputSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    final input = file.openSync();
    final buffer = Uint8List(1024 * 1024);
    try {
      while (true) {
        ctx?.throwIfCancelled();
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

  Future<Directory> _liveAssetRoot(String name) async {
    if (!_assetRootNames.contains(name)) {
      throw StateError('unknown_asset_root:$name');
    }
    final appData = await AppDirectories.getAppDataDirectory();
    return Directory(p.join(appData.path, name));
  }

  Future<void> _copyRestoredFile(File source, File target) async {
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    try {
      await target.setLastModified(await source.lastModified());
    } on FileSystemException {
      // 以载荷复制为准；时间戳只是元数据，
      // 在不支持设置时间戳的文件系统上可以缺省。
    }
  }

  /// 把备份的资源载荷目录复制进实时目录，
  /// 不删除任何已有内容，这样未被改动的聊天数据库
  /// 所引用的文件才能存活。
  Future<void> _restoreAssetDirectoriesAdditive(
    Directory payloadDirectory, {
    Map<String, String> remappedConversationIds = const {},
  }) async {
    for (final name in _assetRootNames) {
      final src = Directory(p.join(payloadDirectory.path, name));
      if (!await src.exists()) continue;
      final dst = await _liveAssetRoot(name);
      if (!await dst.exists()) {
        await dst.create(recursive: true);
      }
      for (final ent in src.listSync(recursive: true)) {
        if (ent is File) {
          final rel = p.relative(ent.path, from: src.path);
          final segments = p.split(rel);
          if (name == 'sessions' && segments.length > 1) {
            segments[0] = remappedConversationIds[segments[0]] ?? segments[0];
          }
          final targetFile = File(p.joinAll([dst.path, ...segments]));
          if (!await targetFile.exists()) {
            await _copyRestoredFile(ent, targetFile);
          }
        }
      }
    }
  }

  static Future<_ParsedChatBackup> _parseLegacyChatsInIsolate(
    BackupIsolateContext ctx,
    _LegacyChatParseArgs args,
  ) async {
    ctx.throwIfCancelled();
    ctx.reportProgress(
      const BackupProgress(
        phase: BackupPhase.importingMessages,
        processed: 0,
        cancellable: true,
      ),
    );
    final parsed = _sanitizeLegacyChatBackup(
      await _parseChatBackup(File(args.chatsPath), ctx: ctx),
    );
    _validateBackupReferences(
      conversations: parsed.conversations,
      messages: parsed.messages,
      toolEvents: parsed.toolEvents,
      geminiThoughtSigs: parsed.geminiThoughtSigs,
    );
    if (args.buildOverwriteCandidate) {
      final candidatePath = p.join(args.stagingPath, 'candidate.sqlite');
      for (final suffix in const ['', '-wal', '-shm', '-journal']) {
        final file = File('$candidatePath$suffix');
        if (file.existsSync()) file.deleteSync();
      }
      try {
        await _buildAndValidateOverwriteChatCandidate(
          candidatePath: candidatePath,
          conversations: parsed.conversations,
          messages: parsed.messages,
          toolEvents: parsed.toolEvents,
          geminiThoughtSigs: parsed.geminiThoughtSigs,
        );
      } finally {
        for (final suffix in const ['', '-wal', '-shm', '-journal']) {
          final file = File('$candidatePath$suffix');
          if (file.existsSync()) file.deleteSync();
        }
      }
    }
    ctx.throwIfCancelled();
    return parsed;
  }

  static Future<_ParsedChatBackup> _parseChatBackup(
    File chatsFile, {
    BackupIsolateContext? ctx,
  }) async {
    ctx?.throwIfCancelled();
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
    final conversations = (chats['conversations'] as List).map((entry) {
      final conversation = Conversation.fromJson(
        (entry as Map).cast<String, dynamic>(),
      );
      return conversation.copyWith(
        extras: {...conversation.extras}..remove('workspace.allowAll'),
      );
    }).toList();

    // 旧版 chats.json 的导入边界：只有当原始 JSON 缺少 `parts` 列表时，
    // 才把带标记的内容提升为结构化 parts。
    // 新导出的内容本就带 `parts`（包括字面形似标记的文本），
    // 必须原样往返，不被二次提升。
    var converted = 0;
    var malformed = 0;
    var missingFiles = 0;
    final messages = <ChatMessage>[];
    for (final entry in chats['messages'] as List) {
      ctx?.throwIfCancelled();
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
      // 导入边界：把受管的本地附件持久化为 kelivo-file URI。
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

  /// 旧版（1.1.17）备份可能带着当时运行时默默容忍的形状：
  /// 悬空或重复的 messageIds 引用、没有任何会话引用的消息，
  /// 以及 conversationId 与引用它的会话不一致的消息。
  /// 这里按 1.1.17 当时**实际显示**的样子恢复，
  /// 而不是拒收归档：每个会话的
  /// messageIds 顺序为准，悬空引用被剪掉
  ///（SQLite 的顺序来自 message_order，剪掉后与旧运行时一致），
  /// 重复引用保留首次出现，
  /// 未被引用的消息本来就没显示过，因此跳过。它还会把
  /// 1.1.17 使用的原始消息下标与版本序号，转换成
  /// SQLite 使用的逻辑槽位下标与具体消息版本。
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
      // 1.1.17 运行时容忍重复的 (groupId, version) 组合（上面的
      // 重新归属还可能产生新的组合）；按与 Hive 迁移相同的方式重排版本，
      // 免得 INSERT OR REPLACE 把行吞掉。
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
        // 字段级修复（空 role、负数 tokens／duration、
        // 越界的版本号、颠倒的推理时间戳）与 Hive 迁移共用逻辑；
        // 它必须在下面的版本冲突修复之前跑，
        // 因为钳制版本号可能引入冲突，
        // 而那一步修复正是用来解决冲突的。
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
      // 计数钳制与 Hive 迁移共用逻辑，这样一份带着越界值
      //（例如负数 truncateIndex）的旧备份，
      // 不会在恢复时触发 conversation_rows 的 CHECK 约束。
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
  _exportBusinessSettings() => exportBusinessSettingsFrom(businessRepository);

  /// 备份中属于设置的那一半，从给定仓库读取。
  static Future<({String settingsJson, Map<String, List<String>> entityRowIds})>
  exportBusinessSettingsFrom(BusinessRepository repository) async {
    final exported = BusinessSettingsRouter.exportSnapshotWithRowIds(
      BackupPortability.portable(await repository.readSnapshot()),
    );
    final settings = Map<String, Object>.from(exported.settings);
    settings.removeWhere((key, _) => BackupSettingsValidator.shouldIgnore(key));
    BackupSettingsValidator.retainCloudAsrForExport(settings);
    return (
      settingsJson: jsonEncode(settings),
      entityRowIds: exported.entityRowIds,
    );
  }

  static Future<void> _sanitizeBackupDatabase(File file) async {
    final database = AppDatabase.open(file: file);
    try {
      await BackupPortability.sanitizeDatabase(database);
    } finally {
      await database.close();
    }
    await ChatDatabaseRepository.normalizeSnapshotJournal(file);
  }

  /// 读取备份文件的清单，报告恢复它的后果。
  ///
  /// 只解码清单条目，因此足够轻量，可以在恢复开始之前调用。
  /// 文件不含 SQLite 载荷或清单读不出来时返回 null ——
  /// 那些情况由恢复流程自己去报。
  ///
  static Future<BackupCompatibility?> inspectBackupCompatibility(
    File file,
  ) async {
    try {
      if (!await file.exists()) return null;
      final inputStream = InputFileStream(file.path);
      Map<String, dynamic>? manifest;
      try {
        final archive = ZipDecoder().decodeStream(inputStream);
        for (final entry in archive.files) {
          if (_zipEntryName(entry.name) != _manifestEntryName) continue;
          if (!entry.isFile || entry.size > _maxManifestBytes) return null;
          final decoded = jsonDecode(utf8.decode(entry.readBytes()!));
          if (decoded is Map<String, dynamic>) manifest = decoded;
          break;
        }
      } finally {
        await inputStream.close();
      }
      if (manifest == null) return null;
      final database = manifest['database'];
      if (database is! Map) return null;
      final schemaVersion = database['schemaVersion'];
      if (schemaVersion is! int) return null;
      final declared = database[SchemaMigrations.minimumReadableManifestKey];
      return (
        schemaVersion: schemaVersion,
        verdict: SchemaMigrations.classifyBackup(
          schemaVersion: schemaVersion,
          declaredMinimumReadable: declared is int ? declared : null,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 从解包目录吸收册子记录并并入正本册子（无条件，任何模式都执行）。
  ///
  /// 单设备文件损坏只跳过该设备，其余照常并入；整个环节的任何失败都不
  /// 影响主恢复 —— 它只是附带的数据累积。
  Future<List<DeviceSettingsRecord>> _absorbDeviceLedger({
    required Directory extractDir,
    BackupCancelToken? cancelToken,
  }) async {
    final records = <DeviceSettingsRecord>[];
    try {
      final ledgerDir = Directory(
        p.join(extractDir.path, 'device_local_settings'),
      );
      if (!await ledgerDir.exists()) return records;
      await for (final entity in ledgerDir.list(followLinks: false)) {
        cancelToken?.throwIfCancelled();
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.endsWith('.json')) continue;
        try {
          final record = LocalDeviceSettingsLedger.parseArchiveFile(
            'device_local_settings/$name',
            await entity.readAsString(),
          );
          if (record != null) records.add(record);
        } catch (_) {
          // 单个文件损坏只跳过该设备。
        }
      }
      if (records.isEmpty) return records;
      final ledger = LocalDeviceSettingsLedger();
      try {
        await ledger.mergeFromArchive(records);
      } finally {
        await ledger.close();
      }
      _lastLedgerAbsorbed = records.length;
      _lastLedgerRecords = records;
    } catch (_) {
      // 册子吸收是附带累积，绝不能影响主恢复。
    }
    return records;
  }

  /// 合并保留模式的就地写回：逐键补缺（本机已有不动、缺少才补）。
  ///
  /// 返回真正写入的键数。写入的都是本机原本不存在的键，因此不会出现
  /// “设置变了、数据退回”的半成品状态 —— 原本促使我们把写回推迟到 cutover
  /// 的那个不一致风险，在本模式下不成立。
  Future<int> _applyLocalSettingsForMerge(
    List<DeviceSettingsRecord> records,
  ) async {
    if (records.isEmpty) return 0;
    try {
      final identity = await DeviceIdentityService.resolve();
      if (identity == null) return 0;
      final mine = records
          .where((record) => record.fingerprint == identity.fingerprintHash)
          .toList();
      if (mine.isEmpty) return 0;
      // 同指纹理论上只有一条；取最近的一条。
      mine.sort((a, b) => b.savedAtUtc.compareTo(a.savedAtUtc));
      return await DeviceLocalSettingsWriter.applyMissingOnly(
        mine.first.values,
      );
    } catch (_) {
      return 0;
    }
  }

  Future<void> _restoreFromBackupFile(
    File file,
    WebDavConfig cfg, {
    RestoreMode mode = RestoreMode.overwrite,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
    bool allowUnverifiedForwardCompatible = false,
  }) async {
    _lastMergeReport = null;
    // 本机设置册子的三项结果每次恢复都重新计数，避免上一轮的值残留。
    _lastLedgerAbsorbed = 0;
    _lastLocalSettingsApplied = 0;
    _lastLedgerRecords = const [];
    // 用文件流解码解到临时目录，避免把整个 ZIP 读进内存
    //（旧做法调用 file.readAsBytes()，对 600-800 MB 的文件
    // 会分配一块同样大小的连续字节数组）。
    final tmp = await _ensureTempDir();
    final extractDir = Directory(
      p.join(tmp.path, 'restore_${DateTime.now().millisecondsSinceEpoch}'),
    );
    await extractDir.create(recursive: true);
    registerLiveTempPath(extractDir.path);

    Object? restoreError;
    File? payloadFile;
    try {
      if (cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      // 本仓库的备份可能是 .joaiclient 容器（zip 外面还包了一层头部）。
      // 判断只看文件头、不认扩展名，所以改过名字的包也能正确还原。
      final isJoaiclient = await JoaiclientArchive.isJoaiclient(file);
      // .joaiclient 是整机完整快照：始终携带聊天与文件，不受 provider
      // 的可选旧版标志影响。恢复模式则尊重用户的选择 —— 合并保留会把
      // 备份并入本机现有数据，而不是静默替换它。
      final effectiveConfig = isJoaiclient
          ? cfg.copyWith(includeChats: true, includeFiles: true)
          : cfg;
      if (isJoaiclient) {
        payloadFile = File(p.join(extractDir.path, '_payload.zip'));
        registerLiveTempPath(payloadFile.path);
        await JoaiclientArchive.unwrapToZip(
          sourceFile: file,
          zipFile: payloadFile,
          cancelToken: cancelToken,
        );
      }
      await runBackupIsolate<void, _BackupExtractArgs>(
        body: _extractZipInIsolate,
        payload: _BackupExtractArgs(
          zipPath: (payloadFile ?? file).path,
          extractDirPath: extractDir.path,
        ),
        cancelToken: cancelToken,
        onProgress: onProgress,
      );

      final manifestFile = File(p.join(extractDir.path, _manifestEntryName));
      final restorePayloadDirectory = extractDir;
      final settingsFile = File(p.join(extractDir.path, 'settings.json'));
      final chatsFile = File(p.join(extractDir.path, 'chats.json'));
      if (!await settingsFile.exists()) {
        throw const FormatException('settings.json');
      }
      final _VersionedBackupInfo? versionedBackup;
      if (await manifestFile.exists()) {
        if (cancelToken?.isCancelled == true) {
          throw const BackupCancelledException();
        }
        versionedBackup =
            await runBackupIsolate<_VersionedBackupInfo, _BackupPreflightArgs>(
              body: _preflightVersionedBackupInIsolate,
              payload: _BackupPreflightArgs(
                manifestPath: manifestFile.path,
                extractDirPath: extractDir.path,
                allowUnverifiedForwardCompatible:
                    allowUnverifiedForwardCompatible,
              ),
              cancelToken: cancelToken,
              onProgress: onProgress,
            );
      } else {
        versionedBackup = null;
      }
      if (cancelToken?.isCancelled == true) {
        throw const BackupCancelledException();
      }
      final settings = await runBackupIsolate<Map<String, dynamic>, String>(
        body: _readSettingsJsonInIsolate,
        payload: settingsFile.path,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      BackupSettingsValidator.normalizeAndValidate(settings);

      // --- 本机设置册子：无条件吸收 + 按模式分流写回 ---
      // 吸收在流程内完成（解包目录此刻还可读），且不受恢复模式影响：
      // 记录属于累积数据，扔掉会打断累积链路。
      final ledgerRecords = await _absorbDeviceLedger(
        extractDir: extractDir,
        cancelToken: cancelToken,
      );
      if (mode == RestoreMode.merge) {
        // 合并保留是就地写回、不重启，因此这里就能确定写入结果。
        _lastLocalSettingsApplied = await _applyLocalSettingsForMerge(
          ledgerRecords,
        );
      }

      void beginNonCancellableCommit() {
        if (cancelToken?.isCancelled == true) {
          throw const BackupCancelledException();
        }
        cancelToken?.setCancellable(false);
        onProgress?.call(
          const BackupProgress(
            phase: BackupPhase.committing,
            processed: 0,
            cancellable: false,
          ),
        );
      }

      final businessRestore = BusinessRestoreService(businessRepository);
      Future<void> Function()? pendingBusinessRestore;
      if (versionedBackup != null) {
        final entityRowIds = versionedBackup.businessEntityRowIds;
        final preserveExplicitEmptyInstructionList = entityRowIds == null;
        final includeChats = versionedBackup.includeChats;
        final includeFiles = versionedBackup.includeFiles;
        if (isJoaiclient && (!includeChats || !includeFiles)) {
          throw const FormatException('joaiclient_not_full_snapshot');
        }
        final restoreChats = effectiveConfig.includeChats && includeChats;
        final restoreFiles = effectiveConfig.includeFiles && includeFiles;
        if (mode == RestoreMode.merge && restoreChats) {
          // 聊天合并独立提交，因此在改动任一侧实时数据之前，
          // 先拒掉不匹配的业务载荷。
          BusinessSettingsRouter.normalizeAndRoute(
            settings,
            preserveExplicitEmptyInstructionList:
                preserveExplicitEmptyInstructionList,
            entityRowIds: entityRowIds,
          );
        }
        if (mode == RestoreMode.overwrite) {
          if (!restoreChats) {
            beginNonCancellableCommit();
            if (restoreFiles) {
              // 文件恢复与聊天恢复彼此独立。这里实时数据库
              // 不会被动到，因此按新增方式复制载荷
              //（绝不删除它所引用的已有文件），
              // 并在最后写入业务数据，与旧路径保持一致。
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
          if (cancelToken?.isCancelled == true) {
            throw const BackupCancelledException();
          }
          await _prepareRestoreBundle(
            appDataPath: appDataPath,
            extractedPath: extractedPath,
            sourceManifestSha256: sourceManifestSha256,
            includeChats: includeChats,
            includeFiles: includeFiles,
            restoreChats: restoreChats,
            restoreFiles: restoreFiles,
            validatedSettings: settings,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
          return;
        }
        if (restoreChats) {
          await _sanitizeBackupDatabase(
            File(p.join(extractDir.path, _databaseEntryName)),
          );
          beginNonCancellableCommit();
          _lastMergeReport = await chatService.mergeDatabaseSnapshot(
            File(p.join(extractDir.path, _databaseEntryName)),
          );
          // 仅聊天：文件没恢复时，绝不能让本地附件被标成可用
          //（目标端路径撞名不足以作为判据）。
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
          beginNonCancellableCommit();
          if (restoreFiles) {
            await _restoreAssetDirectoriesAdditive(extractDir);
          }
          await _runLiveBusinessRestore(pendingBusinessRestore);
          return;
        }
      }
      final restoreChats =
          versionedBackup == null &&
          cfg.includeChats &&
          await chatsFile.exists();

      var conversations = const <Conversation>[];
      var messages = const <ChatMessage>[];
      var toolEvents = const <String, List<Map<String, dynamic>>>{};
      var geminiThoughtSigs = const <String, String>{};
      if (restoreChats) {
        final parsed =
            await runBackupIsolate<_ParsedChatBackup, _LegacyChatParseArgs>(
              body: _parseLegacyChatsInIsolate,
              payload: _LegacyChatParseArgs(
                chatsPath: chatsFile.path,
                stagingPath: extractDir.path,
                buildOverwriteCandidate: mode == RestoreMode.overwrite,
              ),
              cancelToken: cancelToken,
              onProgress: onProgress,
            );
        conversations = parsed.conversations;
        // 工作 isolate 里没有 SandboxPathResolver 的 docsDir。
        // 这里以实时根目录为基准编码受管附件（只改 URI，
        // 不再解析一遍 chats.json）。
        messages = parsed.messages.map((message) {
          final normalized = _normalizeAttachmentPartUris(message.parts);
          return identical(normalized, message.parts)
              ? message
              : message.copyWith(parts: normalized);
        }).toList();
        toolEvents = parsed.toolEvents;
        geminiThoughtSigs = parsed.geminiThoughtSigs;
      }

      if (versionedBackup == null) {
        // 聊天恢复与文件恢复各自独立提交。在改动任一领域之前，
        // 先拒掉整个旧版业务载荷，
        // 并在最后写入业务数据，这样后续失败不会让恢复后的写入
        // 闸门悬在那里却不提示重启。
        BusinessSettingsRouter.normalizeAndRoute(
          settings,
          preserveExplicitEmptyInstructionList: true,
          assumePreV3EmbeddingMigrationWhenVersionMissing: true,
        );
        pendingBusinessRestore = mode == RestoreMode.overwrite
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
      if (cfg.includeFiles) {
        beginNonCancellableCommit();
        if (mode == RestoreMode.overwrite) {
          for (final name in _assetRootNames) {
            final src = Directory(p.join(restorePayloadDirectory.path, name));
            if (!await src.exists()) continue;
            final dst = await _liveAssetRoot(name);
            if (await dst.exists()) {
              await dst.delete(recursive: true);
            }
            await dst.create(recursive: true);
            for (final ent in src.listSync(recursive: true)) {
              if (ent is File) {
                final rel = p.relative(ent.path, from: src.path);
                final target = File(p.join(dst.path, rel));
                await _copyRestoredFile(ent, target);
              }
            }
          }
        } else {
          // 合并模式：只复制尚不存在的文件
          await _restoreAssetDirectoriesAdditive(
            restorePayloadDirectory,
            remappedConversationIds:
                _lastMergeReport?.remappedConversationIds ?? const {},
          );
        }
      }
      // 旧版 chats.json 在资源尚不存在时就已经解码。文件落盘之后，
      // 把旧的绝对根目录定向重映射到已恢复的受管相对路径上，
      // 再刷新可用性（不做全局通用的路径规范化兜底）。
      if (restoreChats && cfg.includeFiles) {
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
      } else if (restoreChats && !cfg.includeFiles) {
        // 仅聊天的旧版导入：本地附件默认标为不可用。
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
        beginNonCancellableCommit();
        try {
          if (mode == RestoreMode.overwrite) {
            await chatService.replaceAllDataFromBackup(
              conversations: conversations,
              messages: messages,
              toolEventsByMessageId: toolEvents,
              geminiSignaturesByMessageId: geminiThoughtSigs,
            );
          } else {
            // 合并模式：只添加尚不存在的会话与消息
            final existingConvs = chatService.getAllCompleteConversations();
            final existingConvIds = existingConvs.map((c) => c.id).toSet();

            // 建一张消息 ID 映射以去重（只取 id：
            // 整条加载会把 LRU 缓存冲掉，却换不来什么收益）
            final existingMsgIds = <String>{};
            for (final conv in existingConvs) {
              existingMsgIds.addAll(await chatService.getMessageIds(conv.id));
            }

            // 按会话给消息分组
            final byConv = <String, List<ChatMessage>>{};
            for (final m in messages) {
              if (!existingMsgIds.contains(m.id)) {
                (byConv[m.conversationId] ??= <ChatMessage>[]).add(m);
              }
            }

            // 恢复尚不存在的会话及其消息
            final mergedConvIds = <String>[];
            for (final c in conversations) {
              if (!existingConvIds.contains(c.id)) {
                final list = byConv[c.id] ?? const <ChatMessage>[];
                await chatService.restoreConversation(c, list);
                mergedConvIds.add(c.id);
              } else if (byConv.containsKey(c.id)) {
                // 会话已存在，但有新消息
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
            // §6.7：恢复回来的历史不得再次触发后台提取，
            // 且注入哈希必须清空，好让下一次请求自愈。
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
        beginNonCancellableCommit();
        await _runLiveBusinessRestore(restoreBusiness);
      }
    } catch (error) {
      restoreError = error;
      rethrow;
    } finally {
      await deleteTempDirectoryWhenIsolateSafe(extractDir, error: restoreError);
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
    this.meter,
  }) : super.withFileHandle(FileHandle(path, mode: FileAccess.write));

  final int expectedBytes;
  final int maxEntryBytes;
  final _ExtractionBudget budget;
  final _BackupByteMeter? meter;
  int _entryBytes = 0;

  void _reserve(int bytes) {
    if (bytes < 0 ||
        _entryBytes + bytes > expectedBytes ||
        _entryBytes + bytes > maxEntryBytes) {
      throw const FormatException('zip_entry_size');
    }
    budget.reserve(bytes);
    _entryBytes += bytes;
    meter?.add(bytes);
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
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      meter?.ctx?.throwIfCancelled();
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

class _BackupExtractArgs {
  const _BackupExtractArgs({
    required this.zipPath,
    required this.extractDirPath,
  });

  final String zipPath;
  final String extractDirPath;
}

class _LegacyChatParseArgs {
  const _LegacyChatParseArgs({
    required this.chatsPath,
    required this.stagingPath,
    required this.buildOverwriteCandidate,
  });

  final String chatsPath;
  final String stagingPath;
  final bool buildOverwriteCandidate;
}

class _BackupPreflightArgs {
  const _BackupPreflightArgs({
    required this.manifestPath,
    required this.extractDirPath,
    this.allowUnverifiedForwardCompatible = false,
  });

  final String manifestPath;
  final String extractDirPath;

  /// 仅在已告知用户“这份备份来自更新版本、且未做兼容性承诺”
  /// 且用户选择继续之后才置位。
  final bool allowUnverifiedForwardCompatible;
}

class _BackupPackArgs {
  const _BackupPackArgs({
    required this.outPath,
    required this.manifestPath,
    required this.settingsPath,
    required this.databasePath,
    required this.snapshotInfo,
    required this.includeChats,
    required this.includeFiles,
    required this.appVersion,
    required this.businessEntityRowIds,
    required this.assetRootPaths,
    this.ledgerDirectoryPath,
  });

  final String outPath;
  final String manifestPath;
  final String settingsPath;
  final String? databasePath;
  final ChatDatabaseSnapshotInfo? snapshotInfo;
  final bool includeChats;
  final bool includeFiles;
  final String appVersion;
  final Map<String, List<String>> businessEntityRowIds;
  final Map<String, String> assetRootPaths;

  /// 本机设置册子的临时目录（内含 `device_local_settings/<指纹>.json`）。
  /// 为空表示“不带”档 —— 册子条目完全不进包。
  ///
  /// 注意：这条路径与 [includeFiles] 完全无关。册子不是附件，
  /// 不能并入 [assetRootPaths]，否则 cutover 会把它当附件搬走。
  final String? ledgerDirectoryPath;
}

class _BackupByteMeter {
  _BackupByteMeter({
    required this.ctx,
    required this.phase,
    required this.total,
  });

  final BackupIsolateContext? ctx;
  final BackupPhase phase;
  final int total;
  var processed = 0;

  void add(int bytes, {String? detail}) {
    processed += bytes;
    report(detail: detail);
  }

  void report({String? detail}) {
    ctx?.throwIfCancelled();
    ctx?.reportProgress(
      BackupProgress(
        phase: phase,
        processed: processed,
        total: total,
        unit: BackupProgressUnit.bytes,
        detail: detail,
        cancellable: true,
      ),
    );
  }
}

class _StreamingZipWriter {
  _StreamingZipWriter(String outPath, {this.meter})
    : _output = OutputFileStream(outPath);

  final _BackupByteMeter? meter;

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
    // Deflate 可能让不可压缩的输入略微变大，因此在触及 32 位边界之前
    // 就预留 ZIP64，而不是等流式写完之后才发现溢出。
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

    final written = _writeDeflatedFile(file, entryName);
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
      // 尺寸由 ZIP64 数据描述符与中央目录最终确定。
      _output.writeUint64(0);
      _output.writeUint64(0);
    }
  }

  _StreamingZipWrittenFile _writeDeflatedFile(File file, String entryName) {
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
        meter?.add(read, detail: entryName);
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

class _NullDigestOutputStream extends OutputStream {
  _NullDigestOutputStream({this.onBytes})
    : super(byteOrder: ByteOrder.littleEndian);

  final void Function(int bytes)? onBytes;

  static const _windowSize = 32768;
  static const _backRefFlushSize = 64 * 1024;
  final Uint8List _window = Uint8List(_windowSize);
  final Uint8List _one = Uint8List(1);
  final Uint8List _backRefBuf = Uint8List(_backRefFlushSize);
  final _digestSink = _DigestOutputSink();
  late final ByteConversionSink _hash = sha256.startChunkedConversion(
    _digestSink,
  );
  var _length = 0;
  var _closed = false;

  @override
  int get length => _length;

  int get bytesWritten => _length;

  String closeAndDigest() {
    if (!_closed) {
      _hash.close();
      _closed = true;
    }
    final digest = _digestSink.digest;
    if (digest == null) {
      throw StateError('sha256');
    }
    return digest.toString();
  }

  void _absorb(List<int> bytes, int start, int end) {
    if (start >= end) return;
    final view = bytes is Uint8List
        ? Uint8List.sublistView(bytes, start, end)
        : Uint8List.fromList(bytes.sublist(start, end));
    _hash.add(view);
    onBytes?.call(end - start);
    var offset = start;
    var remaining = end - start;
    while (remaining > 0) {
      final windowIndex = _length % _windowSize;
      final room = _windowSize - windowIndex;
      final n = remaining < room ? remaining : room;
      if (bytes is Uint8List) {
        _window.setRange(windowIndex, windowIndex + n, bytes, offset);
      } else {
        for (var i = 0; i < n; i++) {
          _window[windowIndex + i] = bytes[offset + i];
        }
      }
      _length += n;
      offset += n;
      remaining -= n;
    }
  }

  int _byteAtDistance(int distance) {
    if (distance <= 0 || distance > _length || distance > _windowSize) {
      throw StateError('lz77_window');
    }
    return _window[(_length - distance) % _windowSize];
  }

  @override
  void writeByte(int value) {
    _one[0] = value;
    _hash.add(_one);
    onBytes?.call(1);
    _window[_length % _windowSize] = value;
    _length++;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final n = length ?? bytes.length;
    if (n < 0 || n > bytes.length) {
      throw RangeError.range(n, 0, bytes.length, 'length');
    }
    _absorb(bytes, 0, n);
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

  @override
  void writeBackReference(int distance, int count) {
    var remaining = count;
    while (remaining > 0) {
      final n = remaining < _backRefFlushSize ? remaining : _backRefFlushSize;
      for (var i = 0; i < n; i++) {
        final value = _byteAtDistance(distance);
        _backRefBuf[i] = value;
        _window[_length % _windowSize] = value;
        _length++;
      }
      _hash.add(Uint8List.sublistView(_backRefBuf, 0, n));
      onBytes?.call(n);
      remaining -= n;
    }
  }

  @override
  void clear() {}

  @override
  void flush() {}

  @override
  void closeSync() {
    if (!_closed) {
      _hash.close();
      _closed = true;
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    if (start < 0) start = _length + start;
    final resolvedEnd = end == null ? _length : (end < 0 ? _length + end : end);
    final n = resolvedEnd - start;
    if (n < 0 || start < 0 || resolvedEnd > _length) {
      throw RangeError('subset');
    }
    if (n > _windowSize || _length - start > _windowSize) {
      throw StateError('subset_window');
    }
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _window[(start + i) % _windowSize];
    }
    return out;
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
