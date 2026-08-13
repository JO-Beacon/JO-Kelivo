import '../../../core/models/message_part.dart';

class MessageEditResult {
  final String content;
  final List<MessagePart> parts;
  final bool shouldSend;

  MessageEditResult({
    required this.content,
    required List<MessagePart> parts,
    this.shouldSend = false,
  }) : parts = List<MessagePart>.unmodifiable(parts);
}
