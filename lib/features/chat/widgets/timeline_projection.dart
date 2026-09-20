import 'dart:convert';

import '../../../core/models/message_part.dart';
import '../utils/thinking_tag_parser.dart';
import 'timeline_visibility.dart';

/// 时间线投影器视角下的工具。
///
/// 字段与 [ToolUIPart] 兼容，使渲染器与高度估算器能共用同一次
/// 遍历，而无需导入控件文件。
class TimelineToolRef {
  const TimelineToolRef({
    required this.providerId,
    required this.fallbackOrdinal,
    required this.toolName,
    required this.arguments,
    this.content,
    this.metadata,
    this.loading = false,
    this.memoToken,
  });

  /// 提供方给出的 id。载荷没有 id 时为空。绝不合成。
  final String providerId;

  /// [providerId] 为空时使用的工具序号。与真实 id 不相交。
  final int fallbackOrdinal;

  final String toolName;
  final Map<String, dynamic> arguments;
  final String? content;
  final Map<String, dynamic>? metadata;
  final bool loading;

  /// 原始 [ToolUIPart] 的身份（或稳定的字段哈希）。
  ///
  /// 渲染器不得对临时转换出来的对象做记忆化。
  final int? memoToken;

  /// 原始提供方 id。工具没有提供方 id 时为空。
  String get id => providerId;

  TimelineToolRef copyWith({
    String? providerId,
    int? fallbackOrdinal,
    String? toolName,
    Map<String, dynamic>? arguments,
    String? content,
    Map<String, dynamic>? metadata,
    bool? loading,
    int? memoToken,
  }) {
    return TimelineToolRef(
      providerId: providerId ?? this.providerId,
      fallbackOrdinal: fallbackOrdinal ?? this.fallbackOrdinal,
      toolName: toolName ?? this.toolName,
      arguments: arguments ?? this.arguments,
      content: content ?? this.content,
      metadata: metadata ?? this.metadata,
      loading: loading ?? this.loading,
      memoToken: memoToken ?? this.memoToken,
    );
  }
}

/// 存在结构化 parts 或旧版分段时使用的推理覆盖层。
class TimelineReasoningRef {
  const TimelineReasoningRef({
    required this.text,
    this.expanded = true,
    this.loading = false,
    this.startAt,
    this.finishedAt,
    this.toolStartIndex = 0,
  });

  final String text;
  final bool expanded;
  final bool loading;
  final DateTime? startAt;
  final DateTime? finishedAt;
  final int toolStartIndex;
}

class TimelineProjectedStep {
  const TimelineProjectedStep.reasoning({
    required this.sourceOrdinal,
    required this.reasoning,
    required this.reasoningCountAfter,
    required this.toolCountAfter,
    this.reasoningOverlayIndex,
  }) : tool = null;

  const TimelineProjectedStep.tool({
    required this.sourceOrdinal,
    required this.tool,
    required this.reasoningCountAfter,
    required this.toolCountAfter,
  }) : reasoning = null,
       reasoningOverlayIndex = null;

  final int sourceOrdinal;
  final TimelineReasoningRef? reasoning;
  final TimelineToolRef? tool;
  final int reasoningCountAfter;
  final int toolCountAfter;

  /// 在所提供的推理分段覆盖层中的下标（若有）。
  final int? reasoningOverlayIndex;

  bool get isReasoning => reasoning != null;
  bool get isTool => tool != null;
}

class TimelineProjectedBlock {
  const TimelineProjectedBlock.text(this.text)
    : steps = const [],
      imageUri = null,
      imageKey = null,
      aspectRatio = null;

  const TimelineProjectedBlock.thinking(this.steps)
    : text = null,
      imageUri = null,
      imageKey = null,
      aspectRatio = null;

  const TimelineProjectedBlock.image(
    this.imageUri, {
    this.imageKey,
    this.aspectRatio,
  }) : text = null,
       steps = const [];

  final String? text;
  final String? imageUri;
  final String? imageKey;
  final double? aspectRatio;
  final List<TimelineProjectedStep> steps;

  bool get isText => text != null;
  bool get isImage => imageUri != null;
  bool get isThinking => steps.isNotEmpty;
}

