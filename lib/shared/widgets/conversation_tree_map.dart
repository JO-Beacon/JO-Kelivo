import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/chat_message.dart';
import '../../core/models/conversation_tree.dart';
import '../../core/models/message_part.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import 'ios_tactile.dart';

/// 会话消息树的紧凑可滚动投影。
///
/// 树按消息深度布局。共同祖先占用一个节点，只有分叉子节点才会额外占用水平空间。
class ConversationTreeMap extends StatelessWidget {
  const ConversationTreeMap({
    super.key,
    required this.tree,
    required this.messages,
    required this.onTapMessage,
    this.activeBranchId,
    this.query = '',
    this.selecting = false,
    this.selectedMessageIds,
    this.onToggleSelection,
  });

  final ConversationTree tree;
  final List<ChatMessage> messages;
  final ValueChanged<String> onTapMessage;
  final String? activeBranchId;
  final String query;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final ValueChanged<String>? onToggleSelection;

  @override
  Widget build(BuildContext context) {
    final layout = _ConversationTreeMapLayout.build(
      tree: tree,
      messages: messages,
      query: query,
    );
    if (layout.nodes.isEmpty) return const SizedBox.shrink();

    final activeIds = tree.activePath().toSet();
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(layout.width, constraints.maxWidth);
        return SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: SizedBox(
              width: width,
              height: layout.height,
              child: CustomPaint(
                painter: _ConversationTreeMapEdgePainter(
                  layout.nodes,
                  activeMessageIds: activeIds,
                  activeColor: Theme.of(context).colorScheme.primary,
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final node in layout.nodes)
                      Positioned(
                        left: node.centerX - _TreeMapNodeCard.width / 2,
                        top: node.top,
                        child: _TreeMapNodeCard(
                          message: node.message,
                          isActive: activeIds.contains(node.message.id),
                          isSelected:
                              selectedMessageIds?.contains(node.message.id) ??
                              false,
                          isDimmed: node.isDimmed,
                          selecting: selecting,
                          userLabel: l10n.treeMapUserLabel,
                          assistantLabel: l10n.treeMapAssistantLabel,
                          onTap: () {
                            if (selecting) {
                              onToggleSelection?.call(node.message.id);
                            } else {
                              onTapMessage(node.message.id);
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TreeMapNodeCard extends StatelessWidget {
  const _TreeMapNodeCard({
    required this.message,
    required this.isActive,
    required this.isSelected,
    required this.isDimmed,
    required this.selecting,
    required this.userLabel,
    required this.assistantLabel,
    required this.onTap,
  });

  static const width = 148.0;
  static const height = 62.0;

  final ChatMessage message;
  final bool isActive;
  final bool isSelected;
  final bool isDimmed;
  final bool selecting;
  final String userLabel;
  final String assistantLabel;
  final VoidCallback onTap;

  String get _summary => message.parts
      .whereType<TextPart>()
      .map((part) => part.text)
      .join()
      .replaceAll(
        RegExp(
          r'<(?:think|thought)>[\s\S]*?<\/(?:think|thought)>',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final selected = isSelected || isActive;
    final baseColor = isUser
        ? cs.primary.withValues(alpha: selected ? 0.18 : 0.09)
        : cs.surfaceContainerHighest.withValues(alpha: selected ? 0.72 : 0.58);
    final borderColor = selected
        ? cs.primary.withValues(alpha: 0.82)
        : cs.outlineVariant.withValues(alpha: 0.72);
    final foreground = cs.onSurface.withValues(alpha: isDimmed ? 0.55 : 0.92);

    return SizedBox(
      width: width,
      height: height,
      child: IosCardPress(
        borderRadius: BorderRadius.circular(8),
        baseColor: baseColor,
        border: Border.all(color: borderColor, width: selected ? 1.4 : 0.8),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        onTap: onTap,
        child: Opacity(
          opacity: isDimmed ? 0.72 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUser ? userLabel : assistantLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 10.5,
                  fontWeight: AppFontWeights.emphasis,
                ),
              ),
              const SizedBox(height: 3),
              Expanded(
                child: Text(
                  _summary.isEmpty ? ' ' : _summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 11.5,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationTreeMapNode {
  _ConversationTreeMapNode({
    required this.message,
    required this.children,
    required this.depth,
    required this.isDimmed,
  });

  final ChatMessage message;
  final List<_ConversationTreeMapNode> children;
  final int depth;
  final bool isDimmed;
  late double centerX;
  late double top;
}

class _ConversationTreeMapLayout {
  _ConversationTreeMapLayout({
    required this.nodes,
    required this.width,
    required this.height,
  });

  final List<_ConversationTreeMapNode> nodes;
  final double width;
  final double height;

  static const _slotWidth = 180.0;
  static const _rowHeight = 94.0;

  static _ConversationTreeMapLayout build({
    required ConversationTree tree,
    required List<ChatMessage> messages,
    required String query,
  }) {
    final byId = <String, ChatMessage>{
      for (final message in messages) message.id: message,
    };
    final messageOrder = <String, int>{
      for (var index = 0; index < messages.length; index++)
        messages[index].id: index,
    };
    final childrenByParent = <String?, List<String>>{};
    for (final edge in tree.edges.values) {
      if (!byId.containsKey(edge.messageId)) continue;
      final parent = byId.containsKey(edge.parentMessageId)
          ? edge.parentMessageId
          : null;
      childrenByParent
          .putIfAbsent(parent, () => <String>[])
          .add(edge.messageId);
    }
    for (final children in childrenByParent.values) {
      children.sort(
        (left, right) =>
            (messageOrder[left] ?? 0).compareTo(messageOrder[right] ?? 0),
      );
    }

    final needle = query.trim().toLowerCase();
    String summary(ChatMessage message) => message.parts
        .whereType<TextPart>()
        .map((part) => part.text)
        .join()
        .toLowerCase();
    final matches = <String, bool>{
      for (final message in byId.values)
        message.id: needle.isEmpty || summary(message).contains(needle),
    };

    _ConversationTreeMapNode? buildNode(String messageId, int depth) {
      final childNodes = [
        for (final childId in childrenByParent[messageId] ?? const <String>[])
          if (buildNode(childId, depth + 1) case final child?) child,
      ];
      final visible = matches[messageId] == true || childNodes.isNotEmpty;
      if (!visible) return null;
      return _ConversationTreeMapNode(
        message: byId[messageId]!,
        children: childNodes,
        depth: depth,
        isDimmed: needle.isNotEmpty && matches[messageId] != true,
      );
    }

    final roots = [
      for (final rootId in childrenByParent[null] ?? const <String>[])
        if (buildNode(rootId, 0) case final root?) root,
    ];
    if (roots.isEmpty) {
      return _ConversationTreeMapLayout(nodes: const [], width: 0, height: 0);
    }

    var leafIndex = 0;
    var maxDepth = 0;
    int leafCount(_ConversationTreeMapNode node) {
      maxDepth = math.max(maxDepth, node.depth);
      if (node.children.isEmpty) return 1;
      return node.children.fold(0, (sum, child) => sum + leafCount(child));
    }

    for (final root in roots) {
      leafCount(root);
    }

    final flat = <_ConversationTreeMapNode>[];
    double assign(_ConversationTreeMapNode node) {
      flat.add(node);
      final children = node.children;
      if (children.isEmpty) {
        node.centerX = 12 + leafIndex * _slotWidth + _TreeMapNodeCard.width / 2;
        leafIndex++;
      } else {
        for (final child in children) {
          assign(child);
        }
        node.centerX = (children.first.centerX + children.last.centerX) / 2;
      }
      node.top = 12 + node.depth * _rowHeight;
      return node.centerX;
    }

    for (final root in roots) {
      assign(root);
    }

    final leafSlots = math.max(leafIndex, 1);
    return _ConversationTreeMapLayout(
      nodes: flat,
      width: 24 + leafSlots * _slotWidth,
      height: 24 + (maxDepth + 1) * _rowHeight,
    );
  }
}

class _ConversationTreeMapEdgePainter extends CustomPainter {
  const _ConversationTreeMapEdgePainter(
    this.nodes, {
    required this.activeMessageIds,
    required this.activeColor,
  });

  final List<_ConversationTreeMapNode> nodes;
  final Set<String> activeMessageIds;
  final Color activeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final byId = <String, _ConversationTreeMapNode>{
      for (final node in nodes) node.message.id: node,
    };
    for (final node in nodes) {
      for (final child in node.children) {
        final parent = byId[node.message.id];
        final childNode = byId[child.message.id];
        if (parent == null || childNode == null) continue;
        final start = Offset(
          parent.centerX,
          parent.top + _TreeMapNodeCard.height,
        );
        final end = Offset(childNode.centerX, childNode.top);
        final middleY = (start.dy + end.dy) / 2;
        final active =
            activeMessageIds.contains(node.message.id) &&
            activeMessageIds.contains(child.message.id);
        final paint = Paint()
          ..color = active
              ? activeColor.withValues(alpha: 0.9)
              : const Color(0x66888888)
          ..strokeWidth = active ? 2.8 : 1.4
          ..style = PaintingStyle.stroke;
        final path = Path()
          ..moveTo(start.dx, start.dy)
          ..lineTo(start.dx, middleY)
          ..lineTo(end.dx, middleY)
          ..lineTo(end.dx, end.dy);
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ConversationTreeMapEdgePainter oldDelegate) =>
      !identical(oldDelegate.nodes, nodes) ||
      !identical(oldDelegate.activeMessageIds, activeMessageIds) ||
      oldDelegate.activeColor != activeColor;
}
