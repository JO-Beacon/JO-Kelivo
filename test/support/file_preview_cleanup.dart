import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 关闭预览并验证测试文件可以删除，不把异步关闭误判为文件泄漏。
Future<void> closeFilePreview(WidgetTester tester, File file) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    // 读取队列及 close 的回调可能来自 widget 测试的虚拟异步区。
    await tester.pump();
    final deleted = (await tester.runAsync(() async {
      try {
        await file.delete();
        return true;
      } on FileSystemException catch (error) {
        if (!Platform.isWindows ||
            error.osError?.errorCode != 32 ||
            !DateTime.now().isBefore(deadline)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return false;
      }
    }))!;
    if (deleted) return;
  }
}
