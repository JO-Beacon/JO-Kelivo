import '../../models/message_part.dart';
import '../../utils/multimodal_input_utils.dart';
import '../../../utils/sandbox_path_resolver.dart';

class LegacyDecodeResult {
  final List<MessagePart> parts;
  final int converted;
  final int malformed;
  final int missingFiles;

  const LegacyDecodeResult({
    required this.parts,
    required this.converted,
    required this.malformed,
    required this.missingFiles,
  });
}

/// 将带旧版标记的 content 解码为结构化 [MessagePart]。
///
/// 这是唯一允许识别
/// `[image:…]` / `[file:…]` 标记的运行时相关位置。生产环境的发送/渲染路径不得
/// 重新引入标记解析。
///
/// 当 [existingParts] 已包含 image/file part 时，输入原样
/// 返回（消息级幂等）。
Future<LegacyDecodeResult> decodeLegacyContent(
  String content, {
  List<MessagePart>? existingParts,
  bool Function(String path)? fileExists,
}) async {
  if (existingParts != null &&
      existingParts.any((part) => part is ImagePart || part is FilePart)) {
    return LegacyDecodeResult(
      parts: existingParts,
      converted: 0,
      malformed: 0,
      missingFiles: 0,
    );
  }

  if (content.isEmpty) {
    return const LegacyDecodeResult(
      parts: <MessagePart>[],
      converted: 0,
      malformed: 0,
      missingFiles: 0,
    );
  }

  final exists = fileExists ?? _defaultFileExists;
  final parts = <MessagePart>[];
  final textLines = <_ContentLine>[];
  var converted = 0;
  var malformed = 0;
  var missingFiles = 0;
  _FenceState? fence;
  // 当可转换标记在文本片段之间被移除时，保留一个换行符，使
  // TextPart 载荷拼接（无分隔符）得到 `a\nb` 而非 `ab`。
  // 该分隔符是前一段文本行原本的结尾。
  String? pendingEnding;
  String lastFlushedEol = '\n';

  void flushText() {
    if (textLines.isEmpty) return;
    lastFlushedEol = textLines.last.eol.isNotEmpty ? textLines.last.eol : '\n';
    parts.add(TextPart(_joinContentLines(textLines)));
    textLines.clear();
  }

  void addTextLine(_ContentLine line) {
    if (pendingEnding != null && textLines.isEmpty) {
      textLines.add(_ContentLine(text: '', eol: pendingEnding!));
    }
    pendingEnding = null;
    textLines.add(line);
  }

  void markAttachmentBoundary() {
    flushText();
    if (parts.any((part) => part is TextPart)) {
      pendingEnding ??= lastFlushedEol;
    } else {
      pendingEnding = null;
    }
  }

  for (final line in _splitKeepingEndings(content)) {
    if (fence != null) {
      addTextLine(line);
      if (_isClosingFence(line.text, fence)) {
        fence = null;
      }
      continue;
    }

    final opened = _matchOpeningFence(line.text);
    if (opened != null) {
      fence = opened;
      addTextLine(line);
      continue;
    }

    final imageUri = _matchExclusiveImageMarker(line.text);
    if (imageUri != null) {
      if (imageUri.isEmpty) {
        malformed += 1;
        addTextLine(line);
        continue;
      }
      markAttachmentBoundary();
      final local = _isLocalPath(imageUri);
      final missing = local && !exists(imageUri);
      if (missing) missingFiles += 1;
      final mime = await inferAttachmentMime(uri: imageUri);
      parts.add(
        ImagePart(
          uri: SandboxPathResolver.canonicalize(imageUri),
          mime: mime,
          unavailable: missing,
        ),
      );
      converted += 1;
      continue;
    }

    final fileMarker = _matchExclusiveFileMarker(line.text);
    if (fileMarker != null) {
      final parsed = _parseFileMarker(fileMarker);
      if (parsed == null) {
        malformed += 1;
        addTextLine(line);
        continue;
      }
      markAttachmentBoundary();
      final local = _isLocalPath(parsed.uri);
      final missing = local && !exists(parsed.uri);
      if (missing) missingFiles += 1;
      final mime = await inferAttachmentMime(
        uri: parsed.uri,
        explicitMime: parsed.mime,
        fileName: parsed.name,
      );
      parts.add(
        FilePart(
          uri: SandboxPathResolver.canonicalize(parsed.uri),
          name: parsed.name,
          mime: mime,
          unavailable: missing,
        ),
      );
      converted += 1;
      continue;
    }

    addTextLine(line);
  }

  flushText();

  return LegacyDecodeResult(
    parts: List<MessagePart>.unmodifiable(parts),
    converted: converted,
    malformed: malformed,
    missingFiles: missingFiles,
  );
}