/// 宽高比未知时内联 [ImagePart] 的兜底高度。
/// 宽度取消息或气泡宽度。不要从 Markdown 推断。
const double kTimelineImageBlockHeight = 240;

/// 由已知宽高比（`width / height`）算出的布局高度。
double estimateTimelineImageHeight({
  required double maxWidth,
  double? aspectRatio,
}) {
  if (aspectRatio == null || !aspectRatio.isFinite || aspectRatio <= 0) {
    return kTimelineImageBlockHeight;
  }
  return maxWidth / aspectRatio;
}

/// 稳定的图片身份。绝不使用载荷 URI。
String timelineImageBlockKey({
  String? imageId,
  String? assetId,
  required int sourceOrdinal,
}) {
  final streamId = imageId?.trim() ?? '';
  if (streamId.isNotEmpty) return 'image-id:$streamId';
  final asset = assetId?.trim() ?? '';
  if (asset.isNotEmpty) return 'image-id:$asset';
  return 'image-ordinal:$sourceOrdinal';
}

/// 以 [timelineImageBlockKey] 为键的内存宽高比缓存。
final Map<String, double> timelineImageAspects = <String, double>{};

/// 渲染器与估算器共用的“推理加载中”判定。
bool timelineReasoningLoading({
  required DateTime? finishedAt,
  required bool isStreaming,
  bool usingInlineThink = false,
}) {
  if (usingInlineThink) return false;
  if (finishedAt != null) return false;
  return isStreaming;
}

class VisibleTimelineBlock {
  const VisibleTimelineBlock({
    required this.visibleSteps,
    required this.hiddenCount,
  });

  final List<TimelineProjectedStep> visibleSteps;
  final int hiddenCount;

  bool get hasExpandRow => hiddenCount > 0;
}

/// 共用的 [fromParts] 判定，以及渲染器与估算器遍历的区块。
class TimelineProjection {
  const TimelineProjection({
    required this.fromParts,
    required this.blocks,
    this.partsArrivalOrdered = false,
  });

  final bool fromParts;
  final List<TimelineProjectedBlock> blocks;

  /// 由调用方提供：正在流式接收的消息按到达顺序遍历。
  ///
  /// 不要根据是否出现 [ReasoningPart] / [ToolCallPart] 来推断它。
  /// 该值为 false 时，合法的历史 [contentSplits] 仍会还原
  /// 前缀 → 工具/思考 → 后缀 的顺序。
  final bool partsArrivalOrdered;
}

/// 经角色设置与审批过滤后的一块可见助手内容。
class TimelineVisibleBlock {
  const TimelineVisibleBlock.text(this.text)
    : imageUri = null,
      imageKey = null,
      aspectRatio = null,
      thinkingSteps = const [];

  const TimelineVisibleBlock.image(
    this.imageUri, {
    this.imageKey,
    this.aspectRatio,
  }) : text = null,
       thinkingSteps = const [];

  const TimelineVisibleBlock.thinking(this.thinkingSteps)
    : text = null,
      imageUri = null,
      imageKey = null,
      aspectRatio = null;

  final String? text;
  final String? imageUri;
  final String? imageKey;
  final double? aspectRatio;

  /// 经审批/设置过滤后的步骤。折叠由遍历器施加。
  final List<TimelineProjectedStep> thinkingSteps;

  bool get isText => text != null;
  bool get isImage => imageUri != null;
  bool get isThinking => thinkingSteps.isNotEmpty;
}

/// 以与渲染器相同的方式解析持久化的 tool_call 载荷。
TimelineToolRef? parseTimelineToolPayload(
  String payloadJson, {
  int fallbackOrdinal = 0,
}) {
  try {
    final decoded = _decodeJsonMap(payloadJson);
    if (decoded == null) return null;
    final providerId = (decoded['id'] ?? '').toString().trim();
    final name = (decoded['name'] ?? '').toString();
    final args = decoded['arguments'];
    final content = decoded['content']?.toString();
    final rawMeta = decoded['metadata'];
    final metadata = rawMeta is Map ? Map<String, dynamic>.from(rawMeta) : null;
    final arguments = args is Map
        ? args.cast<String, dynamic>()
        : const <String, dynamic>{};
    final loading = content == null || content.isEmpty;
    return TimelineToolRef(
      providerId: providerId,
      fallbackOrdinal: fallbackOrdinal,
      toolName: name,
      arguments: arguments,
      content: content,
      metadata: metadata,
      loading: loading,
      memoToken: Object.hash(
        providerId,
        fallbackOrdinal,
        name,
        content,
        loading,
        Object.hashAll(
          arguments.entries.map((entry) => Object.hash(entry.key, entry.value)),
        ),
      ),
    );
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _decodeJsonMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } catch (_) {}
  return null;
}

