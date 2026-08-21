import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 抽屉所在的一侧。
enum DrawerSide { left, right }

/// 用于以编程方式控制抽屉的控制器。
class InteractiveDrawerController extends ChangeNotifier {
  InteractiveDrawerController({double initialValue = 0.0})
    : _valueOffline = initialValue.clamp(0.0, 1.0);

  AnimationController? _controller;
  double _valueOffline;

  /// 当前进度，范围为 [0.0, 1.0]。
  double get value => _controller?.value ?? _valueOffline;
  bool get isOpen => value >= 1.0 - 1e-6;
  bool get isClosed => value <= 1e-6;

  void _attach(AnimationController c) {
    _controller = c;
    if (c.value != _valueOffline) c.value = _valueOffline;
    c.addListener(notifyListeners);
  }

  void _detach() {
    _controller?.removeListener(notifyListeners);
    _controller = null;
  }

  AnimationController _requireAttached() {
    final c = _controller;
    if (c == null) {
      throw FlutterError(
        'InteractiveDrawerController is not attached to any InteractiveDrawer.\n'
        'Pass this controller to InteractiveDrawer(controller: ...) first.',
      );
    }
    return c;
  }

  /// 以类似快速滑动的方式打开（正速度）。
  Future<void> open({double velocity = 2.0}) async {
    _requireAttached().fling(velocity: velocity.abs());
  }

  /// 以类似快速滑动的方式关闭（负速度）。
  Future<void> close({double velocity = -2.0}) async {
    _requireAttached().fling(velocity: -velocity.abs());
  }

  /// 以类似快速滑动的方式切换打开或关闭。
  Future<void> toggle({double velocity = 2.0}) async {
    if (isOpen) {
      await close(velocity: velocity);
    } else {
      await open(velocity: velocity);
    }
  }

  /// 动画到指定进度。
  Future<void> animateTo(
    double target, {
    Duration duration = const Duration(milliseconds: 250),
    Curve curve = Curves.easeOutCubic,
  }) async {
    assert(target >= 0.0 && target <= 1.0);
    await _requireAttached().animateTo(
      target,
      duration: duration,
      curve: curve,
    );
  }

  /// 无动画地跳转到指定进度。
  void jumpTo(double target) {
    assert(target >= 0.0 && target <= 1.0);
    if (_controller != null) {
      _controller!.value = target;
    } else {
      _valueOffline = target;
      notifyListeners();
    }
  }
}

/// 交互式抽屉：
/// - 子组件全屏可拖动，并在其内部显示遮罩
/// - 抽屉跟随进度滑入或滑出，也可拖动
class InteractiveDrawer extends StatefulWidget {
  const InteractiveDrawer({
    super.key,
    required this.child,
    required this.drawer,
    this.controller,
    this.side = DrawerSide.left,
    this.drawerWidth,
    this.duration = const Duration(milliseconds: 250),
    this.curve = Curves.easeOutCubic,
    this.scrimColor,
    this.maxScrimOpacity = 0.5,
    this.barrierDismissible = true,
    this.elevation = 0.0,
    this.semanticLabel,
    this.enableDrawerTapToClose = false,
    this.tabletMode = false,
    this.onScrimTap,
  });

  /// 主内容；会随抽屉进度水平移动。
  final Widget child;

  /// 固定宽度的抽屉内容。
  final Widget drawer;

  /// 外部控制器。如果为 null，则创建内部控制器。
  final InteractiveDrawerController? controller;

  /// 左侧或右侧。
  final DrawerSide side;

  /// 抽屉宽度。默认：min(360, screenWidth * 0.86)。
  final double? drawerWidth;

  /// 编程动画的默认时长（不适用于拖动）。
  final Duration duration;

  /// 编程动画的默认曲线（拖动始终为线性）。
  final Curve curve;

  /// 遮罩基础色（仅应用于子组件内部）。
  final Color? scrimColor;

  /// 最大遮罩不透明度（0 到 1）。
  final double maxScrimOpacity;

  /// 点击遮罩关闭。
  final bool barrierDismissible;

  /// 点击抽屉内空白区域是否关闭抽屉。
  final bool enableDrawerTapToClose;

  /// 平板模式：持续显示的侧边栏，带滑动和淡入效果。
  final bool tabletMode;

  /// 抽屉的 Material 海拔。
  final double elevation;

  /// 无障碍标签。
  final String? semanticLabel;

  /// 当用户点击右侧遮罩以关闭抽屉时触发的可选回调
  /// （仅在 [barrierDismissible] 为 true 且抽屉打开时触发）。
  final VoidCallback? onScrimTap;

  @override
  State<InteractiveDrawer> createState() => _InteractiveDrawerState();
}

