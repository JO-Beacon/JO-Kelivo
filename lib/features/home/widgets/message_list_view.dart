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
import '../../../core/models/message_part.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/assistant_regex.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../chat/widgets/chat_message_widget.dart';
import '../../chat/widgets/timeline_projection.dart';
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

/// 消息列表控件各动作的回调类型
typedef OnVersionChange = Future<void> Function(String groupId, int version);
typedef OnRegenerateMessage = void Function(ChatMessage message);
typedef OnResendMessage = void Function(ChatMessage message);
typedef OnTranslateMessage = void Function(ChatMessage message);
typedef OnEditMessage = void Function(ChatMessage message);

/// 切换消息角色（本仓库自有）。
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

/// 以这条消息为起点分叉出新分支（本仓库自有）。
typedef OnMessageFork = Future<void> Function(ChatMessage message);

/// 分叉会话，可选择保留所有分支或只保留当前分支（本仓库自有）。
typedef OnConversationFork =
    Future<void> Function(ChatMessage message, ConversationForkMode mode);

/// 上游扁平模型的分叉回调（整条会话分叉，不带模式）。
///
/// 本仓库的等价能力是 [OnConversationFork]（多一档模式选择），保留这个
/// typedef 是为了让上游形态的调用方也能编译；实际渲染走
/// [MessageListView.onConversationFork]。
typedef OnForkConversation = Future<void> Function(ChatMessage message);
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

/// 推理界面状态的数据类
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

/// 翻译界面状态的数据类
class TranslationUiState {
  final bool expanded;
  final VoidCallback? onToggle;

  const TranslationUiState({this.expanded = true, this.onToggle});
}

