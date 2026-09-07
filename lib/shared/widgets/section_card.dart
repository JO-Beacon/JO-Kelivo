import 'package:flutter/material.dart';

import '../../theme/app_semantic_colors.dart';

/// JO-AIClient 本地版 SectionCard：上游 1.2.5 的 section_card 依赖
/// hairline/hairlineStrong 与 useLayeredSheetTiles（1.2.6 的分层表单瓦片），
/// 本仓库尚无这些字段，这里以 ColorScheme 直接推导等价视觉。
enum SectionCardVariant { standard, emphasized }

/// Shared iOS-style section card: one step above the page surface.
///
/// Use [children] for stacked rows or [child] for a single body. Optional
/// [padding], [radius], and [shadow] override the defaults.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.children,
    this.child,
    this.padding,
    this.radius,
    this.variant = SectionCardVariant.standard,
    this.shadow,
    this.dividers = false,
  }) : assert(
         children != null || child != null,
         'Provide either children or child',
       );

  final List<Widget>? children;
  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final double? radius;
  final SectionCardVariant variant;
  final List<BoxShadow>? shadow;
  final bool dividers;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final cs = Theme.of(context).colorScheme;
    final emphasized = variant == SectionCardVariant.emphasized;
    final resolvedRadius = radius ?? (emphasized ? 18.0 : 12.0);
    final borderColor = emphasized
        ? cs.outlineVariant.withValues(alpha: 0.45)
        : cs.outlineVariant.withValues(alpha: 0.22);
    final resolvedPadding =
        padding ??
        (child != null && children == null
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(vertical: 4));
    final body = children != null
        ? Column(
            children: [
              for (int i = 0; i < children!.length; i++) ...[
                if (dividers && i > 0)
                  Divider(
                    height: 10,
                    thickness: 0.6,
                    color: cs.outlineVariant.withValues(alpha: 0.18),
                  ),
                children![i],
              ],
            ],
          )
        : child!;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceCard,
        borderRadius: BorderRadius.circular(resolvedRadius),
        border: Border.all(color: borderColor, width: 0.6),
        boxShadow: shadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: resolvedPadding, child: body),
    );
  }
}
