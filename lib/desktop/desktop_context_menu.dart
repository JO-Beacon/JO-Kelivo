import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:ui' as ui;
import '../shared/widgets/ios_tactile.dart';
import '../core/services/haptics.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

/// 桌面端简单的锚定上下文菜单。
/// 在光标或锚点 widget 附近显示带细微动画的 Material 菜单。
class DesktopContextMenuItem {
  final IconData? icon;
  final String? svgAsset;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  const DesktopContextMenuItem({
    this.icon,
    this.svgAsset,
    required this.label,
    this.onTap,
    this.danger = false,
  });
}

/// 在给定全局偏移处显示上下文菜单（例如右键点击位置）。
Future<void> showDesktopContextMenuAt(
  BuildContext context, {
  required Offset globalPosition,
  required List<DesktopContextMenuItem> items,
}) async {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  if (overlayBox == null) return;

  const double minMenuWidth = 160;
  const double maxMenuWidth = 360;
  final double menuWidth = _estimateMenuWidth(
    context,
    items,
    minMenuWidth,
    maxMenuWidth,
  );
  final screen = overlayBox.size;
  final double menuMaxHeight = screen.height * 0.5; // 超出时滚动
  final double estMenuHeight = (items.length * 44.0).clamp(44.0, menuMaxHeight);
  const double gap = 8; // 与光标之间的偏移
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final padding = MediaQuery.of(context).padding;
  final minX = padding.left + 8;
  final maxX = screen.width - padding.right - menuWidth - 8;
  final minY = padding.top + 8;
  final maxY = screen.height - padding.bottom - estMenuHeight - 8;

  final local = overlayBox.globalToLocal(globalPosition);
  double x = (local.dx + gap).clamp(minX, maxX);
  // 根据可用空间决定显示在上方还是下方
  final availableBelow = screen.height - padding.bottom - local.dy - 8;
  final availableAbove = local.dy - padding.top - 8;
  final placeAbove =
      availableBelow < estMenuHeight && availableAbove > availableBelow;
  double y = placeAbove
      ? (local.dy - gap - estMenuHeight).clamp(minY, maxY)
      : (local.dy + gap).clamp(minY, maxY);

  await showGeneralDialog<void>(
    context: context,
    barrierLabel: 'context-menu',
    barrierDismissible: true,
    barrierColor: cs.scrim.withValues(alpha: 0.06),
    pageBuilder: (ctx, _, __) {
      return Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned(
              left: x,
              top: y,
              child: _AnimatedFade(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: menuWidth,
                    maxWidth: menuWidth,
                  ),
                  child: IntrinsicWidth(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: isDark
                                ? cs.onSurface.withValues(alpha: 0.08)
                                : cs.outlineVariant.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: cs.surface.withValues(alpha: 0.66),
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: menuMaxHeight,
                              ),
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (final it in items)
                                      _GlassMenuItem(
                                        icon: it.icon,
                                        svgAsset: it.svgAsset,
                                        label: it.label,
                                        danger: it.danger,
                                        onTap: () {
                                          Navigator.of(ctx).pop();
                                          it.onTap?.call();
                                        },
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
              ),
            ),
          ],
        ),
      );
    },
  );
}

double _estimateMenuWidth(
  BuildContext context,
  List<DesktopContextMenuItem> items,
  double minW,
  double maxW,
) {
  // 基础内边距：左右 12；图标 18，若有则再加间距 10
  double maxText = 0;
  final textStyle = TextStyle(
    fontSize: 14.5,
    color: Theme.of(context).colorScheme.onSurface,
    decoration: TextDecoration.none,
    fontWeight: AppFontWeights.medium,
  );
  for (final it in items) {
    final tp = TextPainter(
      text: TextSpan(text: it.label, style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: maxW);
    double width = 12 /*left*/ + tp.width + 12 /*right*/;
    if (it.icon != null || it.svgAsset != null) {
      width += 18 /*icon*/ + 10 /*gap*/;
    }
    if (width > maxText) maxText = width;
  }
  return maxText.clamp(minW, maxW);
}

/// 显示锚定到 widget key 的菜单（根据空间决定显示在 widget 上方或下方）。
Future<void> showDesktopAnchoredMenu(
  BuildContext context, {
  required GlobalKey anchorKey,
  required List<DesktopContextMenuItem> items,
  Offset offset = Offset.zero,
}) async {
  final rb = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (rb == null) return;
  final topLeft = rb.localToGlobal(Offset.zero);
  final size = rb.size;
  // 将菜单水平居中到头像下方（抵消内部间隙）
  const double minMenuWidth = 160;
  const double maxMenuWidth = 360;
  const double gap = 8; // 应与 showDesktopContextMenuAt 的 gap 保持一致
  final double menuWidth = _estimateMenuWidth(
    context,
    items,
    minMenuWidth,
    maxMenuWidth,
  );
  final anchorBottomCenter = topLeft + Offset(size.width / 2, size.height);
  final adjusted = anchorBottomCenter - Offset(menuWidth / 2 + gap, 0);
  await showDesktopContextMenuAt(
    context,
    globalPosition: adjusted + offset,
    items: items,
  );
}

class _AnimatedFade extends StatefulWidget {
  const _AnimatedFade({required this.child});
  final Widget child;
  @override
  State<_AnimatedFade> createState() => _AnimatedFadeState();
}

class _AnimatedFadeState extends State<_AnimatedFade> {
  double _opacity = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _opacity = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      opacity: _opacity,
      child: widget.child,
    );
  }
}

class _GlassMenuItem extends StatefulWidget {
  const _GlassMenuItem({
    this.icon,
    this.svgAsset,
    required this.label,
    this.onTap,
    this.danger = false,
  });
  final IconData? icon;
  final String? svgAsset;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  State<_GlassMenuItem> createState() => _GlassMenuItemState();
}

class _GlassMenuItemState extends State<_GlassMenuItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = widget.danger
        ? Theme.of(context).colorScheme.error
        : cs.onSurface;
    final ic = widget.danger
        ? Theme.of(context).colorScheme.error
        : cs.onSurface.withValues(alpha: 0.9);
    final bg = _hover
        ? (cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.05))
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: IosCardPress(
        borderRadius: BorderRadius.zero,
        baseColor: Colors.transparent,
        onTap: () {
          try {
            Haptics.light();
          } catch (_) {}
          widget.onTap?.call();
        },
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(color: bg),
          child: Row(
            children: [
              if (widget.icon != null || widget.svgAsset != null) ...[
                if (widget.icon != null)
                  Icon(widget.icon, size: 18, color: ic)
                else
                  SvgPicture.asset(
                    widget.svgAsset!,
                    width: 18,
                    height: 18,
                    colorFilter: ColorFilter.mode(ic, BlendMode.srcIn),
                  ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: fg,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
