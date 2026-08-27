import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/home/services/chat_read_position_store.dart';

import '../../../support/business_test_harness.dart';

void main() {
  test('loads existing read positions and updates them', () async {
    final harness = await createBusinessTestHarness(
      initial: const {
        ChatReadPositionStore.preferenceKey: '{"conv-a":"msg-1"}',
      },
    );
    final store = ChatReadPositionStore(harness.preferences);

    await store.load();
    expect(store.read('conv-a'), 'msg-1');

    await store.write('conv-b', 'msg-2');
    expect(store.read('conv-b'), 'msg-2');
    expect(store.read('conv-a'), 'msg-1');
  });

  test('null write removes the conversation position', () async {
    final harness = await createBusinessTestHarness();
    final store = ChatReadPositionStore(harness.preferences);

    await store.write('conv-a', 'msg-1');
    expect(store.read('conv-a'), 'msg-1');

    await store.write('conv-a', null);
    expect(store.read('conv-a'), isNull);
  });

  test('tolerates malformed persisted payloads', () async {
    final harness = await createBusinessTestHarness(
      initial: const {ChatReadPositionStore.preferenceKey: 'not-json'},
    );
    final store = ChatReadPositionStore(harness.preferences);

    await store.load();
    expect(store.read('conv-a'), isNull);
  });
}
