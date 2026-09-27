import 'package:Kelivo/utils/newline_normalization.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeNewlines', () {
    test('leaves LF unchanged', () {
      expect(normalizeNewlines('a\nb'), 'a\nb');
      expect(identical(normalizeNewlines('a\nb'), 'a\nb'), isTrue);
    });

    test('collapses CRLF to LF', () {
      expect(normalizeNewlines('a\r\nb'), 'a\nb');
    });

    test('collapses a lone CR to LF', () {
      expect(normalizeNewlines('a\rb'), 'a\nb');
    });

    test('handles a mix of sources', () {
      expect(normalizeNewlines('a\r\nb\nc\rd'), 'a\nb\nc\nd');
    });
  });

  group('NormalizeNewlinesFormatter', () {
    const formatter = NormalizeNewlinesFormatter();

    test('returns the value untouched when there is no CR', () {
      const value = TextEditingValue(
        text: 'a\nb',
        selection: TextSelection.collapsed(offset: 3),
      );
      expect(formatter.formatEditUpdate(TextEditingValue.empty, value), value);
    });

    test('normalizes CRLF and moves the caret with the shorter text', () {
      const value = TextEditingValue(
        text: 'a\r\nb',
        selection: TextSelection.collapsed(offset: 4),
      );
      final result = formatter.formatEditUpdate(TextEditingValue.empty, value);
      expect(result.text, 'a\nb');
      expect(result.selection.baseOffset, 3);
    });

    test('normalizes a lone CR', () {
      const value = TextEditingValue(
        text: 'a\rb',
        selection: TextSelection.collapsed(offset: 3),
      );
      final result = formatter.formatEditUpdate(TextEditingValue.empty, value);
      expect(result.text, 'a\nb');
      expect(result.selection.baseOffset, 3);
    });
  });
}
