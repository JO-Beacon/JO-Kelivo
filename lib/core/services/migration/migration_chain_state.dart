import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final class MigrationChainState {
  const MigrationChainState({
    required this.sourceKind,
    required this.backupPath,
    required this.stage,
    this.externalBackupSaved = false,
  });

  final String sourceKind;
  final String? backupPath;
  final String stage;
  final bool externalBackupSaved;

  Map<String, Object?> toJson() => {
    'format': 'jo-kelivo-migration-chain',
    'formatVersion': 1,
    'sourceKind': sourceKind,
    'backupPath': backupPath,
    'stage': stage,
    'externalBackupSaved': externalBackupSaved,
  };

  static MigrationChainState fromJson(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw['format'] != 'jo-kelivo-migration-chain' ||
        raw['formatVersion'] != 1 ||
        raw['sourceKind'] is! String ||
        raw['stage'] is! String ||
        (raw['externalBackupSaved'] != null &&
            raw['externalBackupSaved'] is! bool) ||
        (raw['backupPath'] != null && raw['backupPath'] is! String)) {
      throw const FormatException('migration_chain_state');
    }
    return MigrationChainState(
      sourceKind: raw['sourceKind'] as String,
      backupPath: raw['backupPath'] as String?,
      stage: raw['stage'] as String,
      externalBackupSaved: raw['externalBackupSaved'] as bool? ?? false,
    );
  }
}

final class MigrationChainStateStore {
  MigrationChainStateStore(this.appDataDirectory);

  static const fileName = '.migration_chain_v1.json';
  final Directory appDataDirectory;

  File get file => File(p.join(appDataDirectory.path, fileName));

  Future<MigrationChainState?> read() async {
    if (!await file.exists()) return null;
    try {
      return MigrationChainState.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } catch (_) {
      throw const FormatException('migration_chain_state');
    }
  }

  Future<void> write(MigrationChainState state) async {
    await appDataDirectory.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
    if (Platform.isWindows && await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}
