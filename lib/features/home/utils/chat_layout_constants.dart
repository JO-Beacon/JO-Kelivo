/// 首页聊天 UI（桌面或平板）共享布局常量。
class ChatLayoutConstants {
  /// 聊天消息列表区域的最大可读宽度。
  static const double maxContentWidth = 860.0;

  /// 聊天输入栏区域的最大宽度。
  static const double maxInputWidth = 860.0;

  /// 已删除消息在真正从时间线移除前，淡出并折叠所需的时间。
  /// 控制器在标记插槽和实际删除之间等待此时长，
  /// 使 widget 动画和数据变更保持同步。
  static const Duration slotRemovalAnimationDuration = Duration(
    milliseconds: 240,
  );
}
