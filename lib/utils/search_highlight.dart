import 'package:flutter/painting.dart';

List<TextSpan> highlightSearchText(
  String text,
  List<String> tokens,
  TextStyle base,
  TextStyle highlight,
) {
  if (tokens.isEmpty || text.isEmpty) {
    return [TextSpan(text: text, style: base)];
  }
  final spans = <TextSpan>[];
  final lower = text.toLowerCase();
  var position = 0;
  while (position < text.length) {
    var earliest = -1;
    var earliestLength = 0;
    for (final token in tokens) {
      final index = lower.indexOf(token, position);
      if (index >= 0 && (earliest < 0 || index < earliest)) {
        earliest = index;
        earliestLength = token.length;
      }
    }
    if (earliest < 0) {
      spans.add(TextSpan(text: text.substring(position), style: base));
      break;
    }
    if (earliest > position) {
      spans.add(
        TextSpan(text: text.substring(position, earliest), style: base),
      );
    }
    spans.add(
      TextSpan(
        text: text.substring(earliest, earliest + earliestLength),
        style: highlight,
      ),
    );
    position = earliest + earliestLength;
  }
  return spans;
}
