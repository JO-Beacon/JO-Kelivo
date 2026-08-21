import 'dart:io';
import 'dart:typed_data';

import '../models/chat_input_data.dart';
import '../../utils/sandbox_path_resolver.dart';

const String multimodalInternalMediaPathsKey = '_kelivo_media_paths';
const String multimodalInternalRevisionIdKey = '_kelivo_revision_id';

bool isImageMime(String mime) => mime.toLowerCase().startsWith('image/');

bool isAudioMime(String mime) => mime.toLowerCase().startsWith('audio/');

bool isVideoMime(String mime) => mime.toLowerCase().startsWith('video/');

String inferMediaMimeFromSource(String source, {String fallbackMime = ''}) {
  final lower = source.toLowerCase();
  if (lower.startsWith('data:')) {
    final start = lower.indexOf(':');
    final semi = lower.indexOf(';');
    if (start >= 0 && semi > start) {
      return lower.substring(start + 1, semi);
    }
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.pcm16')) return 'audio/pcm16';
  if (lower.endsWith('.pcm')) return 'audio/pcm';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.mpeg') || lower.endsWith('.mpg')) return 'video/mpeg';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.avi')) return 'video/x-msvideo';
  if (lower.endsWith('.mkv')) return 'video/x-matroska';
  if (lower.endsWith('.flv')) return 'video/x-flv';
  if (lower.endsWith('.wmv')) return 'video/x-ms-wmv';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.3gp') || lower.endsWith('.3gpp')) return 'video/3gpp';
  return fallbackMime;
}

String resolveMediaAttachmentMime({
  required String explicitMime,
  required String fileName,
  required String path,
}) {
  final normalizedExplicit = explicitMime.trim().toLowerCase();
  if (isImageMime(normalizedExplicit) ||
      isAudioMime(normalizedExplicit) ||
      isVideoMime(normalizedExplicit)) {
    return normalizedExplicit;
  }

  final byName = inferMediaMimeFromSource(fileName);
  if (byName.isNotEmpty) return byName;

  final byPath = inferMediaMimeFromSource(path);
  if (byPath.isNotEmpty) return byPath;

  return normalizedExplicit;
}

String resolveDocumentAttachmentMime(DocumentAttachment attachment) {
  return resolveMediaAttachmentMime(
    explicitMime: attachment.mime,
    fileName: attachment.fileName,
    path: attachment.path,
  );
}

/// 单个 `_kelivo_media_paths` 条目（旧版 [String] 或 map）的解析形式。
///
/// 传输契约：
/// - 裸 [String] URI，或
/// - 带 `uri` / `mime` / `unavailable` 键的 map（读取时为兼容性
///   接受旧版 `path`）。
typedef InternalMediaRef = ({String uri, String? mime, bool unavailable});

bool _mediaRefAsBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.trim().toLowerCase();
    return lower == 'true' || lower == '1' || lower == 'yes';
  }
  return false;
}

/// 从裸 URI 字符串或
/// `{uri, mime?, unavailable?}` map 解析单个内部媒体引用。无可用 URI 时返回 null。
///
/// 除非 [includeUnavailable] 为 true，否则跳过 unavailable 的 map 条目。
InternalMediaRef? parseInternalMediaRef(
  dynamic entry, {
  bool includeUnavailable = false,
}) {
  if (entry == null) return null;
  if (entry is String) {
    final uri = entry.trim();
    if (uri.isEmpty) return null;
    return (uri: uri, mime: null, unavailable: false);
  }
  if (entry is Map) {
    final uri = (entry['uri'] ?? entry['path'] ?? '').toString().trim();
    if (uri.isEmpty) return null;
    final unavailable = _mediaRefAsBool(entry['unavailable']);
    if (unavailable && !includeUnavailable) return null;
    final rawMime = entry['mime'];
    final mime = rawMime?.toString().trim();
    return (
      uri: uri,
      mime: (mime == null || mime.isEmpty) ? null : mime,
      unavailable: unavailable,
    );
  }
  final uri = entry.toString().trim();
  if (uri.isEmpty) return null;
  return (uri: uri, mime: null, unavailable: false);
}

