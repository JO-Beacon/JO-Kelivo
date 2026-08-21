import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:provider/provider.dart';
import '../core/providers/settings_provider.dart';

/// 使用 Flutter 实现的自定义 Windows 标题栏。
///
/// - 提供用于移动窗口的拖动区域
/// - 渲染最小化、最大化、还原和关闭按钮
/// - 接受可选的左侧子组件（例如应用图标、菜单切换按钮）
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({
    super.key,
    this.leftChildren = const <Widget>[],
    this.backgroundColor,
  });

  final List<Widget> leftChildren;
  final Color? backgroundColor;

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
    final cs = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final Color bg;
    if (widget.backgroundColor case final backgroundColor?) {
      bg = backgroundColor;
    } else {
      final sp = context.watch<SettingsProvider>();
      bg = sp.usePureBackground ? cs.surface : cs.surfaceContainerHighest;
    }
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: bg,
        // border: Border(
        //   bottom: BorderSide(
        //     color: cs.outlineVariant.withOpacity(0.25),
        //     width: 0.5,
        //   ),
        // ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          ...widget.leftChildren,
          // https://github.com/leanflutter/window_manager/issues/136
          // 只有中间区域应可拖动，按钮区域不应可拖动。
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
