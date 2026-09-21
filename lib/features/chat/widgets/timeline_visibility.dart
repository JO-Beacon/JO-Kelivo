import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../shared/widgets/markdown_line_lexer.dart';
import '../../../utils/mcp_structured_image.dart';
import '../../home/services/ask_user_interaction_service.dart';
import '../../home/services/local_tools_service.dart';
import 'screen_time_tool_ui.dart';
import 'weather_tool_ui.dart';

/// 内置搜索会在别处单独引用，不应产生时间线卡片。
const String kBuiltinSearchToolName = 'builtin_search';

/// 带作用域的待审批标识。空的 [conversationId] 表示不限定作用域，
/// 可匹配任意会话（与 [ToolApprovalService] 相同的失败保护）。
class PendingApprovalKey {
  const PendingApprovalKey({
    required this.conversationId,
    required this.toolCallId,
  });

  final String conversationId;
  final String toolCallId;

  bool matches({required String conversationId, required String toolCallId}) {
    if (this.toolCallId != toolCallId) return false;
    if (this.conversationId.isEmpty) return true;
    return this.conversationId == conversationId;
  }

  @override
  bool operator ==(Object other) =>
      other is PendingApprovalKey &&
      other.conversationId == conversationId &&
      other.toolCallId == toolCallId;

  @override
  int get hashCode => Object.hash(conversationId, toolCallId);
}

/// 从工具结果中提取 markdown 图片。
///
/// 只有整行独占的 `![alt](url)` 才被视为附件。
/// JSON 字符串内、围栏代码块内或正文段落中的图片
/// 仍保留在文本里。目标地址可以包含空格与括号。
(String, List<String>) parseToolResultImages(
  String? content, {
  Map<String, dynamic>? metadata,
}) {
  if (content == null || content.isEmpty) {
    final typed = readMcpResultMetadata(metadata);
    if (typed != null) {
      return ('', dedupeImageUrisFirstSeen(mcpResultImageUris(typed)));
    }
    return ('', const []);
  }

  final typed = readMcpResultMetadata(metadata);
  if (typed != null) {
    final images = dedupeImageUrisFirstSeen(mcpResultImageUris(typed));
    return (_stripStandaloneToolImages(content), images);
  }

  final envelope = tryDecodeLegacyMcpToolResultEnvelope(content);
  if (envelope != null) {
    return (
      (envelope.legacyBody ?? envelope.markdown).trim(),
      dedupeImageUrisFirstSeen(envelope.imageUris),
    );
  }

  final images = <String>[];
  final seen = <String>{};
  final kept = <String>[];
  final lexer = MarkdownLineLexer();

  for (final line in _toolResultLogicalLines(content)) {
    // 仅限旧版保存的行。带类型的 ImageContent 现在不再作为私有标记。
    final structured = decodeMcpStructuredImageLine(line);
    if (structured != null) {
      if (seen.add(structured)) images.add(structured);
      continue;
    }
    if (_isIndentedCodeLine(line)) {
      kept.add(line);
      continue;
    }
    if (lexer.consumeFence(line)) {
      kept.add(line);
      continue;
    }
    final classified = _classifyStandaloneMarkdownImageLine(line.trim());
    switch (classified.kind) {
      case _ImageLineKind.image:
        final path = classified.path;
        if (path != null && seen.add(path)) images.add(path);
        continue;
      case _ImageLineKind.placeholder:
        continue;
      case _ImageLineKind.notImage:
        kept.add(line);
    }
  }
  return (kept.join('\n').trim(), images);
}

String _stripStandaloneToolImages(String content) {
  final kept = <String>[];
  final lexer = MarkdownLineLexer();
  for (final line in _toolResultLogicalLines(content)) {
    if (_isIndentedCodeLine(line) || lexer.consumeFence(line)) {
      kept.add(line);
      continue;
    }
    final classified = _classifyStandaloneMarkdownImageLine(line.trim());
    if (classified.kind == _ImageLineKind.notImage) {
      kept.add(line);
    }
  }
  return kept.join('\n').trim();
}

enum _ImageLineKind { notImage, placeholder, image }

class _ClassifiedImageLine {
  const _ClassifiedImageLine(this.kind, [this.path]);

  final _ImageLineKind kind;
  final String? path;
}

