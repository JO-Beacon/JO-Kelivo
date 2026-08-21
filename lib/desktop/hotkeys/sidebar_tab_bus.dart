import 'dart:async';

/// 桌面侧边栏标签（助手、主题）控制总线，用于内嵌左侧面板。
class DesktopSidebarTabBus {
  DesktopSidebarTabBus._();
  static final DesktopSidebarTabBus instance = DesktopSidebarTabBus._();

  final _controller = StreamController<int>.broadcast();
  // 0 = 助手，1 = 主题
  Stream<int> get stream => _controller.stream;

  int _currentIndex = 0;
  int get currentIndex => _currentIndex;

  void setCurrentIndex(int index) {
    _currentIndex = index;
  }

  void switchToAssistants() => _controller.add(0);
  void switchToTopics() => _controller.add(1);

  void dispose() => _controller.close();
}
