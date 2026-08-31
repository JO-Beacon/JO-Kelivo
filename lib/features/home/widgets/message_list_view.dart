import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/assistant.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../chat/widgets/chat_message_widget.dart';
import '../../chat/widgets/timeline_visibility.dart';
import '../../chat/utils/thinking_tag_parser.dart';
import '../../chat/widgets/message_more_sheet.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import '../controllers/streaming_content_notifier.dart';
import '../controllers/message_render_model.dart';
import '../controllers/scroll_controller.dart' as scroll_ctrl;
import '../services/ask_user_interaction_service.dart';
import '../services/local_tools_service.dart';
import '../services/tool_approval_service.dart';
import '../utils/chat_layout_constants.dart';
import 'model_icon.dart';

/// 消息列表视图动作的回调类型
typedef OnVersionChange = Future<void> Function(String groupId, int version);
typedef OnRegenerateMessage = void Function(ChatMessage message);
typedef OnResendMessage = void Function(ChatMessage message);
typedef OnTranslateMessage = void Function(ChatMessage message);
typedef OnEditMessage = void Function(ChatMessage message);
typedef OnSwitchMessageRole =
    Future<void> Function(ChatMessage message, String role);
typedef OnDeleteMessage =
    Future<void> Function(
      ChatMessage message,
      Map<String, List<ChatMessage>> byGroup,
    );
typedef OnDeleteAllVersions =
    Future<void> Function(
      ChatMessage message,
      Map<String, List<ChatMessage>> byGroup,
    );
typedef OnMessageFork = Future<void> Function(ChatMessage message);
typedef OnConversationFork =
    Future<void> Function(ChatMessage message, ConversationForkMode mode);
typedef OnShareMessage =
    void Function(int messageIndex, List<ChatMessage> messages);
typedef OnSelectMessages =
    void Function(int messageIndex, List<ChatMessage> messages);
typedef OnSpeakMessage = Future<void> Function(ChatMessage message);
typedef OnSuggestionTap = void Function(String suggestion);
typedef OnRecoveredAskUserAnswer =
    Future<void> Function(
      ChatMessage message,
      ToolUIPart part,
      AskUserResult result,
    );

/// 推理 UI 状态的数据类
class ReasoningUiState {
  final String? text;
  final bool expanded;
  final bool loading;
  final DateTime? startAt;
  final DateTime? finishedAt;
  final VoidCallback? onToggle;

  const ReasoningUiState({
    this.text,
    this.expanded = false,
    this.loading = false,
    this.startAt,
    this.finishedAt,
    this.onToggle,
  });
}

/// 翻译 UI 状态的数据类
class TranslationUiState {
  final bool expanded;
  final VoidCallback? onToggle;

  const TranslationUiState({this.expanded = true, this.onToggle});
}

/// 显示聊天消息列表的 widget。
///
/// 接受来自控制器的预折叠消息和预计算 byGroup，
/// 避免每次构建重复计算。使用可变范围懒加载列表，使大型历史记录
/// 无需布局每条前置消息即可滚动并按索引导航。
class MessageListView extends StatefulWidget {
  const MessageListView({
    super.key,
    required this.scrollController,
    required this.listController,
    required this.messages,
    this.renderModels,
    required this.byGroup,
    required this.versionSelections,
    this.truncCollapsedIndex = -1,
    required this.reasoning,
    required this.reasoningSegments,
    required this.contentSplits,
    required this.toolParts,
    required this.translations,
    required this.selecting,
    required this.selectedItems,
    required this.dividerPadding,
    this.topContentPadding = 8,
    this.bottomContentPadding = 16,
    this.maxContentWidth = ChatLayoutConstants.maxContentWidth,
    this.pinnedStreamingMessageId,
    this.isPinnedIndicatorActive = false,
    required this.isProcessingFiles,
    this.processingFilesMessageId,
    this.streamingContentNotifier,
    this.spotlightMessageId,
    this.spotlightToken = 0,
    this.removingSlotIds = const <String>{},
    this.siblingBranchIdsByMessageId = const <String, List<String>>{},
    this.activeBranchId,
    this.onBranchChange,
    this.onVersionChange,
    this.onRegenerateMessage,
    this.onResendMessage,
    this.onTranslateMessage,
    this.onEditMessage,
    this.onSwitchMessageRole,
    this.onDeleteMessageOnly,
    this.onDeleteMessageAndFollowing,
    this.onDeleteMessageNode,
    this.onDeleteCurrentBranch,
    this.onDeleteAllVersions,
    this.onMessageFork,
    this.onConversationFork,
    this.onShareMessage,
    this.onSelectMessages,
    this.onSpeakMessage,
    this.suggestions = const <String>[],
    this.onSuggestionTap,
    this.onRecoveredAskUserAnswer,
    this.onToggleSelection,
    this.onToggleReasoning,
    this.onToggleTranslation,
    this.onToggleReasoningSegment,
    this.buildPinnedStreamingIndicator,
    this.hasMoreBefore = false,
    this.isLoadingWindow = false,
    this.onLoadMoreBefore,
    this.hasMoreAfter = false,
    this.onLoadMoreAfter,
    this.onUserScrollIntent,
    this.chatFontScale = 1,
    this.collapseThinking = true,
    this.collapseThinkingSteps = false,
    this.showThinkingCards = true,
    this.showToolCards = true,
    this.showToolResultSummary = false,
    this.hideToolResultImages = false,
    this.collapsedCodeLines,
    this.wrapCodeBlocks = false,
    this.showModelIcon = true,
    this.showUserAvatar = true,
    this.showTokenStats = false,
    this.assistant,
  });

  final ScrollController scrollController;
  final ListController listController;

  /// 预折叠消息（来自 ChatController.collapsedMessages）。
  final List<ChatMessage> messages;

  /// 为每个插槽预计算的渲染输入，必须与 [messages] 顺序一致。
  final List<MessageRenderModel>? renderModels;

  /// 按 groupId 分组的所有消息（来自 ChatController.groupedMessages）。
  final Map<String, List<ChatMessage>> byGroup;

  /// 每个消息分组选中的版本（用于版本导航控件）。
  final Map<String, int> versionSelections;

  /// 折叠消息空间中预计算的截断索引（-1 表示无截断）。
  final int truncCollapsedIndex;

  final Map<String, stream_ctrl.ReasoningData> reasoning;
  final Map<String, List<stream_ctrl.ReasoningSegmentData>> reasoningSegments;
  final Map<String, stream_ctrl.ContentSplitData> contentSplits;
  final Map<String, List<ToolUIPart>> toolParts;
  final Map<String, TranslationUiState> translations;
  final bool selecting;
  final Set<String> selectedItems;
  final EdgeInsetsGeometry dividerPadding;
  final double topContentPadding;
  final double bottomContentPadding;
  final double? maxContentWidth;
  final String? pinnedStreamingMessageId;
  final bool isPinnedIndicatorActive;
  final ValueNotifier<bool> isProcessingFiles;

  /// Assistant message currently parsing attachments, or null. When omitted,
  /// [isProcessingFiles] remains available for legacy test callers.
  final ValueNotifier<String?>? processingFilesMessageId;

  /// 用于流式内容更新的轻量 notifier。
  /// 提供后，流式消息会使用 ValueListenableBuilder，避免整页重建。
  final StreamingContentNotifier? streamingContentNotifier;

  /// 设置后，此 ID 对应的消息会收到聚焦脉冲动画。
  final String? spotlightMessageId;

  /// 每次触发新的聚焦时递增。用作动画键，使重新选择同一条消息时重新触发脉冲。
  final int spotlightToken;

  /// 当前在删除前淡出的插槽。插槽数据会保留在 [messages] 中，
  /// 直到移除动画完成。
  final Set<String> removingSlotIds;

  /// 将分叉边界上的消息映射到共享其前缀的分支 ID。
  /// 存在时，旧版本选择器由兄弟分支而非消息版本驱动。
  final Map<String, List<String>> siblingBranchIdsByMessageId;

  final String? activeBranchId;

  final ValueChanged<String>? onBranchChange;

  // 回调
  final OnVersionChange? onVersionChange;
  final OnRegenerateMessage? onRegenerateMessage;
  final OnResendMessage? onResendMessage;
  final OnTranslateMessage? onTranslateMessage;
  final OnEditMessage? onEditMessage;
  final OnSwitchMessageRole? onSwitchMessageRole;
  final OnDeleteMessage? onDeleteMessageOnly;
  final OnDeleteMessage? onDeleteMessageAndFollowing;
  final OnDeleteMessage? onDeleteMessageNode;
  final OnDeleteMessage? onDeleteCurrentBranch;
  final OnDeleteAllVersions? onDeleteAllVersions;
  final OnMessageFork? onMessageFork;
  final OnConversationFork? onConversationFork;
  final OnShareMessage? onShareMessage;
  final OnSelectMessages? onSelectMessages;
  final OnSpeakMessage? onSpeakMessage;
  final List<String> suggestions;
  final OnSuggestionTap? onSuggestionTap;
  final OnRecoveredAskUserAnswer? onRecoveredAskUserAnswer;
  final void Function(String messageId, bool selected)? onToggleSelection;
  final void Function(String messageId)? onToggleReasoning;
  final void Function(String messageId)? onToggleTranslation;
  final void Function(String messageId, int segmentIndex)?
  onToggleReasoningSegment;
  final Widget Function()? buildPinnedStreamingIndicator;
  final bool hasMoreBefore;

  /// 仅在冷启动初始窗口加载期间为 true；快速路径缓存命中会在一帧批次内完成，
  /// 不会显示骨架。
  final bool isLoadingWindow;
  final Future<bool> Function()? onLoadMoreBefore;
  final bool hasMoreAfter;
  final Future<bool> Function()? onLoadMoreAfter;
  final VoidCallback? onUserScrollIntent;
  final double chatFontScale;

