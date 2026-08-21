import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// macOS 专用 MethodChannel 的轻量封装，用于获取或设置
/// NSWindow 窗口原点（Cocoa 坐标，原点在左下角）。
class MacOSWindowPosition {
  static const MethodChannel _chan = MethodChannel('app.windowPosition');

  static bool get isSupported => !kIsWeb && Platform.isMacOS;

  /// 以 Cocoa 坐标返回窗口原点（frame.origin.x/y）。
  static Future<Offset> getOrigin() async {
    if (!isSupported) {
      throw StateError('MacOSWindowPosition used on unsupported platform');
    }
    final List<dynamic> res = await _chan.invokeMethod('getWindowOrigin');
    final dx = (res[0] as num).toDouble();
    final dy = (res[1] as num).toDouble();
    return Offset(dx, dy);
  }

  /// 设置窗口原点（frame.origin.x/y），并限制在可见屏幕范围内。
  static Future<bool> setOrigin(Offset origin) async {
    if (!isSupported) return false;
    final ok = await _chan.invokeMethod('setWindowOrigin', <double>[
      origin.dx,
      origin.dy,
    ]);
    return ok == true;
  }

  /// 当前屏幕的可见区域（x、y、宽、高），使用 Cocoa 坐标。
  static Future<Rect?> getCurrentVisibleFrame() async {
    if (!isSupported) return null;
    final List<dynamic> res = await _chan.invokeMethod(
      'getVisibleFrameForCurrentScreen',
    );
    final x = (res[0] as num).toDouble();
    final y = (res[1] as num).toDouble();
    final w = (res[2] as num).toDouble();
    final h = (res[3] as num).toDouble();
    return Rect.fromLTWH(x, y, w, h);
  }
}
