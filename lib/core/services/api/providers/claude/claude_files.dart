import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../../../utils/app_directories.dart';
import '../../../../../utils/sandbox_path_resolver.dart';
import '../../../../../utils/upload_dedupe.dart';
import '../../stream/stream_chunk.dart';

const int claudeGeneratedFileSizeLimit = 500 * 1024 * 1024;
const int claudeUploadSizeLimit = 100 * 1024 * 1024;
const int _uploadExpirySeconds = 24 * 60 * 60;

class ClaudeFileUploadException implements Exception {
  const ClaudeFileUploadException(this.fileName, this.reason);

  final String fileName;
  final String reason;

  @override
  String toString() => 'Attachment "$fileName" could not be uploaded: $reason';
}

final _windowsReservedStem = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
  caseSensitive: false,
);

String claudeGeneratedFileName(String raw, {String fallback = 'download'}) {
  final base = raw.split(RegExp(r'[\\/]')).last;
  var cleaned = base
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (cleaned.isEmpty) return fallback;
  final stem = cleaned.split('.').first;
  if (_windowsReservedStem.hasMatch(stem)) cleaned = '_$cleaned';
  return cleaned.length <= 255 ? cleaned : cleaned.substring(0, 255);
}

List<String> claudeGeneratedFileIds(Object? output) {
  if (output is! Map || output['content'] is! List) return const <String>[];
  return [
    for (final item in output['content'] as List)
      if (item is Map && '${item['file_id'] ?? ''}'.isNotEmpty)
        item['file_id'].toString(),
  ];
}

Future<String> uploadClaudeFile({
  required http.Client client,
  required String base,
  required Map<String, String> headers,
  required String path,
  required String name,
  String mime = '',
}) async {
  final displayName = name.trim().isEmpty ? path : name;
  final resolved = SandboxPathResolver.resolveForIo(path);
  final file = resolved == null ? null : File(resolved);
  if (file == null || !await file.exists()) {
    throw ClaudeFileUploadException(displayName, 'the file cannot be read');
  }
  final size = await file.length();
  if (size > claudeUploadSizeLimit) {
    throw ClaudeFileUploadException(
      displayName,
      'it is larger than the ${claudeUploadSizeLimit ~/ (1024 * 1024)} MB limit',
    );
  }
  final cleanHeaders = <String, String>{
    for (final entry in headers.entries)
      if (entry.key.toLowerCase() != 'content-type' &&
          entry.key.toLowerCase() != 'accept')
        entry.key: entry.value,
  };
  final request = http.MultipartRequest('POST', Uri.parse('$base/files'))
    ..headers.addAll(cleanHeaders)
    ..fields['expires_in_seconds'] = '$_uploadExpirySeconds'
    ..files.add(
      http.MultipartFile(
        'file',
        file.openRead(),
        size,
        filename: claudeGeneratedFileName(displayName, fallback: 'upload'),
        contentType: _parseMediaType(mime),
      ),
    );
  try {
    final response = await client.send(request);
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ClaudeFileUploadException(
        displayName,
        'HTTP ${response.statusCode}: ${_apiErrorMessage(body)}',
      );
    }
    final decoded = jsonDecode(body);
    final id = decoded is Map ? (decoded['id'] ?? '').toString().trim() : '';
    if (id.isEmpty) {
      throw ClaudeFileUploadException(
        displayName,
        'the API returned no file id',
      );
    }
    return id;
  } on ClaudeFileUploadException {
    rethrow;
  } catch (e) {
    throw ClaudeFileUploadException(displayName, e.toString());
  }
}

MediaType? _parseMediaType(String mime) {
  if (mime.trim().isEmpty) return null;
  try {
    return MediaType.parse(mime.trim());
  } catch (_) {
    return null;
  }
}

String _apiErrorMessage(String body) {
  var text = body;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['error'] is Map) {
      final message = (decoded['error']['message'] ?? '').toString();
      if (message.isNotEmpty) text = message;
    }
  } catch (_) {}
  text = text.trim();
  return text.length <= 300 ? text : '${text.substring(0, 300)}…';
}

Future<GeneratedFile?> downloadClaudeGeneratedFile({
  required http.Client client,
  required String base,
  required Map<String, String> headers,
  required String fileId,
}) async {
  File? reservedFile;
  try {
    final cleanHeaders = <String, String>{
      for (final entry in headers.entries)
        if (entry.key.toLowerCase() != 'content-type' &&
            entry.key.toLowerCase() != 'accept')
          entry.key: entry.value,
    };
    final metaResponse = await client.get(
      Uri.parse('$base/files/$fileId'),
      headers: cleanHeaders,
    );
    if (metaResponse.statusCode < 200 || metaResponse.statusCode >= 300) {
      return null;
    }
    final meta = jsonDecode(metaResponse.body);
    if (meta is! Map || meta['downloadable'] == false) return null;
    final size = meta['size_bytes'];
    if (size is num && size > claudeGeneratedFileSizeLimit) return null;
    final name = claudeGeneratedFileName(
      (meta['filename'] ?? fileId).toString(),
      fallback: fileId,
    );
    final dir = await AppDirectories.getUploadDirectory();
    await dir.create(recursive: true);
    final file = await UploadDedupe.reserveUniqueFile(dir, name);
    reservedFile = file;
    final response = await client.send(
      http.Request('GET', Uri.parse('$base/files/$fileId/content'))
        ..headers.addAll(cleanHeaders),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      try {
        await file.delete();
      } catch (_) {}
      return null;
    }
    final sink = file.openWrite();
    var written = 0;
    var complete = false;
    try {
      await for (final chunk in response.stream) {
        written += chunk.length;
        if (written > claudeGeneratedFileSizeLimit) break;
        sink.add(chunk);
      }
      complete = written <= claudeGeneratedFileSizeLimit;
    } finally {
      await sink.close();
    }
    if (!complete) {
      try {
        await file.delete();
      } catch (_) {}
      return null;
    }
    if (!await file.exists()) return null;
    final mime = (meta['mime_type'] ?? '').toString();
    return GeneratedFile(
      uri: SandboxPathResolver.canonicalize(file.path),
      name: name,
      mime: mime.isEmpty ? null : mime,
    );
  } catch (_) {
    try {
      await reservedFile?.delete();
    } catch (_) {}
    return null;
  }
}
