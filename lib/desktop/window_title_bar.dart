import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 应用内自绘标题栏。
///
/// 目前只在 Linux 且用户开启“隐藏系统标题栏”时使用：系统标题栏被隐藏后，
/// 由它提供拖动区和最小化／最大化／关闭按钮。Windows／macOS 继续使用系统
/// 原生标题栏，不经过这里。
///
/// - 中间区域可拖动移动窗口
/// - 右侧渲染最小化／最大化／还原／关闭按钮
/// - 左侧可传入附加内容（例如应用图标与名称）
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key, this.leftChildren = const <Widget>[]});

  final List<Widget> leftChildren;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadState();
  }

  Future<void> _loadState() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (mounted) setState(() => _isMaximized = maximized);
    } catch (_) {}
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    return Container(
      height: 40,
      color: theme.scaffoldBackgroundColor,
      child: Row(
        children: [
          const SizedBox(width: 6),
          ...widget.leftChildren,
          // 只有中间区域响应拖动，窗口按钮不能被拖动区覆盖。
          Expanded(child: DragToMoveArea(child: const SizedBox.expand())),
          WindowCaptionButton.minimize(
            brightness: brightness,
            onPressed: () => windowManager.minimize(),
          ),
          if (_isMaximized)
            WindowCaptionButton.unmaximize(
              brightness: brightness,
              onPressed: () => windowManager.unmaximize(),
            )
          else
            WindowCaptionButton.maximize(
              brightness: brightness,
              onPressed: () => windowManager.maximize(),
            ),
          WindowCaptionButton.close(
            brightness: brightness,
            onPressed: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}
