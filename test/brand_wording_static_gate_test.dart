import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 品牌文案门禁：用户可见文案里出现 Kelivo，只允许是下面这些**有意提到
/// Kelivo 这个外部应用**的键（兼容备份、致谢、来源说明、搜索服务名）。
///
/// 起因：定时任务有 5 条文案把本应用写成了 Kelivo（其中一条是系统通知正文
/// 「定时任务已到期，打开 Kelivo 继续。」），这类上游文案会随基线升级被带回来，
/// 而它不会被任何功能测试发现。新增合法提及必须在此登记。
void main() {
  const allowed = <String>{
    // 与 Kelivo 互通：导出/导入兼容备份与格式名
    'backupPageExportKelivoBackup',
    'backupPageImportKelivoBackup',
    'backupPageKelivoCompatibleBackup',
    'backupPageKelivoFormat',
    // 关于页：致谢与来源说明
    'aboutPageKelivoSectionTitle',
    'aboutPageAppDescription',
    // 搜索服务提供方名
    'searchServiceNameKelivo',
  };

  const files = <String>[
    'lib/l10n/app_en.arb',
    'lib/l10n/app_zh.arb',
    'lib/l10n/app_zh_Hans.arb',
    'lib/l10n/app_zh_Hant.arb',
  ];

  test('用户可见文案里的 Kelivo 只出现在已登记的位置', () async {
    final offenders = <String>[];
    for (final path in files) {
      final messages =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      for (final entry in messages.entries) {
        final value = entry.value;
        if (value is! String) continue;
        if (!value.contains('Kelivo')) continue;
        if (allowed.contains(entry.key)) continue;
        offenders.add('$path: ${entry.key}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '本应用名为 JO-AIClient；Kelivo 只允许在已登记的位置出现'
          '（兼容备份、致谢、来源说明、搜索服务名）。'
          '若确实需要新增提及，请登记到本测试的白名单。',
    );
  });
}
