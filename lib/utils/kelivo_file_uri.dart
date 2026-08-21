import 'package:path/path.dart' as p;

/// 用于受管应用本地文件的逻辑 URI。
///
/// 线上形式：`kelivo-file:///<root>/<relative...>`
/// 其中 `<root>` ∈ { upload, images, avatars, fonts }。
///
/// 纯词法处理，不执行文件系统 I/O（禁止使用 `dart:io`）。根目录由调用方注入。
final class KelivoFileUri {
  KelivoFileUri._();

  static const String _scheme = 'kelivo-file';
  static const String _prefix = '$_scheme:';
  static const String _head = '$_scheme:///';

  static const List<String> _managedRoots = [
    'upload',
    'images',
    'avatars',
    'fonts',
  ];

  /// 廉价的前缀检查，**不会**校验结构。
  static bool isKelivoFileUri(String value) => value.startsWith(_prefix);

  /// 严格解码。返回 `['upload','foo.png']`；无效时返回 `null`。
  static List<String>? decodeToSegments(String uri) {
    // 要求 authority 为空：`kelivo-file:///...`。
    // 拒绝 `kelivo-file://host/...` 和 `kelivo-file:/...`。
    if (!uri.startsWith(_head)) return null;
    final rest = uri.substring(_head.length);
    if (rest.isEmpty) return null;
    // 在不触发 Uri.parse 规范化副作用的前提下拒绝 query/fragment。
    if (rest.contains('?') || rest.contains('#')) return null;
    // 在百分号解码前拒绝 _head 已覆盖的 host 形式，以及空路径段和点段，
    // 避免 `images/./a` 被规范化掉。
    final rawParts = rest.split('/');
    if (rawParts.any((s) => s.isEmpty)) return null;

    final segments = <String>[];
    for (final raw in rawParts) {
      if (raw == '.' || raw == '..') return null;
      late final String decoded;
      try {
        decoded = Uri.decodeComponent(raw);
      } on ArgumentError {
        return null;
      } on FormatException {
        return null;
      }
      if (decoded.isEmpty || decoded == '.' || decoded == '..') return null;
      if (decoded.contains('/') || decoded.contains('\\')) return null;
      segments.add(decoded);
    }
    if (segments.length < 2) return null;
    if (!_isManaged(segments.first)) return null;
    return List<String>.unmodifiable(segments);
  }

  /// 基于绝对应用数据 [root] 解析。不检查文件是否存在。
  /// 当 [uri] 不是有效 kelivo-file URI 时返回 `null`。
  static String? resolveToAbsolute(String uri, {required String root}) {
    final segments = decodeToSegments(uri);
    if (segments == null) return null;
    final ctx = _contextFor(root);
    return ctx.joinAll([root, ...segments]);
  }