/// 为 `_kelivo_media_paths` 编码结构化媒体引用。
///
/// 写入 `{uri, mime?, unavailable?}`。写入方应跳过 unavailable 的 part，
/// 而非编码它们；[unavailable] 仅用于罕见诊断场景。
Map<String, dynamic> encodeInternalMediaRef({
  required String uri,
  String? mime,
  bool unavailable = false,
}) {
  final trimmedUri = uri.trim();
  final trimmedMime = mime?.trim();
  return <String, dynamic>{
    'uri': trimmedUri,
    if (trimmedMime != null && trimmedMime.isNotEmpty) 'mime': trimmedMime,
    if (unavailable) 'unavailable': true,
  };
}

/// 从 `_kelivo_media_paths` 列表值解析可用引用。
///
/// 除非 [includeUnavailable] 为 true，否则跳过 unavailable 的 map 条目。
List<InternalMediaRef> parseInternalMediaRefs(
  dynamic raw, {
  bool includeUnavailable = false,
}) {
  if (raw is! List) return const <InternalMediaRef>[];
  final out = <InternalMediaRef>[];
  for (final entry in raw) {
    final ref = parseInternalMediaRef(
      entry,
      includeUnavailable: includeUnavailable,
    );
    if (ref != null) out.add(ref);
  }
  return out;
}

/// 编码多个引用；默认跳过空 URI 和 unavailable 条目。
List<Map<String, dynamic>> encodeInternalMediaRefs(
  Iterable<InternalMediaRef> refs, {
  bool includeUnavailable = false,
}) {
  final out = <Map<String, dynamic>>[];
  for (final ref in refs) {
    final uri = ref.uri.trim();
    if (uri.isEmpty) continue;
    if (ref.unavailable && !includeUnavailable) continue;
    out.add(
      encodeInternalMediaRef(
        uri: uri,
        mime: ref.mime,
        unavailable: includeUnavailable ? ref.unavailable : false,
      ),
    );
  }
  return out;
}

/// `_kelivo_media_paths` 的纯 URI 视图（String|Map 条目）。
/// 省略 unavailable 的 map 条目。
List<String> internalMediaPathsFromRaw(dynamic raw) {
  return [for (final ref in parseInternalMediaRefs(raw)) ref.uri];
}

bool isRemoteOrDataUri(String uri) {
  final lower = uri.toLowerCase();
  return lower.startsWith('data:') ||
      lower.startsWith('http://') ||
      lower.startsWith('https://');
}

/// 旧版解码器与新建路径共享的 MIME 推断。
/// 顺序：显式 → data-URL 声明 → 内容嗅探 → 扩展名 → null。
Future<String?> inferAttachmentMime({
  required String uri,
  String? explicitMime,
  String? fileName,
}) async {
  final explicit = explicitMime?.trim();
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }

  if (uri.toLowerCase().startsWith('data:')) {
    final declared = inferMediaMimeFromSource(uri);
    if (declared.isNotEmpty) return declared;
  }

  if (!isRemoteOrDataUri(uri)) {
    final sniffed = await sniffMimeFromFile(uri);
    if (sniffed != null) return sniffed;
  }

  if (fileName != null) {
    final byName = inferMediaMimeFromSource(fileName);
    if (byName.isNotEmpty) return byName;
  }
  final byUri = inferMediaMimeFromSource(uri);
  if (byUri.isNotEmpty) return byUri;
  return null;
}

Future<String?> sniffMimeFromFile(String path) async {
  try {
    final resolved = SandboxPathResolver.resolveForIo(path);
    if (resolved == null) return null;
    final file = File(resolved);
    if (!file.existsSync()) return null;
    final raf = await file.open();
    try {
      final length = await raf.length();
      if (length <= 0) return null;
      final toRead = length < 16 ? length : 16;
      final bytes = await raf.read(toRead);
      return sniffMimeFromBytes(bytes);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}

String? sniffMimeFromBytes(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x25 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x44 &&
      bytes[3] == 0x46) {
    return 'application/pdf';
  }
  return null;
}
