import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/models/message_part.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import 'message_attachment_editor.dart';

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
      builder: (context) => AlertDialog(
        title: Text(l10n.messageEditDeletePartConfirmTitle),
        content: Text(l10n.messageEditDeletePartConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.messageEditCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
              dragHandle: ReorderableDragStartListener(
                index: index,
                child: Icon(Icons.drag_handle, color: Colors.grey.shade600),
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
    required this.dragHandle,
  });

  final int index;
  final MessagePart part;
  final TextEditingController? controller;
  final ValueChanged<String>? onTextChanged;
  final VoidCallback onDelete;
  final Widget dragHandle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final label = switch (part) {
      TextPart() => l10n.messageEditTextPart,
      ReasoningPart() => l10n.messageEditReasoningPart,
      ToolCallPart() => l10n.messageEditToolCallPart,
      ImagePart() => l10n.messageEditImagePart,
      FilePart() => l10n.messageEditFilePart,
      UnknownPart() => l10n.messageEditUnknownPart,
      MalformedPart() => l10n.messageEditUnknownPart,
    };
    final readOnly = part is! TextPart;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                dragHandle,
                const SizedBox(width: 6),
                Expanded(child: Text('$label ${index + 1}')),
                IconButton(
                  tooltip: l10n.messageEditDeletePart,
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline, color: cs.error),
                ),
              ],
            ),
            if (part is TextPart)
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: null,
                onChanged: onTextChanged,
                decoration: InputDecoration(
                  hintText: l10n.messageEditTextPart,
                  border: const OutlineInputBorder(),
                ),
              )
            else
              Text(
                readOnly ? _summary(part) : '',
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65)),
              ),
          ],
        ),
      ),
    );
  }

  String _summary(MessagePart part) {
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
}
