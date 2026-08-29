import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/chat/widgets/frosted/chat_frosted_backdrop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backdrop controller selects uniform, cached, and live modes', () {
    final controller = ChatFrostedBackdropController();
    addTearDown(controller.dispose);

    expect(controller.mode, FrostedRenderMode.uniform);
    controller.applyBackdropState(wallpaperActive: true);
    expect(controller.mode, FrostedRenderMode.cached);

    controller.markSnapshotUnsupported();
    expect(controller.snapshotUnsupported, isTrue);
    expect(controller.mode, FrostedRenderMode.liveBackdropFilter);

    controller.applyBackdropState(wallpaperActive: false);
    expect(controller.mode, FrostedRenderMode.uniform);
  });

  test(
    'invalidating snapshots advances generation and clears current images',
    () {
      final controller = ChatFrostedBackdropController();
      addTearDown(controller.dispose);

      final initialGeneration = controller.generation;
      controller.invalidateSnapshots();
      expect(controller.generation, initialGeneration + 1);
      expect(controller.hasAllCurrentSnapshots, isFalse);
    },
  );

  test('sample scale stays bounded for zero and large blur values', () {
    expect(frostedSampleScale(sigma: 0, dpr: 2), 0);
    expect(frostedSampleScale(sigma: 1, dpr: 2), closeTo(2, 0.001));
    expect(frostedSampleScale(sigma: 1000, dpr: 2), closeTo(0.05, 0.001));
  });
}
