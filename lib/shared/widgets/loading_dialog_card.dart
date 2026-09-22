import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../animations/widgets.dart';

class LoadingDialogCard extends StatelessWidget {
  const LoadingDialogCard({
    super.key,
    this.label,
    this.progress,
    this.phaseLabel,
    this.onCancel,
    this.cancelLabel,
  });

  final String? label;

  /// 0..1 的总体进度；为 null 时进度条退化为不确定的扫动动画。
  final double? progress;

  /// 当前阶段的文字（例如「正在打包」）。有进度时显示在百分比旁边。
  final String? phaseLabel;

  final VoidCallback? onCancel;
  final String? cancelLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasLabel = label != null && label!.trim().isNotEmpty;
    final hasPhase = phaseLabel != null && phaseLabel!.trim().isNotEmpty;
    final fraction = progress;
    final percentText = fraction == null
        ? null
        : '${(fraction.clamp(0.0, 1.0) * 100).round()}%';

    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.96, end: 1),
        duration: kAnimSlow,
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Transform.scale(scale: value, child: child);
        },
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 240),
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.2),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  hasLabel ? 16 : 18,
                  20,
                  hasLabel ? 16 : 18,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CupertinoActivityIndicator(radius: 16),
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.all(Radius.circular(999)),
                      child: LinearProgressIndicator(
                        minHeight: 4,
                        value: progress,
                        backgroundColor: cs.surfaceContainerHighest,
                        color: cs.primary,
                      ),
                    ),
                    if (hasLabel || hasPhase) ...[
                      const SizedBox(height: 12),
                      Text(
                        hasPhase ? phaseLabel! : label!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                    if (percentText != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        percentText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      ),
                    ],
                    if (onCancel != null && cancelLabel != null) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: onCancel,
                        child: Text(cancelLabel!),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
