import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../../../utils/platform_utils.dart';

/// 本机设备身份。
///
/// [fingerprintHash] 是原始硬件标识的 sha256 前 32 个十六进制字符，
/// 属于单向散列，不存原文也不可反推；仅用于「同一台设备」的匹配。
/// [displayName] 是给人看的电脑名称 / 手机型号，[platform] 是平台短名。
@immutable
class DeviceIdentity {
  const DeviceIdentity({
    required this.fingerprintHash,
    required this.displayName,
    required this.platform,
  });

  final String fingerprintHash;
  final String displayName;
  final String platform;

  @override
  bool operator ==(Object other) =>
      other is DeviceIdentity &&
      other.fingerprintHash == fingerprintHash &&
      other.displayName == displayName &&
      other.platform == platform;

  @override
  int get hashCode => Object.hash(fingerprintHash, displayName, platform);

  @override
  String toString() =>
      'DeviceIdentity($platform, $displayName, ${fingerprintHash.substring(0, 8)}…)';
}

/// 采集本机设备身份的服务。
///
/// 任何一步失败都返回 null，功能整体静默降级——绝不能因为指纹采集失败
/// 而阻塞备份主流程。进程调用结果在内存中缓存，避免重复付出 PowerShell
/// 冷启动的开销。
abstract final class DeviceIdentityService {
  DeviceIdentityService._();

  static DeviceIdentity? _cached;
  static bool _resolved = false;

  /// 便于测试注入的采集入口。返回 null 或抛异常都按采集失败处理。
  @visibleForTesting
  static Future<DeviceIdentity?> Function()? debugCollectorOverride;

  /// 清空缓存（测试用）。
  @visibleForTesting
  static void resetCache() {
    _cached = null;
    _resolved = false;
  }

  /// 获取本机设备身份；采集失败返回 null。
  ///
  /// 结果在进程内缓存：桌面端读主板标识需要起一次系统进程
  /// （Windows 上 PowerShell 冷启动 100~300ms），只应发生一次。
  static Future<DeviceIdentity?> resolve() async {
    if (_resolved) return _cached;
    DeviceIdentity? identity;
    try {
      final collector = debugCollectorOverride;
      identity = collector != null ? await collector() : await _collect();
    } catch (_) {
      identity = null;
    }
    _cached = identity;
    _resolved = true;
    return identity;
  }

  static Future<DeviceIdentity?> _collect() async {
    if (PlatformUtils.isWindows) {
      return _collectWindows();
    }
    if (PlatformUtils.isMacOS) {
      return _collectMacOS();
    }
    if (PlatformUtils.isLinux) {
      return _collectLinux();
    }
    if (PlatformUtils.isAndroid) {
      return _collectAndroid();
    }
    if (PlatformUtils.isIOS) {
      return _collectIOS();
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // 桌面端：零新依赖，靠系统命令 / 系统文件读取主板级标识。
  // ---------------------------------------------------------------------

  static Future<DeviceIdentity?> _collectWindows() async {
    // 不用已弃用的 wmic；PowerShell 冷启动只在首次采集时付出一次。
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Get-CimInstance Win32_ComputerSystemProduct '
          '| Select-Object -ExpandProperty UUID',
    ]);
    if (result.exitCode != 0) return null;
    final uuid = (result.stdout as String).trim();
    if (!_isUsableHardwareId(uuid)) return null;
    final name = await _windowsComputerName();
    return _build(rawId: uuid, displayName: name, platform: 'windows');
  }

