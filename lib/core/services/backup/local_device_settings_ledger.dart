import 'dart:convert';

import '../device/device_identity.dart';
import '../../database/business_settings_router.dart';
import '../../database/device_ledger_database.dart';
import 'backup_settings_validator.dart';

/// 一条待并入 / 待展示的设备记录。
class DeviceSettingsRecord {
  const DeviceSettingsRecord({
    required this.fingerprint,
    required this.deviceName,
    required this.platform,
    required this.savedAtUtc,
    required this.values,
  });

  final String fingerprint;
  final String deviceName;
  final String platform;
  final DateTime savedAtUtc;

  /// 9 个本机设置键的取值；键必须是 [BusinessKeyRegistry.localOnlyKeys]
  /// 的成员。
  final Map<String, Object?> values;

  String get valuesJson => jsonEncode(values);

  /// 从库行还原（values_json 损坏时返回 null，交由调用方跳过该条）。
  static DeviceSettingsRecord? fromRow(DeviceLocalSettingsLedgerRow row) {
    final values = decodeValues(row.valuesJson);
    if (values == null) return null;
    return DeviceSettingsRecord(
      fingerprint: row.fingerprint,
      deviceName: row.deviceName,
      platform: row.platform,
      savedAtUtc: row.savedAtUtc,
      values: values,
    );
  }

  /// 解析并校验 values_json；任何形状问题都返回 null。
  static Map<String, Object?>? decodeValues(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final values = <String, Object?>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        if (key is! String) return null;
        // 只接受本机设置键；绝不能把 restore_ 前缀之类的内部键装进来，
        // 所以这里用 localOnlyKeys 集合成员判定，而不是 classify()。
        if (!BusinessKeyRegistry.localOnlyKeys.contains(key)) continue;
        values[key] = entry.value;
      }
      return values;
    } catch (_) {
      return null;
    }
  }
}

/// 本机设置册子的读写服务。
///
/// 册子是「数据」：App 永远不会把它当设置读。合并路径与业务库写栅栏
/// （runWithRestoreWriteFence）无关——它在业务库外的独立文件里，
/// 不参与换库，无需「换库前暂存、换库后并回」的补救逻辑。
class LocalDeviceSettingsLedger {
  LocalDeviceSettingsLedger({DeviceLedgerDatabase? database})
    : _database = database ?? DeviceLedgerDatabase.open();

  final DeviceLedgerDatabase _database;

  DeviceLedgerDatabase get database => _database;

  Future<void> close() => _database.close();

  // -------------------------------------------------------------------
  // 写入
  // -------------------------------------------------------------------

  /// 把本机此刻的 9 键值刷进册子（导出"带"档前的关键一步）。
  ///
  /// 只接受 [BusinessKeyRegistry.localOnlyKeys] 的成员，并复用
  /// [BackupSettingsValidator.validateValue] 校验取值类型。
  /// 调用方需保证 [identity] 非空（指纹采集失败时不调用）。
  Future<void> upsertCurrent(
    DeviceIdentity identity,
    Map<String, Object?> values, {
    DateTime? savedAtUtc,
  }) {
    return upsert(
      DeviceSettingsRecord(
        fingerprint: identity.fingerprintHash,
        deviceName: identity.displayName,
        platform: identity.platform,
        savedAtUtc: savedAtUtc ?? DateTime.now().toUtc(),
        values: filterValues(values),
      ),
    );
  }

  /// 同指纹覆盖为新记录：包内 savedAt 较新或并列时覆盖，较旧则保留本机。
  Future<void> upsert(DeviceSettingsRecord record) async {
    final existing = await _database.findByFingerprint(record.fingerprint);
    if (existing != null && existing.savedAtUtc.isAfter(record.savedAtUtc)) {
      return;
    }
    await _database.upsert(
      DeviceLocalSettingsLedgerRowsCompanion.insert(
        fingerprint: record.fingerprint,
        deviceName: record.deviceName,
        platform: record.platform,
        savedAtUtc: record.savedAtUtc,
        valuesJson: record.valuesJson,
      ),
    );
  }

