import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

// ============================================================================
// 自动跟随 ScrollController / ScrollPosition
// ============================================================================

/// 在布局期间自动将位置固定到 maxScrollExtent 的 ScrollController。
///
/// 当 [shouldAutoFollow] 返回 true 时，创建的 [ScrollPosition] 会在
/// [applyContentDimensions] 内，也就是在绘制之前，把像素值修正为
/// maxScrollExtent，因此内容增长和滚动位置更新之间没有视觉延迟。
/// 这消除了帧后 `jumpTo(max)` 无法避免的 1 帧闪烁。
class ChatAutoFollowScrollController extends ScrollController {
  /// 布局期间检查的回调，用于决定是否自动跟随底部。
  bool Function() shouldAutoFollow = () => false;

  /// 打开会话窗口时使用的一帧定位请求。
  ///
  /// 与帧后 `jumpTo` 不同，它在新列表布局期间由滚动位置消费，
  /// 因此旧会话偏移绝不会为新会话绘制。
  bool _positionAtBottomDuringLayout = false;
  int _layoutBottomRequest = 0;
  bool _preserveDistanceFromEndDuringLayout = false;
  double _preservedDistanceFromEnd = 0;
  int _layoutDistanceRequest = 0;

  /// 当前是否已武装一帧布局定位请求。
  ///
  /// 当它处于活动状态时，它拥有即将到来布局的滚动位置，
  /// 因此列表调度的锚点恢复跳转必须让位。
  bool get hasActiveLayoutPositioningRequest =>
      _positionAtBottomDuringLayout || _preserveDistanceFromEndDuringLayout;

  int requestPositionAtBottomDuringLayout() {
    _positionAtBottomDuringLayout = true;
    return ++_layoutBottomRequest;
  }

  void finishPositionAtBottomDuringLayout(int request) {
    if (request == _layoutBottomRequest) {
      _positionAtBottomDuringLayout = false;
    }
  }

  int? requestPreserveDistanceFromEndDuringLayout() {
    if (!hasClients || positions.length != 1) return null;
    final position = this.position;
    _preservedDistanceFromEnd = position.maxScrollExtent - position.pixels;
    _preserveDistanceFromEndDuringLayout = true;
    return ++_layoutDistanceRequest;
  }

  void finishPreserveDistanceFromEndDuringLayout(int request) {
    if (request == _layoutDistanceRequest) {
      _preserveDistanceFromEndDuringLayout = false;
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _AutoFollowScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      controller: this,
    );
  }
}

class _AutoFollowScrollPosition extends ScrollPositionWithSingleContext {
  _AutoFollowScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.controller,
  });

  final ChatAutoFollowScrollController controller;

  _IndexedScrollActivity beginIndexedAnimation(VoidCallback onCanceled) {
    final indexedActivity = _IndexedScrollActivity(this, onCanceled);
    beginActivity(indexedActivity);
    return indexedActivity;
  }

  bool updateIndexedAnimation(
    _IndexedScrollActivity indexedActivity,
    double value,
  ) {
    if (!identical(activity, indexedActivity)) return false;
    setPixels(value.clamp(minScrollExtent, maxScrollExtent));
    return true;
  }

  void finishIndexedAnimation(_IndexedScrollActivity indexedActivity) {
    if (identical(activity, indexedActivity)) indexedActivity.finish();
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final result = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    // 布局阶段也要用 userScrollDirection 保护，因为它通过滚动活动
    // 立即更新，早于设置 _isUserScrolling 的滚动控制器监听器。
    // 没有此检查，correctPixels 会在一帧内覆盖用户拖动，
    // 产生“卡住/无法向上滚动”的感觉。
    final shouldPositionAtBottom =
        controller._positionAtBottomDuringLayout ||
        (controller.shouldAutoFollow() &&
            userScrollDirection == ScrollDirection.idle);
    if (shouldPositionAtBottom) {
      final gap = this.maxScrollExtent - pixels;
      if (gap > 0.5) {
        correctPixels(this.maxScrollExtent);
        return false; // 强制用修正后的位置重新布局视口
      }
    }
    if (controller._preserveDistanceFromEndDuringLayout &&
        userScrollDirection == ScrollDirection.idle) {
      final target =
          (this.maxScrollExtent - controller._preservedDistanceFromEnd).clamp(
            this.minScrollExtent,
            this.maxScrollExtent,
          );
      if ((target - pixels).abs() > 0.5) {
        correctPixels(target);
        return false;
      }
    }
    return result;
  }
}

