import 'package:flutter/foundation.dart'
    show
        AsyncCallback,
        kIsWeb,
        defaultTargetPlatform,
        TargetPlatform,
        visibleForTesting;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'window_size_manager.dart';
import 'windows_window_geometry.dart';
import 'windows_window_placement.dart';
import 'dart:async';

/// 处理桌面窗口初始化和持久化（尺寸、位置、最大化状态）。
class DesktopWindowController with WindowListener {
  DesktopWindowController._() : _whenWindowReady = _whenWindowsReady;

  @visibleForTesting
  DesktopWindowController.forTesting(this._whenWindowReady);

  static final DesktopWindowController instance = DesktopWindowController._();

  static Future<void> _whenWindowsReady(
    WindowOptions options,
    AsyncCallback callback,
  ) => windowManager.waitUntilReadyToShow(options, () {
    unawaited(callback());
  });

  final Future<void> Function(WindowOptions options, AsyncCallback callback)
  _whenWindowReady;
  final WindowSizeManager _sizeMgr = const WindowSizeManager();
  bool _attached = false;
  // 还原窗口边界期间要屏蔽监听器保存，否则会把中间态写进偏好。
  bool _restoring = false;
  // 每次几何变化递增，用于丢弃过期的异步保存结果。
  int _geometryRevision = 0;
  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;
  // 防抖定时器，避免拖动或调整大小时频繁写盘
  Timer? _moveDebounce;
  Timer? _resizeDebounce;
  static const _debounceDuration = Duration(milliseconds: 400);

  Future<void> initializeAndShow({String? title}) async {
    if (kIsWeb) return;
    if (!(defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux)) {
      return;
    }

    await windowManager.ensureInitialized();
    // Windows 上等边界还原完成后再装监听器，避免把还原过程当成用户拖动。
    if (!_isWindows) _attachListeners();

    final initialSize = await _sizeMgr.getInitialSize();
    const minSize = Size(
      WindowSizeManager.minWindowWidth,
      WindowSizeManager.minWindowHeight,
    );
    const maxSize = Size(
      WindowSizeManager.maxWindowWidth,
      WindowSizeManager.maxWindowHeight,
    );

    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final options = WindowOptions(
      // 在 macOS 上让 Cocoa 自动保存恢复最后窗口框架（位置和尺寸），避免跳动。
      size: isMac ? null : initialSize,
      // 避免在 macOS 上设置最小或最大尺寸，以防出现细微尺寸校正。
      minimumSize: isMac ? null : minSize,
      maximumSize: isMac ? null : maxSize,
      title: title,
    );

    final savedPos = await _sizeMgr.getPosition();
    final wasMax = await _sizeMgr.getWindowMaximized();

    if (_isWindows) {
      // Windows 的位置按物理像素保存，并交给原生侧按当前显示器的工作区还原，
      // 避免跨显示器／改缩放后窗口落在看不见的地方。
      final placement = await _windowsPlacement(initialSize, savedPos);
      await _whenWindowReady(options, () async {
        _restoring = true;
        try {
          if (placement == null) {
            // 取不到显示器信息时保留 runner 的初始位置，只应用尺寸。
            await windowManager.setSize(initialSize);
          } else {
            await restoreWindowsWindowBounds(placement);
          }
          await windowManager.show();
          await windowManager.focus();
          if (wasMax) await windowManager.maximize();
        } catch (_) {
          // 窗口管理失败不能阻止应用打开。
        } finally {
          _restoring = false;
          _attachListeners();
        }
      });
      return;
    }

    await windowManager.waitUntilReadyToShow(options, () async {
      // 在 Windows 上，如果窗口上次是从最大化状态关闭的，则在显示前恢复最大化，
      // 避免先出现普通窗口再放大的闪烁。
      if (!isMac && wasMax) {
        try {
          await windowManager.maximize();
        } catch (_) {}
      }
      // 先显示窗口，再恢复位置，避免 macOS 上跳动或闪烁。
      await windowManager.show();
      await windowManager.focus();
      // 在 macOS 上依赖原生自动保存，不从 Dart 设置位置。
      final shouldRestorePos = savedPos != null && !isMac;
      if (shouldRestorePos && !wasMax) {
        try {
          await windowManager.setPosition(savedPos);
        } catch (_) {}
      }
    });
  }

