import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup/restore_durability.dart';

final class LegacyHiveArtifact {
  const LegacyHiveArtifact({required this.name, required this.bytes});

  final String name;
  final int bytes;

  Map<String, Object> toJson() => {'name': name, 'bytes': bytes};
}

enum LegacyRetirementState { deleting, completed }

final class LegacyRetirementReceipt {
  const LegacyRetirementReceipt({
    required this.state,
    required this.requestedAtUtc,
    required this.completedAtUtc,
    required this.deletedArtifacts,
  });

  final LegacyRetirementState state;
  final DateTime requestedAtUtc;
  final DateTime? completedAtUtc;
  final List<LegacyHiveArtifact> deletedArtifacts;
}

/// 仅在用户明确操作后删除冻结的 Hive 工件族。
///
/// 迁移准入在存储 UI 可用之前处理。UI 通过结合数据库内迁移回执和
/// [inspectHiveArtifacts] 来决定是否提供清理。删除通过单个标记文件保持崩溃可恢复：
/// 在第一次 unlink 之前发布 `deleting` 标记，因此中断的清理会在下次请求时继续。
/// 缺失或格式错误的标记绝不会阻塞清理，因为删除是幂等的。
final class LegacyDataRetirementService {
  LegacyDataRetirementService(
    this.appDataDirectory, {
    RestoreDurability? durability,
    this.afterDeletingReceiptPublished,
    this.clock,
  }) : durability = durability ?? RestorePlatformDurability();

  static const hiveArtifactNames = <String>{
    'conversations.hive',
    'messages.hive',
    'tool_events_v1.hive',
  };
  static const _markerFileName = '.hive_retirement.json';
  static const _markerFormat = 'kelivo.hive-retirement-marker';
  static const _markerFormatVersion = 1;

  final Directory appDataDirectory;
  final RestoreDurability durability;
  final Future<void> Function()? afterDeletingReceiptPublished;
  final DateTime Function()? clock;

  File get _markerFile => File(p.join(appDataDirectory.path, _markerFileName));

