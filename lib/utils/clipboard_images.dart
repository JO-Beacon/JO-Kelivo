import 'dart:async';
import 'package:flutter/services.dart';

class ClipboardImages {
  static const MethodChannel _channel = MethodChannel('app.clipboard');

  static Future<List<String>> getImagePaths() async {
    try {
      final res = await _channel.invokeMethod<List<dynamic>>(
        'getClipboardImages',
      );
      if (res == null) return const [];
      return res.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  // 从文件路径将图片写入系统剪贴板（仅桌面端）。
  static Future<bool> setImagePath(String path) async {
    try {
      final res = await _channel.invokeMethod<dynamic>(
        'setClipboardImage',
        path,
      );
      if (res is bool) return res;
      return res == true;
    } catch (_) {
      return false;
    }
  }

  // 从系统剪贴板获取文件路径（仅桌面端）。
  // 返回在 Finder/Explorer/Files 中复制的项目的绝对文件系统路径。
  static Future<List<String>> getFilePaths() async {
    try {
      final res = await _channel.invokeMethod<List<dynamic>>(
        'getClipboardFiles',
      );
      if (res == null) return const [];
      return res.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }
}