bool _isIndentedCodeLine(String line) => _leadingIndentColumns(line) >= 4;

int _leadingIndentColumns(String line) {
  var columns = 0;
  for (var i = 0; i < line.length; i++) {
    final unit = line.codeUnitAt(i);
    if (unit == 0x20) {
      columns += 1;
    } else if (unit == 0x09) {
      columns += 4 - (columns % 4);
    } else {
      break;
    }
  }
  return columns;
}

Iterable<String> _toolResultLogicalLines(String content) sync* {
  var i = 0;
  final end = content.length;
  while (i < end) {
    var lineEnd = i;
    while (lineEnd < end &&
        !markdownIsLogicalLineBreak(content.codeUnitAt(lineEnd))) {
      lineEnd++;
    }
    yield content.substring(i, lineEnd);
    if (lineEnd >= end) return;
    if (content.codeUnitAt(lineEnd) == 0x0D &&
        lineEnd + 1 < end &&
        content.codeUnitAt(lineEnd + 1) == 0x0A) {
      i = lineEnd + 2;
    } else {
      i = lineEnd + 1;
    }
  }
}

@visibleForTesting
({String? path, bool placeholder}) debugClassifyStandaloneImageLine(
  String trimmedLine,
) {
  final classified = _classifyStandaloneMarkdownImageLine(trimmedLine);
  return (
    path: classified.path,
    placeholder: classified.kind == _ImageLineKind.placeholder,
  );
}

_ClassifiedImageLine _classifyStandaloneMarkdownImageLine(String trimmedLine) {
  if (!trimmedLine.startsWith('![')) {
    return const _ClassifiedImageLine(_ImageLineKind.notImage);
  }
  final altClose = trimmedLine.indexOf('](');
  if (altClose == -1) {
    return const _ClassifiedImageLine(_ImageLineKind.notImage);
  }
  final destStart = altClose + 2;
  final parsed = _readMarkdownImageDestination(trimmedLine, destStart);
  if (parsed == null) {
    return const _ClassifiedImageLine(_ImageLineKind.notImage);
  }
  final raw = parsed.trim();
  if (raw.isEmpty || raw == 'generated') {
    return const _ClassifiedImageLine(_ImageLineKind.placeholder);
  }
  return _ClassifiedImageLine(
    _ImageLineKind.image,
    decodeMarkdownImageDestination(raw),
  );
}

/// 当目标地址占满该行剩余部分并在最后一个 `)` 处闭合时，
/// 返回原始目标地址（含可能使用的 `<>`）。
String? _readMarkdownImageDestination(String line, int destStart) {
  if (destStart >= line.length) return null;
  if (line.codeUnitAt(destStart) == 0x3C) {
    var j = destStart + 1;
    while (j < line.length) {
      final ch = line.codeUnitAt(j);
      if (ch == 0x5C && j + 1 < line.length) {
        j += 2;
        continue;
      }
      if (ch == 0x3E) {
        if (j + 1 == line.length - 1 && line.codeUnitAt(j + 1) == 0x29) {
          return line.substring(destStart, j + 1);
        }
        return null;
      }
      j += 1;
    }
    return null;
  }
  var depth = 1;
  var j = destStart;
  while (j < line.length && depth > 0) {
    final ch = line.codeUnitAt(j);
    if (ch == 0x28 && !_isEscapedByOddBackslashes(line, j)) {
      depth += 1;
    } else if (ch == 0x29 && !_isEscapedByOddBackslashes(line, j)) {
      depth -= 1;
      if (depth == 0) break;
    }
    j += 1;
  }
  if (depth != 0 || j != line.length - 1) return null;
  return line.substring(destStart, j);
}

bool _isEscapedByOddBackslashes(String text, int index) {
  var slashes = 0;
  for (var i = index - 1; i >= 0 && text.codeUnitAt(i) == 0x5C; i--) {
    slashes += 1;
  }
  return slashes.isOdd;
}

/// 使用共享的 Markdown／Windows 路径编解码器还原目标地址。
@visibleForTesting
String unescapeMarkdownDestination(String raw) {
  return decodeMarkdownImageDestination(raw);
}

/// [toolName] 是否允许占据一个思维链步骤。
bool toolCreatesTimelineCard(String toolName) =>
    toolName != kBuiltinSearchToolName;

