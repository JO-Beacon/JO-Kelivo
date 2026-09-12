import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../utils/app_directories.dart';

part 'device_ledger_database.g.dart';

/// 单台设备的本机设置记录。
///
/// 这张表存的是「数据」而不是「设置」——App 永远不会把它当业务设置去读，
/// 只在备份时写入、恢复时取出、管理器里展示。因此它**刻意**放在业务库之外
/// 的独立 SQLite 文件里：完全覆盖恢复会用备份整库替换业务库，
/// 若册子住在业务库内，累积过的设备记录会被整个换掉。
class DeviceLocalSettingsLedgerRows extends Table {
  /// 设备指纹散列（sha256 前 32 位十六进制字符）。
  TextColumn get fingerprint => text()();

  /// 仅用于显示的设备名（电脑名称 / 手机型号）。
  TextColumn get deviceName => text()();

  /// 平台短名：windows / macos / linux / android / ios。
  TextColumn get platform => text()();

  /// 该记录代表的本机设置取值时刻（UTC）。
  DateTimeColumn get savedAtUtc => dateTime()();

  /// 10 个本机设置键的取值，JSON 对象；键序与内容由采集侧保证。
  TextColumn get valuesJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {fingerprint};
}

/// 册子库的键值状态表。
///
/// 目前只用于本机设置写回的幂等状态位：cutover 可续跑，若在"已 committed、
/// 写回尚未执行"之间进程被杀，下次启动会直接返回终态、不再进提交分支，
/// 写回就被静默跳过。因此需要一处状态位记录"已写回"。
/// 放在册子库里（业务库外、不参与恢复工作区的任何校验）。
class DeviceLedgerStateRows extends Table {
  /// 状态键。
  TextColumn get key => text()();

  /// 状态值（如 run id）。
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// 本机设置册子的独立库。
///
/// 与 [AppDatabase] 完全隔离：业务库 schemaVersion 保持不变、不写任何业务库
/// 迁移、也不参与 cutover 换库。库文件与业务库同目录（都走
/// [AppDirectories.getAppDataDirectory]），因此卸载清理策略自动一致。
@DriftDatabase(
  tables: [DeviceLocalSettingsLedgerRows, DeviceLedgerStateRows],
)
class DeviceLedgerDatabase extends _$DeviceLedgerDatabase {
  DeviceLedgerDatabase(super.executor);

  static const databaseFileName = 'device_local_settings_ledger.sqlite';

  /// 最近一次已完成本机设置写回的 run id（幂等标记）。
  static const lastAppliedRunKey = 'local_settings_writeback_run_v1';

  /// 本库自身的 schema 版本，从 1 起；未来升级与业务库互不干扰。
  @override
  int get schemaVersion => 1;

  /// 打开默认位置的册子库。
  factory DeviceLedgerDatabase.open({File? file}) {
    final databaseFile = file;
    if (databaseFile != null) {
      return DeviceLedgerDatabase(_openExecutor(databaseFile));
    }
    return DeviceLedgerDatabase(
      LazyDatabase(() async {
        final dir = await AppDirectories.getAppDataDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return _openExecutor(File('${dir.path}/$databaseFileName'));
      }),
    );
  }

  static QueryExecutor _openExecutor(File file) {
    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        database.execute('PRAGMA journal_mode = WAL;');
        database.execute('PRAGMA busy_timeout = 5000;');
        database.execute('PRAGMA synchronous = NORMAL;');
      },
    );
  }

  /// 该指纹是否已有记录。
  Future<bool> hasFingerprint(String fingerprint) async {
    final row = await (select(
      deviceLocalSettingsLedgerRows,
    )..where((t) => t.fingerprint.equals(fingerprint))).getSingleOrNull();
    return row != null;
  }

  /// 列出全部记录，按最近记录时间倒序。
  Future<List<DeviceLocalSettingsLedgerRow>> listAll({
    int? limit,
    int offset = 0,
  }) {
    final query = select(deviceLocalSettingsLedgerRows)
      ..orderBy([(t) => OrderingTerm.desc(t.savedAtUtc)]);
    if (limit != null) {
      query.limit(limit, offset: offset);
    } else if (offset > 0) {
      query.limit(-1, offset: offset);
    }
    return query.get();
  }

  /// 记录总数（管理器分页用）。
  Future<int> countAll() async {
    final expression = deviceLocalSettingsLedgerRows.fingerprint.count();
    final query = selectOnly(deviceLocalSettingsLedgerRows)
      ..addColumns([expression]);
    final row = await query.getSingle();
    return row.read(expression) ?? 0;
  }

  Future<DeviceLocalSettingsLedgerRow?> findByFingerprint(
    String fingerprint,
  ) {
    return (select(deviceLocalSettingsLedgerRows)
          ..where((t) => t.fingerprint.equals(fingerprint)))
        .getSingleOrNull();
  }

  /// 写入或覆盖一条记录（同指纹覆盖）。
  Future<void> upsert(DeviceLocalSettingsLedgerRowsCompanion entry) {
    return into(deviceLocalSettingsLedgerRows).insertOnConflictUpdate(entry);
  }

  Future<int> removeByFingerprint(String fingerprint) {
    return (delete(deviceLocalSettingsLedgerRows)
          ..where((t) => t.fingerprint.equals(fingerprint)))
        .go();
  }

  Future<int> clearAll() => delete(deviceLocalSettingsLedgerRows).go();

  /// 读取状态位。
  Future<String?> readState(String key) async {
    final row = await (select(
      deviceLedgerStateRows,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// 写入状态位（覆盖）。
  Future<void> writeState(String key, String value) {
    return into(deviceLedgerStateRows).insertOnConflictUpdate(
      DeviceLedgerStateRowsCompanion.insert(key: key, value: value),
    );
  }
}
