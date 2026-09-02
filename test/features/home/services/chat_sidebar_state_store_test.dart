import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/home/services/chat_sidebar_state_store.dart';

import '../../../support/business_test_harness.dart';

void main() {
  test('persists the last opened conversation and assistant offsets', () async {
    final harness = await createBusinessTestHarness();
    final first = ChatSidebarStateStore(harness.preferences);
    await first.load();

    await first.setLastOpenedConversationId('conversation-b');
    await first.setAssistantScrollOffset('assistant-tab', 128.5);

    final second = ChatSidebarStateStore(harness.preferences);
    await second.load();
    expect(second.lastOpenedConversationId, 'conversation-b');
    expect(second.assistantScrollOffset('assistant-tab'), 128.5);
    expect(second.assistantScrollOffset('assistant-inline'), 0);
  });

  test(
    'clears an empty last opened conversation id and rejects bad offsets',
    () async {
      final harness = await createBusinessTestHarness();
      final store = ChatSidebarStateStore(harness.preferences);
      await store.load();

      await store.setLastOpenedConversationId('conversation-a');
      await store.setLastOpenedConversationId(' ');
      await store.setAssistantScrollOffset('assistant-tab', -1);
      await store.setAssistantScrollOffset('assistant-tab', double.nan);

      expect(store.lastOpenedConversationId, isNull);
      expect(store.assistantScrollOffset('assistant-tab'), 0);
    },
  );

  test('ignores malformed assistant offset payloads', () async {
    final harness = await createBusinessTestHarness(
      initial: const {
        ChatSidebarStateStore.assistantScrollOffsetsKey: 'not-json',
      },
    );
    final store = ChatSidebarStateStore(harness.preferences);

    await store.load();
    expect(store.assistantScrollOffset('assistant-tab'), 0);
  });
}
