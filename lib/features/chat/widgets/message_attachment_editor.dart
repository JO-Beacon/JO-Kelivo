import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../../../core/models/chat_input_data.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/file_import_helper.dart';
import '../../../utils/sandbox_path_resolver.dart';

class MessageAttachmentEditor extends StatefulWidget {
  const MessageAttachmentEditor({
    super.key,
    required this.imagePaths,
    required this.documents,
    required this.onChanged,
  });

  final List<String> imagePaths;
  final List<DocumentAttachment> documents;
  final void Function(
    List<String> imagePaths,
    List<DocumentAttachment> documents,
  )
  onChanged;

  @override
  State<MessageAttachmentEditor> createState() =>
      _MessageAttachmentEditorState();
}

class _MessageAttachmentEditorState extends State<MessageAttachmentEditor> {
  static const List<String> _imageExtensions = <String>[
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'heic',
    'heif',
  ];

  static const List<String> _fileExtensions = <String>[
    ..._imageExtensions,
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

  late List<String> _imagePaths;
  late List<DocumentAttachment> _documents;

  @override
  void initState() {
    super.initState();
    _imagePaths = List<String>.of(widget.imagePaths);
    _documents = List<DocumentAttachment>.of(widget.documents);
  }

  @override
  void didUpdateWidget(covariant MessageAttachmentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.imagePaths, widget.imagePaths)) {
      _imagePaths = List<String>.of(widget.imagePaths);
    }
    if (!identical(oldWidget.documents, widget.documents)) {
      _documents = List<DocumentAttachment>.of(widget.documents);
    }
  }

  void _emit() {
    widget.onChanged(
      List<String>.of(_imagePaths),
      List<DocumentAttachment>.of(_documents),
    );
  }

  bool _isImageExtension(String name) {
    final lower = name.toLowerCase();
    return _imageExtensions.any((ext) => lower.endsWith('.$ext'));
  }

  String _inferMimeByExtension(String name) {
    final mediaMime = inferMediaMimeFromSource(name);
    if (mediaMime.isNotEmpty) return mediaMime;
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.js')) return 'application/javascript';
    if (lower.endsWith('.html')) return 'text/html';
    if (lower.endsWith('.xml')) return 'application/xml';
    if (lower.endsWith('.txt') || lower.endsWith('.md')) return 'text/plain';
    return 'text/plain';
  }

  Future<List<String>> _copyPickedFiles(List<XFile> files) async {
    final dir = await AppDirectories.getUploadDirectory();
    final out = <String>[];
    if (!mounted) return out;
    for (final file in files) {
      final savedPath = await FileImportHelper.copyXFile(file, dir, context);
      if (savedPath != null) out.add(savedPath);
    }
    return out;
  }

  Future<List<XFile>> _pickFiles({required bool imagesOnly}) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      type: FileType.custom,
      allowedExtensions: imagesOnly ? _imageExtensions : _fileExtensions,
    );
    if (result == null || result.files.isEmpty) return const <XFile>[];
    return result.files
        .where((file) => file.path != null && file.path!.isNotEmpty)
        .map((file) => XFile(file.path!))
        .toList(growable: false);
  }

  Future<void> _addImages() async {
    final picked = await _pickFiles(imagesOnly: true);
    if (picked.isEmpty) return;
    final saved = await _copyPickedFiles(picked);
    if (saved.isEmpty || !mounted) return;
    setState(() => _imagePaths.addAll(saved));
    _emit();
  }

  Future<void> _replaceImage(int index) async {
    final picked = await _pickFiles(imagesOnly: true);
    if (picked.isEmpty) return;
    final saved = await _copyPickedFiles(<XFile>[picked.first]);
    if (saved.isEmpty || !mounted) return;
    setState(() => _imagePaths[index] = saved.first);
    _emit();
  }

  Future<void> _addFiles() async {
    final picked = await _pickFiles(imagesOnly: false);
    if (picked.isEmpty) return;
    final saved = await _copyPickedFiles(picked);
    if (saved.isEmpty || !mounted) return;
    final nextImages = <String>[];
    final nextDocs = <DocumentAttachment>[];
    for (final savedPath in saved) {
      final name = p.basename(savedPath);
      if (_isImageExtension(name)) {
        nextImages.add(savedPath);
      } else {
        nextDocs.add(
          DocumentAttachment(
            path: savedPath,
            fileName: name,
            mime: _inferMimeByExtension(name),
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _imagePaths.addAll(nextImages);
      _documents.addAll(nextDocs);
    });
    _emit();
  }

  void _removeImage(int index) {
    setState(() => _imagePaths.removeAt(index));
    _emit();
  }

  void _removeDocument(int index) {
    setState(() => _documents.removeAt(index));
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final hasAttachments = _imagePaths.isNotEmpty || _documents.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.messageEditAttachmentsTitle,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _addImages,
              icon: const Icon(Lucide.Image, size: 16),
              label: Text(l10n.messageEditAddImage),
            ),
            TextButton.icon(
              onPressed: _addFiles,
              icon: const Icon(Lucide.Paperclip, size: 16),
              label: Text(l10n.messageEditAddFile),
            ),
          ],
        ),
        if (!hasAttachments)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              l10n.messageEditNoAttachments,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        if (_imagePaths.isNotEmpty) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _imagePaths.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final path = SandboxPathResolver.fix(_imagePaths[index]);
                return _ImageAttachmentTile(
                  path: path,
                  onReplace: () => _replaceImage(index),
                  onRemove: () => _removeImage(index),
                );
              },
            ),
          ),
        ],
        if (_documents.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _documents.length; i++)
                _DocumentAttachmentChip(
                  document: _documents[i],
                  onRemove: () => _removeDocument(i),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ImageAttachmentTile extends StatelessWidget {
  const _ImageAttachmentTile({
    required this.path,
    required this.onReplace,
    required this.onRemove,
  });

  final String path;
  final VoidCallback onReplace;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(path),
            width: 78,
            height: 78,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 78,
              height: 78,
              color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
              alignment: Alignment.center,
              child: Icon(
                Lucide.ImageOff,
                size: 22,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ),
        PositionedDirectional(
          start: 4,
          bottom: 4,
          child: Tooltip(
            message: l10n.messageEditReplaceImage,
            child: _MiniOverlayButton(icon: Lucide.RefreshCw, onTap: onReplace),
          ),
        ),
        PositionedDirectional(
          end: 4,
          top: 4,
          child: Tooltip(
            message: l10n.messageEditRemoveAttachment,
            child: _MiniOverlayButton(icon: Lucide.X, onTap: onRemove),
          ),
        ),
      ],
    );
  }
}

class _DocumentAttachmentChip extends StatelessWidget {
  const _DocumentAttachmentChip({
    required this.document,
    required this.onRemove,
  });

  final DocumentAttachment document;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsetsDirectional.fromSTEB(10, 7, 6, 7),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Lucide.FileText,
            size: 16,
            color: cs.onSurface.withValues(alpha: 0.72),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              document.fileName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: l10n.messageEditRemoveAttachment,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  Lucide.X,
                  size: 14,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniOverlayButton extends StatelessWidget {
  const _MiniOverlayButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.54),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 13, color: Colors.white),
        ),
      ),
    );
  }
}