/// 针对索引目标的单一连续滚动活动；当目标进入 SuperListView
/// 的缓存区域时，其测量偏移可能变化。
class _IndexedScrollActivity extends ScrollActivity {
  _IndexedScrollActivity(super.delegate, this._onCanceled);

  final VoidCallback _onCanceled;
  bool _finishing = false;

  void finish() {
    if (_finishing) return;
    _finishing = true;
    delegate.goIdle();
  }

  @override
  bool get shouldIgnorePointer => true;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => 0;

  @override
  void dispose() {
    if (!_finishing) _onCanceled();
    super.dispose();
  }
}

// ============================================================================
// ChatScrollController
// ============================================================================

/// 管理聊天主页滚动行为的控制器。
///
/// 此控制器负责：
/// - 流式处理期间自动滚动到底部（通过自定义 ScrollPosition 实现零延迟）
/// - 相邻消息导航跳转
/// - 通过可变高度索引按 ID 滚动到指定消息
/// - 滚动状态监控（检测用户滚动）
/// - 导航按钮可见状态
class ChatScrollController {
  ChatScrollController({
    required this._scrollController,
    required this._onStateChanged,
    required this._getAutoScrollEnabled,
    required this._getAutoScrollIdleSeconds,
    this._getTopRevealInset,
    this.isGenerating,
  }) {
    final scrollController = _scrollController;
    _messageListController = ListController(
      onDetached: _cancelIndexedNavigationForDetach,
    );
    _scrollController.addListener(_onScrollControllerChanged);

    // 连接自动跟随回调，实现零延迟底部固定
    if (scrollController is ChatAutoFollowScrollController) {
      scrollController.shouldAutoFollow = () =>
          _getAutoScrollEnabled() &&
          (isGenerating?.call() ?? false) &&
          _autoStickToBottom &&
          !_isUserScrolling &&
          !_explicitBottomAnimationInProgress;
    }
  }

  final ScrollController _scrollController;
  final VoidCallback _onStateChanged;
  final bool Function() _getAutoScrollEnabled;
  final int Function() _getAutoScrollIdleSeconds;
  final double Function()? _getTopRevealInset;
  final bool Function()? isGenerating;

  /// 与消息列表共享的索引和高度状态。
  late final ListController _messageListController;

  // ============================================================================
  // 状态字段
  // ============================================================================

  /// 是否显示跳到底部按钮。
  bool _showJumpToBottom = false;
  bool get showJumpToBottom => _showJumpToBottom;

  /// 导航按钮是否应可见（基于滚动活动）。
  bool _showNavButtons = false;
  bool get showNavButtons => _showNavButtons;

  /// 自动隐藏导航按钮的计时器。
  Timer? _navButtonsHideTimer;
  static const int _navButtonsHideDelayMs = 2000;

  /// 用户是否正在主动滚动。
  bool _isUserScrolling = false;
  bool get isUserScrolling => _isUserScrolling;

  /// 自动滚动是否应保持在底部。
  bool _autoStickToBottom = true;
  bool get autoStickToBottom => _autoStickToBottom;

  /// 检测用户滚动结束的计时器。
  Timer? _userScrollTimer;

  /// 当前为下一帧底部滚动排队的请求。
  int? _scheduledBottomScrollRequest;

  /// 受驱动滚动和布局时的尾部固定绝不能在同一帧中拥有像素。
  bool _explicitBottomAnimationInProgress = false;
  bool get explicitBottomAnimationInProgress =>
      _explicitBottomAnimationInProgress;
  int _bottomScrollRequest = 0;
  int _deferredBottomRequest = 0;
  int _indexedNavigationRequest = 0;
  AnimationController? _indexedAnimationController;
  _IndexedScrollActivity? _indexedScrollActivity;

  /// 链式相邻消息导航的锚点。
  String? _lastJumpUserMessageId;
  String? get lastJumpUserMessageId => _lastJumpUserMessageId;

  /// “接近底部”检测的容差。
  static const double _autoScrollSnapTolerance = 56.0;

  // ============================================================================
  // 公共 Getter
  // ============================================================================

  /// 获取底层滚动控制器。
  ScrollController get scrollController => _scrollController;

  /// 获取附着到消息列表的索引控制器。
  ListController get messageListController => _messageListController;

  /// 检查滚动控制器是否已附着客户端。
  bool get hasClients => _scrollController.hasClients;

  // ============================================================================
  // 滚动状态检测
  // ============================================================================