/// 展示聊天消息列表的控件。
///
/// 接收控制器预折叠好的消息与预计算的 byGroup，
/// 避免每次构建都重复计算。用变高度的惰性列表，
/// 让超长历史也能按索引滚动与定位，而无需排版
/// 它前面的每一条消息。
class MessageListView extends StatefulWidget {
  const MessageListView({
    super.key,
    required this.scrollController,
    required this.listController,
    required this.messages,
    this.renderModels,
    required this.byGroup,

    /// 上游扁平模型的“每个消息组选中的版本号”。
    ///
    /// 本仓库用真树模型（库里有 message_tree_edge_rows / conversation_branch_rows
    /// / conversation_tree_state_rows 三张表），当前走哪条由 activePath() 决定，
    /// 因此**不使用**这个映射表 —— 它只在调用方显式传入时才参与版本折叠。
    /// ⛔ 不要为了“与上游一致”而接上它：会把树上的兄弟节点重新混进上下文。
    this.versionSelections = const <String, int>{},

    /// 有子消息的消息 ID 集合。本仓库的树模型用它判断“删除这条及之后”
    /// 会不会连带删掉别处仍在引用的节点。
    this.messageIdsWithChildren = const <String>{},

    /// 内容最大宽度。桌面端用它约束消息气泡的横向伸展。
    this.maxContentWidth = ChatLayoutConstants.maxContentWidth,

    /// 会话是否正在生成中。影响流式指示与部分卡片的可见性。
    this.isConversationGenerating = false,
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
    this.pinnedStreamingMessageId,
    this.isPinnedIndicatorActive = false,

    /// 正在解析附件的助手消息 ID；为 null 表示不监听。
    ///
    /// 本仓库把它做成可选：读取方按“null 即不监听”处理，行为与必填版一致，
    /// 便于测试只关心布局时不必构造这个通知器。
    this.processingFilesMessageId,
    this.streamingContentNotifier,
    this.spotlightMessageId,
    this.spotlightToken = 0,
    this.removingSlotIds = const <String>{},

    /// 本仓库树模型：每个消息的兄弟分支 ID 列表（用于分支切换器）。
    this.siblingBranchIdsByMessageId = const <String, List<String>>{},

    /// 本仓库树模型：当前激活的分支 ID。
    this.activeBranchId,

    /// 本仓库树模型：切换分支时的回调。
    this.onBranchChange,
    this.onVersionChange,
    this.onRegenerateMessage,
    this.onResendMessage,
    this.onTranslateMessage,
    this.onEditMessage,

    /// 切换消息角色（用户⇄助手）。
    this.onSwitchMessageRole,

    /// 删除单条消息（保留其子节点）。
    this.onDeleteMessageOnly,

    /// 删除这条消息及其之后的内容。
    this.onDeleteMessageAndFollowing,

    /// 只删除这一个树节点（连同其子树）。
    this.onDeleteMessageNode,

    /// 删除当前分支（保留兄弟分支）。
    this.onDeleteCurrentBranch,
    this.onDeleteMessage,
    this.onDeleteAllVersions,

    /// 以这条消息为起点分叉出一个新分支（消息树自有）。
    this.onMessageFork,

    /// 以这条消息为起点分叉会话：可选择保留所有分支或只保留当前分支。
    this.onConversationFork,
    this.onForkConversation,
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
    this.showProducedFiles = true,
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

  /// 预折叠的消息（来自 ChatController.collapsedMessages）。
  final List<ChatMessage> messages;

  /// 预计算的“每个槽位一项”渲染输入。必须与 [messages] 顺序一致。
  final List<MessageRenderModel>? renderModels;

  /// 按 groupId 归组后的全部消息（来自 ChatController.groupedMessages）。
  final Map<String, List<ChatMessage>> byGroup;

  /// 每个消息组选中的版本（供版本导航控件使用）。
  final Map<String, int> versionSelections;

  /// 有子消息的消息 ID 集合（本仓库树模型自有）。
  final Set<String> messageIdsWithChildren;

  /// 内容最大宽度（本仓库自有，桌面端约束气泡宽度）。
  final double? maxContentWidth;

  /// 会话是否正在生成中（本仓库自有）。
  final bool isConversationGenerating;

  /// 预计算的截断下标（折叠消息空间内，-1 表示无）。
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
  final String? pinnedStreamingMessageId;
  final bool isPinnedIndicatorActive;

  /// 正在解析附件的助手消息 ID；为 null 表示不监听。
  ///
  /// 作用域限定到单条消息，避免“有文件在处理”的指示器出现在每一条助手回复上。
  final ValueNotifier<String?>? processingFilesMessageId;

  /// 流式内容更新的轻量通知器。
  /// 提供后，流式消息会改用 ValueListenableBuilder，
  /// 以避免整页重建。
  final StreamingContentNotifier? streamingContentNotifier;

  /// 设置后，该 ID 的消息会播放一次高亮脉冲动画。
  final String? spotlightMessageId;

  /// 每次触发新的高亮都会自增。用作动画 key，
  /// 使重复选中同一条消息也能重新播放脉冲。
  final int spotlightToken;

  /// 正在删除前淡出的槽位。在移除动画结束前，
  /// 其数据仍留在 [messages] 里。
  final Set<String> removingSlotIds;

  // 回调
  final OnVersionChange? onVersionChange;

  /// 本仓库树模型：每个消息的兄弟分支 ID 列表与当前激活分支。
  final Map<String, List<String>> siblingBranchIdsByMessageId;
  final String? activeBranchId;
  final ValueChanged<String>? onBranchChange;
  final OnRegenerateMessage? onRegenerateMessage;
  final OnResendMessage? onResendMessage;
  final OnTranslateMessage? onTranslateMessage;
  final OnEditMessage? onEditMessage;

  /// 切换消息角色（本仓库自有）。
  final OnSwitchMessageRole? onSwitchMessageRole;

  /// 本仓库自有的四种删除粒度 + 上游的单条删除。
  final OnDeleteMessage? onDeleteMessageOnly;
  final OnDeleteMessage? onDeleteMessageAndFollowing;
  final OnDeleteMessage? onDeleteMessageNode;
  final OnDeleteMessage? onDeleteCurrentBranch;
  final OnDeleteMessage? onDeleteMessage;
  final OnDeleteAllVersions? onDeleteAllVersions;

  /// 本仓库自有的消息分叉与会话分叉（后者带两种模式）。
  final OnMessageFork? onMessageFork;
  final OnConversationFork? onConversationFork;
  final OnForkConversation? onForkConversation;
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

  /// 仅在冷启动首窗加载进行中为真；快路径缓存命中
  /// 会在一批帧内完成，不会露出骨架屏。
  final bool isLoadingWindow;
  final Future<bool> Function()? onLoadMoreBefore;
  final bool hasMoreAfter;
  final Future<bool> Function()? onLoadMoreAfter;
  final VoidCallback? onUserScrollIntent;
  final double chatFontScale;

  /// 已结束的思考块是否折叠渲染（显示设置）。
  final bool collapseThinking;

  /// 每个时间线区块是否只保留最后两步加一行展开入口。
  /// 必须与渲染器一致，否则估算会误以为每个工具标题
  /// 都可见。
  final bool collapseThinkingSteps;

  /// 聊天中是否渲染思考过程卡片。
  final bool showThinkingCards;

  /// 聊天中是否渲染工具调用卡片。
  final bool showToolCards;

  /// 回复下方的文件摘要是否占高度。
  final bool showProducedFiles;

  /// 折叠的工具卡片是否也显示一行简短结果摘要。
  final bool showToolResultSummary;

  /// 工具结果的图片缩略图是否藏在卡片下。
  final bool hideToolResultImages;

  /// 长代码块折叠后的行数；保持展开时为 null。
  final int? collapsedCodeLines;

  /// 代码块是否换行（桌面端，或移动端开启了换行设置）
  /// 而不是横向滚动。
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
  ScrollMetrics? _latestPointerDragMetrics;
  bool _userScrollActive = false;
  final ValueNotifier<bool> _deferStreamingMessageUpdates = ValueNotifier<bool>(
    false,
  );

  /// 按消息 id 索引的冻结流式载荷，在延迟更新开始时
  /// 捕获。SuperSliverList 不得对行做 AutomaticKeepAlive ——
  /// 那会把行停到舞台外，使 [find.text] 与屏幕上的气泡都拿不到
  /// 初始文本。可见项 builder 改为绘制这份快照。
  final Map<String, StreamingContentData> _deferredStreamingHolds =
      <String, StreamingContentData>{};
  DateTime? _lastHistoryLoadAt;
  Timer? _scrollIdleTimer;
  bool _pointerScrollActivityCheckScheduled = false;
  late List<MessageRenderModel> _effectiveRenderModels;
  late Map<String, int> _slotIndexById;
  late Map<String, int> _messageIndexById;
  final Map<String, int> _lastToolSignatures = <String, int>{};
  final ToolExtentInvalidationQueue _toolExtentQueue =
      ToolExtentInvalidationQueue();
  var _awaitingAttachFlush = false;
  var _attachFlushScheduled = false;
  final FocusNode _keyboardFocusNode = FocusNode(
    debugLabel: 'timeline-keyboard-scroll-region',
  );

  /// 让列表把可视区域外的消息也真实排版一遍，用实测高度替换估算值。
  ///
  /// 聊天页的“底部”是所有消息高度之和算出来的，而上方任何一条的低估都会
  /// 让总高变小、真实末尾永远够不到——误差是累积的，不会相互抵消。
  /// 因此这里不加消息条数阈值：库文档中“大列表预计算收益递减”的说法针对
  /// 的是滚动条位置精度，不适用于本场景。
  ///
  /// 代价是一次性的：待测条数约等于消息条数，按库每帧 3 毫秒的预算分摊，
  /// 全部实测完成后不再产生开销。
  final _extentPrecalculationPolicy = ChatExtentPrecalculationPolicy();

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
    if (!identical(oldWidget.listController, widget.listController)) {
      _awaitingAttachFlush = _toolExtentQueue.pendingIds.isNotEmpty;
      _scheduleAttachAwareFlush();
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

  void _onInlineImageAspect(
    String messageId,
    String imageKey,
    double aspectRatio,
  ) {
    if (aspectRatio <= 0 || !aspectRatio.isFinite) return;
    final previous = timelineImageAspects[imageKey];
    if (previous != null && (previous - aspectRatio).abs() < 0.001) return;
    timelineImageAspects[imageKey] = aspectRatio;
    _invalidateToolExtentForMessage(messageId);
  }

  void _invalidateToolExtentForMessage(String messageId) {
    _extentEstimateCache.remove(messageId);
    final controller = widget.listController;
    if (!controller.isAttached) {
      _toolExtentQueue.retain(messageId);
      _awaitingAttachFlush = true;
      _scheduleAttachAwareFlush();
      return;
    }
    if (!controller.isLocked) {
      _applyToolExtentInvalidation(messageId);
      return;
    }
    if (_toolExtentQueue.enqueue(messageId)) {
      _scheduleToolExtentFlush();
    }
  }

  void _scheduleAttachAwareFlush() {
    if (_attachFlushScheduled) return;
    if (!_awaitingAttachFlush && _toolExtentQueue.pendingIds.isEmpty) {
      return;
    }
    _attachFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachFlushScheduled = false;
      if (!mounted) return;
      if (!widget.listController.isAttached) return;
      _awaitingAttachFlush = false;
      if (_toolExtentQueue.pendingIds.isEmpty) return;
      _scheduleToolExtentFlush();
    });
  }

  void _scheduleToolExtentFlush() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = widget.listController;
      final result = _toolExtentQueue.takeForFlush(
        mounted: mounted,
        isAttached: controller.isAttached,
        isLocked: controller.isLocked,
      );
      for (final id in result.ids) {
        _applyToolExtentInvalidation(id);
      }
      if (result.reschedule) {
        _scheduleToolExtentFlush();
      } else if (_toolExtentQueue.pendingIds.isNotEmpty) {
        _awaitingAttachFlush = true;
        _scheduleAttachAwareFlush();
      }
    });
  }

  void _invalidateExtentsForApprovalChange(
    List<PendingApprovalKey> previous,
    List<PendingApprovalKey> next,
  ) {
    final previousSet = previous.toSet();
    final nextSet = next.toSet();
    final changed = <PendingApprovalKey>{
      ...previousSet.difference(nextSet),
      ...nextSet.difference(previousSet),
    };
    if (changed.isEmpty && previous.length != next.length) {
      changed.addAll(nextSet);
    }
    if (changed.isEmpty) return;
    for (final model in _effectiveRenderModels) {
      final parts = widget.toolParts[model.message.id];
      if (parts == null || parts.isEmpty) continue;
      final conversationId = model.message.conversationId;
      final affected = parts.any((part) {
        for (final key in changed) {
          if (key.matches(
            conversationId: conversationId,
            toolCallId: part.id,
          )) {
            return true;
          }
        }
        return false;
      });
      if (affected) {
        _invalidateToolExtentForMessage(model.message.id);
      }
    }
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

  /// 气泡外的标题行 ＋ 动作栏 ＋ 上下间距。
  static const double _estimateChrome = 96.0;

  /// 折叠后的内联思考卡片高度。
  static const double _estimateCollapsedCard = 44.0;

  /// 时间线区块折叠时显示的展开步骤行。
  static const double _estimateExpandRow = 36.0;

  /// 推算消息行密度之前扫描的字符数。
  static const int _estimateScanLimit = 8000;

  /// 围栏代码渲染时的字号（缩放前）。
  static const double _estimateCodeFontSize = 13.0;

  /// 思考解析器最多处理的字符数。
  static const int _estimateParseLimit = 64000;

  /// 整份缓存丢弃之前保留的估算条目数。
  static const int _extentEstimateCacheLimit = 512;

  final Map<String, _ExtentEstimate> _extentEstimateCache = {};

  /// 系统无障碍字号缩放，会与聊天字号相乘。
  double _systemTextScale = 1.0;

  /// 估算依赖的显示设置，在 [build] 中刷新。
  ToolApprovalService? _approvalForEstimate;
  _EstimateSettings _estimateSettings = const _EstimateSettings(
    collapseThinking: true,
    collapseThinkingSteps: false,
    showThinkingCards: true,
    showToolCards: true,
    showToolResultSummary: false,
    hideToolResultImages: false,
    collapsedCodeLines: null,
    wrapCodeBlocks: false,
    visualRegexSignature: 0,
    pendingApprovals: <PendingApprovalKey>[],
  );

  /// 当前已存高度是按哪个字号缩放估算的。
  double? _estimatedFontScale;

  /// 系统字号缩放变化后丢弃已存高度。
  ///
  /// 只有控件驱动的输入会走 [_synchronizeExtentCache]；
  /// 系统无障碍变更经 MediaQuery 到达，不改变条目数，
  /// 否则 SuperSliverList 会一直沿用旧缩放下算出的屏外
  /// 高度，直到它们各自被滚进视野。
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

  /// 消息气泡的粗略高度，用于从未被排版过的条目。
  ///
  /// SuperSliverList 的默认估算一律是 100px。长对话里一条真实
  /// 气泡比它高一到两个数量级，于是每次排版用实测替换估算时，
  /// 总高度 —— 以及随之而来的贴底滚动偏移 —— 会移动
  /// 数万像素。
  /// 若这一替换跨两帧发生，时间线会明显弹离底部再弹回来。
  /// 按内容推导的估算能让这些修正量保持很小；
  /// 它不必精确，只要量级对就够。
  double _estimateItemExtent(int? index, double crossAxisExtent) {
    // 索引为 null 时是在问“是否有一个高度适用于所有条目”。
    // 若回答正数，SuperSliverList 会把它套用到整个列表，
    // 不再走下面的逐条分支，所以这里必须是 0。
    if (index == null) return 0;
    final models = _effectiveRenderModels;
    if (index < 0 || index >= models.length) return _estimateChrome;

    final message = models[index].message;
    final snapshot = _streamingSnapshot(message);
    final estimateParts = snapshot?.parts ?? message.parts;
    final text = snapshot != null && snapshot.content.isNotEmpty
        ? snapshot.content
        : message.content;
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
    final hasStructuredTimeline =
        message.role == 'assistant' &&
        estimateParts.any(
          (part) =>
              part is ReasoningPart ||
              part is ToolCallPart ||
              part is ImagePart,
        );
    if (text.isEmpty && !hasReasoning && !hasTools && !hasStructuredTimeline) {
      return _estimateChrome;
    }

    // 排版会反复询问同一个条目（每次尺寸变化、每次窗口
    // 变化），而下面的扫描与消息长度线性相关，因此用一份
    // 以“结果所依赖的一切”为键的记忆缓存，可让排版阶段保持轻量。
    // 内容按身份比较：编辑过或正在流式输出的消息一定
    // 带来新字符串，而等长度改写不得命中该缓存。
    final fontScale = widget.chatFontScale * _systemTextScale;
    final settings = _estimateSettings;
    final reasoningSignature = _reasoningEstimateSignature(
      reasoning,
      reasoningSegments,
      isStreaming: message.isStreaming,
    );
    final toolSignature = _toolEstimateSignature(toolParts);
    final partsSignature = _partsEstimateSignature(estimateParts);
    final streamingSignature = Object.hash(
      snapshot?.timelineStructureSignature ?? 0,
      snapshot?.reasoningFinishedAt,
      message.isStreaming,
    );
    final estimateContent = text;
    final cached = _extentEstimateCache[message.id];
    if (cached != null &&
        identical(cached.content, estimateContent) &&
        cached.crossAxisExtent == crossAxisExtent &&
        cached.fontScale == fontScale &&
        cached.settings == settings &&
        cached.reasoningSignature == reasoningSignature &&
        cached.toolSignature == toolSignature &&
        cached.partsSignature == partsSignature &&
        cached.streamingSignature == streamingSignature) {
      return cached.extent;
    }

    // 独立的工具行渲染成自己的卡片 —— 用户隐藏工具卡片时
    // 则不渲染。追问用户的卡片始终显示，以免生成被阻塞。
    // 待审批例外在此不适用：`_buildToolMessage`
    // 构建这些行时 `loading` 恒为 false。
    if (message.role == 'tool' &&
        !settings.showToolCards &&
        !_hiddenStandaloneToolMessageRemainsVisible(text)) {
      if (_extentEstimateCache.length > _extentEstimateCacheLimit) {
        _extentEstimateCache.clear();
      }
      _extentEstimateCache[message.id] = _ExtentEstimate(
        content: estimateContent,
        crossAxisExtent: crossAxisExtent,
        fontScale: fontScale,
        settings: settings,
        reasoningSignature: reasoningSignature,
        toolSignature: toolSignature,
        partsSignature: partsSignature,
        streamingSignature: streamingSignature,
        extent: 0,
      );
      return 0;
    }

    // 内联思考渲染成自己的卡片。它被折叠时 —— 或
    // 思考卡片整体被隐藏时 —— 只有可见的部分占高度，
    // 因此要用与渲染器相同的解析器把它切出来。
    var body = text;
    var collapsedCards = 0;
    final shouldStripInlineThink =
        message.role != 'user' &&
        text.length <= _estimateParseLimit &&
        text.contains('<') &&
        (!settings.showThinkingCards || settings.collapseThinking);
    if (shouldStripInlineThink) {
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
    // 用户气泡有内缩，从不占满整宽。
    final bubbleWidth = crossAxisExtent * (message.role == 'user' ? 0.85 : 1.0);
    final textWidth = math.max(80.0, bubbleWidth - 28);
    // 全角（中日韩）字符约为拉丁字符的两倍宽，
    // 两者的比例决定了每行能放多少个字符。
    final charWidth = fontSize * (0.5 + 0.55 * _wideCharRatio(body));
    final charsPerLine = math.max(1.0, textWidth / charWidth);
    // 代码用固定 13px 等宽字体渲染，因此换行位置与
    // 正文不同，行高也不同。
    final codeFontSize = _estimateCodeFontSize * fontScale;
    final codeCharsPerLine = math.max(1.0, textWidth / (codeFontSize * 0.6));
    // 空正文也会报出一行；跳过它，
    // 使“只有工具”的助手轮次是边框 ＋ 卡片，而不是多一行幽灵文本。
    final visualBody = _estimateVisualTransform(
      body,
      scope: message.role == 'user'
          ? AssistantRegexScope.user
          : AssistantRegexScope.assistant,
    );
    final timeline = _estimateTimelineExtent(
      message: message,
      parts: estimateParts,
      toolParts: toolParts,
      reasoning: reasoning,
      reasoningSegments: reasoningSegments,
      visualContent: visualBody,
      contentSplitOffsets:
          snapshot?.contentSplitOffsets ??
          widget.contentSplits[message.id]?.offsets,
      reasoningCountAtSplit:
          snapshot?.reasoningCountAtSplit ??
          widget.contentSplits[message.id]?.reasoningCounts,
      toolCountAtSplit:
          snapshot?.toolCountAtSplit ??
          widget.contentSplits[message.id]?.toolCounts,
      textWidth: textWidth,
      fontScale: fontScale,
    );
    final bodyForLines = message.role == 'assistant'
        ? (timeline.extent > 0 ? '' : visualBody)
        : visualBody;
    final bodyLines = bodyForLines.isEmpty
        ? 0.0
        : _wrappedLineCount(
            bodyForLines,
            charsPerLine: charsPerLine,
            codeCharsPerLine: settings.wrapCodeBlocks ? codeCharsPerLine : null,
            codeLineRatio: codeFontSize / fontSize,
            collapsedCodeLines: settings.collapsedCodeLines,
          );
    final extent =
        bodyLines * lineHeight +
        _estimateChrome +
        collapsedCards * _estimateCollapsedCard +
        timeline.extent;

    if (_extentEstimateCache.length > _extentEstimateCacheLimit) {
      _extentEstimateCache.clear();
    }
    _extentEstimateCache[message.id] = _ExtentEstimate(
      content: estimateContent,
      crossAxisExtent: crossAxisExtent,
      fontScale: fontScale,
      settings: settings,
      reasoningSignature: reasoningSignature,
      toolSignature: toolSignature,
      partsSignature: partsSignature,
      streamingSignature: streamingSignature,
      extent: extent,
    );
    return extent;
  }

  /// 用与渲染器相同的投影器算出的时间线高度。
  StreamingContentData? _streamingSnapshot(ChatMessage message) {
    if (!message.isStreaming) return null;
    if (_deferStreamingMessageUpdates.value) {
      final hold = _deferredStreamingHolds[message.id];
      if (hold != null) return hold;
    }
    final notifier = widget.streamingContentNotifier;
    if (notifier == null || !notifier.hasNotifier(message.id)) return null;
    return notifier.getNotifier(message.id).value;
  }

  ({double extent, bool fromParts}) _estimateTimelineExtent({
    required ChatMessage message,
    required List<MessagePart> parts,
    required List<ToolUIPart>? toolParts,
    required stream_ctrl.ReasoningData? reasoning,
    required List<stream_ctrl.ReasoningSegmentData>? reasoningSegments,
    required String visualContent,
    required List<int>? contentSplitOffsets,
    required List<int>? reasoningCountAtSplit,
    required List<int>? toolCountAtSplit,
    required double textWidth,
    required double fontScale,
  }) {
    if (message.role != 'assistant') {
      return (extent: 0, fromParts: false);
    }
    final settings = _estimateSettings;
    final liveTools = <TimelineToolRef>[
      for (var i = 0; i < (toolParts?.length ?? 0); i++)
        TimelineToolRef(
          providerId: toolParts![i].id,
          fallbackOrdinal: i,
          toolName: toolParts[i].toolName,
          arguments: toolParts[i].arguments,
          content: toolParts[i].content,
          metadata: toolParts[i].metadata,
          loading: toolParts[i].loading,
          memoToken: identityHashCode(toolParts[i]),
        ),
    ];
    final reasoningRefs = <TimelineReasoningRef>[
      if (reasoningSegments != null && reasoningSegments.isNotEmpty)
        for (final segment in reasoningSegments)
          TimelineReasoningRef(
            text: segment.text,
            expanded: segment.expanded,
            loading: timelineReasoningLoading(
              finishedAt: segment.finishedAt,
              isStreaming: message.isStreaming,
            ),
            startAt: segment.startAt,
            finishedAt: segment.finishedAt,
            toolStartIndex: segment.toolStartIndex,
          )
      else if (reasoning != null && reasoning.text.isNotEmpty)
        TimelineReasoningRef(
          text: reasoning.text,
          expanded: reasoning.expanded,
          loading: timelineReasoningLoading(
            finishedAt: reasoning.finishedAt,
            isStreaming: message.isStreaming,
          ),
          startAt: reasoning.startAt,
          finishedAt: reasoning.finishedAt,
        ),
    ];
    final projected = projectAssistantTimeline(
      parts: parts,
      liveTools: liveTools,
      reasoningSegments: reasoningRefs,
      visualContent: visualContent,
      contentSplitOffsets: contentSplitOffsets,
      reasoningCountAtSplit: reasoningCountAtSplit,
      toolCountAtSplit: toolCountAtSplit,
      transformText: _estimateVisualTransform,
      partsArrivalOrdered: message.isStreaming,
      inlineThinkingExpanded: !settings.collapseThinking,
    );
    bool isPending(TimelineToolRef tool) => _isPendingApproval(
      conversationId: message.conversationId,
      toolCallId: tool.providerId,
    );
    var extent = 0.0;
    var visibleBlockCount = 0;
    void addVisible(double height) {
      if (visibleBlockCount > 0) extent += 8.0;
      extent += height;
      visibleBlockCount++;
    }

    final fontSize = 15.6 * fontScale;
    final lineHeight = fontSize * 1.5;
    final codeFontSize = _estimateCodeFontSize * fontScale;
    final codeCharsPerLine = math.max(1.0, textWidth / (codeFontSize * 0.6));
    for (final block in visibleAssistantTimeline(
      projected,
      showThinkingCards: settings.showThinkingCards,
      showToolCards: settings.showToolCards,
      isPendingApproval: isPending,
    )) {
      if (block.isImage) {
        addVisible(
          estimateTimelineImageHeight(
            maxWidth: textWidth,
            aspectRatio:
                block.aspectRatio ?? timelineImageAspects[block.imageKey],
          ),
        );
        continue;
      }
      if (block.isText && block.text != null) {
        final charWidth = fontSize * (0.5 + 0.55 * _wideCharRatio(block.text!));
        final charsPerLine = math.max(1.0, textWidth / charWidth);
        addVisible(
          _wrappedLineCount(
                block.text!,
                charsPerLine: charsPerLine,
                codeCharsPerLine: settings.wrapCodeBlocks
                    ? codeCharsPerLine
                    : null,
                codeLineRatio: codeFontSize / fontSize,
                collapsedCodeLines: settings.collapsedCodeLines,
              ) *
              lineHeight,
        );
        continue;
      }
      if (!block.isThinking) continue;
      final collapsed = collapseTimelineSteps(
        block.thinkingSteps,
        collapseThinkingSteps: settings.collapseThinkingSteps,
      );
      addVisible(
        _estimateVisibleThinkingHeight(
          VisibleTimelineBlock(
            visibleSteps: collapsed.visibleSteps,
            hiddenCount: collapsed.hiddenCount,
          ),
          conversationId: message.conversationId,
          textWidth: textWidth,
          fontScale: fontScale,
        ),
      );
    }
    return (extent: extent, fromParts: projected.fromParts);
  }

  double _estimateVisibleThinkingHeight(
    VisibleTimelineBlock visible, {
    required String conversationId,
    required double textWidth,
    required double fontScale,
  }) {
    final settings = _estimateSettings;
    var extent = 0.0;
    if (visible.hasExpandRow) extent += _estimateExpandRow;
    for (final step in visible.visibleSteps) {
      if (step.isReasoning) {
        extent += _estimateReasoningStepHeight(
          step.reasoning!,
          textWidth: textWidth,
          fontScale: fontScale,
        );
      } else {
        final tool = step.tool!;
        extent += _estimateCollapsedCard;
        extent += estimateToolExtraHeight(
          toolName: tool.toolName,
          arguments: tool.arguments,
          content: tool.content,
          metadata: tool.metadata,
          showToolResultSummary: settings.showToolResultSummary,
          hideToolResultImages: settings.hideToolResultImages,
          pendingApproval: _isPendingApproval(
            conversationId: conversationId,
            toolCallId: tool.providerId,
          ),
          textWidth: textWidth,
          fontScale: fontScale,
          wrappedLineCount: _wrappedLineCount,
        );
      }
    }
    return extent;
  }

  String _estimateVisualTransform(
    String text, {
    AssistantRegexScope scope = AssistantRegexScope.assistant,
  }) {
    return applyAssistantRegexes(
      text,
      assistant: widget.assistant,
      scope: scope,
      target: AssistantRegexTransformTarget.visual,
    );
  }

  bool _isPendingApproval({
    required String conversationId,
    required String toolCallId,
  }) {
    return _approvalForEstimate?.pendingFor(
          toolCallId: toolCallId,
          conversationId: conversationId,
        ) !=
        null;
  }

  double _estimateReasoningStepHeight(
    TimelineReasoningRef reasoning, {
    required double textWidth,
    required double fontScale,
  }) {
    if (reasoning.text.isEmpty) return 0;
    var extent = _estimateCollapsedCard;
    if (!reasoning.expanded) {
      if (reasoning.loading) return extent + 100;
      return extent;
    }
    final fontSize = 13.0 * fontScale;
    final charWidth = fontSize * (0.5 + 0.55 * _wideCharRatio(reasoning.text));
    final charsPerLine = math.max(1.0, textWidth / charWidth);
    return extent +
        _wrappedLineCount(
              reasoning.text,
              charsPerLine: charsPerLine,
              codeCharsPerLine: null,
              codeLineRatio: 1.0,
              collapsedCodeLines: null,
            ) *
            (fontSize * 1.5);
  }

  /// 该估算所依据的工具卡片输入的身份标识。
  ///
  /// 流式更新会把每个 [ToolUIPart] 换成新实例，因此对象
  /// 身份就是变更信号 —— 与实时工具表同一条规则。
  int _partsEstimateSignature(List<MessagePart> parts) {
    if (parts.isEmpty) return 0;
    return Object.hashAll([for (final part in parts) identityHashCode(part)]);
  }

  int _toolEstimateSignature(List<ToolUIPart>? parts) {
    if (parts == null || parts.isEmpty) return 0;
    return Object.hashAll([for (final part in parts) identityHashCode(part)]);
  }

  /// 该估算所依据的推理输入的身份标识。
  ///
  /// 推理状态对象是原地修改的，但它们的文本每次变更都会被
  /// 换成新字符串，所以“文本身份 ＋ 展开标志”足以
  /// 区分估算依赖的每一种状态。
  int _reasoningEstimateSignature(
    stream_ctrl.ReasoningData? reasoning,
    List<stream_ctrl.ReasoningSegmentData>? segments, {
    required bool isStreaming,
  }) {
    if (reasoning == null && (segments == null || segments.isEmpty)) return 0;
    return Object.hashAll([
      isStreaming,
      if (reasoning != null) ...[
        identityHashCode(reasoning.text),
        reasoning.expanded,
        reasoning.finishedAt,
        timelineReasoningLoading(
          finishedAt: reasoning.finishedAt,
          isStreaming: isStreaming,
        ),
      ],
      if (segments != null)
        for (final segment in segments) ...[
          identityHashCode(segment.text),
          segment.expanded,
          segment.finishedAt,
          timelineReasoningLoading(
            finishedAt: segment.finishedAt,
            isStreaming: isStreaming,
          ),
        ],
    ]);
  }

  /// 按正文行数表示的渲染高度，每个硬换行分别计算。
  ///
  /// 用总长度除以 [charsPerLine] 会把空行与短行压平，
  /// 而聊天消息恰恰多是这种形状。有两类结构
  /// 会被算错：Markdown 链接只渲染标签、不渲染目标，
  /// 围栏代码块用自己的字体渲染 —— 渲染器换行时按
  /// [codeCharsPerLine] 折行，横向滚动时则每个源码行占一行
  ///（此时 [codeCharsPerLine] 为 null），每行高度是正文行的
  /// [codeLineRatio] 倍。代码块还可能被折叠到
  /// [collapsedCodeLines] 个源码行。
  double _wrappedLineCount(
    String text, {
    required double charsPerLine,
    required double? codeCharsPerLine,
    required double codeLineRatio,
    required int? collapsedCodeLines,
  }) {
    var lines = 0.0;
    var visible = 0; // rendered characters on the current line
    var fenceRows = 0.0; // rendered rows inside the open code fence
    var fenceSourceLines = 0; // hard lines inside the open code fence
    var inFence = false;
    var index = 0;

    void endLine() {
      if (inFence) {
        fenceSourceLines++;
        fenceRows += visible == 0 || codeCharsPerLine == null
            ? 1.0 // one row per source line: code scrolls sideways
            : (visible / codeCharsPerLine).ceilToDouble();
      } else {
        lines += visible == 0 ? 1.0 : (visible / charsPerLine).ceilToDouble();
      }
      visible = 0;
    }

    void endFence() {
      // 折叠会隐藏源码行，折行后的行数随之减少。
      final shown = collapsedCodeLines == null || fenceSourceLines == 0
          ? fenceRows
          : fenceRows * math.min(1.0, collapsedCodeLines / fenceSourceLines);
      lines += shown * codeLineRatio;
      fenceRows = 0;
      fenceSourceLines = 0;
    }

    // 超长消息只需要量级正确，因此扫描按字符数设预算 ——
    // 一行 1MB 的 JSON 不能整串遍历 —— 尾部按
    // 观测到的密度外推。
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
        // Markdown 链接渲染的是标签，绝不是目标地址。
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

  /// [index] 处是否是一个 ``` 围栏标记的起点。
  bool _isFenceMarker(String text, int index) {
    if (index + 2 >= text.length) return false;
    if (text.codeUnitAt(index + 1) != 0x60 ||
        text.codeUnitAt(index + 2) != 0x60) {
      return false;
    }
    return index == 0 || text.codeUnitAt(index - 1) == 0x0A;
  }

  /// 全角字符占比，采用抽样以免超长消息上开销变大。
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
        oldWidget.showProducedFiles != widget.showProducedFiles ||
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
        // 删掉被移除下标处的高度，能让每个存活槽位的实测高度
        // 仍挂在它的新下标上；否则会走下面的兜底分支，
        // 丢掉全部实测值，让列表在随后几帧重新测量整个窗口时
        // 发生漂移。
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

  /// 本帧滚动位置是否由排版阶段的定位请求接管（贴底、保持
  /// 距离、流式自动跟随）。
  /// 此时锚点恢复必须让位，而不是与它互抢。
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

  /// 记录移除后仍存活的最上方可见槽位，作为以“移除后下标空间”
  /// 表示的锚点。
  ///
  /// 当所有可见槽位都在被移除时，锚点落到下方最近的存活槽位
  ///（其内容会滑入腾出的视口）；下方没有时，
  /// 则取上方最近的存活槽位。
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
    // 滚动位置由子项实际被绘制的位置定义，
    // 而高度列表的偏移有一部分来自那些从未参与排版的行的
    // 估算高度。混用这两套坐标，会把它们累积的差值
    // 烙进对齐结果，锚点恢复的跳转会正好偏移这个误差 ——
    // 在估算占比高的历史（长推理载荷、超大消息）里，
    // 看起来就是视口跳到了一个莫名其妙的位置。
    // 因此以“已绘制偏移”为锚，
    // 只有子项尚未构建时才回退到估算偏移。
    final itemLeading =
        _paintedLeadingOffset(index) ??
        // 这里用的是 jumpToItem 同款偏移查询。在子项列表进入排版之前
        // 调用它是安全的。
        // ignore: invalid_use_of_visible_for_testing_member
        controller.getOffsetToReveal(index, 0);
    final availableAlignmentExtent = position.viewportDimension - itemExtent;
    final alignment = availableAlignmentExtent.abs() < 0.5
        ? 0.0
        : (itemLeading - position.pixels) / availableAlignmentExtent;
    return (index: index, alignment: alignment);
  }

  /// [index] 的子项实际被排版时所处的滚动偏移，
  /// 该子项当前未构建时为 null。
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

  /// 旧列表中在新列表里缺失的槽位下标；
  /// 当新列表并非“旧列表删掉若干槽位”时为 null。
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
        old.durationMs != current.durationMs ||
        _partsIdentityChanged(old.parts, current.parts);
  }

  bool _partsIdentityChanged(List<MessagePart> old, List<MessagePart> current) {
    if (identical(old, current)) return false;
    if (old.length != current.length) return true;
    for (var i = 0; i < old.length; i++) {
      if (!identical(old[i], current[i])) return true;
    }
    return false;
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

  /// 构建显示在截断位置的分隔线控件。
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
    // 条目按“系统缩放 × 聊天缩放”渲染（见 _buildMessageItem 里的
    // MediaQuery 覆盖），因此估算必须同时用到两者。
    _systemTextScale = MediaQuery.textScalerOf(context).scale(1);
    var pendingApprovals = const <PendingApprovalKey>[];
    try {
      _approvalForEstimate = context.read<ToolApprovalService>();
      pendingApprovals = context.select<ToolApprovalService, _EstimateIdSet>((
        approval,
      ) {
        return _EstimateIdSet([
          for (final req in approval.pendingRequests)
            PendingApprovalKey(
              conversationId: req.conversationId ?? '',
              toolCallId: req.toolCallId,
            ),
        ]);
      }).ids;
    } catch (_) {
      _approvalForEstimate = null;
    }
    final previousApprovals = _estimateSettings.pendingApprovals;
    _estimateSettings = _EstimateSettings(
      collapseThinking: widget.collapseThinking,
      collapseThinkingSteps: widget.collapseThinkingSteps,
      showThinkingCards: widget.showThinkingCards,
      showToolCards: widget.showToolCards,
      showToolResultSummary: widget.showToolResultSummary,
      hideToolResultImages: widget.hideToolResultImages,
      collapsedCodeLines: widget.collapsedCodeLines,
      wrapCodeBlocks: widget.wrapCodeBlocks,
      visualRegexSignature: _visualRegexEstimateSignature(widget.assistant),
      pendingApprovals: pendingApprovals,
    );
    if (!listEquals(previousApprovals, pendingApprovals)) {
      _invalidateExtentsForApprovalChange(previousApprovals, pendingApprovals);
    }
    _invalidateEstimatesIfScaleChanged();
    if (_awaitingAttachFlush && widget.listController.isAttached) {
      _scheduleAttachAwareFlush();
    }
    final presentation = _MessagePresentation(
      chatFontScale: widget.chatFontScale,
      showModelIcon: widget.showModelIcon,
      showUserAvatar: widget.showUserAvatar,
      showTokenStats: widget.showTokenStats,
      assistant: widget.assistant,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 本仓库自有：宽屏布局开关会传 null，表示不限制内容宽度，
        // 此时左右各留 0 内边距（上游这里写死了常量，读不到这个开关）。
        final horizontalPad = widget.maxContentWidth == null
            ? 0.0
            : ((constraints.maxWidth - widget.maxContentWidth!) / 2).clamp(
                0.0,
                double.infinity,
              );

        return Builder(
          builder: (context) {
            final list = SuperListView.builder(
              controller: widget.scrollController,
              listController: widget.listController,
              cacheExtent: 600,
              delayPopulatingCacheArea: false,
              addRepaintBoundaries: false,
              findChildIndexCallback: _findMessageIndexByKey,
              extentEstimation: _estimateItemExtent,
              extentPrecalculationPolicy: _extentPrecalculationPolicy,
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
                  _setDeferStreamingMessageUpdates(true);
                }
              },
              onPointerUp: (_) => _settlePointerDrag(),
              onPointerCancel: (_) => _settlePointerDrag(),
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  _setDeferStreamingMessageUpdates(true);
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
      final gap = metrics.maxScrollExtent - metrics.pixels;
      return gap <= _streamingUpdateDeferBottomTolerance;
    }
    if (!widget.scrollController.hasClients) return true;
    final position = widget.scrollController.position;
    final gap = position.maxScrollExtent - position.pixels;
    return gap <= _streamingUpdateDeferBottomTolerance;
  }

  void _setDeferStreamingMessageUpdates(bool value) {
    if (_deferStreamingMessageUpdates.value == value) return;
    if (value) {
      _captureDeferredStreamingHolds();
    } else {
      _deferredStreamingHolds.clear();
    }
    _deferStreamingMessageUpdates.value = value;
  }

  void _captureDeferredStreamingHolds() {
    _deferredStreamingHolds.clear();
    final notifier = widget.streamingContentNotifier;
    if (notifier == null) return;
    for (final message in widget.messages) {
      if (!message.isStreaming || !notifier.hasNotifier(message.id)) {
        continue;
      }
      final data = notifier.getNotifier(message.id).value;
      _deferredStreamingHolds[message.id] =
          data.content.isEmpty && message.content.isNotEmpty
          ? StreamingContentData(
              content: message.content,
              totalTokens: data.totalTokens,
              parts: data.parts,
              reasoningText: data.reasoningText,
              reasoningStartAt: data.reasoningStartAt,
              reasoningFinishedAt: data.reasoningFinishedAt,
              contentSplitOffsets: data.contentSplitOffsets,
              reasoningCountAtSplit: data.reasoningCountAtSplit,
              toolCountAtSplit: data.toolCountAtSplit,
              toolPartsVersion: data.toolPartsVersion,
              uiVersion: data.uiVersion,
              promptTokens: data.promptTokens,
              completionTokens: data.completionTokens,
              cachedTokens: data.cachedTokens,
              durationMs: data.durationMs,
              retryStatus: data.retryStatus,
            )
          : data;
    }
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
    _setDeferStreamingMessageUpdates(false);
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

      // 在整个重建与锚点恢复过程中保持分页锁定。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _historyLoadScheduled = false;
    });
  }

  Widget _buildMessageItem(
    BuildContext context, {
    required int index,
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

    // 本仓库用真树模型：分支不是“同一条消息的多个版本”，而是树上同一
    // 位置的兄弟节点。下面四个变量都由当前消息的兄弟分支推导，
    // “版本”相关的语义与之等价（同一位置可选几条）。
    final siblingBranchIds =
        widget.siblingBranchIdsByMessageId[message.id] ?? const <String>[];
    final useBranchSelector = siblingBranchIds.length > 1;
    final canDeleteMessageAndFollowing =
        !useBranchSelector &&
        widget.messageIdsWithChildren.contains(message.id);
    final selectedBranchIndex = useBranchSelector
        ? siblingBranchIds.indexOf(widget.activeBranchId ?? '')
        : 0;
    final messageSuggestions =
        !widget.selecting &&
            model.isLatestCompleteAssistant &&
            widget.onSuggestionTap != null
        ? widget.suggestions
        : const <String>[];

    // 判断这是否是一条应当走 ValueListenableBuilder 的流式消息
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
                Widget buildContent(bool isProcessingFiles) => Builder(
                  builder: (context) {
                    final baseMediaQuery = context
                        .getInheritedWidgetOfExactType<MediaQuery>();
                    final baseData = baseMediaQuery?.data;
                    final data = baseData ?? MediaQuery.of(context);
                    final textScale = data.textScaler.scale(1);
                    return MediaQuery(
                      // 保留聊天字号缩放，但不因键盘内边距变化而重建。
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
                              siblingBranchIds: siblingBranchIds,
                              selectedBranchIndex: selectedBranchIndex,
                              useBranchSelector: useBranchSelector,
                              canDeleteMessageAndFollowing:
                                  canDeleteMessageAndFollowing,
                              isProcessingFiles: isProcessingFiles,
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
                              siblingBranchIds: siblingBranchIds,
                              selectedBranchIndex: selectedBranchIndex,
                              useBranchSelector: useBranchSelector,
                              canDeleteMessageAndFollowing:
                                  canDeleteMessageAndFollowing,
                              isProcessingFiles: isProcessingFiles,
                              suggestions: messageSuggestions,
                              presentation: presentation,
                            ),
                    );
                  },
                );

                // 只有拥有该指示器的那条助手消息会监听，
                // 因此解析过程不会重建时间线的其余部分。
                final processingFilesMessageId =
                    widget.processingFilesMessageId;
                Widget content =
                    message.role == 'assistant' &&
                        processingFilesMessageId != null
                    ? ValueListenableBuilder<String?>(
                        valueListenable: processingFilesMessageId,
                        builder: (context, processingId, _) =>
                            buildContent(processingId == message.id),
                      )
                    : buildContent(false);

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

    // 动画器包在条目的 RepaintBoundary 外层，使淡出只重新合成
    // 该边界已缓存的图层，而不是每帧重绘整棵
    // 消息子树。
    return _SlotRemovalAnimator(
      key: ValueKey<String>(model.slotId),
      removing: widget.removingSlotIds.contains(model.slotId),
      child: item,
    );
  }

  /// 构建使用 ValueListenableBuilder 的流式消息控件，
  /// 以避免流式期间整页重建。
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
    required List<String> siblingBranchIds,
    required int selectedBranchIndex,
    required bool useBranchSelector,
    required bool canDeleteMessageAndFollowing,
    required bool isProcessingFiles,
    required List<String> suggestions,
    required _MessagePresentation presentation,
  }) {
    return _StreamingMessageDataGate(
      notifier: widget.streamingContentNotifier!.getNotifier(message.id),
      deferUpdates: _deferStreamingMessageUpdates,
      deferredHold: _deferredStreamingHolds[message.id],
      builder: (context, data, deferUpdates) {
        final painted = deferUpdates
            ? (_deferredStreamingHolds[message.id] ?? data)
            : data;
        // 有流式内容就用它，否则回退到消息自身内容
        final displayContent = painted.content.isNotEmpty
            ? painted.content
            : message.content;
        final displayTokens = painted.totalTokens > 0
            ? painted.totalTokens
            : message.totalTokens;

        // 用流式内容构造一条改过的消息
        final streamingMessage = message.copyWith(
          parts: painted.parts,
          content: painted.parts == null ? displayContent : null,
          totalTokens: displayTokens,
          promptTokens: painted.promptTokens,
          completionTokens: painted.completionTokens,
          cachedTokens: painted.cachedTokens,
          durationMs: painted.durationMs,
        );

        // 用流式数据更新推理文本，同时保留 r 里的展开状态
        // 这样流式期间用户手动切换的展开状态不会被重置
        stream_ctrl.ReasoningData? streamingReasoning = r;
        if (painted.reasoningText != null &&
            painted.reasoningText!.isNotEmpty) {
          streamingReasoning = stream_ctrl.ReasoningData()
            ..text = painted.reasoningText!
            ..startAt = painted.reasoningStartAt ?? r?.startAt
            ..finishedAt = painted.reasoningFinishedAt ?? r?.finishedAt
            ..expanded = r?.expanded ?? false;
        }

        // 用 RepaintBoundary 包住，隔离重绘、不影响其他控件
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
            siblingBranchIds: siblingBranchIds,
            selectedBranchIndex: selectedBranchIndex,
            useBranchSelector: useBranchSelector,
            canDeleteMessageAndFollowing: canDeleteMessageAndFollowing,
            isProcessingFiles: isProcessingFiles,
            suggestions: suggestions,
            presentation: presentation,
            enableStreamingTextMotion: !deferUpdates,
            contentSplitOffsets: painted.contentSplitOffsets,
            reasoningCountAtSplit: painted.reasoningCountAtSplit,
            toolCountAtSplit: painted.toolCountAtSplit,
            retryStatus: painted.retryStatus,
          ),
        );
      },
    );
  }

  /// 构建真正的 ChatMessageWidget，并带上它的全部属性。
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
    required List<String> siblingBranchIds,
    required int selectedBranchIndex,
    required bool useBranchSelector,
    required bool canDeleteMessageAndFollowing,
    required bool isProcessingFiles,
    required List<String> suggestions,
    required _MessagePresentation presentation,
    bool enableStreamingTextMotion = true,
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
    RetryStatus? retryStatus,
  }) {
    final currentIdx = useBranchSelector ? selectedBranchIndex : 0;
    // “删除所有分支”只在当前节点确实还有子节点时才有意义：
    // 叶子节点删掉整条分支就等同于删掉自己，入口应收起。
    final canDeleteAllVersions =
        useBranchSelector && widget.messageIdsWithChildren.contains(message.id);
    return ChatMessageWidget(
      message: message,
      enableStreamingTextMotion: enableStreamingTextMotion,
      // 上游把“分支切换”命名为 version（同一功能的两个叫法），
      // 这里传的是本仓库树模型算出的索引与前后切换回调，语义不变。
      versionIndex: currentIdx < 0 ? 0 : currentIdx,
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
      showUserAvatar: presentation.showUserAvatar,
      showTokenStats: presentation.showTokenStats,
      canDeleteMessageAndFollowing: canDeleteMessageAndFollowing,
      hideStreamingIndicator:
          isProcessingFiles ||
          (widget.isPinnedIndicatorActive &&
              (message.id == widget.pinnedStreamingMessageId)),
      retryStatus: retryStatus,
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
      // 本仓库自有：用户消息的快捷“删除”是“删除这条及之后”，
      // 且只在树模型允许时才出现。
      onDelete: message.role == 'user' && canDeleteMessageAndFollowing
          ? () => widget.onDeleteMessageAndFollowing?.call(
              message,
              widget.byGroup,
            )
          : null,
      onMore: () async {
        final action = await showMessageMoreSheet(
          context,
          message,
          canDeleteAllVersions: canDeleteAllVersions,
          canDeleteCurrentBranch: siblingBranchIds.length > 1,
          canDeleteMessageNode: siblingBranchIds.length > 1,
          canDeleteMessageOnly: !useBranchSelector,
          canDeleteMessageAndFollowing: canDeleteMessageAndFollowing,
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
            MessageMoreAction.conversationForkActiveBranchOnly) {
          await widget.onConversationFork?.call(
            message,
            ConversationForkMode.activeBranchOnly,
          );
        } else if (action ==
            MessageMoreAction.conversationForkPreserveBranches) {
          await widget.onConversationFork?.call(
            message,
            ConversationForkMode.preserveBranches,
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
          ? (contentSplitOffsets ?? widget.contentSplits[message.id]?.offsets)
          : null,
      reasoningCountAtSplit: message.role == 'assistant'
          ? (reasoningCountAtSplit ??
                widget.contentSplits[message.id]?.reasoningCounts)
          : null,
      toolCountAtSplit: message.role == 'assistant'
          ? (toolCountAtSplit ?? widget.contentSplits[message.id]?.toolCounts)
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
                      loading: timelineReasoningLoading(
                        finishedAt: entry.value.finishedAt,
                        isStreaming: message.isStreaming,
                      ),
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
      onInlineImageAspect: (imageKey, aspectRatio) {
        _onInlineImageAspect(message.id, imageKey, aspectRatio);
      },
    );
  }

  /// 被隐藏的独立工具行是否仍占高度。
  ///
  /// 与 `_shouldShowToolCard` 对 `role == 'tool'` 消息的判定一致：
  /// 追问用户的卡片始终可见，以免生成被阻塞。待审批卡片
  /// 不适用 —— 那些行从不以 loading 状态构建。
  bool _hiddenStandaloneToolMessageRemainsVisible(String content) {
    try {
      final obj = jsonDecode(content);
      if (obj is Map) {
        return (obj['tool'] ?? '').toString() == LocalToolNames.askUser;
      }
    } catch (_) {}
    return false;
  }

  int _visualRegexEstimateSignature(Assistant? assistant) {
    if (assistant == null || assistant.regexRules.isEmpty) return 0;
    return Object.hashAll([
      for (final rule in assistant.regexRules)
        Object.hash(
          rule.enabled,
          rule.pattern,
          rule.replacement,
          rule.visualOnly,
          rule.replaceOnly,
          Object.hashAll(rule.scopes.map((scope) => scope.index)),
        ),
    ]);
  }
}

final class _EstimateIdSet {
  const _EstimateIdSet(this.ids);
  final List<PendingApprovalKey> ids;

  @override
  bool operator ==(Object other) =>
      other is _EstimateIdSet && listEquals(other.ids, ids);

  @override
  int get hashCode => Object.hashAll(ids);
}

/// 会改变消息渲染高度的显示设置。
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
    required this.visualRegexSignature,
    required this.pendingApprovals,
  });

  /// 已结束的思考块是否渲染为折叠卡片。
  final bool collapseThinking;

  /// 每个时间线区块是否只保留最后两步加一个展开入口。
  final bool collapseThinkingSteps;

  /// 思考过程卡片是否计入估算高度。
  final bool showThinkingCards;

  /// 工具调用卡片是否计入估算高度。
  final bool showToolCards;

  /// 折叠的工具卡片是否也显示一行简短结果摘要。
  final bool showToolResultSummary;

  /// 工具结果的图片缩略图是否藏在卡片下。
  final bool hideToolResultImages;

  /// 长代码块折叠后的行数；保持展开时为 null。
  final int? collapsedCodeLines;

  /// 代码块是否换行而不是横向滚动。
  final bool wrapCodeBlocks;

  /// 估算变换所用“助手视觉正则规则”的身份标识。
  final int visualRegexSignature;

  /// 在 [build] 期间快照的待审批项，按会话限定作用域。
  ///
  /// 用 List 是为了让两个无作用域的同 id 请求保持区分；[Set] 会把
  /// 它们合并，导致估算认为是待审批而渲染器认为不是。
  final List<PendingApprovalKey> pendingApprovals;

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
      other.visualRegexSignature == visualRegexSignature &&
      listEquals(other.pendingApprovals, pendingApprovals);

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
    visualRegexSignature,
    Object.hashAll(pendingApprovals),
  );
}

