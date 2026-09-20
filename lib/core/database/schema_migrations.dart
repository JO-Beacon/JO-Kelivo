import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'app_database.dart';

/// 考虑把一个数据库文件升级之后的结果。
///
/// 文件本来就在 [toVersion] 时 [upgraded] 为 false，此时没有写入任何东西。
typedef DatabaseUpgradeOutcome = ({
  int fromVersion,
  int toVersion,
  bool upgraded,
});

/// 对某个 SQLite 文件运行 drift 的 schema 迁移器。
///
/// 这里是把“已发布但偏旧”的数据库变成当前 schema 的**唯一**入口。它刻意
/// 不掺策略：不做备份、事后不做校验、持久性交给调用方。
/// [ChatDatabaseRepository.migrateInstalledDatabase] 在它外面包了已安装库
/// 需要的“备份／校验／回滚”策略；恢复流程直接调它，因为暂存快照本身就是
/// 一份可丢弃的副本。
///
/// ## 如何新增一个 schema 版本
///
/// 1. 改 [AppDatabase] 里的表 DSL。新列一律**追加在表末尾**——
///    `ChatDatabaseRepository` 会逐列校验顺序，只有追加的列才能让
///    `ALTER TABLE ADD COLUMN` 与 `createAll` 保持一致。
/// 2. 升 `AppDatabase.currentSchemaVersion`，并把新版本号加进
///    `AppDatabase.publishedSchemaVersions`。
/// 3. 重新生成，然后逐项提交产物：
///    - `dart run build_runner build`
///    - `dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/app_database/`
///    - `dart run drift_dev schema generate drift_schemas/app_database/ test/core/database/generated_schema/`
///    - `dart run drift_dev schema steps drift_schemas/app_database/ lib/core/database/schema_versions.dart`
///    已经发布过的 `drift_schema_vN.json` 是冻结的：**绝不要**原地重导，
///    否则它锚定的那次迁移就不再描述实际发布过的东西。
/// 4. 在 `AppDatabase.migration` 的 `stepByStep` 调用里加上 `fromNToN+1`
///    回调。
/// 5. 把新列名追加到 `ChatDatabaseRepository._validateRawSchema` 里对应的
///    那份清单。
///
/// 注意 `stepByStep` 的一个坑：**新建的索引不会自动创建**。某一步如果
/// 引入了 `@TableIndex`，必须自己调 `m.create(schema.idxWhatever)`。
///
/// 另外要重新考虑下面的 [minimumReadableSchemaVersion]：把它留在低位，就是
/// 让旧版构建仍能读新备份；而这只在改动纯属追加时才安全。
///
/// ## 另一个版本号，以及把它们连起来的那个坑
///
/// schema 版本管的是 SQLite 载荷。**归档**格式——条目名与清单字段——有它
/// 自己的版本，即 `DataSync` 的 `_backupFormatVersion`，声明就写在它旁边。
/// 两者各自演进：某次发版可以只往备份里加一个可忽略的目录而不动 schema，
/// 而一个纯设置的备份根本没有 schema。各自升、各自声明。
///
/// 这两处（以及 `ChatDatabaseRepository.classifyInstalledDatabase`）反复出现
/// 的同一个错误，是拿**本构建**的词汇去判断**更新构建**的产物。在加任何
/// “这是不是我认识的东西”的判断之前，先想清楚判错的两种方向各会怎样：
/// 拒绝执行是可恢复的，覆盖或删除不是。
///
/// 备份声明的 schema 与本构建能读的范围之间的关系。
enum BackupSchemaVerdict {
  /// 由本 schema 亲自写出；原样恢复。
  current,

  /// 由更旧的已发布 schema 写出；向前迁移。
  needsUpgrade,

  /// 由更新的 schema 写出，且声明了本构建仍可读。
  /// 剥掉本构建不认识的内容后恢复。
  forwardCompatible,

  /// 由更新的 schema 写出，且没有做兼容声明，因此是否可读未知。
  /// 只有在用户知情同意后才可恢复。
  forwardUndeclared,

  /// 读不了：要么是更新的 schema 并声明需要更新的构建，要么是一个本构建
  /// 从未听过的版本。
  unreadable,
}

final class SchemaMigrations {
  SchemaMigrations._();

