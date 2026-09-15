import 'dart:io' show Platform;
import 'package:flutter_background/flutter_background.dart';

/// 用于在 Android 上启用或禁用后台执行的简单管理器。
/// 在非 Android 平台上，所有调用均为空操作。
class AndroidBackgroundManager {
  static bool _initialized = false;

  /// 初始化插件一次，并请求所需权限。
  static Future<bool> ensureInitialized({
    required String notificationTitle,
    required String notificationText,
  }) async {
    if (!Platform.isAndroid) return false;
    if (_initialized) return true;
    try {
      final androidConfig = FlutterBackgroundAndroidConfig(
        notificationTitle: notificationTitle,
        notificationText: notificationText,
        notificationImportance: AndroidNotificationImportance.normal,
        // 必须用专门的单色剪影图。这里曾指向应用启动图标，但那是一张带不透明
        // 底的图，通知栏小图标只取 alpha 通道，整块都会被当成实心，显示成一个
        // 色块。ic_notification 是为此单独做的矢量剪影。
        notificationIcon: const AndroidResource(
          name: 'ic_notification',
          defType: 'drawable',
        ),
      );
      final ok = await FlutterBackground.initialize(
        androidConfig: androidConfig,
      );
      _initialized = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 启用或禁用后台执行。需要先运行 [ensureInitialized]。
  static Future<void> setEnabled(bool enable) async {
    if (!Platform.isAndroid) return;
    try {
      // 如果状态已经匹配，则直接返回
      try {
        final current = FlutterBackground.isBackgroundExecutionEnabled;
        if (current == enable) return;
      } catch (_) {}

      if (enable) {
        if (!_initialized) {
          throw StateError('Android background execution is not initialized.');
        }
        await FlutterBackground.enableBackgroundExecution();
      } else {
        // 尝试在不强制初始化的情况下禁用，以避免弹出权限提示
        try {
          await FlutterBackground.disableBackgroundExecution();
        } catch (_) {}
      }
    } catch (_) {
      // 忽略运行时错误；仅尽力而为
    }
  }

  /// 查询当前是否已启用后台执行的便捷方法。
  static Future<bool> isEnabled() async {
    if (!Platform.isAndroid) return false;
    try {
      return FlutterBackground.isBackgroundExecutionEnabled;
    } catch (_) {
      return false;
    }
  }
}
