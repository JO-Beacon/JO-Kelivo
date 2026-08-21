import 'package:flutter/material.dart';
import '../../../icons/lucide_adapter.dart';

const scrollNavHoverRegionKey = ValueKey('scroll-nav-hover-region');

/// 玻璃质感的滚动导航按钮面板，纵向排列 4 个按钮。
///
/// 按钮（从上到下）：
/// - 滚动到顶部（双向上箭头）
/// - 上一条消息（上箭头）
/// - 下一条消息（下箭头）
/// - 滚动到底部（双向下箭头）
///
/// 用户滚动时从右侧滑入显示，
/// 停止滚动后滑出隐藏。
class ScrollNavButtonsPanel extends StatelessWidget {
  const ScrollNavButtonsPanel({
    super.key,
    required this.visible,
    required this.onScrollToTop,
    required this.onPreviousMessage,
    required this.onNextMessage,
    required this.onScrollToBottom,
    this.bottomOffset = 80,
    this.iconSize = 16,
    this.buttonPadding = 6,
    this.buttonSpacing = 8,
    this.hoverEnabled = false,
    this.onHoverChanged,
  });

  final bool visible;
  final bool hoverEnabled;
  final ValueChanged<bool>? onHoverChanged;
  final VoidCallback onScrollToTop;
  final VoidCallback onPreviousMessage;
  final VoidCallback onNextMessage;
  final VoidCallback onScrollToBottom;
  final double bottomOffset;
  final double iconSize;
  final double buttonPadding;
  final double buttonSpacing;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 1.0 : 0.87);
    final buttonDiameter = iconSize + buttonPadding * 2;
    final hoverHeight = buttonDiameter * 4 + buttonSpacing * 3 + 24;
    final hoverWidth = buttonDiameter + 24;

    return Align(
      alignment: Alignment.bottomRight,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(right: 12, bottom: bottomOffset),
          child: MouseRegion(
            key: scrollNavHoverRegionKey,
            opaque: hoverEnabled,
            onEnter: hoverEnabled ? (_) => onHoverChanged?.call(true) : null,
            onExit: hoverEnabled ? (_) => onHoverChanged?.call(false) : null,
            child: SizedBox(
              width: hoverWidth,
              height: hoverHeight,
              child: Align(
                alignment: Alignment.bottomRight,
                child: IgnorePointer(
                  ignoring: !visible,
                  child: AnimatedSlide(
                    offset: visible ? Offset.zero : const Offset(1.2, 0),
                    duration: const Duration(milliseconds: 280),
                    curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      opacity: visible ? 1 : 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _GlassyCircleButton(
                            icon: Lucide.ChevronsUp,
                            iconSize: iconSize,
                            iconColor: iconColor,
                            padding: buttonPadding,
                            isDark: isDark,
                            onTap: onScrollToTop,
                          ),
                          SizedBox(height: buttonSpacing),
                          _GlassyCircleButton(
                            icon: Lucide.ChevronUp,
                            iconSize: iconSize,
                            iconColor: iconColor,
                            padding: buttonPadding,
                            isDark: isDark,
                            onTap: onPreviousMessage,
                          ),
                          SizedBox(height: buttonSpacing),
                          _GlassyCircleButton(
                            icon: Lucide.ChevronDown,
                            iconSize: iconSize,
                            iconColor: iconColor,
                            padding: buttonPadding,
                            isDark: isDark,
                            onTap: onNextMessage,
                          ),
                          SizedBox(height: buttonSpacing),
                          _GlassyCircleButton(
                            icon: Lucide.ChevronsDown,
                            iconSize: iconSize,
                            iconColor: iconColor,
                            padding: buttonPadding,
                            isDark: isDark,
                            onTap: onScrollToBottom,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个玻璃质感圆形按钮，背景半透明。
/// 为获得更好性能，使用简单透明度而非昂贵的 BackdropFilter。
class _GlassyCircleButton extends StatelessWidget {
  const _GlassyCircleButton({
    required this.icon,
    required this.iconSize,
    required this.iconColor,
    required this.padding,
    required this.isDark,
    required this.onTap,
  });

  final IconData icon;
  final double iconSize;
  final Color iconColor;
  final double padding;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: isDark ? 0.4 : 0.85),
        shape: BoxShape.circle,
        border: Border.all(
          color: isDark
              ? cs.onSurface.withValues(alpha: 0.12)
              : cs.outline.withValues(alpha: 0.20),
          width: 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: Icon(icon, size: iconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}
