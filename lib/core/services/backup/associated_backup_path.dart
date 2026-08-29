import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

final class AssociatedBackupPathEvents {
  AssociatedBackupPathEvents._();

  static final instance = AssociatedBackupPathEvents._();
  static const _channel = MethodChannel('app.associated_backup');
  final _controller = StreamController<String>.broadcast();
  var _initialized = false;

  Stream<String> get paths => _controller.stream;

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) {
        final path = (call.arguments as String).trim();
        if (path.isNotEmpty) _controller.add(path);
      }
    });
  }

  static const _pendingFileName = '.associated_joaiclient_backup_v1.json';
  static const _consumedFileName = '.associated_joaiclient_consumed_v1.json';
  static const _restartSuppressionFileName =
      '.associated_joaiclient_restart_v1';

  static Future<void> persistPendingPath(
    Directory appDataDirectory,
    String path,
  ) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return;
    final file = File(p.join(appDataDirectory.path, _pendingFileName));
    await file.writeAsString(
      jsonEncode(<String, String>{'path': normalized}),
      flush: true,
    );
  }

  static Future<String?> readPendingPath(Directory appDataDirectory) async {
    final file = File(p.join(appDataDirectory.path, _pendingFileName));
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['path'] is String) {
        final path = (decoded['path'] as String).trim();
        if (path.toLowerCase().endsWith('.joaiclient')) return path;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> clearPendingPath(Directory appDataDirectory) async {
    final file = File(p.join(appDataDirectory.path, _pendingFileName));
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 记录一次已经进入导入流程的关联文件请求。
  ///
  /// Windows 重启时会继承原始命令行；启动阶段用这条记录消费同一路径，
  /// 避免把内部重启再次识别成新的导入请求。
  static Future<void> persistConsumedPath(
    Directory appDataDirectory,
    String path,
  ) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return;
    final file = File(p.join(appDataDirectory.path, _consumedFileName));
    await file.writeAsString(
      jsonEncode(<String, String>{'path': normalized}),
      flush: true,
    );
  }

  /// 判断是否存在与 [path] 匹配的已处理请求。
  ///
  /// 启动过程中可能还会经过迁移并再次重启，因此这里只读取，不删除；
  /// 应在数据库准入完成后调用 [clearConsumedPath]。
  static Future<bool> hasConsumedPath(
    Directory appDataDirectory,
    String path,
  ) async {
    final file = File(p.join(appDataDirectory.path, _consumedFileName));
    if (!await file.exists()) return false;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final storedPath = decoded is Map && decoded['path'] is String
          ? (decoded['path'] as String).trim()
          : '';
      if (storedPath.isEmpty) {
        return false;
      }
      final matches = storedPath.toLowerCase() == path.trim().toLowerCase();
      return matches;
    } catch (_) {
      return false;
    }
  }

  /// 清理未绑定到本次启动命令行的已处理请求。
  static Future<void> clearConsumedPath(Directory appDataDirectory) async {
    final file = File(p.join(appDataDirectory.path, _consumedFileName));
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 标记下一次进程重启为导入后的内部重启。
  ///
  /// Windows 重启插件会继承原始命令行，因此新进程需要消费此标记，
  /// 避免把同一个关联文件再次当成新的打开请求。
  static Future<void> persistRestartSuppression(
    Directory appDataDirectory,
  ) async {
    final file = File(
      p.join(appDataDirectory.path, _restartSuppressionFileName),
    );
    await file.writeAsString('v1', flush: true);
  }

  /// 消费一次性重启标记，并始终删除它，避免影响后续正常启动。
  static Future<bool> consumeRestartSuppression(
    Directory appDataDirectory,
  ) async {
    final file = File(
      p.join(appDataDirectory.path, _restartSuppressionFileName),
    );
    if (!await file.exists()) return false;
    try {
      return (await file.readAsString()).trim() == 'v1';
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Future<void> clearRestartSuppression(
    Directory appDataDirectory,
  ) async {
    final file = File(
      p.join(appDataDirectory.path, _restartSuppressionFileName),
    );
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// 从桌面启动参数中找出通过文件关联打开的 JO-AIClient 备份。
///
/// Windows runner 会把命令行参数原样传给 Flutter。只接受以
/// `.joaiclient` 结尾的参数，避免把普通启动参数误当成备份路径。
String? associatedJoaiclientPathFromArguments(Iterable<String> arguments) {
  for (final raw in arguments) {
    final candidate = raw.trim();
    if (candidate.isEmpty) continue;
    if (candidate.toLowerCase().endsWith('.joaiclient')) return candidate;
  }
  return null;
}
