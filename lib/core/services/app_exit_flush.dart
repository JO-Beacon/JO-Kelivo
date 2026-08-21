import 'dart:async';

import 'package:flutter/foundation.dart';

/// 进程退出时刷新的注册表（仅桌面端）。
///
/// 处理程序在 AppLifecycleListener.onExitRequested 中运行，以便内存写入队列在
/// 进程退出前到达持久化存储。处理程序必须快速且幂等；失败的处理程序会被跳过，
/// 使后续处理程序仍能继续运行。
final class AppExitFlush {
  AppExitFlush._();

  static final List<Future<void> Function()> _handlers =
      <Future<void> Function()>[];

  static void register(Future<void> Function() handler) {
    _handlers.add(handler);
  }

  static Future<void> flushAll() async {
    for (final handler in List<Future<void> Function()>.of(_handlers)) {
      try {
        await handler();
      } catch (_) {}
    }
  }

  @visibleForTesting
  static void debugReset() {
    _handlers.clear();
  }
}
