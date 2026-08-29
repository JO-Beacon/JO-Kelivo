import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';

void main() {
  test('semantic content hash changes when non-text parts change', () {
    final withImage = ChatMessage(
      role: 'user',
      conversationId: 'c1',
      parts: const [
        TextPart('same visible text'),
        ImagePart(uri: '/tmp/a.png', mime: 'image/png'),
      ],
    );
    final withDifferentImage = withImage.copyWith(
      parts: const [
        TextPart('same visible text'),
        ImagePart(uri: '/tmp/b.png', mime: 'image/png'),
      ],
    );

    expect(withImage.content, withDifferentImage.content);
    expect(
      withImage.semanticContentHash,
      isNot(withDifferentImage.semanticContentHash),
    );
  });

  test('semantic content hash is stable across persistence roundtrip', () {
    final original = ChatMessage(
      id: 'hash-roundtrip',
      role: 'user',
      conversationId: 'c1',
      parts: const [
        TextPart('same visible text'),
        FilePart(uri: '/tmp/a.txt', name: 'a.txt', mime: 'text/plain'),
      ],
    );
    final restored = ChatMessage.fromJson(original.toJson());

    expect(restored.semanticContentHash, original.semanticContentHash);
  });
}
