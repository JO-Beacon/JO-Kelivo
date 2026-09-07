/// 进程级跟踪备份、恢复和导入等重型任务。
final class BackupActivity {
  BackupActivity._();

  static int _depth = 0;

  static bool get isActive => _depth > 0;

  static void begin() => _depth += 1;

  static void end() {
    if (_depth > 0) _depth -= 1;
  }
}
