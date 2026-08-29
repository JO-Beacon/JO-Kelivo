import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/home/controllers/streaming_content_notifier.dart';

void main() {
  test('coalesces tool height notifications within one microtask', () async {
    final notifier = StreamingContentNotifier();
    addTearDown(notifier.dispose);
    final events = <ToolHeightEvent>[];
    notifier.toolHeightEvents.addListener(() {
      final event = notifier.toolHeightEvents.value;
      if (event != null) events.add(event);
    });

    notifier.notifyToolHeightChanged('message-1');
    notifier.notifyToolHeightChanged('message-1');
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single.messageId, 'message-1');
    expect(events.single.version, 1);
  });
}
