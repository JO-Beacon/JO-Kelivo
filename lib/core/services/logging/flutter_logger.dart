import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../utils/app_directories.dart';
import 'log_redactor.dart';

class FlutterLogger {
  FlutterLogger._();

  static const String _activeFileName = 'flutter_logs.txt';
  static const String _rotatedFilePrefix = 'flutter_logs_';

  /// 设置页里“应用日志打印”对应的偏好设置键。
  static const String _enabledPrefKey = 'flutter_log_enabled_v1';

  static bool _enabled = false;
  static bool get enabled => _enabled;
  static bool _writeErrorReported = false;
  static bool _syncWriteErrorReported = false;

  /// 开关值读不到（文件缺失、格式变化、解析失败）时采用的默认值。
  ///
  /// 恒为 false：没设置过就当作不记录，与历史行为一致。启动早期的同步解析
  /// 与启动后半段的偏好加载都以它为兜底，两处必须一致，否则启动中途会被关掉。
  static const bool defaultEnabled = false;

  /// 启动最早期同步解析出的应用数据目录；为 null 表示尚未引导。
  static Directory? _earlyDir;
  static bool _bootstrapped = false;

  /// 引导完成前产生的阶段脚印，暂存内存，引导时按原时间戳补写。
  static final List<String> _pendingStages = <String>[];

