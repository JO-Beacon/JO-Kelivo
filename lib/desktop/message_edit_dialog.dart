import 'package:flutter/material.dart';
import '../core/models/chat_message.dart';
import '../features/chat/models/message_edit_result.dart';
import '../features/chat/models/message_parts_edit_draft.dart';
import '../features/chat/widgets/message_attachment_editor.dart';
import '../l10n/app_localizations.dart';
import '../icons/lucide_adapter.dart';
import '../theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 520,
          maxWidth: 720,
          maxHeight: 680,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: cs.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        l10n.messageEditPageTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          final text = _controller.text.trim();
                          _draft.replaceText(text);
                          Navigator.of(context).pop<MessageEditResult>(
                            MessageEditResult(
                              content: text,
                              parts: _draft.parts,
                              shouldSend: true,
                            ),
                          );
                        },
                        icon: Icon(
                          Lucide.MessageCirclePlus,
                          size: 18,
                          color: cs.primary,
                        ),
                        label: Text(
                          l10n.messageEditPageSaveAndSend,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: () {
                          final text = _controller.text.trim();
                          _draft.replaceText(text);
                          Navigator.of(context).pop<MessageEditResult>(
                            MessageEditResult(
                              content: text,
                              parts: _draft.parts,
                              shouldSend: false,
                            ),
                          );
                        },
                        icon: Icon(Lucide.Check, size: 18, color: cs.primary),
                        label: Text(
                          l10n.messageEditPageSave,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.mcpPageClose,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: Icon(
                          Lucide.X,
                          size: 18,
                          color: cs.onSurface.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                // Body
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
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
    );
  }
}