/// 渲染器与列表高度估算共同使用的可见性判定。
///
/// - [showToolCards] 为真时展示所有真实的工具卡片
/// - 追问用户始终可见，以免生成被阻塞
/// - 加载中的工具在有待审批事项时保持可见
bool isTimelineToolVisible({
  required String toolName,
  required bool loading,
  required bool showToolCards,
  required bool pendingApproval,
  bool filterBuiltinSearch = true,
}) {
  if (filterBuiltinSearch && !toolCreatesTimelineCard(toolName)) return false;
  if (showToolCards) return true;
  if (toolName == LocalToolNames.askUser) return true;
  return loading && pendingApproval;
}

/// 把时间线区块折叠为最后两步加一行展开入口。
class CollapsedTimelineBlock<T> {
  const CollapsedTimelineBlock({
    required this.visibleSteps,
    required this.hiddenCount,
  });

  final List<T> visibleSteps;
  final int hiddenCount;

  bool get hasExpandRow => hiddenCount > 0;
}

CollapsedTimelineBlock<T> collapseTimelineSteps<T>(
  List<T> steps, {
  required bool collapseThinkingSteps,
}) {
  if (!collapseThinkingSteps || steps.length <= 2) {
    return CollapsedTimelineBlock<T>(
      visibleSteps: List<T>.of(steps),
      hiddenCount: 0,
    );
  }
  final hiddenCount = steps.length - 2;
  return CollapsedTimelineBlock<T>(
    visibleSteps: steps.sublist(hiddenCount),
    hiddenCount: hiddenCount,
  );
}

/// 按内容切分得到的累计 [toolCounts] 把工具拆成逐个卡片的区块。
/// 每个区块独立折叠。
List<List<T>> splitToolsIntoTimelineBlocks<T>(
  List<T> tools, {
  List<int>? toolCounts,
}) {
  if (tools.isEmpty) return const [];
  if (toolCounts == null || toolCounts.isEmpty) {
    return <List<T>>[List<T>.of(tools)];
  }

  final blocks = <List<T>>[];
  var start = 0;
  for (final count in toolCounts) {
    final end = count.clamp(0, tools.length);
    if (end > start) {
      blocks.add(tools.sublist(start, end));
      start = end;
    }
  }
  if (start < tools.length) {
    blocks.add(tools.sublist(start));
  }
  return blocks.isEmpty ? <List<T>>[List<T>.of(tools)] : blocks;
}

/// 使用 44px 时间线步骤外壳外加内联正文的工作区工具。
const Set<String> _workspaceToolNames = {
  'shell',
  'read_file',
  'write_file',
  'edit_file',
  'list_dir',
  'glob',
  'grep',
};

/// 工作区工具标题下的第二行（路径／命令／匹配模式）。
const double kEstimateWorkspaceSummaryLine = 16.0;

/// 工作区工具标题下方的间距加一行 [WorkspaceFileChip]。
const double kEstimateWorkspaceChipRow = 38.0;

/// 一行 stdout／stderr 尾部输出（12px / 1.4）。
const double kEstimateWorkspaceTailLine = 17.0;

/// 环境未就绪提示加安装按钮。
const double kEstimateWorkspaceEnvNotice = 36.0;

