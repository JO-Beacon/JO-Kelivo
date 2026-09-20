import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../../utils/multimodal_input_utils.dart';
import '../../../../../utils/app_directories.dart';
import '../../../../../utils/sandbox_path_resolver.dart';
import '../../../../../utils/upload_dedupe.dart';
import '../../stream/stream_chunk.dart';

/// 下载是流式落盘的，所以内存不是约束：桌面端取 API 自身的单文件上限，
/// 移动端取一次对话愿意为一个文件花掉的本机存储。
final claudeGeneratedFileSizeLimit = (Platform.isIOS || Platform.isAndroid)
    ? 200 * 1024 * 1024
    : 500 * 1024 * 1024;

/// 上传时 HTTP 客户端会把整个文件缓冲在内存里再发出去，因此这里是移动端
/// 单次请求能承受的内存量 —— 远低于 API 自身的上限。
const int claudeUploadSizeLimit = 100 * 1024 * 1024;

/// 上传的附件保留多久。紧随上传的那次请求会把它复制进容器，此后不再有
/// 任何东西引用这个文件。
const int _uploadExpirySeconds = 24 * 60 * 60;

/// 消息用的请求头协商的是 JSON 请求体与 SSE 响应，两者都不描述文件传输。
Map<String, String> _filesApiHeaders(Map<String, String> headers) => {
  for (final entry in headers.entries)
    if (entry.key.toLowerCase() != 'content-type' &&
        entry.key.toLowerCase() != 'accept')
      entry.key: entry.value,
};

/// 一个从未到达 API 的附件。它在该轮首个请求之前抛出，所以不会产生任何
/// 计费。它的文本是给用户看的：哪个文件、出了什么问题，都用用户所做的
/// 动作（添加附件）的说法，而不是它本来要去哪里。
class ClaudeFileUploadException implements Exception {
  const ClaudeFileUploadException(this.fileName, this.reason);

  final String fileName;
  final String reason;

  @override
  String toString() => 'Attachment "$fileName" could not be uploaded: $reason';
}

/// 无论扩展名是什么，Windows 都拒绝把下列名字用作文件主名。
final _windowsReservedStem = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
  caseSensitive: false,
);

/// 为 [raw] 生成一个 Files API 与各种本地文件系统都接受的文件名，取不到
/// 时回退到 [fallback]：长度 1–255、不含目录、不含 `<>:"|?*\/` 与控制
/// 字符、结尾没有点和空格、且不是 Windows 设备名。容器起的名字落盘时
/// 要经过这里，用户起的名字上传时同样要经过这里。
String claudeGeneratedFileName(String raw, {String fallback = 'download'}) {
  final base = raw.split(RegExp(r'[\\/]')).last;
  var cleaned = base
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (cleaned.isEmpty) return fallback;
  final dot = cleaned.indexOf('.');
  final stem = dot < 0 ? cleaned : cleaned.substring(0, dot);
  if (_windowsReservedStem.hasMatch(stem)) cleaned = '_$cleaned';
  if (cleaned.length <= 255) return cleaned;
  final lastDot = cleaned.lastIndexOf('.');
  final ext = lastDot > 0 ? cleaned.substring(lastDot) : '';
  return cleaned.substring(0, 255 - ext.length) + ext;
}

/// 通过 Files API 上传 [path] 处的本地文件并返回其 `file_id`，供
/// `container_upload` 块使用。
///
/// 与“下载生成的文件”不同，这里不是可有可无的：这一轮就是围绕这个文件
/// 展开的。因此凡是传不上去的文件 —— 读不到、超过
/// [claudeUploadSizeLimit]、被 API 拒绝 —— 一律抛
/// [ClaudeFileUploadException]，此时调用方还什么都没发出去。
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
        contentType: _mediaTypeOrNull(mime),
      ),
    );
  final http.StreamedResponse response;
  final String body;
  try {
    response = await client.send(request);
    body = await response.stream.bytesToString();
  } catch (e) {
    throw ClaudeFileUploadException(displayName, e.toString());
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw ClaudeFileUploadException(
      displayName,
      'HTTP ${response.statusCode}: ${_apiErrorMessage(body)}',
    );
  }
  final id = _fileIdFrom(body);
  if (id == null) {
    throw ClaudeFileUploadException(displayName, 'the API returned no file id');
  }
  return id;
}

