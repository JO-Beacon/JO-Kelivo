import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' as system;
import 'package:haptic_feedback/haptic_feedback.dart' as hfp;

/// 使用 `haptic_feedback` 插件的集中式轻柔触感。
///
/// 这些辅助方法有意保持调用即发即忘（不 await），并且
/// 在不支持插件的平台上也是安全的（错误会被吞掉）。
class Haptics {
  Haptics._();
  // 由设置控制的全局总开关。为 false 时，所有触感都被禁用。
  static bool _enabled = true;
  static bool get enabled => _enabled;
  static void setEnabled(bool v) {
    _enabled = v;
  }

  /// 非常轻的点击反馈（例如较小的 UI 点击或成功勾选）。
  static void light() {
    if (!enabled) return;
    if (_isIOS) {
      _safe(() => hfp.Haptics.vibrate(hfp.HapticsType.light));
    } else if (_isAndroid) {
      _safe(() => system.HapticFeedback.lightImpact());
    }
  }

  /// 中等点击反馈（例如打开/关闭抽屉、开关）。
  static void medium() {
    if (!enabled) return;
    if (_isIOS) {
      _safe(() => hfp.Haptics.vibrate(hfp.HapticsType.medium));
    } else if (_isAndroid) {
      _safe(() => system.HapticFeedback.mediumImpact());
    }
  }

  static void soft() {
    if (!enabled) return;
    if (_isIOS) {
      _safe(() => hfp.Haptics.vibrate(hfp.HapticsType.soft));
    } else if (_isAndroid) {
      // 最接近的内置等效项，用于非常轻柔的点击
      _safe(() => system.HapticFeedback.selectionClick());
    }
  }

  /// 抽屉专用脉冲；调校为有存在感但不生硬。
  static void drawerPulse() {
    if (!enabled) return;
    if (_isIOS) {
      _safe(() => hfp.Haptics.vibrate(hfp.HapticsType.soft));
    } else if (_isAndroid) {
      _safe(() => system.HapticFeedback.selectionClick());
    }
  }

  /// 取消任何正在进行的振动（在我们的用例中很少需要）。
  static void cancel() {
    /* 无操作 */
  }

  // 即发即忘包装器，用于避免在不支持的平台上抛出异常。
  static void _safe(Future<void> Function() action) {
    if (kIsWeb) return; // 在 Web 目标上跳过
    try {
      // 不要 await；触感不应阻塞 UI。
      // ignore: discarded_futures
      action();
    } catch (_) {
      // 吞掉任何 MissingPluginException 或平台通道错误。
    }
  }

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