  /// 已完成的思考块是否折叠显示（显示设置）。
  final bool collapseThinking;
  final bool collapseThinkingSteps;
  final bool showThinkingCards;
  final bool showToolCards;
  final bool showToolResultSummary;
  final bool hideToolResultImages;

  /// 长代码块折叠到的行数；为 null 时保持展开。
  final int? collapsedCodeLines;

  /// 代码块是否换行（桌面端或移动端换行设置），而不是水平滚动。
  final bool wrapCodeBlocks;

  final bool showModelIcon;
  final bool showUserAvatar;
  final bool showTokenStats;
  final Assistant? assistant;

  @visibleForTesting
  static const Key windowSkeletonKey = ValueKey<String>(
    'timeline-window-skeleton',
  );

  @override
  State<MessageListView> createState() => _MessageListViewState();
}

class _MessageListViewState extends State<MessageListView> {
  static const double _streamingUpdateDeferBottomTolerance = 56.0;

  bool _historyLoadScheduled = false;
  bool _pointerDragInProgress = false;
  bool _userScrollActive = false;
  ScrollMetrics? _latestPointerDragMetrics;
  final ValueNotifier<bool> _deferStreamingMessageUpdates = ValueNotifier<bool>(
    false,
  );
  DateTime? _lastHistoryLoadAt;
  Timer? _scrollIdleTimer;
  bool _pointerScrollActivityCheckScheduled = false;
  late List<MessageRenderModel> _effectiveRenderModels;
  late Map<String, int> _slotIndexById;
  late Map<String, int> _messageIndexById;
  final Map<String, int> _lastToolSignatures = <String, int>{};
  final Set<String> _pendingToolExtentIds = <String>{};
  var _toolExtentFlushScheduled = false;
  final FocusNode _keyboardFocusNode = FocusNode(
    debugLabel: 'timeline-keyboard-scroll-region',
  );

  String _slotId(ChatMessage message) => message.groupId ?? message.id;

  @override
  void initState() {
    super.initState();
    _refreshRenderModels();
    _snapshotToolSignatures();
    widget.streamingContentNotifier?.toolHeightEvents.addListener(
      _handleToolHeightEvent,
    );
  }