/// 稳定的工具键。去空白后的 id 与兜底名使用不相交的命名空间，
/// 因此 `fallback:0:search` 这样的 id 不会与空 id 的工具碰撞。
String timelineToolStepKey({
  required String id,
  required int sourceOrdinal,
  required String toolName,
}) {
  final trimmed = id.trim();
  if (trimmed.isNotEmpty) return 'tool-id:$trimmed';
  return 'tool-fallback:$sourceOrdinal:$toolName';
}

/// 图片 part 是否开启新的渲染区块，与渲染器保持一致。
bool timelineImagePartFlushesBlock(ImagePart part) =>
    !part.unavailable && part.uri.trim().isNotEmpty;

/// 以与渲染器相同的规则投影助手时间线区块：
/// 结构化 parts，或推理与工具混合的顺序（带内容切分兜底）。
TimelineProjection projectAssistantTimeline({
  required List<MessagePart> parts,
  required List<TimelineToolRef> liveTools,
  required List<TimelineReasoningRef> reasoningSegments,
  required String visualContent,
  List<int>? contentSplitOffsets,
  List<int>? reasoningCountAtSplit,
  List<int>? toolCountAtSplit,
  String Function(String text)? transformText,
  bool? renderFromParts,
  bool partsArrivalOrdered = false,
  // reasoningSegments 携带合成的内联思考覆盖层时为真。
  // 提供方给出的推理会保留形似标签的文本原样。
  bool? parseInlineThinking,
  bool inlineThinkingExpanded = true,
}) {
  final usableSplits = contentSplitsAreUsable(
    contentSplitOffsets,
    reasoningCountAtSplit,
    toolCountAtSplit,
  );
  final fromParts =
      renderFromParts ??
      _shouldProjectFromParts(
        parts: parts,
        visualContent: visualContent,
        liveTools: liveTools,
        reasoningSegments: reasoningSegments,
        contentSplitOffsets: contentSplitOffsets,
        reasoningCountAtSplit: reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit,
        usableSplits: usableSplits,
        partsArrivalOrdered: partsArrivalOrdered,
      );
  if (fromParts) {
    // 内联推理仅用于替代缺失的提供方推理。
    final useInlineThinking =
        (parseInlineThinking ?? reasoningSegments.isEmpty) &&
        !parts.any((part) => part is ReasoningPart);
    var displayParts = parts;
    if (useInlineThinking) {
      final joined = parts.whereType<TextPart>().map((p) => p.text).join();
      final ranges = ThinkingTagParser.parseWithRanges(
        joined,
        includeUnclosed: false,
      );
      if (ranges.hiddenRanges.isNotEmpty) {
        displayParts = <MessagePart>[];
        ThinkingTagParser.walkSlices(
          parts,
          joined,
          ranges,
          onVisible: (text) => displayParts.add(TextPart(text)),
          onThinking: (_, text) => displayParts.add(ReasoningPart(text)),
          onOther: displayParts.add,
        );
      }
    }
    return mergeLiveToolsIntoProjection(
      TimelineProjection(
        fromParts: true,
        partsArrivalOrdered: partsArrivalOrdered,
        blocks: _projectFromParts(
          parts: displayParts,
          reasoningSegments: reasoningSegments,
          transformText: transformText,
          inlineThinking: useInlineThinking,
          inlineThinkingExpanded: inlineThinkingExpanded,
        ),
      ),
      liveTools,
    );
  }

  final mixed = _interleaveReasoningAndTools(
    liveTools: [
      for (final tool in liveTools)
        if (toolCreatesTimelineCard(tool.toolName)) tool,
    ],
    reasoningSegments: reasoningSegments,
  );
  if (mixed.isEmpty) {
    return mergeLiveToolsIntoProjection(
      TimelineProjection(
        fromParts: false,
        partsArrivalOrdered: partsArrivalOrdered,
        blocks: visualContent.trim().isEmpty
            ? const <TimelineProjectedBlock>[]
            : <TimelineProjectedBlock>[
                TimelineProjectedBlock.text(visualContent),
              ],
      ),
      liveTools,
    );
  }
  final offsets = contentSplitOffsets;
  final reasoningCounts = reasoningCountAtSplit;
  final toolCounts = toolCountAtSplit;
  if (offsets == null ||
      reasoningCounts == null ||
      toolCounts == null ||
      !contentSplitsMatchTimeline(
        offsets: offsets,
        reasoningCounts: reasoningCounts,
        toolCounts: toolCounts,
        contentLength: visualContent.length,
        stepReasoningCounts: [
          for (final step in mixed) step.reasoningCountAfter,
        ],
        stepToolCounts: [for (final step in mixed) step.toolCountAfter],
      )) {
    return mergeLiveToolsIntoProjection(
      TimelineProjection(
        fromParts: false,
        partsArrivalOrdered: partsArrivalOrdered,
        blocks: <TimelineProjectedBlock>[
          TimelineProjectedBlock.thinking(mixed),
          if (visualContent.trim().isNotEmpty)
            TimelineProjectedBlock.text(visualContent),
        ],
      ),
      liveTools,
    );
  }

  final blocks = <TimelineProjectedBlock>[];
  var stepIndex = 0;
  var textStart = 0;
  for (var i = 0; i < offsets.length; i++) {
    final safeOffset = offsets[i].clamp(0, visualContent.length);
    final textSlice = visualContent.substring(textStart, safeOffset);
    if (textSlice.trim().isNotEmpty) {
      blocks.add(TimelineProjectedBlock.text(textSlice.trim()));
    }
    final targetReasoning = reasoningCounts[i];
    final targetTool = toolCounts[i];
    final blockSteps = <TimelineProjectedStep>[];
    while (stepIndex < mixed.length) {
      final step = mixed[stepIndex];
      blockSteps.add(step);
      stepIndex++;
      if (step.reasoningCountAfter == targetReasoning &&
          step.toolCountAfter == targetTool) {
        break;
      }
    }
    if (blockSteps.isNotEmpty) {
      blocks.add(TimelineProjectedBlock.thinking(blockSteps));
    }
    textStart = safeOffset;
  }
  final trailing = visualContent.substring(textStart);
  if (trailing.trim().isNotEmpty) {
    blocks.add(TimelineProjectedBlock.text(trailing.trim()));
  }
  return mergeLiveToolsIntoProjection(
    TimelineProjection(
      fromParts: false,
      partsArrivalOrdered: partsArrivalOrdered,
      blocks: blocks,
    ),
    liveTools,
  );
}

