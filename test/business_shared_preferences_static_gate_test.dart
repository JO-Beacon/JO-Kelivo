import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'business SharedPreferences access stays inside the frozen allowlist',
    () async {
      const allowed = <String>{
        'lib/core/database/business_migration_engine.dart',
        'lib/core/providers/hotkey_provider.dart',
        'lib/core/providers/settings_provider.dart',
        // 本机设置随备份流转：导出档位记忆、写回 10 键，两处都直接读写
        // SharedPreferences。
        // 恢复流程（restore_local_settings_applier）不经手：它只按切换时机调度
        // 写回，真正落盘在 device_local_settings_writer，故不单列在此。
        'lib/core/services/backup/device_ledger_export_settings.dart',
        'lib/core/services/backup/device_local_settings_writer.dart',
        'lib/desktop/window_size_manager.dart',
        'lib/features/migration/hive_to_sqlite_migration_service.dart',
        'lib/main.dart',
      };
      final references = <String>[];
      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = _stripComments(await entity.readAsString());
        if (!source.contains('package:shared_preferences/') &&
            !RegExp(r'\bSharedPreferences\b').hasMatch(source)) {
          continue;
        }
        references.add(entity.path.replaceAll('\\', '/'));
      }
      references.sort();

      expect(references, orderedEquals(allowed.toList()..sort()));
    },
  );

  test(
    'discarded chat preference keys only exist in the routing filter',
    () async {
      final references = <String>[];
      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = _stripComments(await entity.readAsString());
        if (!source.contains('pinned_chat_ids') &&
            !source.contains('chat_titles_map')) {
          continue;
        }
        references.add(entity.path.replaceAll('\\', '/'));
      }
      references.sort();

      expect(references, <String>[
        'lib/core/database/business_settings_router.dart',
      ]);
    },
  );
}

/// 去掉 Dart 源码里的注释，只留代码本身。
///
/// 本闸门的判据是“某文件是否引用了某个标识符”，而**注释里的提及不是引用**：
/// `business_settings_router.dart` 只在注释里解释了为什么直写
/// SharedPreferences，就被算成了引用，令白名单校验失败。因此先剥离注释再判断。
///
/// 只剥离整行注释与块注释；行内 `//` 之后的内容原样保留——字符串里可能出现
/// `https://`，一旦按第一个 `//` 截断就会连同其后的真实代码一起丢掉，那会
/// 让引用被漏算，比多算更危险。
String _stripComments(String source) {
  final buffer = StringBuffer();
  var inBlockComment = false;
  for (final line in const LineSplitter().convert(source)) {
    if (inBlockComment) {
      final end = line.indexOf('*/');
      if (end < 0) {
        buffer.writeln();
        continue;
      }
      inBlockComment = false;
      buffer.writeln(line.substring(end + 2));
      continue;
    }

    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) {
      buffer.writeln();
      continue;
    }
    if (trimmed.startsWith('/*')) {
      final end = line.indexOf('*/', line.indexOf('/*') + 2);
      if (end < 0) {
        inBlockComment = true;
        buffer.writeln();
        continue;
      }
      buffer.writeln(line.substring(end + 2));
      continue;
    }

    buffer.writeln(line);
  }
  return buffer.toString();
}
