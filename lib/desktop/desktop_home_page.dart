import 'package:flutter/material.dart';
import 'desktop_nav_rail.dart';
import 'desktop_chat_page.dart';
import 'desktop_settings_page.dart';
import 'desktop_translate_page.dart';
import '../features/settings/pages/storage_space_page.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'hotkeys/hotkey_event_bus.dart';
import 'hotkeys/chat_action_bus.dart';
import 'desktop_settings_navigation_bus.dart';
import 'desktop_tray_controller.dart';
import 'window_appearance.dart';
import '../core/services/notification_service.dart';

/// 桌面首页：左侧紧凑导航栏加主内容。
/// 第一阶段关注结构以及适合平台端的交互和悬停效果。
class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({
    super.key,
    this.initialTabIndex,
    this.initialProviderKey,
  });

  final int? initialTabIndex; // 0=Chat,1=Translate,2=Storage,3=Settings
  final String? initialProviderKey;

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _DesktopHomePageState extends State<DesktopHomePage> {
  int _tabIndex = 0; // 0=Chat, 1=Translate, 2=Storage, 3=Settings
  bool _storageVisited = false;
  bool _globalSearchActive = false;
  StreamSubscription<HotkeyAction>? _hotkeySub;
  StreamSubscription<ChatAction>? _chatActionSub;
  StreamSubscription<DesktopSettingsNavigationTarget>? _settingsNavSub;
  StreamSubscription<String>? _conversationOpenSub;

  @override
  void initState() {
    super.initState();
    if (widget.initialTabIndex != null) {
      _tabIndex = widget.initialTabIndex!.clamp(0, 3);
    }
    _storageVisited = _tabIndex == 2;
    _conversationOpenSub = NotificationService.conversationTaps.listen((_) {
      if (!mounted) return;
      setState(() {
        _tabIndex = 0;
        _globalSearchActive = false;
      });
      ChatActionBus.instance.fire(ChatAction.exitGlobalSearch);
    });
    // 初始进入时如果就是聊天页，则聚焦聊天输入框
    if (_tabIndex == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ChatActionBus.instance.fire(ChatAction.focusInput);
      });
    }
    // 监听会影响主标签页和窗口的全局快捷键动作
    _hotkeySub = HotkeyEventBus.instance.stream.listen((action) async {
      switch (action) {
        case HotkeyAction.openSettings:
          if (mounted) {
            setState(() {
              _tabIndex = 3;
              _globalSearchActive = false;
            });
            ChatActionBus.instance.fire(ChatAction.exitGlobalSearch);
          }
          break;
        case HotkeyAction.closeWindow:
          try {
            await windowManager.close();
          } catch (_) {}
          break;
        case HotkeyAction.toggleAppVisibility:
          try {
            final visible = await windowManager.isVisible();
            final minimized = await windowManager.isMinimized();
            final focused = await windowManager.isFocused();

            // 优先级：
            // 1. 如果窗口不可见或最小化，则显示并聚焦
            // 2. 如果窗口可见但未聚焦，则聚焦
            // 3. 如果窗口可见且已聚焦，则隐藏
            if (!visible || minimized) {
              await windowManager.show();
              await windowManager.focus();
              // 如果当前是聊天页，显示窗口时聚焦输入框
              if (_tabIndex == 0) {
                ChatActionBus.instance.fire(ChatAction.focusInput);
              }
            } else if (!focused) {
              await windowManager.focus();
              // 如果当前是聊天页，聚焦窗口时也聚焦输入框
              if (_tabIndex == 0) {
                ChatActionBus.instance.fire(ChatAction.focusInput);
              }
            } else {
              await windowManager.hide();
            }
          } catch (_) {}
          break;
        case HotkeyAction.newTopic:
          if (_tabIndex == 0) {
            ChatActionBus.instance.fire(ChatAction.newTopic);
          }
          break;
        case HotkeyAction.switchModel:
          if (_tabIndex == 0) {
            ChatActionBus.instance.fire(ChatAction.switchModel);
          }
          break;
        case HotkeyAction.toggleLeftPanelAssistants:
          if (_tabIndex == 0) {
            ChatActionBus.instance.fire(ChatAction.toggleLeftPanelAssistants);
          }
          break;
        case HotkeyAction.toggleLeftPanelTopics:
          if (_tabIndex == 0) {
            ChatActionBus.instance.fire(ChatAction.toggleLeftPanelTopics);
          }
          break;
      }
    });

    _chatActionSub = ChatActionBus.instance.stream.listen((action) {
      if (!mounted) return;
      switch (action) {
        case ChatAction.enterGlobalSearch:
          setState(() {
            _tabIndex = 0;
            _globalSearchActive = true;
          });
          break;
        case ChatAction.exitGlobalSearch:
          setState(() {
            _globalSearchActive = false;
          });
          break;
        default:
          break;
      }
    });
    _settingsNavSub = DesktopSettingsNavigationBus.instance.stream.listen((
      target,
    ) {
      if (!mounted) return;
      switch (target) {
        case DesktopSettingsNavigationTarget.backup:
          setState(() {
            _tabIndex = 3;
            _globalSearchActive = false;
          });
          ChatActionBus.instance.fire(ChatAction.exitGlobalSearch);
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 确保合理的最小尺寸，避免在剧烈调整大小时发生溢出。
    const minWidth = 960.0;
    const minHeight = 640.0;

    // Windows 上把当前主题的颜色交给系统，让原生标题栏与界面连成一片。
    // 颜色没有变化时内部会跳过，因此每次重建都调用是安全的。
    unawaited(WindowAppearanceSync.sync(Theme.of(context)));

    // 托盘的深浅图形跟随应用主题：用户切浅色或深色时，托盘图标要跟着一起变。
    // 明暗没变化时内部会跳过，所以每次重建都调用是安全的。
    unawaited(
      DesktopTrayController.instance.applyBrightness(
        Theme.of(context).brightness,
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final needsWidthPad = w < minWidth;
        final needsHeightPad = h < minHeight;

        Widget body = Row(
          children: [
            DesktopNavRail(
              activeIndex: _tabIndex,
              globalSearchActive: _globalSearchActive,
              onTapChat: () {
                setState(() {
                  _tabIndex = 0;
                  _globalSearchActive = false;
                });
                ChatActionBus.instance.fire(ChatAction.exitGlobalSearch);
                // 切换到聊天页时聚焦输入框
                ChatActionBus.instance.fire(ChatAction.focusInput);
              },
              onTapGlobalSearch: () {
                setState(() {
                  _tabIndex = 0;
                  _globalSearchActive = true;
                });
                ChatActionBus.instance.fire(ChatAction.enterGlobalSearch);
              },
              onTapTranslate: () {
                setState(() {
                  _tabIndex = 1;
                  _globalSearchActive = false;
                });
                ChatActionBus.instance.fire(ChatAction.exitGlobalSearch);
              },
              onTapStorage: () => setState(() {
                _tabIndex = 2;
                _globalSearchActive = false;
                _storageVisited = true;
                ChatActionBus.instance.fire(ChatAction.exitGlobalSearch);
              }),
              onTapSettings: () {
                setState(() {
                  _tabIndex = 3;
                  _globalSearchActive = false;
                });
                ChatActionBus.instance.fire(ChatAction.exitGlobalSearch);
              },
            ),
            Expanded(
              // 保持所有页面存活，使桌面端切换标签（聊天、翻译、设置）时
              // 正在进行的聊天流不会被取消。
              child: IndexedStack(
                index: _tabIndex,
                children: [
                  // 聊天页保持挂载
                  const DesktopChatPage(),
                  // 翻译页保持挂载
                  const DesktopTranslatePage(key: ValueKey('translate_page')),
                  _storageVisited
                      ? const StorageSpacePage(
                          key: ValueKey('storage_space_page'),
                          embedded: true,
                        )
                      : const SizedBox.shrink(),
                  DesktopSettingsPage(
                    key: const ValueKey('settings_page'),
                    initialProviderKey: widget.initialProviderKey,
                  ),
                ],
              ),
            ),
          ],
        );

        // Windows 已改用原生标题栏，自绘标题栏（WindowTitleBar）随之移除；
        // 仅保留为窗口尺寸不足时居中的约束包装。
        final content = Stack(
          children: [
            body,
            // 需要时将延迟构建的设置页注入 IndexedStack，
            // 以便传入 initialProviderKey 而不丢弃聊天状态。
            if (_tabIndex == 3) const SizedBox.shrink(),
          ],
        );

        // if (!needsWidthPad && !needsHeightPad) return content;

        // 如果窗口小于最小尺寸，则将受限区域居中
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: minWidth,
              minHeight: minHeight,
            ),
            child: SizedBox(
              width: needsWidthPad ? minWidth : w,
              height: needsHeightPad ? minHeight : h,
              child: content,
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    unawaited(_conversationOpenSub?.cancel());
    try {
      _hotkeySub?.cancel();
    } catch (_) {}
    try {
      _chatActionSub?.cancel();
    } catch (_) {}
    try {
      _settingsNavSub?.cancel();
    } catch (_) {}
    super.dispose();
  }
}

// 没有额外路由或垫片；我们直接在上方导入 DesktopSettingsPage。
