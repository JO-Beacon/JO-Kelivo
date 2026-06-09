import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';

/// Desktop tray + window close behaviour controller.
///
/// - Manages system tray icon visibility and context menu
/// - Implements "minimize to tray on close" when enabled in settings
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

  /// Sync tray state from settings & current localization.
  /// Safe to call multiple times; initialization is performed lazily.
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

    // Persist latest settings (enforce basic invariant in controller as well).
    _showTraySetting = showTray;
    _minimizeToTrayOnClose = showTray && minimizeToTrayOnClose;

    // Whether to intercept window close.
    final shouldPreventClose = _showTraySetting && _minimizeToTrayOnClose;
    try {
      await windowManager.setPreventClose(shouldPreventClose);
    } catch (_) {}

    // Handle tray icon visibility + localized menu.
    final newLocaleKey = l10n.localeName;
    final localeChanged = newLocaleKey != _localeKey;
    _localeKey = newLocaleKey;

    if (_showTraySetting) {
      if (!_trayVisible || localeChanged) {
        await _ensureTrayIconAndMenu(l10n);
        _trayVisible = true;
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

    // Use platform-specific tray icons (mirrors Gopeed's approach):
    // - Windows: multi-size ICO for crisp scaling
    // - macOS: template PNG so the system can adapt to light/dark menu bar
    // - Linux/others: regular PNG asset
    final platform = defaultTargetPlatform;
    try {
      if (platform == TargetPlatform.windows) {
        await trayManager.setIcon('assets/app_icon.ico');
      } else if (platform == TargetPlatform.macOS) {
        await trayManager.setIcon('assets/icon_mac.png', isTemplate: true);
      } else {
        await trayManager.setIcon('assets/icons/kelivo.png');
      }
    } catch (_) {}

    // Some Linux environments do not support tooltip; keep the call
    // consistent with Gopeed and skip it there.
    if (platform != TargetPlatform.linux) {
      try {
        await trayManager.setToolTip('JO-Kelivo');
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
      // On Windows we may have `preventClose` enabled to support
      // "close to tray". Temporarily disable it and send a normal
      // close so the window can exit immediately without being
      // intercepted by the minimize-to-tray logic.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await windowManager.setPreventClose(false);
        } catch (_) {}
        try {
          await windowManager.close();
          return;
        } catch (_) {}
      }

      // Other desktop platforms (and Windows fallback): destroy the
      // window so the process exits cleanly.
      await windowManager.destroy();
    } catch (_) {}
  }

  // ===== TrayListener =====

  @override
  void onTrayIconMouseDown() {
    // Left-click: bring main window to front.
    if (!_isDesktop) return;
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Right-click: show the tray context menu.
    // Guard against duplicate popups in a single interaction cycle.
    if (_contextMenuOpen) {
      return;
    }

    _contextMenuOpen = true;
    try {
      // On Windows, focusing the window before opening the menu helps the menu
      // close normally when the user clicks elsewhere.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await windowManager.focus();
        } catch (_) {}
      }
      await trayManager.popUpContextMenu();
    } catch (_) {
    } finally {
      _contextMenuOpen = false;
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // Treat a menu item click as the end of this tray menu interaction.
    _contextMenuOpen = false;
  }

  // ===== WindowListener =====

  @override
  void onWindowClose() async {
    if (!_isDesktop) return;
    // Only intercept close when user enabled minimize-to-tray.
    final shouldIntercept = _showTraySetting && _minimizeToTrayOnClose;
    if (!shouldIntercept) return;
    try {
      final isPreventClose = await windowManager.isPreventClose();
      if (!isPreventClose) return;
      await windowManager.hide();
    } catch (_) {}
  }
}
