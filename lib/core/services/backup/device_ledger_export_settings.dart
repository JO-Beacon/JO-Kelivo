import 'package:shared_preferences/shared_preferences.dart';

import '../../database/business_settings_router.dart';
import '../device/device_identity.dart';
import 'local_device_settings_ledger.dart';

/// 「带 / 不带」本机设置档位的记忆（存 SharedPreferences）。
///
/// 首档初始为「不带」（= 今天行为，无推荐含义）。
abstract final class DeviceLedgerExportSettings {
  DeviceLedgerExportSettings._();

  static const _key = 'backup_include_device_local_settings_v1';

  /// 上次选择：true = 带，false = 不带。
  static Future<bool> includeLedger() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  static Future<void> setIncludeLedger(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

/// 一次导出需要携带的册子内容，以及是否成功刷新了本机当前值。
class LedgerExportPayload {
  const LedgerExportPayload({
    required this.entries,
    required this.localDeviceRecognized,
  });

  /// `Map<包内条目名, JSON 字符串>`；空表示退化到「不带」的包结构。
  final Map<String, String> entries;

  /// 是否成功识别本机设备。
  ///
  /// 为 false 但 [entries] 非空，说明历史档案照常传递、只是本机当前值
  /// 没能刷新，导出结果应提示"未能识别本机设备，本次未包含本机当前设置"。
  final bool localDeviceRecognized;
}

/// 组装「带」档导出所需的册子内容。
///
/// 两种降级（条件与结果不同，不要混）：
/// - 册子为空（一台设备记录都没有）→ entries 为空，退化为「不带」的包结构；
/// - 指纹采集失败但册子非空 → **仍然导出册子**（历史档案照常传递，扔掉
///   会打断累积链路），只是本机当前值无法刷新、不进包。
abstract final class DeviceLedgerExportCollector {
  DeviceLedgerExportCollector._();

  static Future<LedgerExportPayload> collect() async {
    LocalDeviceSettingsLedger? ledger;
    try {
      ledger = LocalDeviceSettingsLedger();
      final identity = await DeviceIdentityService.resolve();
      if (identity != null) {
        final current = await _readCurrentValues();
        // 关键步骤：把本机此刻的值刷进册子。漏掉的话包里带的是上次备份时的
        // 旧值，用户刚改的设置带不出去。
        await ledger.upsertCurrent(identity, current);
      }
      final entries = await ledger.exportPerDevice();
      return LedgerExportPayload(
        entries: entries,
        localDeviceRecognized: identity != null,
      );
    } catch (_) {
      return const LedgerExportPayload(
        entries: <String, String>{},
        localDeviceRecognized: false,
      );
    } finally {
      await ledger?.close();
    }
  }

  /// 采集本机当前的 10 键值（含档位开关自身）。
  ///
  /// 只用 [BusinessKeyRegistry.localOnlyKeys] 集合成员判定——**不要**用
  /// `classify()`，它会把 `restore_` 前缀的键也算作 localOnly，
  /// 采进来会污染册子。
  static Future<Map<String, Object?>> _readCurrentValues() async {
    final prefs = await SharedPreferences.getInstance();
    final values = <String, Object?>{};
    for (final key in BusinessKeyRegistry.localOnlyKeys) {
      if (!prefs.containsKey(key)) continue;
      final value = prefs.get(key);
      if (value != null) values[key] = value;
    }
    return values;
  }
}