/// 折叠的工具标题下方额外高度。该高度不受常规四行摘要
/// 开关约束 —— 追问用户、语音播报、屏幕使用时间、图片、待审批
/// 以及工作区工具正文各自有独立结构。
double estimateToolExtraHeight({
  required String toolName,
  required Map<String, dynamic> arguments,
  required String? content,
  Map<String, dynamic>? metadata,
  required bool showToolResultSummary,
  required bool hideToolResultImages,
  required bool pendingApproval,
  required double textWidth,
  required double fontScale,
  required double Function(
    String text, {
    required double charsPerLine,
    required double? codeCharsPerLine,
    required double codeLineRatio,
    required int? collapsedCodeLines,
  })
  wrappedLineCount,
}) {
  if (toolName == LocalToolNames.askUser) {
    return _estimateAskUserExtra(
      arguments,
      content: content,
      textWidth: textWidth,
      fontScale: fontScale,
      wrappedLineCount: wrappedLineCount,
    );
  }

  final ttsText = toolName == LocalToolNames.textToSpeech
      ? (arguments['text'] ?? '').toString().trim()
      : '';
  if (ttsText.isNotEmpty) {
    return _estimateTtsReplayRowHeight * fontScale.clamp(0.85, 1.4);
  }

  final (cleanText, imagePaths) = parseToolResultImages(
    content,
    metadata: metadata,
  );
  if (toolName == LocalToolNames.screenTime) {
    final screenTime = ScreenTimeResult.tryParse(cleanText);
    if (screenTime != null &&
        (screenTime.isNoPermission || screenTime.hasApps)) {
      return _estimateScreenTimeExtra(screenTime, fontScale);
    }
  }
  if (toolName == LocalToolNames.weather) {
    final weather = WeatherToolResult.tryParse(cleanText);
    if (weather != null && !weather.isError) {
      return _estimateWeatherExtra(weather, fontScale);
    }
  }

  var extra = 0.0;
  final isWorkspace = _workspaceToolNames.contains(toolName);
  if (isWorkspace) {
    extra += _estimateWorkspaceToolCardExtra(
      toolName: toolName,
      arguments: arguments,
      content: content,
      metadata: metadata,
    );
  }
  final summaryFontSize = 12.0 * fontScale;
  final summaryLineHeight = summaryFontSize * 1.4;
  var hasSummary = false;

  if (pendingApproval) {
    extra += _estimatePendingApprovalExtra(
      arguments,
      showToolResultSummary: showToolResultSummary,
      textWidth: textWidth,
      fontScale: fontScale,
      wrappedLineCount: wrappedLineCount,
    );
    hasSummary = showToolResultSummary;
  } else if (showToolResultSummary && !isWorkspace) {
    final summary = cleanText.trim();
    if (summary.isNotEmpty) {
      final charWidth = summaryFontSize * 0.55;
      final charsPerLine = (textWidth / charWidth).clamp(8.0, 80.0);
      final lines = wrappedLineCount(
        summary,
        charsPerLine: charsPerLine,
        codeCharsPerLine: null,
        codeLineRatio: 1.0,
        collapsedCodeLines: null,
      ).clamp(0.0, 4.0);
      extra += lines * summaryLineHeight;
      hasSummary = lines > 0;
    }
  }

  if (!hideToolResultImages && imagePaths.isNotEmpty) {
    extra += _estimateToolImageHeight;
    if (hasSummary) extra += _estimateToolImageSummaryGap;
  }

  return extra;
}

/// 工作区工具正文在 44px 时间线步骤外壳之外额外占用的高度。
double _estimateWorkspaceToolCardExtra({
  required String toolName,
  required Map<String, dynamic> arguments,
  required String? content,
  Map<String, dynamic>? metadata,
}) {
  final path = _workspaceEstimatePath(arguments, metadata);
  final command = (arguments['command'] ?? '').toString().trim();
  final pattern = (arguments['pattern'] ?? '').toString().trim();
  final hasSummary = switch (toolName) {
    'shell' => command.isNotEmpty,
    'glob' || 'grep' => pattern.isNotEmpty || path.isNotEmpty,
    _ => path.isNotEmpty,
  };
  var extra = hasSummary ? kEstimateWorkspaceSummaryLine : 0.0;

  if (toolName == 'shell') {
    final tail = _workspaceEstimateTailLineCount(content, metadata);
    if (tail > 0) extra += tail * kEstimateWorkspaceTailLine;
  } else {
    final hasChips = switch (toolName) {
      'read_file' || 'write_file' || 'edit_file' => path.isNotEmpty,
      'list_dir' =>
        path.isNotEmpty || _workspaceEstimateHasResultPaths(content, metadata),
      'glob' || 'grep' => _workspaceEstimateHasResultPaths(content, metadata),
      _ => false,
    };
    if (hasChips) extra += kEstimateWorkspaceChipRow;
  }
  if (_workspaceEstimateEnvNotReady(metadata)) {
    extra += kEstimateWorkspaceEnvNotice;
  }
  return extra;
}

String _workspaceEstimatePath(
  Map<String, dynamic> arguments,
  Map<String, dynamic>? metadata,
) {
  final fromMeta = _workspaceMetaString(metadata, 'path');
  if (fromMeta.isNotEmpty) return fromMeta;
  final path = (arguments['path'] ?? '').toString().trim();
  if (path.isNotEmpty) return path;
  return (arguments['pattern'] ?? '').toString().trim();
}

