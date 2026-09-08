import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/models/message_part.dart';
import '../../../desktop/widgets/desktop_dialog_style.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';
import 'message_attachment_editor.dart';

/// 单个文本部件编辑框最多显示的行数，超出后在编辑框内部滚动。
///
/// 这个上限不能去掉改成「不限高」：编辑框所在的列表是自适应高度的，不限高时
/// 它会把内容整个撑开、自己永远不可滚，滚轮只能去滚外层的滚动容器；而 Flutter
/// 在「按住拖拽选择的同时外层发生滚动」这条路径上对选区起点的补偿是错的
/// （flutter/flutter#69296），表现为选中的范围会跑偏。限高之后编辑框自身可滚，
/// 滚轮落在编辑框内，走的是框架处理正确的那条路径。
/// 需要通读长内容时用标题栏的放大按钮打开大窗口。
const int _maxPartEditorLines = 8;

/// 节点级部件编辑器：正文可编辑，思考和工具部件只读但可移动/删除。
class MessagePartsEditor extends StatefulWidget {
  const MessagePartsEditor({
    super.key,
    required this.parts,
    required this.onChanged,
  });

  final List<MessagePart> parts;
  final ValueChanged<List<MessagePart>> onChanged;

  @override
  State<MessagePartsEditor> createState() => _MessagePartsEditorState();
}

class _MessagePartsEditorState extends State<MessagePartsEditor> {
  late List<MessagePart> _parts;
  final Map<int, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    _parts = List<MessagePart>.of(widget.parts);
  }

  @override
  void didUpdateWidget(covariant MessagePartsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.parts, widget.parts)) {
      _parts = List<MessagePart>.of(widget.parts);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(int index, String text) {
    final controller = _controllers.putIfAbsent(
      index,
      () => TextEditingController(text: text),
    );
    if (controller.text != text && !_editing(index)) controller.text = text;
    return controller;
  }

  bool _editing(int index) => _controllers[index]?.selection.isValid == true;

  void _emit() => widget.onChanged(List<MessagePart>.unmodifiable(_parts));

  Future<void> _remove(int index) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Theme.of(dctx).colorScheme.surface,
        title: Text(l10n.messageEditDeletePartConfirmTitle),
        content: Text(l10n.messageEditDeletePartConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(l10n.messageEditCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(l10n.messageEditDeletePart),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _parts.removeAt(index);
    final old = _controllers.remove(index);
    old?.dispose();
    _emit();
    setState(() {});
  }

  void _reorder(int oldIndex, int newIndex) {
    final part = _parts.removeAt(oldIndex);
    _parts.insert(newIndex, part);
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _emit();
    setState(() {});
  }

  void _addText() {
    _parts.add(const TextPart(''));
    _emit();
    setState(() {});
  }

  /// 在大窗口中编辑（正文）或查看（思考 / 工具等只读部件）。
  Future<void> _expandPart(int index) async {
    final part = _parts[index];
    final l10n = AppLocalizations.of(context)!;
    final editable = part is TextPart;
    final initial = part is TextPart
        ? (_controllers[index]?.text ?? part.text)
        : _partSummary(part);
    final title = '${_partLabel(l10n, part)} ${index + 1}';
    final next = await showMessagePartExpandedEditor(
      context,
      title: title,
      initialText: initial,
      readOnly: !editable,
    );
    if (!mounted || next == null || !editable || next == initial) return;
    _parts[index] = TextPart(next);
    _controllers[index]?.text = next;
    _emit();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _parts.length,
          onReorderItem: _reorder,
          itemBuilder: (context, index) {
            final part = _parts[index];
            return _PartCard(
              key: ValueKey('part-$index-${part.kind}'),
              index: index,
              part: part,
              controller: part is TextPart
                  ? _controllerFor(index, part.text)
                  : null,
              onTextChanged: part is TextPart
                  ? (value) {
                      _parts[index] = TextPart(value);
                      _emit();
                    }
                  : null,
              onDelete: () => unawaited(_remove(index)),
              onExpand: () => unawaited(_expandPart(index)),
              dragHandle: ReorderableDragStartListener(
                index: index,
                child: Icon(
                  Lucide.GripVertical,
                  size: 18,
                  color: cs.onSurface.withValues(alpha: 0.45),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        IosCardPress(
          onTap: _addText,
          borderRadius: BorderRadius.circular(12),
          baseColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            l10n.messageEditAddTextPart,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: AppFontWeights.emphasis,
            ),
          ),
        ),
        const SizedBox(height: 8),
        MessageAttachmentEditor(
          parts: _parts,
          onChanged: (parts) {
            _parts = List<MessagePart>.of(parts);
            _emit();
            setState(() {});
          },
        ),
      ],
    );
  }
}

class _PartCard extends StatelessWidget {
  const _PartCard({
    super.key,
    required this.index,
    required this.part,
    required this.controller,
    required this.onTextChanged,
    required this.onDelete,
    required this.onExpand,
    required this.dragHandle,
  });

  final int index;
  final MessagePart part;
  final TextEditingController? controller;
  final ValueChanged<String>? onTextChanged;
  final VoidCallback onDelete;
  final VoidCallback onExpand;
  final Widget dragHandle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final label = _partLabel(l10n, part);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.06),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                dragHandle,
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$label ${index + 1}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                IosIconButton(
                  icon: Lucide.Maximize2,
                  size: 18,
                  color: cs.primary,
                  semanticLabel: l10n.messageEditExpandPart,
                  onTap: onExpand,
                ),
                IosIconButton(
                  icon: Lucide.Trash2,
                  size: 18,
                  color: cs.error,
                  semanticLabel: l10n.messageEditDeletePart,
                  onTap: onDelete,
                ),
              ],
            ),
            if (part is TextPart)
              IosFormTextField(
                label: '',
                controller: controller!,
                hintText: l10n.messageEditTextPart,
                minLines: 3,
                maxLines: _maxPartEditorLines,
                onChanged: onTextChanged,
                outerPadding: EdgeInsets.zero,
              )
            else
              Text(
                _partSummary(part),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65)),
              ),
          ],
        ),
      ),
    );
  }
}

