import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:image_picker/image_picker.dart';
import '../shared/dialogs/file_duplicate_dialog.dart';

class FileImportHelper {
  /// 将文件（由 XFile 表示）复制到目标目录，并处理重名情况。
  ///
  /// 如果存在同名文件：
  /// - 比较文件大小和修改时间。
  /// - 如果完全相同，询问用户是使用现有文件还是作为新副本上传。
  /// - 如果不相同或用户选择新副本，则生成带版本号的文件名（例如 "file(1).ext"）。
  ///
  /// 返回已保存或复用的文件路径；操作失败时返回 null。
  static Future<String?> copyXFile(
    XFile xFile,
    Directory targetDir,
    BuildContext context,
  ) async {
    try {
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      // XFile.name 是首选文件名
      final String originalName = xFile.name.isNotEmpty
          ? xFile.name
          : (xFile.path.isNotEmpty
                ? p.basename(xFile.path)
                : DateTime.now().millisecondsSinceEpoch.toString());

      final File sourceFile = File(xFile.path);
      FileStat? srcStat;
      if (xFile.path.isNotEmpty) {
        try {
          srcStat = await sourceFile.stat();
        } catch (_) {}
      }

      File dest = File(p.join(targetDir.path, originalName));

      if (await dest.exists()) {
        FileStat? destStat;
        try {
          destStat = await dest.stat();
        } catch (_) {}

        final srcModifiedSec = srcStat == null
            ? null
            : (srcStat.modified.millisecondsSinceEpoch ~/ 1000);
        final destModifiedSec = destStat == null
            ? null
            : (destStat.modified.millisecondsSinceEpoch ~/ 1000);

        final sameSize =
            srcStat != null &&
            destStat != null &&
            srcStat.size == destStat.size;
        final sameModified =
            srcModifiedSec != null &&
            destModifiedSec != null &&
            srcModifiedSec == destModifiedSec;

        if (sameSize && sameModified) {
          if (!context.mounted) return null;
          final useExisting = await FileDuplicateDialog.show(
            context,
            originalName,
          );
          if (useExisting) {
            return dest.path;
          }
        }

        // 生成带版本号的文件名
        final base = p.basenameWithoutExtension(originalName);
        final ext = p.extension(originalName);
        var counter = 1;
        String candidate;
        do {
          candidate = p.join(targetDir.path, '$base($counter)$ext');
          counter++;
        } while (await File(candidate).exists());
        dest = File(candidate);
      }

      // 执行复制
      await dest.writeAsBytes(await xFile.readAsBytes());

      // 保留修改时间，以帮助缓存键计算
      if (srcStat != null) {
        try {
          await dest.setLastModified(srcStat.modified);
        } catch (_) {}
      }

      return dest.path;
    } catch (_) {
      return null;
    }
  }
}
