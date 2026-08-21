import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/models/instruction_injection.dart';
import '../../../l10n/app_localizations.dart';
import 'package:Kelivo/theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

/// 用于编辑当前指令注入提示词的底部面板。
///
/// 此组件允许用户直接编辑指令注入项的提示词文本。
class LearningPromptSheet extends StatefulWidget {
  const LearningPromptSheet({super.key, required this.target});

  /// 要编辑的指令注入项。
  final InstructionInjection target;

  @override
  State<LearningPromptSheet> createState() => _LearningPromptSheetState();
}

class _LearningPromptSheetState extends State<LearningPromptSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.target.prompt);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.bottomToolsSheetPrompt,
              style: TextStyle(
                fontSize: 16,
                fontWeight: AppFontWeights.semibold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              maxLines: 10,
              decoration: InputDecoration(
                hintText: l10n.bottomToolsSheetPromptHint,
                filled: true,
                fillColor: context.appColors.surfaceFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: cs.primary.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Spacer(),
                FilledButton(
                  onPressed: () async {
                    final updated = widget.target.copyWith(
                      prompt: _controller.text.trim(),
                    );
                    await context.read<InstructionInjectionProvider>().update(
                      updated,
                    );
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(l10n.bottomToolsSheetSave),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 显示学习提示词底部面板。
///
/// 此函数初始化 provider 并显示用于编辑当前指令注入项提示词的面板。
Future<void> showLearningPromptSheet(BuildContext context) async {
  final provider = context.read<InstructionInjectionProvider>();
  await provider.initialize();
  if (!context.mounted) return;
  final items = provider.items;
  if (items.isEmpty) return;
  final target = provider.active ?? items.first;
  final cs = Theme.of(context).colorScheme;

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return LearningPromptSheet(target: target);
    },
  );
}
