import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueNotifier, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 把应用主题的颜色交给 Windows，让系统标题栏、窗口边框与界面连成一片。
///
/// 只有 Windows 11（build 22000）及以上会采纳这些颜色。更早的系统会拒绝
/// 这几个窗口属性，窗口保持系统自带的外观——功能不受影响，只是标题栏仍是
/// 系统给的灰色。
class WindowAppearanceSync {
  WindowAppearanceSync._();

  static const MethodChannel _channel = MethodChannel('app.window_appearance');

  static int? _lastCaption;
  static int? _lastText;
  static int? _lastBorder;
  static bool? _lastDark;

  /// 系统「Windows 模式」的明暗，读不到时为 null。
  ///
  /// Windows 的个性化设置里有两个独立的开关：应用跟随「应用模式」，而任务栏、
  /// 通知区域和开始菜单跟随「Windows 模式」，后者可以和应用自身的明暗完全不同。
  ///
  /// 托盘图形曾按这个值切换，现已改为跟随应用主题（见 desktop_tray_controller.dart
  /// 的 applyBrightness），目前没有调用方。保留是因为它是任务栏底色唯一的来源，
  /// 若以后想让托盘跟随任务栏而不是应用主题，这里可以直接复用。
  static final ValueNotifier<Brightness?> systemBrightness =
      ValueNotifier<Brightness?>(null);

  static bool _watchingSystemBrightness = false;

  /// 开始跟踪系统「Windows 模式」：读一次初值，之后系统切换时更新
  /// [systemBrightness]。重复调用是安全的，监听只装一次。
  static Future<void> watchSystemBrightness() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }

    if (!_watchingSystemBrightness) {
      _watchingSystemBrightness = true;
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'systemBrightnessChanged') {
          final bool? dark = call.arguments as bool?;
          if (dark != null) {
            systemBrightness.value = dark ? Brightness.dark : Brightness.light;
          }
        }
        return null;
      });
    }

    if (systemBrightness.value == null) {
      await refreshSystemBrightness();
    }
  }

  /// 主动读一次系统「Windows 模式」的明暗；读不到时返回 null。
  static Future<Brightness?> refreshSystemBrightness() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return null;
    }

    try {
      final bool? dark =
          await _channel.invokeMethod<bool>('getSystemBrightness');
      if (dark == null) {
        return null;
      }
      final Brightness value = dark ? Brightness.dark : Brightness.light;
      systemBrightness.value = value;
      return value;
    } catch (_) {
      return null;
    }
  }

  /// 用当前主题同步窗口标题栏的外观；值没有变化时不会发出通道调用。
  static Future<void> sync(ThemeData theme) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }

    // 取界面主体的背景色：导航栏、设置页、翻译页用的都是它，
    // 这样标题栏才能和内容真正连成一片。
    final Color background = theme.scaffoldBackgroundColor;
    final Color foreground = theme.colorScheme.onSurface;
    final bool dark = theme.brightness == Brightness.dark;

    final int caption = background.toARGB32() & 0xFFFFFF;
    final int text = foreground.toARGB32() & 0xFFFFFF;

    // 窗口边框沿用界面里直接描边的颜色（outline）。系统窗口边框不接受透明
    // 度，所以先把它合成到背景上取实色。outline 与背景的差值在九个主题下
    // 都固定为 70（见 palettes.dart），轮廓在各主题下轻重一致。
    final int border = Color.alphaBlend(
          theme.colorScheme.outline,
          background,
        ).toARGB32() &
        0xFFFFFF;

    if (_lastCaption == caption &&
        _lastText == text &&
        _lastBorder == border &&
        _lastDark == dark) {
      return;
    }
    _lastCaption = caption;
    _lastText = text;
    _lastBorder = border;
    _lastDark = dark;

    try {
      await _channel.invokeMethod<void>('setCaptionAppearance', <String, Object>{
        'dark': dark,
        'useCustomColors': true,
        'captionColor': caption,
        'textColor': text,
        'borderColor': border,
      });
    } catch (_) {
      // 旧系统不认这些颜色，失败是预期内的。
    }
  }
}