String _workspaceMetaString(Map<String, dynamic>? metadata, String key) {
  if (metadata == null) return '';
  final nested = metadata['workspace'];
  final map = nested is Map ? nested : metadata;
  return (map[key] ?? '').toString().trim();
}

bool _workspaceEstimateHasResultPaths(
  String? content,
  Map<String, dynamic>? metadata,
) {
  final nested = metadata?['workspace'];
  final map = nested is Map ? nested : metadata;
  final files = map?['files'];
  if (files is List && files.isNotEmpty) return true;
  if (content == null || content.isEmpty) return false;
  return const LineSplitter()
      .convert(content)
      .any((line) => line.isNotEmpty && !line.startsWith('...'));
}

int _workspaceEstimateTailLineCount(
  String? content,
  Map<String, dynamic>? metadata,
) {
  final preview = _workspaceMetaString(metadata, 'stdoutPreview');
  final stderr = _workspaceMetaString(metadata, 'stderrPreview');
  final text = preview.isNotEmpty
      ? preview
      : (stderr.isNotEmpty ? stderr : (content ?? ''));
  if (text.isEmpty) return 0;
  final lines = const LineSplitter()
      .convert(text)
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return 0;
  return lines.length > 4 ? 4 : lines.length;
}

bool _workspaceEstimateEnvNotReady(Map<String, dynamic>? metadata) {
  if (metadata == null) return false;
  final nested = metadata['workspace'];
  final map = nested is Map ? nested : metadata;
  return map['status'] == 'error' && map['code'] == 'environment_not_ready';
}

const double _estimateTtsReplayRowHeight = 36;
const double _estimateToolImageHeight = 120;
const double _estimateToolImageSummaryGap = 8;
const double _estimateAskUserOptionHeight = 40;
const double _estimateAskUserOptionGap = 7;
const double _estimateAskUserOtherHeight = 40;
const double _estimateAskUserSubmitHeight = 38;
const double _estimateAskUserAnsweredGap = 3;
const double _estimateAskUserAnsweredPad = 4;

/// 与 [_AskUserOptionRow] 对齐：13px / 1.25，不限行数，最小高度 40。
double _estimateAskUserOptionRowHeight(
  String label, {
  required double textWidth,
  required double fontScale,
}) {
  final fontSize = 13.0 * fontScale;
  final optionTextWidth = math.max(40.0, textWidth - 28 - 44);
  final textHeight = _askUserLayoutHeight(
    label,
    fontSize: fontSize,
    height: 1.25,
    maxWidth: optionTextWidth,
    fontWeight: FontWeight.w500,
  );
  return math.max(
    _estimateAskUserOptionHeight * fontScale,
    textHeight + 16 * fontScale,
  );
}

double _askUserLayoutHeight(
  String text, {
  required double fontSize,
  required double height,
  required double maxWidth,
  FontWeight? fontWeight,
}) {
  if (text.trim().isEmpty) return fontSize * height;
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        height: height,
        fontWeight: fontWeight,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(1.0, maxWidth));
  try {
    return math.max(fontSize * height, painter.height);
  } finally {
    painter.dispose();
  }
}

double _estimateAskUserExtra(
  Map<String, dynamic> arguments, {
  required String? content,
  required double textWidth,
  required double fontScale,
  required double Function(
    String text, {
    required double charsPerLine,
    required double? codeCharsPerLine,
    required double codeLineRatio,
    required int? collapsedCodeLines,
  })
  wrappedLineCount,
}) {
  final questions = AskUserInteractionService.normalizeQuestions(arguments);
  if (questions.isEmpty) return 20 * fontScale;
  final answeredContent = content;
  if (answeredContent != null && answeredContent.trim().isNotEmpty) {
    return _estimateAskUserAnsweredExtra(
      questions,
      answeredContent,
      textWidth: textWidth,
      fontScale: fontScale,
    );
  }
  final fontSize = 13.0 * fontScale;
  // 卡片内边距（16+12）加上问题行上的“跳过”按钮。
  final questionWidth = math.max(80.0, textWidth - 40 - 28 - 56);
  var extra = 0.0;
  for (final question in questions) {
    extra += _askUserLayoutHeight(
      question.question,
      fontSize: fontSize,
      height: 1.35,
      maxWidth: questionWidth,
    );
    extra += 8;
    for (final option in question.options) {
      extra += _estimateAskUserOptionRowHeight(
        option,
        textWidth: textWidth,
        fontScale: fontScale,
      );
      extra += _estimateAskUserOptionGap * fontScale;
    }
    extra += _estimateAskUserOtherHeight * fontScale;
    extra += 12;
  }
  extra += _estimateAskUserSubmitHeight * fontScale;
  return extra;
}