/// 在所有思考区块之间一次性分配实时工具。
///
/// 优先按 [TimelineToolRef.providerId] 匹配。其余空 id 的实时
/// 工具（除 [kBuiltinSearchToolName] 外）按遭遇顺序分配给
/// 空 id 的投影步骤。绝不合成字符串 id。
TimelineProjection mergeLiveToolsIntoProjection(
  TimelineProjection projection,
  List<TimelineToolRef> liveTools,
) {
  final liveById = <String, TimelineToolRef>{};
  final emptyIdLive = <TimelineToolRef>[];
  for (final tool in liveTools) {
    if (tool.toolName == kBuiltinSearchToolName) continue;
    final trimmed = tool.providerId.trim();
    if (trimmed.isNotEmpty) {
      liveById[trimmed] = tool;
    } else {
      emptyIdLive.add(tool);
    }
  }
  var emptyIndex = 0;
  TimelineToolRef resolve(TimelineToolRef projected) {
    final trimmed = projected.providerId.trim();
    if (trimmed.isNotEmpty) {
      final live = liveById[trimmed];
      if (live != null) {
        return live.copyWith(fallbackOrdinal: projected.fallbackOrdinal);
      }
      return projected;
    }
    if (emptyIndex >= emptyIdLive.length) return projected;
    final live = emptyIdLive[emptyIndex++];
    return live.copyWith(fallbackOrdinal: projected.fallbackOrdinal);
  }

  return TimelineProjection(
    fromParts: projection.fromParts,
    partsArrivalOrdered: projection.partsArrivalOrdered,
    blocks: [
      for (final block in projection.blocks)
        if (block.isThinking)
          TimelineProjectedBlock.thinking([
            for (final step in block.steps)
              if (step.isTool)
                TimelineProjectedStep.tool(
                  sourceOrdinal: step.sourceOrdinal,
                  tool: resolve(step.tool!),
                  reasoningCountAfter: step.reasoningCountAfter,
                  toolCountAfter: step.toolCountAfter,
                )
              else
                step,
          ])
        else
          block,
    ],
  );
}

