import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

class UpdateReleaseNotesCard extends StatelessWidget {
  const UpdateReleaseNotesCard({
    super.key,
    required this.title,
    required this.notes,
    this.onLinkTap,
  });

  final String title;
  final String notes;
  final ValueChanged<String>? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final body = notes.trim();
    final headingBase = TextStyle(
      color: cs.onSurface,
      fontWeight: AppFontWeights.emphasis,
      height: 1.25,
      letterSpacing: 0,
    );

    return Material(
      color: context.appColors.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          width: 0.5,
          color: isDark
              ? cs.onSurface.withValues(alpha: 0.06)
              : cs.outlineVariant.withValues(alpha: 0.12),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Lucide.BadgeInfo, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.emphasis,
                      color: cs.onSurface,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 12),
              GptMarkdownTheme(
                gptThemeData: GptMarkdownThemeData(
                  brightness: theme.brightness,
                  h1: headingBase.copyWith(fontSize: 18),
                  h2: headingBase.copyWith(fontSize: 17),
                  h3: headingBase.copyWith(fontSize: 16),
                  h4: headingBase.copyWith(fontSize: 15),
                  h5: headingBase.copyWith(fontSize: 14),
                  h6: headingBase.copyWith(fontSize: 14),
                  linkColor: cs.primary,
                  linkHoverColor: cs.primary,
                  hrLineColor: cs.outlineVariant,
                  autoAddDividerLineAfterH1: false,
                ),
                child: GptMarkdown(
                  body,
                  textDirection: Directionality.of(context),
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: cs.onSurface.withValues(alpha: 0.85),
                    letterSpacing: 0,
                  ),
                  followLinkColor: true,
                  onLinkTap: onLinkTap == null
                      ? null
                      : (url, _) => onLinkTap!(url),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
