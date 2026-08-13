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

  String get content =>
      _parts.whereType<TextPart>().map((part) => part.text).join();

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

  static List<MessagePart> mergeInputParts(
    List<MessagePart> original,
    List<MessagePart> editedInputParts,
  ) {
    final editedText = editedInputParts
        .whereType<TextPart>()
        .map((part) => part.text)
        .join();
    final editedAttachments = editedInputParts
        .where((part) => part is ImagePart || part is FilePart)
        .toList(growable: false);
    final lastEditableAttachment = original.lastIndexWhere(
      _isAvailableAttachment,
    );
    final remainingAttachments = List<MessagePart>.of(editedAttachments);
    final merged = <MessagePart>[];
    var wroteText = false;

    for (var index = 0; index < original.length; index++) {
      final part = original[index];
      if (part is TextPart) {
        if (!wroteText) {
          merged.add(TextPart(editedText));
          wroteText = true;
        }
      } else if (part is ImagePart || part is FilePart) {
        if (!_isAvailableAttachment(part)) {
          merged.add(part);
        } else {
          final matchingIndex = remainingAttachments.indexWhere(
            (candidate) => _sameEditableAttachment(part, candidate),
          );
          if (matchingIndex >= 0) {
            merged.add(part);
            remainingAttachments.removeAt(matchingIndex);
          }
        }
      } else {
        merged.add(part);
      }

      if (index == lastEditableAttachment) {
        merged.addAll(remainingAttachments);
        remainingAttachments.clear();
      }
    }

    if (!wroteText) merged.insert(0, TextPart(editedText));
    if (lastEditableAttachment < 0) {
      merged.addAll(remainingAttachments);
    }
    return merged;
  }

  static bool _isAvailableAttachment(MessagePart part) {
    return switch (part) {
      ImagePart(:final unavailable) => !unavailable,
      FilePart(:final unavailable) => !unavailable,
      _ => false,
    };
  }

  static bool _sameEditableAttachment(
    MessagePart original,
    MessagePart candidate,
  ) {
    return switch ((original, candidate)) {
      (ImagePart a, ImagePart b) => a.uri == b.uri,
      (FilePart a, FilePart b) => a.uri == b.uri && a.name == b.name,
      _ => false,
    };
  }

  static void _requireEditableAttachment(MessagePart part) {
    if (part is! ImagePart && part is! FilePart) {
      throw ArgumentError.value(part, 'part', 'must be an image or file part');
    }
  }
}
