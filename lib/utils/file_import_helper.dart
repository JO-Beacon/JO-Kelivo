import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:image_picker/image_picker.dart';
import 'upload_dedupe.dart';

class FileImportHelper {
  /// 把文件（以 XFile 表示）复制到目标目录，并处理重复文件。
  ///
  /// 是否重复按内容判定：目标目录里若已有同名且逐字节相同的文件，
  /// 直接复用该文件，不再存第二份。否则以带版本号的名称写入
  ///（例如 “file(1).ext”），因此同名但内容不同的文件
  /// 绝不会覆盖已有文件。
  ///
  /// 返回保存或复用到的路径；操作失败时返回 null。
  static Future<String?> copyXFile(XFile xFile, Directory targetDir) async {
    try {
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      // 优先使用 XFile.name 作为文件名
      final String originalName = xFile.name.isNotEmpty
          ? xFile.name
          : (xFile.path.isNotEmpty
                ? p.basename(xFile.path)
                : DateTime.now().millisecondsSinceEpoch.toString());

      final staging = await targetDir.createTemp('.import-');
      try {
        // 文件选择、粘贴与桌面拖放都可能带来大体积二进制文件。
        // 复制与重复检测都保持在内存有界的方式下进行。
        final temp = File(p.join(staging.path, 'file'));
        final output = await temp.open(mode: FileMode.write);
        try {
          await for (final chunk in xFile.openRead()) {
            await output.writeFrom(chunk);
          }
        } finally {
          await output.close();
        }
        final digest = await sha256.bind(temp.openRead()).first;
        final existing = await UploadDedupe.findIdenticalDigest(
          targetDir,
          await temp.length(),
          digest.bytes,
          originalName,
        );
        if (existing != null) return existing;
        final dest = await UploadDedupe.reserveUniqueFile(
          targetDir,
          originalName,
        );
        try {
          await temp.rename(dest.path);
        } catch (_) {
          await dest.delete();
          rethrow;
        }
        return dest.path;
      } finally {
        await staging.delete(recursive: true);
      }
    } catch (_) {
      return null;
    }
  }
}
