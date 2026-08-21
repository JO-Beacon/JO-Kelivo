import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/services/haptics.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

/// iOS 风格图标按钮：无涟漪，按下时颜色渐变，不缩放。
class IosIconButton extends StatefulWidget {
  const IosIconButton({
    super.key,
    this.icon,
    this.builder,
    this.onTap,
    this.onLongPress,
    this.size = 20,
    this.padding = const EdgeInsets.all(6),
    this.color,
    this.pressedColor,
    this.minSize,
    this.semanticLabel,
    this.enabled = true,
  }) : assert(
         icon != null || builder != null,
         'Either icon or builder must be provided',
       );

  final IconData? icon;
  // Builder 接收当前动画颜色以渲染自定义子组件（例如 SVG）。
  final Widget Function(Color color)? builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double size;
  final EdgeInsets padding;
  final Color? color; // 基础颜色；默认使用主题 onSurface
  final Color? pressedColor; // 覆盖按下颜色；默认与 primary 混合
  final double? minSize; // 最小点击目标（例如 AppBar 使用 44）
  final String? semanticLabel;
  final bool enabled;

  @override
  State<IosIconButton> createState() => _IosIconButtonState();
}

class _IosIconButtonState extends State<IosIconButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 启用时保留所提供颜色的透明度；仅在禁用时变暗。
    final Color base = () {
      if (widget.color != null) {
        final alpha = (widget.color!.a * 0.45).clamp(0.0, 1.0).toDouble();
        return widget.enabled
            ? widget.color!
            : widget.color!.withValues(alpha: alpha);
      }
      return theme.colorScheme.onSurface.withValues(
        alpha: widget.enabled ? 1 : 0.45,
      );
    }();
    // 按下时，将图标颜色向白色（浅色主题）或黑色（深色主题）偏移，
    // 得到轻微变亮或变灰的效果，除非通过 pressedColor 覆盖。
    final bool isDark = theme.brightness == Brightness.dark;
    final Color pressTarget =
        widget.pressedColor ??
        (Color.lerp(base, theme.colorScheme.onSurface, 0.35) ?? base);
    final Color hoverTarget =
        Color.lerp(base, theme.colorScheme.onSurface, 0.20) ?? base;
    final Color target = _pressed
        ? pressTarget
        : (_hovered ? hoverTarget : base);

    final child = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      builder: (context, color, _) {
        final c = color ?? base;
        if (widget.builder != null) {
          return widget.builder!(c);
        }
        return Icon(
          widget.icon,
          size: widget.size,
          color: c,
          semanticLabel: widget.semanticLabel,
        );
      },
    );

    // 桌面或 Web 上的柔和悬停背景
    final Color bgTarget = _pressed
        ? (Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: isDark ? 0.12 : 0.08))
        : (_hovered
              ? (Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: isDark ? 0.08 : 0.06))
              : Colors.transparent);

    final content = Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor:
            (widget.enabled &&
                (widget.onTap != null || widget.onLongPress != null))
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown:
              (widget.enabled &&
                  (widget.onTap != null || widget.onLongPress != null))
              ? (_) => setState(() => _pressed = true)
              : null,
          onTapUp:
              (widget.enabled &&
                  (widget.onTap != null || widget.onLongPress != null))
              ? (_) => setState(() => _pressed = false)
              : null,
          onTapCancel:
              (widget.enabled &&
                  (widget.onTap != null || widget.onLongPress != null))
              ? () => setState(() => _pressed = false)
              : null,
          onTap: widget.enabled ? widget.onTap : null,
          onLongPress: widget.enabled ? widget.onLongPress : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: bgTarget,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(padding: widget.padding, child: child),
          ),
        ),
      ),
    );

    if (widget.minSize != null) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: widget.minSize!,
          minHeight: widget.minSize!,
        ),
        child: Center(child: content),
      );
    }
    return content;
  }
}

/// iOS 风格卡片按压效果：按下时背景色渐变，无涟漪，不缩放。
class IosCardPress extends StatefulWidget {
  const IosCardPress({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.longPressTimeout,
    this.borderRadius,
    this.border,
    this.baseColor,
    this.pressedBlendStrength,
    this.padding,
    this.pressedScale,
    this.duration,
    this.haptics = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Duration? longPressTimeout;
  final BorderRadius? borderRadius;
  final BoxBorder? border;
  final Color? baseColor;
  // 0..1；按下时向 surface tint 混合的程度
  final double? pressedBlendStrength;
  final EdgeInsetsGeometry? padding;
  // 按下时可选轻微缩放（例如 0.98）。默认为 1.0（不缩放）。
  final double? pressedScale;
  // 颜色或缩放渐变的可选自定义动画时长。
  final Duration? duration;
  // 点击时是否执行轻柔触感反馈（同时受设置或全局开关控制）
  final bool haptics;

  @override
  State<IosCardPress> createState() => _IosCardPressState();
}

class _IosCardPressState extends State<IosCardPress> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final Color base = widget.baseColor ?? (context.appColors.surfaceCard);
    final double k = widget.pressedBlendStrength ?? (isDark ? 0.14 : 0.12);
    final Color pressTarget =
        Color.lerp(base, theme.colorScheme.onSurface, k) ?? base;
    final Color hoverTarget =
        Color.lerp(base, theme.colorScheme.onSurface, k * 0.7) ?? base;
    final Color target = _pressed
        ? pressTarget
        : (_hovered ? hoverTarget : base);
    final double scale = _pressed ? (widget.pressedScale ?? 1.0) : 1.0;
    final Duration dur = widget.duration ?? const Duration(milliseconds: 200);

    final content = widget.padding == null
        ? widget.child
        : Padding(padding: widget.padding!, child: widget.child);

    return MouseRegion(
      cursor: (widget.onTap != null || widget.onLongPress != null)
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                TapGestureRecognizer.new,
                (recognizer) {
                  recognizer
                    ..onTapDown =
                        (widget.onTap != null || widget.onLongPress != null)
                        ? (_) => setState(() => _pressed = true)
                        : null
                    ..onTapUp =
                        (widget.onTap != null || widget.onLongPress != null)
                        ? (_) => setState(() => _pressed = false)
                        : null
                    ..onTapCancel =
                        (widget.onTap != null || widget.onLongPress != null)
                        ? () => setState(() => _pressed = false)
                        : null
                    ..onTap = widget.onTap == null
                        ? null
                        : () {
                            if (widget.haptics &&
                                context
                                    .read<SettingsProvider>()
                                    .hapticsOnCardTap) {
                              Haptics.soft();
                            }
                            widget.onTap!.call();
                          };
                },
              ),
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: widget.longPressTimeout,
                ),
                (recognizer) {
                  recognizer
                    ..onLongPress = widget.onLongPress
                    ..onLongPressEnd = (widget.onLongPress != null)
                        ? (_) => setState(() => _pressed = false)
                        : null;
                },
              ),
        },
        child: AnimatedScale(
          scale: scale,
          duration: dur,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: dur,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: target,
              borderRadius: widget.borderRadius ?? BorderRadius.circular(12),
              border: widget.border,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}
