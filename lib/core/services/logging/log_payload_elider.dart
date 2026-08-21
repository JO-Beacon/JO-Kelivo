/// 日志中被占位符替换的大型二进制负载。
class LogPayloadRef {
  const LogPayloadRef({required this.mime, required this.base64Chars});

  final String mime;

  /// 被省略的 base64 文本长度，以字符计。
  final int base64Chars;

  /// 解码后负载的大致大小。
  int get byteLength => (base64Chars * 3) ~/ 4;

  @override
  bool operator ==(Object other) =>
      other is LogPayloadRef &&
      other.mime == mime &&
      other.base64Chars == base64Chars;

  @override
  int get hashCode => Object.hash(mime, base64Chars);

  @override
  String toString() => 'LogPayloadRef($mime, $base64Chars chars)';
}

/// 单次省略处理的结果。
class LogPayloadElision {
  const LogPayloadElision({required this.text, required this.refs});

  final String text;
  final List<LogPayloadRef> refs;
}

/// 将内联 base64 负载（图像、文件、音频）替换为简短
/// 占位符，使日志保持足够小，便于写入、解析和渲染。
///
/// 覆盖提供方使用的三种格式：
/// * OpenAI 兼容格式 — `"url": "data:image/png;base64,<payload>"`
/// * Claude — `{"type":"base64","media_type":"image/png","data":"<payload>"}`
/// * Gemini — `{"inline_data":{"mime_type":"image/png","data":"<payload>"}}`
///
/// 扫描采用手工实现，而不是使用 `RegExp`。Dart 的正则引擎会回溯，
/// 跨数兆字节有效载荷的量词会让原生栈溢出——这正是本类要处理的情况。
class LogPayloadElider {
  LogPayloadElider._();

  /// 短于此长度的裸 base64 连续片段按原样保留。
  static const int bareBase64Threshold = 4096;

  static const String fallbackMime = 'application/octet-stream';

  static const String _b64Marker = ';base64,';

  /// `data:` 前缀与它的 `;base64,` 标记之间最多可以相隔多远。
  /// 限定拒绝非匹配项时所需的工作量。
  static const int _mimeLookback = 128;

  /// 在裸 payload 旁边向前查找 `mime_type` 字段的最大距离。
  static const int _mimeHintWindow = 200;

  static const int _quote = 0x22; // "
  static const int _comma = 0x2C; // ,
  static const int _colon = 0x3A; // :
  static const int _semi = 0x3B; // ;
  static const int _equals = 0x3D; // =

  static final RegExp _mimeHintRe = RegExp(
    r'"(?:mime_type|mimeType|media_type|mediaType)"\s*:\s*"([^"]{1,120})"',
  );

  /// 同时用于两遍处理。占位符从不包含 `\"` 或 `\\`，因此 JSON 主体在替换后
  /// 仍可解码。
  static String elide(String text) =>
      _bareBase64Pass(elideDataUris(text), null);

  /// 将内联的 `data:...;base64,...` payload 替换为简短占位符。
  static String elideDataUris(String text) => _dataUriPass(text, null);

  /// 将较长且不间断的 base64 JSON 字符串值替换为占位符。
  static String elideBareBase64(String text) => _bareBase64Pass(text, null);

  static String placeholder(int chars) => '<omitted $chars chars>';

  /// 在一次遍历中同时完成省略和报告——比分别调用 [elide] 和 [describe] 更高效。
  ///
  /// 将 [rewrite] 设为 false，可在不替换有效载荷的情况下进行报告。
  /// 无论哪种方式都会收集引用，并覆盖进入日志时已被占位符替换的有效载荷。
  static LogPayloadElision process(String text, {bool rewrite = true}) {
    final refs = <LogPayloadRef>[];
    final afterUris = _dataUriPass(text, refs, rewrite: rewrite);
    final out = _bareBase64Pass(afterUris, refs, rewrite: rewrite);
    return LogPayloadElision(text: out, refs: refs);
  }

  /// 描述 [elide] 会移除的有效载荷，用于日志查看器的附件标记。
  static List<LogPayloadRef> describe(String text) => process(text).refs;

  // ---------------------------------------------------------------- 处理阶段

  static String _dataUriPass(
    String text,
    List<LogPayloadRef>? refs, {
    bool rewrite = true,
  }) {
    final len = text.length;
    StringBuffer? out;
    var last = 0;
    var from = 0;

    while (from < len) {
      final marker = text.indexOf(_b64Marker, from);
      if (marker < 0) break;

      final uriStart = _dataUriStart(text, marker);
      if (uriStart < 0) {
        from = marker + _b64Marker.length;
        continue;
      }

      final payloadStart = marker + _b64Marker.length;
      final mime = text.substring(uriStart + 5, marker);

      // 在写入日志途中已被省略，只需报告并保持原样。
      final existing = _readPlaceholder(text, payloadStart);
      if (existing != null) {
        refs?.add(LogPayloadRef(mime: mime, base64Chars: existing.chars));
        from = existing.end;
        continue;
      }

      final payloadEnd = _payloadEnd(text, payloadStart);
      if (payloadEnd <= payloadStart) {
        from = payloadStart;
        continue;
      }

      final chars = payloadEnd - payloadStart;
      refs?.add(LogPayloadRef(mime: mime, base64Chars: chars));
      from = payloadEnd;

      if (!rewrite) continue;
      out ??= StringBuffer();
      out.write(text.substring(last, payloadStart));
      out.write(placeholder(chars));
      last = payloadEnd;
    }

    if (out == null) return text;
    out.write(text.substring(last));
    return out.toString();
  }