  @override
  void didUpdateWidget(covariant MessageListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamingContentNotifier != widget.streamingContentNotifier) {
      oldWidget.streamingContentNotifier?.toolHeightEvents.removeListener(
        _handleToolHeightEvent,
      );
      widget.streamingContentNotifier?.toolHeightEvents.addListener(
        _handleToolHeightEvent,
      );
    }
    final oldRenderModels = _effectiveRenderModels;
    _refreshRenderModels();
    _synchronizeExtentCache(oldWidget, oldRenderModels);
    _snapshotToolSignatures();
  }

  void _refreshRenderModels() {
    _effectiveRenderModels =
        widget.renderModels ??
        MessageRenderModelProjector.project(
          messages: widget.messages,
          byGroup: widget.byGroup,
          versionSelections: widget.versionSelections,
          contextDividerIndex: widget.truncCollapsedIndex,
        );
    _slotIndexById = <String, int>{
      for (var index = 0; index < _effectiveRenderModels.length; index++)
        _effectiveRenderModels[index].slotId: index,
    };
    _messageIndexById = <String, int>{
      for (var index = 0; index < _effectiveRenderModels.length; index++)
        _effectiveRenderModels[index].message.id: index,
    };
  }

  void _snapshotToolSignatures() {
    _lastToolSignatures
      ..clear()
      ..addAll({
        for (final model in _effectiveRenderModels)
          model.message.id: _toolEstimateSignature(
            widget.toolParts[model.message.id],
          ),
      });
  }

  void _handleToolHeightEvent() {
    final event = widget.streamingContentNotifier?.toolHeightEvents.value;
    if (event == null) return;
    _invalidateToolExtentForMessage(event.messageId);
  }

  void _invalidateToolExtentForMessage(String messageId) {
    _extentEstimateCache.remove(messageId);
    final controller = widget.listController;
    if (!controller.isAttached) return;
    if (controller.isLocked) {
      _pendingToolExtentIds.add(messageId);
      if (_toolExtentFlushScheduled) return;
      _toolExtentFlushScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _toolExtentFlushScheduled = false;
        if (!mounted) return;
        final ids = List<String>.of(_pendingToolExtentIds);
        _pendingToolExtentIds.clear();
        for (final id in ids) {
          _applyToolExtentInvalidation(id);
        }
      });
      return;
    }
    _applyToolExtentInvalidation(messageId);
  }

  void _applyToolExtentInvalidation(String messageId) {
    final controller = widget.listController;
    if (!controller.isAttached || controller.isLocked) return;
    final index = _messageIndexById[messageId];
    if (index == null) return;
    final visible = controller.visibleRange;
    final scrollController = widget.scrollController;
    if (visible != null &&
        index < visible.$1 &&
        scrollController is scroll_ctrl.ChatAutoFollowScrollController) {
      final request = scrollController
          .requestPreserveDistanceFromEndDuringLayout();
      if (request != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          scrollController.finishPreserveDistanceFromEndDuringLayout(request);
        });
      }
    }
    controller.invalidateExtent(index);
  }

  /// 消息气泡周围的标题行、操作栏和垂直边距。
  static const double _estimateChrome = 96.0;

  /// 折叠行内思考卡片的高度。
  static const double _estimateCollapsedCard = 44.0;

  /// 折叠时间线显示的展开行高度。
  static const double _estimateExpandRow = 36.0;

  /// 在按观察密度外推前扫描的字符数。
  static const int _estimateScanLimit = 8000;

  /// 围栏代码在缩放前渲染的字体大小。
  static const double _estimateCodeFontSize = 13.0;

  /// 思考解析器会处理的最长消息长度。
  static const int _estimateParseLimit = 64000;

  /// 在整体丢弃 memo 前保留的缓存估算值。
  static const int _extentEstimateCacheLimit = 512;

  final Map<String, _ExtentEstimate> _extentEstimateCache = {};

  /// 系统无障碍文本缩放，会乘以聊天字体缩放。
  double _systemTextScale = 1.0;

  /// 估算所依赖的显示设置，在 [build] 中刷新。
  _EstimateSettings _estimateSettings = const _EstimateSettings(
    collapseThinking: true,
    collapseThinkingSteps: false,
    showThinkingCards: true,
    showToolCards: true,
    showToolResultSummary: false,
    hideToolResultImages: false,
    collapsedCodeLines: null,
    wrapCodeBlocks: false,
    pendingApprovalIds: <String>{},
  );

  /// 当前已存储范围估算时的字体缩放。
  double? _estimatedFontScale;

  /// 系统文本缩放变化后丢弃已存储范围。
  ///
  /// 只有 widget 驱动输入会经过 [_synchronizeExtentCache]；系统无障碍变化
  /// 通过 MediaQuery 到达，不会改变条目数量，因此 SuperSliverList 否则会
  /// 继续保留旧缩放下为屏幕外项目生成的估算值，直到每个项目滚入视野。
  void _invalidateEstimatesIfScaleChanged() {
    final scale = widget.chatFontScale * _systemTextScale;
    if (_estimatedFontScale == scale) return;
    final hadEstimates = _estimatedFontScale != null;
    _estimatedFontScale = scale;
    if (!hadEstimates) return;
    final controller = widget.listController;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.isAttached || controller.isLocked) return;
      controller.invalidateAllExtents();
    });
  }

  /// 消息气泡的大致高度，用于从未实际布局的项目。
  ///
  /// SuperSliverList 默认估算值固定为 100px。长聊天中真实气泡比这高一到两个
  /// 数量级，因此每次布局用实测替换估算时，总范围以及底部固定的滚动偏移
  /// 都会移动数万像素。如果这发生在两帧之间，时间线会明显从底部闪开再回来。
  /// 基于内容派生的估算可让这些修正变小；它不需要精确，只需数量级正确。
  double _estimateItemExtent(int? index, double crossAxisExtent) {
    // null 索引询问一个范围是否适用于所有项目。返回正数会让 SuperSliverList
    // 对整个列表使用该值，而不会查询下方按项目分支，因此这里必须返回 0。
    if (index == null) return 0;
    final models = _effectiveRenderModels;
    if (index < 0 || index >= models.length) return _estimateChrome;

    final message = models[index].message;
    final text = message.content;
    final settings = _estimateSettings;
    if (message.role == 'tool' &&
        !settings.showToolCards &&
        !_hiddenStandaloneToolMessageRemainsVisible(text)) {
      return 0;
    }
    final reasoning = message.role == 'assistant'
        ? widget.reasoning[message.id]
        : null;
    final reasoningSegments = message.role == 'assistant'
        ? widget.reasoningSegments[message.id]
        : null;
    final hasReasoning =
        (reasoning?.text.isNotEmpty ?? false) ||
        (reasoningSegments?.isNotEmpty ?? false);
    final toolParts = message.role == 'assistant'
        ? widget.toolParts[message.id]
        : null;
    final hasTools = toolParts != null && toolParts.isNotEmpty;
    if (text.isEmpty && !hasReasoning && !hasTools) return _estimateChrome;

    // 布局会反复查询同一个项目（每次调整大小、窗口变化都会），而下方扫描
    // 随消息长度线性增长，因此按结果依赖的全部因素缓存，可保持布局阶段廉价。
    // 内容按对象身份比较：编辑或流式消息总会携带新字符串，等长重写不能命中缓存。
    final fontScale = widget.chatFontScale * _systemTextScale;
    final reasoningSignature = _reasoningEstimateSignature(
      reasoning,
      reasoningSegments,
    );
    final toolSignature = _toolEstimateSignature(toolParts);
    final cached = _extentEstimateCache[message.id];
    if (cached != null &&
        identical(cached.content, text) &&
        cached.crossAxisExtent == crossAxisExtent &&
        cached.fontScale == fontScale &&
        cached.settings == settings &&
        cached.reasoningSignature == reasoningSignature &&
        cached.toolSignature == toolSignature) {
      return cached.extent;
    }

    // 行内思考会作为独立卡片渲染。折叠时只有可见剩余内容占空间，
    // 因此使用渲染器同样的解析器解析，而不是猜测标签语法。
    var body = text;
    var collapsedCards = 0;
    if ((settings.collapseThinking || !settings.showThinkingCards) &&
        message.role != 'user' &&
        text.length <= _estimateParseLimit &&
        text.contains('<')) {
      final parsed = ThinkingTagParser.parseLegacyInlineBlocks(text);
      if (parsed.hasThinking) {
        body = parsed.visibleContent;
        if (settings.showThinkingCards) {
          collapsedCards = parsed.thinkingTexts.length;
        }
      }
    }

    final fontSize = 15.6 * fontScale;
    final lineHeight = fontSize * 1.5;
    // 用户气泡有内缩，永远不会占满全宽。
    final bubbleWidth = crossAxisExtent * (message.role == 'user' ? 0.85 : 1.0);
    final textWidth = math.max(80.0, bubbleWidth - 28);
    // 宽字符（CJK）大约两倍于拉丁字符宽度，因此混排决定每行可容纳多少字符。
    final charWidth = fontSize * (0.5 + 0.55 * _wideCharRatio(body));
    final charsPerLine = math.max(1.0, textWidth / charWidth);
    // 代码使用固定 13px 等宽字体渲染，因此换行列数和行高与正文不同。
    final codeFontSize = _estimateCodeFontSize * fontScale;
    final codeCharsPerLine = math.max(1.0, textWidth / (codeFontSize * 0.6));
    final bodyLines = body.isEmpty
        ? 0.0
        : _wrappedLineCount(
            body,
            charsPerLine: charsPerLine,
            codeCharsPerLine: settings.wrapCodeBlocks ? codeCharsPerLine : null,
            codeLineRatio: codeFontSize / fontSize,
            collapsedCodeLines: settings.collapsedCodeLines,
          );
    final extent =
        bodyLines * lineHeight +
        _estimateChrome +
        collapsedCards * _estimateCollapsedCard +
        (settings.showThinkingCards
            ? _estimateReasoningExtent(
                reasoning,
                reasoningSegments,
                textWidth: textWidth,
                fontScale: fontScale,
              )
            : 0) +
        _estimateToolExtent(
          toolParts,
          messageId: message.id,
          textWidth: textWidth,
          fontScale: fontScale,
        );

    if (_extentEstimateCache.length > _extentEstimateCacheLimit) {
      _extentEstimateCache.clear();
    }
    _extentEstimateCache[message.id] = _ExtentEstimate(
      content: text,
      crossAxisExtent: crossAxisExtent,
      fontScale: fontScale,
      settings: settings,
      reasoningSignature: reasoningSignature,
      toolSignature: toolSignature,
      extent: extent,
    );
    return extent;
  }

  /// 渲染在答案上方的推理卡片估算高度。
  ///
  /// 推理内容不在 [ChatMessage.content] 中，仅按内容估算会完全遗漏它；
  /// 推理较多的消息会被低估一个数量级，跨未测量区域的每次滚动或锚点计算
  /// 也会产生相同偏差。这与渲染器在存在分段时显示分段、否则显示单个推理块的
  /// 选择保持一致。
  double _estimateReasoningExtent(
    stream_ctrl.ReasoningData? reasoning,
    List<stream_ctrl.ReasoningSegmentData>? segments, {
    required double textWidth,
    required double fontScale,
  }) {
    var extent = 0.0;
    void addCard(String reasoningText, bool expanded) {
      if (reasoningText.isEmpty) return;
      extent += _estimateCollapsedCard;
      if (!expanded) return;
      final fontSize = 13.0 * fontScale;
      final charWidth = fontSize * (0.5 + 0.55 * _wideCharRatio(reasoningText));
      final charsPerLine = math.max(1.0, textWidth / charWidth);
      extent +=
          _wrappedLineCount(
            reasoningText,
            charsPerLine: charsPerLine,
            codeCharsPerLine: null,
            codeLineRatio: 1.0,
            collapsedCodeLines: null,
          ) *
          (fontSize * 1.5);
    }

    if (segments != null && segments.isNotEmpty) {
      for (final segment in segments) {
        addCard(segment.text, segment.expanded);
      }
    } else if (reasoning != null) {
      addCard(reasoning.text, reasoning.expanded);
    }
    return extent;
  }

  double _estimateToolExtent(
    List<ToolUIPart>? parts, {
    required String messageId,
    required double textWidth,
    required double fontScale,
  }) {
    if (parts == null || parts.isEmpty) return 0;
    final settings = _estimateSettings;
    final cardTools = [
      for (final part in parts)
        if (toolCreatesTimelineCard(part.toolName)) part,
    ];
    if (cardTools.isEmpty) return 0;
    final splits = widget.contentSplits[messageId];
    final blocks = splitToolsIntoTimelineBlocks(
      cardTools,
      toolCounts: splits?.toolCounts,
    );
    var extent = 0.0;
    for (final block in blocks) {
      final visible = [
        for (final part in block)
          if (isTimelineToolVisible(
            toolName: part.toolName,
            loading: part.loading,
            showToolCards: settings.showToolCards,
            pendingApproval: settings.pendingApprovalIds.contains(part.id),
          ))
            part,
      ];
      if (visible.isEmpty) continue;
      final collapsed = collapseTimelineSteps(
        visible,
        collapseThinkingSteps: settings.collapseThinkingSteps,
      );
      if (collapsed.hasExpandRow) extent += _estimateExpandRow;
      for (final part in collapsed.visibleSteps) {
        extent += _estimateCollapsedCard;
        extent += estimateToolExtraHeight(
          toolName: part.toolName,
          arguments: part.arguments,
          content: part.content,
          showToolResultSummary: settings.showToolResultSummary,
          hideToolResultImages: settings.hideToolResultImages,
          pendingApproval: settings.pendingApprovalIds.contains(part.id),
          textWidth: textWidth,
          fontScale: fontScale,
          wrappedLineCount: _wrappedLineCount,
        );
      }
    }
    return extent;
  }

  int _toolEstimateSignature(List<ToolUIPart>? parts) {
    if (parts == null || parts.isEmpty) return 0;
    return Object.hashAll([for (final part in parts) identityHashCode(part)]);
  }

  /// 估算所依据的推理输入身份。
  ///
  /// 推理状态对象会原地变化，但其文本在每次变化时都会替换为新字符串，
  /// 因此文本身份加上展开标志可以区分估算依赖的每个状态。
  int _reasoningEstimateSignature(
    stream_ctrl.ReasoningData? reasoning,
    List<stream_ctrl.ReasoningSegmentData>? segments,
  ) {
    if (reasoning == null && (segments == null || segments.isEmpty)) return 0;
    return Object.hashAll([
      if (reasoning != null) ...[
        identityHashCode(reasoning.text),
        reasoning.expanded,
      ],
      if (segments != null)
        for (final segment in segments) ...[
          identityHashCode(segment.text),
          segment.expanded,
        ],
    ]);
  }

  /// 按正文行数计算的渲染高度，逐硬换行分别换行。
  ///
  /// 将总长度除以 [charsPerLine] 会合并空行和短行，而这恰好是聊天消息常见形态。
  /// 两种结构否则会计算错误：Markdown 链接隐藏目标，围栏代码块使用自己的字体，
  /// 渲染器换行时按 [codeCharsPerLine] 换行；水平滚动时（[codeCharsPerLine] 为 null）
  /// 每个源码行占一行，每行高度为正文行的 [codeLineRatio]。
  /// 代码块还可能折叠到 [collapsedCodeLines] 个源码行。
  double _wrappedLineCount(
    String text, {
    required double charsPerLine,
    required double? codeCharsPerLine,
    required double codeLineRatio,
    required int? collapsedCodeLines,
  }) {
    var lines = 0.0;
    var visible = 0; // 当前行已渲染的字符数
    var fenceRows = 0.0; // 打开的代码围栏内已渲染的行数
    var fenceSourceLines = 0; // 打开的代码围栏内硬行数
    var inFence = false;
    var index = 0;

    void endLine() {
      if (inFence) {
        fenceSourceLines++;
        fenceRows += visible == 0 || codeCharsPerLine == null
            ? 1.0 // 每个源码行一行：代码横向滚动
            : (visible / codeCharsPerLine).ceilToDouble();
      } else {
        lines += visible == 0 ? 1.0 : (visible / charsPerLine).ceilToDouble();
      }
      visible = 0;
    }

    void endFence() {
      // 折叠会隐藏源码行，因此换行后的行数也随之减少。
      final shown = collapsedCodeLines == null || fenceSourceLines == 0
          ? fenceRows
          : fenceRows * math.min(1.0, collapsedCodeLines / fenceSourceLines);
      lines += shown * codeLineRatio;
      fenceRows = 0;
      fenceSourceLines = 0;
    }

    // 非常长的消息只需数量级正确，因此扫描按字符预算；单行兆字节 JSON
    // 不能遍历整串，尾部按观察密度外推。
    while (index < text.length && index < _estimateScanLimit) {
      final unit = text.codeUnitAt(index);
      if (unit == 0x0A) {
        endLine();
        index++;
        continue;
      }
      if (unit == 0x60 && _isFenceMarker(text, index)) {
        if (inFence) {
          endLine();
          endFence();
          inFence = false;
        } else {
          endLine();
          inFence = true;
        }
        index += 3;
        continue;
      }
      if (unit == 0x5D && index + 1 < text.length) {
        // Markdown 链接只渲染标签，从不渲染目标。
        if (text.codeUnitAt(index + 1) == 0x28) {
          final close = text.indexOf(')', index + 2);
          if (close > 0) {
            visible++;
            index = close + 1;
            continue;
          }
        }
      }
      visible++;
      index++;
    }
    endLine();
    if (inFence) endFence();
    if (index >= text.length) return lines;
    return lines * (text.length / math.max(1, index));
  }

  /// 判断 ``` 围栏标记是否从 [index] 开始。
  bool _isFenceMarker(String text, int index) {
    if (index + 2 >= text.length) return false;
    if (text.codeUnitAt(index + 1) != 0x60 ||
        text.codeUnitAt(index + 2) != 0x60) {
      return false;
    }
    return index == 0 || text.codeUnitAt(index - 1) == 0x0A;
  }

  /// 宽字符占比，采样使超大消息的成本保持稳定。
  double _wideCharRatio(String text) {
    const samples = 256;
    final step = math.max(1, text.length ~/ samples);
    var wide = 0;
    var seen = 0;
    for (var index = 0; index < text.length; index += step) {
      if (text.codeUnitAt(index) >= 0x2E80) wide++;
      seen++;
    }
    return seen == 0 ? 0 : wide / seen;
  }

  int? _findMessageIndexByKey(Key key) {
    if (key is! ValueKey<String>) return null;
    return _slotIndexById[key.value];
  }

  void _synchronizeExtentCache(
    MessageListView oldWidget,
    List<MessageRenderModel> oldModels,
  ) {
    final controller = widget.listController;
    if (!identical(controller, oldWidget.listController) ||
        !controller.isAttached) {
      return;
    }
    if (controller.isLocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && controller.isAttached && !controller.isLocked) {
          controller.invalidateAllExtents();
        }
      });
      return;
    }

    final newModels = _effectiveRenderModels;
    final metricInputsChanged =
        oldWidget.chatFontScale != widget.chatFontScale ||
        oldWidget.selecting != widget.selecting ||
        oldWidget.showModelIcon != widget.showModelIcon ||
        oldWidget.showUserAvatar != widget.showUserAvatar ||
        oldWidget.showTokenStats != widget.showTokenStats ||
        oldWidget.collapseThinking != widget.collapseThinking ||
        oldWidget.collapseThinkingSteps != widget.collapseThinkingSteps ||
        oldWidget.showThinkingCards != widget.showThinkingCards ||
        oldWidget.showToolCards != widget.showToolCards ||
        oldWidget.showToolResultSummary != widget.showToolResultSummary ||
        oldWidget.hideToolResultImages != widget.hideToolResultImages ||
        oldWidget.collapsedCodeLines != widget.collapsedCodeLines ||
        oldWidget.wrapCodeBlocks != widget.wrapCodeBlocks ||
        !identical(oldWidget.assistant, widget.assistant);
    if (metricInputsChanged) {
      controller.invalidateAllExtents();
      return;
    }

    if (oldModels.length < newModels.length &&
        _isPrefix(oldModels, newModels)) {
      return;
    }
    if (oldModels.length < newModels.length &&
        _isSuffix(oldModels, newModels)) {
      final anchor = _captureVisibleAnchor(controller);
      final added = newModels.length - oldModels.length;
      for (var index = 0; index < added; index++) {
        controller.addItem(index);
      }
      if (anchor != null) {
        _restoreVisibleAnchorAfterLayout(
          controller,
          index: anchor.index + added,
          alignment: anchor.alignment,
        );
      }
      return;
    }
    if (newModels.length < oldModels.length &&
        _isPrefix(newModels, oldModels)) {
      return;
    }
    if (newModels.length < oldModels.length) {
      final removedOldIndices = _removedOldIndices(oldModels, newModels);
      if (removedOldIndices != null) {
        // 删除索引处范围后，每个幸存插槽的实测高度保持关联到新索引；
        // 否则下方回退会丢弃所有测量，让列表在数帧内重新测量整个窗口时漂移。
        final anchor = _captureVisibleAnchorForRemoval(
          controller,
          removedOldIndices,
        );
        for (var index = removedOldIndices.length - 1; index >= 0; index--) {
          controller.removeItem(removedOldIndices[index]);
        }
        if (anchor != null) {
          _restoreVisibleAnchorAfterLayout(
            controller,
            index: anchor.index,
            alignment: anchor.alignment,
          );
        }
        return;
      }
    }

    if (oldModels.length == newModels.length) {
      final added = _leadingShiftForEqualWindow(oldModels, newModels);
      if (added != null) {
        final anchor = _captureVisibleAnchor(controller);
        for (var index = 0; index < added; index++) {
          controller.addItem(index);
        }
        for (var index = 0; index < added; index++) {
          controller.removeItem(newModels.length);
        }
        if (anchor != null && anchor.index + added < newModels.length) {
          _restoreVisibleAnchorAfterLayout(
            controller,
            index: anchor.index + added,
            alignment: anchor.alignment,
          );
        }
        return;
      }

      var slotsMatch = true;
      final changedIndices = <int>[];
      for (var index = 0; index < newModels.length; index++) {
        if (oldModels[index].slotId != newModels[index].slotId) {
          slotsMatch = false;
          break;
        }
        if (_messageExtentMayHaveChanged(
          oldModels[index].message,
          newModels[index].message,
        )) {
          changedIndices.add(index);
        } else {
          final messageId = newModels[index].message.id;
          if (_lastToolSignatures[messageId] !=
              _toolEstimateSignature(widget.toolParts[messageId])) {
            changedIndices.add(index);
          }
        }
      }
      if (slotsMatch) {
        final visible = controller.visibleRange;
        final scrollController = widget.scrollController;
        if (changedIndices.length == 1 &&
            visible != null &&
            changedIndices.single < visible.$1 &&
            scrollController is scroll_ctrl.ChatAutoFollowScrollController) {
          final request = scrollController
              .requestPreserveDistanceFromEndDuringLayout();
          if (request != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              scrollController.finishPreserveDistanceFromEndDuringLayout(
                request,
              );
            });
          }
        }
        for (final index in changedIndices) {
          controller.invalidateExtent(index);
        }
        return;
      }
    }

    controller.invalidateAllExtents();
  }

  /// 本帧是否由布局阶段定位请求（底部固定、保持距离、流式自动跟随）
  /// 拥有滚动位置。锚点恢复必须让步，而不是与其争抢。
  bool get _layoutPositionOwnedElsewhere {
    final scrollController = widget.scrollController;
    return scrollController is scroll_ctrl.ChatAutoFollowScrollController &&
        (scrollController.hasActiveLayoutPositioningRequest ||
            scrollController.shouldAutoFollow());
  }

  ({int index, double alignment})? _captureVisibleAnchor(
    ListController controller,
  ) {
    if (!widget.scrollController.hasClients) return null;
    if (_layoutPositionOwnedElsewhere) return null;
    final visible = controller.visibleRange;
    if (visible == null) return null;
    return _anchorAtIndex(controller, visible.$1);
  }

  /// 捕获删除后仍存在的最上方可见插槽，作为以删除后索引空间表示的锚点。
  ///
  /// 当所有可见插槽都被删除时，锚点落到下方最近的幸存插槽，其内容会上滑
  /// 进入腾出的视口；若没有，则落到上方最近的幸存插槽。
  ({int index, double alignment})? _captureVisibleAnchorForRemoval(
    ListController controller,
    List<int> removedOldIndices,
  ) {
    if (!widget.scrollController.hasClients) return null;
    if (_layoutPositionOwnedElsewhere) return null;
    final visible = controller.visibleRange;
    if (visible == null) return null;
    final removed = removedOldIndices.toSet();
    final itemCount = controller.numberOfItems;
    int? anchorOldIndex;
    for (var index = visible.$1; index < itemCount; index++) {
      if (!removed.contains(index)) {
        anchorOldIndex = index;
        break;
      }
    }
    if (anchorOldIndex == null) {
      for (var index = visible.$1 - 1; index >= 0; index--) {
        if (!removed.contains(index)) {
          anchorOldIndex = index;
          break;
        }
      }
    }
    if (anchorOldIndex == null) return null;
    final anchor = _anchorAtIndex(controller, anchorOldIndex);
    var anchorNewIndex = anchorOldIndex;
    for (final removedIndex in removedOldIndices) {
      if (removedIndex < anchorOldIndex) anchorNewIndex--;
    }
    return (index: anchorNewIndex, alignment: anchor.alignment);
  }

  ({int index, double alignment}) _anchorAtIndex(
    ListController controller,
    int index,
  ) {
    final position = widget.scrollController.position;
    final itemExtent = controller.extentForIndex(index).$1;
    // 滚动位置由子项实际绘制位置定义，而范围列表偏移部分来自从未进入布局的
    // 行的估算高度。混用两种坐标会把累计误差烘焙进对齐，恢复跳转会准确
    // 偏移该误差；对估算密集历史（长推理载荷、超大消息）会表现为视口跳到
    // 随机位置。应锚定实际绘制偏移，仅当子项未构建时回退到估算偏移。
    final itemLeading =
        _paintedLeadingOffset(index) ??
        // 这与 jumpToItem 使用的偏移查询相同。在新子列表进入布局前使用是安全的。
        // ignore: invalid_use_of_visible_for_testing_member
        controller.getOffsetToReveal(index, 0);
    final availableAlignmentExtent = position.viewportDimension - itemExtent;
    final alignment = availableAlignmentExtent.abs() < 0.5
        ? 0.0
        : (itemLeading - position.pixels) / availableAlignmentExtent;
    return (index: index, alignment: alignment);
  }

  /// [index] 对应子项实际布局时的滚动偏移；该子项当前未构建时返回 null。
  double? _paintedLeadingOffset(int index) {
    final root = context.findRenderObject();
    if (root == null) return null;
    RenderSliverMultiBoxAdaptor? sliver;
    void visit(RenderObject node) {
      if (sliver != null) return;
      if (node is RenderSliverMultiBoxAdaptor) {
        sliver = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(root);
    final list = sliver;
    if (list == null || list.geometry == null) return null;
    for (
      var child = list.firstChild;
      child != null;
      child = list.childAfter(child)
    ) {
      final parentData = child.parentData;
      if (parentData is! SliverMultiBoxAdaptorParentData) continue;
      if (parentData.index != index) continue;
      if (parentData.keptAlive) return null;
      final layoutOffset = parentData.layoutOffset;
      if (layoutOffset == null) return null;
      return layoutOffset + list.constraints.precedingScrollExtent;
    }
    return null;
  }

  /// 新列表中缺失的旧列表索引；如果新列表不只是旧列表移除部分插槽，则返回 null。
  List<int>? _removedOldIndices(
    List<MessageRenderModel> oldModels,
    List<MessageRenderModel> newModels,
  ) {
    final removed = <int>[];
    var newIndex = 0;
    for (var oldIndex = 0; oldIndex < oldModels.length; oldIndex++) {
      if (newIndex < newModels.length &&
          oldModels[oldIndex].slotId == newModels[newIndex].slotId) {
        newIndex++;
      } else {
        removed.add(oldIndex);
      }
    }
    if (newIndex != newModels.length || removed.isEmpty) return null;
    return removed;
  }

  void _restoreVisibleAnchorAfterLayout(
    ListController controller, {
    required int index,
    required double alignment,
  }) {
    final scrollController = widget.scrollController;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !controller.isAttached ||
          controller.isLocked ||
          !scrollController.hasClients ||
          index < 0 ||
          index >= _effectiveRenderModels.length) {
        return;
      }
      controller.jumpToItem(
        index: index,
        scrollController: scrollController,
        alignment: alignment,
      );
    });
  }

  bool _messageExtentMayHaveChanged(ChatMessage old, ChatMessage current) {
    return old.id != current.id ||
        old.role != current.role ||
        old.content != current.content ||
        old.reasoningText != current.reasoningText ||
        old.translation != current.translation ||
        old.reasoningSegmentsJson != current.reasoningSegmentsJson ||
        old.modelId != current.modelId ||
        old.providerId != current.providerId ||
        old.totalTokens != current.totalTokens ||
        old.promptTokens != current.promptTokens ||
        old.completionTokens != current.completionTokens ||
        old.cachedTokens != current.cachedTokens ||
        old.durationMs != current.durationMs;
  }

  bool _isPrefix(
    List<MessageRenderModel> prefix,
    List<MessageRenderModel> values,
  ) {
    if (prefix.length > values.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (prefix[index].slotId != values[index].slotId) return false;
    }
    return true;
  }

  bool _isSuffix(
    List<MessageRenderModel> suffix,
    List<MessageRenderModel> values,
  ) {
    if (suffix.length > values.length) return false;
    final offset = values.length - suffix.length;
    for (var index = 0; index < suffix.length; index++) {
      if (suffix[index].slotId != values[offset + index].slotId) return false;
    }
    return true;
  }

  int? _leadingShiftForEqualWindow(
    List<MessageRenderModel> oldModels,
    List<MessageRenderModel> newModels,
  ) {
    if (oldModels.isEmpty || oldModels.length != newModels.length) return null;
    final shift = newModels.indexWhere(
      (model) => model.slotId == oldModels.first.slotId,
    );
    if (shift <= 0) return null;
    for (var index = 0; index < oldModels.length - shift; index++) {
      if (oldModels[index].slotId != newModels[index + shift].slotId) {
        return null;
      }
    }
    return shift;
  }

  bool get _isDesktopPlatform =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  ScrollViewKeyboardDismissBehavior get _keyboardDismissBehavior {
    if (_isDesktopPlatform) {
      return ScrollViewKeyboardDismissBehavior.manual;
    }
    return ScrollViewKeyboardDismissBehavior.onDrag;
  }

  @override
  void dispose() {
    widget.streamingContentNotifier?.toolHeightEvents.removeListener(
      _handleToolHeightEvent,
    );
    _scrollIdleTimer?.cancel();
    _deferStreamingMessageUpdates.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  /// 构建显示在截断位置的上下文分隔 widget。
  Widget _buildContextDivider(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final label = l10n.homePageClearContext;
    return Row(
      children: [
        Expanded(
          child: Divider(
            color: cs.outlineVariant.withValues(alpha: 0.6),
            height: 1,
            thickness: 1,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        Expanded(
          child: Divider(
            color: cs.outlineVariant.withValues(alpha: 0.6),
            height: 1,
            thickness: 1,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 项目以系统缩放乘聊天缩放渲染（参见 _buildMessageItem 中的 MediaQuery
    // 覆盖），因此估算必须同时使用两者。
    _systemTextScale = MediaQuery.textScalerOf(context).scale(1);
    _estimateSettings = _EstimateSettings(
      collapseThinking: widget.collapseThinking,
      collapseThinkingSteps: widget.collapseThinkingSteps,
      showThinkingCards: widget.showThinkingCards,
      showToolCards: widget.showToolCards,
      showToolResultSummary: widget.showToolResultSummary,
      hideToolResultImages: widget.hideToolResultImages,
      collapsedCodeLines: widget.collapsedCodeLines,
      wrapCodeBlocks: widget.wrapCodeBlocks,
      pendingApprovalIds: _readPendingApprovalIds(context),
    );
    _invalidateEstimatesIfScaleChanged();
    final presentation = _MessagePresentation(
      chatFontScale: widget.chatFontScale,
      showModelIcon: widget.showModelIcon,
      showUserAvatar: widget.showUserAvatar,
      showTokenStats: widget.showTokenStats,
      assistant: widget.assistant,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPad = widget.maxContentWidth == null
            ? 0.0
            : ((constraints.maxWidth - widget.maxContentWidth!) / 2).clamp(
                0.0,
                double.infinity,
              );

        return ValueListenableBuilder<bool>(
          valueListenable: widget.isProcessingFiles,
          builder: (context, isProcessing, child) {
            final list = SuperListView.builder(
              controller: widget.scrollController,
              listController: widget.listController,
              cacheExtent: 600,
              delayPopulatingCacheArea: false,
              addRepaintBoundaries: false,
              findChildIndexCallback: _findMessageIndexByKey,
              extentEstimation: _estimateItemExtent,
              padding: EdgeInsets.fromLTRB(
                horizontalPad,
                widget.topContentPadding,
                horizontalPad,
                widget.bottomContentPadding +
                    (widget.isPinnedIndicatorActive ? 12 : 0),
              ),
              itemCount: _effectiveRenderModels.length,
              keyboardDismissBehavior: _keyboardDismissBehavior,
              itemBuilder: (context, index) {
                if (index < 0 || index >= _effectiveRenderModels.length) {
                  return const SizedBox.shrink();
                }
                return _buildMessageItem(
                  context,
                  index: index,
                  isProcessingFiles: isProcessing,
                  presentation: presentation,
                );
              },
            );

            final historyList = NotificationListener<ScrollNotification>(
              onNotification: _handleScrollNotification,
              child: list,
            );

            final userScrollAwareList = Listener(
              onPointerDown: (event) {
                if (_isDesktopPlatform) _keyboardFocusNode.requestFocus();
                if (event.buttons != 0 &&
                    event.buttons != kSecondaryMouseButton) {
                  _pointerDragInProgress = true;
                  _latestPointerDragMetrics = null;
                }
              },
              onPointerUp: (_) => _settlePointerDrag(),
              onPointerCancel: (_) => _settlePointerDrag(),
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  _schedulePointerScrollActivityCheck();
                }
              },
              child: Focus(
                key: const ValueKey('timeline-keyboard-scroll-region'),
                focusNode: _keyboardFocusNode,
                onKeyEvent: _handleTimelineKeyEvent,
                child: historyList,
              ),
            );

            return Stack(
              children: [
                userScrollAwareList,
                if (_effectiveRenderModels.isEmpty && widget.isLoadingWindow)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _WindowLoadingSkeleton(
                        key: MessageListView.windowSkeletonKey,
                        horizontalPadding: horizontalPad,
                        topPadding: widget.topContentPadding,
                      ),
                    ),
                  ),
                if (widget.isPinnedIndicatorActive &&
                    widget.buildPinnedStreamingIndicator != null)
                  widget.buildPinnedStreamingIndicator!(),
              ],
            );
          },
        );
      },
    );
  }

  KeyEventResult _handleTimelineKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.pageUp &&
        key != LogicalKeyboardKey.pageDown &&
        key != LogicalKeyboardKey.home &&
        key != LogicalKeyboardKey.end) {
      return KeyEventResult.ignored;
    }
    widget.onUserScrollIntent?.call();
    return KeyEventResult.ignored;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails != null) {
        _recordPointerDrag(notification.metrics);
      }
    } else if (notification is OverscrollNotification) {
      if (notification.dragDetails != null) {
        _recordPointerDrag(notification.metrics);
      }
    } else if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _recordPointerDrag(notification.metrics);
    }
    if (notification is UserScrollNotification) {
      final shouldDefer = notification.direction != ScrollDirection.idle;
      if (shouldDefer) {
        _userScrollActive = true;
        _scrollIdleTimer?.cancel();
        _scrollIdleTimer = null;
        _setDeferStreamingMessageUpdates(true);
      } else {
        _userScrollActive = false;
        _scheduleStreamingUpdateResume();
      }
    }
    if (notification is ScrollEndNotification) {
      _userScrollActive = false;
      _scheduleStreamingUpdateResume();
    }
    if (_historyLoadScheduled) return false;
    final now = DateTime.now();
    final last = _lastHistoryLoadAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 120)) {
      return false;
    }

    final isNearTop = notification.metrics.pixels <= 96;
    final isNearBottom =
        notification.metrics.maxScrollExtent - notification.metrics.pixels <=
        96;
    if (isNearTop && widget.hasMoreBefore && widget.onLoadMoreBefore != null) {
      _scheduleHistoryLoad(load: widget.onLoadMoreBefore!);
    } else if (isNearBottom &&
        widget.hasMoreAfter &&
        widget.onLoadMoreAfter != null) {
      _scheduleHistoryLoad(load: widget.onLoadMoreAfter!);
    }
    return false;
  }

  void _recordPointerDrag(ScrollMetrics metrics) {
    _pointerDragInProgress = true;
    _latestPointerDragMetrics = metrics;
  }

  void _settlePointerDrag([ScrollMetrics? metrics]) {
    if (!_pointerDragInProgress) return;
    _pointerDragInProgress = false;
    final settledMetrics = metrics ?? _latestPointerDragMetrics;
    _latestPointerDragMetrics = null;
    _handleUserScrollActivity(settledMetrics);
  }

  void _schedulePointerScrollActivityCheck() {
    if (_pointerScrollActivityCheckScheduled) return;
    _pointerScrollActivityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pointerScrollActivityCheckScheduled = false;
      if (!mounted) return;
      _handleUserScrollActivity();
    });
  }

  void _handleUserScrollActivity([ScrollMetrics? metrics]) {
    widget.onUserScrollIntent?.call();
    if (_isWithinStreamingAutoFollowBand(metrics)) {
      _resumeStreamingMessageUpdates();
      return;
    }
    _setDeferStreamingMessageUpdates(true);
    _scheduleStreamingUpdateResume();
  }

  bool _isWithinStreamingAutoFollowBand([ScrollMetrics? metrics]) {
    if (metrics != null) {
      final gap = _contentMaxScrollExtent(metrics) - metrics.pixels;
      return gap <= _streamingUpdateDeferBottomTolerance;
    }
    if (!widget.scrollController.hasClients) return true;
    final position = widget.scrollController.position;
    final gap = _contentMaxScrollExtent(position) - position.pixels;
    return gap <= _streamingUpdateDeferBottomTolerance;
  }

  double _contentMaxScrollExtent(ScrollMetrics metrics) {
    return metrics.maxScrollExtent;
  }

  void _setDeferStreamingMessageUpdates(bool value) {
    if (_deferStreamingMessageUpdates.value == value) return;
    _deferStreamingMessageUpdates.value = value;
  }

  void _scheduleStreamingUpdateResume() {
    if (_pointerDragInProgress || _userScrollActive) return;
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(
      const Duration(milliseconds: 160),
      _resumeStreamingMessageUpdates,
    );
  }

  void _resumeStreamingMessageUpdates() {
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = null;
    if (!mounted || !_deferStreamingMessageUpdates.value) return;
    _deferStreamingMessageUpdates.value = false;
  }

  void _scheduleHistoryLoad({required Future<bool> Function() load}) {
    _historyLoadScheduled = true;
    _lastHistoryLoadAt = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _historyLoadScheduled = false;
        return;
      }

      final loaded = await load();
      if (!mounted) {
        _historyLoadScheduled = false;
        return;
      }
      if (!loaded) {
        _historyLoadScheduled = false;
        return;
      }

      // 在重建与锚点恢复期间保持分页锁定。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _historyLoadScheduled = false;
    });
  }

  Widget _buildMessageItem(
    BuildContext context, {
    required int index,
    required bool isProcessingFiles,
    required _MessagePresentation presentation,
  }) {
    final model = _effectiveRenderModels[index];
    final message = model.message;
    final r = widget.reasoning[message.id];
    final t = widget.translations[message.id];
    final assistant = presentation.assistant;
    final useAssistAvatar = assistant?.useAssistantAvatar == true;
    final useAssistName = assistant?.useAssistantName == true;
    final gid = model.slotId;
    final availableVersions = model.availableVersions;
    final selectedVersion = model.selectedVersion;
    final selectedIdx = model.selectedVersionIndex;
    final total = availableVersions.length;
    final siblingBranchIds =
        widget.siblingBranchIdsByMessageId[message.id] ?? const <String>[];
    final useBranchSelector = siblingBranchIds.length > 1;
    final selectedBranchIndex = useBranchSelector
        ? siblingBranchIds.indexOf(widget.activeBranchId ?? '')
        : selectedIdx;
    final messageSuggestions =
        !widget.selecting &&
            model.isLatestCompleteAssistant &&
            widget.onSuggestionTap != null
        ? widget.suggestions
        : const <String>[];

    // 检查是否为应使用 ValueListenableBuilder 的流式消息
    final isStreaming =
        message.isStreaming &&
        message.role == 'assistant' &&
        widget.streamingContentNotifier != null &&
        widget.streamingContentNotifier!.hasNotifier(message.id);

    final messageColumn = Column(
      key: ValueKey<String>('timeline-slot:${_slotId(message)}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.selecting &&
                (message.role == 'user' || message.role == 'assistant'))
              Padding(
                padding: const EdgeInsets.only(left: 10, right: 6),
                child: IosCheckbox(
                  value: widget.selectedItems.contains(message.id),
                  size: 20,
                  hitTestSize: 28,
                  onChanged: (v) {
                    widget.onToggleSelection?.call(message.id, v);
                  },
                ),
              ),
            Expanded(
              child: (() {
                Widget buildContent(bool processing) => Builder(
                  builder: (context) {
                    final baseMediaQuery = context
                        .getInheritedWidgetOfExactType<MediaQuery>();
                    final baseData = baseMediaQuery?.data;
                    final data = baseData ?? MediaQuery.of(context);
                    final textScale = data.textScaler.scale(1);
                    return MediaQuery(
                      // 保持聊天字体缩放，且不在键盘内边距变化时重建。
                      data: data.copyWith(
                        textScaler: TextScaler.linear(
                          textScale * presentation.chatFontScale,
                        ),
                      ),
                      child: isStreaming
                          ? _buildStreamingMessageWidget(
                              context,
                              message: message,
                              index: index,
                              r: r,
                              t: t,
                              useAssistAvatar: useAssistAvatar,
                              useAssistName: useAssistName,
                              assistant: assistant,
                              gid: gid,
                              availableVersions: availableVersions,
                              selectedVersion: selectedVersion,
                              selectedIdx: selectedIdx,
                              total: total,
                              siblingBranchIds: siblingBranchIds,
                              selectedBranchIndex: selectedBranchIndex,
                              useBranchSelector: useBranchSelector,
                              isProcessingFiles: processing,
                              suggestions: messageSuggestions,
                              presentation: presentation,
                            )
                          : _buildChatMessageWidget(
                              context,
                              message: message,
                              index: index,
                              r: r,
                              t: t,
                              useAssistAvatar: useAssistAvatar,
                              useAssistName: useAssistName,
                              assistant: assistant,
                              gid: gid,
                              availableVersions: availableVersions,
                              selectedVersion: selectedVersion,
                              selectedIdx: selectedIdx,
                              total: total,
                              siblingBranchIds: siblingBranchIds,
                              selectedBranchIndex: selectedBranchIndex,
                              useBranchSelector: useBranchSelector,
                              isProcessingFiles: processing,
                              suggestions: messageSuggestions,
                              presentation: presentation,
                            ),
                    );
                  },
                );

                Widget content =
                    message.role == 'assistant' &&
                        widget.processingFilesMessageId != null
                    ? ValueListenableBuilder<String?>(
                        valueListenable: widget.processingFilesMessageId!,
                        builder: (context, processingId, _) =>
                            buildContent(processingId == message.id),
                      )
                    : buildContent(isProcessingFiles);

                final canSelect =
                    (message.role == 'user' || message.role == 'assistant');
                if (widget.selecting && canSelect) {
                  final isSelected = widget.selectedItems.contains(message.id);
                  content = GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        widget.onToggleSelection?.call(message.id, !isSelected),
                    child: IgnorePointer(ignoring: true, child: content),
                  );
                }

                return content;
              })(),
            ),
          ],
        ),
        if (model.showContextDivider)
          Padding(
            padding: widget.dividerPadding,
            child: _buildContextDivider(context),
          ),
      ],
    );
    final isSpotlight =
        widget.spotlightMessageId != null &&
        message.id == widget.spotlightMessageId;
    final Widget item = isSpotlight
        ? RepaintBoundary(
            child: TweenAnimationBuilder<double>(
              key: ValueKey('spotlight-${widget.spotlightToken}'),
              tween: Tween<double>(begin: 1.0, end: 0.0),
              duration: const Duration(milliseconds: 1200),
              curve: Curves.easeOut,
              builder: (context, opacity, child) {
                return Stack(
                  children: [
                    child!,
                    if (opacity > 0.0)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFFFFA726,
                              ).withValues(alpha: opacity * 0.30),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
              child: messageColumn,
            ),
          )
        : RepaintBoundary(child: messageColumn);

    // 动画器包裹 item 的 RepaintBoundary，使淡入淡出仅
    // 重新合成该边界的缓存图层，而不是每个动画帧都重绘
    // 整个消息子树。
    return _SlotRemovalAnimator(
      key: ValueKey<String>(model.slotId),
      removing: widget.removingSlotIds.contains(model.slotId),
      child: item,
    );
  }

  /// 使用 ValueListenableBuilder 构建流式消息 widget，
  /// 以避免流式过程中整页重建。
  Widget _buildStreamingMessageWidget(
    BuildContext context, {
    required ChatMessage message,
    required int index,
    required stream_ctrl.ReasoningData? r,
    required TranslationUiState? t,
    required bool useAssistAvatar,
    required bool useAssistName,
    required dynamic assistant,
    required String gid,
    required List<int> availableVersions,
    required int selectedVersion,
    required int selectedIdx,
    required int total,
    required List<String> siblingBranchIds,
    required int selectedBranchIndex,
    required bool useBranchSelector,
    required bool isProcessingFiles,
    required List<String> suggestions,
    required _MessagePresentation presentation,
  }) {
    return _StreamingMessageDataGate(
      notifier: widget.streamingContentNotifier!.getNotifier(message.id),
      deferUpdates: _deferStreamingMessageUpdates,
      builder: (context, data, deferUpdates) {
        // 优先使用流式内容，否则回退到消息内容
        final displayContent = data.content.isNotEmpty
            ? data.content
            : message.content;
        final displayTokens = data.totalTokens > 0
            ? data.totalTokens
            : message.totalTokens;

        // 用流式内容创建修改后的消息
        final streamingMessage = message.copyWith(
          content: displayContent,
          totalTokens: displayTokens,
          promptTokens: data.promptTokens,
          completionTokens: data.completionTokens,
          cachedTokens: data.cachedTokens,
          durationMs: data.durationMs,
        );

        // 从流式数据更新推理文本，同时保留来自 r 的展开状态
        // 这样用户可在流式过程中切换展开状态而不被重置
        stream_ctrl.ReasoningData? streamingReasoning = r;
        if (data.reasoningText != null && data.reasoningText!.isNotEmpty) {
          streamingReasoning = stream_ctrl.ReasoningData()
            ..text = data.reasoningText!
            ..startAt = data.reasoningStartAt ?? r?.startAt
            ..finishedAt = data.reasoningFinishedAt ?? r?.finishedAt
            ..expanded = r?.expanded ?? false;
        }

        // 用 RepaintBoundary 包裹，隔离重绘以免影响其他 widget
        return RepaintBoundary(
          child: _buildChatMessageWidget(
            context,
            message: streamingMessage,
            index: index,
            r: streamingReasoning,
            t: t,
            useAssistAvatar: useAssistAvatar,
            useAssistName: useAssistName,
            assistant: assistant,
            gid: gid,
            availableVersions: availableVersions,
            selectedVersion: selectedVersion,
            selectedIdx: selectedIdx,
            total: total,
            siblingBranchIds: siblingBranchIds,
            selectedBranchIndex: selectedBranchIndex,
            useBranchSelector: useBranchSelector,
            isProcessingFiles: isProcessingFiles,
            suggestions: suggestions,
            presentation: presentation,
            enableStreamingTextMotion: !deferUpdates,
          ),
        );
      },
    );
  }

  /// 用全部属性构建实际的 ChatMessageWidget。
  Widget _buildChatMessageWidget(
    BuildContext context, {
    required ChatMessage message,
    required int index,
    required stream_ctrl.ReasoningData? r,
    required TranslationUiState? t,
    required bool useAssistAvatar,
    required bool useAssistName,
    required dynamic assistant,
    required String gid,
    required List<int> availableVersions,
    required int selectedVersion,
    required int selectedIdx,
    required int total,
    required List<String> siblingBranchIds,
    required int selectedBranchIndex,
    required bool useBranchSelector,
    required bool isProcessingFiles,
    required List<String> suggestions,
    required _MessagePresentation presentation,
    bool enableStreamingTextMotion = true,
  }) {
    final currentIdx = useBranchSelector
        ? selectedBranchIndex
        : availableVersions.indexOf(selectedVersion);
    return ChatMessageWidget(
      message: message,
      enableStreamingTextMotion: enableStreamingTextMotion,
      versionIndex: currentIdx < 0 ? selectedIdx : currentIdx,
      versionCount: useBranchSelector ? siblingBranchIds.length : 1,
      onPrevVersion: useBranchSelector
          ? (currentIdx > 0)
                ? () => widget.onBranchChange?.call(
                    siblingBranchIds[currentIdx - 1],
                  )
                : null
          : null,
      onNextVersion: useBranchSelector
          ? (currentIdx >= 0 && currentIdx < siblingBranchIds.length - 1)
                ? () => widget.onBranchChange?.call(
                    siblingBranchIds[currentIdx + 1],
                  )
                : null
          : null,
      modelIcon:
          (!useAssistAvatar &&
              message.role == 'assistant' &&
              message.providerId != null &&
              message.modelId != null)
          ? CurrentModelIcon(
              providerKey: message.providerId,
              modelId: message.modelId,
              size: 30,
            )
          : null,
      showModelIcon: useAssistAvatar ? false : presentation.showModelIcon,
      useAssistantAvatar: useAssistAvatar && message.role == 'assistant',
      useAssistantName: useAssistName && message.role == 'assistant',
      assistantName: (useAssistAvatar || useAssistName)
          ? (assistant?.name ?? 'Assistant')
          : null,
      assistantAvatar: useAssistAvatar ? (assistant?.avatar ?? '') : null,
      assistantAvatarTransform: useAssistAvatar
          ? assistant?.avatarTransform
          : null,
      showUserAvatar: presentation.showUserAvatar,
      showTokenStats: presentation.showTokenStats,
      hideStreamingIndicator:
          isProcessingFiles ||
          (widget.isPinnedIndicatorActive &&
              (message.id == widget.pinnedStreamingMessageId)),
      reasoningText: (message.role == 'assistant') ? (r?.text ?? '') : null,
      reasoningExpanded: (message.role == 'assistant')
          ? (r?.expanded ?? false)
          : false,
      reasoningLoading: (message.role == 'assistant')
          ? (message.isStreaming &&
                r?.finishedAt == null &&
                (r?.text.isNotEmpty == true))
          : false,
      reasoningStartAt: (message.role == 'assistant') ? r?.startAt : null,
      reasoningFinishedAt: (message.role == 'assistant') ? r?.finishedAt : null,
      onToggleReasoning: (message.role == 'assistant' && r != null)
          ? () => widget.onToggleReasoning?.call(message.id)
          : null,
      translationExpanded: t?.expanded ?? true,
      onToggleTranslation:
          (message.translation != null &&
              message.translation!.isNotEmpty &&
              t != null)
          ? () => widget.onToggleTranslation?.call(message.id)
          : null,
      onRegenerate: message.role == 'assistant'
          ? () => widget.onRegenerateMessage?.call(message)
          : null,
      onResend: message.role == 'user'
          ? () => widget.onResendMessage?.call(message)
          : null,
      onTranslate: message.role == 'assistant'
          ? () => widget.onTranslateMessage?.call(message)
          : null,
      onSpeak: message.role == 'assistant'
          ? () => widget.onSpeakMessage?.call(message)
          : null,
      onEdit: (message.role == 'assistant' || message.role == 'user')
          ? () => widget.onEditMessage?.call(message)
          : null,
      onDelete: message.role == 'user'
          ? () => widget.onDeleteMessageAndFollowing?.call(
              message,
              widget.byGroup,
            )
          : null,
      onMore: () async {
        final action = await showMessageMoreSheet(
          context,
          message,
          canDeleteAllVersions: siblingBranchIds.length > 1,
          canDeleteCurrentBranch: siblingBranchIds.length > 1,
          canDeleteMessageNode: siblingBranchIds.length > 1,
          canUseLinearDeleteActions: !useBranchSelector,
          canCreateBranch: widget.onMessageFork != null,
          canCreateConversationFork: widget.onConversationFork != null,
        );
        if (action == MessageMoreAction.deleteMessageAndFollowing) {
          await widget.onDeleteMessageAndFollowing?.call(
            message,
            widget.byGroup,
          );
        } else if (action == MessageMoreAction.deleteMessageNode) {
          await widget.onDeleteMessageNode?.call(message, widget.byGroup);
        } else if (action == MessageMoreAction.deleteMessageOnly) {
          await widget.onDeleteMessageOnly?.call(message, widget.byGroup);
        } else if (action == MessageMoreAction.deleteCurrentBranch) {
          await widget.onDeleteCurrentBranch?.call(message, widget.byGroup);
        } else if (action == MessageMoreAction.deleteAllVersions) {
          await widget.onDeleteAllVersions?.call(message, widget.byGroup);
        } else if (action == MessageMoreAction.edit) {
          widget.onEditMessage?.call(message);
        } else if (action == MessageMoreAction.switchToUser) {
          await widget.onSwitchMessageRole?.call(message, 'user');
        } else if (action == MessageMoreAction.switchToAssistant) {
          await widget.onSwitchMessageRole?.call(message, 'assistant');
        } else if (action == MessageMoreAction.messageFork) {
          await widget.onMessageFork?.call(message);
        } else if (action ==
            MessageMoreAction.conversationForkPreserveBranches) {
          await widget.onConversationFork?.call(
            message,
            ConversationForkMode.preserveBranches,
          );
        } else if (action ==
            MessageMoreAction.conversationForkActiveBranchOnly) {
          await widget.onConversationFork?.call(
            message,
            ConversationForkMode.activeBranchOnly,
          );
        } else if (action == MessageMoreAction.share) {
          widget.onShareMessage?.call(index, widget.messages);
        } else if (action == MessageMoreAction.selectMessages) {
          widget.onSelectMessages?.call(index, widget.messages);
        }
      },
      toolParts: message.role == 'assistant'
          ? widget.toolParts[message.id]
          : null,
      contentSplitOffsets: message.role == 'assistant'
          ? widget.contentSplits[message.id]?.offsets
          : null,
      reasoningCountAtSplit: message.role == 'assistant'
          ? widget.contentSplits[message.id]?.reasoningCounts
          : null,
      toolCountAtSplit: message.role == 'assistant'
          ? widget.contentSplits[message.id]?.toolCounts
          : null,
      reasoningSegments: message.role == 'assistant'
          ? (() {
              final segments = widget.reasoningSegments[message.id];
              if (segments == null || segments.isEmpty) return null;
              return segments
                  .asMap()
                  .entries
                  .map(
                    (entry) => ReasoningSegment(
                      text: entry.value.text,
                      expanded: entry.value.expanded,
                      loading:
                          message.isStreaming &&
                          entry.value.finishedAt == null &&
                          entry.value.text.isNotEmpty,
                      startAt: entry.value.startAt,
                      finishedAt: entry.value.finishedAt,
                      onToggle: () => widget.onToggleReasoningSegment?.call(
                        message.id,
                        entry.key,
                      ),
                      toolStartIndex: entry.value.toolStartIndex,
                    ),
                  )
                  .toList();
            })()
          : null,
      isProcessingFiles: isProcessingFiles,
      suggestions: suggestions,
      onSuggestionTap: widget.onSuggestionTap,
      onRecoveredAskUserAnswer: widget.onRecoveredAskUserAnswer == null
          ? null
          : (part, result) =>
                widget.onRecoveredAskUserAnswer!(message, part, result),
      showThinkingCards: widget.showThinkingCards,
      showToolCards: widget.showToolCards,
    );
  }

  bool _hiddenStandaloneToolMessageRemainsVisible(String content) {
    try {
      final obj = jsonDecode(content);
      return obj is Map && obj['tool']?.toString() == LocalToolNames.askUser;
    } catch (_) {
      return false;
    }
  }

  Set<String> _readPendingApprovalIds(BuildContext context) {
    try {
      return context
          .select<ToolApprovalService, _EstimateIdSet>(
            (approval) => _EstimateIdSet({
              for (final request in approval.pendingRequests)
                request.toolCallId,
            }),
          )
          .ids;
    } on ProviderNotFoundException {
      return const <String>{};
    }
  }
}

