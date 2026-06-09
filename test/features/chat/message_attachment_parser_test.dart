import 'package:Kelivo/core/models/chat_input_data.dart';
import 'package:Kelivo/features/chat/utils/message_attachment_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageAttachmentParser', () {
    test('parses text, images, and files from persisted content', () {
      final parsed = MessageAttachmentParser.parse(
        'hello\n[image:/tmp/a.png]\n[file:/tmp/a.pdf|a.pdf|application/pdf]',
      );

      expect(parsed.text, 'hello');
      expect(parsed.imagePaths, ['/tmp/a.png']);
      expect(parsed.documents, hasLength(1));
      expect(parsed.documents.single.path, '/tmp/a.pdf');
      expect(parsed.documents.single.fileName, 'a.pdf');
      expect(parsed.documents.single.mime, 'application/pdf');
    });

    test(
      'keeps pure attachment messages editable without placeholder text',
      () {
        final parsed = MessageAttachmentParser.parse('[image:/tmp/a.png]');

        expect(parsed.text, isEmpty);
        expect(parsed.imagePaths, ['/tmp/a.png']);
        expect(parsed.toContent(), '[image:/tmp/a.png]');
      },
    );

    test('builds content with normalized image and file markers', () {
      final content = MessageAttachmentParser.buildContent(
        text: 'hello',
        imagePaths: [' /tmp/a.png ', ''],
        documents: const [
          DocumentAttachment(
            path: ' /tmp/a.pdf ',
            fileName: ' a.pdf ',
            mime: ' application/pdf ',
          ),
          DocumentAttachment(
            path: '',
            fileName: 'empty.txt',
            mime: 'text/plain',
          ),
        ],
      );

      expect(
        content,
        'hello\n[image:/tmp/a.png]\n[file:/tmp/a.pdf|a.pdf|application/pdf]',
      );
    });

    test('uses safe defaults for incomplete file marker fields', () {
      final parsed = MessageAttachmentParser.parse('[file:/tmp/raw||]');

      expect(parsed.text, isEmpty);
      expect(parsed.documents, hasLength(1));
      expect(parsed.documents.single.fileName, 'file');
      expect(parsed.documents.single.mime, 'application/octet-stream');
    });
  });
}
