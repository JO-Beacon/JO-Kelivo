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
        // 本机设置随备份流转：导出档位记忆、写回 10 键、冷重启后补写，
        // 三处都必须直接读写 SharedPreferences。
        'lib/core/services/backup/device_ledger_export_settings.dart',
        'lib/core/services/backup/device_local_settings_writer.dart',
        'lib/core/services/backup/restore_local_settings_applier.dart',
        'lib/desktop/window_size_manager.dart',
        'lib/features/migration/hive_to_sqlite_migration_service.dart',
        'lib/main.dart',
      };
      final references = <String>[];
      await for (final entity in Directory('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = await entity.readAsString();
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
        final source = await entity.readAsString();
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