final class _EstimateIdSet {
  const _EstimateIdSet(this.ids);

  final Set<String> ids;

  @override
  bool operator ==(Object other) =>
      other is _EstimateIdSet && setEquals(other.ids, ids);

  @override
  int get hashCode => Object.hashAllUnordered(ids);
}

/// 影响消息渲染高度的显示设置。
final class _EstimateSettings {
  const _EstimateSettings({
    required this.collapseThinking,
    required this.collapseThinkingSteps,
    required this.showThinkingCards,
    required this.showToolCards,
    required this.showToolResultSummary,
    required this.hideToolResultImages,
    required this.collapsedCodeLines,
    required this.wrapCodeBlocks,
    required this.pendingApprovalIds,
  });

  /// 已完成的思考块是否折叠为卡片渲染。
  final bool collapseThinking;
  final bool collapseThinkingSteps;
  final bool showThinkingCards;
  final bool showToolCards;
  final bool showToolResultSummary;
  final bool hideToolResultImages;

  /// 长代码块折叠到的行数；保持展开时为 null。
  final int? collapsedCodeLines;

  /// 代码块是否换行而非水平滚动。
  final bool wrapCodeBlocks;
  final Set<String> pendingApprovalIds;

  @override
  bool operator ==(Object other) =>
      other is _EstimateSettings &&
      other.collapseThinking == collapseThinking &&
      other.collapseThinkingSteps == collapseThinkingSteps &&
      other.showThinkingCards == showThinkingCards &&
      other.showToolCards == showToolCards &&
      other.showToolResultSummary == showToolResultSummary &&
      other.hideToolResultImages == hideToolResultImages &&
      other.collapsedCodeLines == collapsedCodeLines &&
      other.wrapCodeBlocks == wrapCodeBlocks &&
      setEquals(other.pendingApprovalIds, pendingApprovalIds);

