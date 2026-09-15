import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'flutter_logger.dart';

/// 启动记录：把一次启动的经过写进应用日志。
///
/// 它补的是日志系统自身的一处盲区。日志开关要到启动收尾（读完偏好设置）才
/// 被读到，而启动问题恰好发生在那之前——那一段原本没有任何记录，出问题时
/// 只能靠排除法猜。这里给出两样东西：
///
/// 1. 启动最早期即可用的同步通道（见 [FlutterLogger.bootstrap]），让脚印从
///    “程序刚进来”就开始落盘，且进程随后被强制结束也不会丢；
/// 2. 各关键节点的埋点：走到哪一步、第一帧有没有画出来、之后进程是否还活着。
///
/// 记录内容与其它日志同文件（`logs/flutter_logs.txt`）、同格式、同轮转规则，
/// 并和它们一样受设置里的“应用日志打印”开关控制。**开关关闭时本类的每个
/// 入口都是空操作**，不注册回调、不起定时器、不写盘。
class StartupRecorder {
  StartupRecorder._();

  /// 心跳周期与总时长。
  ///
  /// 心跳回答的是“进程是否还活着、画面是否还在产出”。它只在启动后的一段
  /// 时间内运行：启动问题总在启动后不久被发现，长期运行既无必要，也会让
  /// 日志无谓增长。两分钟足以覆盖“看到白屏、再去任务管理器看一眼”的间隔。
  static const Duration _heartbeatInterval = Duration(seconds: 2);
  static const Duration _heartbeatWindow = Duration(seconds: 120);

  static int _frames = 0;
  static int _beats = 0;
  static Timer? _heartbeat;
  static bool _frameCounterInstalled = false;

  /// 是否应当记录。与普通日志共用同一个开关：关着就什么都不做。
  static bool get _active => FlutterLogger.enabled;

  /// 安装帧计数器。渲染管线每真正产出一帧都会被累计一次。
  ///
  /// 只累加计数，不写盘，因此可以一直挂着；具体数值由心跳定期带出。
  static void installFrameCounter() {
    if (!_active || _frameCounterInstalled) return;
    _frameCounterInstalled = true;
    WidgetsBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
      _frames += timings.length;
    });
  }

  /// 记录某一层界面的首帧。
  ///
  /// [waitForRaster] 为真时额外记录光栅化完成时刻——它比“构建完成”更接近
  /// 真正把画面交给系统，用于区分“帧没生成”与“帧生成了没上屏”。
  static void watchFirstFrame(String label, {bool waitForRaster = false}) {
    if (!_active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterLogger.stage('$label first frame built', tag: 'Frame');
    });
    if (!waitForRaster) return;
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      FlutterLogger.stage('$label first frame rasterized', tag: 'Frame');
    }).catchError((Object _) {});
  }

  /// 启动心跳。
  ///
  /// 刻意只观察、不干预：它**不调用** `scheduleFrame()`。渲染管线该产帧时
  /// 自会产帧，而这类排查要问的恰恰是“该产帧的时候产了没有”；主动请求帧
  /// 会把要观察的现象自己刷掉。
  static void startHeartbeat() {
    if (!_active) return;
    _heartbeat?.cancel();
    _beats = 0;
    final totalBeats =
        _heartbeatWindow.inMilliseconds ~/ _heartbeatInterval.inMilliseconds;
    _heartbeat = Timer.periodic(_heartbeatInterval, (Timer timer) {
      _beats++;
      FlutterLogger.stage(
        'heartbeat beats=$_beats frames=$_frames rss=${_rssMib()}MiB',
        tag: 'Startup',
      );
      if (_beats >= totalBeats) timer.cancel();
    });
  }

  static String _rssMib() {
    try {
      return (ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1);
    } catch (_) {
      return '?';
    }
  }
}
