import 'package:Kelivo/utils/mcp_structured_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Markdown image destinations round-trip Windows and spaced paths', () {
    const paths = <String>[
      r'C:\Users\me\shot.png',
      '/tmp/run (1)/image.png',
      '/tmp/照片.png',
      r'\\server\share\shot.png',
    ];
    for (final path in paths) {
      expect(
        decodeMarkdownImageDestination(encodeMarkdownImageDestination(path)),
        path,
      );
    }
  });

  test(
    'legacy private image lines become Markdown, inline text remains text',
    () {
      final marker = encodeMcpStructuredImage(r'C:\old\shot.png');
      final converted = convertLegacyMcpPrivateImageLinesToMarkdown(
        'caption\n$marker\nsee $marker inline',
      );
      expect(converted, contains('![]('));
      expect(
        toolResultContentForModel('see $marker inline'),
        'see $marker inline',
      );
    },
  );

  test('structured result metadata is explicit even without images', () {
    final result = ClientToolResult.fromHandler(
      const McpToolResult(markdown: 'plain result'),
    );
    expect(result.content, 'plain result');
    expect(mcpResultImageUris(readMcpResultMetadata(result.metadata)), isEmpty);
  });
}
