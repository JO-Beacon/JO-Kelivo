part of '../desktop_settings_page.dart';

// ===== 助手（桌面右侧内容） =====

class _DesktopAssistantsBody extends StatefulWidget {
  const _DesktopAssistantsBody({super.key});

  @override
  State<_DesktopAssistantsBody> createState() => _DesktopAssistantsBodyState();
}

class _DesktopAssistantsBodyState extends State<_DesktopAssistantsBody> {
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  void _toggle(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  void _exit() => setState(() {
    _selectionMode = false;
    _selectedIds.clear();
  });

  Future<void> _delete() async {
    final ids = List<String>.of(_selectedIds);
    if (ids.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.assistantSelectionDeleteConfirmTitle),
        content: Text(l10n.assistantSelectionDeleteConfirmContent(ids.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.assistantSettingsDeleteDialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.assistantSelectionDelete),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    for (final id in ids) {
      await ChatActions.cancelActiveGenerationsForAssistant(id);
    }
    if (!mounted) return;
    final assistantProvider = context.read<AssistantProvider>();
    await assistantProvider.deleteAssistants(ids);
    if (!mounted) return;
    final remainingIds = assistantProvider.assistants.map((a) => a.id).toSet();
    await context.read<AssistantGroupProvider>().assignAssistantsToGroup(
      ids.where((id) => !remainingIds.contains(id)),
      null,
    );
    if (mounted) _exit();
  }

  Future<void> _move() async {
    if (_selectedIds.isEmpty) return;
    final groupId = await showAssistantSelectionGroupSheet(context);
    if (!mounted || groupId == null) return;
    await context.read<AssistantGroupProvider>().assignAssistantsToGroup(
      _selectedIds,
      groupId == assistantSelectionUngroupedKey ? null : groupId,
    );
    if (mounted) _exit();
  }

  @override
  Widget build(BuildContext context) {
    final assistants = context.watch<AssistantProvider>().assistantDirectory;
    final cs = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            children: [
              SizedBox(
                height: 36,
                child: Row(
                  children: [
                    if (_selectionMode)
                      AssistantSelectionHeader(
                        selectedCount: _selectedIds.length,
                        allSelected: _selectedIds.length == assistants.length,
                        onCancel: _exit,
                        onToggleSelectAll: () => setState(() {
                          if (_selectedIds.length == assistants.length) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds.addAll(assistants.map((a) => a.id));
                          }
                        }),
                      )
                    else
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            AppLocalizations.of(
                              context,
                            )!.desktopAssistantsListTitle,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: AppFontWeights.regular,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                      ),
                    if (!_selectionMode) ...[
                      _TactileSelectAssistantButton(
                        onTap: () => setState(() => _selectionMode = true),
                      ),
                      _AddAssistantButton(),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor.withValues(alpha: 0.0),
                  ),
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: EdgeInsets.zero,
                    itemCount: assistants.length,
                    onReorderItem: (oldIndex, newIndex) async {
                      if (_selectionMode) return;
                      await context.read<AssistantProvider>().reorderAssistants(
                        oldIndex,
                        newIndex,
                      );
                    },
                    proxyDecorator: (child, index, animation) {
                      return AnimatedBuilder(
                        animation: animation,
                        builder: (context, _) {
                          final t = Curves.easeOutCubic.transform(
                            animation.value,
                          );
                          return Transform.scale(
                            scale: 0.98 + 0.02 * t,
                            child: Material(
                              elevation: 0,
                              shadowColor: Colors.transparent,
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(18),
                              child: child,
                            ),
                          );
                        },
                      );
                    },
                    itemBuilder: (context, index) {
                      final item = assistants[index];
                      final card = Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _DesktopAssistantCard(
                          item: item,
                          selectionMode: _selectionMode,
                          selected: _selectedIds.contains(item.id),
                          onToggleSelect: () => _toggle(item.id),
                          onTap: () => showAssistantDesktopDialog(
                            context,
                            assistantId: item.id,
                          ),
                        ),
                      );
                      return KeyedSubtree(
                        key: ValueKey('desktop-assistant-${item.id}'),
                        child: _selectionMode
                            ? card
                            : ReorderableDragStartListener(
                                index: index,
                                child: card,
                              ),
                      );
                    },
                  ),
                ),
              ),
              if (_selectionMode)
                AssistantSelectionActionBar(
                  selectedCount: _selectedIds.length,
                  onMoveToGroup: _move,
                  onDelete: _delete,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddAssistantButton extends StatefulWidget {
  @override
  State<_AddAssistantButton> createState() => _AddAssistantButtonState();
}

class _TactileSelectAssistantButton extends StatelessWidget {
  const _TactileSelectAssistantButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: AppLocalizations.of(context)!.assistantSelectionActionSelect,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(lucide.Lucide.CheckSquare, size: 17, color: cs.primary),
        splashRadius: 18,
      ),
    );
  }
}

