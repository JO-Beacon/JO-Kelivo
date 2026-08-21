import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../utils/brand_assets.dart';
import '../../../theme/app_font_weights.dart';

/// 显示当前模型图标的组件。
///
/// 显示以下内容之一：
/// - 如果模型/供应商有可用的品牌 SVG/PNG 图标
/// - 使用模型名称首字母的圆形占位符
class CurrentModelIcon extends StatelessWidget {
  const CurrentModelIcon({
    super.key,
    required this.providerKey,
    required this.modelId,
    this.size = 28,
    this.withBackground = true,
    this.backgroundColor,
  });

  final String? providerKey;
  final String? modelId;
  final double size; // 外径
  final bool withBackground; // 是否绘制圆形背景
  final Color? backgroundColor; // 如果提供则覆盖背景颜色

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (providerKey == null || modelId == null) return const SizedBox.shrink();

    String? asset = BrandAssets.assetForName(modelId!);
    asset ??= BrandAssets.assetForName(providerKey!);

    Widget inner;
    if (asset != null) {
      if (asset.endsWith('.svg')) {
        final ColorFilter? tint =
            (Theme.of(context).brightness == Brightness.dark &&
                BrandAssets.assetNeedsDarkInvert(asset))
            ? ColorFilter.mode(cs.onSurface, BlendMode.srcIn)
            : null;
        inner = SvgPicture.asset(
          asset,
          width: size * 0.5,
          height: size * 0.5,
          colorFilter: tint,
        );
      } else {
        inner = Image.asset(
          asset,
          width: size * 0.5,
          height: size * 0.5,
          fit: BoxFit.contain,
        );
      }
    } else {
      inner = Text(
        modelId!.isNotEmpty ? modelId!.characters.first.toUpperCase() : '?',
        style: TextStyle(
          color: cs.primary,
          fontWeight: AppFontWeights.emphasis,
          fontSize: size * 0.43,
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: withBackground
            ? (backgroundColor ??
                  (cs.primary.withValues(alpha: isDark ? 0.18 : 0.1)))
            : Colors.transparent,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: SizedBox(
        width: size * 0.64,
        height: size * 0.64,
        child: Center(
          child: inner is SvgPicture || inner is Image
              ? inner
              : FittedBox(child: inner),
        ),
      ),
    );
  }
}
