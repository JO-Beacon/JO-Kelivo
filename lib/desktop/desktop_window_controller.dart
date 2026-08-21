import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'window_size_manager.dart';
import 'dart:async';
import 'package:bitsdojo_window/bitsdojo_window.dart';

/// 处理桌面窗口初始化和持久化（尺寸、位置、最大化状态）。
class DesktopWindowController with WindowListener {
  DesktopWindowController._();
  static final DesktopWindowController instance = DesktopWindowController._();

  final WindowSizeManager _sizeMgr = const WindowSizeManager();
  bool _attached = false;
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
    _attachListeners();
    // Windows 自定义标题栏在 main 中处理（TitleBarStyle.hidden）

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

    if (defaultTargetPlatform == TargetPlatform.windows) {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      doWhenWindowReady(() async {
        appWindow.minSize = options.minimumSize;
        appWindow.maxSize = options.maximumSize;
        appWindow.size = initialSize;

        if (savedPos != null) {
          appWindow.position = savedPos;
        }

        /// 在 Windows 上，如果窗口上次是从最大化状态关闭的，则恢复为最大化。
        if (wasMax) {
          appWindow.maximize();
        }
      });
    } else {
      await windowManager.waitUntilReadyToShow(options, () async {
        // 先显示窗口，再恢复位置，避免 macOS 上跳动或闪烁。
        await windowManager.show();
        await windowManager.focus();
        // 在 macOS 上依赖原生自动保存，不从 Dart 设置位置。
        final shouldRestorePos = savedPos != null && !isMac;
        if (shouldRestorePos) {
          try {
            await windowManager.setPosition(savedPos);
          } catch (_) {}
        }
      });
    }
  }

  void _attachListeners() {
    if (_attached) return;
    windowManager.addListener(this);
    _attached = true;
  }

  @override
  void onWindowResize() async {
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
    try {
      await _sizeMgr.setWindowMaximized(true);
      // 将位置标记为原点占位符，避免最大化时恢复过期位置。
      await _sizeMgr.setPosition(const Offset(0, 0));
    } catch (_) {}
  }

  @override
  void onWindowUnmaximize() async {
    try {
      await _sizeMgr.setWindowMaximized(false);
      // 从最大化恢复时捕获当前位置。
      final offset = await windowManager.getPosition();
      await _sizeMgr.setPosition(offset);
    } catch (_) {}
  }

  // 像最大化或取消最大化一样持久化全屏状态转换，
  // 保持跨平台状态一致并避免位置跳动。
  @override
  void onWindowEnterFullScreen() async {
    try {
      await _sizeMgr.setWindowMaximized(true);
      await _sizeMgr.setPosition(const Offset(0, 0));
    } catch (_) {}
  }

  @override
  void onWindowLeaveFullScreen() async {
    try {
      await _sizeMgr.setWindowMaximized(false);
      final offset = await windowManager.getPosition();
      await _sizeMgr.setPosition(offset);
    } catch (_) {}
  }
}