/// 一份带记忆的高度估算，连同它所依据的全部输入。
final class _ExtentEstimate {
  const _ExtentEstimate({
    required this.content,
    required this.crossAxisExtent,
    required this.fontScale,
    required this.settings,
    required this.reasoningSignature,
    required this.toolSignature,
    required this.partsSignature,
    required this.streamingSignature,
    required this.extent,
  });

  final String content;
  final double crossAxisExtent;
  final double fontScale;
  final _EstimateSettings settings;
  final int reasoningSignature;
  final int toolSignature;
  final int partsSignature;
  final int streamingSignature;
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

/// 在时间线槽位被删除前先淡出再收起。
///
/// 先淡出，让消息在视觉上消失；再收起高度，
/// 使相邻消息拼接起来。槽位数据要等到
/// [ChatLayoutConstants.slotRemovalAnimationDuration] 之后才移除，
/// 那时它已是零高度，移除不可见。
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
      // 删除被中止了（槽位通常直接卸载，根本走不到这里），
      // 因此把消息恢复回来。该元素的重建本来就在进行中，
      // 所以不需要 setState。
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
    // 即使空闲，这层包装链也一直存在：动画开始时再换控件类型
    // 会改变父级关系，从而重建整棵消息子树，
    // 对超大消息来说就是肉眼可见的卡顿。
    // 所有包装层在空闲取值下都是直通。
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
    this.deferredHold,
    required this.builder,
  });

  final ValueNotifier<StreamingContentData> notifier;
  final ValueListenable<bool> deferUpdates;
  final StreamingContentData? deferredHold;
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
    _deferUpdates = widget.deferUpdates.value;
    final hold = widget.deferredHold;
    _visibleData = _deferUpdates && hold != null ? hold : widget.notifier.value;
    super.initState();
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
  Widget build(BuildContext context) {
    return widget.builder(context, _visibleData, _deferUpdates);
  }
}

