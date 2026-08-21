import 'package:flutter/material.dart';
import 'breakpoints.dart';

class AdaptiveLayout extends StatelessWidget {
  final Widget? navigationRail; // 仅桌面（平板不使用）
  final Widget? sidePanel; // 平板/桌面：对话/历史面板
  final Widget body; // 主要内容
  final double tabletSideWidth;
  final double desktopNavWidth;
  final double desktopSideWidth;

  const AdaptiveLayout({
    super.key,
    this.navigationRail,
    this.sidePanel,
    required this.body,
    this.tabletSideWidth = 300,
    this.desktopNavWidth = 80,
    this.desktopSideWidth = 320,
  });

  @override
  Widget build(BuildContext context) {
    final type = screenTypeForContext(context);

    switch (type) {
      case ScreenType.mobile:
        return body;
      case ScreenType.tablet:
        return Row(
          children: [
            if (sidePanel != null)
              SizedBox(width: tabletSideWidth, child: sidePanel),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        );
      case ScreenType.desktop:
      case ScreenType.wide:
        // 基础三列骨架；桌面端特定调整可后续补充。
        return Row(
          children: [
            if (navigationRail != null)
              SizedBox(width: desktopNavWidth, child: navigationRail),
            if (sidePanel != null) ...[
              SizedBox(width: desktopSideWidth, child: sidePanel),
              const VerticalDivider(width: 1),
            ],
            Expanded(child: body),
          ],
        );
    }
  }
}
