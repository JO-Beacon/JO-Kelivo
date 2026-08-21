import 'package:flutter/material.dart';

import 'package:Kelivo/theme/app_semantic_colors.dart';

/// 工具详情视图中带标签的文本块，以 sliver 方式渲染。
///
/// 小载荷作为单个 [Text] 渲染。大载荷会拆分为
/// 按需构建有行数上限的块，因此打开详情视图时
/// 不会一次布局整个数 MB 的工具结果。
class ToolDetailTextSection extends StatelessWidget {
  const ToolDetailTextSection({
    super.key,
    required this.label,
    required this.text,
    this.textStyle = const TextStyle(fontSize: 12),
  });

  /// 超过此行数（或字符数）后，文本会分块并延迟构建。
  static const int lazyLineThreshold = 120;
  static const int lazyCharThreshold = 8000;
  static const int chunkLines = 40;

  static const ValueKey<String> lazyListKey = ValueKey(
    'tool-detail-text-lazy-list',
  );

  final String label;
  final String text;
  final TextStyle textStyle;

  static bool shouldChunk(String text) {
    if (text.length > lazyCharThreshold) return true;
    var lines = 1;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        lines++;
        if (lines > lazyLineThreshold) return true;
      }
    }
    return false;
  }

  static List<String> chunksOf(String text) {
    final lines = text.split('\n');
    final chunks = <String>[];
    for (var start = 0; start < lines.length; start += chunkLines) {
      final end = (start + chunkLines).clamp(0, lines.length);
      chunks.add(lines.sublist(start, end).join('\n'));
    }
    return chunks.isEmpty ? <String>[text] : chunks;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final decoration = BoxDecoration(
      color: context.appColors.surfaceFill,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.2)),
    );

    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );

    if (!shouldChunk(text)) {
      return SliverMainAxisGroup(
        slivers: [
          header,
          SliverToBoxAdapter(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: decoration,
              child: Text(text, style: textStyle),
            ),
          ),
        ],
      );
    }

    final chunks = chunksOf(text);
    return SliverMainAxisGroup(
      slivers: [
        header,
        DecoratedSliver(
          decoration: decoration,
          sliver: SliverPadding(
            padding: const EdgeInsets.all(10),
            sliver: SliverList.builder(
              key: lazyListKey,
              itemCount: chunks.length,
              itemBuilder: (context, index) => Text(
                chunks[index],
                key: ValueKey('tool-detail-text-chunk-$index'),
                style: textStyle,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
