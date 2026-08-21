import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show Theme; // 用于 Material color scheme primary
import '../../core/services/haptics.dart';
import 'package:provider/provider.dart';
import '../../core/providers/settings_provider.dart';

/// 经过打磨、符合本应用视觉风格的 iOS 风格开关，
/// 带有细微动画。
class IosSwitch extends StatefulWidget {
  const IosSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.width = 44,
    this.height = 26,
    this.activeColor,
    this.inactiveColor,
    this.thumbColor,
    this.shadowColor,
    this.enableHaptics = true,
    this.semanticLabel,
    this.animationDuration = const Duration(milliseconds: 220),
    this.animationCurve = Curves.easeOutCubic,
    this.hitTestSize = 44,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  // 尺寸
  final double width;
  final double height;
  final double hitTestSize; // 宽/高的最小点击目标尺寸

  // 颜色
  final Color? activeColor; // ON 时的轨道颜色
  final Color? inactiveColor; // OFF 时的轨道颜色
  final Color? thumbColor; // 滑块填充
  final Color? shadowColor; // 滑块阴影

  // 交互体验
  final bool enableHaptics;
  final String? semanticLabel;

  // 动画
  final Duration animationDuration;
  final Curve animationCurve;

  @override
  State<IosSwitch> createState() => _IosSwitchState();
}

class _IosSwitchState extends State<IosSwitch> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // 优先使用 Material 配色方案的主色以更好地匹配应用主题；否则回退到 Cupertino 默认值。
    final primary = widget.activeColor ?? cs.primary;

    final bool isDark = theme.brightness == Brightness.dark;
    final bool isOn = widget.value;

    // 关闭状态下的轨道颜色；深色模式使用更深的填充。
    // 根据当前 scheme 派生，以匹配原始 Cupertino 外观
    // （浅色：black @ ~0.08，深色：systemGrey6 #1C1C1E）。
    final Color offTrack =
        widget.inactiveColor ??
        (isDark
            ? Color.alphaBlend(cs.onSurface.withValues(alpha: 0.02), cs.surface)
            : cs.onSurface.withValues(alpha: 0.08));

    final bool enabled = widget.onChanged != null;
    final double radius = widget.height / 2;
    final double thumbSize = widget.height - 6; // 视觉边距
    final double tapW = math.max(widget.width, widget.hitTestSize);
    final double tapH = math.max(widget.height, widget.hitTestSize);
    final double pressScale = _pressed && enabled ? 0.98 : 1.0;

    // 简洁的实心启用轨道，无光晕或阴影
    final Decoration onDecoration = BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: primary,
    );

    final Decoration offDecoration = BoxDecoration(
      color: offTrack,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        // 原始设计中为 systemGrey3/4 @ 0.65/0.35；部分调色板中的 outlineVariant
        // 是纯黑或纯白，因此改为从 onSurface 派生。
        color: cs.onSurface.withValues(
          alpha: (isDark ? 0.24 : 0.20) * (enabled ? 0.65 : 0.35),
        ),
        width: 1,
      ),
    );

    // 滑块颜色（匹配原始 Cupertino 灰色）：
    // - 深色 + 关闭：中灰（#636366）
    // - 深色 + 开启：深灰（#1C1C1E）
    // - 浅色：白色滑块
    final Color thumb =
        widget.thumbColor ??
        (isDark
            ? (isOn
                  ? Color.alphaBlend(
                      cs.onSurface.withValues(alpha: 0.02),
                      cs.surface,
                    )
                  : Color.alphaBlend(
                      cs.onSurface.withValues(alpha: 0.36),
                      cs.surface,
                    ))
            : cs.surfaceContainerLowest);

    return Semantics(
      label: widget.semanticLabel,
      checked: widget.value,
      button: false,
      enabled: enabled,
      onTap: enabled ? _handleTap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: enabled ? _handleTap : null,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        child: SizedBox(
          width: tapW,
          height: tapH,
          child: Center(
            child: AnimatedScale(
              scale: pressScale,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: widget.animationDuration,
                curve: widget.animationCurve,
                width: widget.width,
                height: widget.height,
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                decoration: widget.value ? onDecoration : offDecoration,
                child: Stack(
                  children: [
                    // 滑块
                    AnimatedAlign(
                      duration: widget.animationDuration,
                      curve: widget.animationCurve,
                      alignment: widget.value
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: _Thumb(
                        size: thumbSize,
                        color: enabled ? thumb : thumb.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleTap() {
    // 仅在 widget 级和设置级开关都允许时才振动；
    // 全局总开关在 Haptics.* 方法内部执行。
    final sp = context.read<SettingsProvider>();
    if (widget.enableHaptics && sp.hapticsIosSwitch) Haptics.soft();
    widget.onChanged?.call(!widget.value);
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
