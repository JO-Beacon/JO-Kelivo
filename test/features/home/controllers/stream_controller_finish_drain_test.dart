import '../../../support/business_test_harness.dart';

import 'dart:async';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/controllers/stream_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const messageId = 'assistant-message';

  StreamController buildController() {
    final settings = SettingsProvider(createBusinessTestPreferences());
    return StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      getSettingsProvider: () => settings,
      getCurrentConversationId: () => 'conversation-1',
    );
  }

  void scheduleBurst(StreamController controller, String content) {
    controller.scheduleThrottledUpdate(
      messageId,
      'conversation-1',
      () => content,
      updateMessageInList: (_, _, _) {},
      totalTokens: 10,
    );
  }

  testWidgets('结束时先排空平滑缓冲，减少最终帧的内容跳变', (tester) async {
    final controller = buildController();
    final notifier = controller.streamingContentNotifier.getNotifier(messageId);
    final published = <int>[];
    notifier.addListener(() => published.add(notifier.value.content.length));

    final content = 'x' * 2000;
    scheduleBurst(controller, content);
    await tester.pump(const Duration(milliseconds: 100));
    final backlogBeforeDrain = content.length - notifier.value.content.length;
    expect(backlogBeforeDrain, greaterThan(200));

    final drain = controller.drainSmoothStream(messageId);
    for (var tick = 0; tick < 10; tick++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await drain;
    final backlogAfterDrain = content.length - notifier.value.content.length;
    controller.cleanupTimers(messageId);

    expect(backlogAfterDrain, lessThan(backlogBeforeDrain));
    expect(published, isNotEmpty);
    controller.dispose();
  });

  testWidgets('排空受时间预算约束，不会无限拖住结束流程', (tester) async {
    final controller = buildController();
    scheduleBurst(controller, 'x' * 400000);

    var completed = false;
    unawaited(
      controller
          .drainSmoothStream(
            messageId,
            budget: const Duration(milliseconds: 100),
          )
          .then((_) => completed = true),
    );
    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(completed, isTrue);
    controller.dispose();
  });
}
