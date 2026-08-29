import 'package:flutter/material.dart';

class UpdateStatusLabel extends StatefulWidget {
  const UpdateStatusLabel({
    super.key,
    required this.label,
    required this.icon,
    required this.checking,
  });

  final String label;
  final IconData icon;
  final bool checking;

  @override
  State<UpdateStatusLabel> createState() => _UpdateStatusLabelState();
}

class _UpdateStatusLabelState extends State<UpdateStatusLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant UpdateStatusLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.checking != widget.checking) _syncRotation();
  }

  void _syncRotation() {
    if (widget.checking) {
      _rotationController.repeat();
    } else {
      _rotationController
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = widget.checking
        ? cs.primary.withValues(alpha: 0.9)
        : cs.onSurface.withValues(alpha: 0.58);
    return Semantics(
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        excludeFromSemantics: true,
        child: SizedBox.square(
          dimension: 32,
          child: Center(
            child: RotationTransition(
              turns: _rotationController,
              child: Icon(widget.icon, size: 20, color: color),
            ),
          ),
        ),
      ),
    );
  }
}
