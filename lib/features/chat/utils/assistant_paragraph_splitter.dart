import '../../../shared/widgets/markdown_line_lexer.dart';

/// 按空行把助手 Markdown 拆成视觉段落，同时保持结构块完整。
///
/// 代码围栏、`<details>`、展示公式、缩进续行、连续列表和单独标题
/// 不会被错误拆开。该函数只生成渲染切片，不修改持久化消息内容。
List<String> splitAssistantParagraphs(String text) {
  if (text.trim().isEmpty) return <String>[text];

  final lines = text.split('\n');
  final chunks = <String>[];
  final current = <String>[];
  final lexer = MarkdownLineLexer();
  final math = markdownScanDisplayMath(text);
  var offset = 0;

  void flush() {
    final chunk = current.join('\n').trim();
    if (chunk.isNotEmpty) chunks.add(chunk);
    current.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final lineStart = offset;
    offset += line.length + 1;
    lexer.consumePhysicalLine(line);

    final breaksParagraph =
        line.trim().isEmpty &&
        !lexer.protected &&
        !math.covers(lineStart) &&
        !_continuesBlock(lines, i + 1);
    if (breaksParagraph) {
      flush();
      continue;
    }
    current.add(line);
  }
  flush();

  if (chunks.length < 2) return <String>[text];
  return _mergeRelatedChunks(chunks);
}

final RegExp _listItemPattern = RegExp(r'^\s*([-*+]\s|\d+[.)]\s)');
final RegExp _headingPattern = RegExp(r'^#{1,6}\s');

bool _continuesBlock(List<String> lines, int from) {
  for (var i = from; i < lines.length; i++) {
    if (lines[i].trim().isEmpty) continue;
    return lines[i].startsWith('    ') || lines[i].startsWith('\t');
  }
  return false;
}

List<String> _mergeRelatedChunks(List<String> chunks) {
  final merged = <String>[];
  for (final chunk in chunks) {
    if (merged.isNotEmpty && _shouldMerge(merged.last, chunk)) {
      merged[merged.length - 1] = '${merged.last}\n\n$chunk';
    } else {
      merged.add(chunk);
    }
  }
  return merged;
}

bool _shouldMerge(String previous, String next) {
  if (_isHeadingOnly(previous)) return true;
  return _startsList(previous) && _startsList(next);
}

bool _isHeadingOnly(String chunk) =>
    !chunk.contains('\n') && _headingPattern.hasMatch(chunk);

bool _startsList(String chunk) => _listItemPattern.hasMatch(chunk);
