import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IosCheckbox extends StatefulWidget {
  const IosCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = 22,
    this.activeColor,
    this.borderColor,
    this.checkmarkColor,
    this.semanticLabel,
    this.enableHaptics = true,
    this.hitTestSize = 32,
    this.borderWidth = 2.0,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  // 视觉配置
  final double size; // 视觉圆形直径
  final double hitTestSize; // 点击目标尺寸
  final double borderWidth;
  final Color? activeColor;
  final Color? borderColor;
  final Color? checkmarkColor;

  // 无障碍
  final String? semanticLabel;

  // 交互体验
  final bool enableHaptics;

  @override
  State<IosCheckbox> createState() => _IosCheckboxState();
}

class _IosCheckboxState extends State<IosCheckbox> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final materialTheme = Theme.of(context);
    final cs = materialTheme.colorScheme;
    final isDark = materialTheme.brightness == Brightness.dark;
    final activeColor =
        widget.activeColor ?? CupertinoTheme.of(context).primaryColor;
    // 中性灰色圆环，匹配原始 Cupertino systemGrey4（浅色）或 systemGrey3（深色）。
    // 部分调色板将 outlineVariant 定义为纯黑或纯白，会让边框过于醒目。
    final borderColor =
        widget.borderColor ??
        cs.onSurface.withValues(alpha: isDark ? 0.24 : 0.20);

    final bool enabled = widget.onChanged != null;
    final Color bgColor = widget.value
        ? activeColor
        : CupertinoColors.transparent;
    final Color effectiveBorderColor = widget.value ? activeColor : borderColor;
    // 类似供应商多选那样动态计算对勾颜色：
    // - 使用主题主色时，用 `onPrimary` 获得最佳对比度。
    // - 提供自定义 activeColor 时，按亮度计算对比色。
    Color contrastOn(Color bg) {
      final b = ThemeData.estimateBrightnessForColor(bg);
      return b == Brightness.dark
          ? CupertinoColors
                .white // color-gate: ignore（与调用方颜色的对比）
          : CupertinoColors.black;
    }

    final bool usesThemePrimary = widget.activeColor == null;
    final Color computedOnPrimary = cs.onPrimary;
    final Color dynamicCheck =
        widget.checkmarkColor ??
        (usesThemePrimary ? computedOnPrimary : contrastOn(activeColor));
    final Color effectiveCheckColor = dynamicCheck.withValues(
      alpha: (widget.onChanged != null) ? 1.0 : 0.5,
    );

    final double visualSize = widget.size;
    final double tapSize = math.max(widget.hitTestSize, visualSize);

    // 平滑的按压反馈缩放
    final double pressScale = _pressed && enabled ? 0.95 : 1.0;

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
          width: tapSize,
          height: tapSize,
          child: Center(
            child: AnimatedScale(
              scale: pressScale,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: visualSize,
                height: visualSize,
                decoration: BoxDecoration(
                  color: enabled ? bgColor : bgColor.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: enabled
                        ? effectiveBorderColor
                        : effectiveBorderColor.withValues(alpha: 0.5),
                    width: widget.borderWidth,
                  ),
                ),
                child: _AnimatedCheck(
                  show: widget.value,
                  color: effectiveCheckColor,
                  strokeWidth: math.max(2.0, widget.borderWidth + 0.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleTap() {
    if (widget.enableHaptics) {
      HapticFeedback.lightImpact();
    }
    widget.onChanged?.call(!widget.value);
  }
}

class _AnimatedCheck extends StatelessWidget {
  const _AnimatedCheck({
    required this.show,
    required this.color,
    required this.strokeWidth,
  });

  final bool show;
  final Color color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      tween: Tween<double>(begin: 0, end: show ? 1 : 0),
      builder: (context, t, child) {
        // 出现时轻微缩放弹出
        final scale = 0.9 + 0.1 * t;
        return Transform.scale(
          scale: scale,
          child: CustomPaint(
            painter: _CheckPainter(
              progress: t,
              color: color,
              strokeWidth: strokeWidth,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  final double progress; // 0..1
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 定义简洁的 iOS 风格对勾路径
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0.28 * w, 0.52 * h)
      ..lineTo(0.46 * w, 0.70 * h)
      ..lineTo(0.75 * w, 0.34 * h);

    // 根据进度绘制部分路径
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final first = metrics.first;
    final extractLen = first.length * progress;
    final animated = first.extractPath(0, extractLen);
    canvas.drawPath(animated, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
