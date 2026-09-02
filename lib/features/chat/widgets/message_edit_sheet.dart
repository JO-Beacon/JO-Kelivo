import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/models/chat_message.dart';
import '../../../icons/lucide_adapter.dart';
import '../models/message_edit_result.dart';
import '../models/message_parts_edit_draft.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../core/services/haptics.dart';
import '../../../theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';
import 'message_attachment_editor.dart';
import 'message_edit_close_confirmation.dart';

Future<MessageEditResult?> showMessageEditSheet(
  BuildContext context, {
  required ChatMessage message,
  bool canCloneSubtree = false,
}) async {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<MessageEditResult?>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: _MessageEditSheet(
        message: message,
        canCloneSubtree: canCloneSubtree,
      ),
    ),
  );
}

class _MessageEditSheet extends StatefulWidget {
  const _MessageEditSheet({
    required this.message,
    this.canCloneSubtree = false,
  });
  final ChatMessage message;
  final bool canCloneSubtree;
  @override
  State<_MessageEditSheet> createState() => _MessageEditSheetState();
}

class _MessageEditSheetState extends State<_MessageEditSheet> {
  late final TextEditingController _controller;
  late MessagePartsEditDraft _draft;
  bool _allowClose = false;
  bool _confirmingClose = false;
  double _headerDragDistance = 0;

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

  Future<void> _confirmOverwrite() async {
    if (_allowClose) return;
    if (await showMessageEditOverwriteConfirmation(context) && mounted) {
      _closeWithResult(
        _result(shouldSend: false, saveMode: MessageEditSaveMode.overwrite),
      );
    }
  }

  void _handleHeaderDragStart(DragStartDetails _) {
    _headerDragDistance = 0;
  }

  void _handleHeaderDragUpdate(DragUpdateDetails details) {
    _headerDragDistance = (_headerDragDistance + (details.primaryDelta ?? 0))
        .clamp(0, 160);
  }

  void _handleHeaderDragEnd(DragEndDetails details) {
    final shouldConfirm =
        _headerDragDistance >= 48 ||
        details.primaryVelocity != null && details.primaryVelocity! >= 700;
    _headerDragDistance = 0;
    if (shouldConfirm) unawaited(_confirmClose());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _allowClose,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _confirmClose();
      },
      child: Padding(
        // 为面板确保键盘安全的下方内边距
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.8,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          builder: (c, sc) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: _handleHeaderDragStart,
                  onVerticalDragUpdate: _handleHeaderDragUpdate,
                  onVerticalDragEnd: _handleHeaderDragEnd,
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
                      Text(
                        l10n.messageEditPageTitle,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: AppFontWeights.semibold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          if (widget.message.role == 'user')
                            IosCardPress(
                              onTap: () {
                                Haptics.light();
                                _closeWithResult(_result(shouldSend: true));
                              },
                              borderRadius: BorderRadius.circular(20),
                              baseColor: Colors.transparent,
                              pressedBlendStrength:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? 0.10
                                  : 0.06,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Text(
                                l10n.messageEditPageSaveAsBranchAndSend,
                                style: TextStyle(
                                  color: cs.primary,
                                  fontWeight: AppFontWeights.emphasis,
                                ),
                              ),
                            ),
                          IosCardPress(
                            onTap: () {
                              Haptics.light();
                              _closeWithResult(_result(shouldSend: false));
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
                              l10n.messageEditPageSaveAsBranch,
                              style: TextStyle(
                                color: cs.primary,
                                fontWeight: AppFontWeights.emphasis,
                              ),
                            ),
                          ),
                          if (widget.canCloneSubtree)
                            IosCardPress(
                              onTap: () => _closeWithResult(
                                _result(
                                  shouldSend: false,
                                  saveMode: MessageEditSaveMode.cloneSubtree,
                                ),
                              ),
                              borderRadius: BorderRadius.circular(20),
                              baseColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Text(
                                l10n.messageEditPageSaveAsBranchCopyChildren,
                                style: TextStyle(color: cs.primary),
                              ),
                            ),
                          IosCardPress(
                            onTap: () {
                              Haptics.light();
                              unawaited(_confirmOverwrite());
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
                              l10n.messageEditPageOverwriteSave,
                              style: TextStyle(
                                color: cs.primary,
                                fontWeight: AppFontWeights.emphasis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: IosCardPress(
                    onTap: _trimWhitespace,
                    borderRadius: BorderRadius.circular(16),
                    baseColor: Colors.transparent,
                    pressedBlendStrength:
                        Theme.of(context).brightness == Brightness.dark
                        ? 0.10
                        : 0.06,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Lucide.Eraser, size: 16, color: cs.primary),
                        const SizedBox(width: 6),
                        Text(
                          l10n.messageEditTrimWhitespace,
                          style: TextStyle(color: cs.primary),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: SingleChildScrollView(
                    controller: sc,
                    child: Column(
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
                            fillColor: context.appColors.surfaceFill,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
