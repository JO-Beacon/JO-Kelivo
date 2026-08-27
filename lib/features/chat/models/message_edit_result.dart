import '../../../core/models/message_part.dart';

enum MessageEditSaveMode { newBranch, overwrite }

class MessageEditResult {
  final String content;
  final List<MessagePart> parts;
  final bool shouldSend;
  final MessageEditSaveMode saveMode;

  MessageEditResult({
    required this.content,
    required List<MessagePart> parts,
    this.shouldSend = false,
    this.saveMode = MessageEditSaveMode.newBranch,
  }) : parts = List<MessagePart>.unmodifiable(parts);
}