class _AddAssistantButtonState extends State<_AddAssistantButton> {
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
        onTap: () async {
          final assistantProvider = context.read<AssistantProvider>();
          final name = await _showAddAssistantDesktopDialog(context);
          if (name == null || name.trim().isEmpty) return;
          if (!context.mounted) return;
          await assistantProvider.addAssistant(
            name: name.trim(),
            context: context,
            insertAtTop: context
                .read<SettingsProvider>()
                .insertNewAssistantAtTop,
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(lucide.Lucide.Plus, size: 16, color: cs.primary),
        ),
      ),
    );
  }
}

Future<String?> _showAddAssistantDesktopDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  final controller = TextEditingController();
  String? result;
  await showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return Dialog(
        backgroundColor: cs.surface,
        shape: DesktopDialogStyle.shape(ctx),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.assistantSettingsAddSheetTitle,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: MaterialLocalizations.of(
                          ctx,
                        ).closeButtonTooltip,
                        icon: const Icon(lucide.Lucide.X, size: 18),
                        color: cs.onSurface,
                        onPressed: () => Navigator.of(ctx).maybePop(),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: l10n.assistantSettingsAddSheetHint,
                        filled: true,
                        fillColor: ctx.appColors.surfaceFill,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: cs.outlineVariant.withValues(alpha: 0.2),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: cs.primary.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                      onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _DeskIosButton(
                          label: l10n.assistantSettingsAddSheetCancel,
                          filled: false,
                          dense: true,
                          onTap: () => Navigator.of(ctx).pop(),
                        ),
                        const SizedBox(width: 8),
                        _DeskIosButton(
                          label: l10n.assistantSettingsAddSheetSave,
                          filled: true,
                          dense: true,
                          onTap: () =>
                              Navigator.of(ctx).pop(controller.text.trim()),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  ).then((v) => result = v);
  final s = (result ?? '').trim();
  if (s.isEmpty) return null;
  return s;
}

class _DeleteAssistantIcon extends StatefulWidget {
  const _DeleteAssistantIcon({required this.onConfirm});
  final Future<void> Function() onConfirm;
  @override
  State<_DeleteAssistantIcon> createState() => _DeleteAssistantIconState();
}

class _DeleteAssistantIconState extends State<_DeleteAssistantIcon> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? (isDark
              ? cs.error.withValues(alpha: 0.18)
              : cs.error.withValues(alpha: 0.14))
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onConfirm(),
        child: Container(
          margin: const EdgeInsets.only(left: 8),
          width: 28,
          height: 28,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Icon(lucide.Lucide.Trash2, size: 15, color: cs.error),
        ),
      ),
    );
  }
}

class _CopyAssistantIcon extends StatefulWidget {
  const _CopyAssistantIcon({required this.onCopy});
  final Future<void> Function() onCopy;
  @override
  State<_CopyAssistantIcon> createState() => _CopyAssistantIconState();
}

class _CopyAssistantIconState extends State<_CopyAssistantIcon> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? (isDark
              ? cs.primary.withValues(alpha: 0.16)
              : cs.primary.withValues(alpha: 0.12))
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onCopy(),
        child: Container(
          margin: const EdgeInsets.only(left: 8),
          width: 28,
          height: 28,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Icon(lucide.Lucide.Copy, size: 15, color: cs.primary),
        ),
      ),
    );
  }
}

