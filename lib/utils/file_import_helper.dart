import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import 'upload_dedupe.dart';

class FileImportHelper {
  /// Copies an attachment, reusing byte-identical files with the same name.
  static Future<String?> copyXFile(XFile xFile, Directory targetDir) async {
    try {
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final originalName = xFile.name.isNotEmpty
          ? xFile.name
          : (xFile.path.isNotEmpty
                ? p.basename(xFile.path)
                : DateTime.now().millisecondsSinceEpoch.toString());
      final bytes = await xFile.readAsBytes();
      final existing = await UploadDedupe.findIdentical(
        targetDir,
        bytes,
        originalName,
      );
      if (existing != null) return existing;

      final dest = await UploadDedupe.reserveUniqueFile(
        targetDir,
        originalName,
      );
      try {
        await dest.writeAsBytes(bytes, flush: true);
      } catch (_) {
        try {
          await dest.delete();
        } catch (_) {}
        rethrow;
      }
      return dest.path;
    } catch (_) {
      return null;
    }
  }
}
