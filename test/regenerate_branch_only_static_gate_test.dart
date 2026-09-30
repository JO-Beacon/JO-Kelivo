import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 消息级分叉模型的产品方向：重新生成永远新建分支，不删除后续消息。
///
/// 上游保留着“重新生成时删除下面的消息”这个设置，基线升级会把它整体带回来。
/// 本门禁按 AGENTS 第 9 节把它钉死：相关标识符与文案不得再次出现，
/// 且重新生成的行为必须保持 `truncateFuture = false`。
void main() {
  test('已作废的“重新生成时删除下面的消息”不得再次出现', () async {
    const forbidden = <String>[
      // 设置键、字段与访问器
      'display_regenerate_delete_trailing_messages_v1',
      'regenerateDeleteTrailingMessages',
      // 设置项文案与“会删除下文”的确认文案
      'displaySettingsPageRegenerateDeleteTrailingMessages',
      'chatMessageWidgetRegenerateConfirmDeleteTrailingContent',
    ];

    final offenders = <String>[];
    await for (final entity in Directory('lib').list(recursive: true)) {
      if (entity is! File) continue;
      final isDart = entity.path.endsWith('.dart');
      final isArb = entity.path.endsWith('.arb');
      if (!isDart && !isArb) continue;
      final source = await entity.readAsString();
      for (final token in forbidden) {
        if (source.contains(token)) {
          offenders.add('${entity.path}: $token');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '重新生成是消息级分叉，不删除后续消息；这些设置与文案已作废，'
          '基线升级把它们带回来时必须在合并后删除。',
    );
  });

  test('重新生成的行为保持不截断后续消息', () async {
    final source = await File(
      'lib/features/home/controllers/chat_actions.dart',
    ).readAsString();
    expect(
      source.contains('const truncateFuture = false;'),
      isTrue,
      reason: '重新生成必须固定走 truncateFuture=false 的分支路径',
    );
  });

  test('四份语言文件都不含已作废的重新生成文案', () async {
    const files = <String>[
      'lib/l10n/app_en.arb',
      'lib/l10n/app_zh.arb',
      'lib/l10n/app_zh_Hans.arb',
      'lib/l10n/app_zh_Hant.arb',
    ];
    for (final path in files) {
      final messages =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      expect(
        messages.containsKey(
          'chatMessageWidgetRegenerateConfirmDeleteTrailingContent',
        ),
        isFalse,
        reason: '$path 不应保留会删除下文的确认文案',
      );
      expect(
        messages.containsKey(
          'displaySettingsPageRegenerateDeleteTrailingMessagesTitle',
        ),
        isFalse,
        reason: '$path 不应保留已作废的设置文案',
      );
    }
  });

  test('重新生成确认文案说的是新建分支，而不是覆盖当前消息', () async {
    // 旧文案写“只会更新当前消息”，与“永远新建分支”的真实行为不符；
    // 这句话曾经被基线升级带回来过，所以逐语言钉住必须出现的措辞。
    const required = <String, List<String>>{
      'lib/l10n/app_en.arb': [
        'new branch',
        'keeps the previous reply',
        'not deleted',
      ],
      'lib/l10n/app_zh.arb': ['新建一条分支', '原来的回复会保留', '不会被删除'],
      'lib/l10n/app_zh_Hans.arb': ['新建一条分支', '原来的回复会保留', '不会被删除'],
      'lib/l10n/app_zh_Hant.arb': ['建立一條分支', '原本的回覆會保留', '不會被刪除'],
    };
    for (final entry in required.entries) {
      final messages =
          jsonDecode(await File(entry.key).readAsString())
              as Map<String, dynamic>;
      final content =
          messages['chatMessageWidgetRegenerateConfirmContent'] as String?;
      expect(content, isNotNull, reason: '${entry.key} 缺少确认文案');
      for (final token in entry.value) {
        expect(
          content,
          contains(token),
          reason: '${entry.key} 的确认文案应含“$token”',
        );
      }
    }
  });

  test('用户可见文案不得再出现“消息版本”这类上游措辞', () async {
    // 上游按“消息版本”组织分叉，本仓库的产品概念是“分支”
    // （见 AGENTS 第 9 节），用户可见文案不得回退到上游措辞。
    // 内部代码注释不在检查范围内：存储层确实按版本存。
    const files = <String>[
      'lib/l10n/app_en.arb',
      'lib/l10n/app_zh.arb',
      'lib/l10n/app_zh_Hans.arb',
      'lib/l10n/app_zh_Hant.arb',
    ];
    const forbidden = <String>[
      '消息版本',
      '訊息版本',
      'message version',
      'message versions',
      'Keep Message Versions When Forking',
      'displaySettingsPageForkKeepMessageVersionsTitle',
    ];
    final offenders = <String>[];
    for (final path in files) {
      final messages =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      for (final entry in messages.entries) {
        final value = entry.value;
        if (value is! String) continue;
        for (final token in forbidden) {
          if (value.contains(token)) {
            offenders.add('$path: ${entry.key} -> $token');
          }
        }
      }
    }
    expect(offenders, isEmpty, reason: '用户可见文案应统一用“分支”；上游的分支语义措辞不得再出现');
  });
}
