import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 平台相关的应用数据目录工具。
///
/// - Windows/macOS/Linux：使用 `path_provider` 提供的 Application Support
///   （应用数据）目录。
/// - Android/iOS：继续使用 Application Documents 目录。
class AppDirectories {
  AppDirectories._();

  /// 获取应用数据存储的根目录。
  ///
  /// - Windows/macOS/Linux：Application Support 目录
  /// - Android/iOS：Application Documents 目录
  static Future<Directory> getAppDataDirectory() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return await getApplicationSupportDirectory();
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return await getApplicationDocumentsDirectory();
    }
  }

  /// 在平台文件管理器中打开目录。
  static Future<bool> openDirectory(Directory directory) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        await Process.start('explorer.exe', [
          directory.path,
        ], mode: ProcessStartMode.detached);
        return true;
      case TargetPlatform.macOS:
        await Process.start('open', [
          directory.path,
        ], mode: ProcessStartMode.detached);
        return true;
      case TargetPlatform.linux:
        await Process.start('xdg-open', [
          directory.path,
        ], mode: ProcessStartMode.detached);
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        break;
    }

    return launchUrl(
      Uri.file(directory.path),
      mode: LaunchMode.externalApplication,
    );
  }

  /// 获取上传文件的目录。
  static Future<Directory> getUploadDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/upload');
  }

  /// 获取图片文件的目录。
  static Future<Directory> getImagesDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/images');
  }

  /// 获取头像文件的目录。
  static Future<Directory> getAvatarsDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/avatars');
  }

  /// 获取用户导入字体文件的目录。
  static Future<Directory> getFontsDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/fonts');
  }

  /// 获取缓存文件的目录。
  static Future<Directory> getCacheDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/cache');
  }

  /// 获取平台提供的应用缓存目录。
  ///
  /// - Android：/data/user/0/`<package>`/cache
  /// - iOS/macOS：Caches 目录
  /// - Windows/Linux：平台缓存目录（Linux 上通过 XDG 指定为应用专属目录）
  static Future<Directory> getSystemCacheDirectory() async {
    return await getApplicationCacheDirectory();
  }

  /// 获取头像缓存文件的目录。
  static Future<Directory> getAvatarCacheDirectory() async {
    final root = await getAppDataDirectory();
    return Directory('${root.path}/cache/avatars');
  }

  /// 根据 MIME 类型获取文件扩展名。
  static String extFromMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      default:
        return 'png';
    }
  }

  /// 将 base64 图片数据保存到 images 目录。
  /// [prefix] 用于文件名（例如 'img'、'mcp_img'）。
  /// 返回保存后的文件路径；失败时返回 null。
  static Future<String?> saveBase64Image(
    String mime,
    String base64Data, {
    String prefix = 'img',
  }) async {
    try {
      final dir = await getImagesDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final cleaned = base64Data.replaceAll(RegExp(r'\s'), '');
      List<int> bytes;
      // 同时支持标准 base64 和 URL 安全 base64
      if (cleaned.contains('-') || cleaned.contains('_')) {
        bytes = base64Url.decode(cleaned);
      } else {
        bytes = base64Decode(cleaned);
      }
      final ext = extFromMime(mime);
      final path =
          '${dir.path}/${prefix}_${DateTime.now().microsecondsSinceEpoch}.$ext';
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      return path;
    } catch (e) {
      debugPrint('Failed to save image: $e');
      return null;
    }
  }
}
