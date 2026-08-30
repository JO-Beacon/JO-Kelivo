import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/avatar_transform.dart';

void main() {
  test('round trips display crop and rotation', () {
    const original = AvatarTransform(
      left: 0.12,
      top: 0.2,
      width: 0.6,
      height: 0.6,
      rotation: 3,
      rotationDegrees: -24.5,
      flipX: true,
      flipY: false,
    );
    final decoded = AvatarTransform.fromJson(original.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.left, closeTo(0.12, 0.0001));
    expect(decoded.top, closeTo(0.2, 0.0001));
    expect(decoded.width, closeTo(0.6, 0.0001));
    expect(decoded.rotation, 3);
    expect(decoded.rotationDegrees, closeTo(-24.5, 0.0001));
    expect(decoded.flipX, isTrue);
  });

  test('clamps invalid values and normalizes rotation', () {
    final decoded = AvatarTransform.fromJson({
      'left': 2,
      'top': -1,
      'width': 4,
      'height': 0,
      'rotation': -1,
    });
    expect(decoded, isNotNull);
    expect(decoded!.left, 0);
    expect(decoded.top, 0);
    expect(decoded.width, 1);
    expect(decoded.height, 0.01);
    expect(decoded.rotation, 3);
  });

  test('missing or malformed JSON returns null', () {
    expect(AvatarTransform.fromJson(null), isNull);
    expect(AvatarTransform.fromJson('not-an-object'), isNull);
  });
}
