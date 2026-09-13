import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:restart_app/restart_app.dart';

import '../core/services/logging/flutter_logger.dart';

abstract final class PlatformUtils {
  PlatformUtils._();

  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  static bool get isDesktopTarget =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  static bool get isMobileTarget =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isMacOS => Platform.isMacOS;

  static bool get isWindows => Platform.isWindows;

  static bool get isLinux => Platform.isLinux;

  static bool get isAndroid => Platform.isAndroid;

  static bool get isIOS => Platform.isIOS;

  static Future<void> restartApp() async {
    // 先留下本次重启的标记，再交还日志文件句柄：新进程启动时也会写同一个
    // 日志文件，两个进程同时持句柄容易写出交错内容。
    FlutterLogger.stage('restart requested');
    final wasLogging = FlutterLogger.enabled;
    await FlutterLogger.setEnabled(false);
    try {
      if (defaultTargetPlatform == TargetPlatform.android || isDesktopTarget) {
        final result = await Restart.restartApp(mode: RestartMode.process);
        if (!result.success) {
          throw StateError('restart_app:${result.code ?? 'unknown'}');
        }
      } else {
        exit(0);
      }
    } catch (_) {
      // 重启没成功，当前进程还要继续用，把日志恢复回去。
      if (wasLogging) await FlutterLogger.setEnabled(true);
      rethrow;
    }
  }
}