  /// 检查滚动位置是否接近底部。
  bool isNearBottom([double tolerance = _autoScrollSnapTolerance]) {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return (pos.maxScrollExtent - pos.pixels) <= tolerance;
  }

  /// 在视口缩小时（例如软键盘打开时），保持已对齐底部的移动时间线固定。
  ///
  /// 必须在新视口尺寸布局前请求；否则旧像素偏移会在新底部上方
  /// 绘制一帧。
  bool pinBottomDuringViewportResizeIfNeeded() {
    if (!isNearBottom(24)) return false;
    positionAtBottomOnNextLayout();
    return true;
  }

  /// 检查滚动视图是否有足够内容可滚动。
  ///
  /// [minExtent] - 视为可滚动的最小滚动范围（默认：56.0）。
  bool hasEnoughContentToScroll([double minExtent = 56.0]) {
    if (!_scrollController.hasClients) return false;
    return _scrollController.position.maxScrollExtent >= minExtent;
  }

  /// 根据当前位置刷新自动保持底部状态。
  void refreshAutoStickToBottom() {
    try {
      final nearBottom = isNearBottom();
      if (!nearBottom) {
        _autoStickToBottom = false;
      } else if (!_isUserScrolling) {
        final enabled = _getAutoScrollEnabled();
        if (enabled || _autoStickToBottom) {
          _autoStickToBottom = true;
        }
      }
    } catch (_) {}
  }

  /// 处理滚动控制器变化（由滚动监听器调用）。
  void _onScrollControllerChanged() {
    try {
      if (!_scrollController.hasClients) return;
      final autoScrollEnabled = _getAutoScrollEnabled();

      // 仅在不在底部附近时显示
      final atBottom = isNearBottom(24);
      if (!atBottom) {
        _autoStickToBottom = false;
      } else if (_isUserScrolling) {
        // 用户主动滚动回底部时立即重新启用自动跟随，
        // 使流式内容无需等待空闲计时器就能继续固定。
        _isUserScrolling = false;
        _userScrollTimer?.cancel();
        _autoStickToBottom = true;
      } else if (autoScrollEnabled || _autoStickToBottom) {
        _autoStickToBottom = true;
      }
      final shouldShow = !atBottom;
      if (_showJumpToBottom != shouldShow) {
        _showJumpToBottom = shouldShow;
        _onStateChanged();
      }
    } catch (_) {}
  }

  /// 记录来自真实指针、滚轮或键盘输入的滚动意图。
  /// 程序化位置变化绝不能调用此方法。
  void handleUserScrollIntent() {
    _cancelProgrammaticNavigation();
    _isUserScrolling = true;
    _autoStickToBottom = false;
    _lastJumpUserMessageId = null;
    if (!_showNavButtons) {
      _showNavButtons = true;
      _onStateChanged();
    }
    _resetNavButtonsHideTimer();
    _userScrollTimer?.cancel();
    final secs = _getAutoScrollIdleSeconds();
    _userScrollTimer = Timer(Duration(seconds: secs), () {
      _isUserScrolling = false;
      refreshAutoStickToBottom();
      _onStateChanged();
    });
  }

  /// 重置导航按钮的自动隐藏计时器。
  void _resetNavButtonsHideTimer() {
    _navButtonsHideTimer?.cancel();
    _navButtonsHideTimer = Timer(
      const Duration(milliseconds: _navButtonsHideDelayMs),
      () {
        if (_showNavButtons) {
          _showNavButtons = false;
          _onStateChanged();
        }
      },
    );
  }

  /// 手动显示导航按钮（例如用户点击按钮时）。
  void revealNavButtons() {
    if (!_showNavButtons) {
      _showNavButtons = true;
      _onStateChanged();
    }
    _resetNavButtonsHideTimer();
  }

  /// 立即隐藏导航按钮。
  void hideNavButtons() {
    _navButtonsHideTimer?.cancel();
    if (_showNavButtons) {
      _showNavButtons = false;
      _onStateChanged();
    }
  }

  // ============================================================================
  // 滚动到底部方法
  // ============================================================================