String _partLabel(AppLocalizations l10n, MessagePart part) => switch (part) {
  TextPart() => l10n.messageEditTextPart,
  ReasoningPart() => l10n.messageEditReasoningPart,
  ToolCallPart() => l10n.messageEditToolCallPart,
  ImagePart() => l10n.messageEditImagePart,
  FilePart() => l10n.messageEditFilePart,
  UnknownPart() => l10n.messageEditUnknownPart,
  MalformedPart() => l10n.messageEditUnknownPart,
};

/// 只读部件在卡片和大窗口里展示的文本。
String _partSummary(MessagePart part) {
  if (part is ReasoningPart) return part.text;
  if (part is ToolCallPart) {
    try {
      final value = jsonDecode(part.payloadJson);
      return value is Map ? jsonEncode(value) : part.payloadJson;
    } catch (_) {
      return part.payloadJson;
    }
  }
  if (part is ImagePart) return part.uri;
  if (part is FilePart) return '${part.name}\n${part.uri}';
  return part.encodePayload();
}

/// 打开大窗口编辑或查看单个部件的完整内容。
///
/// [readOnly] 为 true 时只展示（仍可选中复制），不返回新内容。
/// 关闭或取消返回 null；正文部件点保存才返回新文本。
Future<String?> showMessagePartExpandedEditor(
  BuildContext context, {
  required String title,
  required String initialText,
  required bool readOnly,
}) {
  final platform = Theme.of(context).platform;
  final isDesktopPlatform = platform == TargetPlatform.macOS ||
      platform == TargetPlatform.linux ||
      platform == TargetPlatform.windows;
  if (isDesktopPlatform) {
    final cs = Theme.of(context).colorScheme;
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: cs.surface,
        shape: DesktopDialogStyle.shape(ctx),
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: 24,
        ),
        child: _ExpandedPartDesktopDialog(
          title: title,
          initialText: initialText,
          readOnly: readOnly,
        ),
      ),
    );
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _ExpandedPartMobileSheet(
      title: title,
      initialText: initialText,
      readOnly: readOnly,
    ),
  );
}

class _ExpandedPartDesktopDialog extends StatefulWidget {
  const _ExpandedPartDesktopDialog({
    required this.title,
    required this.initialText,
    required this.readOnly,
  });

  final String title;
  final String initialText;
  final bool readOnly;

  @override
  State<_ExpandedPartDesktopDialog> createState() =>
      _ExpandedPartDesktopDialogState();
}

class _ExpandedPartDesktopDialogState
    extends State<_ExpandedPartDesktopDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: DesktopDialogStyle.proportionalConstraints(
        context,
        maxWidth: 860,
        maxHeight: 660,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    icon: Icon(
                      Lucide.X,
                      size: 18,
                      color: cs.onSurface.withValues(alpha: 0.75),
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              thickness: 0.6,
              color: cs.outlineVariant.withValues(alpha: 0.14),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: _ExpandedPartField(
                  controller: _controller,
                  readOnly: widget.readOnly,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      widget.readOnly
                          ? MaterialLocalizations.of(context).closeButtonLabel
                          : l10n.messageEditCancel,
                    ),
                  ),
                  if (!widget.readOnly) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(
                        _controller.text,
                      ),
                      child: Text(
                        l10n.messageEditExpandedSave,
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: AppFontWeights.semibold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandedPartMobileSheet extends StatefulWidget {
  const _ExpandedPartMobileSheet({
    required this.title,
    required this.initialText,
    required this.readOnly,
  });

  final String title;
  final String initialText;
  final bool readOnly;

  @override
  State<_ExpandedPartMobileSheet> createState() =>
      _ExpandedPartMobileSheetState();
}

class _ExpandedPartMobileSheetState extends State<_ExpandedPartMobileSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.96,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, 16, bottom + 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(
                    widget.readOnly
                        ? MaterialLocalizations.of(context).closeButtonLabel
                        : l10n.messageEditCancel,
                  ),
                ),
                if (!widget.readOnly)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(
                      _controller.text,
                    ),
                    child: Text(
                      l10n.messageEditExpandedSave,
                      style: TextStyle(
                        color: cs.primary,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _ExpandedPartField(
                controller: _controller,
                readOnly: widget.readOnly,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 大窗口里的输入框：铺满可用空间、自身可滚。
class _ExpandedPartField extends StatelessWidget {
  const _ExpandedPartField({
    required this.controller,
    required this.readOnly,
  });

  final TextEditingController controller;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.2)),
      ),
      child: TextField(
        controller: controller,
        autofocus: true,
        readOnly: readOnly,
        expands: true,
        maxLines: null,
        minLines: null,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.fromLTRB(14, 14, 14, 14),
        ),
      ),
    );
  }
}
