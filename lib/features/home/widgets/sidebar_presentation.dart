/// 主侧边栏的展示与交互能力。
///
/// 主外壳负责这些决策。[SideDrawer] 使用这些值，而不自行读取宿主平台；
/// 因此同一个侧边栏可以在紧凑屏幕上渲染为抽屉，
/// 也可以在较宽屏幕上渲染为停靠面板。
enum SidebarPresentation { overlay, docked }

class SidebarCapabilities {
  const SidebarCapabilities({
    this.showTabs = false,
    this.assistantsOnly = false,
    this.topicsOnly = false,
    this.pointerInteractions = false,
    this.assistantReorder = false,
  });

  /// 分别渲染助手和对话标签页。
  final bool showTabs;

  /// 只渲染助手列表。
  final bool assistantsOnly;

  /// 只渲染对话列表。
  final bool topicsOnly;

  /// 启用面向指针的交互，例如悬停、上下文菜单和
  /// 桌面导航入口。
  final bool pointerInteractions;

  /// 允许原地重排助手。
  final bool assistantReorder;
}