Future<bool?> _confirmDeleteDesktop(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'assistant-delete',
    barrierColor: cs.scrim.withValues(alpha: 0.15),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (ctx, _, __) {
      final dialog = Material(
        color: Colors.transparent,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: cs.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: Theme.of(ctx).brightness == Brightness.dark
                        ? cs.onSurface.withValues(alpha: 0.08)
                        : cs.outlineVariant.withValues(alpha: 0.25),
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 44,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.assistantSettingsDeleteDialogTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: AppFontWeights.emphasis,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              ctx,
                            ).closeButtonTooltip,
                            icon: const Icon(lucide.Lucide.X, size: 18),
                            color: cs.onSurface,
                            onPressed: () => Navigator.of(ctx).maybePop(false),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: cs.outlineVariant.withValues(alpha: 0.12),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l10n.assistantSettingsDeleteDialogContent,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.9),
                            fontSize: 13.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _DeskIosButton(
                              label: l10n.assistantSettingsDeleteDialogCancel,
                              filled: false,
                              dense: true,
                              onTap: () => Navigator.of(ctx).pop(false),
                            ),
                            const SizedBox(width: 8),
                            _DeskIosButton(
                              label: l10n.assistantSettingsDeleteDialogConfirm,
                              filled: true,
                              danger: true,
                              dense: true,
                              onTap: () => Navigator.of(ctx).pop(true),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return dialog;
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

class _DeskIosButton extends StatefulWidget {
  const _DeskIosButton({
    required this.label,
    required this.onTap,
    this.filled = false,
    this.danger = false,
    this.dense = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool filled;
  final bool danger;
  final bool dense;
  @override
  State<_DeskIosButton> createState() => _DeskIosButtonState();
}

class _DeskIosButtonState extends State<_DeskIosButton> {
  bool _pressed = false;
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = widget.danger ? cs.error : cs.primary;
    final textColor = widget.filled
        ? (widget.danger ? cs.onError : cs.onPrimary)
        : baseColor;
    final baseBg = widget.filled
        ? baseColor
        : (isDark ? cs.onSurface.withValues(alpha: 0.10) : Colors.transparent);
    final hoverBg = widget.filled
        ? baseColor.withValues(alpha: 0.92)
        : (cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.04));
    final bg = _hover ? hoverBg : baseBg;
    final borderColor = widget.filled
        ? Colors.transparent
        : baseColor.withValues(alpha: isDark ? 0.6 : 0.5);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: EdgeInsets.symmetric(
              vertical: widget.dense ? 8 : 12,
              horizontal: 12,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: textColor,
                fontWeight: AppFontWeights.semibold,
                fontSize: widget.dense ? 13 : 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopAssistantCard extends StatefulWidget {
  const _DesktopAssistantCard({
    required this.item,
    required this.onTap,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelect,
  });
  final AssistantListItem item;
  final VoidCallback onTap;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  @override
  State<_DesktopAssistantCard> createState() => _DesktopAssistantCardState();
}

class _DesktopAssistantCardState extends State<_DesktopAssistantCard> {
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
      child: _CardPress(
        onTap: widget.selectionMode ? widget.onToggleSelect : widget.onTap,
        pressedScale: 1.0,
        builder: (pressed, overlay) => Container(
          decoration: BoxDecoration(
            color: Color.alphaBlend(overlay, baseBg),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: 1.0),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.selectionMode) ...[
                  IosCheckbox(
                    value: widget.selected,
                    size: 22,
                    hitTestSize: 30,
                    enableHaptics: false,
                    onChanged: (_) => widget.onToggleSelect(),
                  ),
                  const SizedBox(width: 10),
                ],
                _AssistantAvatarDesktop(item: widget.item, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: AppFontWeights.emphasis,
                              ),
                            ),
                          ),
                          if (!widget.selectionMode)
                            _CopyAssistantIcon(
                              onCopy: () async {
                                final assistantProvider = context
                                    .read<AssistantProvider>();
                                final l10n = AppLocalizations.of(context)!;
                                final newId = await assistantProvider
                                    .duplicateAssistant(
                                      widget.item.id,
                                      l10n: l10n,
                                      insertAtTop: context
                                          .read<SettingsProvider>()
                                          .insertNewAssistantAtTop,
                                    );
                                if (!context.mounted) return;
                                if (newId != null) {
                                  showAppSnackBar(
                                    context,
                                    message: l10n.assistantSettingsCopySuccess,
                                    type: NotificationType.success,
                                  );
                                }
                              },
                            ),
                          if (!widget.selectionMode)
                            _DeleteAssistantIcon(
                              onConfirm: () async {
                                final assistantProvider = context
                                    .read<AssistantProvider>();
                                final l10n = AppLocalizations.of(context)!;
                                final count =
                                    assistantProvider.assistants.length;
                                if (count <= 1) {
                                  showAppSnackBar(
                                    context,
                                    message: l10n
                                        .assistantSettingsAtLeastOneAssistantRequired,
                                    type: NotificationType.warning,
                                  );
                                  return;
                                }
                                final ok = await _confirmDeleteDesktop(context);
                                if (ok == true) {
                                  if (!context.mounted) return;
                                  await ChatActions.cancelActiveGenerationsForAssistant(
                                    widget.item.id,
                                  );
                                  if (!context.mounted) return;
                                  final success = await assistantProvider
                                      .deleteAssistant(widget.item.id);
                                  if (!context.mounted) return;
                                  if (success != true) {
                                    showAppSnackBar(
                                      context,
                                      message: l10n
                                          .assistantSettingsAtLeastOneAssistantRequired,
                                      type: NotificationType.warning,
                                    );
                                  }
                                }
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        (widget.item.promptPreview.trim().isEmpty
                            ? AppLocalizations.of(
                                context,
                              )!.assistantSettingsNoPromptPlaceholder
                            : widget.item.promptPreview),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.7),
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantAvatarDesktop extends StatelessWidget {
  const _AssistantAvatarDesktop({required this.item, this.size = 40});
  final AssistantListItem item;
  final double size;
  @override
  Widget build(BuildContext context) =>
      AssistantAvatar.fromListItem(item: item, size: size);
}
