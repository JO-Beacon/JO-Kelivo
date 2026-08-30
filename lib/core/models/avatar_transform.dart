import 'dart:ui';

/// Non-destructive display transform for a local avatar image.
class AvatarTransform {
  const AvatarTransform({
    this.left = 0,
    this.top = 0,
    this.width = 1,
    this.height = 1,
    this.rotation = 0,
    this.rotationDegrees = 0,
    this.flipX = false,
    this.flipY = false,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  /// Clockwise quarter turns (0..3).
  final int rotation;

  /// Additional clockwise free rotation in degrees.
  final double rotationDegrees;
  final bool flipX;
  final bool flipY;

  Rect get rect => Rect.fromLTWH(left, top, width, height);

  Map<String, dynamic> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'rotation': rotation,
    'rotationDegrees': rotationDegrees,
    'flipX': flipX,
    'flipY': flipY,
  };

  static AvatarTransform? fromJson(Object? value) {
    if (value is! Map) return null;
    double number(Object? v, double fallback) =>
        v is num ? v.toDouble() : fallback;
    final left = number(value['left'], 0).clamp(0.0, 1.0);
    final top = number(value['top'], 0).clamp(0.0, 1.0);
    final width = number(value['width'], 1).clamp(0.01, 1.0);
    final height = number(value['height'], 1).clamp(0.01, 1.0);
    final maxLeft = (1.0 - width).clamp(0.0, 1.0);
    final maxTop = (1.0 - height).clamp(0.0, 1.0);
    final turns = ((value['rotation'] as num?)?.toInt() ?? 0) % 4;
    final angle = number(value['rotationDegrees'], 0).clamp(-180.0, 180.0);
    return AvatarTransform(
      left: left.clamp(0.0, maxLeft),
      top: top.clamp(0.0, maxTop),
      width: width,
      height: height,
      rotation: turns < 0 ? turns + 4 : turns,
      rotationDegrees: angle,
      flipX: value['flipX'] == true,
      flipY: value['flipY'] == true,
    );
  }

  AvatarTransform copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
    int? rotation,
    double? rotationDegrees,
    bool? flipX,
    bool? flipY,
  }) => AvatarTransform(
    left: left ?? this.left,
    top: top ?? this.top,
    width: width ?? this.width,
    height: height ?? this.height,
    rotation: rotation ?? this.rotation,
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    flipX: flipX ?? this.flipX,
    flipY: flipY ?? this.flipY,
  );
}