  @override
  int get hashCode => Object.hash(
    collapseThinking,
    collapseThinkingSteps,
    showThinkingCards,
    showToolCards,
    showToolResultSummary,
    hideToolResultImages,
    collapsedCodeLines,
    wrapCodeBlocks,
    Object.hashAllUnordered(pendingApprovalIds),
  );
}

/// 记忆化的范围估算及其全部推导依据。
final class _ExtentEstimate {
  const _ExtentEstimate({
    required this.content,
    required this.crossAxisExtent,
    required this.fontScale,
    required this.settings,
    required this.reasoningSignature,
    required this.toolSignature,
    required this.extent,
  });

  final String content;
  final double crossAxisExtent;
  final double fontScale;
  final _EstimateSettings settings;
  final int reasoningSignature;
  final int toolSignature;
  final double extent;
}

final class _MessagePresentation {
  const _MessagePresentation({
    required this.chatFontScale,
    required this.showModelIcon,
    required this.showUserAvatar,
    required this.showTokenStats,
    required this.assistant,
  });

  final double chatFontScale;
  final bool showModelIcon;
  final bool showUserAvatar;
  final bool showTokenStats;
  final Assistant? assistant;
}

/// 在删除时间线插槽前先淡出再折叠。
///
/// 先执行淡出让消息视觉上消失，随后高度折叠使相邻消息拼接。插槽数据仅在
/// [ChatLayoutConstants.slotRemovalAnimationDuration] 之后才移除；
/// 此时插槽已为零高度，移除不可见。
class _SlotRemovalAnimator extends StatefulWidget {
  const _SlotRemovalAnimator({
    super.key,
    required this.removing,
    required this.child,
  });

