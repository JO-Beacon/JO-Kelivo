import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/business_settings_router.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/asr/asr_service_options.dart';
import 'package:Kelivo/core/services/search/search_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late BusinessRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'display_chat_font_scale_v1': 1.2,
      'flutter_log_enabled_v1': false,
      // A business value in prefs must no longer win over SQLite.
      'theme_mode_v1': 'light',
    });
    database = AppDatabase(NativeDatabase.memory());
    repository = BusinessRepository(database);
    await repository.replaceSnapshot(
      BusinessSettingsRouter.normalizeAndRoute({
        'theme_mode_v1': 'dark',
        'theme_palette_v1': 'ocean',
        'app_launch_count_v1': 4,
        'learning_mode_enabled_v1': true,
        'learning_mode_prompt_v1': 'Learn from the database',
      }),
    );
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'loads business values from SQLite and local-only values from prefs',
    () async {
      final preferences = BusinessPreferences(repository);
      final settings = SettingsProvider(preferences);

      await settings.loaded;

      expect(settings.themeMode, ThemeMode.dark);
      expect(settings.themePaletteId, 'ocean');
      expect(settings.appLaunchCount, 4);
      expect(settings.learningModeEnabled, isTrue);
      expect(settings.learningModePrompt, 'Learn from the database');
      expect(settings.chatFontScale, 1.2);
    },
  );

  test(
    'fresh business storage preserves the built-in search service',
    () async {
      final settings = SettingsProvider(BusinessPreferences(repository));

      await settings.loaded;

      expect(settings.searchServices, <SearchServiceOptions>[
        SearchServiceOptions.defaultOption,
      ]);
      expect(settings.searchServiceSelected, 0);
    },
  );

  test('fresh business storage preselects no built-in models', () async {
    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    expect(settings.getProviderConfig('KelivoIN').models, isEmpty);
    expect(settings.getProviderConfig('SiliconFlow').models, isEmpty);
  });

  test('provider reordering survives a cold reload', () async {
    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    // 只有真实存在的配置才会进入顺序表。
    for (final key in <String>['Gemini', 'OpenAI']) {
      await settings.setProviderConfig(key, settings.getProviderConfig(key));
    }
    await settings.setProvidersOrder(<String>['Gemini', 'OpenAI']);
    expect(settings.providersOrder.take(2), <String>['Gemini', 'OpenAI']);

    final reloaded = SettingsProvider(BusinessPreferences(repository));
    await reloaded.loaded;

    expect(reloaded.providersOrder.take(2), <String>['Gemini', 'OpenAI']);
  });

  test('order-only provider state no longer resurrects providers', () async {
    // 没有配置的顺序项一律丢弃：不再有“内置供应商”这个概念，
    // 启动时也不会再把它们实体化出来。
    const legacyOrder = <String>[
      'Gemini',
      'OpenAI',
      'SiliconFlow',
      'OpenRouter',
      'KelivoIN',
      'Tensdaq',
      'DeepSeek',
      'AIhubmix',
      'Aliyun',
      'Zhipu AI',
      'Claude',
      'Grok',
      'ByteDance',
    ];
    await repository.replaceSnapshot(
      BusinessSettingsRouter.normalizeAndRoute(<String, Object?>{
        'providers_order_v1': <String>[...legacyOrder, '随想AI中转站'],
      }),
    );

    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;
    expect(settings.providersOrder, isEmpty);
    expect(settings.providerConfigs, isEmpty);

    final reloaded = SettingsProvider(BusinessPreferences(repository));
    await reloaded.loaded;
    expect(reloaded.providersOrder, isEmpty);
  });

  test(
    'preserves existing retired provider configs as user providers',
    () async {
      final settings = SettingsProvider(BusinessPreferences(repository));
      await settings.loaded;

      const retiredKey = '随想AI中转站';
      await settings.setProviderConfig(
        retiredKey,
        settings.getProviderConfig(retiredKey),
      );
      await settings.setProvidersOrder([
        ...settings.providersOrder,
        retiredKey,
      ]);

      final reloaded = SettingsProvider(BusinessPreferences(repository));
      await reloaded.loaded;

      expect(reloaded.providerConfigs.containsKey(retiredKey), isTrue);
      expect(reloaded.providersOrder, contains(retiredKey));
    },
  );

  test(
    'persists representative settings and restores them on cold reload',
    () async {
      final settings = SettingsProvider(BusinessPreferences(repository));
      await settings.loaded;

      await settings.setThemeMode(ThemeMode.light);
      await settings.setThemePalette('forest');
      await settings.incrementAppLaunchCount();
      await settings.setLearningModeEnabled(false);
      await settings.setLearningModePrompt('Updated prompt');
      await settings.setChatFontScale(1.35);

      final reloaded = SettingsProvider(BusinessPreferences(repository));
      await reloaded.loaded;

      expect(reloaded.themeMode, ThemeMode.light);
      expect(reloaded.themePaletteId, 'forest');
      expect(reloaded.appLaunchCount, 5);
      expect(reloaded.learningModeEnabled, isFalse);
      expect(reloaded.learningModePrompt, 'Updated prompt');
      expect(reloaded.chatFontScale, 1.35);

      final localPreferences = await SharedPreferences.getInstance();
      expect(localPreferences.getDouble('display_chat_font_scale_v1'), 1.35);
      expect(localPreferences.getString('theme_mode_v1'), 'light');
    },
  );

  test(
    'copyWith keeps the in-memory snapshot without starting another load',
    () async {
      final preferences = BusinessPreferences(repository);
      final settings = SettingsProvider(preferences);
      await settings.loaded;

      await settings.setAsrServices(<AsrServiceOptions>[
        SystemAsrOptions(id: 'copy-system'),
      ]);

      await repository.setPreference('search_enabled_v1', true);
      final copy = settings.copyWith(searchAutoTestOnLaunch: true);
      await copy.loaded;

      expect(copy.searchEnabled, settings.searchEnabled);
      expect(copy.searchAutoTestOnLaunch, isTrue);
      expect(copy.selectedAsrServiceId, 'copy-system');
    },
  );

  test('JO-Kelivo display preferences use their 0.1.5 defaults', () async {
    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    expect(settings.insertNewAssistantAtTop, isFalse);
    expect(settings.wideChatLayout, isFalse);
    // 超长粘贴转文件：本仓库默认**关闭**（产品决定，勿改）。
    // 上游 Kelivo 该项默认开启；本仓库刻意不同，不得按
    // 「与上游分歧默认换成上游」的口径改回去。
    // 断言引用具名常量，改默认值必须同时改常量与这条断言。
    expect(
      settings.longPasteAsFile,
      SettingsProvider.defaultLongPasteAsFileEnabled,
    );
    expect(
      settings.longPasteAsFileThreshold,
      SettingsProvider.defaultLongPasteAsFileThreshold,
    );
  });

  test('JO-Kelivo display preferences persist across a cold reload', () async {
    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    await settings.setInsertNewAssistantAtTop(true);
    await settings.setWideChatLayout(true);

    final reloaded = SettingsProvider(BusinessPreferences(repository));
    await reloaded.loaded;

    expect(reloaded.insertNewAssistantAtTop, isTrue);
    expect(reloaded.wideChatLayout, isTrue);
  });

  test(
    'long paste file conversion setting persists and clamps threshold',
    () async {
      final settings = SettingsProvider(BusinessPreferences(repository));
      await settings.loaded;

      await settings.setLongPasteAsFile(true);
      await settings.setLongPasteAsFileThreshold(0);
      expect(settings.longPasteAsFileThreshold, 1);

      final reloaded = SettingsProvider(BusinessPreferences(repository));
      await reloaded.loaded;
      expect(reloaded.longPasteAsFile, isTrue);
      expect(reloaded.longPasteAsFileThreshold, 1);
    },
  );

  test('wide chat layout falls back to the legacy desktop key', () async {
    await repository.setPreference('display_desktop_wide_chat_layout_v1', true);

    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    expect(settings.wideChatLayout, isTrue);
  });

  test('wide chat layout primary key wins over the legacy key', () async {
    await repository.setPreference('display_wide_chat_layout_v1', false);
    await repository.setPreference('display_desktop_wide_chat_layout_v1', true);

    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    expect(settings.wideChatLayout, isFalse);
  });

  test('ASR is opt-in and persists services with a stable selection', () async {
    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    expect(settings.asrServices, isEmpty);
    expect(settings.selectedAsrService, isNull);

    final system = SystemAsrOptions(id: 'system-asr', localeId: 'zh_CN');
    final openAi = OpenAiRealtimeAsrOptions(
      id: 'openai-asr',
      apiKey: 'test-key',
    );
    await settings.setAsrServices(<AsrServiceOptions>[system, openAi]);
    expect(settings.selectedAsrServiceId, system.id);
    await settings.setSelectedAsrServiceId(openAi.id);

    final reloaded = SettingsProvider(BusinessPreferences(repository));
    await reloaded.loaded;

    expect(reloaded.asrServices, hasLength(2));
    expect(reloaded.selectedAsrServiceId, openAi.id);
    expect(reloaded.selectedAsrService, isA<OpenAiRealtimeAsrOptions>());
    expect(
      (reloaded.selectedAsrService! as OpenAiRealtimeAsrOptions).apiKey,
      'test-key',
    );
  });

  test(
    'removing the selected ASR falls back to the first remaining service',
    () async {
      final settings = SettingsProvider(BusinessPreferences(repository));
      await settings.loaded;
      final first = SystemAsrOptions(id: 'first');
      final second = MimoAsrOptions(id: 'second', apiKey: 'test-key');
      await settings.setAsrServices(<AsrServiceOptions>[first, second]);
      await settings.setSelectedAsrServiceId(second.id);

      await settings.setAsrServices(<AsrServiceOptions>[first]);
      expect(settings.selectedAsrServiceId, first.id);
      await settings.setAsrServices(const <AsrServiceOptions>[]);
      expect(settings.selectedAsrServiceId, isNull);
    },
  );

  test(
    'long paste file conversion stays OFF by default (product decision)',
    () async {
      // ⛔ 防回改用例（2026-09-17 产品明确定：默认关闭是有意为之）。
      //
      // 上游 Kelivo 把这一项默认设为 true（超长粘贴自动转成文件附件），
      // 本仓库刻意保持 false（粘贴的长文本仍直接进入输入框，
      // 由用户主动开启该开关才会转文件）。
      //
      // 这条用例的作用是：任何把默认值改成 true 的改动都会在此失败。
      // 若将来产品决定改为默认开启，应连同本用例一起改，而不是忽略失败。
      expect(SettingsProvider.defaultLongPasteAsFileEnabled, isFalse);

      final settings = SettingsProvider(BusinessPreferences(repository));
      await settings.loaded;

      // 全新偏好（没有任何已存值）时必须落到「关闭」。
      expect(settings.longPasteAsFile, isFalse);
      // 阈值常量本身与上游一致，差异只在默认开关状态。
      expect(
        settings.longPasteAsFileThreshold,
        SettingsProvider.defaultLongPasteAsFileThreshold,
      );
    },
  );

  test('corrupted provider config locks whole-table writes', () async {
    const corrupt = '{ this is not json';
    await repository.setPreference('provider_configs_v1', corrupt);

    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    expect(settings.providerConfigsCorrupted, isTrue);
    expect(settings.providerConfigs, isEmpty);

    // 损坏状态下所有整表写入都必须被拒绝，避免覆盖用户原始数据。
    await settings.setProviderConfig(
      'OpenAI',
      settings.getProviderConfig('OpenAI'),
    );
    await settings.removeProviderConfig('OpenAI');
    await settings.setProvidersOrder(<String>['OpenAI']);

    expect(settings.providerConfigsCorrupted, isTrue);
    expect(await repository.getPreference('provider_configs_v1'), corrupt);
  });

  test('reset provider configs clears corruption and writes back', () async {
    const corrupt = '{ this is not json';
    await repository.setPreference('provider_configs_v1', corrupt);

    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;
    expect(settings.providerConfigsCorrupted, isTrue);

    await settings.resetProviderConfigs();

    expect(settings.providerConfigsCorrupted, isFalse);
    expect(settings.providerConfigs, isEmpty);
    // 重置后重启不应再判定为损坏。
    final reloaded = SettingsProvider(BusinessPreferences(repository));
    await reloaded.loaded;
    expect(reloaded.providerConfigsCorrupted, isFalse);
    expect(reloaded.providerConfigs, isEmpty);
  });

  test('any provider key can be removed, including former built-ins', () async {
    final settings = SettingsProvider(BusinessPreferences(repository));
    await settings.loaded;

    for (final key in <String>['KelivoIN', 'OpenAI', '随想AI中转站']) {
      await settings.setProviderConfig(key, settings.getProviderConfig(key));
    }
    expect(settings.providerConfigs.keys, containsAll(<String>['KelivoIN']));

    await settings.removeProviderConfig('KelivoIN');
    expect(settings.providerConfigs.containsKey('KelivoIN'), isFalse);

    final reloaded = SettingsProvider(BusinessPreferences(repository));
    await reloaded.loaded;
    expect(reloaded.providerConfigs.containsKey('KelivoIN'), isFalse);
    expect(reloaded.providerConfigs.containsKey('OpenAI'), isTrue);
  });
}
