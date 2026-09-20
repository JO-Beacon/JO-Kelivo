import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../database/business_settings_router.dart';
import 'local_device_settings_ledger.dart';

/// 把册子里记录的 10 个本机设置键写回本机。
///
/// 这是唯一一处「把备份里的值落到 SharedPreferences」的地方，两个调用方：
/// - 合并保留模式：恢复流程内**逐键补缺**（就地写回，不重启）；
/// - 完全覆盖模式：冷重启后切库成功时**直接采纳**（在启动门里）。
///
/// 刻意不做数值规范化：按原类型写回对应 API（double / bool / StringList）。
abstract final class DeviceLocalSettingsWriter {
  DeviceLocalSettingsWriter._();

  /// 逐键补缺：本机已有该键一律不动，只有本机缺少该键才用备份值补上。
  ///
  /// 返回实际写入的键数（0 表示什么都没写）。
  static Future<int> applyMissingOnly(Map<String, Object?> values) async {
    final prefs = await SharedPreferences.getInstance();
    var written = 0;
    for (final entry in values.entries) {
      if (prefs.containsKey(entry.key)) continue;
      if (await _write(prefs, entry.key, entry.value)) written++;
    }
    return written;
  }

  /// 直接采纳：本机已有的同名设置项也一并被备份值覆盖。
  ///
  /// 返回实际写入的键数。这是完全覆盖模式的行为（用户 2026-09-10 确认），
  /// 刻意与 [applyMissingOnly] 相区分，不要「顺手」统一。
  static Future<int> applyOverwrite(Map<String, Object?> values) async {
    final prefs = await SharedPreferences.getInstance();
    var written = 0;
    for (final entry in values.entries) {
      if (await _write(prefs, entry.key, entry.value)) written++;
    }
    return written;
  }

  static Future<bool> _write(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    try {
      switch (value) {
        case final double v:
          await prefs.setDouble(key, v);
        case final int v:
          // 窗口值历史上可能是 int；统一落到 double 更稳妥。
          await prefs.setDouble(key, v.toDouble());
        case final bool v:
          await prefs.setBool(key, v);
        case final List<Object?> v when v.every((item) => item is String):
          await prefs.setStringList(key, v.cast<String>());
        default:
          return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 从候选目录里读回本机设置记录。
///
/// 完全覆盖模式下写回发生在冷重启之后的启动门里，那时能读的只有候选目录
/// 里那份册子文件（`device_local_settings/<指纹>.json`）——**不能**改读册子
/// 正本，因为册子合并是 upsert 取新语义，本机记录较新时册子里存的已经不是
/// 备份里的那个值。
abstract final class CandidateLedgerReader {
  CandidateLedgerReader._();

  /// 读取候选目录中匹配 [fingerprint] 的设备记录；不存在或损坏返回 null。
  static DeviceSettingsRecord? readForDevice({
    required Directory candidateDirectory,
    required String fingerprint,
  }) {
    try {
      final file = File(
        p.join(
          candidateDirectory.path,
          'device_local_settings',
          '$fingerprint.json',
        ),
      );
      if (!file.existsSync()) return null;
      return LocalDeviceSettingsLedger.parseArchiveFile(
        'device_local_settings/$fingerprint.json',
        file.readAsStringSync(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 候选目录里的册子文件路径（供启动门推导，勿硬编码 run 位置）。
  static String ledgerFilePath(
    Directory candidateDirectory,
    String fingerprint,
  ) {
    return p.join(
      candidateDirectory.path,
      'device_local_settings',
      '$fingerprint.json',
    );
  }

  /// 判定某个键是否属于本机设置集合。
  static bool isLocalOnlyKey(String key) =>
      BusinessKeyRegistry.localOnlyKeys.contains(key);
}
