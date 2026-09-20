import 'dart:io';

import 'package:path/path.dart' as p;

/// Explorer 入口使用绝对 Windows 路径，避免把应用内混合分隔符原样传入。
/// 保留大小写与文件名内容，引号交给 Process.start 处理，不经过命令解释器。
List<String> windowsExplorerArguments(String hostPath, {bool select = false}) {
  if (hostPath.isEmpty || hostPath.contains('\u0000')) {
    throw ArgumentError('Explorer path must be non-empty and contain no NUL');
  }
  final absolute = p.windows.isAbsolute(hostPath)
      ? hostPath
      : File(hostPath).absolute.path;
  final path = p.windows.normalize(absolute);
  return [select ? '/select,$path' : path];
}