bool _shouldProjectFromParts({
  required List<MessagePart> parts,
  required String visualContent,
  required List<TimelineToolRef> liveTools,
  required List<TimelineReasoningRef> reasoningSegments,
  required List<int>? contentSplitOffsets,
  required List<int>? reasoningCountAtSplit,
  required List<int>? toolCountAtSplit,
  required bool usableSplits,
  required bool partsArrivalOrdered,
}) {
  if (partsArrivalOrdered &&
      (renderAssistantFromParts(parts: parts, hasContentSplits: false) ||
          parts.any(
            (part) => part is ImagePart && timelineImagePartFlushesBlock(part),
          ))) {
    return true;
  }
  if (renderAssistantFromParts(parts: parts, hasContentSplits: usableSplits)) {
    return true;
  }
  // 与旧渲染器相同的结构化信号：应予内联的推理、工具或图片。
  // 切分存在但与实时时间线不匹配时，
  // [ImagePart] 不得被丢弃。
  if (!renderAssistantFromParts(parts: parts, hasContentSplits: false)) {
    return false;
  }
  if (!usableSplits ||
      contentSplitOffsets == null ||
      reasoningCountAtSplit == null ||
      toolCountAtSplit == null) {
    return false;
  }
  final mixed = _interleaveReasoningAndTools(
    liveTools: [
      for (final tool in liveTools)
        if (toolCreatesTimelineCard(tool.toolName)) tool,
    ],
    reasoningSegments: reasoningSegments,
  );
  return !contentSplitsMatchTimeline(
    offsets: contentSplitOffsets,
    reasoningCounts: reasoningCountAtSplit,
    toolCounts: toolCountAtSplit,
    contentLength: visualContent.length,
    stepReasoningCounts: [for (final step in mixed) step.reasoningCountAfter],
    stepToolCounts: [for (final step in mixed) step.toolCountAfter],
  );
}