  final bool removing;
  final Widget child;

  @override
  State<_SlotRemovalAnimator> createState() => _SlotRemovalAnimatorState();
}

class _SlotRemovalAnimatorState extends State<_SlotRemovalAnimator>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.removing) _startRemoval();
  }

  @override
  void didUpdateWidget(covariant _SlotRemovalAnimator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.removing && !oldWidget.removing) {
      _startRemoval();
    } else if (!widget.removing && oldWidget.removing) {
      // 删除被中止（插槽通常直接卸载而不会
      // 到达此处），因此恢复消息。该 element 的重建已经在进行，
      // 无需 setState。
      _controller?.dispose();
      _controller = null;
    }
  }

  void _startRemoval() {
    final controller = AnimationController(
      vsync: this,
      duration: ChatLayoutConstants.slotRemovalAnimationDuration,
    );
    controller.addListener(() => setState(() {}));
    _controller = controller;
    controller.forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final removing = controller != null;
    final progress = controller?.value ?? 0.0;
    final opacity = removing
        ? 1.0 - Curves.easeOut.transform(math.min(1.0, progress / 0.6))
        : 1.0;
    final heightFactor = removing
        ? 1.0 -
              Curves.easeInOutCubic.transform(
                math.max(0.0, (progress - 0.2) / 0.8),
              )
        : 1.0;
    // 即使空闲时 wrapper 链也存在：动画开始时切换 widget 类型会导致重父级化
    // ——从而重建——整个消息子树，对巨型消息会造成可见卡顿。所有
    // wrapper 在空闲值下都是直通。
    return ClipRect(
      clipBehavior: removing ? Clip.hardEdge : Clip.none,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: heightFactor.clamp(0.0, 1.0),
        child: Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: IgnorePointer(ignoring: removing, child: widget.child),
        ),
      ),
    );
  }
}

