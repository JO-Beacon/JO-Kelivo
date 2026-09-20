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

/// 将 [value] 限制在 [maxLength] 个 code unit 以内，保留由 [marker] 连接
/// 的首尾预览。切点会做代理对校正，绝不切开代理对；输出长度不超过
/// [maxLength]。
String truncateHeadTailUtf16Safe(
  String value,
  int maxLength, {
  required String marker,
}) {
  if (value.length <= maxLength) return value;
  final available = maxLength - marker.length;
  if (available <= 0) return truncateHeadUtf16Safe(value, maxLength);
  final head = available ~/ 2;
  final tail = available - head;
  final headEnd = _headEndAt(value, head);
  final tailStart = _tailStartAt(value, value.length - tail);
  return '${value.substring(0, headEnd)}$marker'
      '${value.substring(tailStart)}';
}

/// 返回适合 `value.substring(0, result)` 的结束下标，绝不落在代理对中间。
int _headEndAt(String value, int end) {
  if (end <= 0 || end >= value.length) return end;
  final prev = value.codeUnitAt(end - 1);
  final cur = value.codeUnitAt(end);
  if (!_isHighSurrogate(prev) || !_isLowSurrogate(cur)) return end;
  return end - 1;
}

/// 返回适合 `value.substring(result)` 的起始下标，绝不落在代理对中间。
int _tailStartAt(String value, int start) {
  if (start <= 0 || start >= value.length) return start;
  final prev = value.codeUnitAt(start - 1);
  final cur = value.codeUnitAt(start);
  if (!_isHighSurrogate(prev) || !_isLowSurrogate(cur)) return start;
  return start + 1;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