List<TimelineProjectedBlock> _projectFromParts({
  required List<MessagePart> parts,
  required List<TimelineReasoningRef> reasoningSegments,
  String Function(String text)? transformText,
  bool inlineThinking = false,
  bool inlineThinkingExpanded = true,
}) {
  final blocks = <TimelineProjectedBlock>[];
  var pending = <TimelineProjectedStep>[];
  var reasoningCount = 0;
  var toolCount = 0;
  var reasoningIndex = 0;
  var sourceOrdinal = 0;
  var imageOrdinal = 0;

  void flushSteps() {
    if (pending.isEmpty) return;
    blocks.add(TimelineProjectedBlock.thinking(List.of(pending)));
    pending = <TimelineProjectedStep>[];
  }

  for (final part in parts) {
    switch (part) {
      case TextPart(:final text):
        final visual = transformText?.call(text) ?? text;
        if (visual.trim().isEmpty) continue;
        flushSteps();
        blocks.add(TimelineProjectedBlock.text(visual));
      case ImagePart(:final uri):
        if (!timelineImagePartFlushesBlock(part)) continue;
        flushSteps();
        final imageKey = timelineImageBlockKey(
          imageId: part.id,
          assetId: part.assetId,
          sourceOrdinal: imageOrdinal++,
        );
        blocks.add(
          TimelineProjectedBlock.image(
            uri,
            imageKey: imageKey,
            aspectRatio: timelineImageAspects[imageKey],
          ),
        );
      case ReasoningPart(:final text):
        if (text.isEmpty) continue;
        final overlayIndex = inlineThinking ? 0 : reasoningIndex;
        final provided = overlayIndex < reasoningSegments.length
            ? reasoningSegments[overlayIndex]
            : null;
        reasoningIndex++;
        pending.add(
          TimelineProjectedStep.reasoning(
            sourceOrdinal: sourceOrdinal++,
            reasoning: TimelineReasoningRef(
              text: text,
              expanded:
                  provided?.expanded ??
                  (inlineThinking ? inlineThinkingExpanded : false),
              loading: provided?.loading ?? false,
              startAt: provided?.startAt,
              finishedAt: provided?.finishedAt,
              toolStartIndex: provided?.toolStartIndex ?? toolCount,
            ),
            reasoningCountAfter: ++reasoningCount,
            toolCountAfter: toolCount,
            reasoningOverlayIndex: provided == null ? null : overlayIndex,
          ),
        );
      case ToolCallPart(:final payloadJson):
        final parsed = parseTimelineToolPayload(
          payloadJson,
          fallbackOrdinal: toolCount,
        );
        if (parsed == null || parsed.toolName == kBuiltinSearchToolName) {
          continue;
        }
        pending.add(
          TimelineProjectedStep.tool(
            sourceOrdinal: sourceOrdinal++,
            tool: parsed,
            reasoningCountAfter: reasoningCount,
            toolCountAfter: ++toolCount,
          ),
        );
      default:
        break;
    }
  }
  flushSteps();
  return blocks;
}

List<TimelineProjectedStep> _interleaveReasoningAndTools({
  required List<TimelineToolRef> liveTools,
  required List<TimelineReasoningRef> reasoningSegments,
}) {
  var sourceOrdinal = 0;
  var assignedFallback = 0;
  TimelineToolRef withFallback(TimelineToolRef tool) {
    if (tool.providerId.trim().isNotEmpty) return tool;
    return tool.copyWith(fallbackOrdinal: assignedFallback++);
  }

  if (reasoningSegments.isEmpty) {
    var toolCount = 0;
    return [
      for (final tool in liveTools)
        TimelineProjectedStep.tool(
          sourceOrdinal: sourceOrdinal++,
          tool: withFallback(tool),
          reasoningCountAfter: 0,
          toolCountAfter: ++toolCount,
        ),
    ];
  }

  final steps = <TimelineProjectedStep>[];
  var reasoningCount = 0;
  var toolCount = 0;
  var toolIndex = 0;

  for (var i = 0; i < reasoningSegments.length; i++) {
    final segment = reasoningSegments[i];
    final segmentToolStart = segment.toolStartIndex.clamp(0, liveTools.length);
    while (toolIndex < segmentToolStart && toolIndex < liveTools.length) {
      steps.add(
        TimelineProjectedStep.tool(
          sourceOrdinal: sourceOrdinal++,
          tool: withFallback(liveTools[toolIndex]),
          reasoningCountAfter: reasoningCount,
          toolCountAfter: ++toolCount,
        ),
      );
      toolIndex++;
    }
    if (segment.text.isNotEmpty) {
      steps.add(
        TimelineProjectedStep.reasoning(
          sourceOrdinal: sourceOrdinal++,
          reasoning: segment,
          reasoningCountAfter: ++reasoningCount,
          toolCountAfter: toolCount,
          reasoningOverlayIndex: i,
        ),
      );
    }
    final nextToolBoundary = i < reasoningSegments.length - 1
        ? reasoningSegments[i + 1].toolStartIndex.clamp(0, liveTools.length)
        : liveTools.length;
    while (toolIndex < nextToolBoundary && toolIndex < liveTools.length) {
      steps.add(
        TimelineProjectedStep.tool(
          sourceOrdinal: sourceOrdinal++,
          tool: withFallback(liveTools[toolIndex]),
          reasoningCountAfter: reasoningCount,
          toolCountAfter: ++toolCount,
        ),
      );
      toolIndex++;
    }
  }
  while (toolIndex < liveTools.length) {
    steps.add(
      TimelineProjectedStep.tool(
        sourceOrdinal: sourceOrdinal++,
        tool: withFallback(liveTools[toolIndex]),
        reasoningCountAfter: reasoningCount,
        toolCountAfter: ++toolCount,
      ),
    );
    toolIndex++;
  }
  return steps;
}

