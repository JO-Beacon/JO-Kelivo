import 'dart:io';
import 'package:http/http.dart' as http;
import './app_directories.dart';

class AvatarCache {
  AvatarCache._();

  static final Map<String, String?> _memo = <String, String?>{};

  static void clearMemory() {
    _memo.clear();
  }

  static Future<Directory> _cacheDir() async {
    return await AppDirectories.getAvatarCacheDirectory();
  }

  static String _safeName(String url) {
    // 使用 64 位 FNV-1a 哈希，避免常见 URL 前缀带来的冲突
    int h = 0xcbf29ce484222325; // FNV 偏移基数
    const int prime = 0x100000001b3; // FNV 质数
    for (final c in url.codeUnits) {
      h ^= c;
      h = (h * prime) & 0xFFFFFFFFFFFFFFFF; // 保持 64 位
    }
    final hex = h.toRadixString(16).padLeft(16, '0');
    // 尽量保留合理的扩展名（可能有助于部分平台识别）
    final uri = Uri.tryParse(url);
    String ext = 'img';
    if (uri != null) {
      final seg = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last.toLowerCase()
          : '';
      final m = RegExp(
        r"\.(png|jpg|jpeg|webp|gif|bmp|ico|svg)",
      ).firstMatch(seg);
      if (m != null) ext = m.group(1)!;
    }
    return 'av_$hex.$ext';
  }

  /// 同步查看缓存：仅当 [url] 已缓存且文件仍存在于磁盘时，返回本地缓存文件路径。
  /// 尚未解析时返回 null（调用方应回退到 [getPath]）。
  static String? peek(String url) {
    if (url.isEmpty) return null;
    final cached = _memo[url];
    if (cached == null) return null;
    try {
      if (File(cached).existsSync()) return cached;
    } catch (_) {}
    return null;
  }

  /// 确保 [url] 对应的头像已缓存到本地，并返回文件路径。
  /// 失败时返回 null。
  static Future<String?> getPath(String url) async {
    if (url.isEmpty) return null;
    if (_memo.containsKey(url)) {
      final cached = _memo[url];
      if (cached == null) return null;
      try {
        final f = File(cached);
        if (await f.exists()) return cached;
      } catch (_) {}
      // 过期条目：文件已被删除，需要重新解析。
      _memo.remove(url);
    }
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final name = _safeName(url);
      final file = File('${dir.path}/$name');
      if (await file.exists()) {
        _memo[url] = file.path;
        return file.path;
      }
      // 下载并保存
      final res = await http.get(Uri.parse(url));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        await file.writeAsBytes(res.bodyBytes, flush: true);
        _memo[url] = file.path;
        return file.path;
      }
    } catch (_) {}
    _memo[url] = null;
    return null;
  }

  static Future<void> evict(String url) async {
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return;
      final name = _safeName(url);
      final file = File('${dir.path}/$name');
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _memo.remove(url);
  }
}
