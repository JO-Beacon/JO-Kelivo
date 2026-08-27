import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/chat_message.dart';
import '../../core/models/conversation_tree.dart';
import '../../core/models/message_part.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import 'ios_tactile.dart';

/// 会话消息树的紧凑可滚动投影。
///
/// 树按消息深度布局。共同祖先占用一个节点，只有分叉子节点才会额外占用水平空间。
class ConversationTreeMap extends StatefulWidget {
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
  State<ConversationTreeMap> createState() => ConversationTreeMapState();
}

class ConversationTreeMapState extends State<ConversationTreeMap> {
  final TransformationController _transformationController =
      TransformationController();

  static const double _minScale = 0.2;
  static const double _maxScale = 4.0;
  Size _viewportSize = Size.zero;
  Size _contentSize = Size.zero;

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  /// 恢复为 1:1 实际大小，并保留当前平移位置。
  void resetToActualSize() {
    if (_viewportSize.isEmpty || _contentSize.isEmpty) return;
    final translation = _transformationController.value.getTranslation();
    _setScale(
      1.0,
      translation: Offset(translation.x, translation.y),
      centerHorizontally: false,
    );
  }

  /// 横向适配当前视口：缩小到能完整显示树宽，并水平居中。
  void fitHorizontal() {
    if (_viewportSize.isEmpty || _contentSize.isEmpty) return;
    final scale = math.min(1.0, _viewportSize.width / _contentSize.width);
    final translation = _transformationController.value.getTranslation();
    _setScale(
      scale,
      translation: Offset(translation.x, translation.y),
      centerHorizontally: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = _ConversationTreeMapLayout.build(
      tree: widget.tree,
      messages: widget.messages,
      query: widget.query,
    );
    if (layout.nodes.isEmpty) return const SizedBox.shrink();

    final activeIds = widget.tree.activePath().toSet();
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final contentWidth = math.max(layout.width, viewport.width);
        final contentHeight = math.max(layout.height, viewport.height);
        final contentSize = Size(contentWidth, contentHeight);
        _viewportSize = viewport;
        _contentSize = contentSize;

        return ClipRect(
          child: Listener(
            onPointerSignal: _handlePointerSignal,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    transformationController: _transformationController,
                    constrained: false,
                    boundaryMargin: EdgeInsets.zero,
                    minScale: _minScale,
                    maxScale: _maxScale,
                    scaleEnabled: false,
                    panAxis: PanAxis.free,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: contentWidth,
                      height: contentHeight,
                      child: CustomPaint(
                        painter: _ConversationTreeMapEdgePainter(
                          layout.nodes,
                          activeMessageIds: activeIds,
                          activeColor: Theme.of(context).colorScheme.primary,
                        ),
                        child: AnimatedBuilder(
                          animation: _transformationController,
                          builder: (context, child) {
                            final visibleNodes = _visibleNodes(
                              layout,
                              viewport,
                            );
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                for (final node in visibleNodes)
                                  Positioned(
                                    left:
                                        node.centerX -
                                        _TreeMapNodeCard.width / 2,
                                    top: node.top,
                                    child: _TreeMapNodeCard(
                                      key: ValueKey(
                                        'conversationTreeMapNode-${node.message.id}',
                                      ),
                                      message: node.message,
                                      isActive: activeIds.contains(
                                        node.message.id,
                                      ),
                                      isSelected:
                                          widget.selectedMessageIds?.contains(
                                            node.message.id,
                                          ) ??
                                          false,
                                      isDimmed: node.isDimmed,
                                      selecting: widget.selecting,
                                      userLabel: l10n.treeMapUserLabel,
                                      assistantLabel:
                                          l10n.treeMapAssistantLabel,
                                      onTap: () {
                                        if (widget.selecting) {
                                          widget.onToggleSelection?.call(
                                            node.message.id,
                                          );
                                        } else {
                                          widget.onTapMessage(node.message.id);
                                        }
                                      },
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 10,
                  width: 10,
                  child: _TreeMapScrollbar(
                    key: const ValueKey('conversationTreeMapVerticalScrollbar'),
                    axis: Axis.vertical,
                    controller: _transformationController,
                    viewportSize: viewport,
                    contentSize: contentSize,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 10,
                  bottom: 0,
                  height: 10,
                  child: _TreeMapScrollbar(
                    key: const ValueKey(
                      'conversationTreeMapHorizontalScrollbar',
                    ),
                    axis: Axis.horizontal,
                    controller: _transformationController,
                    viewportSize: viewport,
                    contentSize: contentSize,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<_ConversationTreeMapNode> _visibleNodes(
    _ConversationTreeMapLayout layout,
    Size viewport,
  ) {
    if (viewport.isEmpty) return layout.nodes;
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    const margin = 64.0;
    final minX = (0 - translation.x) / scale - margin;
    final maxX = (viewport.width - translation.x) / scale + margin;
    final minY = (0 - translation.y) / scale - margin;
    final maxY = (viewport.height - translation.y) / scale + margin;
    final halfWidth = _TreeMapNodeCard.width / 2;
    return [
      for (final node in layout.nodes)
        if (node.centerX + halfWidth >= minX &&
            node.centerX - halfWidth <= maxX &&
            node.top + _TreeMapNodeCard.height >= minY &&
            node.top <= maxY)
          node,
    ];
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        _viewportSize.isEmpty ||
        _contentSize.isEmpty) {
      return;
    }

    final scrollDelta = event.scrollDelta;
    if (HardwareKeyboard.instance.isControlPressed &&
        scrollDelta.dy != 0 &&
        scrollDelta.dx == 0) {
      _zoomAt(event.localPosition, scrollDelta.dy);
    } else {
      _scrollBy(scrollDelta.dx, scrollDelta.dy);
    }
  }

  void _scrollBy(double deltaX, double deltaY) {
    if (deltaX == 0 && deltaY == 0) return;
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    final nextX = _clampAxis(
      translation.x - deltaX,
      _viewportSize.width,
      _contentSize.width * scale,
    );
    final nextY = _clampAxis(
      translation.y - deltaY,
      _viewportSize.height,
      _contentSize.height * scale,
    );
    _transformationController.value = _matrixFor(Offset(nextX, nextY), scale);
  }

  void _setScale(
    double scale, {
    required Offset translation,
    required bool centerHorizontally,
  }) {
    final clampedScale = scale.clamp(_minScale, _maxScale).toDouble();
    final scaledWidth = _contentSize.width * clampedScale;
    final scaledHeight = _contentSize.height * clampedScale;
    final nextX = centerHorizontally
        ? _clampAxis(
            -(scaledWidth - _viewportSize.width) / 2,
            _viewportSize.width,
            scaledWidth,
          )
        : _clampAxis(translation.dx, _viewportSize.width, scaledWidth);
    final nextY = _clampAxis(
      translation.dy,
      _viewportSize.height,
      scaledHeight,
    );
    _transformationController.value = _matrixFor(
      Offset(nextX, nextY),
      clampedScale,
    );
  }

  void _zoomAt(Offset localPosition, double scrollDelta) {
    if (scrollDelta == 0) return;
    final matrix = _transformationController.value;
    final oldScale = matrix.getMaxScaleOnAxis();
    final factor = math.exp(-scrollDelta / 200.0);
    final newScale = (oldScale * factor).clamp(_minScale, _maxScale).toDouble();
    if ((newScale - oldScale).abs() < 0.0001) return;

    final ratio = newScale / oldScale;
    final translation = matrix.getTranslation();
    final nextX = localPosition.dx * (1 - ratio) + translation.x * ratio;
    final nextY = localPosition.dy * (1 - ratio) + translation.y * ratio;
    _transformationController.value = _matrixFor(
      Offset(
        _clampAxis(nextX, _viewportSize.width, _contentSize.width * newScale),
        _clampAxis(nextY, _viewportSize.height, _contentSize.height * newScale),
      ),
      newScale,
    );
  }

  double _clampAxis(double value, double viewportExtent, double scaledExtent) {
    final maxScroll = math.max(0.0, scaledExtent - viewportExtent);
    return value.clamp(-maxScroll, 0.0).toDouble();
  }

  Matrix4 _matrixFor(Offset translation, double scale) {
    return Matrix4.identity()
      ..translateByDouble(translation.dx, translation.dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }
}

class _TreeMapScrollbar extends StatelessWidget {
  const _TreeMapScrollbar({
    super.key,
    required this.axis,
    required this.controller,
    required this.viewportSize,
    required this.contentSize,
  });

  final Axis axis;
  final TransformationController controller;
  final Size viewportSize;
  final Size contentSize;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final vertical = axis == Axis.vertical;
            final trackLength = vertical
                ? constraints.maxHeight
                : constraints.maxWidth;
            if (!trackLength.isFinite || trackLength <= 0) {
              return const SizedBox.shrink();
            }

            final matrix = controller.value;
            final scale = matrix.getMaxScaleOnAxis();
            final contentExtent = vertical
                ? contentSize.height
                : contentSize.width;
            final viewportExtent = vertical
                ? viewportSize.height
                : viewportSize.width;
            final scaledContentExtent = contentExtent * scale;
            final maxScroll = math.max(
              0.0,
              scaledContentExtent - viewportExtent,
            );
            if (maxScroll <= 0) {
              return const SizedBox.shrink();
            }

            final thumbExtent = math.max(
              24.0,
              viewportExtent / scaledContentExtent * trackLength,
            );
            final translation = matrix.getTranslation();
            final scrollOffset = vertical
                ? (-translation.y).clamp(0.0, maxScroll).toDouble()
                : (-translation.x).clamp(0.0, maxScroll).toDouble();
            final thumbStart =
                (trackLength - thumbExtent) * scrollOffset / maxScroll;

            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: vertical
                    ? (details) => _dragBy(
                        details.delta.dy,
                        scale,
                        maxScroll,
                        trackLength,
                        thumbExtent,
                      )
                    : null,
                onHorizontalDragUpdate: vertical
                    ? null
                    : (details) => _dragBy(
                        details.delta.dx,
                        scale,
                        maxScroll,
                        trackLength,
                        thumbExtent,
                      ),
                child: SizedBox.expand(
                  child: Stack(
                    children: [
                      Positioned.fill(child: _track(context)),
                      Positioned(
                        left: vertical ? 1 : thumbStart,
                        top: vertical ? thumbStart : 1,
                        width: vertical
                            ? math.max(0, constraints.maxWidth - 2)
                            : thumbExtent,
                        height: vertical
                            ? thumbExtent
                            : math.max(0, constraints.maxHeight - 2),
                        child: _thumb(context),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _dragBy(
    double delta,
    double scale,
    double maxScroll,
    double trackLength,
    double thumbExtent,
  ) {
    if (trackLength <= thumbExtent) return;
    final scrollDelta = delta * maxScroll / (trackLength - thumbExtent);
    final matrix = controller.value;
    final translation = matrix.getTranslation();
    final scaledWidth = contentSize.width * scale;
    final scaledHeight = contentSize.height * scale;
    final minX = viewportSize.width - scaledWidth;
    final minY = viewportSize.height - scaledHeight;

    final nextX = axis == Axis.horizontal
        ? (translation.x - scrollDelta).clamp(minX, 0.0).toDouble()
        : translation.x;
    final nextY = axis == Axis.vertical
        ? (translation.y - scrollDelta).clamp(minY, 0.0).toDouble()
        : translation.y;

    controller.value = Matrix4.identity()
      ..translateByDouble(nextX, nextY, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  Widget _track(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  Widget _thumb(BuildContext context) {
    return Container(
      key: ValueKey(
        axis == Axis.vertical
            ? 'conversationTreeMapVerticalThumb'
            : 'conversationTreeMapHorizontalThumb',
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

class _TreeMapNodeCard extends StatelessWidget {
  const _TreeMapNodeCard({
    super.key,
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
