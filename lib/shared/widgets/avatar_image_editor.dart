import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/models/avatar_transform.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';

class AvatarImageEditResult {
  const AvatarImageEditResult(this.transform);
  final AvatarTransform transform;
}

Future<AvatarImageEditResult?> showAvatarImageEditor(
  BuildContext context,
  String path, {
  AvatarTransform? initial,
}) {
  return showDialog<AvatarImageEditResult>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.9,
        ),
        child: _AvatarImageEditor(
          path: path,
          initial: initial ?? const AvatarTransform(),
        ),
      ),
    ),
  );
}

class _AvatarImageEditor extends StatefulWidget {
  const _AvatarImageEditor({required this.path, required this.initial});
  final String path;
  final AvatarTransform initial;
  @override
  State<_AvatarImageEditor> createState() => _AvatarImageEditorState();
}

class _AvatarImageEditorState extends State<_AvatarImageEditor> {
  late double _left, _top, _width, _height, _angle;
  late int _rotation;
  late bool _flipX, _flipY;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    // The editor always uses a square frame. Normalize older rectangular
    // transforms when they are opened, while keeping their source image.
    final size = math.min(t.width, t.height).clamp(0.08, 1.0);
    _width = size;
    _height = size;
    _left = t.left.clamp(0.0, 1.0 - size);
    _top = t.top.clamp(0.0, 1.0 - size);
    _rotation = t.rotation;
    _angle = t.rotationDegrees;
    _flipX = t.flipX;
    _flipY = t.flipY;
  }

  void _reset() => setState(() {
    _left = 0;
    _top = 0;
    _width = 1;
    _height = 1;
    _rotation = 0;
    _angle = 0;
    _flipX = false;
    _flipY = false;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return SafeArea(
      top: false,
      child: Material(
        color: cs.surface,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 12 + bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.avatarEditorTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _reset,
                      icon: const Icon(Lucide.RotateCcw, size: 17),
                      label: Text(l10n.avatarEditorReset),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.avatarEditorCropHint,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.62),
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final side = math.min(constraints.maxWidth, 380.0);
                    return SizedBox(
                      width: side,
                      height: side,
                      child: _CropCanvas(
                        path: widget.path,
                        left: _left,
                        top: _top,
                        width: _width,
                        height: _height,
                        rotation: _rotation,
                        angle: _angle,
                        flipX: _flipX,
                        flipY: _flipY,
                        onChanged: (l, t, w, h) => setState(() {
                          _left = l;
                          _top = t;
                          _width = w;
                          _height = h;
                        }),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            setState(() => _rotation = (_rotation + 3) % 4),
                        icon: const Icon(Lucide.RotateCcw, size: 18),
                        label: Text(l10n.avatarEditorRotateLeft),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            setState(() => _rotation = (_rotation + 1) % 4),
                        icon: const Icon(Lucide.RotateCw, size: 18),
                        label: Text(l10n.avatarEditorRotateRight),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() => _flipX = !_flipX),
                        icon: const Icon(Lucide.FlipHorizontal2, size: 18),
                        label: Text(l10n.avatarEditorFlipHorizontal),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() => _flipY = !_flipY),
                        icon: const Icon(Lucide.FlipVertical2, size: 18),
                        label: Text(l10n.avatarEditorFlipVertical),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Text(l10n.avatarEditorFreeRotation),
                    Expanded(
                      child: Slider(
                        value: _angle,
                        min: -180,
                        max: 180,
                        divisions: 360,
                        label: '${_angle.round()}°',
                        onChanged: (v) => setState(() => _angle = v),
                      ),
                    ),
                    SizedBox(width: 42, child: Text('${_angle.round()}°')),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.avatarEditorCancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(
                        context,
                        AvatarImageEditResult(
                          AvatarTransform(
                            left: _left,
                            top: _top,
                            width: _width,
                            height: _height,
                            rotation: _rotation,
                            rotationDegrees: _angle,
                            flipX: _flipX,
                            flipY: _flipY,
                          ),
                        ),
                      ),
                      icon: const Icon(Lucide.Check, size: 18),
                      label: Text(l10n.avatarEditorDone),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CropCanvas extends StatefulWidget {
  const _CropCanvas({
    required this.path,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.rotation,
    required this.angle,
    required this.flipX,
    required this.flipY,
    required this.onChanged,
  });
  final String path;
  final double left, top, width, height, angle;
  final int rotation;
  final bool flipX, flipY;
  final void Function(double, double, double, double) onChanged;

  @override
  State<_CropCanvas> createState() => _CropCanvasState();
}

class _CropCanvasState extends State<_CropCanvas> {
  double _startLeft = 0;
  double _startTop = 0;
  double _startSize = 1;
  Offset _startFocal = Offset.zero;
  double _frameSide = 0;
  int? _mousePointer;
  Offset _mouseStart = Offset.zero;
  double _mouseStartLeft = 0;
  double _mouseStartTop = 0;

  Offset _frameLocal(Offset canvasPosition) {
    final inset = _frameSide * (1 - 0.78) / 2;
    return canvasPosition - Offset(inset, inset);
  }

  void _beginScale(ScaleStartDetails details) {
    _startLeft = widget.left;
    _startTop = widget.top;
    _startSize = math.min(widget.width, widget.height).clamp(0.08, 1.0);
    final inset = _frameSide * (1 - 0.78) / 2;
    _startFocal = details.localFocalPoint - Offset(inset, inset);
  }

  void _updateScale(ScaleUpdateDetails details) {
    if (_frameSide <= 0) return;
    final frameSide = _frameSide * 0.78;
    // Gesture coordinates are local to the fixed frame itself.
    const frameLeft = 0.0;
    const frameTop = 0.0;
    final focalX = ((_startFocal.dx - frameLeft) / frameSide).clamp(0.0, 1.0);
    final focalY = ((_startFocal.dy - frameTop) / frameSide).clamp(0.0, 1.0);
    final sourceX = _startLeft + focalX * _startSize;
    final sourceY = _startTop + focalY * _startSize;
    final size = (_startSize / details.scale).clamp(0.08, 1.0);
    final inset = _frameSide * (1 - 0.78) / 2;
    final currentFocal = details.localFocalPoint - Offset(inset, inset);
    final currentX = (currentFocal.dx - frameLeft) / frameSide;
    final currentY = (currentFocal.dy - frameTop) / frameSide;
    final left = (sourceX - currentX * size).clamp(0.0, 1.0 - size);
    final top = (sourceY - currentY * size).clamp(0.0, 1.0 - size);
    widget.onChanged(left, top, size, size);
  }

  void _mouseDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons & kPrimaryButton == 0) {
      return;
    }
    _mousePointer = event.pointer;
    _mouseStart = event.localPosition;
    _mouseStartLeft = widget.left;
    _mouseStartTop = widget.top;
  }

  void _mouseMove(PointerMoveEvent event) {
    if (_mousePointer != event.pointer ||
        event.buttons & kPrimaryButton == 0 ||
        _frameSide <= 0) {
      return;
    }
    final frameSide = _frameSide * 0.78;
    final size = math.min(widget.width, widget.height).clamp(0.08, 1.0);
    final delta = event.localPosition - _mouseStart;
    final left = (_mouseStartLeft - delta.dx / frameSide * size).clamp(
      0.0,
      1.0 - size,
    );
    final top = (_mouseStartTop - delta.dy / frameSide * size).clamp(
      0.0,
      1.0 - size,
    );
    widget.onChanged(left, top, size, size);
  }

  void _mouseEnd(PointerEvent event) {
    if (_mousePointer == event.pointer) _mousePointer = null;
  }

  void _mouseWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _frameSide <= 0) return;
    final zoomFactor = event.scrollDelta.dy > 0 ? 1 / 1.12 : 1.12;
    final frameSide = _frameSide * 0.78;
    final size = math.min(widget.width, widget.height).clamp(0.08, 1.0);
    final focal = _frameLocal(event.localPosition);
    final focalX = (focal.dx / frameSide).clamp(0.0, 1.0);
    final focalY = (focal.dy / frameSide).clamp(0.0, 1.0);
    final sourceX = widget.left + focalX * size;
    final sourceY = widget.top + focalY * size;
    final nextSize = (size / zoomFactor).clamp(0.08, 1.0);
    final left = (sourceX - focalX * nextSize).clamp(0.0, 1.0 - nextSize);
    final top = (sourceY - focalY * nextSize).clamp(0.0, 1.0 - nextSize);
    widget.onChanged(left, top, nextSize, nextSize);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = constraints.biggest.shortestSide;
      _frameSide = side;
      final frameSide = side * 0.78;
      final frame = Rect.fromCenter(
        center: Offset(side / 2, side / 2),
        width: frameSide,
        height: frameSide,
      );
      final size = math.min(widget.width, widget.height).clamp(0.08, 1.0);
      final left = widget.left.clamp(0.0, 1.0 - size);
      final top = widget.top.clamp(0.0, 1.0 - size);
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: ClipRect(
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..scaleByDouble(
                      widget.flipX ? -1.0 : 1.0,
                      widget.flipY ? -1.0 : 1.0,
                      1.0,
                      1.0,
                    )
                    ..rotateZ(
                      (widget.rotation * 90 + widget.angle) * math.pi / 180,
                    ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        left: frame.left - left * frameSide / size,
                        top: frame.top - top * frameSide / size,
                        width: frameSide / size,
                        height: frameSide / size,
                        child: Image.file(File(widget.path), fit: BoxFit.cover),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _mouseDown,
                onPointerMove: _mouseMove,
                onPointerUp: _mouseEnd,
                onPointerCancel: _mouseEnd,
                onPointerSignal: _mouseWheel,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  supportedDevices: const {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.trackpad,
                  },
                  onScaleStart: _beginScale,
                  onScaleUpdate: _updateScale,
                ),
              ),
            ),
            IgnorePointer(
              child: CustomPaint(
                painter: _CropOverlayPainter(
                  rect: frame,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _CropOverlayPainter extends CustomPainter {
  const _CropOverlayPainter({required this.rect, required this.color});
  final Rect rect;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()..addRect(Offset.zero & size);
    final inside = Path()..addRect(rect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outside, inside),
      Paint()..color = Colors.black.withValues(alpha: 0.52),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final grid = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = rect.left + rect.width * i / 3,
          y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter old) =>
      old.rect != rect || old.color != color;
}

class AvatarImage extends StatelessWidget {
  const AvatarImage({
    super.key,
    required this.path,
    required this.size,
    this.transform,
  });
  final String path;
  final double size;
  final AvatarTransform? transform;
  @override
  Widget build(BuildContext context) {
    final t = transform ?? const AvatarTransform();
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: ClipRect(
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..scaleByDouble(
                t.flipX ? -1.0 : 1.0,
                t.flipY ? -1.0 : 1.0,
                1.0,
                1.0,
              )
              ..rotateZ((t.rotation * 90 + t.rotationDegrees) * math.pi / 180),
            child: FractionallySizedBox(
              widthFactor: 1 / t.width,
              heightFactor: 1 / t.height,
              alignment: Alignment(
                -1 + 2 * t.left / t.width,
                -1 + 2 * t.top / t.height,
              ),
              child: Image.file(File(path), fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }
}
