import 'package:flutter/material.dart';
import '../features/home/pages/home_page.dart';

/// 桌面聊天页入口。
/// 第一阶段复用 HomePage 中宽度较大时已有的平板布局。
/// 后续可把平板分支抽到本目录下的专用桌面布局中。
class DesktopChatPage extends StatelessWidget {
  const DesktopChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 复用现有聊天体验（平板分支），不修改移动端实现。
    return const HomePage();
  }
}