  /// 在下一次绘制前将新打开的会话定位到其尾部。
  ///
  /// RikkaHub 使用等效的 `requestScrollToItem` 操作：初始位置参与布局，
  /// 而不是在之后修正可见帧。该标志在整个帧期间保持活动，
  /// 因为惰性视口可能在布局期间多次细化其最大范围。
  void positionAtBottomOnNextLayout() {
    _cancelProgrammaticNavigation(stopDrivenScroll: true);
    _lastJumpUserMessageId = null;
    _isUserScrolling = false;
    _userScrollTimer?.cancel();
    _autoStickToBottom = true;
    final controller = _scrollController;
    if (controller is! ChatAutoFollowScrollController) {
      _scheduleExplicitScrollToBottom(animate: false);
      return;
    }
    final request = controller.requestPositionAtBottomDuringLayout();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.finishPositionAtBottomDuringLayout(request);
    });
  }

  /// 在切换后的会话显示前解析真实索引尾部。
  ///
  /// 惰性列表的首个 maxScrollExtent 仍可能基于估算项高度。
  /// RikkaHub 通过直接请求最后一项来避免把该估算值当作目标；
  /// 此方法执行等效的索引定位，并等待尾部范围变为具体值。
  Future<void> settleAtBottomBeforeReveal() async {
    _cancelProgrammaticNavigation(stopDrivenScroll: true);
    _lastJumpUserMessageId = null;
    _isUserScrolling = false;
    _userScrollTimer?.cancel();
    _autoStickToBottom = true;

    for (var pass = 0; pass < 3; pass++) {
      if (_scrollController.hasClients && _messageListController.isAttached) {
        break;
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!_scrollController.hasClients) return;

    final request = ++_bottomScrollRequest;
    await _animateToBottom(animate: false, request: request);
  }

  /// 滚动到列表底部。
  ///
  /// [animate] - 是否动画滚动（默认：true）。
  void scrollToBottom({bool animate = true}) {
    _autoStickToBottom = true;
    final generating = isGenerating?.call() ?? false;
    _scheduleExplicitScrollToBottom(animate: animate && !generating);
  }

  /// 强制滚动到底部（用于用户显式点击按钮时）。
  void forceScrollToBottom({bool animate = true}) {
    _cancelProgrammaticNavigation(stopDrivenScroll: true);
    _isUserScrolling = false;
    _userScrollTimer?.cancel();
    _lastJumpUserMessageId = null;
    revealNavButtons();
    _autoStickToBottom = true;
    _scheduleExplicitScrollToBottom(animate: animate);
  }

  /// 切换主题/会话后在重建后强制滚动。
  void forceScrollToBottomSoon({
    bool animate = true,
    Duration postSwitchDelay = const Duration(milliseconds: 220),
  }) {
    _isUserScrolling = false;
    _userScrollTimer?.cancel();
    final request = ++_deferredBottomRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (request == _deferredBottomRequest) {
        scrollToBottom(animate: animate);
      }
    });
    Future.delayed(postSwitchDelay, () {
      if (request == _deferredBottomRequest) {
        scrollToBottom(animate: animate);
      }
    });
  }

  /// 生成结束后，如果用户仍在跟随则固定到底部。
  ///
  /// 布局阶段的自动跟随需要 [isGenerating]，而最终消息控件
  /// 被换入并通常增高时它已经为 false。
  void stickToBottomAfterGeneration() {
    if (!_getAutoScrollEnabled()) return;
    if (!_autoStickToBottom || _isUserScrolling) return;
    // 使用动画：用户正在看此位置，立即跳转会显得像闪烁，
    // 而短暂缓动滚动会像回复正在就位。
    scrollToBottomSoon(animate: true);
  }

  /// 确保在控件树切换后滚动仍到达底部。
  void scrollToBottomSoon({bool animate = true}) {
    final request = ++_deferredBottomRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (request == _deferredBottomRequest) {
        scrollToBottom(animate: animate);
      }
    });
    Future.delayed(const Duration(milliseconds: 120), () {
      // 重试用于使帧后尝试失效的控件树切换；此处重启正在进行的动画
      // 会造成可见的速度不连续。
      if (request == _deferredBottomRequest &&
          !_explicitBottomAnimationInProgress) {
        scrollToBottom(animate: animate);
      }
    });
  }

  /// 条件满足时自动滚动到底部（从 onStreamTick 调用）。
  ///
  /// 使用 [ChatAutoFollowScrollController] 时，自定义 [ScrollPosition]
  /// 会在布局期间自动处理底部固定。此方法保留为边界情况的轻量兜底
  /// （例如普通 ScrollController）。
  void autoScrollToBottomIfNeeded() {
    final enabled = _getAutoScrollEnabled();
    if (!enabled || !_autoStickToBottom) return;
    // 使用自定义 ScrollPosition 时，底部固定发生在
    // applyContentDimensions 中（布局期间、绘制之前）。
    // 流式路径不需要帧后回调。
    // 仅为普通 ScrollController 的兜底安排显式跳转。
    if (_scrollController is! ChatAutoFollowScrollController) {
      _scheduleExplicitScrollToBottom(animate: false);
    }
  }

  /// 调度显式滚动到底部（通过帧后回调批量处理）。
  ///
  /// 用于用户触发的“到底部”，并在自定义 [ScrollPosition] 不可用时
  /// 作为流式自动滚动的兜底。
  void _scheduleExplicitScrollToBottom({bool animate = true}) {
    final request = ++_bottomScrollRequest;
    _scheduledBottomScrollRequest = request;
    _explicitBottomAnimationInProgress =
        animate && _scrollController.hasClients;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_scheduledBottomScrollRequest == request) {
        _scheduledBottomScrollRequest = null;
      }
      if (request != _bottomScrollRequest) return;
      await _animateToBottom(animate: animate, request: request);
    });
  }

  /// 动画滚动或跳转到滚动视图底部。
  ///
  /// 用于显式滚动到底部请求（用户触发的按钮、会话切换等）。
  /// 流式自动滚动改由自定义 [ScrollPosition] 处理。
  Future<void> _animateToBottom({
    bool animate = true,
    required int request,
  }) async {
    try {
      if (request != _bottomScrollRequest || !_scrollController.hasClients) {
        return;
      }
      _explicitBottomAnimationInProgress = false;

      // 防止在控制器仍同时附着于旧会话和新会话时使用它。
      // 保持此调用可等待，以便在显示前完成稳定。
      if (_scrollController.positions.length != 1) {
        await WidgetsBinding.instance.endOfFrame;
        if (request != _bottomScrollRequest ||
            _scrollController.positions.length != 1) {
          return;
        }
      }
      final pos = _scrollController.position;
      final hasIndexedTail =
          _messageListController.isAttached &&
          _messageListController.numberOfItems > 0;
      if (hasIndexedTail) {
        final lastIndex = _messageListController.numberOfItems - 1;
        final target = pos.maxScrollExtent;
        if ((target - pos.pixels).abs() <= 0.5) {
          _updateJumpToBottomVisibility(false);
          _autoStickToBottom = true;
          return;
        }
        if (animate) {
          _explicitBottomAnimationInProgress = true;
          try {
            await _animateToMessageIndex(
              index: lastIndex,
              alignment: 1,
              bottomRequest: request,
            );
          } finally {
            if (request == _bottomScrollRequest) {
              _explicitBottomAnimationInProgress = false;
            }
          }
          if (request != _bottomScrollRequest) return;
          _updateJumpToBottomVisibility(false);
          _autoStickToBottom = true;
          return;
        }
        for (var pass = 0; pass < 4; pass++) {
          if (request != _bottomScrollRequest ||
              !_scrollController.hasClients ||
              !_messageListController.isAttached ||
              lastIndex >= _messageListController.numberOfItems) {
            return;
          }
          _messageListController.jumpToItem(
            index: lastIndex,
            scrollController: _scrollController,
            alignment: 1,
          );
          await WidgetsBinding.instance.endOfFrame;
          if (request != _bottomScrollRequest) return;
          final visible = _messageListController.visibleRange;
          final extentIsEstimated = _messageListController
              .extentForIndex(lastIndex)
              .$2;
          if (!extentIsEstimated &&
              visible != null &&
              visible.$1 <= lastIndex &&
              visible.$2 >= lastIndex &&
              pass > 0) {
            break;
          }
        }
        if (request != _bottomScrollRequest) return;
        final tailPosition = _scrollController.position;
        if (tailPosition.maxScrollExtent - tailPosition.pixels > 0.5) {
          tailPosition.jumpTo(tailPosition.maxScrollExtent);
          await WidgetsBinding.instance.endOfFrame;
        }
        if (request != _bottomScrollRequest) return;
        _updateJumpToBottomVisibility(false);
        _autoStickToBottom = true;
        return;
      }

      final start = pos.pixels;
      final target = pos.maxScrollExtent;
      final distance = (target - start).abs();
      final animateNearby = animate && distance >= 0.5;

      if (animateNearby) {
        final durationMs = distance < 500
            ? 250
            : distance < 2000
            ? 350
            : 450;
        pos.jumpTo(start.clamp(pos.minScrollExtent, pos.maxScrollExtent));
        _explicitBottomAnimationInProgress = true;
        try {
          await pos.animateTo(
            target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
            duration: Duration(milliseconds: durationMs),
            curve: Curves.easeOutCubic,
          );
        } finally {
          if (request == _bottomScrollRequest) {
            _explicitBottomAnimationInProgress = false;
          }
        }
      } else if (distance >= 0.5) {
        pos.jumpTo(target);
      }

      if (request != _bottomScrollRequest) return;
      _updateJumpToBottomVisibility(false);
      _autoStickToBottom = true;
    } catch (_) {}
  }

  void _updateJumpToBottomVisibility(bool show) {
    if (_showJumpToBottom != show) {
      _showJumpToBottom = show;
      _onStateChanged();
    }
  }

  // ============================================================================
  // 导航方法
  // ============================================================================

  double _currentTopRevealInset() {
    try {
      final inset = _getTopRevealInset?.call() ?? 0.0;
      if (!inset.isFinite || inset <= 0) return 0;
      if (!_scrollController.hasClients) return inset;
      return inset
          .clamp(0.0, _scrollController.position.viewportDimension)
          .toDouble();
    } catch (_) {
      return 0;
    }
  }

  double _messageRevealOffset(int index, double alignment) {
    // 这与 jumpToItem 内部使用的偏移查询相同。
    // ignore: invalid_use_of_visible_for_testing_member
    final rawOffset = _messageListController.getOffsetToReveal(
      index,
      alignment,
    );
    final normalizedAlignment = alignment.clamp(0.0, 1.0).toDouble();
    return rawOffset - _currentTopRevealInset() * (1.0 - normalizedAlignment);
  }

  void _correctMessageReveal(int index, double alignment) {
    if (!_scrollController.hasClients ||
        !_messageListController.isAttached ||
        index < 0 ||
        index >= _messageListController.numberOfItems) {
      return;
    }
    final position = _scrollController.position;
    final target = _messageRevealOffset(
      index,
      alignment,
    ).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if ((position.pixels - target).abs() > 0.5) {
      position.jumpTo(target);
    }
  }

  int? _firstVisibleMessageBelowTopOverlay() {
    if (!_scrollController.hasClients || !_messageListController.isAttached) {
      return null;
    }
    final visible = _messageListController.visibleRange;
    if (visible == null) return null;
    final topBoundary =
        _scrollController.position.pixels + _currentTopRevealInset();
    for (var index = visible.$1; index <= visible.$2; index++) {
      if (index < 0 || index >= _messageListController.numberOfItems) continue;
      // ignore: invalid_use_of_visible_for_testing_member
      final leading = _messageListController.getOffsetToReveal(index, 0);
      final extent = _messageListController.extentForIndex(index).$1;
      if (leading + extent > topBoundary + 0.5) return index;
    }
    return visible.$2;
  }

  /// 滚动到列表顶部。
  void scrollToTop({bool animate = true}) {
    try {
      if (!_scrollController.hasClients) return;
      _cancelProgrammaticNavigation(stopDrivenScroll: true);
      _lastJumpUserMessageId = null;
      revealNavButtons();

      if (animate) {
        final pos = _scrollController.position;
        final distance = pos.pixels;
        final durationMs = distance < 200
            ? 150
            : distance < 800
            ? 220
            : 300;
        pos.animateTo(
          0.0,
          duration: Duration(milliseconds: durationMs),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(0.0);
      }
    } catch (_) {}
  }

  /// 跳转到当前索引锚点紧前一条消息。
  Future<bool> jumpToPreviousQuestion({
    required List<dynamic> messages,
    required int Function(String id) indexOfId,
  }) async {
    try {
      if (!_scrollController.hasClients || !_messageListController.isAttached) {
        return false;
      }
      if (messages.isEmpty) return false;

      revealNavButtons();

      final cursorIndex = _lastJumpUserMessageId == null
          ? -1
          : indexOfId(_lastJumpUserMessageId!);
      final anchor = cursorIndex >= 0
          ? cursorIndex
          : (_firstVisibleMessageBelowTopOverlay() ?? messages.length - 1);

      final target = anchor - 1;
      if (target < 0) {
        _lastJumpUserMessageId = null;
        return false;
      }

      _lastJumpUserMessageId = messages[target].id;
      await _animateToMessageIndex(index: target, alignment: 0);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 跳转到当前索引锚点紧后一条消息。
  Future<bool> jumpToNextQuestion({
    required List<dynamic> messages,
    required int Function(String id) indexOfId,
  }) async {
    try {
      if (!_scrollController.hasClients || !_messageListController.isAttached) {
        return false;
      }
      if (messages.isEmpty) return false;

      revealNavButtons();

      final cursorIndex = _lastJumpUserMessageId == null
          ? -1
          : indexOfId(_lastJumpUserMessageId!);
      final anchor = cursorIndex >= 0
          ? cursorIndex
          : (_firstVisibleMessageBelowTopOverlay() ?? 0);

      final target = anchor + 1;
      if (target >= messages.length) {
        _lastJumpUserMessageId = null;
        return false;
      }

      _lastJumpUserMessageId = messages[target].id;
      await _animateToMessageIndex(index: target, alignment: 0);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 按索引滚动到指定消息（从小地图或搜索）。
  ///
  /// 直接索引定位与 RikkaHub 的 `scrollToItem` 一致：
  /// 远处目标不会构建或动画经过每一条中间消息。
  Future<void> scrollToMessageId({
    required String targetId,
    required int targetIndex,
  }) async {
    try {
      if (!_scrollController.hasClients || !_messageListController.isAttached) {
        return;
      }
      if (targetIndex < 0) return;
      if (targetIndex >= _messageListController.numberOfItems) return;
      _cancelProgrammaticNavigation(stopDrivenScroll: true);
      final request = ++_indexedNavigationRequest;
      _messageListController.jumpToItem(
        index: targetIndex,
        scrollController: _scrollController,
        alignment: 0,
      );
      _correctMessageReveal(targetIndex, 0);
      for (var pass = 0; pass < 3; pass++) {
        await WidgetsBinding.instance.endOfFrame;
        if (request != _indexedNavigationRequest ||
            !_scrollController.hasClients ||
            !_messageListController.isAttached ||
            targetIndex >= _messageListController.numberOfItems) {
          return;
        }
        _correctMessageReveal(targetIndex, 0);
        final estimated = _messageListController.extentForIndex(targetIndex).$2;
        if (!estimated && pass > 0) break;
      }
      _lastJumpUserMessageId = targetId;
    } catch (_) {}
  }

  Future<void> _animateToMessageIndex({
    required int index,
    required double alignment,
    int? bottomRequest,
  }) async {
    if (!_scrollController.hasClients ||
        !_messageListController.isAttached ||
        index < 0 ||
        index >= _messageListController.numberOfItems) {
      return;
    }
    if (bottomRequest == null) {
      _cancelProgrammaticNavigation(stopDrivenScroll: true);
      _autoStickToBottom = false;
    } else {
      if (bottomRequest != _bottomScrollRequest) return;
      _cancelIndexedNavigation();
    }
    final request = ++_indexedNavigationRequest;
    final position = _scrollController.position;
    final estimatedDistance =
        ((bottomRequest == null
                    ? _messageRevealOffset(index, alignment)
                    : position.maxScrollExtent) -
                position.pixels)
            .abs();
    final duration = estimatedDistance < 320
        ? const Duration(milliseconds: 220)
        : estimatedDistance < 1000
        ? const Duration(milliseconds: 280)
        : const Duration(milliseconds: 360);
    final animationController = AnimationController(
      vsync: position.context.vsync,
      duration: duration,
    );
    _indexedAnimationController = animationController;
    _IndexedScrollActivity? indexedActivity;
    if (position is _AutoFollowScrollPosition) {
      late final _IndexedScrollActivity startedActivity;
      startedActivity = position.beginIndexedAnimation(
        () => _cancelIndexedAnimationFromActivity(startedActivity),
      );
      indexedActivity = startedActivity;
      _indexedScrollActivity = startedActivity;
    }
    final animation = CurvedAnimation(
      parent: animationController,
      curve: Curves.easeOutCubic,
    );
    var previousProgress = 0.0;
    bool movePosition(double value) {
      final activity = indexedActivity;
      if (position is _AutoFollowScrollPosition && activity != null) {
        return position.updateIndexedAnimation(activity, value);
      }
      position.jumpTo(value);
      position.isScrollingNotifier.value = true;
      return true;
    }

    void updatePosition() {
      if (request != _indexedNavigationRequest ||
          (bottomRequest != null && bottomRequest != _bottomScrollRequest) ||
          !_scrollController.hasClients ||
          !_messageListController.isAttached ||
          index >= _messageListController.numberOfItems) {
        animationController.stop(canceled: false);
        return;
      }

      // 当目标进入其缓存区域时，SuperListView 可能用真实高度替换估算高度。
      // 每个 tick 都重新读取索引偏移，使修正被这一段连续动画吸收，
      // 而不是在动画后成为可见跳变。
      final target =
          (bottomRequest == null
                  ? _messageRevealOffset(index, alignment)
                  : position.maxScrollExtent)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      final progress = animation.value;
      final remainingProgress = 1.0 - previousProgress;
      final stepProgress = remainingProgress <= 0.0001
          ? 1.0
          : ((progress - previousProgress) / remainingProgress).clamp(0.0, 1.0);
      // 从当前像素仅按剩余进度插值。如果惰性高度发生变化，
      // 这样会把修正分散到动画剩余部分，而不是在一帧内
      // 将所有已过进度应用到新目标。
      final next = position.pixels + (target - position.pixels) * stepProgress;
      previousProgress = progress;
      if ((next - position.pixels).abs() > 0.01) {
        if (!movePosition(next)) {
          animationController.stop(canceled: false);
        }
      }
    }

    animation.addListener(updatePosition);
    if (indexedActivity == null) position.isScrollingNotifier.value = true;
    try {
      await animationController.forward().orCancel;
    } on TickerCanceled {
      // 新的导航请求、用户手势或已分离时间线拥有下一个位置。
      // 取消是预期的终态。
    } finally {
      animation.removeListener(updatePosition);
      animation.dispose();
      if (identical(_indexedAnimationController, animationController)) {
        _indexedAnimationController = null;
        final activity = indexedActivity;
        if (identical(_indexedScrollActivity, activity)) {
          _indexedScrollActivity = null;
          if (position is _AutoFollowScrollPosition && activity != null) {
            position.finishIndexedAnimation(activity);
          }
        } else if (activity == null) {
          position.isScrollingNotifier.value = false;
        }
        animationController.dispose();
      }
    }
  }

  void _cancelIndexedAnimationFromActivity(
    _IndexedScrollActivity indexedActivity,
  ) {
    if (!identical(_indexedScrollActivity, indexedActivity)) return;
    _indexedScrollActivity = null;
    _indexedNavigationRequest++;
    final animationController = _indexedAnimationController;
    _indexedAnimationController = null;
    animationController?.stop();
    animationController?.dispose();
  }

  void _cancelIndexedNavigationForDetach() {
    _indexedNavigationRequest++;
    // 此时 ScrollPosition 的销毁拥有该活动。从 ListController.onDetached
    // 调用 goIdle 会通过已停用的控件树派发滚动结束通知。
    _indexedScrollActivity = null;
    final animationController = _indexedAnimationController;
    _indexedAnimationController = null;
    animationController?.stop();
    animationController?.dispose();
  }

  void _cancelIndexedNavigation() {
    _indexedNavigationRequest++;
    final indexedActivity = _indexedScrollActivity;
    _indexedScrollActivity = null;
    if (indexedActivity != null &&
        _scrollController.hasClients &&
        _scrollController.position is _AutoFollowScrollPosition) {
      (_scrollController.position as _AutoFollowScrollPosition)
          .finishIndexedAnimation(indexedActivity);
    }
    final animationController = _indexedAnimationController;
    _indexedAnimationController = null;
    if (animationController == null) return;
    if (_scrollController.hasClients && indexedActivity == null) {
      _scrollController.position.isScrollingNotifier.value = false;
    }
    animationController.stop();
    animationController.dispose();
  }

  void _cancelProgrammaticNavigation({bool stopDrivenScroll = false}) {
    _bottomScrollRequest++;
    _deferredBottomRequest++;
    _scheduledBottomScrollRequest = null;
    _cancelIndexedNavigation();
    _explicitBottomAnimationInProgress = false;
    if (!stopDrivenScroll || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position is ScrollPositionWithSingleContext) {
      position.goIdle();
    }
  }

  // ============================================================================
  // 状态修改器
  // ============================================================================

  /// 重置上次跳转的用户消息 ID（例如开始新导航时）。
  void resetLastJumpUserMessageId() {
    _cancelIndexedNavigation();
    _lastJumpUserMessageId = null;
  }

  /// 设置自动保持底部状态。
  void setAutoStickToBottom(bool value) {
    _autoStickToBottom = value;
  }

  /// 重置用户滚动状态（例如强制滚动时）。
  void resetUserScrolling() {
    _isUserScrolling = false;
    _userScrollTimer?.cancel();
  }

  // ============================================================================
  // 清理
  // ============================================================================

  /// 释放资源。
  void dispose() {
    _scrollController.removeListener(_onScrollControllerChanged);
    _userScrollTimer?.cancel();
    _navButtonsHideTimer?.cancel();
    _cancelIndexedNavigation();
    _messageListController.dispose();
  }
}
