import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import './app_directories.dart';
import './kelivo_file_uri.dart';

/// 将包含 iOS 沙箱 UUID 的持久化绝对文件路径，在应用更新后解析为当前应用容器路径。
///
/// 示例：
///   更新前：/var/mobile/Containers/Data/Application/ABC/Documents/upload/x.png
///   更新后：/var/mobile/Containers/Data/Application/XYZ/Documents/upload/x.png
///
/// 我们会在消息内容中存储绝对路径。iOS 更新后容器前缀会变化。此工具会将指向
/// 旧容器 Documents 子目录（upload/avatars）的路径重写为当前 Documents 目录。
/// 如果重写后的文件存在，返回新路径；否则返回原路径。
///
/// 规范的 `kelivo-file:///` URI 会基于缓存的 Documents 根目录进行词法解析，
/// 不检查文件系统是否存在该文件。
class SandboxPathResolver {
  SandboxPathResolver._();

  static String? _docsDir;
  static String? _supportDir;
  static bool debug = false;

  /// 应用启动时调用一次，缓存当前 Documents 目录。
  static Future<void> init() async {
    try {
      // 使用平台特定的应用数据目录
      final dir = await AppDirectories.getAppDataDirectory();
      _docsDir = dir.path;
      try {
        final sup = await getApplicationSupportDirectory();
        _supportDir = sup.path;
      } catch (_) {
        _supportDir = null;
      }
      if (debug) {
        debugPrint(
          '[SandboxPathResolver.init] docsDir=$_docsDir supportDir=$_supportDir',
        );
      }
    } catch (_) {
      // 保持为 null；这种情况下 fix() 会直接跳过。
      _docsDir = null;
      _supportDir = null;
    }
  }

  /// 仅测试用的注入点，可在不依赖 `path_provider` 的情况下注入 Documents / Support 根目录。
  @visibleForTesting
  static void debugSetDirs({String? docsDir, String? supportDir}) {
    _docsDir = docsDir;
    _supportDir = supportDir;
  }

  /// 当旧绝对路径位于受管子目录（upload/images/avatars）下时，同步映射到当前容器路径。
  /// 如果映射成功且目标存在，返回映射后的路径；否则原样返回 [path]。
  ///
  /// 规范的 `kelivo-file:` URI 在解析时不进行存在性探测。
  static String fix(String path) {
    if (path.isEmpty) return path;

    if (KelivoFileUri.isKelivoFileUri(path)) {
      final docs = _docsDir;
      if (docs == null || docs.isEmpty) return path;
      return KelivoFileUri.resolveToAbsolute(path, root: docs) ?? path;
    }

    // 在重映射前解码 file:// 的百分号转义（避免 %20 变成 %2520）。
    // 非本地或 UNC file: URI 不得重映射或探测（存在 SMB 风险）。
    final String raw0 = _decodeFileUri(path);
    if (raw0 == path && path.toLowerCase().startsWith('file:')) return path;
    if (_isUncPath(raw0)) return path;
    // 只有 Windows 驱动器路径会规范化 `\`；POSIX 反斜杠文件名保持不变。
    final String raw = _normalizeSeparatorsForMatch(raw0);
    if (_isUncPath(raw)) return path;

    final docs = _docsDir;
    final support = _supportDir;
    if (docs == null || docs.isEmpty) return raw;

    // 确定要映射的根目录和尾部路径。优先使用与
    // KelivoFileUri.tryEncodeLegacyAbsolutePath 相同的结构化沙箱标记，然后才使用通用规则。
    const subdirs = ['avatars', 'fonts', 'images', 'upload'];
    String? tail; // 以 '/' 开头
    String rootType = 'unknown';

    final encoded = KelivoFileUri.tryEncodeLegacyAbsolutePath(
      raw,
      allowGenericFallback: false,
    );
    if (encoded != null) {
      final segs = KelivoFileUri.decodeToSegments(encoded);
      if (segs != null && segs.isNotEmpty) {
        tail = '/${segs.join('/')}';
        rootType = 'structured_legacy';
      }
    }

    // 最终通用回退：在任意位置检测 '/avatars/'、'/images/'、'/upload/'
    // （仅用于运行时恢复，canonicalize 从不使用此路径）。
    if (tail == null) {
      for (final s in subdirs) {
        final i = raw.indexOf('/$s/');
        if (i != -1) {
          tail = raw.substring(i); // 包含前导 '/'
          rootType = 'generic_subdir';
          break;
        }
      }
    }

    if (tail == null) {
      if (debug) {
        debugPrint(
          '[SandboxPathResolver.fix] input=$path -> skipped (no known subdir pattern found)',
        );
      }
      return raw;
    }

    // 首选：映射到当前 ApplicationDocumentsDirectory
    final String mapped = '$docs$tail';
    try {
      if (File(mapped).existsSync()) {
        if (debug) {
          debugPrint(
            '[SandboxPathResolver.fix] root=$rootType input=$path -> mappedDocs=$mapped (exists)',
          );
        }
        return mapped;
      } else {
        if (debug) {
          debugPrint(
            '[SandboxPathResolver.fix] root=$rootType tried mappedDocs=$mapped (missing)',
          );
        }
      }
    } catch (e) {
      if (debug) {
        debugPrint(
          '[SandboxPathResolver.fix] root=$rootType mappedDocs error: $e',
        );
      }
    }

    // 备选：尝试 ApplicationSupportDirectory
    if (support != null && support.isNotEmpty) {
      final alt = '$support$tail';
      try {
        if (File(alt).existsSync()) {
          if (debug) {
            debugPrint(
              '[SandboxPathResolver.fix] root=$rootType input=$path -> mappedSupport=$alt (exists)',
            );
          }
          return alt;
        } else {
          if (debug) {
            debugPrint(
              '[SandboxPathResolver.fix] root=$rootType tried mappedSupport=$alt (missing)',
            );
          }
        }
      } catch (e) {
        if (debug) {
          debugPrint(
            '[SandboxPathResolver.fix] root=$rootType mappedSupport error: $e',
          );
        }
      }
    }

    // 回退：在两个根目录的常用文件夹下按文件名搜索
    final String base = _basename(tail);
    for (final root in <String?>[docs, support]) {
      if (root == null || root.isEmpty) continue;
      for (final sub in const ['avatars', 'fonts', 'images', 'upload']) {
        final probe = '$root/$sub/$base';
        try {
          if (File(probe).existsSync()) {
            if (debug) {
              debugPrint(
                '[SandboxPathResolver.fix] root=$rootType input=$path -> basenameProbe=$probe (exists)',
              );
            }
            return probe;
          } else {
            if (debug) {
              debugPrint(
                '[SandboxPathResolver.fix] root=$rootType tried basenameProbe=$probe (missing)',
              );
            }
          }
        } catch (e) {
          if (debug) {
            debugPrint(
              '[SandboxPathResolver.fix] root=$rootType basenameProbe error: $e',
            );
          }
        }
      }
    }
    if (debug) {
      debugPrint(
        '[SandboxPathResolver.fix] root=$rootType input=$path -> unchanged=$raw (no match)',
      );
    }
    return raw;
  }

