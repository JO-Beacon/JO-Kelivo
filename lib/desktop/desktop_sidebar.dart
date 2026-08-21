import 'dart:async';
import 'package:flutter/material.dart';
import '../features/home/widgets/side_drawer.dart';
import '../features/home/widgets/sidebar_presentation.dart';

/// 桌面侧边栏包装器。第一阶段复用平板内嵌的 SideDrawer 以保证一致。
/// 后续可演进为带右键菜单的专用桌面侧边栏。
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.userName,
    required this.assistantName,
    this.onSelectConversation,
    this.onNewConversation,
    this.loadingConversationIds = const <String>{},
  });

  final String userName;
  final String assistantName;

  /// 选中会话时的回调。
  /// 桌面端会忽略 [closeDrawer] 参数（侧边栏始终可见）。
  final FutureOr<void> Function(String id, {bool closeDrawer})?
  onSelectConversation;

  /// 请求新建会话时的回调。
  /// 桌面端会忽略 [closeDrawer] 参数（侧边栏始终可见）。
  final FutureOr<void> Function({bool closeDrawer})? onNewConversation;
  final Set<String> loadingConversationIds;

  @override
  Widget build(BuildContext context) {
    return SideDrawer(
      embeddedWidth: 300,
      userName: userName,
      assistantName: assistantName,
      onSelectConversation: onSelectConversation,
      onNewConversation: onNewConversation,
      loadingConversationIds: loadingConversationIds,
      onEnterGlobalSearch: () {},
      onExitGlobalSearch: () {},
      showBottomBar: false,
      presentation: SidebarPresentation.docked,
      capabilities: const SidebarCapabilities(
        showTabs: true,
        pointerInteractions: true,
        assistantReorder: true,
      ),
    );
  }
}
