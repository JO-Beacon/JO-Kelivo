/// Presentation and interaction capabilities for the home sidebar.
///
/// The home shell owns these decisions. [SideDrawer] consumes them instead of
/// reading the host platform itself, so the same sidebar can render as an
/// off-canvas drawer on compact screens or a docked panel on wider surfaces.
enum SidebarPresentation { overlay, docked }

class SidebarCapabilities {
  const SidebarCapabilities({
    this.showTabs = false,
    this.assistantsOnly = false,
    this.topicsOnly = false,
    this.pointerInteractions = false,
    this.assistantReorder = false,
  });

  /// Render separate assistant and conversation tabs.
  final bool showTabs;

  /// Render only the assistant list.
  final bool assistantsOnly;

  /// Render only the conversation list.
  final bool topicsOnly;

  /// Enable pointer-oriented interactions such as hover, context menus, and
  /// desktop navigation entry points.
  final bool pointerInteractions;

  /// Allow reordering assistants in place.
  final bool assistantReorder;
}