class _StreamingMessageDataGate extends StatefulWidget {
  const _StreamingMessageDataGate({
    required this.notifier,
    required this.deferUpdates,
    required this.builder,
  });

  final ValueNotifier<StreamingContentData> notifier;
  final ValueListenable<bool> deferUpdates;
  final Widget Function(
    BuildContext context,
    StreamingContentData data,
    bool deferUpdates,
  )
  builder;

  @override
  State<_StreamingMessageDataGate> createState() =>
      _StreamingMessageDataGateState();
}

class _StreamingMessageDataGateState extends State<_StreamingMessageDataGate> {
  late StreamingContentData _visibleData;
  late bool _deferUpdates;
  bool _hasDeferredUpdate = false;

  @override
  void initState() {
    super.initState();
    _visibleData = widget.notifier.value;
    _deferUpdates = widget.deferUpdates.value;
    widget.notifier.addListener(_handleNotifierChanged);
    widget.deferUpdates.addListener(_handleDeferUpdatesChanged);
  }

  @override
  void didUpdateWidget(covariant _StreamingMessageDataGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notifier != widget.notifier) {
      oldWidget.notifier.removeListener(_handleNotifierChanged);
      _visibleData = widget.notifier.value;
      _hasDeferredUpdate = false;
      widget.notifier.addListener(_handleNotifierChanged);
    }

