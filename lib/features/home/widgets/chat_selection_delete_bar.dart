import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/design_tokens.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

/// 多选删除底栏：始终只呈现一个删除按钮。
///
/// 勾选里含分支节点时，删除会收拢所选目标所属的分叉、仅保留活动血脉，
/// 按钮文案随之改为「删除此分支节点」以提示这一语义；不含分支节点时
/// 为普通的「删除」。原先并列的「删除所有分支」入口已移除——它的作用
/// 范围完全由树结构决定、与勾选内容无关，多选并不能带来任何选择余地。
class ChatSelectionDeleteBar extends StatelessWidget {
  const ChatSelectionDeleteBar({
    super.key,
    required this.hasMultiVersionSelection,
    required this.onDeleteCurrentVersions,
  });

  final bool hasMultiVersionSelection;
  final VoidCallback onDeleteCurrentVersions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    final bg = cs.surface.withValues(alpha: isDark ? 0.35 : 0.78);
    final shadowColor = cs.shadow.withValues(alpha: isDark ? 0.40 : 0.10);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: 22,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: ColoredBox(
            color: bg,
            child: SafeArea(
              top: false,
              left: false,
              right: false,
              bottom: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 380;
                    return SizedBox(
                      width: double.infinity,
                      child: _DeleteButton(
                        icon: Lucide.Trash2,
                        label: hasMultiVersionSelection
                            ? l10n.homePageDeleteMessageNode
                            : l10n.homePageDelete,
                        color: cs.error,
                        onTap: onDeleteCurrentVersions,
                        dense: compact,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    required this.dense,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final bg = Color.alphaBlend(
      cs.onSurface.withValues(alpha: 0.04),
      color.withValues(alpha: isDark ? 0.18 : 0.14),
    );

    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      baseColor: bg,
      pressedBlendStrength: isDark ? 0.20 : 0.16,
      pressedScale: 0.98,
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 10)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: dense ? 16 : 18, color: color),
            SizedBox(width: dense ? 4 : 6),
            Text(
              label,
              style: TextStyle(
                fontSize: dense ? 13 : 14,
                fontWeight: AppFontWeights.medium,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
