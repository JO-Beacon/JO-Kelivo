import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';

/// Mutable edit draft that keeps the persisted part order as its source of
/// truth. Only text, image, and file parts are editable; every other part is
/// carried through unchanged.
class MessagePartsEditDraft {
  MessagePartsEditDraft(Iterable<MessagePart> parts)
    : _parts = List<MessagePart>.of(parts);

  final List<MessagePart> _parts;

  List<MessagePart> get parts => List<MessagePart>.unmodifiable(_parts);

  List<int> get editableAttachmentIndexes => <int>[
    for (var index = 0; index < _parts.length; index++)
      if (_parts[index] is ImagePart || _parts[index] is FilePart) index,
  ];

  void replaceText(String content) {
    final next = ChatMessage.partsWithReplacedText(_parts, content);
    _parts
      ..clear()
      ..addAll(next);
  }

  void addAttachments(Iterable<MessagePart> attachments) {
    for (final part in attachments) {
      _requireEditableAttachment(part);
      _parts.add(part);
    }
  }

  void replaceAttachment(int partIndex, MessagePart replacement) {
    _requireEditableAttachment(replacement);
    _requireEditableAttachment(_parts[partIndex]);
    _parts[partIndex] = replacement;
  }

  void removeAttachment(int partIndex) {
    _requireEditableAttachment(_parts[partIndex]);
    _parts.removeAt(partIndex);
  }

  static void _requireEditableAttachment(MessagePart part) {
    if (part is! ImagePart && part is! FilePart) {
      throw ArgumentError.value(part, 'part', 'must be an image or file part');
    }
  }
}
