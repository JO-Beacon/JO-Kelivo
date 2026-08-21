import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import './app_directories.dart';
import './sandbox_path_resolver.dart';

class MarkdownMediaSanitizer {
  static final Uuid _uuid = const Uuid();
  static final RegExp _imgRe = RegExp(
    r'!\[[^\]]*\]\((data:image\/[a-zA-Z0-9.+-]+;base64,[a-zA-Z0-9+/=\r\n]+)\)',
    multiLine: true,
  );

  static Future<String> replaceInlineBase64Images(String markdown) async {
    // // 快速路径：仅当明确是 base64 数据图片时才继续处理
    // if (!(markdown.contains('data:image/') && markdown.contains(';base64,'))) {
    //   return markdown;
    // }
    if (!markdown.contains('data:image')) return markdown;

    final matches = _imgRe.allMatches(markdown).toList();
    if (matches.isEmpty) return markdown;

    // 确保目标目录存在
    final dir = await AppDirectories.getImagesDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final sb = StringBuffer();
    int last = 0;
    for (final m in matches) {
      sb.write(markdown.substring(last, m.start));
      final dataUrl = m.group(1)!;
      String ext = AppDirectories.extFromMime(_mimeOf(dataUrl));

      // 提取 base64 数据
      final b64Index = dataUrl.indexOf('base64,');
      if (b64Index < 0) {
        sb.write(markdown.substring(m.start, m.end));
        last = m.end;
        continue;
      }
      final payload = dataUrl.substring(b64Index + 7);

      // // 跳过非常小的数据以避免额外开销（通常是微小图标）
      // if (payload.length < 4096) {
      //   sb.write(markdown.substring(m.start, m.end));
      //   last = m.end;
      //   continue;
      // }

      // 在后台 isolate 中解码（纯 Dart 解码）
      final normalized = payload.replaceAll('\n', '');
      List<int> bytes;
      try {
        bytes = await compute(_decodeBase64, normalized);
      } catch (_) {
        // 跳过格式错误的 base64，避免流式响应崩溃；保留原始标记。
        sb.write(markdown.substring(m.start, m.end));
        last = m.end;
        continue;
      }

      // 根据内容哈希生成确定性文件名，避免重复。
      // 相同的 base64 在不同运行中会得到相同文件名。
      final digest = _uuid.v5(Namespace.url.value, normalized);
      final file = File('${dir.path}/img_$digest.$ext');
      if (!await file.exists()) {
        await file.writeAsBytes(bytes, flush: true);
      }

      // 只替换括号内的 URL 部分
      final uri = SandboxPathResolver.canonicalize(file.path);
      final replaced = markdown
          .substring(m.start, m.end)
          .replaceFirst(dataUrl, uri);
      sb.write(replaced);
      last = m.end;
    }
    sb.write(markdown.substring(last));
    return sb.toString();
  }

  // 将指向本地文件路径的 Markdown 图片链接替换为内联 base64 数据 URL。
  // Example: "![image](/data/user/0/.../images/xxx.png)" -> "![image](data:image/png;base64,...)"
  static Future<String> inlineLocalImagesToBase64(String markdown) async {
    // 快速检查：包含 Markdown 图片且看起来像本地路径
    if (!(markdown.contains('![') && markdown.contains(']('))) return markdown;

    final re = RegExp(r'!\[[^\]]*\]\(([^)]+)\)', multiLine: true);
    final matches = re.allMatches(markdown).toList();
    if (matches.isEmpty) return markdown;

    final sb = StringBuffer();
    int last = 0;
    for (final m in matches) {
      sb.write(markdown.substring(last, m.start));
      final url = (m.group(1) ?? '').trim();
      // 只转换本地文件路径；跳过 http(s) 和已有 data URL
      final isRemote = url.startsWith('http://') || url.startsWith('https://');
      final isData = url.startsWith('data:');
      final isFileUri = url.startsWith('file://');
      final isLikelyLocalPath =
          (!isRemote && !isData) &&
          (isFileUri || url.startsWith('/') || url.contains(':'));

      if (!isLikelyLocalPath) {
        // 保留原始内容
        sb.write(markdown.substring(m.start, m.end));
        last = m.end;
        continue;
      }

      try {
        // 单一 I/O 入口：resolveForIo 会拒绝 UNC/SMB，并避免 fix()
        // 的通用 `/images/` 路径别名。返回 null 时不访问磁盘。
        final resolved = SandboxPathResolver.resolveForIo(url);
        if (resolved == null) {
          sb.write(markdown.substring(m.start, m.end));
          last = m.end;
          continue;
        }
        final f = File(resolved);
        if (!f.existsSync()) {
          // 文件不存在时回退到原始内容
          sb.write(markdown.substring(m.start, m.end));
          last = m.end;
          continue;
        }
        final bytes = await f.readAsBytes();
        final b64 = base64Encode(bytes);
        final mime = _guessMimeFromPath(resolved);
        final dataUrl = 'data:$mime;base64,$b64';
        final replaced = markdown
            .substring(m.start, m.end)
            .replaceFirst(url, dataUrl);
        sb.write(replaced);
      } catch (_) {
        // 失败时保留原始内容
        sb.write(markdown.substring(m.start, m.end));
      }
      last = m.end;
    }
    sb.write(markdown.substring(last));
    return sb.toString();
  }

  static String _guessMimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  static List<int> _decodeBase64(String b64) =>
      base64Decode(b64.replaceAll('\n', ''));

  static String _mimeOf(String dataUrl) {
    try {
      final start = dataUrl.indexOf(':');
      final semi = dataUrl.indexOf(';');
      if (start >= 0 && semi > start) {
        return dataUrl.substring(start + 1, semi);
      }
    } catch (_) {}
    return 'image/png';
  }
}
