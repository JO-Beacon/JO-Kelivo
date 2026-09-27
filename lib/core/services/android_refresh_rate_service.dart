import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 高刷新率策略开关。
///
/// 默认（关闭）时原生侧固定到最高显示模式，这样连不采纳帧率投票的厂商
/// ROM（实测 OPPO/ColorOS）也能保持高刷；打开后改用 `Surface.setFrameRate`
/// 的自适应路线。该功能只有 Android 11（API 30）起才有效，低于此版本
/// 原生侧始终固定模式。
abstract final class AndroidRefreshRateService {
  /// 只存本机、随「本机设置」册子流转的偏好键。
  static const adaptiveKey = 'android_adaptive_refresh_rate_v1';

  static const MethodChannel _channel = MethodChannel('app.refresh_rate');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static int? _sdkInt;
  static bool _sdkIntLoaded = false;

  /// 是否支持自适应刷新率（Android 11 / API 30 起）。
  ///
  /// 版本要在启动时读一次并缓存（[ensureSdkIntLoaded]），避免在 widget 构建
  /// 里发起异步平台调用；读到之前返回 false，旧系统上不会出现无效开关。
  static bool get supportsAdaptiveRefreshRate =>
      isSupported && (_sdkInt ?? 0) >= 30;

  /// 启动时调用一次。读不到系统版本就不展示该开关。
  static Future<void> ensureSdkIntLoaded() async {
    if (!isSupported || _sdkIntLoaded) return;
    _sdkIntLoaded = true;
    try {
      _sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    } catch (_) {
      _sdkInt = null;
    }
  }

  @visibleForTesting
  static void debugSetSdkInt(int? value) {
    _sdkInt = value;
    _sdkIntLoaded = true;
  }

  static Future<void> setAdaptive(bool adaptive) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setAdaptiveRefreshRate', {
        'adaptive': adaptive,
      });
    } catch (_) {}
  }
}