  static String _basename(String p) {
    if (p.isEmpty) return p;
    final norm = _looksLikeWindowsDrivePath(p) ? p.replaceAll('\\', '/') : p;
    final i = norm.lastIndexOf('/');
    return i == -1 ? norm : norm.substring(i + 1);
  }

  /// 当本地绝对路径（或 `file://` URL）指向受管应用存储时，将其转换为稳定的
  /// `kelivo-file:///` URI。
  ///
  /// 远程（`http`/`https`）、`data:` 以及已经是规范形式的 kelivo-file URI 会原样透传。
  /// 无法编码的外部绝对路径在解码可选的本地 `file://` 前缀后原样返回。
  ///
  /// 编码过程从不使用 `/images/`·`/upload/` 这种通用猜测。即使 [encodeFromAbsolute]
  /// 失败，仍会识别结构化沙箱标记（`Documents` / `kelivo` / `app_flutter`·`files`），
  /// 因此即使 [_docsDir] 已设置，旧容器 UUID 路径仍可规范化。
  static String canonicalize(String uri) {
    if (uri.isEmpty) return uri;
    if (KelivoFileUri.isKelivoFileUri(uri)) return uri;
    // 不区分大小写：HTTPS://… 不得落入本地路径启发式逻辑。
    final lower = uri.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('data:')) {
      return uri;
    }

    // 为旧路径匹配生成可移植斜杠路径（Windows 仍需识别 iOS 的
    // file:///var/mobile/... 标记；Uri.toFilePath 是平台相关的）。
    final portable = KelivoFileUri.toPortableSlashPath(uri);
    if (portable == null) {
      // 非本地 file:、UNC 或空输入：保持不变。
      return uri;
    }

