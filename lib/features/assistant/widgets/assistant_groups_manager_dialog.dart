import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/assistant_group_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

Future<void> showAssistantGroupsManagerDialog(
  BuildContext context, {
  required String assistantId,
}) async {
  final cs = Theme.of(context).colorScheme;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'assistant-groups-manager',
    barrierColor: cs.scrim.withValues(alpha: 0.15),
    pageBuilder: (ctx, _, __) {
      // 使用全屏点击区域，允许点击对话框外部关闭。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(ctx).maybePop(),
        child: Material(
          type: MaterialType.transparency,
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {}, // 吸收对话框内的点击
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 520,
                  maxHeight: 600,
                ),
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: Theme.of(ctx).colorScheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: Theme.of(ctx).brightness == Brightness.dark
                            ? cs.onSurface.withValues(alpha: 0.08)
                            : cs.outlineVariant.withValues(alpha: 0.2),
                      ),
                    ),
                  ),
                  child: _AssistantGroupsManagerBody(
                    assistantId: assistantId,
                    isDialog: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _AssistantGroupsManagerBody extends StatefulWidget {
  const _AssistantGroupsManagerBody({
    required this.assistantId,
    required this.isDialog,
  });
  final String assistantId;
  final bool isDialog;

  @override
  State<_AssistantGroupsManagerBody> createState() =>
      _AssistantGroupsManagerBodyState();
}

class _AssistantGroupsManagerBodyState
    extends State<_AssistantGroupsManagerBody> {
  Future<void> _createGroup(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
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
      final name = c.text.trim();
      if (name.isEmpty) return; // 无效；在对话框中静默忽略
      if (!context.mounted) return;
      final groupProvider = context.read<AssistantGroupProvider>();
      // 按名称防止重复
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
      final name = c.text.trim();
      if (name.isEmpty) return;
      if (!context.mounted) return;
      final groupProvider = context.read<AssistantGroupProvider>();
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
      await context.read<AssistantGroupProvider>().deleteGroup(groupId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groupProvider = context.watch<AssistantGroupProvider>();
    final groups = groupProvider.groups;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶栏无底部分隔线；桌面小按钮，无涟漪
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.assistantGroupsManageTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ),
                _SmallIconBtn(
                  icon: Lucide.Plus,
                  onTap: () => _createGroup(context),
                ),
                const SizedBox(width: 6),
                _SmallIconBtn(
                  icon: Lucide.X,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: groups.length,
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) {
              // 拖动时无阴影或海拔；只返回卡片本身并带细微缩放。
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
                key: ValueKey('assistant-group-${group.id}'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                  child: ReorderableDragStartListener(
                    index: i,
                    child: _GroupCard(
                      title: group.name,
                      onTap: () async {
                        await context
                            .read<AssistantGroupProvider>()
                            .assignAssistantToGroup(
                              widget.assistantId,
                              group.id,
                            );
                        if (widget.isDialog && context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                      onRename: () =>
                          _renameGroup(context, group.id, group.name),
                      onDelete: () => _deleteGroup(context, group.id),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SmallIconBtn extends StatefulWidget {
  const _SmallIconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  State<_SmallIconBtn> createState() => _SmallIconBtnState();
}

class _SmallIconBtnState extends State<_SmallIconBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? (cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.05))
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 18, color: cs.onSurface),
        ),
      ),
    );
  }
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({
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
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = context.appColors.surfaceCard;
    final borderColor = _hover
        ? cs.primary.withValues(alpha: isDark ? 0.35 : 0.45)
        : cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: baseBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1.0),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SmallIconBtn(icon: Lucide.Pencil, onTap: widget.onRename),
              const SizedBox(width: 6),
              _SmallIconBtn(icon: Lucide.Trash2, onTap: widget.onDelete),
            ],
          ),
        ),
      ),
    );
  }
}
