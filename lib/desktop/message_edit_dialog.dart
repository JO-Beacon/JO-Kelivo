import 'package:flutter/material.dart';
import '../core/models/chat_message.dart';
import '../features/chat/models/message_edit_result.dart';
import '../features/chat/models/message_parts_edit_draft.dart';
import '../features/chat/widgets/message_attachment_editor.dart';
import '../features/chat/widgets/message_edit_close_confirmation.dart';
import '../l10n/app_localizations.dart';
import '../icons/lucide_adapter.dart';
import '../theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';
import 'widgets/desktop_dialog_style.dart';

Future<MessageEditResult?> showMessageEditDesktopDialog(
  BuildContext context, {
  required ChatMessage message,
}) async {
  return showDialog<MessageEditResult?>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _MessageEditDesktopDialog(message: message),
  );
}

class _MessageEditDesktopDialog extends StatefulWidget {
  const _MessageEditDesktopDialog({required this.message});
  final ChatMessage message;

  @override
  State<_MessageEditDesktopDialog> createState() =>
      _MessageEditDesktopDialogState();
}

class _MessageEditDesktopDialogState extends State<_MessageEditDesktopDialog> {
  late final TextEditingController _controller;
  late MessagePartsEditDraft _draft;
  bool _allowClose = false;
  bool _confirmingClose = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.message.content);
    _draft = MessagePartsEditDraft(widget.message.parts);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  MessageEditResult _result({
    required bool shouldSend,
    MessageEditSaveMode saveMode = MessageEditSaveMode.newBranch,
  }) {
    final text = _controller.text;
    _draft.replaceText(text);
    return MessageEditResult(
      content: text,
      parts: _draft.parts,
      shouldSend: shouldSend,
      saveMode: saveMode,
    );
  }

  void _closeWithResult(MessageEditResult? result) {
    if (!mounted) return;
    setState(() => _allowClose = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop<MessageEditResult?>(result);
    });
  }

  bool get _hasChanges =>
      _controller.text != widget.message.content ||
      !_draft.isSameAs(widget.message.parts);

  void _trimWhitespace() {
    final trimmed = _controller.text.trim();
    if (trimmed == _controller.text) return;
    _controller.value = TextEditingValue(
      text: trimmed,
      selection: TextSelection.collapsed(offset: trimmed.length),
      composing: TextRange.empty,
    );
    setState(() {});
  }

  Future<void> _confirmClose() async {
    if (_confirmingClose || _allowClose) return;
    if (!_hasChanges) {
      _closeWithResult(null);
      return;
    }
    _confirmingClose = true;
    final action = await showMessageEditCloseConfirmation(context);
    _confirmingClose = false;
    if (!mounted) return;
    switch (action) {
      case MessageEditCloseAction.confirm:
        _closeWithResult(null);
      case MessageEditCloseAction.cancel:
      case null:
        break;
    }
  }

  BoxConstraints _dialogConstraints(BuildContext context) {
    return DesktopDialogStyle.proportionalConstraints(
      context,
      minWidth: 520,
      maxWidth: 720,
      maxHeight: 680,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: _allowClose,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _confirmClose();
      },
      child: Dialog(
        elevation: 12,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: DesktopDialogStyle.shape(context),
        child: ConstrainedBox(
          constraints: _dialogConstraints(context),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Material(
              color: cs.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 标题栏
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.messageEditPageTitle,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: AppFontWeights.emphasis,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: l10n.mcpPageClose,
                              onPressed: _confirmClose,
                              icon: Icon(
                                Lucide.X,
                                size: 18,
                                color: cs.onSurface.withValues(alpha: 0.75),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 4,
                          runSpacing: 2,
                          children: [
                            TextButton.icon(
                              onPressed: () {
                                _closeWithResult(_result(shouldSend: true));
                              },
                              icon: Icon(
                                Lucide.MessageCirclePlus,
                                size: 18,
                                color: cs.primary,
                              ),
                              label: Text(
                                l10n.messageEditPageSaveAsBranchAndSend,
                                style: TextStyle(
                                  color: cs.primary,
                                  fontWeight: AppFontWeights.semibold,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () {
                                _closeWithResult(_result(shouldSend: false));
                              },
                              icon: Icon(
                                Lucide.Check,
                                size: 18,
                                color: cs.primary,
                              ),
                              label: Text(
                                l10n.messageEditPageSaveAsBranch,
                                style: TextStyle(
                                  color: cs.primary,
                                  fontWeight: AppFontWeights.semibold,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () {
                                _closeWithResult(
                                  _result(
                                    shouldSend: false,
                                    saveMode: MessageEditSaveMode.overwrite,
                                  ),
                                );
                              },
                              icon: Icon(
                                Lucide.Edit,
                                size: 18,
                                color: cs.primary,
                              ),
                              label: Text(
                                l10n.messageEditPageOverwriteSave,
                                style: TextStyle(
                                  color: cs.primary,
                                  fontWeight: AppFontWeights.semibold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 内容区
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: _trimWhitespace,
                                icon: Icon(
                                  Lucide.Eraser,
                                  size: 18,
                                  color: cs.primary,
                                ),
                                label: Text(
                                  l10n.messageEditTrimWhitespace,
                                  style: TextStyle(
                                    color: cs.primary,
                                    fontWeight: AppFontWeights.semibold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            TextField(
                              controller: _controller,
                              autofocus: true,
                              keyboardType: TextInputType.multiline,
                              minLines: 10,
                              maxLines: null,
                              decoration: InputDecoration(
                                hintText: l10n.messageEditPageHint,
                                filled: true,
                                fillColor: context.appColors.surfaceFill,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: cs.outlineVariant.withValues(
                                      alpha: 0.18,
                                    ),
                                    width: 0.6,
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: cs.outlineVariant.withValues(
                                      alpha: 0.18,
                                    ),
                                    width: 0.6,
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: cs.primary.withValues(alpha: 0.35),
                                    width: 0.8,
                                  ),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                              ),
                              style: const TextStyle(fontSize: 15, height: 1.5),
                            ),
                            const SizedBox(height: 12),
                            MessageAttachmentEditor(
                              parts: _draft.parts,
                              onChanged: (parts) {
                                setState(() {
                                  _draft = MessagePartsEditDraft(parts);
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
