import '../../home/services/ask_user_interaction_service.dart';
import '../../home/services/local_tools_service.dart';
import 'screen_time_tool_ui.dart';

const String kBuiltinSearchToolName = 'builtin_search';

(String, List<String>) parseToolResultImages(String? content) {
  if (content == null || content.isEmpty) return ('', const []);
  final images = <String>[];
  final buffer = StringBuffer();
  var i = 0;
  while (i < content.length) {
    if (content.startsWith('![', i)) {
      final altClose = content.indexOf('](', i + 2);
      if (altClose != -1) {
        final destStart = altClose + 2;
        var depth = 1;
        var j = destStart;
        while (j < content.length && depth > 0) {
          final ch = content.codeUnitAt(j);
          if (ch == 0x28) {
            depth++;
          } else if (ch == 0x29) {
            depth--;
            if (depth == 0) break;
          }
          j++;
        }
        if (depth == 0 && j < content.length) {
          final path = content.substring(destStart, j).trim();
          if (path.isNotEmpty && path != 'generated') images.add(path);
          i = j + 1;
          continue;
        }
      }
    }
    buffer.writeCharCode(content.codeUnitAt(i));
    i++;
  }
  return (buffer.toString().trim(), images);
}

bool toolCreatesTimelineCard(String toolName) =>
    toolName != kBuiltinSearchToolName;

bool isTimelineToolVisible({
  required String toolName,
  required bool loading,
  required bool showToolCards,
  required bool pendingApproval,
}) {
  if (!toolCreatesTimelineCard(toolName)) return false;
  if (showToolCards) return true;
  if (toolName == LocalToolNames.askUser) return true;
  // JO-Kelivo's renderer keeps every in-progress tool visible while cards
  // are hidden; a pending approval is also visible even if its part has
  // already been marked complete.
  return loading || pendingApproval;
}

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
  if (start < tools.length) blocks.add(tools.sublist(start));
  return blocks.isEmpty ? <List<T>>[List<T>.of(tools)] : blocks;
}

double estimateToolExtraHeight({
  required String toolName,
  required Map<String, dynamic> arguments,
  required String? content,
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
      textWidth,
      fontScale,
      wrappedLineCount,
    );
  }
  final ttsText = toolName == LocalToolNames.textToSpeech
      ? (arguments['text'] ?? '').toString().trim()
      : '';
  if (ttsText.isNotEmpty) {
    return _estimateTtsReplayRowHeight * fontScale.clamp(0.85, 1.4);
  }
  final (cleanText, imagePaths) = parseToolResultImages(content);
  if (toolName == LocalToolNames.screenTime) {
    final screenTime = ScreenTimeResult.tryParse(cleanText);
    if (screenTime != null &&
        (screenTime.isNoPermission || screenTime.hasApps)) {
      return _estimateScreenTimeExtra(screenTime, fontScale);
    }
  }
  var extra = 0.0;
  final summaryFontSize = 12.0 * fontScale;
  final summaryLineHeight = summaryFontSize * 1.4;
  var hasSummary = false;
  if (pendingApproval) {
    extra += _estimatePendingApprovalExtra(
      arguments,
      textWidth: textWidth,
      fontScale: fontScale,
      wrappedLineCount: wrappedLineCount,
    );
    hasSummary = true;
  } else if (showToolResultSummary) {
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

const double _estimateTtsReplayRowHeight = 36;
const double _estimateToolImageHeight = 120;
const double _estimateToolImageSummaryGap = 8;
const double _estimateApprovalButtonsHeight = 36;
const double _estimateAskUserOptionHeight = 36;
const double _estimateAskUserSubmitHeight = 40;

double _estimateAskUserExtra(
  Map<String, dynamic> arguments,
  double textWidth,
  double fontScale,
  double Function(
    String text, {
    required double charsPerLine,
    required double? codeCharsPerLine,
    required double codeLineRatio,
    required int? collapsedCodeLines,
  })
  wrappedLineCount,
) {
  final questions = AskUserInteractionService.normalizeQuestions(arguments);
  if (questions.isEmpty) return 20 * fontScale;
  final fontSize = 13.0 * fontScale;
  final lineHeight = fontSize * 1.35;
  final charWidth = fontSize * 0.55;
  final charsPerLine = (textWidth / charWidth).clamp(8.0, 80.0);
  var extra = 8.0;
  for (final question in questions) {
    extra +=
        wrappedLineCount(
          question.question,
          charsPerLine: charsPerLine,
          codeCharsPerLine: null,
          codeLineRatio: 1.0,
          collapsedCodeLines: null,
        ).clamp(1.0, 3.0) *
        lineHeight;
    extra += question.options.length * _estimateAskUserOptionHeight * fontScale;
    extra += 12;
  }
  extra += _estimateAskUserSubmitHeight * fontScale;
  return extra;
}

double _estimateScreenTimeExtra(ScreenTimeResult result, double fontScale) {
  final line = 16.0 * fontScale;
  if (result.isNoPermission) return line;
  final apps = result.apps.length.clamp(0, 3);
  return line + apps * (line + 2);
}

double _estimatePendingApprovalExtra(
  Map<String, dynamic> arguments, {
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
  final entries = arguments.entries.take(2).map((e) {
    final v = e.value?.toString() ?? '';
    final truncated = v.length > 40 ? '${v.substring(0, 40)}...' : v;
    return '${e.key}: $truncated';
  });
  final summary = entries.join(', ');
  var extra = _estimateApprovalButtonsHeight * fontScale;
  if (summary.isEmpty) return extra;
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
  return extra + lines * (fontSize * 1.4);
}