    if (oldWidget.deferUpdates != widget.deferUpdates) {
      oldWidget.deferUpdates.removeListener(_handleDeferUpdatesChanged);
      _deferUpdates = widget.deferUpdates.value;
      widget.deferUpdates.addListener(_handleDeferUpdatesChanged);
    }
  }

  void _handleNotifierChanged() {
    if (_deferUpdates) {
      _hasDeferredUpdate = true;
      return;
    }
    if (_visibleData == widget.notifier.value) return;
    setState(() {
      _visibleData = widget.notifier.value;
      _hasDeferredUpdate = false;
    });
  }

  void _handleDeferUpdatesChanged() {
    final next = widget.deferUpdates.value;
    if (_deferUpdates == next) return;
    if (!next) {
      _deferUpdates = next;
      final hadDeferredUpdate = _hasDeferredUpdate;
      _applyLatestDeferredData();
      if (!hadDeferredUpdate && _visibleData == widget.notifier.value) {
        setState(() {});
      }
      return;
    }
    setState(() => _deferUpdates = next);
  }

  void _applyLatestDeferredData({bool notify = true}) {
    if (!_hasDeferredUpdate && _visibleData == widget.notifier.value) return;
    if (!notify) {
      _visibleData = widget.notifier.value;
      _hasDeferredUpdate = false;
      return;
    }
    setState(() {
      _visibleData = widget.notifier.value;
      _hasDeferredUpdate = false;
    });
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_handleNotifierChanged);
    widget.deferUpdates.removeListener(_handleDeferUpdatesChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _visibleData, _deferUpdates);
}

/// 气泡形骨架屏，仅在冷启动初始窗口加载进行中
/// 且列表尚无消息时显示。
class _WindowLoadingSkeleton extends StatefulWidget {
  const _WindowLoadingSkeleton({
    super.key,
    required this.horizontalPadding,
    required this.topPadding,
  });

  final double horizontalPadding;
  final double topPadding;

  @override
  State<_WindowLoadingSkeleton> createState() => _WindowLoadingSkeletonState();
}

class _WindowLoadingSkeletonState extends State<_WindowLoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bubbleColor = cs.onSurface.withValues(alpha: 0.08);

    Widget bubble({required bool alignEnd, required double widthFactor}) {
      return Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: widthFactor,
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        widget.horizontalPadding + 12,
        widget.topPadding + 24,
        widget.horizontalPadding + 12,
        0,
      ),
      child: FadeTransition(
        opacity: _pulse.drive(Tween<double>(begin: 0.45, end: 1.0)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            bubble(alignEnd: false, widthFactor: 0.62),
            const SizedBox(height: 14),
            bubble(alignEnd: true, widthFactor: 0.48),
            const SizedBox(height: 14),
            bubble(alignEnd: false, widthFactor: 0.7),
            const SizedBox(height: 14),
            bubble(alignEnd: true, widthFactor: 0.55),
          ],
        ),
      ),
    );
  }
}