  /// 清单里用来声明“还能读这份备份的最旧 schema”的键。
  ///
  /// 每一个懂前向兼容的构建都会写它。本构建只要
  /// [AppDatabase.currentSchemaVersion] 不低于这个值，就可以在把不认识的
  /// 内容规范化掉之后恢复该备份。
  static const minimumReadableManifestKey = 'minimumReadableSchemaVersion';

  /// 本构建写出的备份能被读的最旧 schema。
  ///
  /// 前向兼容从 schema 2 才开始——schema 1 的构建除自己的版本外一律拒收
  /// ——所以这个值再低也没有意义。
  ///
  /// 任何一次**不是纯追加**的 schema 改动，都要把它升到
  /// [AppDatabase.currentSchemaVersion]：改名列、改变列的含义、在已有列里
  /// 引入旧构建会读错的新取值、收紧约束，都算。这种时候把它留在低位，等于
  /// 让旧构建静默导入它理解错的数据。
  static const minimumReadableSchemaVersion = 2;

  /// 依据清单对一份备份做分类。
  ///
  /// [declaredMinimumReadable] 是清单里的 [minimumReadableManifestKey]；
  /// 该键还不存在的旧备份（或写出时省略了它的构建）则为 null。
  static BackupSchemaVerdict classifyBackup({
    required int schemaVersion,
    int? declaredMinimumReadable,
  }) {
    final current = AppDatabase.currentSchemaVersion;
    if (schemaVersion == current) return BackupSchemaVerdict.current;
    if (schemaVersion < current) {
      return isPublished(schemaVersion)
          ? BackupSchemaVerdict.needsUpgrade
          // 一个低于我们、又从未发布过的版本并不存在；不要猜它是什么，
          // 直接拒绝。
          : BackupSchemaVerdict.unreadable;
    }
    if (declaredMinimumReadable == null) {
      return BackupSchemaVerdict.forwardUndeclared;
    }
    return declaredMinimumReadable <= current
        ? BackupSchemaVerdict.forwardCompatible
        : BackupSchemaVerdict.unreadable;
  }

  /// [version] 是不是本应用发布过的 schema。
  static bool isPublished(int version) =>
      AppDatabase.publishedSchemaVersions.contains(version);

  /// [version] 处的文件是否既能、也必须先升级再使用。
  static bool needsUpgrade(int version) =>
      isPublished(version) && version < AppDatabase.currentSchemaVersion;

  /// 读取 `PRAGMA user_version`，除此之外不碰 [file]。
  static int readSchemaVersion(File file) {
    final database = sqlite.sqlite3.open(
      file.absolute.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      return database.userVersion;
    } finally {
      database.close();
    }
  }

  /// 就地把 [file] 升到 [AppDatabase.currentSchemaVersion]。
  ///
  /// 已经在当前 schema 的文件保持不动。更新的版本或未发布的版本会抛
  /// `StateError('database_schema_version')`。
  ///
  /// 原子性由 drift 保证：`onUpgrade` 与 `PRAGMA user_version` 的写入共享
  /// 同一个事务，所以崩溃后文件要么完整停在旧 schema，要么完整停在新
  /// schema。
  static Future<DatabaseUpgradeOutcome> upgradeFileInPlace(File file) async {
    final installed = readSchemaVersion(file);
    if (installed == AppDatabase.currentSchemaVersion) {
      return (fromVersion: installed, toVersion: installed, upgraded: false);
    }
    if (!needsUpgrade(installed)) {
      throw StateError('database_schema_version');
    }

    final database = AppDatabase(AppDatabase.upgradeExecutor(file));
    try {
      // 强制把执行器打开，迁移器就是在这一步跑的。
      await database.customSelect('SELECT 1;').getSingle();
      // 把升级折叠回主文件，这样调用方看到的是一个自洽的数据库，
      // 快照里也不会留下附属文件。
      await database.customStatement('PRAGMA wal_checkpoint(TRUNCATE);');
    } finally {
      await database.close();
    }

    final resulting = readSchemaVersion(file);
    if (resulting != AppDatabase.currentSchemaVersion) {
      throw StateError('database_schema_version');
    }
    return (fromVersion: installed, toVersion: resulting, upgraded: true);
  }
}
