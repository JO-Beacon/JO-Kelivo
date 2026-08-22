import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/assistant_group_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_tactile.dart';
import 'package:Kelivo/theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

class AssistantGroupsManagerPage extends StatefulWidget {
  const AssistantGroupsManagerPage({super.key, required this.assistantId});
  final String assistantId;

  @override
  State<AssistantGroupsManagerPage> createState() =>
      _AssistantGroupsManagerPageState();
}

class _AssistantGroupsManagerPageState
    extends State<AssistantGroupsManagerPage> {
  Future<void> _createGroup(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final groupProvider = context.read<AssistantGroupProvider>();
    final TextEditingController c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.assistantGroupsCreateDialogTitle),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.assistantGroupsNameHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.assistantGroupsCreateDialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.assistantGroupsCreateDialogOk),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (!context.mounted) return;
      final name = c.text.trim();
      if (name.isEmpty) return;
      if (groupProvider.groups.any((group) => group.name == name)) return;
      await groupProvider.createGroup(name);
    }
  }

  Future<void> _renameGroup(
    BuildContext context,
    String groupId,
    String oldName,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final groupProvider = context.read<AssistantGroupProvider>();
    final TextEditingController c = TextEditingController(text: oldName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.assistantGroupsRenameDialogTitle),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.assistantGroupsNameHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.assistantGroupsCreateDialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.assistantGroupsRenameDialogOk),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (!context.mounted) return;
      final name = c.text.trim();
      if (name.isEmpty) return;
      if (groupProvider.groups.any(
        (group) => group.name == name && group.id != groupId,
      )) {
        return;
      }
      await groupProvider.renameGroup(groupId, name);
    }
  }

  Future<void> _deleteGroup(BuildContext context, String groupId) async {
    final l10n = AppLocalizations.of(context)!;
    final groupProvider = context.read<AssistantGroupProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.assistantGroupsDeleteConfirmTitle),
        content: Text(l10n.assistantGroupsDeleteConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.assistantGroupsDeleteConfirmCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.assistantGroupsDeleteConfirmOk),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (!context.mounted) return;
      await groupProvider.deleteGroup(groupId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groupProvider = context.watch<AssistantGroupProvider>();
    final groups = groupProvider.groups;
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 52,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: IosIconButton(
            icon: Lucide.ChevronLeft,
            minSize: 44,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.assistantGroupsManageTitle),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IosIconButton(
              icon: Lucide.Plus,
              minSize: 44,
              onTap: () => _createGroup(context),
            ),
          ),
        ],
      ),
      body: ReorderableListView.builder(
        itemCount: groups.length,
        buildDefaultDragHandles: false,
        proxyDecorator: (child, index, animation) {
          // 拖动时无阴影；只有轻微缩放
          return ScaleTransition(
            scale: Tween<double>(begin: 1.0, end: 1.02).animate(animation),
            child: child,
          );
        },
        onReorderItem: (oldIndex, newIndex) async {
          await context.read<AssistantGroupProvider>().reorderGroups(
            oldIndex,
            newIndex,
          );
        },
        itemBuilder: (ctx, i) {
          final group = groups[i];
          return KeyedSubtree(
            key: ValueKey('assistant-group-mobile-${group.id}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: ReorderableDelayedDragStartListener(
                index: i,
                child: _MobileGroupCard(
                  title: group.name,
                  onTap: () async {
                    await context
                        .read<AssistantGroupProvider>()
                        .assignAssistantToGroup(widget.assistantId, group.id);
                    if (!context.mounted) return;
                    Navigator.of(context).maybePop();
                  },
                  onRename: () => _renameGroup(context, group.id, group.name),
                  onDelete: () => _deleteGroup(context, group.id),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MobileGroupCard extends StatelessWidget {
  const _MobileGroupCard({
    required this.title,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });
  final String title;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = context.appColors.surfaceFill;
    final borderColor = cs.outlineVariant.withValues(
      alpha: isDark ? 0.12 : 0.10,
    );
    Widget iconBtn(IconData icon, VoidCallback onPressed, {Color? color}) {
      return IosCardPress(
        baseColor: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 18, color: color ?? cs.onSurface),
      );
    }

    return IosCardPress(
      baseColor: bg,
      borderRadius: BorderRadius.circular(14),
      pressedBlendStrength: 0.06,
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: 1.0),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
            ),
            iconBtn(Lucide.Pencil, onRename),
            const SizedBox(width: 4),
            iconBtn(Lucide.Trash2, onDelete, color: cs.error),
          ],
        ),
      ),
    );
  }
}
