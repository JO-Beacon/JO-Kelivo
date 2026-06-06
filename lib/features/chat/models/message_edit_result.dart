import '../../../core/models/chat_input_data.dart';
import '../utils/message_attachment_parser.dart';

class MessageEditResult {
  final String text;
  final List<String> imagePaths;
  final List<DocumentAttachment> documents;
  final bool shouldSend;

  const MessageEditResult({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.shouldSend = false,
  });

  String get content => MessageAttachmentParser.buildContent(
    text: text,
    imagePaths: imagePaths,
    documents: documents,
  );
}