  Future<Rect?> _windowsPlacement(Size size, Offset? position) async {
    try {
      return resolveWindowsWindowBounds(
        size: size,
        savedPosition: position,
        displays: await getWindowsDisplays(),
      );
    } catch (_) {
      return null;
    }
  }

  void _cancelWindowsSave() {
    _geometryRevision++;
    _moveDebounce?.cancel();
  }

  void _scheduleWindowsSave() {
    _cancelWindowsSave();
    if (_restoring) return;
    _moveDebounce = Timer(_debounceDuration, _saveWindowsNormalBounds);
  }

  Future<void> _saveWindowsNormalBounds() async {
    final revision = _geometryRevision;
    try {
      if (_restoring ||
          await windowManager.isMaximized() ||
          await windowManager.isMinimized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      // 与 getBounds 传给原生侧的缩放保持一致。
      final scale = windowManager.getDevicePixelRatio();
      final bounds = await windowManager.getBounds();
      if (_restoring || revision != _geometryRevision) return;
      await _sizeMgr.setSize(bounds.size);
      await _sizeMgr.setPosition(bounds.topLeft * scale);
    } catch (_) {}
  }

  void _attachListeners() {
    if (_attached) return;
    windowManager.addListener(this);
    _attached = true;
  }

  @override
  void onWindowResize() async {
    if (_isWindows) {
      _scheduleWindowsSave();
      return;
    }
    // 调整大小时节流保存，减少卡顿
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(_debounceDuration, () async {
      try {
        final isMax = await windowManager.isMaximized();
        if (!isMax) {
          final s = await windowManager.getSize();
          await _sizeMgr.setSize(s);
        }
      } catch (_) {}
    });
  }

  @override
  void onWindowMove() async {
    if (_isWindows) {
      _scheduleWindowsSave();
      return;
    }
    // 拖动期间对位置持久化做防抖，避免每次移动都在主 isolate 执行 I/O
    _moveDebounce?.cancel();
    _moveDebounce = Timer(_debounceDuration, () async {
      try {
        final offset = await windowManager.getPosition();
        await _sizeMgr.setPosition(offset);
      } catch (_) {}
    });
  }

  @override
  void onWindowMaximize() async {
    if (_isWindows) _cancelWindowsSave();
    if (_restoring) return;
    try {
      await _sizeMgr.setWindowMaximized(true);
      // 将位置标记为原点占位符，避免最大化时恢复过期位置。
      if (!_isWindows) await _sizeMgr.setPosition(const Offset(0, 0));
    } catch (_) {}
  }

  @override
  void onWindowUnmaximize() async {
    if (_restoring) return;
    try {
      await _sizeMgr.setWindowMaximized(false);
      if (_isWindows) {
        _scheduleWindowsSave();
        return;
      }
      // 从最大化恢复时捕获当前位置。
      final offset = await windowManager.getPosition();
      await _sizeMgr.setPosition(offset);
    } catch (_) {}
  }

  // 像最大化或取消最大化一样持久化全屏状态转换，
  // 保持跨平台状态一致并避免位置跳动。
  @override
  void onWindowEnterFullScreen() async {
    if (_isWindows) _cancelWindowsSave();
    if (_restoring) return;
    try {
      await _sizeMgr.setWindowMaximized(true);
      if (!_isWindows) await _sizeMgr.setPosition(const Offset(0, 0));
    } catch (_) {}
  }

  @override
  void onWindowLeaveFullScreen() async {
    if (_restoring) return;
    try {
      await _sizeMgr.setWindowMaximized(false);
      if (_isWindows) {
        _scheduleWindowsSave();
        return;
      }
      final offset = await windowManager.getPosition();
      await _sizeMgr.setPosition(offset);
    } catch (_) {}
  }

  @override
  void onWindowMinimize() {
    if (_isWindows) _cancelWindowsSave();
  }

  @override
  void onWindowRestore() {
    if (_isWindows) _scheduleWindowsSave();
  }
}
