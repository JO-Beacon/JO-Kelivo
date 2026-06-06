import 'package:flutter/material.dart';
import '../core/models/chat_input_data.dart';
import '../core/models/chat_message.dart';
import '../features/chat/models/message_edit_result.dart';
import '../features/chat/utils/message_attachment_parser.dart';
import '../features/chat/widgets/message_attachment_editor.dart';
import '../l10n/app_localizations.dart';
import '../icons/lucide_adapter.dart';

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
  late List<String> _imagePaths;
  late List<DocumentAttachment> _documents;

  @override
  void initState() {
    super.initState();
    final parsed = MessageAttachmentParser.parse(widget.message.content);
    _controller = TextEditingController(text: parsed.text);
    _imagePaths = List<String>.of(parsed.imagePaths);
    _documents = List<DocumentAttachment>.of(parsed.documents);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  MessageEditResult _result({required bool shouldSend}) {
    return MessageEditResult(
      text: _controller.text.trim(),
      imagePaths: _imagePaths,
      documents: _documents,
      shouldSend: shouldSend,
    );
  }

  void _updateAttachments(
    List<String> imagePaths,
    List<DocumentAttachment> documents,
  ) {
    _imagePaths = imagePaths;
    _documents = documents;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        l10n.messageEditPageTitle,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.of(
                            context,
                          ).pop<MessageEditResult>(_result(shouldSend: true));
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
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.of(
                            context,
                          ).pop<MessageEditResult>(_result(shouldSend: false));
                        },
                        icon: Icon(Lucide.Check, size: 18, color: cs.primary),
                        label: Text(
                          l10n.messageEditPageSave,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
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
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
                            fillColor: isDark
                                ? Colors.white10
                                : const Color(0xFFF7F7F9),
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
                        const SizedBox(height: 14),
                        MessageAttachmentEditor(
                          imagePaths: _imagePaths,
                          documents: _documents,
                          onChanged: _updateAttachments,
                        ),
                      ],
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
