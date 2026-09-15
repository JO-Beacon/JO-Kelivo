import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/theme/chat_bubble_style.dart';

/// Foreground colours for a chat surface, resolved once per bubble.
///
/// 上游把这族实现从 chat_message_widget.dart 抽到本文件（Kelivo 1.2.7 的
/// fe8cb760）。本仓库目前只搬来长消息折叠需要的色板部分：ChatSurfaceTheme、
/// buildSharedChatSurface 等随 1.2.7 的 D1 批次一起落地。
/// chat_message_widget.dart 的私有色板函数改为转发到这里，避免两份实现漂移。
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

ChatSurfaceForegroundPalette chatSurfaceForegroundPalette(
  BuildContext context, {
  bool isUser = false,
}) {
  // 本仓库暂无 ChatSurfaceTheme，等 1.2.7 的 D1 批次落地后再补继承查找。
  return computeChatSurfaceForegroundPalette(context, isUser: isUser);
}

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