/// 气泡形状的微光骨架屏，仅在冷启动首窗加载进行中
/// 且列表还没有消息时显示。
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

/// 合并那些在锁定状态下无法执行的 SuperList 高度失效请求。
///
/// 在刷新观察到控制器未锁定且已挂载之前，ID 一直排队。
/// 同一时刻最多只安排一个下一帧回调。
@visibleForTesting
class ToolExtentInvalidationQueue {
  final Set<String> _pending = <String>{};
  var _scheduled = false;

  @visibleForTesting
  Set<String> get pendingIds => Set<String>.unmodifiable(_pending);

  @visibleForTesting
  bool get isScheduled => _scheduled;

  /// 调用方应当安排下一帧刷新时返回 true。
  bool enqueue(String id) {
    _pending.add(id);
    if (_scheduled) return false;
    _scheduled = true;
    return true;
  }

  /// 让 [id] 继续排队，但不把“已安排刷新”置位。
  ///
  /// 用于列表控制器已分离时，使之后的挂载能把队列排空，
  /// 而无需每帧空转。
  void retain(String id) {
    _pending.add(id);
  }

  ({List<String> ids, bool reschedule}) takeForFlush({
    required bool mounted,
    required bool isAttached,
    required bool isLocked,
  }) {
    _scheduled = false;
    if (!mounted || !isAttached) {
      return (ids: const <String>[], reschedule: false);
    }
    if (isLocked) {
      if (_pending.isEmpty) {
        return (ids: const <String>[], reschedule: false);
      }
      _scheduled = true;
      return (ids: const <String>[], reschedule: true);
    }
    final ids = List<String>.of(_pending);
    _pending.clear();
    return (ids: ids, reschedule: false);
  }
}

/// 聊天消息列表的范围预计算策略。
///
/// 恒为启用：屏幕外的消息高度必须先有值，列表才能算出可滚动总长度，
/// 而估算值天然带有误差。本策略让列表在布局预算内逐帧把屏幕外的消息
/// 真实排版一次，实测结果随即替换估算值，使账面总高与实际总高一致。
class ChatExtentPrecalculationPolicy extends ExtentPrecalculationPolicy {
  @override
  bool shouldPrecalculateExtents(ExtentPrecalculationContext context) => true;
}