class _InteractiveDrawerState extends State<InteractiveDrawer>
    with SingleTickerProviderStateMixin {
  static const double _kMinFlingVelocityPxPerSec = 365.0;

  late final AnimationController _anim;
  late InteractiveDrawerController _controllerProxy;
  double _drawerWidth = 0.0;

  bool get _isLeft => widget.side == DrawerSide.left;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      value: widget.controller?.value ?? 0.0,
      duration: widget.duration,
    );
    _controllerProxy = widget.controller ?? InteractiveDrawerController();
    _controllerProxy._attach(_anim);
  }

  @override
  void didUpdateWidget(covariant InteractiveDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach();
      _controllerProxy = widget.controller ?? InteractiveDrawerController();
      _controllerProxy._attach(_anim);
    }
    if (oldWidget.duration != widget.duration) {
      _anim.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    widget.controller?._detach();
    _anim.dispose();
    super.dispose();
  }

  // -------- 子组件和抽屉共用的拖动处理逻辑 --------

  void _onDragStart(DragStartDetails details) {
    _anim.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_drawerWidth <= 0) return;
    final double deltaPx = details.primaryDelta ?? 0.0;
    final double signedDelta =
        (_isLeft ? deltaPx : -deltaPx) / _drawerWidth; // 正值表示打开
    _anim.value = (_anim.value + signedDelta).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    if (_drawerWidth <= 0) return;
    final double vxPx = details.velocity.pixelsPerSecond.dx;
    final double signedVxPx = _isLeft ? vxPx : -vxPx; // 正值表示打开

    // 速度足够快时按速度执行快速滑动。
    if (signedVxPx.abs() >= _kMinFlingVelocityPxPerSec) {
      final double visualVelocity = (signedVxPx / _drawerWidth).clamp(
        -2.0,
        2.0,
      ); // 进度/秒
      _anim.fling(velocity: visualVelocity);
      return;
    }

    // 否则回落到最近的状态。
    if (_anim.value >= 0.5) {
      _controllerProxy.open();
    } else {
      _controllerProxy.close();
    }
  }

  /// 可拖动的子组件，内部带遮罩（不会覆盖抽屉）。
  Widget _buildDraggableChild() {
    if (widget.tabletMode) {
      // 平板模式下子组件保持静态（不位移，也没有遮罩）。
      return widget.child;
    }
    final double dx = (_isLeft ? 1 : -1) * _drawerWidth * _anim.value;
    final double scrimOpacity = (widget.maxScrimOpacity * _anim.value).clamp(
      0.0,
      1.0,
    );

    return Transform.translate(
      offset: Offset(dx, 0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onTap: widget.barrierDismissible && _controllerProxy.isOpen
            ? () {
                // 父组件可挂接触感或其他副作用。
                widget.onScrimTap?.call();
                _controllerProxy.close();
              }
            : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_anim.value > 0.0)
              IgnorePointer(
                ignoring: !widget.barrierDismissible,
                child: Container(
                  color:
                      (widget.scrimColor ?? Theme.of(context).colorScheme.scrim)
                          .withValues(alpha: scrimOpacity),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 跟随进度的可拖动抽屉（从屏幕外滑动到边缘）。
  Widget _buildDraggableDrawer() {
    if (widget.tabletMode) {
      // 滑动加淡入（宽度固定为配置的 _drawerWidth）。关闭时完全移到屏幕外。
      final targetWidth = _drawerWidth; // 在 build() 中已解析
      final double translateX =
          (_isLeft ? -1 : 1) * (1 - _anim.value) * targetWidth;
      final drawerBody = Material(
        elevation: widget.elevation,
        clipBehavior: Clip.none,
        child: Semantics(
          label: widget.semanticLabel,
          container: true,
          child: widget.drawer,
        ),
      );
      return Align(
        alignment: _isLeft ? Alignment.centerLeft : Alignment.centerRight,
        child: SizedBox(
          width: targetWidth,
          child: Opacity(
            opacity: _anim.value.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(translateX, 0),
              child: IgnorePointer(
                // 只有在打开到足够程度时才可交互。
                ignoring: _anim.value < 0.95,
                child: drawerBody,
              ),
            ),
          ),
        ),
      );
    }
    // 关闭时（value=0），抽屉完全在屏幕外。
    // 打开过程中它会向 0 偏移移动。
    final double hiddenOffset = _isLeft ? -_drawerWidth : _drawerWidth;
    final double dx = hiddenOffset * (1.0 - _anim.value); // 1->隐藏，0->在屏幕上

    final drawerBody = Material(
      elevation: widget.elevation,
      clipBehavior: Clip.none,
      child: Semantics(
        label: widget.semanticLabel,
        container: true,
        child: widget.drawer,
      ),
    );

    return Transform.translate(
      offset: Offset(dx, 0),
      child: Align(
        alignment: _isLeft ? Alignment.centerLeft : Alignment.centerRight,
        child: SizedBox(
          width: _drawerWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onTap: widget.enableDrawerTapToClose
                ? (_controllerProxy.isOpen ? _controllerProxy.close : null)
                : null,
            child: drawerBody,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (widget.tabletMode) {
            _drawerWidth = widget.drawerWidth ?? 250.0; // 平板默认 250
          } else {
            _drawerWidth =
                widget.drawerWidth ??
                math.max(300.0, constraints.maxWidth * 0.80);
          }

          return PopScope(
            canPop: !_controllerProxy.isOpen,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              if (_controllerProxy.isOpen) {
                _controllerProxy.close();
              }
            },
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, _) {
                if (widget.tabletMode) {
                  // Stack：带动态 padding 的主内容，以及顶部对齐的滑动抽屉。
                  final sidePadding = _drawerWidth * _anim.value;
                  EdgeInsets mainPadding;
                  if (_isLeft) {
                    mainPadding = EdgeInsets.only(left: sidePadding);
                  } else {
                    mainPadding = EdgeInsets.only(right: sidePadding);
                  }
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // 抽屉显现时，主内容通过 padding 移动以腾出空间。
                      AnimatedContainer(
                        duration: const Duration(
                          milliseconds: 16,
                        ), // 接近帧间隔以保证流畅度
                        curve: Curves.linear,
                        padding: mainPadding,
                        child: _buildDraggableChild(),
                      ),
                      _buildDraggableDrawer(),
                    ],
                  );
                }
                return Stack(
                  fit: StackFit.expand,
                  children: [_buildDraggableChild(), _buildDraggableDrawer()],
                );
              },
            ),
          );
        },
      ),
    );
  }
}
