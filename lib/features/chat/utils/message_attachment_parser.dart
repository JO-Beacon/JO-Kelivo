import '../../../core/models/chat_input_data.dart';

class ParsedMessageAttachments {
  const ParsedMessageAttachments({
    required this.text,
    required this.imagePaths,
    required this.documents,
  });

  final String text;
  final List<String> imagePaths;
  final List<DocumentAttachment> documents;

  String toContent() => MessageAttachmentParser.buildContent(
    text: text,
    imagePaths: imagePaths,
    documents: documents,
  );
}

abstract final class MessageAttachmentParser {
  MessageAttachmentParser._();

  static final RegExp _imageMarker = RegExp(r'\n?\[image:([^\]]+)\]');
  static final RegExp _fileMarker = RegExp(
    r'\n?\[file:([^\]|]+)\|([^\]|]*)\|([^\]]*)\]',
  );

  static ParsedMessageAttachments parse(String content) {
    final images = <String>[];
    final documents = <DocumentAttachment>[];

    final withoutImages = content.replaceAllMapped(_imageMarker, (match) {
      final path = match.group(1)?.trim() ?? '';
      if (path.isNotEmpty) images.add(path);
      return '';
    });

    final text = withoutImages.replaceAllMapped(_fileMarker, (match) {
      final path = match.group(1)?.trim() ?? '';
      final fileName = match.group(2)?.trim() ?? '';
      final mime = match.group(3)?.trim() ?? '';
      if (path.isNotEmpty) {
        documents.add(
          DocumentAttachment(
            path: path,
            fileName: fileName.isEmpty ? 'file' : fileName,
            mime: mime.isEmpty ? 'application/octet-stream' : mime,
          ),
        );
      }
      return '';
    }).trim();

    return ParsedMessageAttachments(
      text: text,
      imagePaths: List.unmodifiable(images),
      documents: List.unmodifiable(documents),
    );
  }

  static String buildContent({
    required String text,
    required List<String> imagePaths,
    required List<DocumentAttachment> documents,
  }) {
    final buffer = StringBuffer(text.trim());
    for (final path in imagePaths) {
      final normalized = path.trim();
      if (normalized.isEmpty) continue;
      buffer.write('\n[image:$normalized]');
    }
    for (final doc in documents) {
      final path = doc.path.trim();
      if (path.isEmpty) continue;
      final fileName = doc.fileName.trim().isEmpty
          ? 'file'
          : doc.fileName.trim();
      final mime = doc.mime.trim().isEmpty
          ? 'application/octet-stream'
          : doc.mime.trim();
      buffer.write('\n[file:$path|$fileName|$mime]');
    }
    return buffer.toString().trim();
  }
}