  /// 把包内解析出的记录全量并入正本册子。
  ///
  /// 无论恢复模式、无论用户选择，这一步**无条件**执行——记录属于累积数据，
  /// 扔掉会打断累积链路。单条损坏由调用方先行过滤。
  Future<void> mergeFromArchive(Iterable<DeviceSettingsRecord> records) async {
    for (final record in records) {
      await upsert(record);
    }
  }

  // -------------------------------------------------------------------
  // 读取
  // -------------------------------------------------------------------

  Future<List<DeviceSettingsRecord>> getAll({
    int? limit,
    int offset = 0,
  }) async {
    final rows = await _database.listAll(limit: limit, offset: offset);
    return [
      for (final row in rows)
        if (DeviceSettingsRecord.fromRow(row) case final record?) record,
    ];
  }

  Future<int> countAll() => _database.countAll();

  Future<DeviceSettingsRecord?> findByFingerprint(String fingerprint) async {
    final row = await _database.findByFingerprint(fingerprint);
    if (row == null) return null;
    return DeviceSettingsRecord.fromRow(row);
  }

  Future<bool> hasFingerprint(String fingerprint) =>
      _database.hasFingerprint(fingerprint);

  /// 导出用：按设备拆成 `Map<包内条目名, JSON 字符串>`。
  ///
  /// 条目名形如 `device_local_settings/<指纹散列>.json`，每台设备一个
  /// 独立文件——单设备文件损坏只影响一台，manifest 逐文件校验。
  Future<Map<String, String>> exportPerDevice() async {
    final records = await getAll();
    return {
      for (final record in records)
        'device_local_settings/${record.fingerprint}.json': _payloadJson(
          record,
        ),
    };
  }

  String _payloadJson(DeviceSettingsRecord record) {
    return jsonEncode({
      'fingerprint': record.fingerprint,
      'deviceName': record.deviceName,
      'platform': record.platform,
      'savedAtUtc': record.savedAtUtc.toIso8601String(),
      'values': record.values,
    });
  }

  // -------------------------------------------------------------------
  // 删除
  // -------------------------------------------------------------------

  Future<void> removeDevice(String fingerprint) =>
      _database.removeByFingerprint(fingerprint);

  Future<void> clearAll() => _database.clearAll();

  // -------------------------------------------------------------------
  // 纯函数
  // -------------------------------------------------------------------

  /// 只保留 localOnlyKeys 成员并对取值做类型校验；不合法的键直接丢弃。
  static Map<String, Object?> filterValues(Map<String, Object?> raw) {
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      if (!BusinessKeyRegistry.localOnlyKeys.contains(entry.key)) continue;
      final value = entry.value;
      if (value == null) continue;
      try {
        BackupSettingsValidator.validateValue(entry.key, value);
      } catch (_) {
        continue;
      }
      result[entry.key] = value;
    }
    return result;
  }

  /// 解析包内的单设备文件；形状或内容不合法时返回 null（跳过该设备）。
  static DeviceSettingsRecord? parseArchiveFile(
    String entryName,
    String content,
  ) {
    final name = entryName.split('/').last;
    if (!name.endsWith('.json')) return null;
    final fingerprint = name.substring(0, name.length - '.json'.length);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(fingerprint)) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      final valuesRaw = decoded['values'];
      if (valuesRaw is! Map) return null;
      final values = <String, Object?>{};
      for (final entry in valuesRaw.entries) {
        final key = entry.key;
        if (key is! String) continue;
        values[key] = entry.value;
      }
      final savedAt =
          DateTime.tryParse(decoded['savedAtUtc'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      return DeviceSettingsRecord(
        fingerprint: fingerprint,
        deviceName: (decoded['deviceName'] as String?) ?? 'Unknown',
        platform: (decoded['platform'] as String?) ?? 'unknown',
        savedAtUtc: savedAt.toUtc(),
        values: filterValues(values),
      );
    } catch (_) {
      return null;
    }
  }
}
