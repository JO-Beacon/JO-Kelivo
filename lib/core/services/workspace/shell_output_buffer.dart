import 'dart:convert';

import 'output_buffer.dart';

enum _EscapeState { none, escape, intermediate, csi, string, stringEscape }

/// 给 shell 工具用的有界纯文本输出，不是交互式终端。
/// 回车开始一帧替换用的进度内容；在可打印文本到来之前，上一帧仍然可见。
/// UTF-8 与转义解析都能跨分块边界正确接续。
class ShellOutputBuffer {
  ShellOutputBuffer({this.maxBytes = 128 * 1024, this.onLine})
    : _completed = BoundedStreamBuffer(maxBytes: maxBytes),
      _line = BoundedStreamBuffer(maxBytes: maxBytes);

  final int maxBytes;
  final void Function(String line)? onLine;
  final BoundedStreamBuffer _completed;
  BoundedStreamBuffer _line;
  late final ByteConversionSink _decoder = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(_TextSink(_consume));
  _EscapeState _escape = _EscapeState.none;
  bool _replaceLine = false;
  bool _completedLineTruncated = false;
  bool _closed = false;
  bool _emittedText = false;

  String get currentLine => _line.text;

  bool get truncated =>
      _completedLineTruncated ||
      _completed.totalBytes + _line.totalBytes > maxBytes;

  String get text {
    if (_line.totalBytes == 0) return _completed.text;
    if (_completed.totalBytes == 0) return currentLine;
    // 两段各自先解码再拼接，否则头尾接缝处被截断的 UTF-8
    // 会变成一个替换字符。
    final combined = BoundedStreamBuffer(maxBytes: maxBytes)
      ..add(utf8.encode(_completed.text))
      ..add(utf8.encode(currentLine));
    return combined.text;
  }

  /// 本块是否输出了可打印文本。整行通过 [onLine] 交付；
  /// 控制序列与不完整的 UTF-8 不算输出文本。
  bool add(List<int> bytes) {
    if (_closed) throw StateError('Shell output is already closed');
    _emittedText = false;
    _decoder.add(bytes);
    return _emittedText;
  }

  /// 收尾 UTF-8 时是否输出了可打印文本。
  bool close() {
    if (_closed) return false;
    _emittedText = false;
    _decoder.close();
    _closed = true;
    return _emittedText;
  }

  /// 给已落库的 shell 预览用同一套规则，但不缩短输入。
  static String normalize(String text) {
    final bytes = utf8.encode(text);
    final output = ShellOutputBuffer(maxBytes: bytes.length + 4)
      ..add(bytes)
      ..close();
    return output.text;
  }

  void _consume(String text) {
    var index = 0;
    while (index < text.length) {
      final code = text.codeUnitAt(index);
      if (_escape == _EscapeState.none && _isText(code)) {
        final start = index++;
        while (index < text.length && _isText(text.codeUnitAt(index))) {
          index++;
        }
        if (_replaceLine) {
          _line = BoundedStreamBuffer(maxBytes: maxBytes);
          _replaceLine = false;
        }
        _line.add(utf8.encode(text.substring(start, index)));
        _emittedText = true;
        continue;
      }
      index++;
      if (_escape == _EscapeState.string ||
          _escape == _EscapeState.stringEscape) {
        if (code == 0x07 ||
            code == 0x9c ||
            (_escape == _EscapeState.stringEscape && code == 0x5c)) {
          _escape = _EscapeState.none;
        } else {
          _escape = code == 0x1b
              ? _EscapeState.stringEscape
              : _EscapeState.string;
        }
        continue;
      }
      switch (code) {
        case 0x1b:
          _escape = _EscapeState.escape;
        case 0x9b:
          _escape = _EscapeState.csi;
        case 0x90 || 0x98 || 0x9d || 0x9e || 0x9f:
          _escape = _EscapeState.string;
        case 0x0d:
          _replaceLine = true;
          _escape = _EscapeState.none;
        case 0x0a:
          final line = currentLine;
          _completedLineTruncated |= _line.truncated;
          _completed.add(utf8.encode('$line\n'));
          onLine?.call(line);
          _line = BoundedStreamBuffer(maxBytes: maxBytes);
          _replaceLine = false;
          _escape = _EscapeState.none;
        default:
          switch (_escape) {
            case _EscapeState.escape:
              _escape = switch (code) {
                0x5b => _EscapeState.csi,
                0x5d || 0x50 || 0x58 || 0x5e || 0x5f => _EscapeState.string,
                >= 0x20 && <= 0x2f => _EscapeState.intermediate,
                _ => _EscapeState.none,
              };
            case _EscapeState.csi:
              if (code >= 0x40 && code <= 0x7e) {
                _escape = _EscapeState.none;
              }
            case _EscapeState.intermediate:
              if (code >= 0x30 && code <= 0x7e) {
                _escape = _EscapeState.none;
              }
            case _EscapeState.none ||
                _EscapeState.string ||
                _EscapeState.stringEscape:
              break;
          }
      }
    }
  }

  static bool _isText(int code) =>
      code == 0x09 || (code >= 0x20 && (code < 0x7f || code > 0x9f));
}

class _TextSink implements Sink<String> {
  _TextSink(this.onText);

  final void Function(String text) onText;

  @override
  void add(String data) => onText(data);

  @override
  void close() {}
}