  static String _bareBase64Pass(
    String text,
    List<LogPayloadRef>? refs, {
    bool rewrite = true,
  }) {
    final len = text.length;

    StringBuffer? out;
    var last = 0;
    var i = 0;

    while (i < len) {
      if (text.codeUnitAt(i) != _quote) {
        i++;
        continue;
      }

      // 在写入日志途中已被替换的 payload。
      final existing = _readPlaceholder(text, i + 1);
      if (existing != null &&
          existing.end < len &&
          text.codeUnitAt(existing.end) == _quote) {
        refs?.add(
          LogPayloadRef(
            mime: _mimeBefore(text, i + 1),
            base64Chars: existing.chars,
          ),
        );
        i = existing.end + 1;
        continue;
      }

      if (len <= bareBase64Threshold) {
        i++;
        continue;
      }

      final start = i + 1;
      var end = start;
      while (end < len && _isBase64Unit(text.codeUnitAt(end))) {
        end++;
      }

      var close = end;
      var pad = 0;
      while (close < len && pad < 2 && text.codeUnitAt(close) == _equals) {
        close++;
        pad++;
      }

      final isPayload =
          close < len &&
          text.codeUnitAt(close) == _quote &&
          (end - start) >= bareBase64Threshold;

      if (isPayload) {
        final chars = close - start;
        refs?.add(
          // 从起始引号向前回看，mime 字段在其前面。
          LogPayloadRef(mime: _mimeBefore(text, start), base64Chars: chars),
        );
        i = close + 1;
        if (rewrite) {
          out ??= StringBuffer();
          out.write(text.substring(last, start));
          out.write(placeholder(chars));
          last = close;
        }
        continue;
      }

      // 跳过刚刚测量的连续片段；其中不可能包含起始引号。
      i = close > start ? close : i + 1;
    }

    if (out == null) return text;
    out.write(text.substring(last));
    return out.toString();
  }

  // --------------------------------------------------------------- 辅助函数

  /// 返回 URI 起始处 `data:` 的索引；该 URI 的标记位于 [marker]，
  /// 当标记不属于 data URI 时返回 -1。
  static int _dataUriStart(String text, int marker) {
    final lo = marker - _mimeLookback < 0 ? 0 : marker - _mimeLookback;

    // mime 类型匹配 `[^;,\\s]+`，因此只向前回退这些字符。
    var i = marker;
    while (i > lo) {
      final c = text.codeUnitAt(i - 1);
      if (c == _semi || c == _comma || _isSpace(c)) break;
      i--;
    }

    // 仍能留下非空 mime 类型的最左侧 `data:`。
    for (var p = i; p + 5 < marker; p++) {
      if (_isDataPrefix(text, p)) return p;
    }
    return -1;
  }

  /// 从 [start] 开始的 base64 连续片段的结束位置。空白和 `=` 属于
  /// 该连续片段的一部分，这与各提供方写入这些 payload 的方式一致。
  static int _payloadEnd(String text, int start) {
    final len = text.length;
    var end = start;
    while (end < len) {
      final c = text.codeUnitAt(end);
      if (_isBase64Unit(c) || c == _equals || _isSpace(c)) {
        end++;
        continue;
      }
      break;
    }
    return end;
  }

  /// 读取 [start] 处的 `<omitted N chars>` 占位符，使写入方
  /// 已省略的 payload 仍可作为附件报告。
  static ({int chars, int end})? _readPlaceholder(String text, int start) {
    const head = '<omitted ';
    const tail = ' chars>';
    if (!text.startsWith(head, start)) return null;

    var p = start + head.length;
    final digitsFrom = p;
    while (p < text.length) {
      final c = text.codeUnitAt(p);
      if (c < 0x30 || c > 0x39) break;
      p++;
    }
    if (p == digitsFrom) return null;
    if (!text.startsWith(tail, p)) return null;

    final chars = int.tryParse(text.substring(digitsFrom, p));
    if (chars == null) return null;
    return (chars: chars, end: p + tail.length);
  }

  /// 回看一个短窗口，以查找裸 payload 旁的 mime 字段。
  static String _mimeBefore(String text, int start) {
    final from = start - _mimeHintWindow < 0 ? 0 : start - _mimeHintWindow;
    final slice = text.substring(from, start);
    String? last;
    for (final m in _mimeHintRe.allMatches(slice)) {
      last = m[1];
    }
    return last ?? fallbackMime;
  }

  static bool _isDataPrefix(String t, int p) {
    return _lower(t.codeUnitAt(p)) == 0x64 && // d
        _lower(t.codeUnitAt(p + 1)) == 0x61 && // a
        _lower(t.codeUnitAt(p + 2)) == 0x74 && // t
        _lower(t.codeUnitAt(p + 3)) == 0x61 && // a
        t.codeUnitAt(p + 4) == _colon;
  }

  static int _lower(int c) => (c >= 0x41 && c <= 0x5A) ? c + 32 : c;

  static bool _isBase64Unit(int c) =>
      (c >= 0x41 && c <= 0x5A) || // A-Z
      (c >= 0x61 && c <= 0x7A) || // a-z
      (c >= 0x30 && c <= 0x39) || // 0-9
      c == 0x2B || // +
      c == 0x2F; // /

  static bool _isSpace(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      c == 0x0B ||
      c == 0x0C;
}
