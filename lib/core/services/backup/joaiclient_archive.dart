import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../models/progress_update.dart';
import '../../models/backup_task_progress.dart';

/// JO-AIClient 外部归档的隐式外层容器。
///
/// 第一个版本有意不加密。它仍在固定头部保留保护字段，并在 payload 中保留
/// 空间，以便未来升级时无需引入第二种文件类型。
final class JoaiclientArchive {
  JoaiclientArchive._();

  static const magic = <int>[0x4a, 0x4f, 0x41, 0x49, 0x43, 0x4c, 0x4e, 0x54];
  static const formatVersion = 1;
  static const protectionNone = 0;
  static const payloadZip = 1;
  static const headerLength = 56;

  static Future<File> wrapZipPayload({
    required File zipFile,
    required File outputFile,
    ProgressCallback? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    if (zipFile.absolute.path == outputFile.absolute.path) {
      throw ArgumentError('zipFile and outputFile must differ');
    }
    onProgress?.call(const ProgressUpdate(value: 0));
    final payloadLength = await zipFile.length();
    var hashed = 0;
    final digest = await sha256
        .bind(
          zipFile.openRead().map((chunk) {
            cancelToken?.throwIfCancelled();
            hashed += chunk.length;
            onProgress?.call(
              ProgressUpdate(
                value: payloadLength == 0 ? 0.5 : hashed / payloadLength * 0.5,
              ),
            );
            return chunk;
          }),
        )
        .first;
    final header = _encodeHeader(payloadLength, digest.bytes);
    await outputFile.parent.create(recursive: true);
    final output = outputFile.openWrite(mode: FileMode.write);
    Object? writeError;
    try {
      output.add(header);
      var copied = 0;
      await for (final chunk in zipFile.openRead()) {
        cancelToken?.throwIfCancelled();
        output.add(chunk);
        copied += chunk.length;
        onProgress?.call(
          ProgressUpdate(
            value: payloadLength == 0 ? 1 : 0.5 + copied / payloadLength * 0.5,
          ),
        );
      }
      await output.flush();
    } catch (error) {
      writeError = error;
    } finally {
      await output.close();
    }
    if (writeError != null) {
      await _deleteQuietly(outputFile);
      Error.throwWithStackTrace(writeError, StackTrace.current);
    }
    onProgress?.call(const ProgressUpdate(value: 1));
    return outputFile;
  }

  static Future<bool> isJoaiclient(File file) async {
    final handle = await file.open();
    try {
      final bytes = await handle.read(magic.length);
      return _sameBytes(bytes, magic);
    } finally {
      await handle.close();
    }
  }

  static Future<File> unwrapToZip({
    required File sourceFile,
    required File zipFile,
    ProgressCallback? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    if (sourceFile.absolute.path == zipFile.absolute.path) {
      throw ArgumentError('sourceFile and zipFile must differ');
    }
    onProgress?.call(const ProgressUpdate(value: 0));
    final handle = await sourceFile.open();
    late final _JoaiclientHeader parsed;
    try {
      final header = await handle.read(headerLength);
      parsed = _decodeHeader(header);
      final actualLength = await sourceFile.length();
      if (actualLength != headerLength + parsed.payloadLength) {
        throw const FormatException('joaiclient_payload_length');
      }
      await zipFile.parent.create(recursive: true);
      final output = await zipFile.open(mode: FileMode.write);
      try {
        await handle.setPosition(headerLength);
        var remaining = parsed.payloadLength;
        while (remaining > 0) {
          cancelToken?.throwIfCancelled();
          final chunk = await handle.read(remaining.clamp(1, 1024 * 1024));
          if (chunk.isEmpty) {
            throw const FormatException('joaiclient_payload_truncated');
          }
          await output.writeFrom(chunk);
          remaining -= chunk.length;
          onProgress?.call(
            ProgressUpdate(
              value: parsed.payloadLength == 0
                  ? 0.9
                  : (parsed.payloadLength - remaining) /
                        parsed.payloadLength *
                        0.9,
            ),
          );
        }
        await output.flush();
      } finally {
        await output.close();
      }
    } catch (_) {
      await _deleteQuietly(zipFile);
      rethrow;
    } finally {
      await handle.close();
    }
    var hashed = 0;
    final digest = await sha256
        .bind(
          zipFile.openRead().map((chunk) {
            cancelToken?.throwIfCancelled();
            hashed += chunk.length;
            onProgress?.call(
              ProgressUpdate(
                value: parsed.payloadLength == 0
                    ? 1
                    : 0.9 + hashed / parsed.payloadLength * 0.1,
              ),
            );
            return chunk;
          }),
        )
        .first;
    if (!_sameBytes(digest.bytes, parsed.payloadSha256)) {
      await _deleteQuietly(zipFile);
      throw const FormatException('joaiclient_payload_hash');
    }
    onProgress?.call(const ProgressUpdate(value: 1));
    return zipFile;
  }

  static List<int> _encodeHeader(int payloadLength, List<int> digest) {
    if (digest.length != 32) {
      throw ArgumentError.value(digest.length, 'digest.length');
    }
    final bytes = Uint8List(headerLength);
    bytes.setRange(0, magic.length, magic);
    final data = ByteData.sublistView(bytes);
    data.setUint16(8, formatVersion, Endian.little);
    data.setUint8(10, protectionNone);
    data.setUint8(11, payloadZip);
    data.setUint32(12, headerLength, Endian.little);
    data.setUint64(16, payloadLength, Endian.little);
    bytes.setRange(24, headerLength, digest);
    return bytes;
  }

  static _JoaiclientHeader _decodeHeader(List<int> bytes) {
    if (bytes.length != headerLength) {
      throw const FormatException('joaiclient_header');
    }
    for (var index = 0; index < magic.length; index++) {
      if (bytes[index] != magic[index]) {
        throw const FormatException('joaiclient_magic');
      }
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    if (data.getUint16(8, Endian.little) != formatVersion ||
        data.getUint8(10) != protectionNone ||
        data.getUint8(11) != payloadZip ||
        data.getUint32(12, Endian.little) != headerLength) {
      throw const FormatException('joaiclient_header_version');
    }
    final payloadLength = data.getUint64(16, Endian.little);
    if (payloadLength > 16 * 1024 * 1024 * 1024) {
      throw const FormatException('joaiclient_payload_size');
    }
    return _JoaiclientHeader(
      payloadLength: payloadLength,
      payloadSha256: bytes.sublist(24),
    );
  }

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

final class _JoaiclientHeader {
  const _JoaiclientHeader({
    required this.payloadLength,
    required this.payloadSha256,
  });

  final int payloadLength;
  final List<int> payloadSha256;
}
