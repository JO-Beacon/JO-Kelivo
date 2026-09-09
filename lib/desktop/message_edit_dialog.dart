import 'package:flutter/material.dart';
import '../core/models/chat_message.dart';
import '../core/models/message_part.dart';
import '../features/chat/models/message_edit_result.dart';
import '../features/chat/widgets/message_parts_editor.dart';
import '../features/chat/widgets/message_edit_close_confirmation.dart';
import '../l10n/app_localizations.dart';
import '../icons/lucide_adapter.dart';
import '../theme/app_font_weights.dart';
import 'widgets/desktop_dialog_style.dart';

Future<MessageEditResult?> showMessageEditDesktopDialog(
  BuildContext context, {
  required ChatMessage message,
  bool canCloneSubtree = false,
}) async {
  return showDialog<MessageEditResult?>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _MessageEditDesktopDialog(
      message: message,
      canCloneSubtree: canCloneSubtree,
    ),
  );
}

class _MessageEditDesktopDialog extends StatefulWidget {
  const _MessageEditDesktopDialog({
    required this.message,
    this.canCloneSubtree = false,
  });
  final ChatMessage message;
  final bool canCloneSubtree;

  @override
  State<_MessageEditDesktopDialog> createState() =>
      _MessageEditDesktopDialogState();
}

class _MessageEditDesktopDialogState extends State<_MessageEditDesktopDialog> {
  late final TextEditingController _controller;
  late List<MessagePart> _editedParts;
  bool _allowClose = false;
  bool _confirmingClose = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.message.content);
    _editedParts = List<MessagePart>.of(widget.message.parts);
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
    final text = _editedParts
        .whereType<TextPart>()
        .map((part) => part.text)
        .join();
    return MessageEditResult(
      content: text,
      parts: _editedParts,
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
      !_sameParts(_editedParts, widget.message.parts);

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

  Future<void> _confirmOverwrite() async {
    if (_allowClose) return;
    if (await showMessageEditOverwriteConfirmation(context) && mounted) {
      _closeWithResult(
        _result(shouldSend: false, saveMode: MessageEditSaveMode.overwrite),
      );
    }
  }

  BoxConstraints _dialogConstraints(BuildContext context) {
    return DesktopDialogStyle.editorConstraints(context);
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
                            if (widget.message.role == 'user')
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
                            if (widget.canCloneSubtree)
                              TextButton.icon(
                                onPressed: () => _closeWithResult(
                                  _result(
                                    shouldSend: false,
                                    saveMode: MessageEditSaveMode.cloneSubtree,
                                  ),
                                ),
                                icon: Icon(
                                  Lucide.GitFork,
                                  size: 18,
                                  color: cs.primary,
                                ),
                                label: Text(
                                  l10n.messageEditPageSaveAsBranchCopyChildren,
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
                              onPressed: () => _confirmOverwrite(),
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
                              MessagePartsEditor(
                              parts: _editedParts,
                              onChanged: (parts) => setState(() {
                                _editedParts = parts;
                              }),
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

bool _sameParts(List<MessagePart> left, List<MessagePart> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i].kind != right[i].kind ||
        left[i].encodePayload() != right[i].encodePayload()) {
      return false;
    }
  }
  return true;
}