  static Future<String> _windowsComputerName() async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'$env:COMPUTERNAME',
    ]);
    final name = result.exitCode == 0 ? (result.stdout as String).trim() : '';
    return name.isEmpty ? 'Windows PC' : name;
  }

  static Future<DeviceIdentity?> _collectMacOS() async {
    final result = await Process.run('ioreg', [
      '-rd1',
      '-c',
      'IOPlatformExpertDevice',
    ]);
    if (result.exitCode != 0) return null;
    final uuid = _parseIoregValue(result.stdout as String, 'IOPlatformUUID');
    if (uuid == null || !_isUsableHardwareId(uuid)) return null;
    return _build(rawId: uuid, displayName: _macHostName(), platform: 'macos');
  }

  static String _macHostName() {
    final host = Platform.localHostname.trim();
    return host.isEmpty ? 'Mac' : host;
  }

  static Future<DeviceIdentity?> _collectLinux() async {
    var raw = await _readFirstNonEmptyLine('/etc/machine-id');
    raw ??= await _readFirstNonEmptyLine('/var/lib/dbus/machine-id');
    raw ??= await _readFirstNonEmptyLine('/sys/class/dmi/id/product_uuid');
    if (raw == null || !_isUsableHardwareId(raw)) return null;
    final host = Platform.localHostname.trim();
    return _build(
      rawId: raw,
      displayName: host.isEmpty ? 'Linux' : host,
      platform: 'linux',
    );
  }

  static Future<String?> _readFirstNonEmptyLine(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      for (final line in content.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) return trimmed;
      }
    } catch (_) {}
    return null;
  }

  /// 从 `ioreg` 输出中取出形如 `"IOPlatformUUID" = "XXXX"` 的值。
  static String? _parseIoregValue(String output, String key) {
    final match = RegExp('"$key"\\s*=\\s*"([^"]*)"').firstMatch(output);
    return match?.group(1);
  }

  // ---------------------------------------------------------------------
  // 移动端：走 device_info_plus（本功能唯一的新依赖）。
  // ---------------------------------------------------------------------

  static Future<DeviceIdentity?> _collectAndroid() async {
    final info = await DeviceInfoPlugin().androidInfo;
    final raw = info.id; // ANDROID_ID
    if (!_isUsableHardwareId(raw)) return null;
    final name = [
      info.brand,
      info.model,
    ].where((part) => part.trim().isNotEmpty).join(' ').trim();
    return _build(
      rawId: raw,
      displayName: name.isEmpty ? 'Android' : name,
      platform: 'android',
    );
  }

  static Future<DeviceIdentity?> _collectIOS() async {
    final info = await DeviceInfoPlugin().iosInfo;
    final raw = info.identifierForVendor;
    if (raw == null || !_isUsableHardwareId(raw)) return null;
    final name = info.name.trim();
    return _build(
      rawId: raw,
      displayName: name.isEmpty ? 'iPhone' : name,
      platform: 'ios',
    );
  }

  // ---------------------------------------------------------------------
  // 公共处理
  // ---------------------------------------------------------------------

  static DeviceIdentity _build({
    required String rawId,
    required String displayName,
    required String platform,
  }) {
    final digest = sha256.convert(utf8.encode(rawId.trim())).toString();
    return DeviceIdentity(
      // 前 32 个十六进制字符（128 bit）足够避免碰撞，也便于人眼核对。
      fingerprintHash: digest.substring(0, 32),
      displayName: displayName,
      platform: platform,
    );
  }

  /// 判断硬件标识是否可用。
  ///
  /// 部分 Windows 主板未烧录 UUID，读出来是全 0 或全 F；这类「假 UUID」
  /// 必须判为采集失败，否则一大批设备会撞成同一条指纹记录。
  @visibleForTesting
  static bool isUsableHardwareId(String raw) => _isUsableHardwareId(raw);

  static bool _isUsableHardwareId(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return false;
    // 去掉常见分隔符后只剩 0 或只剩 F，说明是未烧录的占位值。
    final compact = value.replaceAll(RegExp(r'[-:\s{}]'), '');
    if (compact.isEmpty) return false;
    if (RegExp(r'^[0]+$').hasMatch(compact)) return false;
    if (RegExp(r'^[fF]+$').hasMatch(compact)) return false;
    return true;
  }
}
