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

  test('input merge keeps opaque and unavailable parts losslessly', () {
    const unknown = UnknownPart(rawKind: 'future', payload: '{"opaque":true}');
    const malformed = MalformedPart(
      rawKind: 'image',
      rawPayload: 'not-json',
      parseError: 'invalid_json',
    );
    const unavailable = ImagePart(
      uri: 'kelivo-file:///upload/missing.png',
      assetId: 'missing',
      unavailable: true,
    );
    final merged = MessagePartsEditDraft.mergeInputParts(
      const <MessagePart>[
        unknown,
        TextPart('old'),
        ImagePart(uri: 'old.png'),
        malformed,
        unavailable,
      ],
      const <MessagePart>[
        TextPart('new'),
        FilePart(uri: 'new.pdf', name: 'new.pdf'),
        ImagePart(uri: 'extra.png'),
      ],
    );

    expect(identical(merged[0], unknown), isTrue);
    expect((merged[1] as TextPart).text, 'new');
    expect(merged[2], isA<FilePart>());
    expect((merged[3] as ImagePart).uri, 'extra.png');
    expect(identical(merged[4], malformed), isTrue);
    expect(identical(merged[5], unavailable), isTrue);
  });

  test('input grouping does not reorder existing interleaved attachments', () {
    const image = ImagePart(
      uri: 'a.png',
      assetId: 'asset-a',
      mime: 'image/png',
    );
    const unknown = UnknownPart(rawKind: 'future', payload: 'opaque');
    const file = FilePart(uri: 'b.pdf', name: 'b.pdf', mime: 'application/pdf');
    final merged = MessagePartsEditDraft.mergeInputParts(
      const <MessagePart>[TextPart('old'), image, unknown, file],
      const <MessagePart>[
        TextPart('new'),
        ImagePart(uri: 'a.png', mime: 'image/webp'),
        file,
      ],
    );

    expect(identical(merged[1], image), isTrue);
    expect((merged[1] as ImagePart).assetId, 'asset-a');
    expect(identical(merged[2], unknown), isTrue);
    expect(identical(merged[3], file), isTrue);
  });

  test('empty text and multiple attachments remain valid', () {
    final merged = MessagePartsEditDraft.mergeInputParts(
      const <MessagePart>[UnknownPart(rawKind: 'future', payload: 'x')],
      const <MessagePart>[
        TextPart(''),
        ImagePart(uri: 'a.png'),
        FilePart(uri: 'b.txt', name: 'b.txt'),
      ],
    );

    expect(merged.map((part) => part.kind), <String>[
      'text',
      'future',
      'image',
      'file',
    ]);
    expect((merged.first as TextPart).text, isEmpty);
  });
}