MediaType? _mediaTypeOrNull(String mime) {
  if (mime.trim().isEmpty) return null;
  try {
    return MediaType.parse(mime.trim());
  } catch (_) {
    return null;
  }
}

String? _fileIdFrom(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final id = (decoded['id'] ?? '').toString();
      if (id.isNotEmpty) return id;
    }
  } catch (_) {}
  return null;
}

/// API 自己那句说明哪里出错的话；若不是常见的错误信封，就取请求体里能
/// 塞进一条提示条的那部分。
String _apiErrorMessage(String body) {
  String text = body;
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

/// 一次代码执行结果所报告的全部 `file_id`，按到达顺序。
///
/// 容器运行会把留在 `$OUTPUT_DIR` 里的每个文件，以 id 的形式写进它自己
/// 结果里的 `content` 列表。没有别的服务端工具结果会带这个，所以只看
/// 结构即可判断 —— 不需要去查工具名。
List<String> claudeGeneratedFileIds(Object? output) {
  if (output is! Map) return const <String>[];
  final content = output['content'];
  if (content is! List) return const <String>[];
  return <String>[
    for (final entry in content)
      if (entry is Map) (entry['file_id'] ?? '').toString(),
  ]..removeWhere((id) => id.isEmpty);
}

/// 通过 Files API 取回 [fileId] 并存成本地上传文件；取不到时返回 null。
///
/// Anthropic 返回生成的文件时给的是 id、不是字节，所以模型刚画出来的图表
/// 在下载之前是看不见的。与“丢掉整轮对话”相比，这里的任何失败都只是
/// 外观问题，因此一律不抛异常。
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
    // 只有技能或容器创建的文件才允许下载；问别的会拿到一个 400，
    // 白白多跑一趟。
    if (meta['downloadable'] == false) return null;
    final declaredSize = meta['size_bytes'];
    if (declaredSize is int && declaredSize > claudeGeneratedFileSizeLimit) {
      return null;
    }
    // 文件名由容器给出，所以它可能是个路径、可能是个设备名、也可能什么
    // 都没有；本地文件系统只能接受剩下的那部分。
    final name = claudeGeneratedFileName(
      (meta['filename'] ?? '').toString(),
      fallback: fileId,
    );
    final reported = (meta['mime_type'] ?? '').toString().trim().toLowerCase();
    // 文件名由容器给出，所以它的扩展名更可靠：即使图表是以
    // application/octet-stream 回来的，也仍应作为图片显示在消息里，
    // 而不是当成待下载的附件。
    final mime = reported.startsWith('image/')
        ? reported
        : inferMediaMimeFromSource(name, fallbackMime: reported);

    final dir = await AppDirectories.getUploadDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // 直接以最终文件名写入、并在写入过程中算哈希，因此不论文件多大，
    // 内存占用都是有界的。若已有完全相同的副本，则丢弃这一份、留用旧的。
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
      // 被中断的下载（比如客户端在下载途中关闭）不得把半截文件留在
      // upload 目录里。
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

/// 把 [uri] 的响应体流式写进 [destination]，返回其大小与 SHA-256；响应体
/// 不可用时（请求失败或超过 [claudeGeneratedFileSizeLimit]）返回 null。
/// 空响应体也是一个文件：代码写出的空 CSV 或占位文件，Files API 会报
/// `size_bytes: 0`。
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

/// 接收分块 SHA-256 在收尾时发出的那一个摘要。
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

/// 删除一个不会再有消息引用的已下载文件 —— 即下载完成后才被取消的那一轮。
/// 若下载时发现文件已存在，则它属于最先拥有它的那条消息，保留不动。
Future<void> discardClaudeGeneratedFile(GeneratedFile file) async {
  final path = SandboxPathResolver.resolveForIo(file.uri);
  if (path == null || UploadDedupe.isShared(path)) return;
  await _discard(File(path));
}