List<TimelineProjectedStep> _filteredThinkingSteps(
  TimelineProjectedBlock block, {
  required bool showThinkingCards,
  required bool showToolCards,
  required bool Function(TimelineToolRef tool) isPendingApproval,
}) {
  if (!block.isThinking) return const [];
  return [
    for (final step in block.steps)
      if (step.isReasoning
          ? showThinkingCards
          : isTimelineToolVisible(
              toolName: step.tool!.toolName,
              loading: step.tool!.loading,
              showToolCards: showToolCards,
              pendingApproval: isPendingApproval(step.tool!),
            ))
        step,
  ];
}

VisibleTimelineBlock? _visibleThinkingFromProjected(
  TimelineProjectedBlock block, {
  required bool showThinkingCards,
  required bool showToolCards,
  required bool collapseThinkingSteps,
  required bool Function(TimelineToolRef tool) isPendingApproval,
}) {
  final filtered = _filteredThinkingSteps(
    block,
    showThinkingCards: showThinkingCards,
    showToolCards: showToolCards,
    isPendingApproval: isPendingApproval,
  );
  if (filtered.isEmpty) return null;
  final collapsed = collapseTimelineSteps(
    filtered,
    collapseThinkingSteps: collapseThinkingSteps,
  );
  return VisibleTimelineBlock(
    visibleSteps: collapsed.visibleSteps,
    hiddenCount: collapsed.hiddenCount,
  );
}

/// 可见性过滤 ＋ 逐块折叠。展开行由 [VisibleTimelineBlock.hasExpandRow] 表示。
List<VisibleTimelineBlock> collapseProjectedTimeline(
  List<TimelineProjectedBlock> blocks, {
  required bool showThinkingCards,
  required bool showToolCards,
  required bool collapseThinkingSteps,
  required bool Function(TimelineToolRef tool) isPendingApproval,
}) {
  return [
    for (final block in blocks)
      if (_visibleThinkingFromProjected(
            block,
            showThinkingCards: showThinkingCards,
            showToolCards: showToolCards,
            collapseThinkingSteps: collapseThinkingSteps,
            isPendingApproval: isPendingApproval,
          )
          case final visible?)
        visible,
  ];
}

/// 经设置与审批过滤后的最终可见助手区块。
///
/// 渲染器与估算器都遍历此列表，并施加相同的 8px 间距。
List<TimelineVisibleBlock> visibleAssistantTimeline(
  TimelineProjection projection, {
  required bool showThinkingCards,
  required bool showToolCards,
  required bool Function(TimelineToolRef tool) isPendingApproval,
}) {
  final visible = <TimelineVisibleBlock>[];
  for (final block in projection.blocks) {
    if (block.isText && (block.text?.trim().isNotEmpty ?? false)) {
      visible.add(TimelineVisibleBlock.text(block.text!));
      continue;
    }
    if (block.isImage && (block.imageUri?.trim().isNotEmpty ?? false)) {
      visible.add(
        TimelineVisibleBlock.image(
          block.imageUri!,
          imageKey: block.imageKey,
          aspectRatio:
              block.aspectRatio ?? timelineImageAspects[block.imageKey],
        ),
      );
      continue;
    }
    final thinking = _filteredThinkingSteps(
      block,
      showThinkingCards: showThinkingCards,
      showToolCards: showToolCards,
      isPendingApproval: isPendingApproval,
    );
    if (thinking.isNotEmpty) {
      visible.add(TimelineVisibleBlock.thinking(thinking));
    }
  }
  return visible;
}

int visibleTimelineStepCount(List<VisibleTimelineBlock> blocks) {
  var count = 0;
  for (final block in blocks) {
    count += block.visibleSteps.length;
  }
  return count;
}