  static Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    if (!v) {
      try {
        await _sink?.flush();
      } catch (_) {}
      try {
        await _sink?.close();
      } catch (_) {}
      _sink = null;
      _sinkDate = null;
    } else {
      _writeErrorReported = false;
    }
  }

  static bool _installed = false;
  static FlutterExceptionHandler? _originalFlutterOnError;
  static bool Function(Object, StackTrace)? _originalPlatformOnError;

  static void installGlobalHandlers() {
    if (_installed) return;
    _installed = true;

    _originalFlutterOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      try {
        log(details.toString().trimRight(), tag: 'FlutterError');
      } catch (_) {}

      final original = _originalFlutterOnError;
      if (original != null) {
        original(details);
      } else {
        FlutterError.dumpErrorToConsole(details);
      }
    };

    _originalPlatformOnError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      try {
        log('$error\n$stack', tag: 'Uncaught');
      } catch (_) {}

      final original = _originalPlatformOnError;
      if (original != null) return original(error, stack);
      return false;
    };
  }

  static IOSink? _sink;
  static DateTime? _sinkDate;
  static Future<void> _writeQueue = Future<void>.value();

  static String _two(int v) => v.toString().padLeft(2, '0');
  static DateTime _dayOf(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
  static String _formatDate(DateTime dt) =>
      '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';
  static String _formatTs(DateTime dt) {
    return '${_formatDate(dt)} ${_two(dt.hour)}:${_two(dt.minute)}:${_two(dt.second)}.${dt.millisecond.toString().padLeft(3, '0')}';
  }

  static Future<IOSink> _ensureSink() async {
    final now = DateTime.now();
    final today = _dayOf(now);
    if (_sink != null && _sinkDate == today) return _sink!;

    try {
      await _sink?.flush();
    } catch (_) {}
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _sinkDate = today;

    final dir = await AppDirectories.getAppDataDirectory();
    final logsDir = Directory('${dir.path}/logs');
    if (!await logsDir.exists()) {
      await logsDir.create(recursive: true);
    }

    final active = File('${logsDir.path}/$_activeFileName');
    if (await active.exists()) {
      try {
        final stat = await active.stat();
        final fileDay = _dayOf(stat.modified.toLocal());
        if (fileDay != today) {
          final suffix = _formatDate(fileDay);
          var rotated = File('${logsDir.path}/$_rotatedFilePrefix$suffix.txt');
          if (await rotated.exists()) {
            int i = 1;
            while (await File(
              '${logsDir.path}/$_rotatedFilePrefix${suffix}_$i.txt',
            ).exists()) {
              i++;
            }
            rotated = File(
              '${logsDir.path}/$_rotatedFilePrefix${suffix}_$i.txt',
            );
          }
          await active.rename(rotated.path);
        }
      } catch (_) {}
    }

    _sink = active.openWrite(mode: FileMode.append);
    return _sink!;
  }

  static void log(String message, {String? tag}) {
    if (!_enabled) return;
    message = LogRedactor.redactText(message);
    final now = DateTime.now();
    final prefix = '[${_formatTs(now)}]${tag == null ? '' : ' [$tag]'} ';
    final normalized = message.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final buffer = StringBuffer();
    for (final line in lines) {
      buffer.writeln('$prefix$line');
    }
    final text = buffer.toString();

    _writeQueue = _writeQueue.then((_) async {
      if (!_enabled) return;
      try {
        final sink = await _ensureSink();
        sink.write(text);
        await sink.flush();
      } catch (_) {
        try {
          await _sink?.flush();
        } catch (_) {}
        try {
          await _sink?.close();
        } catch (_) {}
        _sink = null;
        _sinkDate = null;
        if (!_writeErrorReported) {
          _writeErrorReported = true;
          try {
            stderr.writeln(
              '[FlutterLogger] write failed; further write errors will be suppressed.',
            );
          } catch (_) {}
        }
      }
    });
  }

  static void logPrint(String line) {
    log(line, tag: 'print');
  }

  // ---------------------------------------------------------------------
  // 启动早期通道
  //
  // 日志开关原本要到启动收尾（读完偏好设置）才生效，于是启动全程没有记录。
  // 这里补一条同步入口，让启动最早期就能落盘：
  //   - 开关值直接同步读偏好设置的落盘文件，不等它的异步初始化；
  //   - 写入为同步追加，进程随后被强制结束时也不会丢；
  //   - 与异步通道共用同一文件、同一时间戳格式、同一按天轮转规则。
  // ---------------------------------------------------------------------

  /// 启动最早期调用一次：解析开关、写出本次启动的分隔行、补写暂存条目。
  ///
  /// 必须在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用。
  /// 全程同步 IO；任何失败都被吞掉，绝不影响启动。
  static void bootstrap(Directory appDataDirectory) {
    if (_bootstrapped) return;
    _bootstrapped = true;
    _earlyDir = appDataDirectory;
    try {
      _enabled = _readEnabledSync(appDataDirectory) ?? defaultEnabled;
    } catch (_) {
      _enabled = defaultEnabled;
    }
    _writeSync(_separatorLine());
    _flushPendingSync();
  }

  /// 阶段脚印：同步追加一行。
  ///
  /// 引导前调用会暂存内存，待引导时按原时间戳补写；引导后与普通日志一样受
  /// 开关约束。
  static void stage(String label, {String? tag}) {
    final now = DateTime.now();
    final prefix = '[${_formatTs(now)}]${tag == null ? '' : ' [$tag]'} ';
    final line = '$prefix$label\n';
    if (!_bootstrapped) {
      _pendingStages.add(line);
      return;
    }
    if (!_enabled) return;
    _writeSync(line);
  }

  static String _separatorLine() {
    return '\n===== JO-AIClient startup ${_formatTs(DateTime.now())} '
        'pid=$pid =====\n';
  }

  /// 同步读取日志开关。文件里的键由 shared_preferences 统一加了 `flutter.` 前缀。
  ///
  /// 返回 null 表示没有存过这个开关，由调用方决定兜底值。
  static bool? _readEnabledSync(Directory appDataDirectory) {
    final file = File('${appDataDirectory.path}/shared_preferences.json');
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final value = decoded['flutter.$_enabledPrefKey'];
    return value is bool ? value : null;
  }

  /// 同步追加写入，仅供启动早期通道使用。
  static void _writeSync(String text) {
    if (!_enabled) return;
    final root = _earlyDir;
    if (root == null) return;
    try {
      final logsDir = Directory('${root.path}/logs');
      if (!logsDir.existsSync()) logsDir.createSync(recursive: true);
      final active = File('${logsDir.path}/$_activeFileName');
      _rotateIfNeededSync(active, logsDir);
      active.writeAsStringSync(text, mode: FileMode.append, flush: true);
    } catch (error) {
      // 同步通道在启动最早期用，静默失败会让整段启动失去记录，且从外部
      // 完全看不出来（2026-09-13 的心跳缺失就是被这里吞掉的）。只报一次。
      if (!_syncWriteErrorReported) {
        _syncWriteErrorReported = true;
        try {
          stderr.writeln('[FlutterLogger] sync write failed: $error');
        } catch (_) {}
      }
    }
  }

  /// 与 [_ensureSink] 一致的按天轮转规则，供同步路径使用。
  static void _rotateIfNeededSync(File active, Directory logsDir) {
    if (!active.existsSync()) return;
    final today = _dayOf(DateTime.now());
    final fileDay = _dayOf(active.statSync().modified.toLocal());
    if (fileDay == today) return;
    active.rename(_rotatedTargetSync(logsDir, fileDay).path);
  }

  static File _rotatedTargetSync(Directory logsDir, DateTime fileDay) {
    final suffix = _formatDate(fileDay);
    var rotated = File('${logsDir.path}/$_rotatedFilePrefix$suffix.txt');
    if (rotated.existsSync()) {
      var index = 1;
      while (File(
        '${logsDir.path}/$_rotatedFilePrefix${suffix}_$index.txt',
      ).existsSync()) {
        index++;
      }
      rotated = File('${logsDir.path}/$_rotatedFilePrefix${suffix}_$index.txt');
    }
    return rotated;
  }

  static void _flushPendingSync() {
    if (_pendingStages.isEmpty) return;
    if (!_enabled) {
      _pendingStages.clear();
      return;
    }
    final buffer = StringBuffer();
    for (final line in _pendingStages) {
      buffer.write(line);
    }
    _pendingStages.clear();
    _writeSync(buffer.toString());
  }
}
