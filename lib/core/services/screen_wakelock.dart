import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 在启用设置且至少有一个会话生成时保持移动端屏幕常亮。
///
/// 生成会话使用引用计数，避免并发会话中一个会话结束就提前关闭常亮。
/// 最后一个会话结束后延迟 10 秒释放，避免连续生成时频繁切换平台状态。
class ScreenWakelock {
  ScreenWakelock._();

  static bool _enabled = false;
  static int _holders = 0;
  static bool _held = false;
  static Timer? _releaseTimer;
  static const Duration _releaseDelay = Duration(seconds: 10);

  /// 测试替身；设置后不会触碰平台插件。
  @visibleForTesting
  static FutureOr<void> Function(bool enable)? debugPlatformApply;

  static void setEnabled(bool value) {
    _enabled = value;
    if (value) {
      _apply();
    } else {
      _applyRelease();
    }
  }

  static void acquire() {
    _holders++;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _apply();
  }

  static void release() {
    if (_holders > 0) _holders--;
    if (_holders == 0) _scheduleRelease();
  }

  /// 清除当前服务持有的全部生成引用，供控制器销毁时使用。
  static void releaseNow() {
    _holders = 0;
    _applyRelease();
  }

  /// 应用从后台恢复后重新向平台声明常亮状态。
  static void reassert() {
    if (!_enabled || _holders <= 0) return;
    _applyPlatformHeld(true);
  }

  @visibleForTesting
  static bool get debugEnabled => _enabled;

  @visibleForTesting
  static int get debugHolders => _holders;

  @visibleForTesting
  static bool get debugHeld => _held;

  @visibleForTesting
  static void debugReset({
    FutureOr<void> Function(bool enable)? platformApply,
  }) {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _enabled = false;
    _holders = 0;
    _held = false;
    debugPlatformApply = platformApply;
  }

  static void _apply() {
    if (_enabled && _holders > 0) _setPlatformHeld(true);
  }

  static void _applyRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    _setPlatformHeld(false);
  }

  static void _scheduleRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_releaseDelay, _applyRelease);
  }

  static void _setPlatformHeld(bool held) {
    if (_held == held) return;
    _applyPlatformHeld(held);
  }

  static void _applyPlatformHeld(bool held) {
    final previous = _held;
    _held = held;
    _invokePlatform(
      held,
      onError: () {
        if (_held == held) _held = previous;
      },
    );
  }

  static void _applyPlatformError(Object error, StackTrace stackTrace) {
    debugPrint('[ScreenWakelock] platform apply failed: $error');
    debugPrint('$stackTrace');
  }

  static void _invokePlatform(bool enable, {void Function()? onError}) {
    final hook = debugPlatformApply;
    if (hook != null) {
      try {
        final result = hook(enable);
        if (result is Future<void>) {
          unawaited(
            result.catchError((Object error, StackTrace stackTrace) {
              onError?.call();
              _applyPlatformError(error, stackTrace);
            }),
          );
        }
      } catch (error, stackTrace) {
        onError?.call();
        _applyPlatformError(error, stackTrace);
      }
      return;
    }
    if (!_isMobile || kIsWeb) return;
    unawaited(
      (enable ? WakelockPlus.enable() : WakelockPlus.disable()).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        onError?.call();
        _applyPlatformError(error, stackTrace);
      }),
    );
  }

  static bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
