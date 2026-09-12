import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, Brightness;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/services/app_exit_flush.dart';
import '../l10n/app_localizations.dart';

/// 桌面托盘和窗口关闭行为控制器。
///
/// - 管理系统托盘图标可见性和上下文菜单
/// - 在设置中启用时实现“关闭窗口时最小化到托盘”
class DesktopTrayController with TrayListener, WindowListener {
  DesktopTrayController._();
  static final DesktopTrayController instance = DesktopTrayController._();

  bool _initialized = false;
  bool _isDesktop = false;
  bool _trayVisible = false;
  bool _showTraySetting = false;
  bool _minimizeToTrayOnClose = false;
  String _localeKey = '';
  bool _contextMenuOpen = false;
  Brightness _iconBrightness = Brightness.light;

  /// 按应用当前的主题明暗换用对应的托盘图形。
  ///
  /// 面板底色可深可浅，一份图形不可能两头都看得见（实测浅色版描边置于深色底色，
  /// 对比度只有 1.18，等于看不见），所以深浅各出一份，按 [appBrightness] 挑。
  ///
  /// 跟随的是**应用主题**，不是系统主题：用户在应用里选浅色、深色或跟随系统时，
  /// 这里收到的就是界面实际呈现的明暗，托盘图形要跟着一起变（包括用户在设置里
  /// 切主题的当下）。明暗没有变化时内部直接返回，所以随每次重建调用是安全的。
  Future<void> applyBrightness(Brightness appBrightness) async {
    if (kIsWeb) return;
    await _setIconBrightness(appBrightness);
  }

  /// 记下托盘图形该用的明暗，并在托盘已建好时立刻换图。
  ///
  /// 先记下来是因为托盘可能还没建好：记下后建托盘时会直接用这一份。
  Future<void> _setIconBrightness(Brightness brightness) async {
    final changed = _iconBrightness != brightness;
    _iconBrightness = brightness;
    if (!changed || !_isDesktop || !_trayVisible) return;
    await _applyTrayIcon();
  }

