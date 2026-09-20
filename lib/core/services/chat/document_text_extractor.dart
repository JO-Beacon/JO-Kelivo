import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/unicode_sanitizer.dart';

/// 传递给后台 isolate 用于文档提取的数据。
class _ExtractorParams {
  final String path;
  final String mime;
  _ExtractorParams(this.path, this.mime);
}

class AttachmentRequiresWorkspace implements Exception {
  const AttachmentRequiresWorkspace(this.name);
  final String name;
  @override
  String toString() => 'Attachment requires workspace file tools: $name';
}

class DocumentTextExtractor {
  /// 从位于 [path] 且类型为 [mime] 的文档文件中提取文本。
  ///
  /// 通过 [SandboxPathResolver.resolveForIo] 解析一次，然后委托给
  /// [extractResolved]。当调用方已经解析过路径时，优先使用 [extractResolved]
  /// （避免第二次解析）。
  static Future<String> extract({
    required String path,
    required String mime,
  }) async {
    final resolved = SandboxPathResolver.resolveForIo(path);
    if (resolved == null) return '[[File not found: $path]]';
    return extractResolved(path: resolved, mime: mime);
  }

  /// 使用已经解析好的绝对文件系统路径进行提取。
  /// **不会**调用 [SandboxPathResolver.fix] / [resolveForIo]。
  static Future<String> extractResolved({
    required String path,
    required String mime,
  }) {
    // 使用 compute 将繁重工作转移到单独的 isolate。
    return compute(_extractTask, _ExtractorParams(path, mime));
  }

  /// 在后台 isolate 中运行的繁重提取逻辑。
  static String _extractTask(_ExtractorParams params) {
    final path = params.path;
    final mime = params.mime;

    try {
      final source = File(path);
      if (!source.existsSync()) return '[[File not found: $path]]';
      // 接收文件与把它内联到模型请求里是两回事。
      // 更大的文件仍可供工作区工具使用，无需整份读取。
      if (source.lengthSync() > 16 * 1024 * 1024) {
        throw AttachmentRequiresWorkspace(p.basename(path));
      }
      if (mime == 'application/pdf') {
        try {
          final file = File(path);
          if (!file.existsSync()) return '[[File not found: $path]]';

          final bytes = file.readAsBytesSync();
          // 繁重的同步 PDF 解析在此处、在子线程中进行。
          final document = PdfDocument(inputBytes: bytes);
          final extractor = PdfTextExtractor(document);
          final extracted = extractor.extractText();
          final text = UnicodeSanitizer.sanitize(extracted);

          document.dispose();

          if (text.trim().isNotEmpty) return text;
          return '[PDF] Unable to extract text from file.';
        } catch (e) {
          return '[[Failed to read PDF: $e]]';
        }
      }

      if (mime == 'application/msword') {
        return '[[DOC format (.doc) not supported for text extraction]]';
      }

      if (mime ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
        return _extractDocxSync(path);
      }

      // 未知类型可能是压缩包或可执行文件。先探测一小段前缀，
      // 再判断按文本读取是否有意义。
      final probe = source.openSync();
      try {
        final prefix = probe.readSync(8192);
        if (prefix.contains(0)) {
          throw AttachmentRequiresWorkspace(p.basename(path));
        }
        final decoder = utf8.decoder.startChunkedConversion(
          StringConversionSink.fromStringSink(StringBuffer()),
        );
        try {
          decoder.add(prefix);
          if (source.lengthSync() <= prefix.length) decoder.close();
        } on FormatException {
          throw AttachmentRequiresWorkspace(p.basename(path));
        }
      } finally {
        probe.closeSync();
      }
      // 只读取有大小上限、且看起来是文本的文件。
      final file = File(path);
      if (!file.existsSync()) return '[[File not found: $path]]';
      final bytes = file.readAsBytesSync();
      return UnicodeSanitizer.sanitize(
        utf8.decode(bytes, allowMalformed: true),
      );
    } on AttachmentRequiresWorkspace {
      rethrow;
    } catch (e) {
      return '[[Failed to read file: $e]]';
    }
  }

  /// 供 isolate 使用的同步 DOCX 提取。
  static String _extractDocxSync(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return '[DOCX] file not found';

      final input = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(input);
      final docXml = archive.findFile('word/document.xml');
      if (docXml == null) return '[DOCX] document.xml not found';

      final xml = XmlDocument.parse(utf8.decode(docXml.content as List<int>));
      final buffer = StringBuffer();
      for (final p in xml.findAllElements('w:p')) {
        final texts = p.findAllElements('w:t');
        if (texts.isEmpty) {
          buffer.writeln();
          continue;
        }
        for (final t in texts) {
          buffer.write(t.innerText);
        }
        buffer.writeln();
      }
      return UnicodeSanitizer.sanitize(buffer.toString());
    } catch (e) {
      return '[[Failed to parse DOCX: $e]]';
    }
  }
}
