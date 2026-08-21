import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';

/// 可变编辑草稿，以已持久化的 part 顺序作为唯一事实来源。
/// 只有 text、image 和 file part 可编辑；其他 part 都
/// 原样保留。
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
