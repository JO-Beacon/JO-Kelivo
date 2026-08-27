/// UTF-16 字符串的安全截断工具。
///
/// Dart 的 String 下标以 UTF-16 code unit 计数，因此必须避免在代理对
/// 中间切分，否则下游 JSON/API 文本可能包含无效的孤立代理项。
String truncateHeadUtf16Safe(String value, int maxCodeUnits) {
  if (maxCodeUnits <= 0) return '';
  if (value.length <= maxCodeUnits) return value;
  var end = maxCodeUnits;
  if (end > 0 &&
      end < value.length &&
      _isHighSurrogate(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(0, end);
}

int utf16SafeTailStart(String value, int maxCodeUnits) {
  if (maxCodeUnits <= 0) return value.length;
  if (value.length <= maxCodeUnits) return 0;
  var start = value.length - maxCodeUnits;
  if (start > 0 &&
      start < value.length &&
      _isLowSurrogate(value.codeUnitAt(start))) {
    start++;
  }
  return start;
}

String truncateTailUtf16Safe(String value, int maxCodeUnits) {
  return value.substring(utf16SafeTailStart(value, maxCodeUnits));
}

List<String> splitUtf16SafeChunks(String value, int maxCodeUnits) {
  if (value.isEmpty) return const <String>[];
  if (maxCodeUnits <= 0 || value.length <= maxCodeUnits) return <String>[value];
  final chunks = <String>[];
  var offset = 0;
  while (offset < value.length) {
    final remaining = value.substring(offset);
    final chunk = truncateHeadUtf16Safe(remaining, maxCodeUnits);
    if (chunk.isEmpty) {
      // A positive budget can only reach here for an invalid/isolated unit.
      chunks.add(remaining.substring(0, 1));
      offset++;
      continue;
    }
    chunks.add(chunk);
    offset += chunk.length;
  }
  return chunks;
}

List<String> splitUtf16SafeHalves(String value) {
  if (value.length < 2) return <String>[value];
  var midpoint = value.length ~/ 2;
  if (midpoint > 0 &&
      midpoint < value.length &&
      _isLowSurrogate(value.codeUnitAt(midpoint))) {
    midpoint++;
  }
  if (midpoint >= value.length) midpoint = value.length - 1;
  return <String>[value.substring(0, midpoint), value.substring(midpoint)];
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
