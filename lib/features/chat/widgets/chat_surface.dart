import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/theme/chat_bubble_style.dart';

import 'frosted/frosted_surface.dart';

/// 聊天气泡表面的共享实现。
///
/// 上游在 Kelivo 1.2.7 的 fe8cb760 里把这族代码从 chat_message_widget.dart
/// 抽到本文件；本仓库据此补全（原先只搬来色板那一部分）。
///
/// 本文件负责三件事：
/// ① 气泡样式选择（私有 [_chatSurfaceStyleSelection]，找不到 Provider 时
///    退回默认样式而不抛异常）；
/// ② 气泡背景壳 [buildSharedChatSurface]（磨砂 / 实色 / 默认三态）；
/// ③ 前景色板 [ChatSurfaceForegroundPalette]，以及允许气泡内部覆盖前景色的
///    继承组件 [ChatSurfaceTheme] 与它的查找入口 [chatSurfaceForegroundPalette]。
({ChatMessageBackgroundStyle style, ChatBubbleStyleOverrides overrides})
_chatSurfaceStyleSelection(BuildContext context, {bool isUser = false}) {
  try {
    return context.select<
      SettingsProvider,
      ({ChatMessageBackgroundStyle style, ChatBubbleStyleOverrides overrides})
    >(
      (s) => (
        style: s.chatMessageBackgroundStyle,
        overrides: s.chatBubbleStyleOverridesFor(isUser: isUser),
      ),
    );
  } on ProviderNotFoundException {
    return (
      style: ChatMessageBackgroundStyle.defaultStyle,
      overrides: const ChatBubbleStyleOverrides(),
    );
  }
}

/// 当前气泡里纯文本该用的颜色：默认样式直接取 onSurface，
/// 其余样式取气泡样式的文字色。
Color chatSurfacePlainTextColor(BuildContext context, {bool isUser = false}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final selection = _chatSurfaceStyleSelection(context, isUser: isUser);
  if (selection.style == ChatMessageBackgroundStyle.defaultStyle) {
    return cs.onSurface;
  }
  return resolveBubbleStyle(
    cs,
    theme.brightness,
    selection.style,
    selection.overrides,
  ).text;
}

/// 按当前气泡样式包一层背景壳。
///
/// [defaultColor] 为空时默认样式不加背景；[bareOnDefault] 为真时默认样式
/// 连内边距也不加（内容自带内边距的场景）。
Widget buildSharedChatSurface(
  BuildContext context, {
  required Widget child,
  required BorderRadius borderRadius,
  required EdgeInsetsGeometry padding,
  Color? defaultColor,
  bool bareOnDefault = false,
  bool isUser = false,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final selection = _chatSurfaceStyleSelection(context, isUser: isUser);
  final style = selection.style;
  final overrides = selection.overrides;
  final resolved = resolveBubbleStyle(cs, theme.brightness, style, overrides);
  Widget paddedChild = Padding(padding: padding, child: child);
  if (style != ChatMessageBackgroundStyle.defaultStyle &&
      overrides.hasTextOverride(theme.brightness)) {
    paddedChild = DefaultTextStyle.merge(
      style: TextStyle(color: resolved.text),
      child: paddedChild,
    );
  }

  switch (style) {
    case ChatMessageBackgroundStyle.frosted:
      final radius = BorderRadius.circular(resolved.radius);
      return FrostedSurface(
        style: resolved,
        borderRadius: radius,
        isUser: isUser,
        child: paddedChild,
      );
    case ChatMessageBackgroundStyle.solid:
      final radius = BorderRadius.circular(resolved.radius);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: resolved.background,
          borderRadius: radius,
          border: Border.all(
            color: resolved.border,
            width: resolved.borderWidth,
          ),
        ),
        child: paddedChild,
      );
    case ChatMessageBackgroundStyle.defaultStyle:
      if (bareOnDefault) {
        return child;
      }
      if (defaultColor == null) {
        return paddedChild;
      }
      return DecoratedBox(
        decoration: BoxDecoration(
          color: defaultColor,
          borderRadius: borderRadius,
        ),
        child: paddedChild,
      );
  }
}

/// 气泡内的前景色板，各强度一次算好，避免逐处重算。
class ChatSurfaceForegroundPalette {
  const ChatSurfaceForegroundPalette({
    required this.strong,
    required this.medium,
    required this.muted,
    required this.body,
    required this.divider,
    required this.accent,
  });

  final Color strong;
  final Color medium;
  final Color muted;
  final Color body;
  final Color divider;
  final Color accent;

  @override
  bool operator ==(Object other) =>
      other is ChatSurfaceForegroundPalette &&
      other.strong == strong &&
      other.medium == medium &&
      other.muted == muted &&
      other.body == body &&
      other.divider == divider &&
      other.accent == accent;

  @override
  int get hashCode => Object.hash(strong, medium, muted, body, divider, accent);
}

/// 允许气泡内部覆盖前景色板（例如引用卡片、自带底色的嵌套气泡）。
///
/// 用户气泡不参与继承查找：发送方气泡的底色由全局样式决定。
class ChatSurfaceTheme extends InheritedWidget {
  const ChatSurfaceTheme({
    super.key,
    required this.palette,
    required super.child,
  });

  final ChatSurfaceForegroundPalette palette;

  static ChatSurfaceForegroundPalette? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ChatSurfaceTheme>()
        ?.palette;
  }

  @override
  bool updateShouldNotify(ChatSurfaceTheme oldWidget) =>
      palette != oldWidget.palette;
}

/// 取气泡前景色：优先用祖先 [ChatSurfaceTheme] 指定的色板，否则现算。
ChatSurfaceForegroundPalette chatSurfaceForegroundPalette(
  BuildContext context, {
  bool isUser = false,
}) {
  if (!isUser) {
    final inherited = ChatSurfaceTheme.maybeOf(context);
    if (inherited != null) return inherited;
  }
  return computeChatSurfaceForegroundPalette(context, isUser: isUser);
}

/// 无条件现算前景色板（跳过继承查找）。
ChatSurfaceForegroundPalette computeChatSurfaceForegroundPalette(
  BuildContext context, {
  bool isUser = false,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final selection = _chatSurfaceStyleSelection(context, isUser: isUser);
  if (selection.style == ChatMessageBackgroundStyle.defaultStyle) {
    return ChatSurfaceForegroundPalette(
      strong: cs.secondary,
      medium: cs.secondary.withValues(alpha: 0.9),
      muted: cs.onSurface.withValues(alpha: 0.5),
      body: cs.onSurface.withValues(alpha: 0.7),
      divider: theme.brightness == Brightness.dark
          ? cs.onSurface.withValues(alpha: 0.24)
          : cs.outline.withValues(alpha: 0.15),
      accent: cs.primary,
    );
  }

  final base = resolveBubbleStyle(
    cs,
    theme.brightness,
    selection.style,
    selection.overrides,
  ).text;
  final bool isDark = theme.brightness == Brightness.dark;
  return ChatSurfaceForegroundPalette(
    strong: base.withValues(alpha: isDark ? 0.88 : 0.78),
    medium: base.withValues(alpha: isDark ? 0.76 : 0.66),
    muted: base.withValues(alpha: isDark ? 0.56 : 0.46),
    body: base.withValues(alpha: isDark ? 0.72 : 0.6),
    divider: base.withValues(alpha: isDark ? 0.16 : 0.14),
    accent: base.withValues(alpha: isDark ? 0.84 : 0.74),
  );
}
