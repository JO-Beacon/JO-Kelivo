import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/utils/utf16_safe_cut.dart';

void main() {
  test('head and tail cuts do not split surrogate pairs', () {
    const value = 'ab😀cd';
    expect(truncateHeadUtf16Safe(value, 3), 'ab');
    expect(truncateTailUtf16Safe(value, 3), 'cd');
    expect(utf16SafeTailStart(value, 3), 4);
  });

  test('chunks cover the complete text without splitting emoji', () {
    const value = 'a😀b😀c';
    final chunks = splitUtf16SafeChunks(value, 3);
    expect(chunks, ['a😀', 'b😀', 'c']);
    expect(chunks.join(), value);
  });

  test('halves remain valid at an emoji boundary', () {
    const value = 'ab😀cd';
    final halves = splitUtf16SafeHalves(value);
    expect(halves.join(), value);
    expect(halves.every((part) => !part.contains('\uFFFD')), isTrue);
  });
}