  /// 按平台与当前明暗设置托盘图标。
  ///
  /// - macOS：模板图，系统只取形状、自动适配浅色或深色菜单栏 → 不需要分深浅
  /// - Windows：多尺寸 ICO，缩放更清晰
  /// - Linux 及其他：普通 PNG
  Future<void> _applyTrayIcon() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await trayManager.setIcon('assets/icon_mac.png', isTemplate: true);
      } else {
        final suffix = _iconBrightness == Brightness.dark ? 'dark' : 'light';
        final extension =
            defaultTargetPlatform == TargetPlatform.windows ? 'ico' : 'png';
        await trayManager.setIcon('assets/icon_tray_$suffix.$extension');
      }
    } catch (_) {}
  }

  /// 根据设置和当前本地化同步托盘状态。
  /// 可安全地多次调用；初始化会延迟执行。
  Future<void> syncFromSettings(
    AppLocalizations l10n, {
    required bool showTray,
    required bool minimizeToTrayOnClose,
  }) async {
    if (kIsWeb) return;
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (!isDesktop) return;
    _isDesktop = true;

    if (!_initialized) {
      try {
        await windowManager.ensureInitialized();
      } catch (_) {}
      try {
        trayManager.addListener(this);
      } catch (_) {}
      try {
        windowManager.addListener(this);
      } catch (_) {}
      _initialized = true;
    }

    // 持久化最新设置（同时在控制器中强制基础约束）。
    _showTraySetting = showTray;
    _minimizeToTrayOnClose = showTray && minimizeToTrayOnClose;

    // 是否拦截窗口关闭。
    final shouldPreventClose = _showTraySetting && _minimizeToTrayOnClose;
    try {
      await windowManager.setPreventClose(shouldPreventClose);
    } catch (_) {}

    // 处理托盘图标可见性和本地化菜单。
    final newLocaleKey = l10n.localeName;
    final localeChanged = newLocaleKey != _localeKey;
    _localeKey = newLocaleKey;

    if (_showTraySetting) {
      if (!_trayVisible || localeChanged) {
        // 先置位再建托盘：图标一放上去就可能有人按新明暗来换（见
        // _setIconBrightness），那时必须已经算“托盘存在”，否则换图会被跳过。
        _trayVisible = true;
        await _ensureTrayIconAndMenu(l10n);
      }
    } else {
      if (_trayVisible) {
        try {
          await trayManager.destroy();
        } catch (_) {}
        _trayVisible = false;
      }
    }
  }

  Future<void> _ensureTrayIconAndMenu(AppLocalizations l10n) async {
    if (!_isDesktop) return;

    // 平台特定的托盘图标；深浅由 _applyTrayIcon 按当前明暗挑。
    final platform = defaultTargetPlatform;
    await _applyTrayIcon();

    // 部分 Linux 环境不支持 tooltip；与 Gopeed 保持一致，在这些环境中跳过。
    if (platform != TargetPlatform.linux) {
      try {
        await trayManager.setToolTip('JO-AIClient');
      } catch (_) {}
    }
    try {
      final menu = Menu(
        items: [
          MenuItem(
            label: l10n.desktopTrayMenuShowWindow,
            onClick: (_) async => _showWindow(),
          ),
          MenuItem.separator(),
          MenuItem(
            label: l10n.desktopTrayMenuExit,
            onClick: (_) async => _exitApp(),
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (_) {}
  }

  Future<void> _showWindow() async {
    if (!_isDesktop) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> _exitApp() async {
    if (!_isDesktop) return;
    try {
      // 退出前排空待处理写入。在 macOS/Linux 上，destroy() 会通过引擎的
      // 退出请求通道执行（这会再次 flush；flush 处理器是幂等的）。
      // 但在 Windows 上，destroy() 回退会直接发送 WM_QUIT 并绕过 WM_CLOSE，
      // 因此如果没有这里的处理，回退退出会完全跳过 flush。
      // 超时用于避免卡住的写入队列挂起托盘退出。
      try {
        await AppExitFlush.flushAll().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      } catch (_) {}
      // Windows 上可能启用了 `preventClose` 以支持“关闭到托盘”。
      // 临时禁用它并发送正常关闭，让窗口能立即退出，
      // 而不会被最小化到托盘逻辑拦截。
      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await windowManager.setPreventClose(false);
        } catch (_) {}
        try {
          await windowManager.close();
          return;
        } catch (_) {}
      }

      // 其他桌面平台（以及 Windows 回退）：销毁窗口，让进程干净退出。
      await windowManager.destroy();
    } catch (_) {}
  }

  // ===== 托盘监听器 =====

  @override
  void onTrayIconMouseDown() {
    // 左键点击：将主窗口带到前台。
    if (!_isDesktop) return;
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Right‑click: 弹出托盘菜单。
    // 使用内部标记防止在一次交互周期内重复弹出，
    // 否则在某些 Windows 环境下会看到第二个偏移的菜单。
    if (_contextMenuOpen) {
      return;
    }
    _contextMenuOpen = true;
    try {
      // Windows 环境下建议在弹出菜单前尝试聚焦窗口，
      // 以避免部分环境中菜单不会在点击其他地方时自动关闭。
      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await windowManager.focus();
        } catch (_) {}
      }
      await trayManager.popUpContextMenu();
    } catch (_) {}
    // 无论是点击菜单项还是点击其他地方关闭菜单，
    // popUpContextMenu 都会在菜单关闭后返回，这里统一重置标记。
    _contextMenuOpen = false;
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // 任一菜单项被点击视为一次菜单交互结束，
    // 额外保险地解除防抖标记（即使 Future 尚未完成）。
    _contextMenuOpen = false;
  }

  // ===== 窗口监听器 =====

  @override
  void onWindowClose() async {
    if (!_isDesktop) return;
    // 仅当用户启用了“关闭到托盘”时才拦截关闭。
    final shouldIntercept = _showTraySetting && _minimizeToTrayOnClose;
    if (!shouldIntercept) return;
    try {
      final isPreventClose = await windowManager.isPreventClose();
      if (!isPreventClose) return;
      await windowManager.hide();
    } catch (_) {}
  }
}