    final docs = _docsDir;
    if (docs != null && docs.isNotEmpty) {
      // 优先在当前根目录下编码（Windows 上不区分大小写）。
      final underRoot = KelivoFileUri.encodeFromAbsolute(portable, root: docs);
      if (underRoot != null) return underRoot;
      // 当 docsDir 使用反斜杠时，也尝试宿主平台原生绝对路径形式。
      final native = _decodeFileUri(uri);
      if (native != portable) {
        final underNative = KelivoFileUri.encodeFromAbsolute(
          native,
          root: docs,
        );
        if (underNative != null) return underNative;
      }
      return KelivoFileUri.tryEncodeLegacyAbsolutePath(
            portable,
            allowGenericFallback: false,
          ) ??
          portable;
    }
    return KelivoFileUri.tryEncodeLegacyAbsolutePath(
          portable,
          allowGenericFallback: false,
        ) ??
        portable;
  }

  /// 恢复边界重映射：如果 [uri] 是已知的旧受管沙箱绝对路径，且对应文件
  /// 因备份文件复制而存在于当前 docs 根目录，则返回 kelivo-file URI。
  ///
  /// 对于仅与恢复文件同名的任意外部路径，**不会**重新启用通用 `/images/` 回退。
  static String? tryRemapRestoredManagedAbsolute(String uri) {
    final docs = _docsDir;
    if (docs == null || docs.isEmpty) return null;
    if (KelivoFileUri.isKelivoFileUri(uri)) return uri;
    final lower = uri.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('data:')) {
      return null;
    }
    final portable = KelivoFileUri.toPortableSlashPath(uri);
    if (portable == null) return null;

    final encoded = KelivoFileUri.tryEncodeLegacyAbsolutePath(
      portable,
      allowGenericFallback: false,
    );
    if (encoded == null) return null;
    final abs = KelivoFileUri.resolveToAbsolute(encoded, root: docs);
    if (abs == null) return null;
    try {
      if (File(abs).existsSync()) return encoded;
    } catch (_) {}
    return null;
  }

  /// 将本地 `file:` URI 解码为文件系统路径。
  ///
  /// UNC/SMB 或非本地主机（`file://server/share/...`）返回 `null`，
  /// 避免调用方把助手 Markdown 变成网络文件 I/O。
  static String? tryDecodeLocalFileUri(String value) {
    final lower = value.toLowerCase();
    if (!lower.startsWith('file:')) return null;
    try {
      final parsed = Uri.parse(value);
      if (parsed.scheme.toLowerCase() != 'file') return null;
      final host = parsed.host.toLowerCase();
      // 拒绝非本地主机（通过 file://server/... 表示的 SMB/UNC）。
      if (host.isNotEmpty && host != 'localhost') return null;
      // Dart 的 toFilePath 在非 Windows 上会拒绝 file://localhost/...；
      // 因此先移除 authority。空主机 UNC 形式（file:////server/share）
      // 仍会解码为 //server/...，并在下方被拒绝。
      final local = host.isEmpty
          ? parsed
          : Uri(scheme: 'file', path: parsed.path);
      final path = local.toFilePath();
      if (_isUncPath(path)) return null;
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 为本地文件 I/O 解析 [path]，不使用 [fix] 中的通用 `/images/` 或文件名探测
  /// （这些逻辑可能把缺失的外部路径错误映射到同名受管文件）。
  ///
  /// 当 [path] 是非本地 `file:` URI 时返回 `null`。
  static String? resolveForIo(String path) {
    if (path.isEmpty) return path;
    if (KelivoFileUri.isKelivoFileUri(path)) return fix(path);

    var candidate = path;
    if (path.toLowerCase().startsWith('file:')) {
      final decoded = tryDecodeLocalFileUri(path);
      if (decoded == null) return null;
      candidate = decoded;
    }
    if (_isUncPath(candidate)) return null;

    try {
      if (File(candidate).existsSync()) return candidate;
    } catch (_) {}

    final remapped = _remapStructuredIfExists(candidate);
    return remapped ?? candidate;
  }

  /// 使用 [resolveForIo] 判断 [path] 是否指向已存在的本地文件。
  static bool localFileExists(String path) {
    final resolved = resolveForIo(path);
    if (resolved == null) return false;
    try {
      return File(resolved).existsSync();
    } catch (_) {
      return false;
    }
  }

  static String? _remapStructuredIfExists(String abs) {
    final docs = _docsDir;
    if (docs == null || docs.isEmpty) return null;
    final uri = KelivoFileUri.tryEncodeLegacyAbsolutePath(
      abs,
      allowGenericFallback: false,
    );
    if (uri == null) return null;
    final mapped = KelivoFileUri.resolveToAbsolute(uri, root: docs);
    if (mapped == null) return null;
    try {
      if (File(mapped).existsSync()) return mapped;
    } catch (_) {}
    return null;
  }

  /// 为路径重映射解码 `file:` URI。非 file 输入保持不变。
  /// 非本地或 UNC 的 `file:` URI 原样返回（不进行解码）。
  static String _decodeFileUri(String value) {
    final lower = value.toLowerCase();
    if (!lower.startsWith('file:')) return value;
    return tryDecodeLocalFileUri(value) ?? value;
  }

  static bool _isUncPath(String path) =>
      path.startsWith(r'\\') || path.startsWith('//');

  static bool _looksLikeWindowsDrivePath(String path) =>
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  /// 仅对 Windows 驱动器路径将 `\` 转换为 `/`；POSIX 保留 `\`。
  static String _normalizeSeparatorsForMatch(String path) {
    if (_looksLikeWindowsDrivePath(path)) {
      return path.replaceAll('\\', '/');
    }
    return path;
  }

  // 暴露当前目录用于诊断
  static String? get docsDir => _docsDir;
  static String? get supportDir => _supportDir;
}
