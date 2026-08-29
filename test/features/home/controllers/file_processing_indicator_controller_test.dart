import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/home/controllers/file_processing_indicator_controller.dart';

void main() {
  const delay = Duration(milliseconds: 220);
  const hold = Duration(milliseconds: 320);

  FileProcessingIndicatorController create() =>
      FileProcessingIndicatorController(showDelay: delay, minVisible: hold);

  test('短解析不会显示指示器', () {
    fakeAsync((async) {
      final controller = create();
      controller.start('assistant-a');
      async.elapse(const Duration(milliseconds: 100));
      controller.finish('assistant-a');
      async.elapse(const Duration(seconds: 1));
      expect(controller.messageId.value, isNull);
      controller.dispose();
    });
  });

  test('指示器显示后至少保持最短展示时间', () {
    fakeAsync((async) {
      final controller = create();
      controller.start('assistant-a');
      async.elapse(delay);
      expect(controller.messageId.value, 'assistant-a');
      controller.finish('assistant-a');
      expect(controller.messageId.value, 'assistant-a');
      async.elapse(hold);
      expect(controller.messageId.value, isNull);
      controller.dispose();
    });
  });

  test('其它消息的结束不会清掉当前归属', () {
    fakeAsync((async) {
      final controller = create();
      controller.start('assistant-b');
      async.elapse(delay);
      controller.finish('assistant-a');
      expect(controller.messageId.value, 'assistant-b');
      controller.dispose();
    });
  });

  test('新消息会接管旧消息并清理待显示计时', () {
    fakeAsync((async) {
      final controller = create();
      controller.start('assistant-a');
      async.elapse(const Duration(milliseconds: 100));
      controller.start('assistant-b');
      async.elapse(delay);
      expect(controller.messageId.value, 'assistant-b');
      controller.dispose();
    });
  });
}
