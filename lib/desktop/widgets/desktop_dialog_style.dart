import 'package:flutter/material.dart';

import '../window_size_manager.dart';

/// 桌面复杂弹窗的统一尺寸和轮廓样式。
///
/// 尺寸以桌面应用最小窗口为基准放大，紧凑确认框不应使用此比例约束。
abstract final class DesktopDialogStyle {
  static const defaultVerticalInset = 24.0;
  static const defaultVerticalFraction = 0.9;

  /// 大中弹窗的三档命名尺寸，同类弹窗必须使用同一档位。
  ///
  /// - [editor]：写大段内容的编辑窗（助手编辑、消息编辑、放大窗口、JSON/HTML 预览等）。
  /// - [form]：填表单/配置的中型弹窗（供应商、模型、MCP、TTS、世界书、备份、记忆等）。
  /// - [compact]：轻量列表选择窗（会话历史、选择复制等）。
  static BoxConstraints editorConstraints(BuildContext context) =>
      proportionalConstraints(
        context,
        minWidth: 720,
        maxWidth: 860,
        maxHeight: 700,
      );

  static BoxConstraints formConstraints(BuildContext context) =>
      proportionalConstraints(
        context,
        minWidth: 560,
        maxWidth: 720,
        maxHeight: 660,
      );

  static BoxConstraints compactConstraints(BuildContext context) =>
      proportionalConstraints(
        context,
        minWidth: 420,
        maxWidth: 560,
        maxHeight: 620,
      );

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
