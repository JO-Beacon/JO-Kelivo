import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../database/chat_database_repository.dart';

/// 在不启动 drift isolate 的情况下读取数据库内迁移回执
/// （[ChatStorageMetaKeys.hiveMigrationComplete]）。WAL 模式允许在运行中的应用
/// 保持数据库打开时使用这个只读连接。
abstract final class HiveMigrationMarker {
  HiveMigrationMarker._();

  /// [databaseFile] 是否带有已完成的 Hive 迁移回执。
  ///
  /// 数据库缺失、不可读或结构损坏时，会保持旧版 Hive 清理闸门关闭；数据库准入问题
  /// 由 DatabaseInstallationGate 处理，而不是这里。
  static bool isMigrationComplete(File databaseFile) {
    if (!_hasSqliteHeader(databaseFile)) return false;
    final sqlite.Database database;
    try {
      database = sqlite.sqlite3.open(
        databaseFile.absolute.path,
        mode: sqlite.OpenMode.readOnly,
      );
    } on sqlite.SqliteException {
      return false;
    }
    try {
      final rows = database.select(
        'SELECT value FROM chat_storage_meta_rows WHERE key = ?;',
        [ChatStorageMetaKeys.hiveMigrationComplete],
      );
      return rows.length == 1 && rows.single['value'] == 'true';
    } on sqlite.SqliteException {
      return false;
    } finally {
      database.close();
    }
  }

  /// 在散落的 -wal/-shm 兄弟文件旁打开非 SQLite 文件时，即使在只读模式下，也可能使
  /// -shm 文件增长；而报告不得修改文件，因此会在 SQLite 接触路径之前检查魔数。
  ///
  static bool _hasSqliteHeader(File databaseFile) {
    const magic = 'SQLite format 3\x00';
    try {
      final file = databaseFile.openSync();
      try {
        final header = file.readSync(magic.length);
        return String.fromCharCodes(header) == magic;
      } finally {
        file.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }
}