  Future<List<LegacyHiveArtifact>> inspectHiveArtifacts() async {
    final artifacts = <LegacyHiveArtifact>[];
    for (final name in hiveArtifactNames.toList()..sort()) {
      final file = File(p.join(appDataDirectory.path, name));
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) {
        throw StateError('legacy_retirement_artifact_type');
      }
      artifacts.add(LegacyHiveArtifact(name: name, bytes: await file.length()));
    }
    return List.unmodifiable(artifacts);
  }

  Future<LegacyRetirementReceipt> retireHiveArtifacts() async {
    final existing = await readReceipt();
    late final LegacyRetirementReceipt deleting;
    if (existing?.state == LegacyRetirementState.deleting) {
      deleting = existing!;
    } else {
      final artifacts = await inspectHiveArtifacts();
      if (artifacts.isEmpty && existing != null) return existing;
      deleting = await _publishReceipt(
        state: LegacyRetirementState.deleting,
        requestedAtUtc: (clock?.call() ?? DateTime.now()).toUtc(),
        completedAtUtc: null,
        artifacts: artifacts,
      );
      await afterDeletingReceiptPublished?.call();
    }

    for (final artifact in deleting.deletedArtifacts) {
      final file = File(p.join(appDataDirectory.path, artifact.name));
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file ||
          await file.length() != artifact.bytes) {
        throw StateError('legacy_retirement_artifact_changed');
      }
      await file.delete();
      await durability.syncDirectory(appDataDirectory, fullBarrier: true);
    }
    return _publishReceipt(
      state: LegacyRetirementState.completed,
      requestedAtUtc: deleting.requestedAtUtc,
      completedAtUtc: (clock?.call() ?? DateTime.now()).toUtc(),
      artifacts: deleting.deletedArtifacts,
    );
  }

  /// 返回最新标记；标记缺失或格式错误时返回 null。
  /// 格式错误的标记故意不作为错误：该标记仅携带恢复元数据，缺少它时清理仍必须可用。
  Future<LegacyRetirementReceipt?> readReceipt() async {
    if (await FileSystemEntity.type(_markerFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      return _decodeReceipt(await _markerFile.readAsString());
    } on FormatException {
      return null;
    }
  }

  Future<LegacyRetirementReceipt> _publishReceipt({
    required LegacyRetirementState state,
    required DateTime requestedAtUtc,
    required DateTime? completedAtUtc,
    required List<LegacyHiveArtifact> artifacts,
  }) async {
    final body = <String, Object?>{
      'format': _markerFormat,
      'formatVersion': _markerFormatVersion,
      'state': state.name,
      'requestedAtUtc': requestedAtUtc.toIso8601String(),
      'completedAtUtc': completedAtUtc?.toIso8601String(),
      'artifacts': artifacts.map((artifact) => artifact.toJson()).toList(),
    };
    final temporary = File(
      p.join(
        appDataDirectory.path,
        '.hive_retirement_${pid}_${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await temporary.create(exclusive: true);
      await durability.restrictFile(temporary);
      await temporary.writeAsString(jsonEncode(body), flush: true);
      await durability.syncFile(temporary, fullBarrier: true);
      // renameAndSync 会拒绝已存在的目标，因此分两步替换。
      // 在删除和重命名之间发生崩溃只会丢失恢复元数据，
      // retireHiveArtifacts 会通过一次全新检查重建该元数据。
      if (await _markerFile.exists()) {
        await _markerFile.delete();
      }
      await durability.renameAndSync(
        source: temporary,
        targetPath: _markerFile.path,
      );
      return _decodeReceipt(await _markerFile.readAsString());
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static LegacyRetirementReceipt _decodeReceipt(String content) {
    final value = jsonDecode(content);
    if (value is! Map<String, dynamic> ||
        value['format'] != _markerFormat ||
        value['formatVersion'] != _markerFormatVersion) {
      throw const FormatException('legacy_retirement_marker');
    }
    final state = LegacyRetirementState.values
        .where((candidate) => candidate.name == value['state'])
        .firstOrNull;
    final requestedAt = DateTime.tryParse(
      value['requestedAtUtc']?.toString() ?? '',
    );
    final completedRaw = value['completedAtUtc'];
    final completedAt = completedRaw == null
        ? null
        : DateTime.tryParse(completedRaw.toString());
    final artifacts = _decodeArtifacts(value['artifacts']);
    if (state == null ||
        requestedAt == null ||
        !requestedAt.isUtc ||
        (completedRaw != null && (completedAt == null || !completedAt.isUtc)) ||
        (state == LegacyRetirementState.deleting && completedAt != null) ||
        (state == LegacyRetirementState.completed && completedAt == null)) {
      throw const FormatException('legacy_retirement_marker');
    }
    return LegacyRetirementReceipt(
      state: state,
      requestedAtUtc: requestedAt,
      completedAtUtc: completedAt,
      deletedArtifacts: artifacts,
    );
  }

  static List<LegacyHiveArtifact> _decodeArtifacts(Object? value) {
    if (value is! List) {
      throw const FormatException('legacy_retirement_artifacts');
    }
    final artifacts = <LegacyHiveArtifact>[];
    final names = <String>{};
    for (final item in value) {
      if (item is! Map ||
          item['name'] is! String ||
          !hiveArtifactNames.contains(item['name']) ||
          !names.add(item['name'] as String) ||
          item['bytes'] is! int ||
          (item['bytes'] as int) < 0) {
        throw const FormatException('legacy_retirement_artifacts');
      }
      artifacts.add(
        LegacyHiveArtifact(
          name: item['name'] as String,
          bytes: item['bytes'] as int,
        ),
      );
    }
    artifacts.sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(artifacts);
  }
}
