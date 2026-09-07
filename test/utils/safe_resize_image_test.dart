import 'dart:typed_data';

import 'package:Kelivo/utils/safe_resize_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('contain keeps a non-zero minor axis and honors pixel budget', () {
    final target = computeSafeResizeTarget(
      intrinsicWidth: 17277,
      intrinsicHeight: 11457,
      boxWidth: 720,
      boxHeight: 360,
      fit: SafeResizeFit.contain,
      maxEdge: 4096,
      maxPixels: 12 * 1024 * 1024,
    );
    expect(target.width, lessThan(17277));
    expect(target.height, lessThan(11457));
    expect(target.width, greaterThanOrEqualTo(1));
    expect(target.height, greaterThanOrEqualTo(1));
    expect(target.width * target.height, lessThanOrEqualTo(12 * 1024 * 1024));
  });

  test('cover keeps the crop box large enough without upscaling', () {
    final target = computeSafeResizeTarget(
      intrinsicWidth: 4000,
      intrinsicHeight: 1000,
      boxWidth: 336,
      boxHeight: 336,
      fit: SafeResizeFit.cover,
    );
    expect(target.width, 1344);
    expect(target.height, 336);
    final small = computeSafeResizeTarget(
      intrinsicWidth: 80,
      intrinsicHeight: 80,
      boxWidth: 336,
      boxHeight: 336,
      fit: SafeResizeFit.cover,
    );
    expect(small.width, 80);
    expect(small.height, 80);
  });

  test('cache key includes policy and size', () {
    final image = MemoryImage(Uint8List.fromList([1, 2, 3]));
    final a = SafeResizeImage(
      image,
      width: 100,
      height: 80,
      fit: SafeResizeFit.contain,
      allowUpscaling: false,
    );
    expect(a, SafeResizeImage(image, width: 100, height: 80));
    expect(a, isNot(SafeResizeImage(image, width: 120, height: 80)));
    expect(
      a,
      isNot(
        SafeResizeImage(
          image,
          width: 100,
          height: 80,
          fit: SafeResizeFit.cover,
        ),
      ),
    );
  });
}