/// 独立地从旧版 content 中剥离可转换的独占标记，并
/// 返回剩余的文本段（在移除的标记间保留换行符）。
/// 用于迁移摘要预期，使校验不会
/// 只是回显解码器的 [TextPart] 对象。
///
/// 用空分隔符拼接返回的段，等于对同一输入
/// 成功解码后的 [ChatMessage.content]。
List<String> stripLegacyContentTextSegments(String content) {
  if (content.isEmpty) return const [''];

  final segments = <String>[];
  final textLines = <_ContentLine>[];
  _FenceState? fence;
  String? pendingEnding;
  String lastFlushedEol = '\n';

  void flushText() {
    if (textLines.isEmpty) return;
    lastFlushedEol = textLines.last.eol.isNotEmpty ? textLines.last.eol : '\n';
    segments.add(_joinContentLines(textLines));
    textLines.clear();
  }

  void addTextLine(_ContentLine line) {
    if (pendingEnding != null && textLines.isEmpty) {
      textLines.add(_ContentLine(text: '', eol: pendingEnding!));
    }
    pendingEnding = null;
    textLines.add(line);
  }

  void markAttachmentBoundary() {
    flushText();
    if (segments.isNotEmpty) {
      pendingEnding ??= lastFlushedEol;
    } else {
      pendingEnding = null;
    }
  }

  for (final line in _splitKeepingEndings(content)) {
    if (fence != null) {
      addTextLine(line);
      if (_isClosingFence(line.text, fence)) {
        fence = null;
      }
      continue;
    }

    final opened = _matchOpeningFence(line.text);
    if (opened != null) {
      fence = opened;
      addTextLine(line);
      continue;
    }

    final imageUri = _matchExclusiveImageMarker(line.text);
    if (imageUri != null) {
      if (imageUri.isEmpty) {
        addTextLine(line);
        continue;
      }
      markAttachmentBoundary();
      continue;
    }

    final fileMarker = _matchExclusiveFileMarker(line.text);
    if (fileMarker != null) {
      final parsed = _parseFileMarker(fileMarker);
      if (parsed == null) {
        addTextLine(line);
        continue;
      }
      markAttachmentBoundary();
      continue;
    }

    addTextLine(line);
  }

  flushText();
  // 到达此处却没有段，意味着每行都是可转换标记
  // （空内容已在上方返回 ['']）。解码器对这种纯附件内容
  // 不输出 TextPart，迁移服务仅当 part 列表完全为空时
  // 才替换为 TextPart('')，因此摘要预期也必须为空。
  if (segments.isEmpty) return const <String>[];
  return List<String>.unmodifiable(segments);
}

final RegExp _exclusiveImage = RegExp(r'^\[image:(.*)\]$');
final RegExp _exclusiveFile = RegExp(r'^\[file:(.*)\]$');
final RegExp _validFileSegments = RegExp(
  r'^\[file:([^|\]]+)\|([^|\]]+)\|([^|\]]*)\]$',
);
final RegExp _openingFence = RegExp(r'^( {0,3})(`{3,}|~{3,})(.*)$');

class _ContentLine {
  final String text;
  final String eol;
  const _ContentLine({required this.text, required this.eol});
}

class _FenceState {
  final String char;
  final int length;
  const _FenceState({required this.char, required this.length});
}

/// 拆分 [content] 同时保留每个原始 `\r\n` / `\n` / `\r`
/// 分隔符。镜像 `split` 对换行的处理：当 [content] 以换行结尾时
/// 保留尾部空行。
List<_ContentLine> _splitKeepingEndings(String content) {
  if (content.isEmpty) return const <_ContentLine>[];

  final out = <_ContentLine>[];
  final re = RegExp(r'\r\n|\n|\r');
  var start = 0;
  for (final match in re.allMatches(content)) {
    out.add(
      _ContentLine(
        text: content.substring(start, match.start),
        eol: match.group(0)!,
      ),
    );
    start = match.end;
  }
  if (start < content.length) {
    out.add(_ContentLine(text: content.substring(start), eol: ''));
  } else {
    // 尾部换行 → 末尾空行，与 String.split 行为一致。
    out.add(const _ContentLine(text: '', eol: ''));
  }
  return out;
}

String _joinContentLines(List<_ContentLine> lines) {
  if (lines.isEmpty) return '';
  final buffer = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    buffer.write(lines[i].text);
    if (i < lines.length - 1) {
      buffer.write(lines[i].eol);
    }
  }
  return buffer.toString();
}

/// CommonMark 开场围栏：可选 0–3 个空格 + 3 个及以上的 ` 或 ~。
/// info string 仅在开场围栏允许；反引号围栏拒绝
/// 自身包含反引号的 info string。
_FenceState? _matchOpeningFence(String line) {
  final match = _openingFence.firstMatch(line);
  if (match == null) return null;
  final run = match.group(2)!;
  final char = run[0];
  final info = match.group(3) ?? '';
  if (char == '`' && info.contains('`')) return null;
  return _FenceState(char: char, length: run.length);
}

/// CommonMark 闭合围栏：可选 0–3 个空格 + 相同字符的连续段
/// 长度 >= 开场长度，之后仅允许到行尾的可选空格。
bool _isClosingFence(String line, _FenceState fence) {
  final escaped = RegExp.escape(fence.char);
  final closing = RegExp('^( {0,3})($escaped{${fence.length},}) *\$');
  return closing.hasMatch(line);
}

String? _matchExclusiveImageMarker(String line) {
  final match = _exclusiveImage.firstMatch(line);
  if (match == null) return null;
  return (match.group(1) ?? '').trim();
}

String? _matchExclusiveFileMarker(String line) {
  final match = _exclusiveFile.firstMatch(line);
  return match?.group(1);
}

({String uri, String name, String mime})? _parseFileMarker(String inner) {
  // 对重构后的行按严格的 3 段格式重新校验。
  final match = _validFileSegments.firstMatch('[file:$inner]');
  if (match == null) return null;
  final uri = match.group(1)!.trim();
  final name = match.group(2)!.trim();
  final mime = match.group(3)!.trim();
  if (uri.isEmpty || name.isEmpty) return null;
  return (uri: uri, name: name, mime: mime);
}

bool _isLocalPath(String uri) => !isRemoteOrDataUri(uri);

bool _defaultFileExists(String path) {
  // 不要使用 fix()：其通用的 `/images/`·basename 探测在存在同名受管文件时，
  // 可能把缺失的外部路径标记为可用。
  return SandboxPathResolver.localFileExists(path);
}
