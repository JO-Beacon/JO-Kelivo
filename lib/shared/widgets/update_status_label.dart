import 'package:flutter/material.dart';

import '../../theme/app_font_weights.dart';

class UpdateStatusLabel extends StatelessWidget {
  const UpdateStatusLabel({
    super.key,
    required this.label,
    required this.icon,
    required this.enabled,
  });

  final String label;
  final IconData icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: enabled ? 0.72 : 0.45);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              fontWeight: AppFontWeights.semibold,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
