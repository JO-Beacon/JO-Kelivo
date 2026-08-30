import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/assistant_group_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';

const assistantSelectionUngroupedKey = '__assistant_ungrouped__';

class AssistantSelectionHeader extends StatelessWidget {
  const AssistantSelectionHeader({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onCancel,
    required this.onToggleSelectAll,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback onCancel;
  final VoidCallback onToggleSelectAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        IosIconButton(
          icon: Lucide.X,
          size: 22,
          minSize: 36,
          semanticLabel: l10n.assistantSettingsAddSheetCancel,
          onTap: onCancel,
        ),
        Expanded(
          child: Text(
            l10n.assistantSelectionTitle(selectedCount),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface,
            ),
          ),
        ),
        IosCardPress(
          baseColor: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          onTap: onToggleSelectAll,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IgnorePointer(
                child: IosCheckbox(
                  value: allSelected,
                  size: 18,
                  hitTestSize: 32,
                  enableHaptics: false,
                  onChanged: (_) {},
                ),
              ),
              const SizedBox(width: 2),
              Text(
                allSelected
                    ? l10n.assistantSelectionDeselectAll
                    : l10n.assistantSelectionSelectAll,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class AssistantSelectionActionBar extends StatelessWidget {
  const AssistantSelectionActionBar({
    super.key,
    required this.selectedCount,
    required this.onMoveToGroup,
    required this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onMoveToGroup;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final enabled = selectedCount > 0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: _Action(
                icon: Lucide.Folder,
                label: l10n.assistantSelectionMoveToGroup,
                color: cs.primary,
                enabled: enabled,
                onTap: onMoveToGroup,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Action(
                icon: Lucide.Trash2,
                label: l10n.assistantSelectionDelete,
                color: cs.error,
                enabled: enabled,
                onTap: onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IosCardPress(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(14),
      baseColor: color.withValues(alpha: 0.13),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontWeight: AppFontWeights.medium,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> showAssistantSelectionGroupSheet(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<String?>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final l10n = AppLocalizations.of(ctx)!;
      final groups = ctx.watch<AssistantGroupProvider>().groups;
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.assistantSelectionGroupPickerTitle,
                style: TextStyle(fontWeight: AppFontWeights.emphasis),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _GroupOption(
                      title: l10n.assistantSelectionGroupUngrouped,
                      onTap: () =>
                          Navigator.of(ctx).pop(assistantSelectionUngroupedKey),
                    ),
                    for (final group in groups)
                      _GroupOption(
                        title: group.name,
                        onTap: () => Navigator.of(ctx).pop(group.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _GroupOption extends StatelessWidget {
  const _GroupOption({required this.title, required this.onTap});
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: IosCardPress(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        baseColor: cs.surface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
