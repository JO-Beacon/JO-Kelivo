import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import 'token_detail_popup.dart';

/// 紧凑的 token 显示，展示“123 tokens”并弹出详情气泡。
///
/// - 移动端：点击切换弹窗（透明遮罩会关闭弹窗）
/// - 桌面端：悬停 200ms 后显示，300ms 后关闭
/// - 显示/隐藏时使用淡入和轻微滑动动画
class TokenDisplayWidget extends StatefulWidget {
  const TokenDisplayWidget({
    super.key,
    required this.totalTokens,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.durationMs,
  });

  final int totalTokens;
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
  final int? durationMs;

  @override
  State<TokenDisplayWidget> createState() => _TokenDisplayWidgetState();
}

class _TokenDisplayWidgetState extends State<TokenDisplayWidget>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  OverlayEntry? _barrierEntry;
  bool _isShowing = false;
  bool _showBelow = false;

  AnimationController? _animController;
  CurvedAnimation? _curvedAnim;

  bool _isHoveringTarget = false;
  bool _isHoveringPopup = false;
  int _showTimerId = 0;
  int _hideTimerId = 0;

  ScrollPosition? _scrollPosition;

  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  bool get _hasDetailData =>
      (widget.promptTokens != null && widget.promptTokens! > 0) ||
      (widget.completionTokens != null && widget.completionTokens! > 0) ||
      (widget.durationMs != null && widget.durationMs! > 0);

  static const double _estimatedPopupHeight = 120;

  /// 在首次使用时（弹窗实际打开时）延迟创建动画控制器。
  CurvedAnimation _ensureAnimation() {
    _animController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _curvedAnim ??= CurvedAnimation(
      parent: _animController!,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return _curvedAnim!;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _removeOverlayImmediate();
    _curvedAnim?.dispose();
    _animController?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (_isShowing) _removeOverlayImmediate();
  }

  void _showPopup() {
    if (_isShowing || !mounted) return;
    _isShowing = true;

    final box = context.findRenderObject() as RenderBox?;
    _showBelow = _shouldShowBelow(box);

    final Alignment tAnchor;
    final Alignment fAnchor;
    final Offset offset;
    if (_showBelow) {
      tAnchor = Alignment.bottomRight;
      fAnchor = Alignment.topRight;
      offset = const Offset(0, 8);
    } else {
      tAnchor = Alignment.topRight;
      fAnchor = Alignment.bottomRight;
      offset = const Offset(0, -8);
    }

    // 监听滚动位置，滚动时关闭弹窗
    _attachScrollListener();

    final overlay = Overlay.of(context, rootOverlay: true);

    if (!_isDesktop) {
      // 使用 Listener（onPointerDown）而非 GestureDetector（onTap）
      // 这样滚动手势（从 pointerDown 开始）也会关闭弹窗
      _barrierEntry = OverlayEntry(
        builder: (_) => Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _hidePopup(),
          child: const SizedBox.expand(),
        ),
      );
      overlay.insert(_barrierEntry!);
    }

    _overlayEntry = OverlayEntry(
      builder: (_) => UnconstrainedBox(
        child: CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: tAnchor,
          followerAnchor: fAnchor,
          offset: offset,
          child: Material(
            type: MaterialType.transparency,
            child: _AnimatedPopupContent(
              animation: _ensureAnimation(),
              showBelow: _showBelow,
              isDesktop: _isDesktop,
              onHoverEnter: () {
                _isHoveringPopup = true;
                _cancelHideTimer();
              },
              onHoverExit: () {
                _isHoveringPopup = false;
                _scheduleHide();
              },
              child: TokenDetailPopup(
                promptTokens: widget.promptTokens,
                completionTokens: widget.completionTokens,
                cachedTokens: widget.cachedTokens,
                durationMs: widget.durationMs,
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
    _ensureAnimation();
    _animController!.forward(from: 0);
  }

  bool _shouldShowBelow(RenderBox? box) {
    if (box == null || !box.attached) return false;
    try {
      final topY = box.localToGlobal(Offset.zero).dy;
      final padding = MediaQuery.of(context).padding.top;
      return topY - padding < _estimatedPopupHeight + 16;
    } catch (_) {
      return false;
    }
  }

  Future<void> _hidePopup() async {
    if (!_isShowing) return;
    try {
      await _animController?.reverse();
    } catch (_) {}
    _removeOverlayImmediate();
  }

  void _removeOverlayImmediate() {
    _detachScrollListener();
    _barrierEntry?.remove();
    _barrierEntry = null;
    _overlayEntry?.remove();
    _overlayEntry = null;
    _isShowing = false;
    _isHoveringTarget = false;
    _isHoveringPopup = false;
  }

  void _togglePopup() {
    if (_isShowing) {
      _hidePopup();
    } else {
      _showPopup();
    }
  }

  void _scheduleShow() {
    final id = ++_showTimerId;
    Future.delayed(const Duration(milliseconds: 200), () {
      if (id == _showTimerId && _isHoveringTarget && mounted) {
        _showPopup();
      }
    });
  }

  void _scheduleHide() {
    final id = ++_hideTimerId;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (id == _hideTimerId &&
          !_isHoveringTarget &&
          !_isHoveringPopup &&
          mounted) {
        _hidePopup();
      }
    });
  }

  void _cancelHideTimer() {
    _hideTimerId++;
  }

  void _attachScrollListener() {
    _detachScrollListener();
    try {
      final scrollable = Scrollable.maybeOf(context);
      _scrollPosition = scrollable?.position;
      _scrollPosition?.addListener(_onScroll);
    } catch (_) {}
  }

  void _detachScrollListener() {
    try {
      _scrollPosition?.removeListener(_onScroll);
    } catch (_) {}
    _scrollPosition = null;
  }

  void _onScroll() {
    if (_isShowing) {
      _removeOverlayImmediate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    final label = Text(
      l10n.tokenDetailTotalTokens(widget.totalTokens),
      style: TextStyle(
        fontSize: 11,
        color: cs.onSurface.withValues(alpha: 0.5),
      ),
    );

    if (!_hasDetailData) {
      return CompositedTransformTarget(link: _layerLink, child: label);
    }

    Widget child = CompositedTransformTarget(link: _layerLink, child: label);

    if (_isDesktop) {
      child = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          _isHoveringTarget = true;
          _cancelHideTimer();
          _scheduleShow();
        },
        onExit: (_) {
          _isHoveringTarget = false;
          _scheduleHide();
        },
        child: child,
      );
    } else {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _togglePopup,
        child: child,
      );
    }

    return child;
  }
}

class _AnimatedPopupContent extends StatelessWidget {
  const _AnimatedPopupContent({
    required this.animation,
    required this.showBelow,
    required this.isDesktop,
    required this.onHoverEnter,
    required this.onHoverExit,
    required this.child,
  });

  final Animation<double> animation;
  final bool showBelow;
  final bool isDesktop;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final begin = Offset(0, showBelow ? -0.15 : 0.15);

    Widget content = SlideTransition(
      position: Tween<Offset>(
        begin: begin,
        end: Offset.zero,
      ).animate(animation),
      child: FadeTransition(opacity: animation, child: child),
    );

    if (isDesktop) {
      content = MouseRegion(
        onEnter: (_) => onHoverEnter(),
        onExit: (_) => onHoverExit(),
        child: content,
      );
    }

    return content;
  }
}
