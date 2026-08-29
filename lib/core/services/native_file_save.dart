import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

class NativeFileSave {
  static const MethodChannel _channel = MethodChannel('app.file_save');
  static const String joaiclientMimeType =
      'application/vnd.jokelivo.joaiclient';

  @visibleForTesting
  static bool debugForceAndroidForTest = false;

  /// Android 直接创建 SAF 目标并分块写入，避免先生成完整临时副本。
  static Future<bool> saveFileWithWriter({
    required String fileName,
    String mimeType = 'application/zip',
    required Future<void> Function(
      Future<void> Function(Uint8List bytes) writeChunk,
    )
    write,
  }) async {
    if (!Platform.isAndroid && !debugForceAndroidForTest) {
      throw UnsupportedError(
        'Direct writable file destinations are only supported on Android.',
      );
    }
    final result = await _channel.invokeMethod<dynamic>('createWritableFile', {
      'fileName': fileName.trim(),
      'mimeType': mimeType,
    });
    if (result == null) return false;
    if (result != true) {
      throw const FileSystemException('Android did not open a backup target.');
    }
    try {
      await write((bytes) async {
        if (bytes.isEmpty) return;
        await _channel.invokeMethod<void>('writeWritableFileChunk', bytes);
      });
      await _channel.invokeMethod<void>('completeWritableFile');
      return true;
    } catch (_) {
      try {
        await _channel.invokeMethod<void>('abortWritableFile');
      } catch (_) {}
      rethrow;
    }
  }

  static Future<bool> saveFileFromPath({
    required String sourcePath,
    String? fileName,
    String mimeType = 'application/zip',
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS && !debugForceAndroidForTest) {
      throw UnsupportedError(
        'Native file save is only supported on Android and iOS.',
      );
    }

    final result = await _channel.invokeMethod<dynamic>('saveFileFromPath', {
      'sourcePath': sourcePath,
      if (fileName != null && fileName.trim().isNotEmpty)
        'fileName': fileName.trim(),
      'mimeType': mimeType,
    });
    if (result is bool) return result;
    return result == true;
  }
}
