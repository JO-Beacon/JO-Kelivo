import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_role_normalizer.dart';

import 'support/business_test_harness.dart';

const _enabledKey = 'claude_first_turn_placeholder_enabled_v1';
const _textKey = 'claude_first_turn_placeholder_text_v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    ClaudeFirstTurnPlaceholderConfig.enabled = false;
    ClaudeFirstTurnPlaceholderConfig.text = claudeFirstTurnPlaceholder;
  });

  test('默认关闭，内容预填默认占位字符', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.claudeFirstTurnPlaceholderEnabled, isFalse);
    expect(settings.claudeFirstTurnPlaceholderText, claudeFirstTurnPlaceholder);
    expect(ClaudeFirstTurnPlaceholderConfig.enabled, isFalse);
    expect(ClaudeFirstTurnPlaceholderConfig.filler, isNull);
  });

  test('打开开关后请求侧开始补位，且落库', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    await settings.setClaudeFirstTurnPlaceholderEnabled(true);

    expect(settings.claudeFirstTurnPlaceholderEnabled, isTrue);
    expect(ClaudeFirstTurnPlaceholderConfig.enabled, isTrue);
    expect(ClaudeFirstTurnPlaceholderConfig.filler, claudeFirstTurnPlaceholder);
    expect(harness.preferences.getBool(_enabledKey), isTrue);
  });

  test('改内容会去空白、压单行并落库', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;
    await settings.setClaudeFirstTurnPlaceholderEnabled(true);

    await settings.setClaudeFirstTurnPlaceholderText('  下\n划  ');

    expect(settings.claudeFirstTurnPlaceholderText, '下 划');
    expect(ClaudeFirstTurnPlaceholderConfig.filler, '下 划');
    expect(harness.preferences.getString(_textKey), '下 划');
  });

  test('只有空白的内容不落库，保留原值', () async {
    final harness = await createBusinessTestHarness();
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    await settings.setClaudeFirstTurnPlaceholderText('   ');

    expect(settings.claudeFirstTurnPlaceholderText, claudeFirstTurnPlaceholder);
    expect(harness.preferences.getString(_textKey), isNull);
  });

  test('启动时读到已保存的开关与内容，空白内容回落默认值', () async {
    final harness = await createBusinessTestHarness(
      initial: const {_enabledKey: true, _textKey: '  #  '},
    );
    final settings = SettingsProvider(harness.preferences);

    await settings.loaded;

    expect(settings.claudeFirstTurnPlaceholderEnabled, isTrue);
    expect(settings.claudeFirstTurnPlaceholderText, '#');
    expect(ClaudeFirstTurnPlaceholderConfig.enabled, isTrue);

    final blank = await createBusinessTestHarness(
      initial: const {_textKey: '   '},
    );
    final blankSettings = SettingsProvider(blank.preferences);

    await blankSettings.loaded;

    expect(
      blankSettings.claudeFirstTurnPlaceholderText,
      claudeFirstTurnPlaceholder,
    );
  });
}
