import 'package:flutter/material.dart';

import '../window_size_manager.dart';

/// 桌面复杂弹窗的统一尺寸和轮廓样式。
///
/// 尺寸以桌面应用最小窗口为基准放大，紧凑确认框不应使用此比例约束。
abstract final class DesktopDialogStyle {
  static const defaultVerticalInset = 24.0;
  static const defaultVerticalFraction = 0.9;

  static BoxConstraints proportionalConstraints(
    BuildContext context, {
    double? minWidth,
    required double maxWidth,
    required double maxHeight,
    double verticalInset = defaultVerticalInset,
    double verticalFraction = defaultVerticalFraction,
  }) {
    final windowSize = MediaQuery.sizeOf(context);
    final widthScale = (windowSize.width / WindowSizeManager.minWindowWidth)
        .clamp(1.0, double.infinity);
    final availableHeight = (windowSize.height - verticalInset * 2).clamp(
      0.0,
      double.infinity,
    );
    final heightScale = (windowSize.height / WindowSizeManager.minWindowHeight)
        .clamp(1.0, double.infinity);
    return BoxConstraints(
      minWidth: minWidth == null ? 0 : minWidth * widthScale,
      maxWidth: maxWidth * widthScale,
      maxHeight: (maxHeight * heightScale).clamp(
        0.0,
        availableHeight * verticalFraction,
      ),
    );
  }

  static RoundedRectangleBorder shape(
    BuildContext context, {
    double radius = 16,
  }) {
    final cs = Theme.of(context).colorScheme;
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.25)),
    );
  }
}
