import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

/// 带有跨平台对齐微调的单 emoji Text widget。
class EmojiText extends StatelessWidget {
  const EmojiText(
    this.text, {
    super.key,
    this.fontSize = 20,
    this.figmaLineHeight,
    this.lineHeight,
    this.textAlign = TextAlign.center,
    this.optimizeEmojiAlign = true,
    this.nudge,
  });

  final String text;
  final double fontSize;
  final double? figmaLineHeight;
  final double? lineHeight;
  final TextAlign textAlign;
  final bool optimizeEmojiAlign;
  final Offset? nudge; // 可选显式偏移覆盖

  @override
  Widget build(BuildContext context) {
    // 确保最多渲染一个字符（ZWJ 序列保持完整）
    final String glyph = text.characters.take(1).toString();

    // Windows 上可选执行平台特定缩放，以减少行抖动
    final bool isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    const double winScale = 0.9;
    final double scaleFactor = isWindows ? winScale : 1.0;
    double fs = fontSize * scaleFactor;

    // 根据 figmaLineHeight 或显式 lineHeight 计算有效高度
    double? effectiveHeight;
    if (figmaLineHeight != null && figmaLineHeight! > 0) {
      // 高度是行像素与当前字体大小的比值
      effectiveHeight = figmaLineHeight! / fs;
    } else if (lineHeight != null && lineHeight! > 0) {
      // 缩放字体时保持视觉行高稳定
      effectiveHeight = (lineHeight! / scaleFactor) / fs;
    } else if (optimizeEmojiAlign) {
      // 默认使用 1.0，以获得稳定紧凑的单 emoji 行
      effectiveHeight = 1.0;
    }

    // 通用回退字体族，提高 emoji 可用性。
    // 这些字体只有在系统中存在时才会生效。
    const List<String> fallback = <String>[
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Noto Color Emoji',
      'Twemoji Mozilla',
      'EmojiOne Color',
    ];

    final TextStyle base = DefaultTextStyle.of(context).style;
    final TextStyle style = base.copyWith(
      fontSize: fs,
      height: effectiveHeight,
      // 促进均匀的行距分布，以获得更好的视觉居中效果
      leadingDistribution: optimizeEmojiAlign
          ? TextLeadingDistribution.even
          : null,
      fontFamilyFallback: fallback,
      decoration: TextDecoration.none,
    );

    // 根据平台进行微小偏移，抵消平台字体边距差异。
    double dx = 0, dy = 0;
    if (optimizeEmojiAlign) {
      if (nudge != null) {
        dx = nudge!.dx;
        dy = nudge!.dy;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS
        dx = fs * 0.04; // 约 5% 右移
        dy = fs * -0.075; // 约 1.2% 上移
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        // macOS
        dx = fs * 0.08; // 约 3.5% 右移
        dy = fs * -0.008; // 约 0.8% 上移
      } else if (isWindows) {
        // Windows（Segoe UI Emoji）
        dx = fs * 0.015; // 轻微右移
        dy = 0;
      } else {
        // Linux/其他（Noto 等）
        dx = fs * 0.012; // 微小右移
        dy = 0;
      }
    }

    return Transform.translate(
      offset: Offset(dx, dy),
      child: Text(
        glyph,
        textAlign: textAlign,
        style: style,
        // 使用 StrutStyle 稳定跨平台行度量
        strutStyle: StrutStyle(
          forceStrutHeight: true,
          height: style.height,
          leading: 0,
          fontSize: style.fontSize,
          fontFamily: style.fontFamily,
          fontFamilyFallback: style.fontFamilyFallback,
        ),
      ),
    );
  }
}
