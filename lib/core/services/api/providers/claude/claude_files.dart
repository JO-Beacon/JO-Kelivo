import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../../../utils/app_directories.dart';
import '../../../../../utils/sandbox_path_resolver.dart';
import '../../../../../utils/upload_dedupe.dart';
import '../../../../utils/multimodal_input_utils.dart';
import '../../stream/stream_chunk.dart';

/// The download streams to disk, so memory is not the constraint: on desktop
/// this is the API's own per-file limit, and on a phone it is what a chat is
/// willing to spend of the device's storage on one file.
final claudeGeneratedFileSizeLimit = (Platform.isIOS || Platform.isAndroid)
    ? 200 * 1024 * 1024
    : 500 * 1024 * 1024;

const int claudeUploadSizeLimit = 100 * 1024 * 1024;
const int _uploadExpirySeconds = 24 * 60 * 60;

/// The message headers negotiate a JSON body and an SSE response; neither
/// describes a file transfer.
Map<String, String> _filesApiHeaders(Map<String, String> headers) => {
  for (final entry in headers.entries)
    if (entry.key.toLowerCase() != 'content-type' &&
        entry.key.toLowerCase() != 'accept')
      entry.key: entry.value,
};

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
  if (cleaned.length <= 255) return cleaned;
  final lastDot = cleaned.lastIndexOf('.');
  final ext = lastDot > 0 ? cleaned.substring(lastDot) : '';
  return cleaned.substring(0, 255 - ext.length) + ext;
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
      'it is larger than the ${claudeUploadSizeLimit ~/ (1024 * 1024)} MiB limit',
    );
  }
  final request = http.MultipartRequest('POST', Uri.parse('$base/files'))
    ..headers.addAll(_filesApiHeaders(headers))
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

/// Fetches [fileId] through the Files API and stores it as an upload, or null
/// when it cannot be had.
///
/// Anthropic hands a generated file back as an id rather than as bytes, so a
/// chart the model just drew is invisible until it is downloaded. Every
/// failure here is cosmetic next to losing the turn, so none of them throw.
Future<GeneratedFile?> downloadClaudeGeneratedFile({
  required http.Client client,
  required String base,
  required Map<String, String> headers,
  required String fileId,
}) async {
  try {
    final getHeaders = _filesApiHeaders(headers);

    final metaResponse = await client.get(
      Uri.parse('$base/files/$fileId'),
      headers: getHeaders,
    );
    if (metaResponse.statusCode < 200 || metaResponse.statusCode >= 300) {
      return null;
    }
    final meta = jsonDecode(metaResponse.body);
    if (meta is! Map) return null;
    // Only what a skill or the container created may be downloaded; asking for
    // anything else is a 400 that costs a round trip.
    if (meta['downloadable'] == false) return null;
    final declaredSize = meta['size_bytes'];
    if (declaredSize is int && declaredSize > claudeGeneratedFileSizeLimit) {
      return null;
    }
    // The container names the file, so it can name a path, a device, or
    // nothing at all; the local filesystem has to take what is left.
    final name = claudeGeneratedFileName(
      (meta['filename'] ?? '').toString(),
      fallback: fileId,
    );
    final reported = (meta['mime_type'] ?? '').toString().trim().toLowerCase();
    // The container named the file, so its extension is the reliable half: a
    // chart handed back as application/octet-stream still belongs in the
    // message as a picture rather than as something to download.
    final mime = reported.startsWith('image/')
        ? reported
        : inferMediaMimeFromSource(name, fallbackMime: reported);

    final dir = await AppDirectories.getUploadDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // Written under its final name straight away and hashed on the way, so a
    // file of any size costs a bounded amount of memory. Should an identical
    // copy already be stored, this one is dropped again in its favour.
    final destination = await UploadDedupe.reserveUniqueFile(dir, name);
    ({int size, List<int> bytes})? digest;
    try {
      digest = await _streamToFile(
        client: client,
        uri: Uri.parse('$base/files/$fileId/content'),
        headers: getHeaders,
        destination: destination,
      );
    } finally {
      // A download cut off — the client closed under it, say — must not
      // leave its half in the upload directory.
      if (digest == null) await _discard(destination);
    }
    if (digest == null) return null;
    var path = destination.path;
    final identical = await UploadDedupe.findIdenticalDigest(
      dir,
      digest.size,
      digest.bytes,
      name,
      exclude: path,
    );
    if (identical != null) {
      await _discard(destination);
      path = identical;
    }
    return GeneratedFile(
      uri: SandboxPathResolver.canonicalize(path),
      name: name,
      mime: mime.isEmpty ? null : mime,
    );
  } catch (_) {
    return null;
  }
}

/// Streams the body at [uri] into [destination], returning its size and
/// SHA-256, or null when the body cannot be used (a failed request or one
/// past [claudeGeneratedFileSizeLimit]). An empty body is a file: the Files
/// API reports `size_bytes: 0` for an empty CSV or placeholder the code wrote.
Future<({int size, List<int> bytes})?> _streamToFile({
  required http.Client client,
  required Uri uri,
  required Map<String, String> headers,
  required File destination,
}) async {
  final request = http.Request('GET', uri)..headers.addAll(headers);
  final response = await client.send(request);
  if (response.statusCode < 200 || response.statusCode >= 300) return null;

  final sink = destination.openWrite();
  final hash = _DigestSink();
  final hasher = sha256.startChunkedConversion(hash);
  var size = 0;
  try {
    await for (final chunk in response.stream) {
      size += chunk.length;
      if (size > claudeGeneratedFileSizeLimit) return null;
      sink.add(chunk);
      hasher.add(chunk);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  hasher.close();
  return (size: size, bytes: hash.digest!.bytes);
}

/// Receives the one digest a chunked SHA-256 conversion emits on close.
class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

Future<void> _discard(File file) async {
  try {
    await file.delete();
  } catch (_) {}
}

/// Removes a downloaded file no message will refer to — a turn cancelled
/// after the download completed. A file the download found already present
/// belongs to whichever message had it first and stays.
Future<void> discardClaudeGeneratedFile(GeneratedFile file) async {
  final path = SandboxPathResolver.resolveForIo(file.uri);
  if (path == null || UploadDedupe.isShared(path)) return;
  await _discard(File(path));
}
