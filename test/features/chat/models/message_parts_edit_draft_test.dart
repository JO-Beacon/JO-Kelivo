import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/features/chat/models/message_parts_edit_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text edit preserves attachment and opaque part order', () {
    const unknown = UnknownPart(rawKind: 'future', payload: '{"v":1}');
    const malformed = MalformedPart(
      rawKind: 'file',
      rawPayload: '{broken',
      parseError: 'invalid_json',
    );
    final draft = MessagePartsEditDraft(const <MessagePart>[
      ReasoningPart('thinking'),
      TextPart('before'),
      ImagePart(uri: 'kelivo-file:///upload/a.png', assetId: 'asset-a'),
      unknown,
      malformed,
    ]);

    draft.replaceText('after');

    expect(draft.parts[0], isA<ReasoningPart>());
    expect((draft.parts[1] as TextPart).text, 'after');
    expect((draft.parts[2] as ImagePart).assetId, 'asset-a');
    expect(identical(draft.parts[3], unknown), isTrue);
    expect(identical(draft.parts[4], malformed), isTrue);
  });

  test('attachments can be removed replaced and appended', () {
    final draft = MessagePartsEditDraft(const <MessagePart>[
      TextPart('body'),
      ImagePart(uri: 'old.png'),
      UnknownPart(rawKind: 'future', payload: 'opaque'),
      FilePart(uri: 'old.pdf', name: 'old.pdf'),
    ]);

    draft.replaceAttachment(
      draft.editableAttachmentIndexes.first,
      const ImagePart(uri: 'new.png', mime: 'image/png'),
    );
    draft.removeAttachment(draft.editableAttachmentIndexes.last);
    draft.addAttachments(const <MessagePart>[
      FilePart(uri: 'new.pdf', name: 'new.pdf', mime: 'application/pdf'),
    ]);

    expect(draft.parts.map((part) => part.kind), <String>[
      'text',
      'image',
      'future',
      'file',
    ]);
    expect((draft.parts[1] as ImagePart).uri, 'new.png');
    expect((draft.parts[3] as FilePart).name, 'new.pdf');
  });
}
