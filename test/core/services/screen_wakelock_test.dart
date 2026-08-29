import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/screen_wakelock.dart';

void main() {
  tearDown(ScreenWakelock.debugReset);

  test('disabled by default and does not apply platform lock', () {
    final calls = <bool>[];
    ScreenWakelock.debugReset(platformApply: calls.add);

    ScreenWakelock.acquire();

    expect(ScreenWakelock.debugEnabled, isFalse);
    expect(ScreenWakelock.debugHolders, 1);
    expect(ScreenWakelock.debugHeld, isFalse);
    expect(calls, isEmpty);
  });

  test('reference count keeps lock until the last generation ends', () {
    fakeAsync((async) {
      final calls = <bool>[];
      ScreenWakelock.debugReset(platformApply: calls.add);
      ScreenWakelock.setEnabled(true);

      ScreenWakelock.acquire();
      ScreenWakelock.acquire();
      ScreenWakelock.release();

      expect(ScreenWakelock.debugHolders, 1);
      expect(ScreenWakelock.debugHeld, isTrue);
      expect(calls, <bool>[true]);

      ScreenWakelock.release();
      async.elapse(const Duration(seconds: 9));
      expect(ScreenWakelock.debugHeld, isTrue);
      expect(calls, <bool>[true]);

      async.elapse(const Duration(seconds: 1));
      expect(ScreenWakelock.debugHeld, isFalse);
      expect(calls, <bool>[true, false]);
    });
  });

  test(
    'disabling releases immediately and re-enabling restores active holders',
    () {
      final calls = <bool>[];
      ScreenWakelock.debugReset(platformApply: calls.add);

      ScreenWakelock.acquire();
      ScreenWakelock.setEnabled(true);
      ScreenWakelock.setEnabled(false);
      ScreenWakelock.setEnabled(true);

      expect(ScreenWakelock.debugHolders, 1);
      expect(calls, <bool>[true, false, true]);
    },
  );

  test('failed platform apply rolls back so the next apply retries', () {
    fakeAsync((async) {
      var shouldFail = true;
      final calls = <bool>[];
      ScreenWakelock.debugReset(
        platformApply: (enable) async {
          calls.add(enable);
          if (shouldFail) throw StateError('platform unavailable');
        },
      );
      ScreenWakelock.setEnabled(true);
      ScreenWakelock.acquire();
      async.flushMicrotasks();

      expect(ScreenWakelock.debugHeld, isFalse);
      shouldFail = false;
      ScreenWakelock.reassert();
      async.flushMicrotasks();

      expect(ScreenWakelock.debugHeld, isTrue);
      expect(calls, <bool>[true, true]);
    });
  });

  test('reassert applies the lock again after app resume', () {
    final calls = <bool>[];
    ScreenWakelock.debugReset(platformApply: calls.add);
    ScreenWakelock.setEnabled(true);
    ScreenWakelock.acquire();

    ScreenWakelock.reassert();

    expect(calls, <bool>[true, true]);
  });
}
