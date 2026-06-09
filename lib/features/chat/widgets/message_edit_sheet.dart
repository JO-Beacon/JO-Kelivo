import 'package:flutter/material.dart';

import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/services/haptics.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../models/message_edit_result.dart';
import '../utils/message_attachment_parser.dart';
import 'message_attachment_editor.dart';

Future<MessageEditResult?> showMessageEditSheet(
  BuildContext context, {
  required ChatMessage message,
}) async {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<MessageEditResult?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) =>
        SafeArea(top: false, child: _MessageEditSheet(message: message)),
  );
}

class _MessageEditSheet extends StatefulWidget {
  const _MessageEditSheet({required this.message});

  final ChatMessage message;

  @override
  State<_MessageEditSheet> createState() => _MessageEditSheetState();
}

class _MessageEditSheetState extends State<_MessageEditSheet> {
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
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (c, sc) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 32,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IosCardPress(
                        onTap: () {
                          Haptics.light();
                          Navigator.of(
                            context,
                          ).pop<MessageEditResult>(_result(shouldSend: true));
                        },
                        borderRadius: BorderRadius.circular(20),
                        baseColor: Colors.transparent,
                        pressedBlendStrength:
                            Theme.of(context).brightness == Brightness.dark
                            ? 0.10
                            : 0.06,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Text(
                          l10n.messageEditPageSaveAndSend,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ),
                    ),
                    Center(
                      child: Text(
                        l10n.messageEditPageTitle,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: AppFontWeights.semibold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IosCardPress(
                        onTap: () {
                          Haptics.light();
                          Navigator.of(
                            context,
                          ).pop<MessageEditResult>(_result(shouldSend: false));
                        },
                        borderRadius: BorderRadius.circular(20),
                        baseColor: Colors.transparent,
                        pressedBlendStrength:
                            Theme.of(context).brightness == Brightness.dark
                            ? 0.10
                            : 0.06,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Text(
                          l10n.messageEditPageSave,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  controller: sc,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _controller,
                        autofocus: false,
                        keyboardType: TextInputType.multiline,
                        minLines: 8,
                        maxLines: null,
                        decoration: InputDecoration(
                          hintText: l10n.messageEditPageHint,
                          filled: true,
                          fillColor:
                              Theme.of(context).brightness == Brightness.dark
                              ? Colors.white10
                              : const Color(0xFFF2F3F5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: const BorderSide(
                              color: Colors.transparent,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: const BorderSide(
                              color: Colors.transparent,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(
                              color: cs.primary.withValues(alpha: 0.45),
                            ),
                          ),
                        ),
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
    );
  }
}