double _estimateAskUserAnsweredExtra(
  List<AskUserQuestion> questions,
  String content, {
  required double textWidth,
  required double fontScale,
}) {
  final questionFontSize = 12.5 * fontScale;
  final answerFontSize = 13.0 * fontScale;
  // 卡片内边距（16+12）加上未计入 [textWidth] 的消息内缩。
  final innerWidth = math.max(80.0, textWidth - 40);
  final answers = _askUserAnsweredValues(content);
  var extra = 8.0;
  for (var i = 0; i < questions.length; i++) {
    final question = questions[i];
    extra += _askUserLayoutHeight(
      question.question,
      fontSize: questionFontSize,
      height: 1.35,
      maxWidth: innerWidth,
      fontWeight: FontWeight.w600,
    );
    extra += _estimateAskUserAnsweredGap;
    extra += _askUserLayoutHeight(
      _askUserAnswerSummary(question.id, answers),
      fontSize: answerFontSize,
      height: 1.35,
      maxWidth: innerWidth,
      fontWeight: FontWeight.w600,
    );
    extra += _estimateAskUserAnsweredPad;
    if (i != questions.length - 1) extra += 10;
  }
  return extra;
}

Map<dynamic, dynamic> _askUserAnsweredValues(String content) {
  try {
    final payload = jsonDecode(content);
    if (payload is Map) {
      final answers = payload['answers'];
      if (answers is Map) return answers;
    }
  } catch (_) {}
  return const <dynamic, dynamic>{};
}

String _askUserAnswerSummary(String questionId, Map<dynamic, dynamic> answers) {
  final raw = answers[questionId];
  if (raw is! Map) return ' ';
  if (raw['skipped'] == true) return 'Skipped';
  final value = raw['value'];
  if (value is List) {
    final joined = value.map((item) => item.toString()).join(', ');
    return joined.isEmpty ? ' ' : joined;
  }
  final text = value?.toString() ?? '';
  return text.isEmpty ? ' ' : text;
}

double _estimateScreenTimeExtra(ScreenTimeResult result, double fontScale) {
  final line = 16.0 * fontScale;
  if (result.isNoPermission) return line;
  final apps = result.apps.length.clamp(0, 3);
  return line + apps * (line + 2);
}

double _estimateWeatherExtra(WeatherToolResult result, double fontScale) {
  if (!result.hasCurrent) return 0;
  final line = 16.0 * fontScale;
  return line * 2;
}

double _estimatePendingApprovalExtra(
  Map<String, dynamic> arguments, {
  required bool showToolResultSummary,
  required double textWidth,
  required double fontScale,
  required double Function(
    String text, {
    required double charsPerLine,
    required double? codeCharsPerLine,
    required double codeLineRatio,
    required int? collapsedCodeLines,
  })
  wrappedLineCount,
}) {
  // 批准／拒绝按钮位于标题行 —— 不产生额外的垂直高度。
  if (!showToolResultSummary) return 0;
  final entries = arguments.entries.take(2).map((e) {
    final v = e.value?.toString() ?? '';
    final truncated = v.length > 40 ? '${v.substring(0, 40)}...' : v;
    return '${e.key}: $truncated';
  });
  final summary = entries.join(', ');
  if (summary.isEmpty) return 0;
  final fontSize = 12.0 * fontScale;
  final charWidth = fontSize * 0.55;
  final charsPerLine = (textWidth / charWidth).clamp(8.0, 80.0);
  final lines = wrappedLineCount(
    summary,
    charsPerLine: charsPerLine,
    codeCharsPerLine: null,
    codeLineRatio: 1.0,
    collapsedCodeLines: null,
  ).clamp(0.0, 2.0);
  return lines * (fontSize * 1.4);
}