  /// 将 `[root]/<managed>/...` 下的绝对路径编码为 URI。
  /// 外部或非受管路径返回 `null`。
  ///
  /// 包含 `\` 的路径段会被拒绝，确保编码器不会生成 [decodeToSegments]
  /// 无法往返还原的 URI。受管根目录在线上会转为小写（`Images` → `images`）。
  static String? encodeFromAbsolute(String abs, {required String root}) {
    // 在路径规范化可能按 Windows 风格重新解释之前，拒绝 POSIX 反斜杠文件名。
    final looksWindows =
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(abs) ||
        root.contains('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(root);
    if (!looksWindows && abs.contains('\\')) return null;

    final ctx = _contextFor(root);
    final normalizedAbs = ctx.normalize(abs);
    final normalizedRoot = ctx.normalize(root);
    // Windows 根目录通过 Style.windows 进行不区分大小写比较。
    if (!ctx.isWithin(normalizedRoot, normalizedAbs)) return null;

    final rel = ctx.relative(normalizedAbs, from: normalizedRoot);
    final parts = ctx.split(rel).where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return null;
    final managed = parts.first.toLowerCase();
    if (!_isManaged(managed)) return null;
    parts[0] = managed;
    for (final part in parts) {
      if (part == '.' || part == '..') return null;
      if (part.contains('\\')) return null;
    }
    return _encodeSegments(parts);
  }

  /// 已知拥有受管根目录的生产 bundle 或包标识。
  /// 故意拒绝子串匹配（例如 `com.other.kelivo.notes`），只允许精确白名单条目。
  static const Set<String> _knownBundleIds = {
    'com.psyche.kelivo',
    'psyche.kelivo',
  };

  /// Windows AppData 文件夹名（Flutter BINARY_NAME）。
  /// 作为完整路径段进行不区分大小写比较，而不是子串比较。
  static const String _windowsAppFolder = 'kelivo';

  static final RegExp _iosUuid = RegExp(
    r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
  );

  /// 尽力将旧版绝对沙箱路径转换为 kelivo-file URI。标记顺序
  /// （仅限严格的平台沙箱）：
  /// 1. iOS 设备 `/var/mobile/...`（锚定路径开头）
  /// 2. iOS 模拟器 `/Users/.../CoreSimulator/...`（锚定路径开头）
  /// 3. macOS Kelivo 容器 Documents（精确 bundle 白名单）
  /// 4. macOS/Linux Application Support / `.local/share`（精确白名单）
  /// 5. Windows `AppData\Local|Roaming\[com.psyche\]kelivo`
  /// 6. Android 应用私有 app_flutter / files（精确包白名单）
  /// 7. 通用回退：第一个 `/<managed>/` 出现位置
  ///    （当 [allowGenericFallback] 为 false 时禁用）
  ///
  /// 纯词法处理，不调用 `existsSync`。拒绝 UNC/SMB。所有平台匹配器都锚定在
  /// 可移植路径开头，避免嵌套归档副本（`/tmp/archive/...`）被误认为活动沙箱。
  static String? tryEncodeLegacyAbsolutePath(
    String abs, {
    bool allowGenericFallback = true,
  }) {
    if (abs.isEmpty) return null;
    final portable = toPortableSlashPath(abs);
    if (portable == null) return null;
    final raw = portable;

    const subdirs = ['avatars', 'fonts', 'images', 'upload'];
    String? tail; // 以 '/managed/...' 开头

    // iOS 设备：必须以 /var/mobile/... 开头。
    final iosDevice = RegExp(
      r'^/var/mobile/Containers/Data/Application/([^/]+)/Documents/',
      caseSensitive: false,
    ).firstMatch(raw);
    if (iosDevice != null && _iosUuid.hasMatch(iosDevice.group(1)!)) {
      tail = _normalizeManagedTail('/${raw.substring(iosDevice.end)}', subdirs);
    }

    // iOS 模拟器：从头开始的完整用户目录 CoreSimulator 路径。
    if (tail == null) {
      final iosSim = RegExp(
        r'^/Users/[^/]+/Library/Developer/CoreSimulator/Devices/'
        r'([^/]+)/data/Containers/Data/Application/([^/]+)/Documents/',
        caseSensitive: false,
      ).firstMatch(raw);
      if (iosSim != null &&
          _iosUuid.hasMatch(iosSim.group(1)!) &&
          _iosUuid.hasMatch(iosSim.group(2)!)) {
        tail = _normalizeManagedTail('/${raw.substring(iosSim.end)}', subdirs);
      }
    }

    // macOS Kelivo 应用容器 Documents（精确 bundle id）。
    if (tail == null) {
      final macContainer = RegExp(
        r'^/Users/[^/]+/Library/Containers/([^/]+)/Data/Documents/',
        caseSensitive: false,
      ).firstMatch(raw);
      if (macContainer != null && _isKnownBundleId(macContainer.group(1)!)) {
        tail = _normalizeManagedTail(
          '/${raw.substring(macContainer.end)}',
          subdirs,
        );
      }
    }

    // macOS/Linux Application Support / .local/share 下的 Kelivo 根目录。
    if (tail == null) {
      final support = RegExp(
        r'^/(?:Users/[^/]+/Library/Application Support|'
        r'home/[^/]+/\.local/share)/([^/]+)/',
        caseSensitive: false,
      ).firstMatch(raw);
      if (support != null && _isKnownBundleId(support.group(1)!)) {
        tail = _normalizeManagedTail('/${raw.substring(support.end)}', subdirs);
      }
    }

    // Windows：C:/Users/<user>/AppData/Local|Roaming/[com.psyche/]<Kelivo>/...
    // 文件夹名必须不区分大小写地等于 "kelivo"（不能是 KelivoNotes）。
    if (tail == null) {
      final win = RegExp(
        r'^[A-Za-z]:/Users/[^/]+/AppData/(?:Local|Roaming)/'
        r'(?:com\.psyche/)?([^/]+)/',
        caseSensitive: false,
      ).firstMatch(raw);
      if (win != null && win.group(1)!.toLowerCase() == _windowsAppFolder) {
        tail = _normalizeManagedTail('/${raw.substring(win.end)}', subdirs);
      }
    }

    // Android 应用私有 app_flutter 目录
    if (tail == null) {
      final flutter = RegExp(
        r'^/(?:data/user/\d+|data/data)/([^/]+)/app_flutter/',
        caseSensitive: false,
      ).firstMatch(raw);
      if (flutter != null && _isKnownBundleId(flutter.group(1)!)) {
        tail = _normalizeManagedTail('/${raw.substring(flutter.end)}', subdirs);
      }
    }

    // Android 应用私有 files 目录
    if (tail == null) {
      final files = RegExp(
        r'^/(?:(?:data/user/\d+|data/data)/([^/]+)/files/|'
        r'storage/emulated/\d+/Android/data/([^/]+)/files/)',
        caseSensitive: false,
      ).firstMatch(raw);
      if (files != null) {
        final pkg = files.group(1) ?? files.group(2)!;
        if (_isKnownBundleId(pkg)) {
          tail = _normalizeManagedTail('/${raw.substring(files.end)}', subdirs);
        }
      }
    }

    if (tail == null && allowGenericFallback) {
      final lower = raw.toLowerCase();
      for (final s in subdirs) {
        final i = lower.indexOf('/$s/');
        if (i != -1) {
          tail = _normalizeManagedTail(raw.substring(i), subdirs);
          break;
        }
      }
    }

    if (tail == null) return null;

    final trimmed = tail.startsWith('/') ? tail.substring(1) : tail;
    final parts = trimmed.split('/');
    if (parts.length < 2) return null;
    if (parts.any((s) => s.isEmpty || s == '.' || s == '..')) return null;
    if (!_isManaged(parts.first)) return null;
    return _encodeSegments(parts);
  }

  static bool _isKnownBundleId(String value) =>
      _knownBundleIds.contains(value.toLowerCase());

  /// 将绝对路径或 file URI 转换为用于匹配的可移植斜杠路径。
  ///
  /// UNC/SMB 或空输入返回 `null`。Windows 驱动器路径保留 `C:/...` 形式；
  /// 拒绝 POSIX 反斜杠文件名。
  ///
  /// 对 `file:` 输入使用 URI 路径（始终为 `/`），以便 Windows 主机仍能识别
  /// iOS 的 `file:///var/mobile/...` 沙箱标记。
  static String? toPortableSlashPath(String abs) {
    if (abs.isEmpty) return null;
    var value = abs;
    if (value.toLowerCase().startsWith('file:')) {
      try {
        final parsed = Uri.parse(value);
        if (parsed.scheme.toLowerCase() != 'file') return null;
        final host = parsed.host.toLowerCase();
        if (host.isNotEmpty && host != 'localhost') return null;
        value = Uri.decodeComponent(parsed.path);
        if (value.startsWith('/') &&
            value.length >= 3 &&
            RegExp(r'^/[A-Za-z]:').hasMatch(value)) {
          // file:///C:/Users/... → C:/Users/...
          value = value.substring(1);
        }
      } catch (_) {
        return null;
      }
    }

    if (value.startsWith(r'\\') || value.startsWith('//')) return null;

    final looksWindows = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
    if (looksWindows) {
      return value.replaceAll('\\', '/');
    }
    if (value.contains('\\')) return null;
    return value;
  }

  static String? _normalizeManagedTail(
    String candidateTail,
    List<String> subdirs,
  ) {
    var tail = candidateTail;
    if (!tail.startsWith('/')) tail = '/$tail';
    final lower = tail.toLowerCase();
    for (final s in subdirs) {
      if (lower.startsWith('/$s/')) {
        // 保留受管根目录之后文件名或相对路径的大小写。
        return '/$s${tail.substring(1 + s.length)}';
      }
    }
    return null;
  }

  static String _encodeSegments(List<String> parts) {
    final encoded = parts.map(Uri.encodeComponent).join('/');
    return '$_scheme:///$encoded';
  }

  static bool _isManaged(String value) => _managedRoots.contains(value);

  static p.Context _contextFor(String root) {
    if (root.contains('\\') || RegExp(r'^[A-Za-z]:').hasMatch(root)) {
      return p.Context(style: p.Style.windows);
    }
    return p.Context(style: p.Style.posix);
  }
}
