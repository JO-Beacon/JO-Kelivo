import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../../../core/models/message_part.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/file_import_helper.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../models/message_parts_edit_draft.dart';

typedef MessageAttachmentPicker =
    Future<List<MessagePart>> Function(
      BuildContext context, {
      required bool imagesOnly,
      required bool single,
    });

class MessageAttachmentEditor extends StatefulWidget {
  const MessageAttachmentEditor({
    super.key,
    required this.parts,
    required this.onChanged,
    this.picker,
  });

  final List<MessagePart> parts;
  final ValueChanged<List<MessagePart>> onChanged;
  final MessageAttachmentPicker? picker;

  @override
  State<MessageAttachmentEditor> createState() =>
      _MessageAttachmentEditorState();
}

class _MessageAttachmentEditorState extends State<MessageAttachmentEditor> {
  late MessagePartsEditDraft _draft;

  @override
  void initState() {
    super.initState();
    _draft = MessagePartsEditDraft(widget.parts);
  }

  @override
  void didUpdateWidget(covariant MessageAttachmentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.parts, widget.parts)) {
      _draft = MessagePartsEditDraft(widget.parts);
    }
  }

  Future<List<MessagePart>> _pick({
    required bool imagesOnly,
    required bool single,
  }) {
    return (widget.picker ?? _pickAndImportAttachments)(
      context,
      imagesOnly: imagesOnly,
      single: single,
    );
  }

  Future<void> _add({required bool imagesOnly}) async {
    final attachments = await _pick(imagesOnly: imagesOnly, single: false);
    if (attachments.isEmpty || !mounted) return;
    setState(() => _draft.addAttachments(attachments));
    widget.onChanged(_draft.parts);
  }

  Future<void> _replace(int partIndex, MessagePart current) async {
    final attachments = await _pick(
      imagesOnly: current is ImagePart,
      single: true,
    );
    if (attachments.isEmpty || !mounted) return;
    setState(() => _draft.replaceAttachment(partIndex, attachments.first));
    widget.onChanged(_draft.parts);
  }

  void _remove(int partIndex) {
    setState(() => _draft.removeAttachment(partIndex));
    widget.onChanged(_draft.parts);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final indexes = _draft.editableAttachmentIndexes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.messageEditAttachmentsTitle,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            _AddAttachmentButton(
              icon: Lucide.Image,
              label: l10n.messageEditAddImage,
              onTap: () => _add(imagesOnly: true),
            ),
            const SizedBox(width: 6),
            _AddAttachmentButton(
              icon: Lucide.Paperclip,
              label: l10n.messageEditAddFile,
              onTap: () => _add(imagesOnly: false),
            ),
          ],
        ),
        if (indexes.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              l10n.messageEditNoAttachments,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final partIndex in indexes)
                  _AttachmentItem(
                    part: _draft.parts[partIndex],
                    onReplace: () =>
                        _replace(partIndex, _draft.parts[partIndex]),
                    onRemove: () => _remove(partIndex),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _AddAttachmentButton extends StatelessWidget {
  const _AddAttachmentButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      baseColor: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.primary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 13, color: cs.primary)),
        ],
      ),
    );
  }
}

class _AttachmentItem extends StatelessWidget {
  const _AttachmentItem({
    required this.part,
    required this.onReplace,
    required this.onRemove,
  });

  final MessagePart part;
  final VoidCallback onReplace;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final name = switch (part) {
      FilePart(:final name) => name,
      ImagePart(:final uri) => _attachmentName(uri, l10n.messageEditImage),
      _ => '',
    };
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsetsDirectional.fromSTEB(9, 5, 3, 5),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            part is ImagePart ? Lucide.Image : Lucide.FileText,
            size: 16,
            color: cs.onSurface.withValues(alpha: 0.72),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          IosIconButton(
            icon: Lucide.RefreshCw,
            size: 14,
            padding: const EdgeInsets.all(5),
            semanticLabel: l10n.messageEditReplaceAttachment,
            onTap: onReplace,
          ),
          IosIconButton(
            icon: Lucide.X,
            size: 14,
            padding: const EdgeInsets.all(5),
            semanticLabel: l10n.messageEditRemoveAttachment,
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

String _attachmentName(String uri, String fallback) {
  final resolved = SandboxPathResolver.resolveForIo(uri) ?? uri;
  final name = p.basename(resolved);
  return name.isEmpty ? fallback : name;
}

Future<List<MessagePart>> _pickAndImportAttachments(
  BuildContext context, {
  required bool imagesOnly,
  required bool single,
}) async {
  const imageExtensions = <String>[
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
  ];
  const fileExtensions = <String>[
    ...imageExtensions,
    'mp4',
    'avi',
    'mkv',
    'mov',
    'flv',
    'wmv',
    'mpeg',
    'mpg',
    'webm',
    '3gp',
    '3gpp',
    'wav',
    'mp3',
    'pcm',
    'pcm16',
    'txt',
    'md',
    'json',
    'js',
    'pdf',
    'docx',
    'html',
    'xml',
    'py',
    'java',
    'kt',
    'dart',
    'ts',
    'tsx',
    'markdown',
    'mdx',
    'yml',
    'yaml',
  ];
  try {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: !single,
      withData: false,
      type: FileType.custom,
      allowedExtensions: imagesOnly ? imageExtensions : fileExtensions,
    );
    if (result == null || result.files.isEmpty) return const <MessagePart>[];
    final uploadDirectory = await AppDirectories.getUploadDirectory();
    final parts = <MessagePart>[];
    for (final selected in result.files) {
      final sourcePath = selected.path;
      if (sourcePath == null || sourcePath.isEmpty || !context.mounted) {
        continue;
      }
      final savedPath = await FileImportHelper.copyXFile(
        XFile(sourcePath),
        uploadDirectory,
        context,
      );
      if (savedPath == null) continue;
      final name = p.basename(savedPath);
      final mime = await inferAttachmentMime(uri: savedPath, fileName: name);
      final uri = SandboxPathResolver.canonicalize(savedPath);
      if (imagesOnly || (mime != null && isImageMime(mime))) {
        parts.add(ImagePart(uri: uri, mime: mime));
      } else {
        parts.add(FilePart(uri: uri, name: name, mime: mime));
      }
      if (single) break;
    }
    if (parts.isEmpty && context.mounted) {
      showAppSnackBar(
        context,
        message: AppLocalizations.of(context)!.messageEditAttachmentCopyFailed,
        type: NotificationType.error,
      );
    }
    return parts;
  } catch (error) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: AppLocalizations.of(
          context,
        )!.messageEditAttachmentImportFailed(error.toString()),
        type: NotificationType.error,
      );
    }
    return const <MessagePart>[];
  }
}
