import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:collection';
import 'dart:io';
import 'package:socks5_proxy/socks_client.dart' as socks;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import '../services/search/search_service.dart';
import '../services/tts/network_tts.dart';
import '../services/tts/tts_text_selection.dart';
import '../services/asr/asr_service_options.dart';
import '../services/network/request_logger.dart';
import '../services/logging/context_logger.dart';
import '../services/logging/flutter_logger.dart';
import '../services/learning_mode_store.dart';
import '../models/api_keys.dart';
import '../models/backup.dart';
import '../models/compress_context_options.dart';
import '../models/provider_group.dart';
import '../services/haptics.dart';
import '../services/screen_wakelock.dart';
import '../../utils/app_directories.dart';
import '../../utils/sandbox_path_resolver.dart';
import '../../utils/avatar_cache.dart';
import '../utils/openai_model_compat.dart';
import '../../utils/provider_grouping_logic.dart';
import '../../utils/brand_assets.dart';
import '../../utils/image_compressor.dart';
import '../database/business_preferences.dart';
import '../services/memory/memory_prompts.dart';
import '../services/memory/memory_trace.dart';
import '../../theme/palettes.dart';
import '../../theme/custom_theme.dart';
import '../../theme/chat_bubble_style.dart';

// 桌面端：话题列表位置
enum DesktopTopicPosition { left, right }

// 桌面端：发送消息快捷键
enum DesktopSendShortcut { enter, ctrlEnter }

// 桌面端：消息导航按钮可见性模式
enum DesktopMessageNavButtonsMode {
  always,
  scroll,
  hover,
  scrollAndHover,
  never,
}

// 移动端：消息导航按钮可见性模式
enum MobileMessageNavButtonsMode { always, scroll, never }

enum ImageUploadQuality { original, high, balanced, saver, custom }

class SettingsProvider extends ChangeNotifier {
  static const String _providersOrderKey = 'providers_order_v1';
  static const String _providerGroupsKey =
      'provider_groups_v1'; // [{id,name,createdAt}]
  static const String _providerGroupMapKey =
      'provider_group_map_v1'; // providerKey -> groupId
  static const String _providerGroupCollapsedKey =
      'provider_group_collapsed_v1'; // groupId|__ungrouped__ -> bool
  static const String _providerUngroupedPositionKey =
      'provider_ungrouped_position_v1'; // 分组之间的显示索引
  static const String providerUngroupedGroupKey = '__ungrouped__';
  static const List<String> _builtInProviderKeysInOrder = [
    'OpenAI',
    'SiliconFlow',
    'Gemini',
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
  static const Set<String> _builtInProviderKeys = {
    ..._builtInProviderKeysInOrder,
  };
  static const String _themeModeKey = 'theme_mode_v1';
  static const String _providerConfigsKey = 'provider_configs_v1';
  static const String _pinnedModelsKey = 'pinned_models_v1';
  static const String _selectedModelKey = 'selected_model_v1';
  static const String _titleModelKey = 'title_model_v1';
  static const String _titlePromptKey = 'title_prompt_v1';
  static const String _ocrModelKey = 'ocr_model_v1';
  static const String _ocrPromptKey = 'ocr_prompt_v1';
  static const String _summaryModelKey = 'summary_model_v1';
  static const String _summaryPromptKey = 'summary_prompt_v1';
  static const String _suggestionModelKey = 'suggestion_model_v1';
  static const String _suggestionPromptKey = 'suggestion_prompt_v1';
  static const String _suggestionInsertOnTapOnlyKey =
      'suggestion_insert_on_tap_only_v1';
  static const String _compressModelKey = 'compress_model_v1';
  static const String _compressPromptKey = 'compress_prompt_v1';
  static const String _compressLimitModeKey = 'compress_limit_mode_v1';
  static const String _compressKeepUserMessagesKey =
      'compress_keep_user_messages_v1';
  static const String _compressMaxCharsKey = 'compress_max_chars_v1';
  static const String _themePaletteKey = 'theme_palette_v1';
  static const String _useDynamicColorKey = 'use_dynamic_color_v1';
  static const String _customThemesKey = 'custom_themes_v1';
  static const String _customThemeSelectedKey = 'custom_theme_selected_v1';
  // 旧版单个自定义调色板键（加载时迁移到 _customThemesKey）
  static const String _legacyCustomSeedColorKey = 'theme_custom_seed_v1';
  static const String _legacyCustomPrimaryOverrideKey =
      'theme_custom_primary_v1';
  static const String _thinkingBudgetKey = 'thinking_budget_v1';
  static const String _titleGenerationThinkingEnabledKey =
      'title_generation_thinking_enabled_v1';
  static const String _summaryGenerationThinkingEnabledKey =
      'summary_generation_thinking_enabled_v1';
  static const String _suggestionGenerationThinkingEnabledKey =
      'suggestion_generation_thinking_enabled_v1';
  static const String _compressGenerationThinkingEnabledKey =
      'compress_generation_thinking_enabled_v1';
  static const String _translateGenerationThinkingEnabledKey =
      'translate_generation_thinking_enabled_v1';
  static const String _ocrGenerationThinkingEnabledKey =
      'ocr_generation_thinking_enabled_v1';
  static const String _memoryModelKey = 'memory_model_v1';
  static const String _memoryModelThinkingEnabledKey =
      'memory_model_thinking_enabled_v1';
  static const String _memoryPromptLangKey = 'memory_prompt_lang_v1';
  static const String _memoryTraceEnabledKey = 'memory_trace_enabled_v1';
  static const String _legacyMemoryModeKey = 'memory_legacy_mode_v1';
  static const String _legacyMemoryPromptZhKey = 'memory_legacy_prompt_zh_v1';
  static const String _legacyMemoryPromptEnKey = 'memory_legacy_prompt_en_v1';
  static const String _memoryRulesPromptZhKey = 'memory_rules_prompt_zh_v1';
  static const String _memoryRulesPromptEnKey = 'memory_rules_prompt_en_v1';
  static const String _memoryGatePromptZhKey = 'memory_gate_prompt_zh_v1';
  static const String _memoryGatePromptEnKey = 'memory_gate_prompt_en_v1';
  static const String _memoryExtractPromptZhKey = 'memory_extract_prompt_zh_v1';
  static const String _memoryExtractPromptEnKey = 'memory_extract_prompt_en_v1';
  static const String _memorySmartAddPromptZhKey =
      'memory_smart_add_prompt_zh_v1';
  static const String _memorySmartAddPromptEnKey =
      'memory_smart_add_prompt_en_v1';
  static const String _memorySmartAddBatchPromptZhKey =
      'memory_smart_add_batch_prompt_zh_v1';
  static const String _memorySmartAddBatchPromptEnKey =
      'memory_smart_add_batch_prompt_en_v1';
  static const String _memoryProfileDistillPromptZhKey =
      'memory_profile_distill_prompt_zh_v1';
  static const String _memoryProfileDistillPromptEnKey =
      'memory_profile_distill_prompt_en_v1';
  static const String _memoryMigratePromptZhKey = 'memory_migrate_prompt_zh_v1';
  static const String _memoryMigratePromptEnKey = 'memory_migrate_prompt_en_v1';
  static const String _memoryMigrationBatchSizeKey =
      'memory_migration_batch_size_v1';
  static const int defaultMemoryMigrationBatchSize = 12;
  static const int minMemoryMigrationBatchSize = 1;
  static const int maxMemoryMigrationBatchSize = 24;
  static const String _memoryInjectionMaxItemsKey =
      'memory_injection_max_items_v1';
  static const int defaultMemoryInjectionMaxItems = 10;
  static const int minMemoryInjectionMaxItems = 1;
  static const int maxMemoryInjectionMaxItems = 100;
  static const String _displayShowUserAvatarKey = 'display_show_user_avatar_v1';
  static const String _displayShowModelIconKey = 'display_show_model_icon_v1';
  static const String _displayShowModelNameTimestampKey =
      'display_show_model_name_timestamp_v1';
  static const String _displayShowTokenStatsKey = 'display_show_token_stats_v1';
  static const String _displayShowUserNameTimestampKey =
      'display_show_user_name_timestamp_v1';
  static const String _displayShowUserNameKey = 'display_show_user_name_v1';
  static const String _displayShowUserTimestampKey =
      'display_show_user_timestamp_v1';
  static const String _displayShowModelNameKey = 'display_show_model_name_v1';
  static const String _displayShowModelTimestampKey =
      'display_show_model_timestamp_v1';
  static const String _displayShowUserMessageActionsKey =
      'display_show_user_message_actions_v1';
  static const String _displayShowThinkingCardsKey =
      'display_show_thinking_cards_v1';
  static const String _displayShowToolCardsKey = 'display_show_tool_cards_v1';
  static const String _displayAutoCollapseThinkingKey =
      'display_auto_collapse_thinking_v1';
  static const String _displayCollapseThinkingStepsKey =
      'display_collapse_thinking_steps_v1';
  static const String _displayShowToolResultSummaryKey =
      'display_show_tool_result_summary_v1';
  static const String _displayHideToolResultImagesKey =
      'display_hide_tool_result_images_v1';
  static const String _displayShowRegenerateConfirmDialogKey =
      'display_show_regenerate_confirm_dialog_v1';
  static const String _displayShowMessageNavKey = 'display_show_message_nav_v1';
  static const String _displayInsertNewAssistantAtTopKey =
      'display_insert_new_assistant_at_top_v1';
  static const String _displayWideChatLayoutKey = 'display_wide_chat_layout_v1';
  static const String _displayDesktopWideChatLayoutLegacyKey =
      'display_desktop_wide_chat_layout_v1';
  static const String _displayDesktopMessageNavButtonsModeKey =
      'display_desktop_message_nav_buttons_mode_v1';
  static const String _displayMobileMessageNavButtonsModeKey =
      'display_mobile_message_nav_buttons_mode_v1';
  static const String _displayUseNewAssistantAvatarUxKey =
      'display_use_new_assistant_avatar_ux_v1';
  static const String _displayShowProviderInModelCapsuleKey =
      'display_show_provider_in_model_capsule_v1';
  static const String _displayShowProviderInChatMessageKey =
      'display_show_provider_in_chat_message_v1';
  static const String _displayHapticsOnGenerateKey =
      'display_haptics_on_generate_v1';
  static const String _displayHapticsOnDrawerKey =
      'display_haptics_on_drawer_v1';
  static const String _displayHapticsGlobalEnabledKey =
      'display_haptics_global_enabled_v1';
  static const String _displayHapticsIosSwitchKey =
      'display_haptics_ios_switch_v1';
  static const String _displayHapticsOnListItemTapKey =
      'display_haptics_on_list_item_tap_v1';
  static const String _displayHapticsOnCardTapKey =
      'display_haptics_on_card_tap_v1';
  static const String _displayKeepScreenOnDuringGenerationKey =
      'display_keep_screen_on_during_generation_v1';
  static const String _displayShowAppUpdatesKey = 'display_show_app_updates_v1';
  static const String _displayKeepSidebarOpenOnAssistantTapKey =
      'display_keep_sidebar_open_on_assistant_tap_v1';
  static const String _displayKeepSidebarOpenOnTopicTapKey =
      'display_keep_sidebar_open_on_topic_tap_v1';
  static const String _displayKeepAssistantListExpandedOnSidebarCloseKey =
      'display_keep_assistant_list_expanded_on_sidebar_close_v1';
  static const String _displayNewChatOnAssistantSwitchKey =
      'display_new_chat_on_assistant_switch_v1';
  static const String _displayNewChatOnLaunchKey =
      'display_new_chat_on_launch_v1';
  static const String _displayNewChatAfterDeleteKey =
      'display_new_chat_after_delete_v1';
  static const String _displayEnterToSendOnMobileKey =
      'display_enter_to_send_on_mobile_v1';
  static const String _displayLongPasteAsFileKey =
      'display_long_paste_as_file_v1';
  static const String _displayLongPasteAsFileThresholdKey =
      'display_long_paste_as_file_threshold_v1';
  static const String _desktopSendShortcutKey = 'desktop_send_shortcut_v1';
  static const String _displayChatFontScaleKey = 'display_chat_font_scale_v1';
  static const String _displayAutoScrollEnabledKey =
      'display_auto_scroll_enabled_v1';
  static const String _displayAutoScrollIdleSecondsKey =
      'display_auto_scroll_idle_seconds_v1';
  static const String _displayChatBackgroundMaskStrengthKey =
      'display_chat_background_mask_strength_v1';
  static const String _displayChatInputBackgroundOpacityLightKey =
      'display_chat_input_background_opacity_light_v1';
  static const String _displayChatInputBackgroundOpacityDarkKey =
      'display_chat_input_background_opacity_dark_v1';
  static const String _displayEnableDollarLatexKey =
      'display_enable_dollar_latex_v1';
  static const String _displayEnableMathRenderingKey =
      'display_enable_math_rendering_v1';
  static const String _displayEnableUserMarkdownKey =
      'display_enable_user_markdown_v1';
  static const String _displayEnableReasoningMarkdownKey =
      'display_enable_reasoning_markdown_v1';
  static const String _displayEnableAssistantMarkdownKey =
      'display_enable_assistant_markdown_v1';
  static const String _displayShowChatListDateKey =
      'display_show_chat_list_date_v1';
  static const String _imageCropperEnabledKey = 'image_cropper_enabled_v1';
  static const String _imageUploadQualityKey = 'image_upload_quality_v1';
  static const String _imageCompressCustomQualityKey =
      'image_compress_custom_quality_v1';
  static const String _imageCompressTransparentEnabledKey =
      'image_compress_transparent_enabled_v1';
  static const String _displayMobileCodeBlockWrapKey =
      'display_mobile_code_block_wrap_v1';
  static const String _displayAutoCollapseCodeBlockKey =
      'display_auto_collapse_code_block_v1';
  static const String _displayAutoCollapseCodeBlockLinesKey =
      'display_auto_collapse_code_block_lines_v1';
  static const String _displayDesktopAutoSwitchTopicsKey =
      'display_desktop_auto_switch_topics_v1';
  static const String _displayDesktopShowTrayKey =
      'display_desktop_show_tray_v1';
  static const String _displayDesktopMinimizeToTrayOnCloseKey =
      'display_desktop_minimize_to_tray_on_close_v1';
  static const String _displayUsePureBackgroundKey =
      'display_use_pure_background_v1';
  static const String _displayChatMessageBackgroundStyleKey =
      'display_chat_message_background_style_v1';
  static const String _chatBubbleStyleOverridesKey =
      'chat_bubble_style_overrides_v1';
  static const String _userChatBubbleStyleOverridesKey =
      'chat_bubble_style_overrides_user_v1';
  static const String _mobileAssistantEditTabOrderKey =
      'mobile_assistant_edit_tab_order_v1';
  static const String _mobileAssistantEditTabHiddenKey =
      'mobile_assistant_edit_tab_hidden_v1';
  static const String _mobileAssistantDetailOutlineEnabledKey =
      'mobile_assistant_detail_outline_enabled_v1';
  // 网络请求日志（调试）
  static const String _requestLogEnabledKey = 'request_log_enabled_v1';
  static const String _contextLogEnabledKey = 'context_log_enabled_v1';
  // Flutter 运行时日志（调试）
  static const String _flutterLogEnabledKey = 'flutter_log_enabled_v1';
  // 日志设置：保存响应输出、自动删除、最大大小
  static const String _logSaveOutputKey = 'log_save_output_v1';
  static const String _logElideLargePayloadsKey = 'log_elide_large_payloads_v1';
  static const String _logAutoDeleteDaysKey = 'log_auto_delete_days_v1';
  static const String _logMaxSizeMBKey = 'log_max_size_mb_v1';
  static const String _appLaunchCountKey = 'app_launch_count_v1';
  // 桌面端话题面板位置 + 右侧边栏展开状态
  static const String _desktopTopicPositionKey = 'desktop_topic_position_v1';
  static const String _desktopRightSidebarOpenKey =
      'desktop_right_sidebar_open_v1';
  // Android 后台聊天生成模式
  static const String _androidBackgroundChatModeKey =
      'android_background_chat_mode_v1';
  // iOS 后台生成设置
  static const String _iosBackgroundGenerationEnabledKey =
      'ios_background_generation_enabled_v1';
  static const String _iosBackgroundTaskRefreshEnabledKey =
      'ios_background_task_refresh_enabled_v1';
  static const String _iosLiveActivityEnabledKey =
      'ios_live_activity_enabled_v1';
  static const String _iosBackgroundNotificationsEnabledKey =
      'ios_background_notifications_enabled_v1';
  // 字体
  static const String _displayAppFontFamilyKey = 'display_app_font_family_v1';
  static const String _displayCodeFontFamilyKey = 'display_code_font_family_v1';
  // 已移除的 Google Fonts 选择器遗留键：只在加载时读取一次，
  // 用于把旧选择回退到系统默认，然后删除。
  static const String _legacyAppFontIsGoogleKey =
      'display_app_font_is_google_v1';
  static const String _legacyCodeFontIsGoogleKey =
      'display_code_font_is_google_v1';
  static const String _displayAppFontLocalPathKey =
      'display_app_font_local_path_v1';
  static const String _displayCodeFontLocalPathKey =
      'display_code_font_local_path_v1';
  static const String _displayAppFontLocalAliasKey =
      'display_app_font_local_alias_v1';
  static const String _displayCodeFontLocalAliasKey =
      'display_code_font_local_alias_v1';
  static const String _appLocaleKey = 'app_locale_v1';
  static const String _translateModelKey = 'translate_model_v1';
  static const String _translatePromptKey = 'translate_prompt_v1';
  static const String _translateTargetLangKey = 'translate_target_lang_v1';
  static const String _ocrEnabledKey = 'ocr_enabled_v1';
  static const String _learningModeEnabledKey = 'learning_mode_enabled_v1';
  static const String _learningModePromptKey = 'learning_mode_prompt_v1';
  static const String _searchServicesKey = 'search_services_v1';
  static const String _searchCommonKey = 'search_common_v1';
  static const String _searchSelectedKey = 'search_selected_v1';
  static const String _searchEnabledKey = 'search_enabled_v1';
  static const String _searchAutoTestOnLaunchKey =
      'search_auto_test_on_launch_v1';
  static const String _webDavConfigKey = 'webdav_config_v1';
  static const String _s3ConfigKey = 's3_config_v1';
  // 全局网络代理
  static const String _globalProxyEnabledKey = 'global_proxy_enabled_v1';
  static const String _globalProxyTypeKey =
      'global_proxy_type_v1'; // http|https|socks5
  static const String _globalProxyHostKey = 'global_proxy_host_v1';
  static const String _globalProxyPortKey = 'global_proxy_port_v1';
  static const String _globalProxyUsernameKey = 'global_proxy_username_v1';
  static const String _globalProxyPasswordKey = 'global_proxy_password_v1';
  static const String _globalProxyBypassKey = 'global_proxy_bypass_v1';
  static const String _defaultGlobalProxyBypassRules =
      'localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,::1';
  // TTS 服务（网络）
  static const String _ttsServicesKey = 'tts_services_v1';
  static const String _ttsSelectedServiceIdKey = 'tts_selected_service_id_v1';
  // 旧版索引键，仅在迁移期间读取一次。
  static const String _ttsSelectedKey = 'tts_selected_v1';
  static const String _ttsAutoPlayAssistantRepliesKey =
      'tts_auto_play_assistant_replies_v1';
  static const String _ttsTextSelectionModeKey = 'tts_text_selection_mode_v1';
  static const String _asrServicesKey = 'asr_services_v1';
  static const String _asrSelectedServiceIdKey = 'asr_selected_service_id_v1';
  // 桌面端 UI
  static const String _desktopSidebarWidthKey = 'desktop_sidebar_width_v1';
  static const String _desktopSidebarOpenKey = 'desktop_sidebar_open_v1';
  static const String _desktopRightSidebarWidthKey =
      'desktop_right_sidebar_width_v1';

  // ===== 网络 TTS 服务 =====
  List<TtsServiceOptions> _ttsServices = const <TtsServiceOptions>[];
  String? _selectedTtsServiceId; // null => 使用系统 TTS
  bool _ttsAutoPlayAssistantReplies = false;
  TtsTextSelectionMode _ttsTextSelectionMode = TtsTextSelectionMode.fullText;
  List<TtsServiceOptions> get ttsServices => _ttsServices;
  String? get selectedTtsServiceId => _selectedTtsServiceId;
  int get ttsServiceSelected {
    final selectedId = _selectedTtsServiceId;
    if (selectedId == null) return -1;
    return _ttsServices.indexWhere((service) => service.id == selectedId);
  }

  bool get usingSystemTts => _selectedTtsServiceId == null;
  bool get ttsAutoPlayAssistantReplies => _ttsAutoPlayAssistantReplies;
  TtsTextSelectionMode get ttsTextSelectionMode => _ttsTextSelectionMode;
  TtsServiceOptions? get selectedTtsService {
    final selectedId = _selectedTtsServiceId;
    if (selectedId == null) return null;
    for (final service in _ttsServices) {
      if (service.id == selectedId) return service;
    }
    return null;
  }

  // ASR 是可选加入的。空列表会刻意保持语音输入隐藏。
  List<AsrServiceOptions> _asrServices = const <AsrServiceOptions>[];
  String? _selectedAsrServiceId;
  List<AsrServiceOptions> get asrServices => _asrServices;
  String? get selectedAsrServiceId => _selectedAsrServiceId;
  AsrServiceOptions? get selectedAsrService {
    final selectedId = _selectedAsrServiceId;
    if (selectedId == null) return null;
    for (final service in _asrServices) {
      if (service.id == selectedId) return service;
    }
    return null;
  }

  List<String> _providersOrder = const [];
  List<String> get providersOrder => _providersOrder;

  // ===== Provider 分组 =====
  List<ProviderGroup> _providerGroups = const <ProviderGroup>[];
  Map<String, String> _providerGroupMap =
      <String, String>{}; // providerKey -> groupId
  final Map<String, bool> _providerGroupCollapsed =
      <String, bool>{}; // groupId|__ungrouped__ -> bool
  int _providerUngroupedPosition = 0;

  List<ProviderGroup> get providerGroups => List.unmodifiable(_providerGroups);
  int get providerUngroupedDisplayIndex =>
      _providerUngroupedPosition.clamp(0, _providerGroups.length);

  ProviderGroup? groupById(String id) {
    for (final g in _providerGroups) {
      if (g.id == id) return g;
    }
    return null;
  }

  String? groupIdForProvider(String providerKey) {
    final gid = _providerGroupMap[providerKey];
    if (gid == null) return null;
    return groupById(gid) == null ? null : gid;
  }

  bool get providerGroupingActive {
    for (final entry in _providerGroupMap.entries) {
      final gid = entry.value;
      if (groupById(gid) != null) return true;
    }
    return false;
  }

  bool isGroupCollapsed(String groupIdOrUngrouped) =>
      _providerGroupCollapsed[groupIdOrUngrouped] ?? false;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;
  // 主题调色板与动态颜色
  String _themePaletteId = 'default';
  String get themePaletteId => _themePaletteId;
  bool _useDynamicColor = true; // 在 Android 上受支持时
  bool get useDynamicColor => _useDynamicColor;
  bool _dynamicColorSupported = false; // 运行时能力，不持久化
  bool get dynamicColorSupported => _dynamicColorSupported;

  // 自定义用户主题（RikkaHub 风格：名称 + 主色/次色/第三色）
  List<CustomTheme> _customThemes = const <CustomTheme>[];
  List<CustomTheme> get customThemes =>
      List<CustomTheme>.unmodifiable(_customThemes);
  String? _selectedCustomThemeId;
  String? get selectedCustomThemeId => _selectedCustomThemeId;
  CustomTheme? get selectedCustomTheme {
    final id = _selectedCustomThemeId;
    if (id == null) return null;
    for (final t in _customThemes) {
      if (t.id == id) return t;
    }
    return null;
  }

  // 启用后，无论主题颜色如何，都强制使用纯白/纯黑背景
  bool _usePureBackground = false;
  bool get usePureBackground => _usePureBackground;

  // 桌面端 UI 持久化状态
  double _desktopSidebarWidth = 240;
  bool _desktopSidebarOpen = true;
  double get desktopSidebarWidth => _desktopSidebarWidth;
  bool get desktopSidebarOpen => _desktopSidebarOpen;
  double _desktopRightSidebarWidth = 300;
  double get desktopRightSidebarWidth => _desktopRightSidebarWidth;

  // 桌面端：话题列表位置（左侧或右侧）和右侧边栏展开状态
  DesktopTopicPosition _desktopTopicPosition = DesktopTopicPosition.left;
  DesktopTopicPosition get desktopTopicPosition => _desktopTopicPosition;
  bool get desktopTopicsOnRight =>
      _desktopTopicPosition == DesktopTopicPosition.right;
  bool _desktopRightSidebarOpen = true;
  bool get desktopRightSidebarOpen => _desktopRightSidebarOpen;

  Map<String, ProviderConfig> _providerConfigs = {};
  Map<String, ProviderConfig> get providerConfigs =>
      Map.unmodifiable(_providerConfigs);
  bool get hasAnyActiveModel =>
      _providerConfigs.values.any((c) => c.enabled && c.models.isNotEmpty);
  // 在缺少配置时为给定键返回配置，而不改变内部状态。
  // 这样可避免在读取路径（例如渲染旧聊天）期间隐式创建 provider。
  ProviderConfig getProviderConfig(String key, {String? defaultName}) {
    final existed = _providerConfigs[key];
    if (existed != null) return existed;
    // 返回一个非持久化的默认构造配置，用于只读场景。
    return ProviderConfig.defaultsFor(key, displayName: defaultName);
  }

  String resolveOpenAIUpstreamModelId(String providerKey, String modelId) {
    final cfg = getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    if (kind != ProviderKind.openai) return modelId;
    final rawOv = cfg.modelOverrides[modelId];
    final ov = rawOv is Map ? rawOv.cast<String, dynamic>() : null;
    return resolveApiModelIdOverride(ov, modelId);
  }

  bool supportsXhighReasoning(String providerKey, String modelId) {
    final cfg = getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    switch (kind) {
      case ProviderKind.openai:
        final modelForCheck = resolveOpenAIUpstreamModelId(
          providerKey,
          modelId,
        );
        return openAISupportsXhighReasoning(modelForCheck);
      case ProviderKind.claude:
        final rawOv = cfg.modelOverrides[modelId];
        final ov = rawOv is Map ? rawOv.cast<String, dynamic>() : null;
        final modelForCheck = resolveApiModelIdOverride(ov, modelId);
        return !_isDeepSeekClaudeCompatible(cfg, modelForCheck) &&
            _claudeSupportsXhighReasoning(modelForCheck);
      case ProviderKind.google:
        return false;
    }
  }

  bool supportsMaxReasoning(String providerKey, String modelId) {
    final cfg = getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    switch (kind) {
      case ProviderKind.openai:
        final modelForCheck = resolveOpenAIUpstreamModelId(
          providerKey,
          modelId,
        );
        return openAISupportsMaxReasoning(modelForCheck);
      case ProviderKind.google:
        return false;
      case ProviderKind.claude:
        final rawOv = cfg.modelOverrides[modelId];
        final ov = rawOv is Map ? rawOv.cast<String, dynamic>() : null;
        final modelForCheck = resolveApiModelIdOverride(ov, modelId);
        return _isDeepSeekClaudeCompatible(cfg, modelForCheck) ||
            _claudeSupportsMaxReasoning(modelForCheck);
    }
  }

  bool supportsOpenAIXhighReasoning(String providerKey, String modelId) {
    return supportsXhighReasoning(providerKey, modelId);
  }

  bool _claudeSupportsXhighReasoning(String modelId) {
    final lower = modelId.trim().toLowerCase();
    if (!lower.contains('claude-')) return false;
    if (lower.contains('fable') || lower.contains('mythos')) return true;
    if (RegExp(
      r'claude-(?:opus|sonnet)-5(?:$|[._:@/-])',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return true;
    }
    final m = RegExp(
      r'claude-(opus|sonnet)-(\d+)[-.](\d+)',
      caseSensitive: false,
    ).firstMatch(lower);
    if (m == null) {
      return lower.contains('claude-opus-4-7') ||
          lower.contains('claude-opus-4.7') ||
          lower.contains('claude-opus-4-8') ||
          lower.contains('claude-opus-4.8');
    }
    final family = (m.group(1) ?? '').toLowerCase();
    final major = int.tryParse(m.group(2) ?? '');
    final minor = int.tryParse(m.group(3) ?? '');
    if (major == null || minor == null) return false;
    if (family == 'opus' && (major > 4 || (major == 4 && minor >= 7))) {
      return true;
    }
    return false;
  }

  bool _claudeSupportsMaxReasoning(String modelId) {
    final lower = modelId.trim().toLowerCase();
    if (!lower.contains('claude-')) return false;
    if (lower.contains('fable') || lower.contains('mythos')) return true;
    if (RegExp(
      r'claude-(?:opus|sonnet)-5(?:$|[._:@/-])',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return true;
    }
    final m = RegExp(
      r'claude-(opus|sonnet)-(\d+)[-.](\d+)',
      caseSensitive: false,
    ).firstMatch(lower);
    if (m == null) {
      return lower.contains('claude-opus-4-7') ||
          lower.contains('claude-opus-4.7') ||
          lower.contains('claude-opus-4-8') ||
          lower.contains('claude-opus-4.8') ||
          lower.contains('claude-opus-4-6') ||
          lower.contains('claude-opus-4.6') ||
          lower.contains('claude-sonnet-4-6') ||
          lower.contains('claude-sonnet-4.6');
    }
    final family = (m.group(1) ?? '').toLowerCase();
    final major = int.tryParse(m.group(2) ?? '');
    final minor = int.tryParse(m.group(3) ?? '');
    if (major == null || minor == null) return false;
    if (family == 'opus' && (major > 4 || (major == 4 && minor >= 7))) {
      return true;
    }
    if (major == 4 && minor == 6) return true;
    return false;
  }

  bool _isDeepSeekClaudeCompatible(ProviderConfig cfg, String modelId) {
    final lowerModelId = modelId.trim().toLowerCase();
    if (lowerModelId.contains('deepseek')) return true;
    final baseUrl = cfg.baseUrl.trim().toLowerCase();
    final providerId = cfg.id.trim().toLowerCase();
    final providerName = cfg.name.trim().toLowerCase();
    return baseUrl.contains('api.deepseek.com') ||
        providerId.contains('deepseek') ||
        providerName.contains('deepseek');
  }

  // 显式确保内存中存在一个提供者配置（不持久化到存储）。
  // 用于初始化首次运行的默认值。
  ProviderConfig ensureProviderConfig(String key, {String? defaultName}) {
    final existed = _providerConfigs[key];
    if (existed != null) return existed;
    final cfg = ProviderConfig.defaultsFor(key, displayName: defaultName);
    _providerConfigs[key] = cfg;
    return cfg;
  }

  // 搜索服务设置
  List<SearchServiceOptions> _searchServices = [
    SearchServiceOptions.defaultOption,
  ];
  List<SearchServiceOptions> get searchServices =>
      List.unmodifiable(_searchServices);
  SearchCommonOptions _searchCommonOptions = const SearchCommonOptions();
  SearchCommonOptions get searchCommonOptions => _searchCommonOptions;
  int _searchServiceSelected = 0;
  int get searchServiceSelected => _searchServiceSelected;
  bool _searchEnabled = false;
  bool get searchEnabled => _searchEnabled;
  bool _searchAutoTestOnLaunch = false;
  bool get searchAutoTestOnLaunch => _searchAutoTestOnLaunch;
  // 临时连接测试结果：serviceId -> 已连接（true）、失败（false）或 null（未测试）
  final Map<String, bool?> _searchConnection = <String, bool?>{};
  Map<String, bool?> get searchConnection =>
      Map.unmodifiable(_searchConnection);

  // ===== 全局代理设置 =====
  bool _globalProxyEnabled = false;
  String _globalProxyType = 'http';
  String _globalProxyHost = '';
  String _globalProxyPort = '8080';
  String _globalProxyUsername = '';
  String _globalProxyPassword = '';
  String _globalProxyBypass = _defaultGlobalProxyBypassRules;

  bool get globalProxyEnabled => _globalProxyEnabled;
  String get globalProxyType => _globalProxyType; // http|https|socks5
  String get globalProxyHost => _globalProxyHost;
  String get globalProxyPort => _globalProxyPort;
  String get globalProxyUsername => _globalProxyUsername;
  String get globalProxyPassword => _globalProxyPassword;
  String get globalProxyBypass => _globalProxyBypass;

  int _appLaunchCount = 0;
  int get appLaunchCount => _appLaunchCount;

  SettingsProvider(this._preferences) {
    _appLocaleTag = _readAppLocaleTag(_preferences);
    _loaded = _load();
  }

  SettingsProvider._withoutLoad(this._preferences)
    : _loaded = Future<void>.value();

  final BusinessPreferences _preferences;
  late final Future<void> _loaded;
  Future<void> get loaded => _loaded;

  Future<void> _load() async {
    final prefs = _preferences;
    await prefs.load();
    final localPreferences = await SharedPreferences.getInstance();
    _providersOrder = prefs.getStringList(_providersOrderKey) ?? [];
    final m = prefs.getString(_themeModeKey);
    switch (m) {
      case 'light':
        _themeMode = ThemeMode.light;
        break;
      case 'dark':
        _themeMode = ThemeMode.dark;
        break;
      default:
        _themeMode = ThemeMode.system;
    }
    _themePaletteId = prefs.getString(_themePaletteKey) ?? 'default';
    _useDynamicColor = prefs.getBool(_useDynamicColorKey) ?? true;
    _loadCustomThemes(prefs);
    final cfgStr = prefs.getString(_providerConfigsKey);
    if (cfgStr != null && cfgStr.isNotEmpty) {
      try {
        final raw = jsonDecode(cfgStr) as Map<String, dynamic>;
        _providerConfigs = raw.map(
          (k, v) =>
              MapEntry(k, ProviderConfig.fromJson(v as Map<String, dynamic>)),
        );
      } catch (e, st) {
        assert(() {
          debugPrint('[SettingsProvider] providerConfigs decode failed: $e');
          debugPrint('$st');
          return true;
        }());
      }
    }

    // 加载提供者分组
    try {
      final groupsStr = prefs.getString(_providerGroupsKey) ?? '';
      _providerGroups = groupsStr.isEmpty
          ? const <ProviderGroup>[]
          : ProviderGroup.decodeList(groupsStr);
    } catch (_) {
      _providerGroups = const <ProviderGroup>[];
    }
    try {
      final mapStr = prefs.getString(_providerGroupMapKey) ?? '';
      if (mapStr.isNotEmpty) {
        final raw = jsonDecode(mapStr) as Map<String, dynamic>;
        _providerGroupMap = raw.map((k, v) => MapEntry(k, v.toString()));
      } else {
        _providerGroupMap = <String, String>{};
      }
    } catch (_) {
      _providerGroupMap = <String, String>{};
    }
    try {
      final collapsedStr = prefs.getString(_providerGroupCollapsedKey) ?? '';
      if (collapsedStr.isNotEmpty) {
        final raw = jsonDecode(collapsedStr) as Map<String, dynamic>;
        _providerGroupCollapsed
          ..clear()
          ..addAll(
            raw.map(
              (k, v) => MapEntry(k, (v is bool) ? v : (v.toString() == 'true')),
            ),
          );
      } else {
        _providerGroupCollapsed.clear();
      }
    } catch (_) {
      _providerGroupCollapsed.clear();
    }
    _providerUngroupedPosition =
        prefs.getInt(_providerUngroupedPositionKey) ?? _providerGroups.length;
    // 加载固定模型
    final pinned = prefs.getStringList(_pinnedModelsKey) ?? const <String>[];
    _pinnedModels
      ..clear()
      ..addAll(pinned);

    // 加载选中的模型
    final sel = prefs.getString(_selectedModelKey);
    if (sel != null && sel.contains('::')) {
      final parts = sel.split('::');
      if (parts.length >= 2) {
        _currentModelProvider = parts[0];
        _currentModelId = parts.sublist(1).join('::');
      }
    }
    // 加载标题模型
    final titleSel = prefs.getString(_titleModelKey);
    if (titleSel != null && titleSel.contains('::')) {
      final parts = titleSel.split('::');
      if (parts.length >= 2) {
        _titleModelProvider = parts[0];
        _titleModelId = parts.sublist(1).join('::');
      }
    }
    // 加载标题提示词
    final tp = prefs.getString(_titlePromptKey);
    _titlePrompt = (tp == null || tp.trim().isEmpty) ? defaultTitlePrompt : tp;
    // 加载翻译模型
    final translateSel = prefs.getString(_translateModelKey);
    if (translateSel != null && translateSel.contains('::')) {
      final parts = translateSel.split('::');
      if (parts.length >= 2) {
        _translateModelProvider = parts[0];
        _translateModelId = parts.sublist(1).join('::');
      }
    }
    // 加载翻译提示词
    final transp = prefs.getString(_translatePromptKey);
    _translatePrompt = (transp == null || transp.trim().isEmpty)
        ? defaultTranslatePrompt
        : transp;
    // 加载翻译目标语言
    final targetLang = prefs.getString(_translateTargetLangKey);
    if (targetLang != null && targetLang.trim().isNotEmpty) {
      _translateTargetLang = targetLang.trim();
    }
    // 加载 OCR 模型
    final ocrSel = prefs.getString(_ocrModelKey);
    if (ocrSel != null && ocrSel.contains('::')) {
      final parts = ocrSel.split('::');
      if (parts.length >= 2) {
        _ocrModelProvider = parts[0];
        _ocrModelId = parts.sublist(1).join('::');
      }
    }
    // 加载 OCR 提示词（null 表示默认值，空字符串表示明确清空）
    final ocrp = prefs.getString(_ocrPromptKey);
    _ocrPrompt = ocrp ?? defaultOcrPrompt;
    // 加载 OCR 启用状态（仅在已配置模型时生效）
    _ocrEnabled = prefs.getBool(_ocrEnabledKey) ?? false;
    if (_ocrModelProvider == null || _ocrModelId == null) {
      _ocrEnabled = false;
    }
    // 加载摘要模型
    final summarySel = prefs.getString(_summaryModelKey);
    if (summarySel != null && summarySel.contains('::')) {
      final parts = summarySel.split('::');
      if (parts.length >= 2) {
        _summaryModelProvider = parts[0];
        _summaryModelId = parts.sublist(1).join('::');
      }
    }
    // 加载摘要提示词
    final summaryp = prefs.getString(_summaryPromptKey);
    _summaryPrompt = (summaryp == null || summaryp.trim().isEmpty)
        ? defaultSummaryPrompt
        : summaryp;
    // 加载聊天建议模型
    final suggestionSel = prefs.getString(_suggestionModelKey);
    if (suggestionSel != null && suggestionSel.contains('::')) {
      final parts = suggestionSel.split('::');
      if (parts.length >= 2) {
        _suggestionModelProvider = parts[0];
        _suggestionModelId = parts.sublist(1).join('::');
      }
    }
    // 加载聊天建议提示词
    final suggestionp = prefs.getString(_suggestionPromptKey);
    _suggestionPrompt = (suggestionp == null || suggestionp.trim().isEmpty)
        ? defaultSuggestionPrompt
        : suggestionp;
    _insertSuggestionOnTapOnly =
        prefs.getBool(_suggestionInsertOnTapOnlyKey) ?? false;
    // 加载压缩模型
    final compressSel = prefs.getString(_compressModelKey);
    if (compressSel != null && compressSel.contains('::')) {
      final parts = compressSel.split('::');
      if (parts.length >= 2) {
        _compressModelProvider = parts[0];
        _compressModelId = parts.sublist(1).join('::');
      }
    }
    // 加载压缩提示词
    final compressp = prefs.getString(_compressPromptKey);
    _compressPrompt = (compressp == null || compressp.trim().isEmpty)
        ? defaultCompressPrompt
        : compressp;
    final compressModeName = prefs.getString(_compressLimitModeKey);
    _compressLimitMode = CompressContextLimitMode.values.firstWhere(
      (mode) => mode.name == compressModeName,
      orElse: () => CompressContextLimitMode.start,
    );
    _compressKeepUserMessages = prefs.getInt(_compressKeepUserMessagesKey);
    _compressMaxChars =
        prefs.getInt(_compressMaxCharsKey) ??
        CompressContextOptions.defaultMaxChars;
    // 学习模式
    _learningModeEnabled = prefs.getBool(_learningModeEnabledKey) ?? false;
    final lmp = prefs.getString(_learningModePromptKey);
    _learningModePrompt = (lmp == null || lmp.trim().isEmpty)
        ? defaultLearningModePrompt
        : lmp;
    // 加载思考预算（推理强度）
    _thinkingBudget = prefs.getInt(_thinkingBudgetKey);
    _titleGenerationThinkingEnabled =
        prefs.getBool(_titleGenerationThinkingEnabledKey) ?? false;
    _summaryGenerationThinkingEnabled =
        prefs.getBool(_summaryGenerationThinkingEnabledKey) ?? false;
    _suggestionGenerationThinkingEnabled =
        prefs.getBool(_suggestionGenerationThinkingEnabledKey) ?? false;
    _compressGenerationThinkingEnabled =
        prefs.getBool(_compressGenerationThinkingEnabledKey) ?? false;
    _translateGenerationThinkingEnabled =
        prefs.getBool(_translateGenerationThinkingEnabledKey) ?? false;
    _ocrGenerationThinkingEnabled =
        prefs.getBool(_ocrGenerationThinkingEnabledKey) ?? false;

    // 记忆系统 v1（§4.2）
    final memorySel = prefs.getString(_memoryModelKey);
    if (memorySel != null && memorySel.contains('::')) {
      final parts = memorySel.split('::');
      if (parts.length >= 2) {
        _memoryModelProvider = parts[0];
        _memoryModelId = parts.sublist(1).join('::');
      }
    }
    _memoryModelThinkingEnabled =
        prefs.getBool(_memoryModelThinkingEnabledKey) ?? false;
    final memoryLang = prefs.getString(_memoryPromptLangKey);
    _memoryPromptLang = (memoryLang == 'zh' || memoryLang == 'en')
        ? memoryLang!
        : 'auto';
    _memoryTraceEnabled = prefs.getBool(_memoryTraceEnabledKey) ?? true;
    MemoryTraceRecorder.instance.setEnabled(_memoryTraceEnabled);
    _legacyMemoryMode = prefs.getBool(_legacyMemoryModeKey) ?? false;
    _legacyMemoryPromptZh = _nonEmptyOr(
      prefs.getString(_legacyMemoryPromptZhKey),
      MemoryPrompts.legacyRulesZh,
    );
    _legacyMemoryPromptEn = _nonEmptyOr(
      prefs.getString(_legacyMemoryPromptEnKey),
      MemoryPrompts.legacyRulesEn,
    );
    _memoryRulesPromptZh = _nonEmptyOr(
      prefs.getString(_memoryRulesPromptZhKey),
      MemoryPrompts.rulesZh,
    );
    _memoryRulesPromptEn = _nonEmptyOr(
      prefs.getString(_memoryRulesPromptEnKey),
      MemoryPrompts.rulesEn,
    );
    _memoryGatePromptZh = _nonEmptyOr(
      prefs.getString(_memoryGatePromptZhKey),
      MemoryPrompts.gateZh,
    );
    _memoryGatePromptEn = _nonEmptyOr(
      prefs.getString(_memoryGatePromptEnKey),
      MemoryPrompts.gateEn,
    );

    _memoryExtractPromptZh = _nonEmptyOr(
      prefs.getString(_memoryExtractPromptZhKey),
      MemoryPrompts.extractZh,
    );
    _memoryExtractPromptEn = _nonEmptyOr(
      prefs.getString(_memoryExtractPromptEnKey),
      MemoryPrompts.extractEn,
    );
    _memorySmartAddPromptZh = _nonEmptyOr(
      prefs.getString(_memorySmartAddPromptZhKey),
      MemoryPrompts.smartAddZh,
    );
    _memorySmartAddPromptEn = _nonEmptyOr(
      prefs.getString(_memorySmartAddPromptEnKey),
      MemoryPrompts.smartAddEn,
    );
    _memorySmartAddBatchPromptZh = _nonEmptyOr(
      prefs.getString(_memorySmartAddBatchPromptZhKey),
      MemoryPrompts.smartAddBatchZh,
    );
    _memorySmartAddBatchPromptEn = _nonEmptyOr(
      prefs.getString(_memorySmartAddBatchPromptEnKey),
      MemoryPrompts.smartAddBatchEn,
    );
    _memoryProfileDistillPromptZh = _nonEmptyOr(
      prefs.getString(_memoryProfileDistillPromptZhKey),
      MemoryPrompts.profileDistillZh,
    );
    _memoryProfileDistillPromptEn = _nonEmptyOr(
      prefs.getString(_memoryProfileDistillPromptEnKey),
      MemoryPrompts.profileDistillEn,
    );
    _memoryMigratePromptZh = _nonEmptyOr(
      prefs.getString(_memoryMigratePromptZhKey),
      MemoryPrompts.migrateZh,
    );
    _memoryMigratePromptEn = _nonEmptyOr(
      prefs.getString(_memoryMigratePromptEnKey),
      MemoryPrompts.migrateEn,
    );
    _memoryMigrationBatchSize =
        (prefs.getInt(_memoryMigrationBatchSizeKey) ??
                defaultMemoryMigrationBatchSize)
            .clamp(minMemoryMigrationBatchSize, maxMemoryMigrationBatchSize);
    _memoryInjectionMaxItems =
        (prefs.getInt(_memoryInjectionMaxItemsKey) ??
                defaultMemoryInjectionMaxItems)
            .clamp(minMemoryInjectionMaxItems, maxMemoryInjectionMaxItems);

    // 显示设置
    _showUserAvatar = prefs.getBool(_displayShowUserAvatarKey) ?? true;
    _showModelIcon = prefs.getBool(_displayShowModelIconKey) ?? true;
    _showModelNameTimestamp =
        prefs.getBool(_displayShowModelNameTimestampKey) ?? true;
    _showTokenStats = prefs.getBool(_displayShowTokenStatsKey) ?? true;
    _showUserNameTimestamp =
        prefs.getBool(_displayShowUserNameTimestampKey) ?? true;
    // 新的拆分设置：为向后兼容，默认使用旧版合并设置的值
    final legacyUserNameTs = _showUserNameTimestamp;
    _showUserName = prefs.getBool(_displayShowUserNameKey) ?? legacyUserNameTs;
    _showUserTimestamp =
        prefs.getBool(_displayShowUserTimestampKey) ?? legacyUserNameTs;
    final legacyModelNameTs = _showModelNameTimestamp;
    _showModelName =
        prefs.getBool(_displayShowModelNameKey) ?? legacyModelNameTs;
    _showModelTimestamp =
        prefs.getBool(_displayShowModelTimestampKey) ?? legacyModelNameTs;
    _showUserMessageActions =
        prefs.getBool(_displayShowUserMessageActionsKey) ?? true;
    _showThinkingCards = prefs.getBool(_displayShowThinkingCardsKey) ?? true;
    _showToolCards = prefs.getBool(_displayShowToolCardsKey) ?? true;
    _autoCollapseThinking =
        prefs.getBool(_displayAutoCollapseThinkingKey) ?? true;
    _collapseThinkingSteps =
        prefs.getBool(_displayCollapseThinkingStepsKey) ?? false;
    _showToolResultSummary =
        prefs.getBool(_displayShowToolResultSummaryKey) ?? false;
    _hideToolResultImages =
        prefs.getBool(_displayHideToolResultImagesKey) ?? false;
    _showRegenerateConfirmDialog =
        prefs.getBool(_displayShowRegenerateConfirmDialogKey) ?? true;
    _showMessageNavButtons = prefs.getBool(_displayShowMessageNavKey) ?? true;
    _mobileMessageNavButtonsMode = _parseMobileMessageNavButtonsMode(
      prefs.getString(_displayMobileMessageNavButtonsModeKey),
      legacyEnabled: _showMessageNavButtons,
    );
    _desktopMessageNavButtonsMode = _parseDesktopMessageNavButtonsMode(
      prefs.getString(_displayDesktopMessageNavButtonsModeKey),
      legacyEnabled: _showMessageNavButtons,
    );
    _useNewAssistantAvatarUx =
        prefs.getBool(_displayUseNewAssistantAvatarUxKey) ?? false;
    _showProviderInModelCapsule =
        prefs.getBool(_displayShowProviderInModelCapsuleKey) ?? true;
    _showProviderInChatMessage =
        prefs.getBool(_displayShowProviderInChatMessageKey) ?? false;
    _hapticsOnGenerate = prefs.getBool(_displayHapticsOnGenerateKey) ?? false;
    _hapticsOnDrawer = prefs.getBool(_displayHapticsOnDrawerKey) ?? true;
    _hapticsGlobalEnabled =
        prefs.getBool(_displayHapticsGlobalEnabledKey) ?? true;
    _hapticsIosSwitch = prefs.getBool(_displayHapticsIosSwitchKey) ?? true;
    _hapticsOnListItemTap =
        prefs.getBool(_displayHapticsOnListItemTapKey) ?? true;
    _hapticsOnCardTap = prefs.getBool(_displayHapticsOnCardTapKey) ?? true;
    // 将全局触觉反馈应用到服务层
    Haptics.setEnabled(_hapticsGlobalEnabled);
    _keepScreenOnDuringGeneration =
        prefs.getBool(_displayKeepScreenOnDuringGenerationKey) ?? false;
    ScreenWakelock.setEnabled(_keepScreenOnDuringGeneration);
    _showAppUpdates = prefs.getBool(_displayShowAppUpdatesKey) ?? true;
    _keepSidebarOpenOnAssistantTap =
        prefs.getBool(_displayKeepSidebarOpenOnAssistantTapKey) ?? false;
    _keepSidebarOpenOnTopicTap =
        prefs.getBool(_displayKeepSidebarOpenOnTopicTapKey) ?? false;
    _keepAssistantListExpandedOnSidebarClose =
        prefs.getBool(_displayKeepAssistantListExpandedOnSidebarCloseKey) ??
        false;
    _requestLogEnabled = prefs.getBool(_requestLogEnabledKey) ?? true;
    await RequestLogger.setEnabled(_requestLogEnabled);
    _contextLogEnabled = prefs.getBool(_contextLogEnabledKey) ?? true;
    await ContextLogger.setEnabled(_contextLogEnabled);
    _flutterLogEnabled =
        localPreferences.getBool(_flutterLogEnabledKey) ?? false;
    await FlutterLogger.setEnabled(_flutterLogEnabled);
    _logSaveOutput = prefs.getBool(_logSaveOutputKey) ?? false;
    RequestLogger.saveOutput = _logSaveOutput;
    _logElideLargePayloads = prefs.getBool(_logElideLargePayloadsKey) ?? true;
    RequestLogger.elideLargePayloads = _logElideLargePayloads;
    _logAutoDeleteDays = prefs.getInt(_logAutoDeleteDaysKey) ?? 0;
    _logMaxSizeMB = prefs.getInt(_logMaxSizeMBKey) ?? 50;
    _appLaunchCount = prefs.getInt(_appLaunchCountKey) ?? 0;
    // 根据当前设置执行日志清理
    RequestLogger.cleanupLogs(
      autoDeleteDays: _logAutoDeleteDays,
      maxSizeMB: _logMaxSizeMB,
    );
    _newChatOnLaunch = prefs.getBool(_displayNewChatOnLaunchKey) ?? false;
    _newChatOnAssistantSwitch =
        prefs.getBool(_displayNewChatOnAssistantSwitchKey) ?? false;
    _insertNewAssistantAtTop =
        prefs.getBool(_displayInsertNewAssistantAtTopKey) ?? false;
    _wideChatLayout =
        prefs.getBool(_displayWideChatLayoutKey) ??
        prefs.getBool(_displayDesktopWideChatLayoutLegacyKey) ??
        false;
    _newChatAfterDelete = prefs.getBool(_displayNewChatAfterDeleteKey) ?? false;
    // 移动端按回车发送：iOS 默认开启，Android 默认关闭
    final enterToSendPref = prefs.getBool(_displayEnterToSendOnMobileKey);
    if (enterToSendPref == null) {
      _enterToSendOnMobile = Platform.isIOS;
      await prefs.setBool(_displayEnterToSendOnMobileKey, _enterToSendOnMobile);
    } else {
      _enterToSendOnMobile = enterToSendPref;
    }
    _longPasteAsFile = prefs.getBool(_displayLongPasteAsFileKey) ?? false;
    _longPasteAsFileThreshold =
        (prefs.getInt(_displayLongPasteAsFileThresholdKey) ??
                defaultLongPasteAsFileThreshold)
            .clamp(minLongPasteAsFileThreshold, maxLongPasteAsFileThreshold);
    // 桌面发送快捷键：Enter（默认）或 Ctrl/Cmd+Enter
    final sendShortcutStr = prefs.getString(_desktopSendShortcutKey);
    switch (sendShortcutStr) {
      case 'ctrlEnter':
        _desktopSendShortcut = DesktopSendShortcut.ctrlEnter;
        break;
      case 'enter':
      default:
        _desktopSendShortcut = DesktopSendShortcut.enter;
    }
    _chatFontScale =
        localPreferences.getDouble(_displayChatFontScaleKey) ?? 1.0;
    _autoScrollEnabled = prefs.getBool(_displayAutoScrollEnabledKey) ?? true;
    _autoScrollIdleSeconds =
        prefs.getInt(_displayAutoScrollIdleSecondsKey) ?? 8;
    _chatBackgroundMaskStrength =
        prefs.getDouble(_displayChatBackgroundMaskStrengthKey) ?? 1.0;
    _chatInputBackgroundOpacityLight =
        (prefs.getDouble(_displayChatInputBackgroundOpacityLightKey) ??
                defaultChatInputBackgroundOpacityLight)
            .clamp(0.0, 1.0);
    _chatInputBackgroundOpacityDark =
        (prefs.getDouble(_displayChatInputBackgroundOpacityDarkKey) ??
                defaultChatInputBackgroundOpacityDark)
            .clamp(0.0, 1.0);
    final pureBgPref = prefs.getBool(_displayUsePureBackgroundKey);
    if (pureBgPref == null) {
      final isDesktop =
          Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      _usePureBackground = isDesktop;
      await prefs.setBool(_displayUsePureBackgroundKey, _usePureBackground);
    } else {
      _usePureBackground = pureBgPref;
    }
    // 显示：markdown/math 渲染
    _enableDollarLatex = prefs.getBool(_displayEnableDollarLatexKey) ?? true;
    _enableMathRendering =
        prefs.getBool(_displayEnableMathRenderingKey) ?? true;
    _enableUserMarkdown = prefs.getBool(_displayEnableUserMarkdownKey) ?? true;
    _enableReasoningMarkdown =
        prefs.getBool(_displayEnableReasoningMarkdownKey) ?? true;
    _enableAssistantMarkdown =
        prefs.getBool(_displayEnableAssistantMarkdownKey) ?? true;
    _showChatListDate = prefs.getBool(_displayShowChatListDateKey) ?? false;
    _imageCropperEnabled = prefs.getBool(_imageCropperEnabledKey) ?? false;
    _imageUploadQuality = switch (prefs.getString(_imageUploadQualityKey)) {
      'original' => ImageUploadQuality.original,
      'high' => ImageUploadQuality.high,
      'saver' => ImageUploadQuality.saver,
      'custom' => ImageUploadQuality.custom,
      _ => ImageUploadQuality.balanced,
    };
    _imageCompressCustomQuality =
        (prefs.getInt(_imageCompressCustomQualityKey) ?? 85).clamp(10, 100);
    _imageCompressTransparentEnabled =
        prefs.getBool(_imageCompressTransparentEnabledKey) ?? false;
    _mobileCodeBlockWrap =
        prefs.getBool(_displayMobileCodeBlockWrapKey) ?? false;
    _autoCollapseCodeBlock =
        prefs.getBool(_displayAutoCollapseCodeBlockKey) ?? false;
    _autoCollapseCodeBlockLines =
        (prefs.getInt(_displayAutoCollapseCodeBlockLinesKey) ?? 2).clamp(
          1,
          999,
        );
    _desktopAutoSwitchTopics =
        prefs.getBool(_displayDesktopAutoSwitchTopicsKey) ?? false;
    // 桌面：托盘设置（桌面平台默认启用）
    final trayPref = prefs.getBool(_displayDesktopShowTrayKey);
    if (trayPref == null) {
      final isDesktop =
          Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      _desktopShowTray = isDesktop;
      await prefs.setBool(_displayDesktopShowTrayKey, _desktopShowTray);
    } else {
      _desktopShowTray = trayPref;
    }
    final minimizeTrayPref = prefs.getBool(
      _displayDesktopMinimizeToTrayOnCloseKey,
    );
    if (minimizeTrayPref == null) {
      _desktopMinimizeToTrayOnClose = _desktopShowTray;
      await prefs.setBool(
        _displayDesktopMinimizeToTrayOnCloseKey,
        _desktopMinimizeToTrayOnClose,
      );
    } else {
      // 强制不变量：托盘隐藏时不能最小化到托盘。
      _desktopMinimizeToTrayOnClose = minimizeTrayPref && _desktopShowTray;
      if (minimizeTrayPref && !_desktopShowTray) {
        await prefs.setBool(
          _displayDesktopMinimizeToTrayOnCloseKey,
          _desktopMinimizeToTrayOnClose,
        );
      }
    }
    // 桌面：话题面板位置 + 右侧边栏打开状态
    final topicPos = prefs.getString(_desktopTopicPositionKey);
    switch (topicPos) {
      case 'right':
        _desktopTopicPosition = DesktopTopicPosition.right;
        break;
      case 'left':
      default:
        _desktopTopicPosition = DesktopTopicPosition.left;
    }
    _desktopRightSidebarOpen =
        prefs.getBool(_desktopRightSidebarOpenKey) ?? true;
    // 聊天消息背景样式（default | frosted | solid）
    final bgStyleStr =
        prefs.getString(_displayChatMessageBackgroundStyleKey) ?? 'default';
    switch (bgStyleStr) {
      case 'frosted':
        _chatMessageBackgroundStyle = ChatMessageBackgroundStyle.frosted;
        break;
      case 'solid':
        _chatMessageBackgroundStyle = ChatMessageBackgroundStyle.solid;
        break;
      default:
        _chatMessageBackgroundStyle = ChatMessageBackgroundStyle.defaultStyle;
    }
    final bubbleOverridesRaw = prefs.getString(_chatBubbleStyleOverridesKey);
    if (bubbleOverridesRaw != null && bubbleOverridesRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(bubbleOverridesRaw);
        if (decoded is Map<String, dynamic>) {
          _chatBubbleStyleOverrides = ChatBubbleStyleOverrides.fromJson(
            decoded,
          );
        } else if (decoded is Map) {
          _chatBubbleStyleOverrides = ChatBubbleStyleOverrides.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {
        _chatBubbleStyleOverrides = const ChatBubbleStyleOverrides();
      }
    }
    final userBubbleOverridesRaw = prefs.getString(
      _userChatBubbleStyleOverridesKey,
    );
    if (userBubbleOverridesRaw != null && userBubbleOverridesRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(userBubbleOverridesRaw);
        if (decoded is Map<String, dynamic>) {
          _userChatBubbleStyleOverrides = ChatBubbleStyleOverrides.fromJson(
            decoded,
          );
        } else if (decoded is Map) {
          _userChatBubbleStyleOverrides = ChatBubbleStyleOverrides.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      } catch (_) {
        // Keep null so a corrupt user key still follows the assistant style.
      }
    }
    _mobileAssistantEditTabOrder = List.unmodifiable(
      prefs.getStringList(_mobileAssistantEditTabOrderKey) ?? const <String>[],
    );
    _hiddenMobileAssistantEditTabs = Set.unmodifiable(
      prefs.getStringList(_mobileAssistantEditTabHiddenKey) ?? const <String>[],
    );
    _mobileAssistantDetailOutlineEnabled =
        prefs.getBool(_mobileAssistantDetailOutlineEnabledKey) ?? false;
    // 桌面 UI
    _desktopSidebarWidth = prefs.getDouble(_desktopSidebarWidthKey) ?? 300;
    _desktopSidebarOpen = prefs.getBool(_desktopSidebarOpenKey) ?? true;
    _desktopRightSidebarWidth =
        prefs.getDouble(_desktopRightSidebarWidthKey) ?? 300;
    // 加载应用语言区域；首次启动默认跟随系统
    final storedAppLocale = prefs.get(_appLocaleKey);
    _appLocaleTag = _readAppLocaleTag(prefs);
    if (storedAppLocale != _appLocaleTag) {
      await prefs.setString(_appLocaleKey, 'system');
    }

    // Android 后台聊天模式（仅 Android；首次运行默认开启）
    try {
      final rawBg = prefs.getString(_androidBackgroundChatModeKey);
      if (rawBg == null) {
        // 默认关闭，避免首次启动时弹出权限提示
        _androidBackgroundChatMode = AndroidBackgroundChatMode.off;
        await prefs.setString(_androidBackgroundChatModeKey, 'off');
      } else {
        switch (rawBg) {
          case 'on_notify':
            _androidBackgroundChatMode = AndroidBackgroundChatMode.onNotify;
            break;
          case 'on':
            _androidBackgroundChatMode = AndroidBackgroundChatMode.on;
            break;
          case 'off':
          default:
            _androidBackgroundChatMode = AndroidBackgroundChatMode.off;
        }
      }
    } catch (_) {
      _androidBackgroundChatMode = AndroidBackgroundChatMode.off;
    }
    _iosBackgroundGenerationEnabled =
        prefs.getBool(_iosBackgroundGenerationEnabledKey) ?? false;
    _iosBackgroundTaskRefreshEnabled =
        prefs.getBool(_iosBackgroundTaskRefreshEnabledKey) ?? false;
    _iosLiveActivityEnabled =
        prefs.getBool(_iosLiveActivityEnabledKey) ?? false;
    _iosBackgroundNotificationsEnabled =
        prefs.getBool(_iosBackgroundNotificationsEnabledKey) ?? false;

    // 加载搜索设置
    final searchServicesStr = prefs.getString(_searchServicesKey);
    if (searchServicesStr != null && searchServicesStr.isNotEmpty) {
      try {
        final list = jsonDecode(searchServicesStr) as List;
        final decoded = list
            .map(
              (e) => SearchServiceOptions.fromJson(e as Map<String, dynamic>),
            )
            .toList();
        if (decoded.isNotEmpty) _searchServices = decoded;
      } catch (_) {}
    }
    final searchCommonStr = prefs.getString(_searchCommonKey);
    if (searchCommonStr != null && searchCommonStr.isNotEmpty) {
      try {
        _searchCommonOptions = SearchCommonOptions.fromJson(
          jsonDecode(searchCommonStr) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    _searchServiceSelected = prefs.getInt(_searchSelectedKey) ?? 0;
    _searchEnabled = prefs.getBool(_searchEnabledKey) ?? false;
    _searchAutoTestOnLaunch =
        prefs.getBool(_searchAutoTestOnLaunchKey) ?? false;

    // 加载全局代理
    _globalProxyEnabled = prefs.getBool(_globalProxyEnabledKey) ?? false;
    _globalProxyType = prefs.getString(_globalProxyTypeKey) ?? 'http';
    _globalProxyHost = prefs.getString(_globalProxyHostKey) ?? '';
    _globalProxyPort = prefs.getString(_globalProxyPortKey) ?? '8080';
    _globalProxyUsername = prefs.getString(_globalProxyUsernameKey) ?? '';
    _globalProxyPassword = prefs.getString(_globalProxyPasswordKey) ?? '';
    final bypass = prefs.getString(_globalProxyBypassKey);
    if (bypass == null) {
      _globalProxyBypass = _defaultGlobalProxyBypassRules;
      await prefs.setString(_globalProxyBypassKey, _globalProxyBypass);
    } else {
      _globalProxyBypass = bypass;
    }

    // 加载网络 TTS 服务
    try {
      final ttsStr = prefs.getString(_ttsServicesKey) ?? '';
      if (ttsStr.isNotEmpty) {
        final list = jsonDecode(ttsStr) as List;
        var generatedMissingIds = false;
        _ttsServices = [
          for (final value in list)
            TtsServiceOptions.fromJson(() {
              final map = value is Map<String, dynamic>
                  ? value
                  : Map<String, dynamic>.from(value as Map);
              if ((map['id'] ?? '').toString().trim().isEmpty) {
                generatedMissingIds = true;
              }
              return map;
            }()),
        ];
        // 旧数据行没有稳定标识符。先持久化生成的 ID，
        // 再迁移所选索引，以确保下次启动时 UUID 仍然有效。
        if (generatedMissingIds) {
          await prefs.setString(
            _ttsServicesKey,
            jsonEncode(
              _ttsServices.map((service) => service.toJson()).toList(),
            ),
          );
        }
      } else {
        _ttsServices = const <TtsServiceOptions>[];
      }
    } catch (_) {
      _ttsServices = const <TtsServiceOptions>[];
    }
    final storedTtsId = prefs.getString(_ttsSelectedServiceIdKey);
    if (storedTtsId != null) {
      _selectedTtsServiceId =
          _ttsServices.any((service) => service.id == storedTtsId)
          ? storedTtsId
          : (_ttsServices.isEmpty ? null : _ttsServices.first.id);
    } else {
      final legacyIndex = prefs.getInt(_ttsSelectedKey) ?? -1;
      _selectedTtsServiceId =
          legacyIndex >= 0 && legacyIndex < _ttsServices.length
          ? _ttsServices[legacyIndex].id
          : null;
    }
    await _persistSelectedTtsServiceId(prefs);
    await prefs.remove(_ttsSelectedKey);
    _ttsAutoPlayAssistantReplies =
        prefs.getBool(_ttsAutoPlayAssistantRepliesKey) ?? false;
    _ttsTextSelectionMode = TtsTextSelectionModeStorage.fromStorageValue(
      prefs.getString(_ttsTextSelectionModeKey),
    );
    // ASR 没有隐式系统默认值：用户需显式添加提供方。
    final decodedAsrServices = <AsrServiceOptions>[];
    try {
      final raw = prefs.getString(_asrServicesKey) ?? '';
      if (raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final value in list) {
          try {
            decodedAsrServices.add(
              AsrServiceOptions.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            );
          } catch (_) {
            // 当某条旧数据行损坏时，保留其他有效服务。
          }
        }
      }
    } catch (_) {}
    _asrServices = List<AsrServiceOptions>.unmodifiable(decodedAsrServices);
    final storedAsrId = prefs.getString(_asrSelectedServiceIdKey);
    _selectedAsrServiceId =
        decodedAsrServices.any((service) => service.id == storedAsrId)
        ? storedAsrId
        : (decodedAsrServices.isEmpty ? null : decodedAsrServices.first.id);
    if (_selectedAsrServiceId != storedAsrId) {
      if (_selectedAsrServiceId == null) {
        await prefs.remove(_asrSelectedServiceIdKey);
      } else {
        await prefs.setString(_asrSelectedServiceIdKey, _selectedAsrServiceId!);
      }
    }
    // webdav 配置
    final webdavStr = prefs.getString(_webDavConfigKey);
    if (webdavStr != null && webdavStr.isNotEmpty) {
      try {
        _webDavConfig = WebDavConfig.fromJson(
          jsonDecode(webdavStr) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    // s3 配置
    final s3Str = prefs.getString(_s3ConfigKey);
    if (s3Str != null && s3Str.isNotEmpty) {
      try {
        _s3Config = S3Config.fromJson(
          jsonDecode(s3Str) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    if (_providerConfigs.isEmpty) {
      // 首次启动时写入少量合理默认值，但后续读取（例如切换聊天时）
      // 不隐式重建提供方。
      ensureProviderConfig('KelivoIN', defaultName: 'KelivoIN');
      ensureProviderConfig('Tensdaq', defaultName: 'Tensdaq');
      ensureProviderConfig('SiliconFlow', defaultName: 'SiliconFlow');
      ensureProviderConfig('AIhubmix', defaultName: 'AIhubmix');
      final seededConfigs = _providerConfigs.map(
        (key, config) => MapEntry(key, config.toJson()),
      );
      await prefs.setString(_providerConfigsKey, jsonEncode(seededConfigs));
    }

    // 为服务启动一次连接性检测（排除本地 Bing）
    if (_searchAutoTestOnLaunch) {
      _initSearchConnectivityTests();
    }

    // 尝试重新加载用户安装的本地字体（移动平台）
    await _reloadLocalFontsIfAny();

    // 对提供方顺序和分组状态做最终清理（尽力而为）。
    if (_cleanupProviderOrderAndGrouping()) {
      try {
        await prefs.setStringList(_providersOrderKey, _providersOrder);
        await prefs.setString(
          _providerGroupMapKey,
          jsonEncode(_providerGroupMap),
        );
        await prefs.setString(
          _providerGroupCollapsedKey,
          jsonEncode(_providerGroupCollapsed),
        );
      } catch (_) {}
    }

    notifyListeners();
  }

  Future<void> setGlobalProxyEnabled(bool v) async {
    _globalProxyEnabled = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_globalProxyEnabledKey, _globalProxyEnabled);
  }

  Future<void> setGlobalProxyType(String v) async {
    _globalProxyType = v.trim().isEmpty ? 'http' : v.trim();
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_globalProxyTypeKey, _globalProxyType);
  }

  Future<void> setGlobalProxyHost(String v) async {
    _globalProxyHost = v.trim();
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_globalProxyHostKey, _globalProxyHost);
  }

  Future<void> setGlobalProxyPort(String v) async {
    _globalProxyPort = v.trim();
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_globalProxyPortKey, _globalProxyPort);
  }

  Future<void> setGlobalProxyUsername(String v) async {
    _globalProxyUsername = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_globalProxyUsernameKey, _globalProxyUsername);
  }

  Future<void> setGlobalProxyPassword(String v) async {
    _globalProxyPassword = v;
    notifyListeners();
    final prefs = _preferences;
    if (_globalProxyPassword.isEmpty) {
      await prefs.remove(_globalProxyPasswordKey);
    } else {
      await prefs.setString(_globalProxyPasswordKey, _globalProxyPassword);
    }
  }

  Future<void> setGlobalProxyBypass(String v) async {
    _globalProxyBypass = v.trim();
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_globalProxyBypassKey, _globalProxyBypass);
  }

  // 将全局代理应用到 Dart IO 层；提供方级代理在调用处优先。
  String _lastProxySignature = '';
  void applyGlobalProxyOverridesIfNeeded() {
    try {
      final enabled = _globalProxyEnabled;
      final host = _globalProxyHost.trim();
      final portStr = _globalProxyPort.trim();
      final user = _globalProxyUsername.trim();
      final pass = _globalProxyPassword;
      final type = _globalProxyType;
      final bypass = _globalProxyBypass;
      final sig = [enabled, type, host, portStr, user, pass, bypass].join('|');
      if (_lastProxySignature == sig) return;
      _lastProxySignature = sig;
      if (!enabled || host.isEmpty || portStr.isEmpty) {
        HttpOverrides.global = null;
        return;
      }
      final port = int.tryParse(portStr) ?? 8080;
      if (type == 'socks5') {
        HttpOverrides.global = _SocksProxyHttpOverrides(
          host: host,
          port: port,
          username: user.isEmpty ? null : user,
          password: pass,
          bypassRules: bypass,
        );
      } else {
        HttpOverrides.global = _ProxyHttpOverrides(
          host: host,
          port: port,
          username: user.isEmpty ? null : user,
          password: pass,
          bypassRules: bypass,
        );
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> setTtsServices(List<TtsServiceOptions> v) async {
    _ttsServices = List.unmodifiable(v);
    final prefs = _preferences;
    final list = v.map((e) => e.toJson()).toList();
    await prefs.setString(_ttsServicesKey, jsonEncode(list));
    if (_selectedTtsServiceId != null &&
        !_ttsServices.any((service) => service.id == _selectedTtsServiceId)) {
      _selectedTtsServiceId = _ttsServices.isEmpty
          ? null
          : _ttsServices.first.id;
      await _persistSelectedTtsServiceId(prefs);
    }
    notifyListeners();
  }

  Future<void> setTtsServiceSelected(int index) async {
    await setSelectedTtsServiceId(
      index >= 0 && index < _ttsServices.length ? _ttsServices[index].id : null,
    );
  }

  Future<void> setSelectedTtsServiceId(String? id) async {
    final normalized =
        id != null && _ttsServices.any((service) => service.id == id)
        ? id
        : null;
    if (_selectedTtsServiceId == normalized) return;
    _selectedTtsServiceId = normalized;
    await _persistSelectedTtsServiceId(_preferences);
    notifyListeners();
  }

  Future<void> _persistSelectedTtsServiceId(BusinessPreferences prefs) async {
    final selectedId = _selectedTtsServiceId;
    if (selectedId == null) {
      await prefs.remove(_ttsSelectedServiceIdKey);
    } else {
      await prefs.setString(_ttsSelectedServiceIdKey, selectedId);
    }
  }

  Future<void> setTtsAutoPlayAssistantReplies(bool value) async {
    if (_ttsAutoPlayAssistantReplies == value) return;
    _ttsAutoPlayAssistantReplies = value;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_ttsAutoPlayAssistantRepliesKey, value);
  }

  Future<void> setTtsTextSelectionMode(TtsTextSelectionMode mode) async {
    if (_ttsTextSelectionMode == mode) return;
    _ttsTextSelectionMode = mode;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_ttsTextSelectionModeKey, mode.storageValue);
  }

  Future<void> setAsrServices(List<AsrServiceOptions> value) async {
    _asrServices = List<AsrServiceOptions>.unmodifiable(value);
    if (!_asrServices.any((service) => service.id == _selectedAsrServiceId)) {
      _selectedAsrServiceId = _asrServices.isEmpty
          ? null
          : _asrServices.first.id;
    }
    final prefs = _preferences;
    await prefs.setString(
      _asrServicesKey,
      jsonEncode(_asrServices.map((service) => service.toJson()).toList()),
    );
    await _persistSelectedAsrServiceId(prefs);
    notifyListeners();
  }

  Future<void> setSelectedAsrServiceId(String? id) async {
    final normalized =
        id != null && _asrServices.any((service) => service.id == id)
        ? id
        : null;
    if (_selectedAsrServiceId == normalized) return;
    _selectedAsrServiceId = normalized;
    await _persistSelectedAsrServiceId(_preferences);
    notifyListeners();
  }

  Future<void> _persistSelectedAsrServiceId(BusinessPreferences prefs) async {
    final selectedId = _selectedAsrServiceId;
    if (selectedId == null) {
      await prefs.remove(_asrSelectedServiceIdKey);
    } else {
      await prefs.setString(_asrSelectedServiceIdKey, selectedId);
    }
  }

  // ===== 用户字体设置 =====
  String? _appFontFamily; // 全局使用的系统字体族
  String? _codeFontFamily; // 代码块使用的系统字体族
  // 本地字体文件选择（移动端）：持久化以便重新加载
  String? _appFontLocalPath;
  String? _codeFontLocalPath;
  // 通过 FontLoader 为本地字体注册的别名字体族名称
  String? _appFontLocalAlias;
  String? _codeFontLocalAlias;

  String? get appFontFamily => _effectiveAppFontAlias ?? _appFontFamily;
  String? get codeFontFamily => _effectiveCodeFontAlias ?? _codeFontFamily;
  String? get appFontLocalAlias => _appFontLocalAlias;
  String? get codeFontLocalAlias => _codeFontLocalAlias;

  // 如果设置了本地字体且注册成功，则使用别名
  String? get _effectiveAppFontAlias =>
      (_appFontLocalAlias?.isNotEmpty == true) ? _appFontLocalAlias : null;
  String? get _effectiveCodeFontAlias =>
      (_codeFontLocalAlias?.isNotEmpty == true) ? _codeFontLocalAlias : null;

  Future<void> setAppFontSystemFamily(String? family) async {
    _appFontFamily = (family == null || family.trim().isEmpty)
        ? null
        : family.trim();
    // 切换到系统字体时清除本地别名
    _appFontLocalAlias = null;
    _appFontLocalPath = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_displayAppFontFamilyKey, _appFontFamily ?? '');
    await prefs.remove(_displayAppFontLocalAliasKey);
    await prefs.remove(_displayAppFontLocalPathKey);
  }

  Future<void> setCodeFontSystemFamily(String? family) async {
    _codeFontFamily = (family == null || family.trim().isEmpty)
        ? null
        : family.trim();
    _codeFontLocalAlias = null;
    _codeFontLocalPath = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_displayCodeFontFamilyKey, _codeFontFamily ?? '');
    await prefs.remove(_displayCodeFontLocalAliasKey);
    await prefs.remove(_displayCodeFontLocalPathKey);
  }

  Future<void> setAppFontFromLocal({
    required String path,
    String? alias,
  }) async {
    final previousPath = _appFontLocalPath;
    final localPath = await _importLocalFontFile(path);
    if (localPath == null) return;
    final fam = await _registerLocalFont(
      path: localPath,
      aliasPrefix: alias ?? 'kelivo_local_app',
    );
    if (fam == null) {
      await _deleteManagedFontFileIfUnused(localPath);
      return;
    }
    _appFontFamily = fam;
    _appFontLocalAlias = fam;
    _appFontLocalPath = localPath;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_displayAppFontFamilyKey, _appFontFamily!);
    await prefs.setString(_displayAppFontLocalAliasKey, _appFontLocalAlias!);
    await prefs.setString(_displayAppFontLocalPathKey, _appFontLocalPath!);
    await _deleteManagedFontFileIfUnused(previousPath);
  }

  Future<void> setCodeFontFromLocal({
    required String path,
    String? alias,
  }) async {
    final previousPath = _codeFontLocalPath;
    final localPath = await _importLocalFontFile(path);
    if (localPath == null) return;
    final fam = await _registerLocalFont(
      path: localPath,
      aliasPrefix: alias ?? 'kelivo_local_code',
    );
    if (fam == null) {
      await _deleteManagedFontFileIfUnused(localPath);
      return;
    }
    _codeFontFamily = fam;
    _codeFontLocalAlias = fam;
    _codeFontLocalPath = localPath;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_displayCodeFontFamilyKey, _codeFontFamily!);
    await prefs.setString(_displayCodeFontLocalAliasKey, _codeFontLocalAlias!);
    await prefs.setString(_displayCodeFontLocalPathKey, _codeFontLocalPath!);
    await _deleteManagedFontFileIfUnused(previousPath);
  }

  Future<void> clearAppFont() async {
    final previousPath = _appFontLocalPath;
    _appFontFamily = null;
    _appFontLocalAlias = null;
    _appFontLocalPath = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_displayAppFontFamilyKey);
    await prefs.remove(_displayAppFontLocalAliasKey);
    await prefs.remove(_displayAppFontLocalPathKey);
    await _deleteManagedFontFileIfUnused(previousPath);
  }

  Future<void> clearCodeFont() async {
    final previousPath = _codeFontLocalPath;
    _codeFontFamily = null;
    _codeFontLocalAlias = null;
    _codeFontLocalPath = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_displayCodeFontFamilyKey);
    await prefs.remove(_displayCodeFontLocalAliasKey);
    await prefs.remove(_displayCodeFontLocalPathKey);
    await _deleteManagedFontFileIfUnused(previousPath);
  }

  Future<void> _reloadLocalFontsIfAny() async {
    final prefs = _preferences;
    // 加载持久化值
    _appFontFamily = _nonEmpty(prefs.getString(_displayAppFontFamilyKey));
    _codeFontFamily = _nonEmpty(prefs.getString(_displayCodeFontFamilyKey));
    _appFontLocalPath = _nonEmpty(prefs.getString(_displayAppFontLocalPathKey));
    _codeFontLocalPath = _nonEmpty(
      prefs.getString(_displayCodeFontLocalPathKey),
    );
    _appFontLocalAlias = _nonEmpty(
      prefs.getString(_displayAppFontLocalAliasKey),
    );
    _codeFontLocalAlias = _nonEmpty(
      prefs.getString(_displayCodeFontLocalAliasKey),
    );

    var changed = false;

    // 已移除的 Google Fonts 选择器所选的字体没有安装在设备上，
    // 因此旧选择回退到系统默认。
    final legacyAppFontIsGoogle =
        prefs.getBool(_legacyAppFontIsGoogleKey) ?? false;
    final legacyCodeFontIsGoogle =
        prefs.getBool(_legacyCodeFontIsGoogleKey) ?? false;
    if (legacyAppFontIsGoogle) {
      _appFontFamily = null;
      changed = true;
    }
    if (legacyCodeFontIsGoogle) {
      _codeFontFamily = null;
      changed = true;
    }

    // 如果路径可用，则重新注册本地字体。
    if (_appFontLocalPath != null && _appFontLocalPath!.isNotEmpty) {
      final alias = _appFontLocalAlias ?? 'kelivo_local_app';
      final resolvedPath = SandboxPathResolver.fix(_appFontLocalPath!);
      final fam = await _registerLocalFont(
        path: resolvedPath,
        aliasPrefix: alias,
      );
      if (fam != null) {
        _appFontLocalAlias = fam;
        _appFontFamily = fam;
        if (_appFontLocalPath != resolvedPath) {
          _appFontLocalPath = resolvedPath;
          changed = true;
        }
      } else if (_appFontLocalAlias != null || _appFontFamily != null) {
        _appFontLocalAlias = null;
        _appFontLocalPath = null;
        _appFontFamily = null;
        changed = true;
      }
    }
    if (_codeFontLocalPath != null && _codeFontLocalPath!.isNotEmpty) {
      final alias = _codeFontLocalAlias ?? 'kelivo_local_code';
      final resolvedPath = SandboxPathResolver.fix(_codeFontLocalPath!);
      final fam = await _registerLocalFont(
        path: resolvedPath,
        aliasPrefix: alias,
      );
      if (fam != null) {
        _codeFontLocalAlias = fam;
        _codeFontFamily = fam;
        if (_codeFontLocalPath != resolvedPath) {
          _codeFontLocalPath = resolvedPath;
          changed = true;
        }
      } else if (_codeFontLocalAlias != null || _codeFontFamily != null) {
        _codeFontLocalAlias = null;
        _codeFontLocalPath = null;
        _codeFontFamily = null;
        changed = true;
      }
    }

    if (changed) {
      await _persistFontSettings(prefs);
    }
    if (prefs.containsKey(_legacyAppFontIsGoogleKey)) {
      await prefs.remove(_legacyAppFontIsGoogleKey);
    }
    if (prefs.containsKey(_legacyCodeFontIsGoogleKey)) {
      await prefs.remove(_legacyCodeFontIsGoogleKey);
    }
  }

  String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

  Future<void> _persistFontSettings(BusinessPreferences prefs) async {
    if (_appFontFamily == null || _appFontFamily!.isEmpty) {
      await prefs.remove(_displayAppFontFamilyKey);
    } else {
      await prefs.setString(_displayAppFontFamilyKey, _appFontFamily!);
    }
    if (_appFontLocalAlias == null || _appFontLocalAlias!.isEmpty) {
      await prefs.remove(_displayAppFontLocalAliasKey);
    } else {
      await prefs.setString(_displayAppFontLocalAliasKey, _appFontLocalAlias!);
    }
    if (_appFontLocalPath == null || _appFontLocalPath!.isEmpty) {
      await prefs.remove(_displayAppFontLocalPathKey);
    } else {
      await prefs.setString(_displayAppFontLocalPathKey, _appFontLocalPath!);
    }

    if (_codeFontFamily == null || _codeFontFamily!.isEmpty) {
      await prefs.remove(_displayCodeFontFamilyKey);
    } else {
      await prefs.setString(_displayCodeFontFamilyKey, _codeFontFamily!);
    }
    if (_codeFontLocalAlias == null || _codeFontLocalAlias!.isEmpty) {
      await prefs.remove(_displayCodeFontLocalAliasKey);
    } else {
      await prefs.setString(
        _displayCodeFontLocalAliasKey,
        _codeFontLocalAlias!,
      );
    }
    if (_codeFontLocalPath == null || _codeFontLocalPath!.isEmpty) {
      await prefs.remove(_displayCodeFontLocalPathKey);
    } else {
      await prefs.setString(_displayCodeFontLocalPathKey, _codeFontLocalPath!);
    }
  }

  Future<String?> _importLocalFontFile(String sourcePath) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) return null;
      final dir = await AppDirectories.getFontsDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final sourceName = p.basename(source.path);
      final safeBase = p
          .basenameWithoutExtension(sourceName)
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
      final base = safeBase.isEmpty ? 'font' : safeBase;
      final ext = p.extension(sourceName).toLowerCase();
      final safeExt = (ext == '.ttf' || ext == '.otf') ? ext : '.ttf';
      final dest = File(
        p.join(
          dir.path,
          '${base}_${DateTime.now().microsecondsSinceEpoch}$safeExt',
        ),
      );
      await dest.writeAsBytes(await source.readAsBytes(), flush: true);
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteManagedFontFileIfUnused(String? path) async {
    if (path == null || path.isEmpty) return;
    if (path == _appFontLocalPath || path == _codeFontLocalPath) return;
    try {
      final fontsDir = await AppDirectories.getFontsDirectory();
      final root = p.normalize(Directory(fontsDir.path).absolute.path);
      final file = File(path);
      final target = p.normalize(file.absolute.path);
      if (!(p.isWithin(root, target) || target == root)) return;
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<String?> _registerLocalFont({
    required String path,
    required String aliasPrefix,
  }) async {
    try {
      // 使用从文件名派生的稳定别名以减少重复
      final ts = DateTime.now().millisecondsSinceEpoch;
      final alias = '${aliasPrefix}_$ts';
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (!_looksLikeFontBytes(bytes)) return null;
      final bd = bytes.buffer.asByteData();
      final loader = FontLoader(alias);
      loader.addFont(Future.value(bd));
      await loader.load();
      return alias;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeFontBytes(List<int> bytes) {
    if (bytes.length < 4) return false;
    final tag = String.fromCharCodes(bytes.take(4));
    if (tag == 'OTTO' || tag == 'ttcf') return true;
    return bytes[0] == 0x00 &&
        bytes[1] == 0x01 &&
        bytes[2] == 0x00 &&
        bytes[3] == 0x00;
  }

  // ===== 桌面 UI 设置方法 =====
  Future<void> setDesktopSidebarWidth(double width) async {
    final w = width.clamp(200.0, 640.0).toDouble();
    if ((w - _desktopSidebarWidth).abs() < 0.5) return;
    _desktopSidebarWidth = w;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setDouble(_desktopSidebarWidthKey, _desktopSidebarWidth);
  }

  Future<void> setDesktopSidebarOpen(bool open) async {
    if (_desktopSidebarOpen == open) return;
    _desktopSidebarOpen = open;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_desktopSidebarOpenKey, _desktopSidebarOpen);
  }

  Future<void> setDesktopRightSidebarWidth(double w) async {
    if ((_desktopRightSidebarWidth - w).abs() < 0.5) return;
    _desktopRightSidebarWidth = w;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setDouble(
      _desktopRightSidebarWidthKey,
      _desktopRightSidebarWidth,
    );
  }

  // 桌面端：话题面板位置（左/右）
  Future<void> setDesktopTopicPosition(DesktopTopicPosition pos) async {
    if (_desktopTopicPosition == pos) return;
    _desktopTopicPosition = pos;
    notifyListeners();
    final prefs = _preferences;
    final v = (pos == DesktopTopicPosition.right) ? 'right' : 'left';
    await prefs.setString(_desktopTopicPositionKey, v);
  }

  // 桌面端：右侧边栏可见状态
  Future<void> setDesktopRightSidebarOpen(bool open) async {
    if (_desktopRightSidebarOpen == open) return;
    _desktopRightSidebarOpen = open;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_desktopRightSidebarOpenKey, _desktopRightSidebarOpen);
  }

  // ===== 应用语言环境（UI 语言） =====
  String? _appLocaleTag; // 'system', 'zh_CN', 'zh_Hant', 'en_US'
  static String _readAppLocaleTag(BusinessPreferences preferences) {
    final value = preferences.get(_appLocaleKey);
    const supportedTags = {'system', 'zh_CN', 'zh_Hant', 'en_US'};
    return value is String && supportedTags.contains(value) ? value : 'system';
  }

  Locale get appLocale => _parseLocaleTag(_appLocaleTag ?? 'en_US');
  bool get isFollowingSystemLocale =>
      (_appLocaleTag == null) || (_appLocaleTag == 'system');
  Locale? get appLocaleForMaterialApp =>
      isFollowingSystemLocale ? null : appLocale;
  Future<void> setAppLocale(Locale locale) async {
    final tag = _localeToTag(locale);
    if (_appLocaleTag == tag) return;
    _appLocaleTag = tag;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_appLocaleKey, _appLocaleTag!);
  }

  Future<void> setAppLocaleFollowSystem() async {
    if (_appLocaleTag == 'system') return;
    _appLocaleTag = 'system';
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_appLocaleKey, 'system');
  }

  String _localeToTag(Locale l) {
    final lc = l.languageCode.toLowerCase();
    if (lc == 'zh') {
      final script = (l.scriptCode ?? '').toLowerCase();
      if (script == 'hant') return 'zh_Hant';
      return 'zh_CN';
    }
    return 'en_US';
  }

  Locale _parseLocaleTag(String tag) {
    switch (tag) {
      case 'zh_CN':
        return const Locale('zh', 'CN');
      case 'zh_Hant':
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      case 'en_US':
      default:
        return const Locale('en', 'US');
    }
  }

  // ===== 备份与 WebDAV 设置 =====
  WebDavConfig _webDavConfig = const WebDavConfig();
  WebDavConfig get webDavConfig => _webDavConfig;
  Future<void> setWebDavConfig(WebDavConfig cfg) async {
    _webDavConfig = cfg;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_webDavConfigKey, jsonEncode(cfg.toJson()));
  }

  S3Config _s3Config = const S3Config();
  S3Config get s3Config => _s3Config;
  Future<void> setS3Config(S3Config cfg) async {
    _s3Config = cfg;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_s3ConfigKey, jsonEncode(cfg.toJson()));
  }

  Future<void> _initSearchConnectivityTests() async {
    final services = List<SearchServiceOptions>.from(_searchServices);
    final common = _searchCommonOptions;
    for (final s in services) {
      if (s is BingLocalOptions) {
        _searchConnection[s.id] = null; // 本地 Bing 不使用标签
        continue;
      }
      // 在后台运行；不要 await 全部
      unawaited(_testSingleSearchService(s, common));
    }
  }

  Future<void> _testSingleSearchService(
    SearchServiceOptions s,
    SearchCommonOptions common,
  ) async {
    try {
      final svc = SearchService.getService(s);
      await svc.search(
        query: 'connectivity test',
        commonOptions: common,
        serviceOptions: s,
      );
      _searchConnection[s.id] = true;
    } catch (_) {
      _searchConnection[s.id] = false;
    }
    notifyListeners();
  }

  void setSearchConnection(String id, bool? value) {
    _searchConnection[id] = value;
    notifyListeners();
  }

  Future<void> setProvidersOrder(List<String> order) async {
    var seededBuiltIn = false;
    for (final key in order) {
      if (_builtInProviderKeys.contains(key) &&
          !_providerConfigs.containsKey(key)) {
        ensureProviderConfig(key, defaultName: key);
        seededBuiltIn = true;
      }
    }
    _providersOrder = List.unmodifiable(order);
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    if (seededBuiltIn) {
      final configs = _providerConfigs.map(
        (key, config) => MapEntry(key, config.toJson()),
      );
      await prefs.setString(_providerConfigsKey, jsonEncode(configs));
    }
    await prefs.setStringList(_providersOrderKey, _providersOrder);
  }

  Set<String> _knownProviderKeys() => <String>{
    ..._builtInProviderKeys,
    ..._providerConfigs.keys,
  };

  bool _cleanupProviderOrderAndGrouping() {
    bool changed = false;
    final knownKeys = _knownProviderKeys();

    // 清理 provider 顺序：移除不存在的项并去重，将新项追加到末尾。
    final nextOrder = <String>[];
    final seen = <String>{};
    for (final k in _providersOrder) {
      if (!knownKeys.contains(k)) {
        changed = true;
        continue;
      }
      if (!seen.add(k)) {
        changed = true;
        continue;
      }
      nextOrder.add(k);
    }
    final mergedDefault = <String>[
      ..._builtInProviderKeysInOrder,
      ..._providerConfigs.keys.where((k) => !_builtInProviderKeys.contains(k)),
    ];
    for (final k in mergedDefault) {
      if (knownKeys.contains(k) && seen.add(k)) {
        nextOrder.add(k);
        changed = true;
      }
    }
    if (!listEquals(_providersOrder, nextOrder)) {
      _providersOrder = List.unmodifiable(nextOrder);
      changed = true;
    }

    // 清理分组映射：移除无效的 groupIds 或不存在的 provider 键。
    final validGroupIds = {for (final g in _providerGroups) g.id};
    final nextMap = <String, String>{};
    for (final entry in _providerGroupMap.entries) {
      final providerKey = entry.key;
      final groupId = entry.value;
      if (!knownKeys.contains(providerKey)) {
        changed = true;
        continue;
      }
      if (!validGroupIds.contains(groupId)) {
        changed = true;
        continue;
      }
      nextMap[providerKey] = groupId;
    }
    if (!mapEquals(_providerGroupMap, nextMap)) {
      _providerGroupMap = nextMap;
      changed = true;
    }

    // 清理折叠状态：移除未知的分组 ID（未分组除外）。
    final nextCollapsed = <String, bool>{};
    for (final entry in _providerGroupCollapsed.entries) {
      final key = entry.key;
      if (key == providerUngroupedGroupKey || validGroupIds.contains(key)) {
        nextCollapsed[key] = entry.value;
      } else {
        changed = true;
      }
    }
    if (!mapEquals(_providerGroupCollapsed, nextCollapsed)) {
      _providerGroupCollapsed
        ..clear()
        ..addAll(nextCollapsed);
      changed = true;
    }

    final normalizedUngroupedPosition = _providerUngroupedPosition.clamp(
      0,
      _providerGroups.length,
    );
    if (_providerUngroupedPosition != normalizedUngroupedPosition) {
      _providerUngroupedPosition = normalizedUngroupedPosition;
      changed = true;
    }

    return changed;
  }

  Future<void> _persistProviderGrouping(BusinessPreferences prefs) async {
    await prefs.setString(
      _providerGroupsKey,
      ProviderGroup.encodeList(_providerGroups),
    );
    await prefs.setString(_providerGroupMapKey, jsonEncode(_providerGroupMap));
    await prefs.setString(
      _providerGroupCollapsedKey,
      jsonEncode(_providerGroupCollapsed),
    );
    await prefs.setInt(
      _providerUngroupedPositionKey,
      providerUngroupedDisplayIndex,
    );
    await prefs.setStringList(_providersOrderKey, _providersOrder);
  }

  Future<String> createGroup(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '';
    final key = trimmed.toLowerCase();
    for (final g in _providerGroups) {
      if (g.name.trim().toLowerCase() == key) return g.id;
    }
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    final res = insertProviderGroup(
      groups: _providerGroups,
      ungroupedIndex: providerUngroupedDisplayIndex,
      group: ProviderGroup(id: id, name: trimmed, createdAt: now),
    );
    _providerGroups = List<ProviderGroup>.of(res.groups);
    _providerUngroupedPosition = res.ungroupedIndex;
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
    return id;
  }

  Future<void> renameGroup(String groupId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final idx = _providerGroups.indexWhere((g) => g.id == groupId);
    if (idx < 0) return;

    final key = trimmed.toLowerCase();
    for (final g in _providerGroups) {
      if (g.id != groupId && g.name.trim().toLowerCase() == key) return;
    }

    final current = _providerGroups[idx];
    if (current.name == trimmed) return;
    final mut = List<ProviderGroup>.of(_providerGroups);
    mut[idx] = current.copyWith(name: trimmed);
    _providerGroups = List.unmodifiable(mut);
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
  }

  Future<void> reorderProviderGroups(int oldIndex, int newIndex) async {
    if (_providerGroups.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= _providerGroups.length) return;
    if (newIndex < 0 || newIndex > _providerGroups.length) return;
    if (oldIndex == newIndex) return;

    final mut = List<ProviderGroup>.of(_providerGroups);
    final item = mut.removeAt(oldIndex);
    final insertIndex = newIndex.clamp(0, mut.length);
    mut.insert(insertIndex, item);
    _providerGroups = List.unmodifiable(mut);
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
  }

  Future<void> reorderProviderGroupsWithUngrouped(
    int oldIndex,
    int newIndex,
  ) async {
    final displayCount = _providerGroups.length + 1;
    if (displayCount <= 1) return;
    if (oldIndex < 0 || oldIndex >= displayCount) return;
    if (newIndex < 0 || newIndex > displayCount) return;
    if (oldIndex == newIndex) return;

    final res = reorderProviderGroupDisplayWithUngrouped(
      groups: _providerGroups,
      ungroupedIndex: providerUngroupedDisplayIndex,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    _providerGroups = List<ProviderGroup>.of(res.groups);
    _providerUngroupedPosition = res.ungroupedIndex;
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
  }

  Future<void> deleteGroup(String groupId) async {
    if (groupById(groupId) == null) return;
    final res = deleteProviderGroup(
      groups: _providerGroups,
      ungroupedIndex: providerUngroupedDisplayIndex,
      providerGroupMap: _providerGroupMap,
      collapsed: _providerGroupCollapsed,
      groupId: groupId,
    );
    _providerGroups = List<ProviderGroup>.of(res.groups);
    _providerUngroupedPosition = res.ungroupedIndex;
    _providerGroupMap = Map<String, String>.from(res.providerGroupMap);
    _providerGroupCollapsed
      ..clear()
      ..addAll(res.collapsed);
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
  }

  Future<void> setProviderGroup(String providerKey, String? groupId) async {
    final known = _knownProviderKeys();
    if (!known.contains(providerKey)) return;
    final target = (groupId != null && groupById(groupId) != null)
        ? groupId
        : null;
    final current = groupIdForProvider(providerKey);
    if (current == target) return;

    if (target == null) {
      _providerGroupMap.remove(providerKey);
    } else {
      _providerGroupMap[providerKey] = target;
    }
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
  }

  Future<void> moveProvidersToGroup(
    Iterable<String> providerKeys,
    String? targetGroupId,
  ) async {
    final known = _knownProviderKeys();
    final validGroupIds = {for (final g in _providerGroups) g.id};
    final normalizedTargetGroupId =
        (targetGroupId != null && validGroupIds.contains(targetGroupId))
        ? targetGroupId
        : null;

    final keysSet = providerKeys.where(known.contains).toSet();
    if (keysSet.isEmpty) return;

    // 在追加到目标分组时，保留当前可见顺序。
    final orderedKeys = <String>[];
    for (final k in _providersOrder) {
      if (keysSet.remove(k)) orderedKeys.add(k);
    }
    orderedKeys.addAll(keysSet);

    List<String> order = _providersOrder;
    Map<String, String> groupMap = _providerGroupMap;

    String? groupIdFor(String key) {
      final gid = groupMap[key];
      return (gid != null && validGroupIds.contains(gid)) ? gid : null;
    }

    bool changed = false;
    for (final key in orderedKeys) {
      final current = groupIdFor(key);
      if (current == normalizedTargetGroupId) continue;

      final res = moveProviderInGroupedOrder(
        providersOrder: order,
        providerGroupMap: groupMap,
        knownProviderKeys: known,
        validGroupIds: validGroupIds,
        providerKey: key,
        targetGroupId: normalizedTargetGroupId,
        targetPos: 1 << 30, // 追加
      );
      order = res.providersOrder;
      groupMap = res.providerGroupMap;
      changed = true;
    }

    if (!changed) return;
    _providersOrder = order;
    _providerGroupMap = Map<String, String>.from(groupMap);
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
  }

  Future<void> setGroupCollapsed(String groupIdOrUngrouped, bool value) async {
    if (groupIdOrUngrouped != providerUngroupedGroupKey &&
        groupById(groupIdOrUngrouped) == null) {
      return;
    }
    _providerGroupCollapsed[groupIdOrUngrouped] = value;
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
  }

  Future<void> toggleGroupCollapsed(String groupIdOrUngrouped) async =>
      setGroupCollapsed(
        groupIdOrUngrouped,
        !isGroupCollapsed(groupIdOrUngrouped),
      );

  Future<void> moveProvider(
    String providerKey,
    String? targetGroupId,
    int targetPos,
  ) async {
    final known = _knownProviderKeys();
    if (!known.contains(providerKey)) return;

    final validGroupIds = {for (final g in _providerGroups) g.id};
    final res = moveProviderInGroupedOrder(
      providersOrder: _providersOrder,
      providerGroupMap: _providerGroupMap,
      knownProviderKeys: known,
      validGroupIds: validGroupIds,
      providerKey: providerKey,
      targetGroupId: targetGroupId,
      targetPos: targetPos,
    );
    _providersOrder = res.providersOrder;
    _providerGroupMap = Map<String, String>.from(res.providerGroupMap);
    _cleanupProviderOrderAndGrouping();
    notifyListeners();
    final prefs = _preferences;
    await _persistProviderGrouping(prefs);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = _preferences;
    final v = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.dark
        ? 'dark'
        : 'system';
    await prefs.setString(_themeModeKey, v);
  }

  Future<void> setThemePalette(String id) async {
    if (_themePaletteId == id) return;
    _themePaletteId = id;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_themePaletteKey, id);
  }

  Future<void> setUseDynamicColor(bool v) async {
    if (_useDynamicColor == v) return;
    _useDynamicColor = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_useDynamicColorKey, v);
  }

  Future<void> setUsePureBackground(bool v) async {
    if (_usePureBackground == v) return;
    _usePureBackground = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayUsePureBackgroundKey, v);
  }

  void _loadCustomThemes(BusinessPreferences prefs) {
    final raw = prefs.getStringList(_customThemesKey) ?? const <String>[];
    final themes = <CustomTheme>[];
    for (final s in raw) {
      try {
        themes.add(CustomTheme.parse(s));
      } catch (_) {}
    }
    _customThemes = themes;
    _selectedCustomThemeId = prefs.getString(_customThemeSelectedKey);
    if (_selectedCustomThemeId != null &&
        !_customThemes.any((t) => t.id == _selectedCustomThemeId)) {
      _selectedCustomThemeId = null;
    }
    // 从旧版单一种子/主调色板进行的一次性迁移。
    final legacyArgb =
        prefs.getInt(_legacyCustomPrimaryOverrideKey) ??
        prefs.getInt(_legacyCustomSeedColorKey);
    if (legacyArgb != null) {
      if (_customThemes.isEmpty) {
        final migrated = CustomTheme(
          id: 'migrated_$legacyArgb',
          name: '',
          primaryArgb: legacyArgb,
        );
        _customThemes = <CustomTheme>[migrated];
        _selectedCustomThemeId ??= migrated.id;
        unawaited(
          prefs.setStringList(
            _customThemesKey,
            _customThemes.map((t) => t.export()).toList(),
          ),
        );
        unawaited(prefs.setString(_customThemeSelectedKey, migrated.id));
      }
      unawaited(prefs.remove(_legacyCustomSeedColorKey));
      unawaited(prefs.remove(_legacyCustomPrimaryOverrideKey));
      unawaited(prefs.remove('theme_custom_surface_v1'));
    }
  }

  Future<void> _persistCustomThemes() async {
    final prefs = _preferences;
    await prefs.setStringList(
      _customThemesKey,
      _customThemes.map((t) => t.export()).toList(),
    );
    final sel = _selectedCustomThemeId;
    if (sel == null) {
      await prefs.remove(_customThemeSelectedKey);
    } else {
      await prefs.setString(_customThemeSelectedKey, sel);
    }
  }

  /// 插入或更新自定义主题。返回保存后的主题（如果
  /// [theme.id] 为空，则会分配一个 id）。
  Future<CustomTheme> saveCustomTheme(CustomTheme theme) async {
    var t = theme;
    if (t.id.isEmpty) {
      t = t.copyWith(id: 'ct_${DateTime.now().microsecondsSinceEpoch}');
    }
    final idx = _customThemes.indexWhere((e) => e.id == t.id);
    final next = List<CustomTheme>.of(_customThemes);
    if (idx >= 0) {
      next[idx] = t;
    } else {
      next.add(t);
    }
    _customThemes = next;
    notifyListeners();
    await _persistCustomThemes();
    return t;
  }

  Future<void> deleteCustomTheme(String id) async {
    if (!_customThemes.any((t) => t.id == id)) return;
    _customThemes = _customThemes.where((t) => t.id != id).toList();
    if (_selectedCustomThemeId == id) {
      _selectedCustomThemeId = _customThemes.isEmpty
          ? null
          : _customThemes.first.id;
      if (_selectedCustomThemeId == null &&
          _themePaletteId == ThemePalettes.customPaletteId) {
        _themePaletteId = ThemePalettes.defaultId;
        unawaited(
          _preferences.setString(_themePaletteKey, ThemePalettes.defaultId),
        );
      }
    }
    notifyListeners();
    await _persistCustomThemes();
  }

  /// 选择自定义主题并将其设为当前调色板。
  Future<void> selectCustomTheme(String id) async {
    if (!_customThemes.any((t) => t.id == id)) return;
    final changed =
        _selectedCustomThemeId != id ||
        _themePaletteId != ThemePalettes.customPaletteId;
    if (!changed) return;
    _selectedCustomThemeId = id;
    _themePaletteId = ThemePalettes.customPaletteId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_customThemeSelectedKey, id);
    await prefs.setString(_themePaletteKey, ThemePalettes.customPaletteId);
  }

  /// 解析共享的自定义主题 JSON 字符串，保存并返回存储后的
  /// 主题（当 id 缺失或已被占用时，会分配一个新的 id）。
  Future<CustomTheme> importCustomTheme(String source) {
    var t = CustomTheme.parse(source);
    if (t.id.isEmpty || _customThemes.any((e) => e.id == t.id)) {
      t = t.copyWith(id: 'ct_${DateTime.now().microsecondsSinceEpoch}');
    }
    return saveCustomTheme(t);
  }

  // 显示：聊天消息背景样式（影响用户/助手气泡）
  ChatMessageBackgroundStyle _chatMessageBackgroundStyle =
      ChatMessageBackgroundStyle.defaultStyle;
  ChatMessageBackgroundStyle get chatMessageBackgroundStyle =>
      _chatMessageBackgroundStyle;
  Future<void> setChatMessageBackgroundStyle(
    ChatMessageBackgroundStyle style,
  ) async {
    if (_chatMessageBackgroundStyle == style) return;
    _chatMessageBackgroundStyle = style;
    notifyListeners();
    final prefs = _preferences;
    final v = switch (style) {
      ChatMessageBackgroundStyle.frosted => 'frosted',
      ChatMessageBackgroundStyle.solid => 'solid',
      ChatMessageBackgroundStyle.defaultStyle => 'default',
    };
    await prefs.setString(_displayChatMessageBackgroundStyleKey, v);
  }

  ChatBubbleStyleOverrides _chatBubbleStyleOverrides =
      const ChatBubbleStyleOverrides();
  ChatBubbleStyleOverrides? _userChatBubbleStyleOverrides;
  ChatBubbleStyleOverrides get chatBubbleStyleOverrides =>
      _chatBubbleStyleOverrides;
  ChatBubbleStyleOverrides get assistantChatBubbleStyleOverrides =>
      _chatBubbleStyleOverrides;
  ChatBubbleStyleOverrides get userChatBubbleStyleOverrides =>
      _userChatBubbleStyleOverrides ?? _chatBubbleStyleOverrides;
  ChatBubbleStyleOverrides chatBubbleStyleOverridesFor({
    required bool isUser,
  }) =>
      isUser ? userChatBubbleStyleOverrides : assistantChatBubbleStyleOverrides;
  Future<void> setChatBubbleStyleOverrides(ChatBubbleStyleOverrides v) async {
    final assistantChanged = _chatBubbleStyleOverrides != v;
    final hadUserSplit = _userChatBubbleStyleOverrides != null;
    if (!assistantChanged && !hadUserSplit) return;
    _chatBubbleStyleOverrides = v;
    _userChatBubbleStyleOverrides = null;
    notifyListeners();
    if (assistantChanged) {
      await _preferences.setString(
        _chatBubbleStyleOverridesKey,
        jsonEncode(v.toJson()),
      );
    }
    if (hadUserSplit) {
      await _preferences.remove(_userChatBubbleStyleOverridesKey);
    }
  }

  Future<void> setChatBubbleStyleOverridesForRole({
    required bool isUser,
    required ChatBubbleStyleOverrides value,
  }) async {
    if (isUser) {
      if (_userChatBubbleStyleOverrides == value) return;
      _userChatBubbleStyleOverrides = value;
      notifyListeners();
      await _preferences.setString(
        _userChatBubbleStyleOverridesKey,
        jsonEncode(value.toJson()),
      );
      return;
    }
    if (_chatBubbleStyleOverrides == value) return;
    if (_userChatBubbleStyleOverrides == null) {
      final previous = _chatBubbleStyleOverrides;
      _userChatBubbleStyleOverrides = previous;
      _chatBubbleStyleOverrides = value;
      notifyListeners();
      // Submit both writes before awaiting so a later edit cannot queue ahead
      // of the first edit's assistant value.
      final userWrite = _preferences.setString(
        _userChatBubbleStyleOverridesKey,
        jsonEncode(previous.toJson()),
      );
      final assistantWrite = _preferences.setString(
        _chatBubbleStyleOverridesKey,
        jsonEncode(value.toJson()),
      );
      await userWrite;
      await assistantWrite;
      return;
    }
    _chatBubbleStyleOverrides = value;
    notifyListeners();
    await _preferences.setString(
      _chatBubbleStyleOverridesKey,
      jsonEncode(value.toJson()),
    );
  }

  List<String> _mobileAssistantEditTabOrder = const <String>[];
  List<String> get mobileAssistantEditTabOrder => _mobileAssistantEditTabOrder;
  Future<void> setMobileAssistantEditTabOrder(List<String> order) async {
    final next = List<String>.unmodifiable(LinkedHashSet<String>.from(order));
    if (listEquals(_mobileAssistantEditTabOrder, next)) return;
    _mobileAssistantEditTabOrder = next;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setStringList(_mobileAssistantEditTabOrderKey, next);
  }

  Set<String> _hiddenMobileAssistantEditTabs = const <String>{};
  Set<String> get hiddenMobileAssistantEditTabs =>
      _hiddenMobileAssistantEditTabs;
  Future<void> setHiddenMobileAssistantEditTabs(Set<String> hidden) async {
    final sorted = hidden.toList()..sort();
    final next = Set<String>.unmodifiable(sorted);
    if (setEquals(_hiddenMobileAssistantEditTabs, next)) return;
    _hiddenMobileAssistantEditTabs = next;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setStringList(_mobileAssistantEditTabHiddenKey, sorted);
  }

  bool _mobileAssistantDetailOutlineEnabled = false;
  bool get mobileAssistantDetailOutlineEnabled =>
      _mobileAssistantDetailOutlineEnabled;
  Future<void> setMobileAssistantDetailOutlineEnabled(bool enabled) async {
    if (_mobileAssistantDetailOutlineEnabled == enabled) return;
    _mobileAssistantDetailOutlineEnabled = enabled;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_mobileAssistantDetailOutlineEnabledKey, enabled);
  }

  // ===== Android 后台聊天生成 =====
  AndroidBackgroundChatMode _androidBackgroundChatMode =
      AndroidBackgroundChatMode.off;
  AndroidBackgroundChatMode get androidBackgroundChatMode =>
      _androidBackgroundChatMode;
  Future<void> setAndroidBackgroundChatMode(
    AndroidBackgroundChatMode mode,
  ) async {
    if (_androidBackgroundChatMode == mode) return;
    _androidBackgroundChatMode = mode;
    notifyListeners();
    final prefs = _preferences;
    final v = switch (mode) {
      AndroidBackgroundChatMode.onNotify => 'on_notify',
      AndroidBackgroundChatMode.on => 'on',
      AndroidBackgroundChatMode.off => 'off',
    };
    await prefs.setString(_androidBackgroundChatModeKey, v);
    // 尽力而为：立即更新 Android 后台执行状态
    try {
      if (Platform.isAndroid) {
        // 直接调用；该文件已存在于项目中，并通过 Platform 进行平台判断
        // ignore: depend_on_referenced_packages
        // ignore_for_file: unnecessary_import
        // ignore: avoid_print
        // 此处无法延迟导入；依赖 main.dart 中的同步。这是一个 no-op 占位符。
      }
    } catch (_) {}
  }

  // ===== iOS 后台聊天生成 =====
  bool _iosBackgroundGenerationEnabled = false;
  bool get iosBackgroundGenerationEnabled => _iosBackgroundGenerationEnabled;
  Future<void> setIosBackgroundGenerationEnabled(bool v) async {
    if (_iosBackgroundGenerationEnabled == v) return;
    _iosBackgroundGenerationEnabled = v;
    if (!v) {
      _iosBackgroundTaskRefreshEnabled = false;
      _iosLiveActivityEnabled = false;
      _iosBackgroundNotificationsEnabled = false;
    }
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(
      _iosBackgroundGenerationEnabledKey,
      _iosBackgroundGenerationEnabled,
    );
    if (!v) {
      await prefs.setBool(_iosBackgroundTaskRefreshEnabledKey, false);
      await prefs.setBool(_iosLiveActivityEnabledKey, false);
      await prefs.setBool(_iosBackgroundNotificationsEnabledKey, false);
    }
  }

  bool _iosBackgroundTaskRefreshEnabled = false;
  bool get iosBackgroundTaskRefreshEnabled => _iosBackgroundTaskRefreshEnabled;
  Future<void> setIosBackgroundTaskRefreshEnabled(bool v) async {
    if (_iosBackgroundTaskRefreshEnabled == v) return;
    _iosBackgroundTaskRefreshEnabled = v;
    if (v) _iosBackgroundGenerationEnabled = true;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(
      _iosBackgroundTaskRefreshEnabledKey,
      _iosBackgroundTaskRefreshEnabled,
    );
    if (v) {
      await prefs.setBool(_iosBackgroundGenerationEnabledKey, true);
    }
  }

  bool _iosLiveActivityEnabled = false;
  bool get iosLiveActivityEnabled => _iosLiveActivityEnabled;
  Future<void> setIosLiveActivityEnabled(bool v) async {
    if (_iosLiveActivityEnabled == v) return;
    _iosLiveActivityEnabled = v;
    if (v) _iosBackgroundGenerationEnabled = true;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_iosLiveActivityEnabledKey, _iosLiveActivityEnabled);
    if (v) {
      await prefs.setBool(_iosBackgroundGenerationEnabledKey, true);
    }
  }

  bool _iosBackgroundNotificationsEnabled = false;
  bool get iosBackgroundNotificationsEnabled =>
      _iosBackgroundNotificationsEnabled;
  Future<void> setIosBackgroundNotificationsEnabled(bool v) async {
    if (_iosBackgroundNotificationsEnabled == v) return;
    _iosBackgroundNotificationsEnabled = v;
    if (v) _iosBackgroundGenerationEnabled = true;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(
      _iosBackgroundNotificationsEnabledKey,
      _iosBackgroundNotificationsEnabled,
    );
    if (v) {
      await prefs.setBool(_iosBackgroundGenerationEnabledKey, true);
    }
  }

  void setDynamicColorSupported(bool v) {
    if (_dynamicColorSupported == v) return;
    _dynamicColorSupported = v;
    notifyListeners();
  }

  Future<void> toggleTheme() => setThemeMode(
    _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
  );

  Future<void> followSystem() => setThemeMode(ThemeMode.system);

  Future<void> setProviderConfig(String key, ProviderConfig config) async {
    _providerConfigs[key] = config;
    notifyListeners();
    final prefs = _preferences;
    final map = _providerConfigs.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_providerConfigsKey, jsonEncode(map));
  }

  Future<int> deleteModels(String providerKey, Set<String> modelIds) async {
    if (modelIds.isEmpty) return 0;
    final old = _providerConfigs[providerKey];
    if (old == null) return 0;
    final deletedModelIds = old.models
        .where((modelId) => modelIds.contains(modelId))
        .toSet();
    if (deletedModelIds.isEmpty) return 0;
    final nextModels = old.models
        .where((modelId) => !deletedModelIds.contains(modelId))
        .toList();
    final deletedCount = old.models.length - nextModels.length;

    final nextOverrides = nextModels.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(old.modelOverrides);
    if (nextModels.isNotEmpty) {
      for (final modelId in deletedModelIds) {
        nextOverrides.remove(modelId);
      }
    }

    await setProviderConfig(
      providerKey,
      old.copyWith(models: nextModels, modelOverrides: nextOverrides),
    );
    for (final modelId in deletedModelIds) {
      await clearSelectionsForModel(providerKey, modelId);
    }
    return deletedCount;
  }

  // ===== 服务商头像 =====
  Future<void> setProviderAvatarEmoji(String key, String emoji) async {
    final e = emoji.trim();
    if (e.isEmpty) return;
    final old = getProviderConfig(key);
    await setProviderConfig(
      key,
      old.copyWith(avatarType: 'emoji', avatarValue: e),
    );
  }

  Future<void> setProviderAvatarUrl(String key, String url) async {
    final u = url.trim();
    if (u.isEmpty) return;
    final old = getProviderConfig(key);
    await setProviderConfig(
      key,
      old.copyWith(avatarType: 'url', avatarValue: u),
    );
    // 为离线使用预取
    try {
      await AvatarCache.getPath(u);
    } catch (_) {}
  }

  Future<void> setProviderAvatarFilePath(String key, String path) async {
    final p = path.trim();
    if (p.isEmpty) return;
    final fixedInput = SandboxPathResolver.fix(p);
    try {
      final src = File(fixedInput);
      if (!await src.exists()) return;
      final avatarsDir = await AppDirectories.getAvatarsDirectory();
      if (!await avatarsDir.exists()) {
        await avatarsDir.create(recursive: true);
      }
      String ext = '';
      final dot = fixedInput.lastIndexOf('.');
      if (dot != -1 && dot < fixedInput.length - 1) {
        ext = fixedInput.substring(dot + 1).toLowerCase();
        if (ext.length > 6) ext = 'jpg';
      } else {
        ext = 'jpg';
      }
      final safeKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final filename =
          'provider_${safeKey}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final dest = File('${avatarsDir.path}/$filename');
      await src.copy(dest.path);

      // 清理受管头像文件夹下的旧头像文件
      final old = getProviderConfig(key);
      if (old.avatarType == 'file' && (old.avatarValue ?? '').isNotEmpty) {
        try {
          final oldFile = File(old.avatarValue!);
          if ((oldFile.path.contains('/avatars/') ||
                  oldFile.path.contains('\\\\avatars\\\\')) &&
              await oldFile.exists()) {
            await oldFile.delete();
          }
        } catch (_) {}
      }

      await setProviderConfig(
        key,
        old.copyWith(avatarType: 'file', avatarValue: dest.path),
      );
    } catch (_) {
      // 回退：仍然保存原始路径
      final old = getProviderConfig(key);
      await setProviderConfig(
        key,
        old.copyWith(avatarType: 'file', avatarValue: fixedInput),
      );
    }
  }

  Future<void> setProviderAvatarIcon(String key, String asset) async {
    final normalized = BrandAssets.selectableAssetOrNull(asset.trim());
    if (normalized == null) return;
    final old = getProviderConfig(key);
    await setProviderConfig(
      key,
      old.copyWith(avatarType: 'icon', avatarValue: normalized),
    );
  }

  // 存储 LobeHub 图标名称（不是完整 URL）；URL 在渲染时构建。
  Future<void> setProviderAvatarLobehub(String key, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final old = getProviderConfig(key);
    await setProviderConfig(
      key,
      old.copyWith(avatarType: 'lobehub', avatarValue: trimmed),
    );
  }

  Future<void> resetProviderAvatar(String key) async {
    final old = getProviderConfig(key);
    // 如果旧本地文件由我们管理，则尝试将其删除
    if (old.avatarType == 'file' && (old.avatarValue ?? '').isNotEmpty) {
      try {
        final f = File(old.avatarValue!);
        if ((f.path.contains('/avatars/') ||
                f.path.contains('\\\\avatars\\\\')) &&
            await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
    // 尽力而为：清除缓存的 URL 头像
    if (old.avatarType == 'url' && (old.avatarValue ?? '').isNotEmpty) {
      try {
        await AvatarCache.evict(old.avatarValue!);
      } catch (_) {}
    }
    await setProviderConfig(
      key,
      old.copyWith(avatarType: null, avatarValue: null),
    );
  }

  /// 清除所有引用给定服务商的全局模型选择（current、title、translate、OCR）。
  /// 在服务商被禁用或删除时使用。
  Future<void> clearSelectionsForProvider(String providerKey) async {
    final prefs = _preferences;
    bool changed = false;
    if (_currentModelProvider == providerKey) {
      _currentModelProvider = null;
      _currentModelId = null;
      await prefs.remove(_selectedModelKey);
      changed = true;
    }
    if (_titleModelProvider == providerKey) {
      _titleModelProvider = null;
      _titleModelId = null;
      await prefs.remove(_titleModelKey);
      changed = true;
    }
    if (_translateModelProvider == providerKey) {
      _translateModelProvider = null;
      _translateModelId = null;
      await prefs.remove(_translateModelKey);
      changed = true;
    }
    if (_ocrModelProvider == providerKey) {
      _ocrModelProvider = null;
      _ocrModelId = null;
      _ocrEnabled = false;
      await prefs.remove(_ocrModelKey);
      await prefs.setBool(_ocrEnabledKey, false);
      changed = true;
    }
    if (_summaryModelProvider == providerKey) {
      _summaryModelProvider = null;
      _summaryModelId = null;
      await prefs.remove(_summaryModelKey);
      changed = true;
    }
    if (_suggestionModelProvider == providerKey) {
      _suggestionModelProvider = null;
      _suggestionModelId = null;
      await prefs.remove(_suggestionModelKey);
      changed = true;
    }
    if (_compressModelProvider == providerKey) {
      _compressModelProvider = null;
      _compressModelId = null;
      await prefs.remove(_compressModelKey);
      changed = true;
    }
    if (_memoryModelProvider == providerKey) {
      _memoryModelProvider = null;
      _memoryModelId = null;
      await prefs.remove(_memoryModelKey);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// 清除引用特定模型的全局模型选择。
  /// 在从提供程序删除模型时使用。
  Future<void> clearSelectionsForModel(
    String providerKey,
    String modelId,
  ) async {
    final prefs = _preferences;
    bool changed = false;
    if (_currentModelProvider == providerKey && _currentModelId == modelId) {
      _currentModelProvider = null;
      _currentModelId = null;
      await prefs.remove(_selectedModelKey);
      changed = true;
    }
    if (_titleModelProvider == providerKey && _titleModelId == modelId) {
      _titleModelProvider = null;
      _titleModelId = null;
      await prefs.remove(_titleModelKey);
      changed = true;
    }
    if (_translateModelProvider == providerKey &&
        _translateModelId == modelId) {
      _translateModelProvider = null;
      _translateModelId = null;
      await prefs.remove(_translateModelKey);
      changed = true;
    }
    if (_ocrModelProvider == providerKey && _ocrModelId == modelId) {
      _ocrModelProvider = null;
      _ocrModelId = null;
      _ocrEnabled = false;
      await prefs.remove(_ocrModelKey);
      await prefs.setBool(_ocrEnabledKey, false);
      changed = true;
    }
    if (_summaryModelProvider == providerKey && _summaryModelId == modelId) {
      _summaryModelProvider = null;
      _summaryModelId = null;
      await prefs.remove(_summaryModelKey);
      changed = true;
    }
    if (_suggestionModelProvider == providerKey &&
        _suggestionModelId == modelId) {
      _suggestionModelProvider = null;
      _suggestionModelId = null;
      await prefs.remove(_suggestionModelKey);
      changed = true;
    }
    if (_compressModelProvider == providerKey && _compressModelId == modelId) {
      _compressModelProvider = null;
      _compressModelId = null;
      await prefs.remove(_compressModelKey);
      changed = true;
    }
    if (_memoryModelProvider == providerKey && _memoryModelId == modelId) {
      _memoryModelProvider = null;
      _memoryModelId = null;
      await prefs.remove(_memoryModelKey);
      changed = true;
    }
    // 如果适用，也将其从置顶中移除
    final pinKey = '$providerKey::$modelId';
    if (_pinnedModels.contains(pinKey)) {
      _pinnedModels.remove(pinKey);
      await prefs.setStringList(_pinnedModelsKey, _pinnedModels.toList());
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> removeProviderConfig(String key) async {
    if (!_providerConfigs.containsKey(key)) return;
    _providerConfigs.remove(key);
    // 从排序中移除
    _providersOrder = List<String>.from(_providersOrder.where((k) => k != key));
    // 同时从分组映射中移除
    _providerGroupMap.remove(key);
    _cleanupProviderOrderAndGrouping();

    // 清除引用此提供程序的选择，以避免重新创建默认值
    final prefs = _preferences;
    if (_currentModelProvider == key) {
      _currentModelProvider = null;
      _currentModelId = null;
      await prefs.remove(_selectedModelKey);
    }
    if (_titleModelProvider == key) {
      _titleModelProvider = null;
      _titleModelId = null;
      await prefs.remove(_titleModelKey);
    }
    if (_translateModelProvider == key) {
      _translateModelProvider = null;
      _translateModelId = null;
      await prefs.remove(_translateModelKey);
    }
    if (_ocrModelProvider == key) {
      _ocrModelProvider = null;
      _ocrModelId = null;
      _ocrEnabled = false;
      await prefs.remove(_ocrModelKey);
      await prefs.setBool(_ocrEnabledKey, false);
    }
    if (_summaryModelProvider == key) {
      _summaryModelProvider = null;
      _summaryModelId = null;
      await prefs.remove(_summaryModelKey);
    }
    if (_suggestionModelProvider == key) {
      _suggestionModelProvider = null;
      _suggestionModelId = null;
      await prefs.remove(_suggestionModelKey);
    }
    if (_compressModelProvider == key) {
      _compressModelProvider = null;
      _compressModelId = null;
      await prefs.remove(_compressModelKey);
    }
    if (_memoryModelProvider == key) {
      _memoryModelProvider = null;
      _memoryModelId = null;
      await prefs.remove(_memoryModelKey);
    }

    // 移除此提供程序的置顶模型
    final beforePinned = _pinnedModels.length;
    _pinnedModels.removeWhere((entry) => entry.startsWith('$key::'));
    if (_pinnedModels.length != beforePinned) {
      await prefs.setStringList(_pinnedModelsKey, _pinnedModels.toList());
    }

    // 持久化更新
    final map = _providerConfigs.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_providerConfigsKey, jsonEncode(map));
    await prefs.setStringList(_providersOrderKey, _providersOrder);
    await prefs.setString(_providerGroupMapKey, jsonEncode(_providerGroupMap));
    notifyListeners();
  }

  // 收藏（置顶模型）
  final Set<String> _pinnedModels = <String>{};
  Set<String> get pinnedModels => Set.unmodifiable(_pinnedModels);
  bool isModelPinned(String providerKey, String modelId) =>
      _pinnedModels.contains('$providerKey::$modelId');
  Future<void> togglePinModel(String providerKey, String modelId) async {
    final k = '$providerKey::$modelId';
    if (_pinnedModels.contains(k)) {
      _pinnedModels.remove(k);
    } else {
      _pinnedModels.add(k);
    }
    notifyListeners();
    final prefs = _preferences;
    await prefs.setStringList(_pinnedModelsKey, _pinnedModels.toList());
  }

  // 用于聊天的所选模型
  String? _currentModelProvider;
  String? _currentModelId;
  String? get currentModelProvider => _currentModelProvider;
  String? get currentModelId => _currentModelId;
  String? get currentModelKey =>
      (_currentModelProvider != null && _currentModelId != null)
      ? '${_currentModelProvider!}::${_currentModelId!}'
      : null;
  Future<void> setCurrentModel(String providerKey, String modelId) async {
    _currentModelProvider = providerKey;
    _currentModelId = modelId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_selectedModelKey, '$providerKey::$modelId');
  }

  Future<void> resetCurrentModel() async {
    _currentModelProvider = null;
    _currentModelId = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_selectedModelKey);
  }

  // 标题模型和提示词
  String? _titleModelProvider;
  String? _titleModelId;
  String? get titleModelProvider => _titleModelProvider;
  String? get titleModelId => _titleModelId;
  bool get isTitleGenerationEnabled =>
      _titleModelProvider != null && _titleModelId != null;
  String? get titleModelKey =>
      (_titleModelProvider != null && _titleModelId != null)
      ? '${_titleModelProvider!}::${_titleModelId!}'
      : null;

  static const String defaultTitlePrompt =
      '''I will give you some dialogue content in the `<content>` block.
You need to summarize the conversation between user and assistant into a short title.
1. The title language should be consistent with the user's primary language
2. Do not use punctuation or other special symbols
3. Reply directly with the title
4. Summarize using {locale} language
5. The title should not exceed 10 characters

<content>
{content}
</content>''';

  String _titlePrompt = defaultTitlePrompt;
  String get titlePrompt => _titlePrompt;

  Future<void> setTitleModel(String providerKey, String modelId) async {
    _titleModelProvider = providerKey;
    _titleModelId = modelId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_titleModelKey, '$providerKey::$modelId');
  }

  Future<void> resetTitleModel() async {
    _titleModelProvider = null;
    _titleModelId = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_titleModelKey);
  }

  Future<void> setTitlePrompt(String prompt) async {
    _titlePrompt = prompt.trim().isEmpty ? defaultTitlePrompt : prompt;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_titlePromptKey, _titlePrompt);
  }

  Future<void> resetTitlePrompt() async => setTitlePrompt(defaultTitlePrompt);

  // 翻译模型和提示词
  String? _translateModelProvider;
  String? _translateModelId;
  String? get translateModelProvider => _translateModelProvider;
  String? get translateModelId => _translateModelId;
  String? get translateModelKey =>
      (_translateModelProvider != null && _translateModelId != null)
      ? '${_translateModelProvider!}::${_translateModelId!}'
      : null;

  static const String defaultTranslatePrompt =
      '''You are a translation expert, skilled in translating various languages, and maintaining accuracy, faithfulness, and elegance in translation.
Next, I will send you text. Please translate it into {target_lang}, and return the translation result directly, without adding any explanations or other content.

Please translate the <source_text> section:
<source_text>
{source_text}
</source_text>''';

  String _translatePrompt = defaultTranslatePrompt;
  String get translatePrompt => _translatePrompt;
  String? _translateTargetLang;
  String? get translateTargetLang => _translateTargetLang;

  Future<void> setTranslateModel(String providerKey, String modelId) async {
    _translateModelProvider = providerKey;
    _translateModelId = modelId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_translateModelKey, '$providerKey::$modelId');
  }

  Future<void> resetTranslateModel() async {
    _translateModelProvider = null;
    _translateModelId = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_translateModelKey);
  }

  Future<void> setTranslatePrompt(String prompt) async {
    _translatePrompt = prompt.trim().isEmpty ? defaultTranslatePrompt : prompt;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_translatePromptKey, _translatePrompt);
  }

  Future<void> resetTranslatePrompt() async =>
      setTranslatePrompt(defaultTranslatePrompt);
  Future<void> setTranslateTargetLang(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return;
    _translateTargetLang = trimmed;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_translateTargetLangKey, trimmed);
  }

  Future<void> resetTranslateTargetLang() async {
    _translateTargetLang = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_translateTargetLangKey);
  }

  // OCR 模型、提示词和开关
  String? _ocrModelProvider;
  String? _ocrModelId;
  String? get ocrModelProvider => _ocrModelProvider;
  String? get ocrModelId => _ocrModelId;
  String? get ocrModelKey => (_ocrModelProvider != null && _ocrModelId != null)
      ? '${_ocrModelProvider!}::${_ocrModelId!}'
      : null;

  static const String defaultOcrPrompt = '''You are an OCR assistant.

Extract all visible text from the image and also describe any non-text elements (icons, shapes, arrows, objects, symbols, or emojis).

For each element, specify:
- The exact text (for text) or a short description (for non-text).
- For document-type content, please use markdown and latex format.
- If there are objects like buildings or characters, try to identify who they are.
- Its approximate position in the image (e.g., 'top left', 'center right', 'bottom middle').
- Its spatial relationship to nearby elements (e.g., 'above', 'below', 'next to', 'on the left of').

Keep the original reading order and layout structure as much as possible.
Do not interpret or translate—only transcribe and describe what is visually present.''';

  String _ocrPrompt = defaultOcrPrompt;
  String get ocrPrompt => _ocrPrompt;

  bool _ocrEnabled = false;
  bool get ocrEnabled => _ocrEnabled;

  Future<void> setOcrModel(String providerKey, String modelId) async {
    _ocrModelProvider = providerKey;
    _ocrModelId = modelId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_ocrModelKey, '$providerKey::$modelId');
  }

  Future<void> resetOcrModel() async {
    _ocrModelProvider = null;
    _ocrModelId = null;
    _ocrEnabled = false;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_ocrModelKey);
    await prefs.setBool(_ocrEnabledKey, false);
  }

  Future<void> setOcrPrompt(String prompt) async {
    _ocrPrompt = prompt.trim();
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_ocrPromptKey, _ocrPrompt);
  }

  Future<void> resetOcrPrompt() async => setOcrPrompt(defaultOcrPrompt);

  Future<void> setOcrEnabled(bool value) async {
    // 如果没有配置 OCR 模型，则强制禁用。
    if (_ocrModelProvider == null || _ocrModelId == null) {
      value = false;
    }
    if (_ocrEnabled == value) return;
    _ocrEnabled = value;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_ocrEnabledKey, _ocrEnabled);
  }

  // 摘要模型和提示词
  String? _summaryModelProvider;
  String? _summaryModelId;
  String? get summaryModelProvider => _summaryModelProvider;
  String? get summaryModelId => _summaryModelId;
  String? get summaryModelKey =>
      (_summaryModelProvider != null && _summaryModelId != null)
      ? '${_summaryModelProvider!}::${_summaryModelId!}'
      : null;

  static const String defaultSummaryPrompt =
      '''I will give you user messages from a conversation in the `<messages>` block.
Generate or update a brief summary of the user's questions and intentions.

1. The summary should be in the same language as the user messages
2. Focus on the user's core questions and intentions
3. Keep it under 100 characters
4. Output the summary directly without any prefix
5. If a previous summary exists, incorporate it with the new messages

<previous_summary>
{previous_summary}
</previous_summary>

<messages>
{user_messages}
</messages>''';

  String _summaryPrompt = defaultSummaryPrompt;
  String get summaryPrompt => _summaryPrompt;

  Future<void> setSummaryModel(String providerKey, String modelId) async {
    _summaryModelProvider = providerKey;
    _summaryModelId = modelId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_summaryModelKey, '$providerKey::$modelId');
  }

  Future<void> resetSummaryModel() async {
    _summaryModelProvider = null;
    _summaryModelId = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_summaryModelKey);
  }

  Future<void> setSummaryPrompt(String prompt) async {
    _summaryPrompt = prompt.trim().isEmpty ? defaultSummaryPrompt : prompt;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_summaryPromptKey, _summaryPrompt);
  }

  Future<void> resetSummaryPrompt() async =>
      setSummaryPrompt(defaultSummaryPrompt);

  // 聊天建议模型和提示词。模型为 null 表示该功能已禁用。
  String? _suggestionModelProvider;
  String? _suggestionModelId;
  String? get suggestionModelProvider => _suggestionModelProvider;
  String? get suggestionModelId => _suggestionModelId;
  String? get suggestionModelKey =>
      (_suggestionModelProvider != null && _suggestionModelId != null)
      ? '${_suggestionModelProvider!}::${_suggestionModelId!}'
      : null;

  static const String defaultSuggestionPrompt =
      '''I will provide you with some chat content in the `<content>` block, including conversations between the User and the AI assistant.
You need to act as the User to continue the conversation, generating 3 appropriate and contextually relevant responses or questions to the assistant.

Rules:
1. Reply directly with suggestions, do not add any formatting, and separate suggestions with newlines.
2. Use {locale} language.
3. Ensure each suggestion is valid and useful for continuing the conversation.
4. Each suggestion should be concise.
5. Imitate the user's previous conversational style.
6. Act as a User, not an Assistant.

<content>
{content}
</content>''';

  String _suggestionPrompt = defaultSuggestionPrompt;
  String get suggestionPrompt => _suggestionPrompt;
  bool _insertSuggestionOnTapOnly = false;
  bool get insertSuggestionOnTapOnly => _insertSuggestionOnTapOnly;

  Future<void> setSuggestionModel(String providerKey, String modelId) async {
    _suggestionModelProvider = providerKey;
    _suggestionModelId = modelId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_suggestionModelKey, '$providerKey::$modelId');
  }

  Future<void> resetSuggestionModel() async {
    _suggestionModelProvider = null;
    _suggestionModelId = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_suggestionModelKey);
  }

  Future<void> setSuggestionPrompt(String prompt) async {
    _suggestionPrompt = prompt.trim().isEmpty
        ? defaultSuggestionPrompt
        : prompt;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_suggestionPromptKey, _suggestionPrompt);
  }

  Future<void> resetSuggestionPrompt() async =>
      setSuggestionPrompt(defaultSuggestionPrompt);

  Future<void> setInsertSuggestionOnTapOnly(bool value) async {
    if (_insertSuggestionOnTapOnly == value) return;
    _insertSuggestionOnTapOnly = value;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_suggestionInsertOnTapOnlyKey, value);
  }

  // 压缩模型和提示词
  String? _compressModelProvider;
  String? _compressModelId;
  String? get compressModelProvider => _compressModelProvider;
  String? get compressModelId => _compressModelId;
  String? get compressModelKey =>
      (_compressModelProvider != null && _compressModelId != null)
      ? '${_compressModelProvider!}::${_compressModelId!}'
      : null;

  static const String defaultCompressPrompt =
      '''Provide a detailed summary of the following conversation for continuing in a new session.

The new session will not have access to the original conversation history, so preserve all context needed to continue seamlessly.

Focus on:
- Key topics discussed and why they matter
- Important decisions made and their reasoning
- Current work in progress and its state
- Next steps or open questions to address
- Any relevant technical details, code snippets, or configurations mentioned

Requirements:
1. Write in {locale} language, matching the original conversation language
2. Be concise but complete — do not omit important context
3. Output the summary directly without prefaces or meta-commentary
4. Start with a clear indicator (e.g., "[Summary of previous conversation]" or equivalent)

<conversation>
{content}
</conversation>''';

  String _compressPrompt = defaultCompressPrompt;
  String get compressPrompt => _compressPrompt;

  CompressContextLimitMode _compressLimitMode = CompressContextLimitMode.start;
  CompressContextLimitMode get compressLimitMode => _compressLimitMode;
  int? _compressKeepUserMessages;
  int? get compressKeepUserMessages => _compressKeepUserMessages;
  int _compressMaxChars = CompressContextOptions.defaultMaxChars;
  int get compressMaxChars => _compressMaxChars;

  Future<void> setCompressModel(String providerKey, String modelId) async {
    _compressModelProvider = providerKey;
    _compressModelId = modelId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_compressModelKey, '$providerKey::$modelId');
  }

  Future<void> resetCompressModel() async {
    _compressModelProvider = null;
    _compressModelId = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_compressModelKey);
  }

  Future<void> setCompressLimitMode(CompressContextLimitMode mode) async {
    _compressLimitMode = mode;
    notifyListeners();
    await _preferences.setString(_compressLimitModeKey, mode.name);
  }

  Future<void> setCompressKeepUserMessages(int? count) async {
    _compressKeepUserMessages = count;
    notifyListeners();
    if (count == null) {
      await _preferences.remove(_compressKeepUserMessagesKey);
    } else {
      await _preferences.setInt(_compressKeepUserMessagesKey, count);
    }
  }

  Future<void> setCompressMaxChars(int maxChars) async {
    _compressMaxChars = maxChars;
    notifyListeners();
    await _preferences.setInt(_compressMaxCharsKey, maxChars);
  }

  Future<void> setCompressPrompt(String prompt) async {
    _compressPrompt = prompt.trim().isEmpty ? defaultCompressPrompt : prompt;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_compressPromptKey, _compressPrompt);
  }

  Future<void> resetCompressPrompt() async =>
      setCompressPrompt(defaultCompressPrompt);

  // 学习模式
  bool _learningModeEnabled = false;
  bool get learningModeEnabled => _learningModeEnabled;
  Future<void> setLearningModeEnabled(bool v) async {
    if (_learningModeEnabled == v) return;
    _learningModeEnabled = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_learningModeEnabledKey, v);
  }

  static const String defaultLearningModePrompt =
      LearningModeStore.defaultPrompt;

  String _learningModePrompt = defaultLearningModePrompt;
  String get learningModePrompt => _learningModePrompt;
  Future<void> setLearningModePrompt(String prompt) async {
    _learningModePrompt = prompt.trim().isEmpty
        ? defaultLearningModePrompt
        : prompt;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_learningModePromptKey, _learningModePrompt);
  }

  Future<void> resetLearningModePrompt() async =>
      setLearningModePrompt(defaultLearningModePrompt);

  // 推理强度 / 思考预算
  int? _thinkingBudget; // null = 未设置，使用提供商默认值；-1 = 自动；0 = 关闭；>0 = 预算 token
  int? get thinkingBudget => _thinkingBudget;
  Future<void> setThinkingBudget(int? budget) async {
    _thinkingBudget = budget;
    notifyListeners();
    final prefs = _preferences;
    if (budget == null) {
      await prefs.remove(_thinkingBudgetKey);
    } else {
      await prefs.setInt(_thinkingBudgetKey, budget);
    }
  }

  // 后台模型思考开关。默认全部关闭，以保持这些
  // 对延迟敏感的实用请求快速响应。
  bool _titleGenerationThinkingEnabled = false;
  bool get titleGenerationThinkingEnabled => _titleGenerationThinkingEnabled;
  Future<void> setTitleGenerationThinkingEnabled(bool enabled) async {
    if (_titleGenerationThinkingEnabled == enabled) return;
    _titleGenerationThinkingEnabled = enabled;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_titleGenerationThinkingEnabledKey, enabled);
  }

  Future<void> resetTitleGenerationThinkingEnabled() async =>
      setTitleGenerationThinkingEnabled(false);

  bool _summaryGenerationThinkingEnabled = false;
  bool get summaryGenerationThinkingEnabled =>
      _summaryGenerationThinkingEnabled;
  Future<void> setSummaryGenerationThinkingEnabled(bool enabled) async {
    if (_summaryGenerationThinkingEnabled == enabled) return;
    _summaryGenerationThinkingEnabled = enabled;
    notifyListeners();
    await _preferences.setBool(_summaryGenerationThinkingEnabledKey, enabled);
  }

  Future<void> resetSummaryGenerationThinkingEnabled() async =>
      setSummaryGenerationThinkingEnabled(false);

  bool _suggestionGenerationThinkingEnabled = false;
  bool get suggestionGenerationThinkingEnabled =>
      _suggestionGenerationThinkingEnabled;
  Future<void> setSuggestionGenerationThinkingEnabled(bool enabled) async {
    if (_suggestionGenerationThinkingEnabled == enabled) return;
    _suggestionGenerationThinkingEnabled = enabled;
    notifyListeners();
    await _preferences.setBool(
      _suggestionGenerationThinkingEnabledKey,
      enabled,
    );
  }

  Future<void> resetSuggestionGenerationThinkingEnabled() async =>
      setSuggestionGenerationThinkingEnabled(false);

  bool _compressGenerationThinkingEnabled = false;
  bool get compressGenerationThinkingEnabled =>
      _compressGenerationThinkingEnabled;
  Future<void> setCompressGenerationThinkingEnabled(bool enabled) async {
    if (_compressGenerationThinkingEnabled == enabled) return;
    _compressGenerationThinkingEnabled = enabled;
    notifyListeners();
    await _preferences.setBool(_compressGenerationThinkingEnabledKey, enabled);
  }

  Future<void> resetCompressGenerationThinkingEnabled() async =>
      setCompressGenerationThinkingEnabled(false);

  bool _translateGenerationThinkingEnabled = false;
  bool get translateGenerationThinkingEnabled =>
      _translateGenerationThinkingEnabled;
  Future<void> setTranslateGenerationThinkingEnabled(bool enabled) async {
    if (_translateGenerationThinkingEnabled == enabled) return;
    _translateGenerationThinkingEnabled = enabled;
    notifyListeners();
    await _preferences.setBool(_translateGenerationThinkingEnabledKey, enabled);
  }

  Future<void> resetTranslateGenerationThinkingEnabled() async =>
      setTranslateGenerationThinkingEnabled(false);

  bool _ocrGenerationThinkingEnabled = false;
  bool get ocrGenerationThinkingEnabled => _ocrGenerationThinkingEnabled;
  Future<void> setOcrGenerationThinkingEnabled(bool enabled) async {
    if (_ocrGenerationThinkingEnabled == enabled) return;
    _ocrGenerationThinkingEnabled = enabled;
    notifyListeners();
    await _preferences.setBool(_ocrGenerationThinkingEnabledKey, enabled);
  }

  Future<void> resetOcrGenerationThinkingEnabled() async =>
      setOcrGenerationThinkingEnabled(false);

  // 记忆系统 v1 (§4.2)
  String? _memoryModelProvider;
  String? _memoryModelId;
  String? get memoryModelProvider => _memoryModelProvider;
  String? get memoryModelId => _memoryModelId;
  String? get memoryModelKey =>
      (_memoryModelProvider != null && _memoryModelId != null)
      ? '${_memoryModelProvider!}::${_memoryModelId!}'
      : null;

  bool _memoryModelThinkingEnabled = false;
  bool get memoryModelThinkingEnabled => _memoryModelThinkingEnabled;

  /// 存储值：`auto` / `zh` / `en`。默认值为 `auto`。
  String _memoryPromptLang = 'auto';
  String get memoryPromptLang => _memoryPromptLang;

  /// 记录每次后台记忆运行的逐步跟踪。默认开启。
  bool _memoryTraceEnabled = true;
  bool get memoryTraceEnabled => _memoryTraceEnabled;

  bool _legacyMemoryMode = false;
  bool get legacyMemoryMode => _legacyMemoryMode;
  String _legacyMemoryPromptZh = MemoryPrompts.legacyRulesZh;
  String _legacyMemoryPromptEn = MemoryPrompts.legacyRulesEn;
  String get legacyMemoryPromptZh => _legacyMemoryPromptZh;
  String get legacyMemoryPromptEn => _legacyMemoryPromptEn;

  /// 界面实际渲染所使用的区域设置。
  ///
  /// [appLocale] 会解析存储的标签，而 `system` 标签没有可解析的
  /// 区域设置，因此会回退到 `en_US`。任何决定用什么语言
  /// 与用户交流的逻辑都必须询问平台。
  Locale get effectiveLocale =>
      isFollowingSystemLocale ? PlatformDispatcher.instance.locale : appLocale;

  /// 将 `auto` 解析为：界面为中文时 → zh，否则 → en。
  MemoryPromptLang get resolvedMemoryPromptLang {
    switch (_memoryPromptLang) {
      case 'zh':
        return MemoryPromptLang.zh;
      case 'en':
        return MemoryPromptLang.en;
      default:
        return effectiveLocale.languageCode == 'zh'
            ? MemoryPromptLang.zh
            : MemoryPromptLang.en;
    }
  }

  String _memoryRulesPromptZh = MemoryPrompts.rulesZh;
  String _memoryRulesPromptEn = MemoryPrompts.rulesEn;
  String _memoryGatePromptZh = MemoryPrompts.gateZh;
  String _memoryGatePromptEn = MemoryPrompts.gateEn;
  String _memoryExtractPromptZh = MemoryPrompts.extractZh;
  String _memoryExtractPromptEn = MemoryPrompts.extractEn;
  String _memorySmartAddPromptZh = MemoryPrompts.smartAddZh;
  String _memorySmartAddPromptEn = MemoryPrompts.smartAddEn;
  String _memorySmartAddBatchPromptZh = MemoryPrompts.smartAddBatchZh;
  String _memorySmartAddBatchPromptEn = MemoryPrompts.smartAddBatchEn;
  String _memoryProfileDistillPromptZh = MemoryPrompts.profileDistillZh;
  String _memoryProfileDistillPromptEn = MemoryPrompts.profileDistillEn;
  String _memoryMigratePromptZh = MemoryPrompts.migrateZh;
  String _memoryMigratePromptEn = MemoryPrompts.migrateEn;
  int _memoryMigrationBatchSize = defaultMemoryMigrationBatchSize;
  int _memoryInjectionMaxItems = defaultMemoryInjectionMaxItems;

  String get memoryRulesPromptZh => _memoryRulesPromptZh;
  String get memoryRulesPromptEn => _memoryRulesPromptEn;
  String get memoryGatePromptZh => _memoryGatePromptZh;
  String get memoryGatePromptEn => _memoryGatePromptEn;
  String get memoryExtractPromptZh => _memoryExtractPromptZh;
  String get memoryExtractPromptEn => _memoryExtractPromptEn;
  String get memorySmartAddPromptZh => _memorySmartAddPromptZh;
  String get memorySmartAddPromptEn => _memorySmartAddPromptEn;
  String get memorySmartAddBatchPromptZh => _memorySmartAddBatchPromptZh;
  String get memorySmartAddBatchPromptEn => _memorySmartAddBatchPromptEn;
  String get memoryProfileDistillPromptZh => _memoryProfileDistillPromptZh;
  String get memoryProfileDistillPromptEn => _memoryProfileDistillPromptEn;
  String get memoryMigratePromptZh => _memoryMigratePromptZh;
  String get memoryMigratePromptEn => _memoryMigratePromptEn;
  int get memoryMigrationBatchSize => _memoryMigrationBatchSize;
  int get memoryInjectionMaxItems => _memoryInjectionMaxItems;

  Future<void> setMemoryModel(String providerKey, String modelId) async {
    _memoryModelProvider = providerKey;
    _memoryModelId = modelId;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_memoryModelKey, '$providerKey::$modelId');
  }

  Future<void> resetMemoryModel() async {
    _memoryModelProvider = null;
    _memoryModelId = null;
    notifyListeners();
    final prefs = _preferences;
    await prefs.remove(_memoryModelKey);
  }

  Future<void> setMemoryModelThinkingEnabled(bool enabled) async {
    if (_memoryModelThinkingEnabled == enabled) return;
    _memoryModelThinkingEnabled = enabled;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_memoryModelThinkingEnabledKey, enabled);
  }

  /// 关闭此选项也会立即丢弃所有保留的跟踪记录。
  Future<void> setMemoryTraceEnabled(bool enabled) async {
    if (_memoryTraceEnabled == enabled) return;
    _memoryTraceEnabled = enabled;
    MemoryTraceRecorder.instance.setEnabled(enabled);
    notifyListeners();
    await _preferences.setBool(_memoryTraceEnabledKey, enabled);
  }

  Future<void> setLegacyMemoryMode(bool enabled) async {
    if (_legacyMemoryMode == enabled) return;
    _legacyMemoryMode = enabled;
    notifyListeners();
    await _preferences.setBool(_legacyMemoryModeKey, enabled);
  }

  Future<void> setLegacyMemoryPromptZh(String prompt) async {
    _legacyMemoryPromptZh = prompt.trim().isEmpty
        ? MemoryPrompts.legacyRulesZh
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _legacyMemoryPromptZhKey,
      _legacyMemoryPromptZh,
    );
  }

  Future<void> setLegacyMemoryPromptEn(String prompt) async {
    _legacyMemoryPromptEn = prompt.trim().isEmpty
        ? MemoryPrompts.legacyRulesEn
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _legacyMemoryPromptEnKey,
      _legacyMemoryPromptEn,
    );
  }

  Future<void> setMemoryPromptLang(String lang) async {
    final normalized = (lang == 'zh' || lang == 'en') ? lang : 'auto';
    if (_memoryPromptLang == normalized) return;
    _memoryPromptLang = normalized;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_memoryPromptLangKey, _memoryPromptLang);
  }

  Future<void> setMemoryRulesPromptZh(String prompt) async {
    _memoryRulesPromptZh = prompt.trim().isEmpty
        ? MemoryPrompts.rulesZh
        : prompt;
    notifyListeners();
    await _preferences.setString(_memoryRulesPromptZhKey, _memoryRulesPromptZh);
  }

  Future<void> setMemoryRulesPromptEn(String prompt) async {
    _memoryRulesPromptEn = prompt.trim().isEmpty
        ? MemoryPrompts.rulesEn
        : prompt;
    notifyListeners();
    await _preferences.setString(_memoryRulesPromptEnKey, _memoryRulesPromptEn);
  }

  Future<void> setMemoryGatePromptZh(String prompt) async {
    _memoryGatePromptZh = prompt.trim().isEmpty ? MemoryPrompts.gateZh : prompt;
    notifyListeners();
    await _preferences.setString(_memoryGatePromptZhKey, _memoryGatePromptZh);
  }

  Future<void> setMemoryGatePromptEn(String prompt) async {
    _memoryGatePromptEn = prompt.trim().isEmpty ? MemoryPrompts.gateEn : prompt;
    notifyListeners();
    await _preferences.setString(_memoryGatePromptEnKey, _memoryGatePromptEn);
  }

  Future<void> setMemoryExtractPromptZh(String prompt) async {
    _memoryExtractPromptZh = prompt.trim().isEmpty
        ? MemoryPrompts.extractZh
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memoryExtractPromptZhKey,
      _memoryExtractPromptZh,
    );
  }

  Future<void> setMemoryExtractPromptEn(String prompt) async {
    _memoryExtractPromptEn = prompt.trim().isEmpty
        ? MemoryPrompts.extractEn
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memoryExtractPromptEnKey,
      _memoryExtractPromptEn,
    );
  }

  Future<void> setMemorySmartAddPromptZh(String prompt) async {
    _memorySmartAddPromptZh = prompt.trim().isEmpty
        ? MemoryPrompts.smartAddZh
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memorySmartAddPromptZhKey,
      _memorySmartAddPromptZh,
    );
  }

  Future<void> setMemorySmartAddPromptEn(String prompt) async {
    _memorySmartAddPromptEn = prompt.trim().isEmpty
        ? MemoryPrompts.smartAddEn
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memorySmartAddPromptEnKey,
      _memorySmartAddPromptEn,
    );
  }

  Future<void> setMemorySmartAddBatchPromptZh(String prompt) async {
    _memorySmartAddBatchPromptZh = prompt.trim().isEmpty
        ? MemoryPrompts.smartAddBatchZh
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memorySmartAddBatchPromptZhKey,
      _memorySmartAddBatchPromptZh,
    );
  }

  Future<void> setMemorySmartAddBatchPromptEn(String prompt) async {
    _memorySmartAddBatchPromptEn = prompt.trim().isEmpty
        ? MemoryPrompts.smartAddBatchEn
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memorySmartAddBatchPromptEnKey,
      _memorySmartAddBatchPromptEn,
    );
  }

  Future<void> setMemoryProfileDistillPromptZh(String prompt) async {
    _memoryProfileDistillPromptZh = prompt.trim().isEmpty
        ? MemoryPrompts.profileDistillZh
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memoryProfileDistillPromptZhKey,
      _memoryProfileDistillPromptZh,
    );
  }

  Future<void> setMemoryProfileDistillPromptEn(String prompt) async {
    _memoryProfileDistillPromptEn = prompt.trim().isEmpty
        ? MemoryPrompts.profileDistillEn
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memoryProfileDistillPromptEnKey,
      _memoryProfileDistillPromptEn,
    );
  }

  Future<void> setMemoryMigratePromptZh(String prompt) async {
    _memoryMigratePromptZh = prompt.trim().isEmpty
        ? MemoryPrompts.migrateZh
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memoryMigratePromptZhKey,
      _memoryMigratePromptZh,
    );
  }

  Future<void> setMemoryMigratePromptEn(String prompt) async {
    _memoryMigratePromptEn = prompt.trim().isEmpty
        ? MemoryPrompts.migrateEn
        : prompt;
    notifyListeners();
    await _preferences.setString(
      _memoryMigratePromptEnKey,
      _memoryMigratePromptEn,
    );
  }

  Future<void> setMemoryMigrationBatchSize(int size) async {
    final next = size.clamp(
      minMemoryMigrationBatchSize,
      maxMemoryMigrationBatchSize,
    );
    if (_memoryMigrationBatchSize == next) return;
    _memoryMigrationBatchSize = next;
    notifyListeners();
    await _preferences.setInt(_memoryMigrationBatchSizeKey, next);
  }

  Future<void> setMemoryInjectionMaxItems(int size) async {
    final next = size.clamp(
      minMemoryInjectionMaxItems,
      maxMemoryInjectionMaxItems,
    );
    if (_memoryInjectionMaxItems == next) return;
    _memoryInjectionMaxItems = next;
    notifyListeners();
    await _preferences.setInt(_memoryInjectionMaxItemsKey, next);
  }

  Future<void> resetMemoryRulesPromptZh() async =>
      setMemoryRulesPromptZh(MemoryPrompts.rulesZh);
  Future<void> resetMemoryRulesPromptEn() async =>
      setMemoryRulesPromptEn(MemoryPrompts.rulesEn);
  Future<void> resetMemoryGatePromptZh() async =>
      setMemoryGatePromptZh(MemoryPrompts.gateZh);
  Future<void> resetMemoryGatePromptEn() async =>
      setMemoryGatePromptEn(MemoryPrompts.gateEn);
  Future<void> resetMemoryExtractPromptZh() async =>
      setMemoryExtractPromptZh(MemoryPrompts.extractZh);
  Future<void> resetMemoryExtractPromptEn() async =>
      setMemoryExtractPromptEn(MemoryPrompts.extractEn);
  Future<void> resetMemorySmartAddPromptZh() async =>
      setMemorySmartAddPromptZh(MemoryPrompts.smartAddZh);
  Future<void> resetMemorySmartAddPromptEn() async =>
      setMemorySmartAddPromptEn(MemoryPrompts.smartAddEn);
  Future<void> resetMemorySmartAddBatchPromptZh() async =>
      setMemorySmartAddBatchPromptZh(MemoryPrompts.smartAddBatchZh);
  Future<void> resetMemorySmartAddBatchPromptEn() async =>
      setMemorySmartAddBatchPromptEn(MemoryPrompts.smartAddBatchEn);
  Future<void> resetMemoryProfileDistillPromptZh() async =>
      setMemoryProfileDistillPromptZh(MemoryPrompts.profileDistillZh);
  Future<void> resetMemoryProfileDistillPromptEn() async =>
      setMemoryProfileDistillPromptEn(MemoryPrompts.profileDistillEn);
  Future<void> resetMemoryMigratePromptZh() async =>
      setMemoryMigratePromptZh(MemoryPrompts.migrateZh);
  Future<void> resetMemoryMigratePromptEn() async =>
      setMemoryMigratePromptEn(MemoryPrompts.migrateEn);
  Future<void> resetLegacyMemoryPromptZh() async =>
      setLegacyMemoryPromptZh(MemoryPrompts.legacyRulesZh);
  Future<void> resetLegacyMemoryPromptEn() async =>
      setLegacyMemoryPromptEn(MemoryPrompts.legacyRulesEn);

  int? titleGenerationThinkingBudgetFor(int? assistantBudget) {
    return _backgroundThinkingBudgetFor(
      _titleGenerationThinkingEnabled,
      assistantBudget,
    );
  }

  int? summaryGenerationThinkingBudgetFor(int? assistantBudget) =>
      _backgroundThinkingBudgetFor(
        _summaryGenerationThinkingEnabled,
        assistantBudget,
      );

  int? suggestionGenerationThinkingBudgetFor(int? assistantBudget) =>
      _backgroundThinkingBudgetFor(
        _suggestionGenerationThinkingEnabled,
        assistantBudget,
      );

  int? compressGenerationThinkingBudgetFor(int? assistantBudget) =>
      _backgroundThinkingBudgetFor(
        _compressGenerationThinkingEnabled,
        assistantBudget,
      );

  int? translateGenerationThinkingBudgetFor(int? assistantBudget) =>
      _backgroundThinkingBudgetFor(
        _translateGenerationThinkingEnabled,
        assistantBudget,
      );

  int? ocrGenerationThinkingBudgetFor(int? assistantBudget) =>
      _backgroundThinkingBudgetFor(
        _ocrGenerationThinkingEnabled,
        assistantBudget,
      );

  int? _backgroundThinkingBudgetFor(bool enabled, int? assistantBudget) {
    if (!enabled) return 0;
    return assistantBudget ?? _thinkingBudget;
  }

  // 显示设置：用户头像和模型图标的可见性
  bool _showUserAvatar = true;
  bool get showUserAvatar => _showUserAvatar;
  Future<void> setShowUserAvatar(bool v) async {
    if (_showUserAvatar == v) return;
    _showUserAvatar = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowUserAvatarKey, v);
  }

  // 显示：用户名和时间戳（用于用户消息）
  bool _showUserNameTimestamp = true;
  bool get showUserNameTimestamp => _showUserNameTimestamp;
  Future<void> setShowUserNameTimestamp(bool v) async {
    if (_showUserNameTimestamp == v) return;
    _showUserNameTimestamp = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowUserNameTimestampKey, v);
  }

  // 显示：仅用户名（用于用户消息）
  bool _showUserName = true;
  bool get showUserName => _showUserName;
  Future<void> setShowUserName(bool v) async {
    if (_showUserName == v) return;
    _showUserName = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowUserNameKey, v);
  }

  // 显示：仅时间戳（用于用户消息）
  bool _showUserTimestamp = true;
  bool get showUserTimestamp => _showUserTimestamp;
  Future<void> setShowUserTimestamp(bool v) async {
    if (_showUserTimestamp == v) return;
    _showUserTimestamp = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowUserTimestampKey, v);
  }

  bool _showUserMessageActions = true;
  bool get showUserMessageActions => _showUserMessageActions;
  Future<void> setShowUserMessageActions(bool v) async {
    if (_showUserMessageActions == v) return;
    _showUserMessageActions = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowUserMessageActionsKey, v);
  }

  bool _showModelIcon = true;
  bool get showModelIcon => _showModelIcon;
  Future<void> setShowModelIcon(bool v) async {
    if (_showModelIcon == v) return;
    _showModelIcon = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowModelIconKey, v);
  }

  // 显示：模型名称和时间戳（用于助手消息）
  bool _showModelNameTimestamp = true;
  bool get showModelNameTimestamp => _showModelNameTimestamp;
  Future<void> setShowModelNameTimestamp(bool v) async {
    if (_showModelNameTimestamp == v) return;
    _showModelNameTimestamp = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowModelNameTimestampKey, v);
  }

  // 显示：仅显示模型名称（用于助手消息）
  bool _showModelName = true;
  bool get showModelName => _showModelName;
  Future<void> setShowModelName(bool v) async {
    if (_showModelName == v) return;
    _showModelName = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowModelNameKey, v);
  }

  // 显示：仅显示模型时间戳（用于助手消息）
  bool _showModelTimestamp = true;
  bool get showModelTimestamp => _showModelTimestamp;
  Future<void> setShowModelTimestamp(bool v) async {
    if (_showModelTimestamp == v) return;
    _showModelTimestamp = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowModelTimestampKey, v);
  }

  // 显示：token/上下文统计
  bool _showTokenStats = true;
  bool get showTokenStats => _showTokenStats;
  Future<void> setShowTokenStats(bool v) async {
    if (_showTokenStats == v) return;
    _showTokenStats = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowTokenStatsKey, v);
  }

  // 显示：自动折叠推理/思考部分
  bool _autoCollapseThinking = true;
  bool get autoCollapseThinking => _autoCollapseThinking;
  Future<void> setAutoCollapseThinking(bool v) async {
    if (_autoCollapseThinking == v) return;
    _autoCollapseThinking = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayAutoCollapseThinkingKey, v);
  }

  bool _collapseThinkingSteps = false;
  bool get collapseThinkingSteps => _collapseThinkingSteps;
  Future<void> setCollapseThinkingSteps(bool v) async {
    if (_collapseThinkingSteps == v) return;
    _collapseThinkingSteps = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayCollapseThinkingStepsKey, v);
  }

  bool _showToolResultSummary = false;
  bool get showToolResultSummary => _showToolResultSummary;
  Future<void> setShowToolResultSummary(bool v) async {
    if (_showToolResultSummary == v) return;
    _showToolResultSummary = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowToolResultSummaryKey, v);
  }

  bool _showThinkingCards = true;
  bool get showThinkingCards => _showThinkingCards;
  Future<void> setShowThinkingCards(bool v) async {
    if (_showThinkingCards == v) return;
    _showThinkingCards = v;
    notifyListeners();
    await _preferences.setBool(_displayShowThinkingCardsKey, v);
  }

  bool _showToolCards = true;
  bool get showToolCards => _showToolCards;
  Future<void> setShowToolCards(bool v) async {
    if (_showToolCards == v) return;
    _showToolCards = v;
    notifyListeners();
    await _preferences.setBool(_displayShowToolCardsKey, v);
  }

  bool _hideToolResultImages = false;
  bool get hideToolResultImages => _hideToolResultImages;
  Future<void> setHideToolResultImages(bool v) async {
    if (_hideToolResultImages == v) return;
    _hideToolResultImages = v;
    notifyListeners();
    await _preferences.setBool(_displayHideToolResultImagesKey, v);
  }

  bool _showRegenerateConfirmDialog = true;
  bool get showRegenerateConfirmDialog => _showRegenerateConfirmDialog;
  Future<void> setShowRegenerateConfirmDialog(bool v) async {
    if (_showRegenerateConfirmDialog == v) return;
    _showRegenerateConfirmDialog = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowRegenerateConfirmDialogKey, v);
  }

  // 显示：显示消息导航按钮
  bool _showMessageNavButtons = true;
  bool get showMessageNavButtons => _showMessageNavButtons;
  Future<void> setShowMessageNavButtons(bool v) async {
    if (_showMessageNavButtons == v) return;
    _showMessageNavButtons = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowMessageNavKey, v);
  }

  // 显示：在应用栏中使用新的助手头像交互。
  bool _useNewAssistantAvatarUx = false;
  bool get useNewAssistantAvatarUx => _useNewAssistantAvatarUx;
  Future<void> setUseNewAssistantAvatarUx(bool v) async {
    if (_useNewAssistantAvatarUx == v) return;
    _useNewAssistantAvatarUx = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayUseNewAssistantAvatarUxKey, v);
  }

  // 显示：在模型胶囊中显示提供商名称（桌面端标题）
  bool _showProviderInModelCapsule = true;
  bool get showProviderInModelCapsule => _showProviderInModelCapsule;
  Future<void> setShowProviderInModelCapsule(bool v) async {
    if (_showProviderInModelCapsule == v) return;
    _showProviderInModelCapsule = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowProviderInModelCapsuleKey, v);
  }

  // 显示：在聊天消息中的模型 ID 后显示提供商名称
  bool _showProviderInChatMessage = false;
  bool get showProviderInChatMessage => _showProviderInChatMessage;
  Future<void> setShowProviderInChatMessage(bool v) async {
    if (_showProviderInChatMessage == v) return;
    _showProviderInChatMessage = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowProviderInChatMessageKey, v);
  }

  // 显示：应用启动时创建新聊天
  bool _newChatOnLaunch = false;
  bool get newChatOnLaunch => _newChatOnLaunch;
  Future<void> setNewChatOnLaunch(bool v) async {
    if (_newChatOnLaunch == v) return;
    _newChatOnLaunch = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayNewChatOnLaunchKey, v);
  }

  // 显示：切换助手时创建新聊天
  bool _newChatOnAssistantSwitch = false;
  bool get newChatOnAssistantSwitch => _newChatOnAssistantSwitch;
  Future<void> setNewChatOnAssistantSwitch(bool v) async {
    if (_newChatOnAssistantSwitch == v) return;
    _newChatOnAssistantSwitch = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayNewChatOnAssistantSwitchKey, v);
  }

  bool _insertNewAssistantAtTop = false;
  bool get insertNewAssistantAtTop => _insertNewAssistantAtTop;
  Future<void> setInsertNewAssistantAtTop(bool v) async {
    if (_insertNewAssistantAtTop == v) return;
    _insertNewAssistantAtTop = v;
    notifyListeners();
    await _preferences.setBool(_displayInsertNewAssistantAtTopKey, v);
  }

  bool _wideChatLayout = false;
  bool get wideChatLayout => _wideChatLayout;
  Future<void> setWideChatLayout(bool v) async {
    if (_wideChatLayout == v) return;
    _wideChatLayout = v;
    notifyListeners();
    await _preferences.setBool(_displayWideChatLayoutKey, v);
  }

  // 显示：删除一个聊天后创建新聊天
  bool _newChatAfterDelete = false;
  bool get newChatAfterDelete => _newChatAfterDelete;
  Future<void> setNewChatAfterDelete(bool v) async {
    if (_newChatAfterDelete == v) return;
    _newChatAfterDelete = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayNewChatAfterDeleteKey, v);
  }

  // 显示：移动端回车键发送消息（iOS 默认为 true，Android 默认为 false）
  bool _enterToSendOnMobile = false;
  bool get enterToSendOnMobile => _enterToSendOnMobile;
  Future<void> setEnterToSendOnMobile(bool v) async {
    if (_enterToSendOnMobile == v) return;
    _enterToSendOnMobile = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayEnterToSendOnMobileKey, v);
  }

  static const int defaultLongPasteAsFileThreshold = 5000;
  static const int minLongPasteAsFileThreshold = 1;
  static const int maxLongPasteAsFileThreshold = 999999;

  static int resolveLongPasteAsFileThreshold(
    String raw, {
    required int fallback,
  }) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return fallback;
    return parsed.clamp(
      minLongPasteAsFileThreshold,
      maxLongPasteAsFileThreshold,
    );
  }

  bool _longPasteAsFile = false;
  bool get longPasteAsFile => _longPasteAsFile;
  Future<void> setLongPasteAsFile(bool v) async {
    if (_longPasteAsFile == v) return;
    _longPasteAsFile = v;
    notifyListeners();
    await _preferences.setBool(_displayLongPasteAsFileKey, v);
  }

  int _longPasteAsFileThreshold = defaultLongPasteAsFileThreshold;
  int get longPasteAsFileThreshold => _longPasteAsFileThreshold;
  Future<void> setLongPasteAsFileThreshold(int v) async {
    final next = v.clamp(
      minLongPasteAsFileThreshold,
      maxLongPasteAsFileThreshold,
    );
    if (_longPasteAsFileThreshold == next) return;
    _longPasteAsFileThreshold = next;
    notifyListeners();
    await _preferences.setInt(_displayLongPasteAsFileThresholdKey, next);
  }

  // 桌面端：发送快捷键（Enter 或 Ctrl/Cmd+Enter）
  DesktopSendShortcut _desktopSendShortcut = DesktopSendShortcut.enter;
  DesktopSendShortcut get desktopSendShortcut => _desktopSendShortcut;
  Future<void> setDesktopSendShortcut(DesktopSendShortcut v) async {
    if (_desktopSendShortcut == v) return;
    _desktopSendShortcut = v;
    notifyListeners();
    final prefs = _preferences;
    final str = v == DesktopSendShortcut.ctrlEnter ? 'ctrlEnter' : 'enter';
    await prefs.setString(_desktopSendShortcutKey, str);
  }

  // 桌面端：消息导航按钮可见性模式
  DesktopMessageNavButtonsMode _desktopMessageNavButtonsMode =
      DesktopMessageNavButtonsMode.scroll;
  DesktopMessageNavButtonsMode get desktopMessageNavButtonsMode =>
      _desktopMessageNavButtonsMode;

  Future<void> setDesktopMessageNavButtonsMode(
    DesktopMessageNavButtonsMode mode,
  ) async {
    if (_desktopMessageNavButtonsMode == mode) return;
    _desktopMessageNavButtonsMode = mode;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(
      _displayDesktopMessageNavButtonsModeKey,
      _desktopMessageNavButtonsModeToString(mode),
    );
  }

  DesktopMessageNavButtonsMode _parseDesktopMessageNavButtonsMode(
    String? raw, {
    required bool legacyEnabled,
  }) {
    switch (raw) {
      case 'always':
        return DesktopMessageNavButtonsMode.always;
      case 'scroll':
        return DesktopMessageNavButtonsMode.scroll;
      case 'hover':
        return DesktopMessageNavButtonsMode.hover;
      case 'scrollAndHover':
        return DesktopMessageNavButtonsMode.scrollAndHover;
      case 'never':
        return DesktopMessageNavButtonsMode.never;
      default:
        return legacyEnabled
            ? DesktopMessageNavButtonsMode.scroll
            : DesktopMessageNavButtonsMode.never;
    }
  }

  String _desktopMessageNavButtonsModeToString(
    DesktopMessageNavButtonsMode mode,
  ) {
    switch (mode) {
      case DesktopMessageNavButtonsMode.always:
        return 'always';
      case DesktopMessageNavButtonsMode.scroll:
        return 'scroll';
      case DesktopMessageNavButtonsMode.hover:
        return 'hover';
      case DesktopMessageNavButtonsMode.scrollAndHover:
        return 'scrollAndHover';
      case DesktopMessageNavButtonsMode.never:
        return 'never';
    }
  }

  // 移动端：消息导航按钮可见性模式
  MobileMessageNavButtonsMode _mobileMessageNavButtonsMode =
      MobileMessageNavButtonsMode.scroll;
  MobileMessageNavButtonsMode get mobileMessageNavButtonsMode =>
      _mobileMessageNavButtonsMode;

  Future<void> setMobileMessageNavButtonsMode(
    MobileMessageNavButtonsMode mode,
  ) async {
    if (_mobileMessageNavButtonsMode == mode) return;
    _mobileMessageNavButtonsMode = mode;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(
      _displayMobileMessageNavButtonsModeKey,
      _mobileMessageNavButtonsModeToString(mode),
    );
  }

  MobileMessageNavButtonsMode _parseMobileMessageNavButtonsMode(
    String? raw, {
    required bool legacyEnabled,
  }) {
    switch (raw) {
      case 'always':
        return MobileMessageNavButtonsMode.always;
      case 'scroll':
        return MobileMessageNavButtonsMode.scroll;
      case 'never':
        return MobileMessageNavButtonsMode.never;
      default:
        return legacyEnabled
            ? MobileMessageNavButtonsMode.scroll
            : MobileMessageNavButtonsMode.never;
    }
  }

  String _mobileMessageNavButtonsModeToString(
    MobileMessageNavButtonsMode mode,
  ) {
    switch (mode) {
      case MobileMessageNavButtonsMode.always:
        return 'always';
      case MobileMessageNavButtonsMode.scroll:
        return 'scroll';
      case MobileMessageNavButtonsMode.never:
        return 'never';
    }
  }

  // 显示：聊天字体缩放（0.5 - 1.5，默认 1.0）
  double _chatFontScale = 1.0;
  double get chatFontScale => _chatFontScale;
  Future<void> setChatFontScale(double scale) async {
    final s = scale.clamp(0.5, 1.5);
    if (_chatFontScale == s) return;
    _chatFontScale = s;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_displayChatFontScaleKey, _chatFontScale);
  }

  // 显示：自动滚动回底部开关
  bool _autoScrollEnabled = true;
  bool get autoScrollEnabled => _autoScrollEnabled;
  Future<void> setAutoScrollEnabled(bool v) async {
    if (_autoScrollEnabled == v) return;
    _autoScrollEnabled = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayAutoScrollEnabledKey, v);
  }

  // 显示：自动滚动回底部的空闲超时（秒）
  int _autoScrollIdleSeconds = 8;
  int get autoScrollIdleSeconds => _autoScrollIdleSeconds;
  Future<void> setAutoScrollIdleSeconds(int seconds) async {
    final v = seconds.clamp(2, 64);
    if (_autoScrollIdleSeconds == v) return;
    _autoScrollIdleSeconds = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setInt(
      _displayAutoScrollIdleSecondsKey,
      _autoScrollIdleSeconds,
    );
  }

  // 显示：聊天背景遮罩强度（0.0 - 2.0，默认 1.0）
  double _chatBackgroundMaskStrength = 1.0;
  double get chatBackgroundMaskStrength => _chatBackgroundMaskStrength;
  Future<void> setChatBackgroundMaskStrength(double strength) async {
    final s = strength.clamp(0.0, 2.0);
    if (_chatBackgroundMaskStrength == s) return;
    _chatBackgroundMaskStrength = s;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setDouble(
      _displayChatBackgroundMaskStrengthKey,
      _chatBackgroundMaskStrength,
    );
  }

  // 显示：聊天输入框背景不透明度按主题亮度设置。
  static const double defaultChatInputBackgroundOpacityLight = 0.8236;
  static const double defaultChatInputBackgroundOpacityDark = 0.7396;
  double _chatInputBackgroundOpacityLight =
      defaultChatInputBackgroundOpacityLight;
  double _chatInputBackgroundOpacityDark =
      defaultChatInputBackgroundOpacityDark;
  double get chatInputBackgroundOpacityLight =>
      _chatInputBackgroundOpacityLight;
  double get chatInputBackgroundOpacityDark => _chatInputBackgroundOpacityDark;

  double chatInputBackgroundOpacityFor(Brightness brightness) {
    return brightness == Brightness.dark
        ? _chatInputBackgroundOpacityDark
        : _chatInputBackgroundOpacityLight;
  }

  Future<void> setChatInputBackgroundOpacity(
    Brightness brightness,
    double opacity,
  ) async {
    final v = opacity.clamp(0.0, 1.0);
    if (brightness == Brightness.dark) {
      if (_chatInputBackgroundOpacityDark == v) return;
      _chatInputBackgroundOpacityDark = v;
    } else {
      if (_chatInputBackgroundOpacityLight == v) return;
      _chatInputBackgroundOpacityLight = v;
    }
    notifyListeners();
    final prefs = _preferences;
    await prefs.setDouble(
      brightness == Brightness.dark
          ? _displayChatInputBackgroundOpacityDarkKey
          : _displayChatInputBackgroundOpacityLightKey,
      v,
    );
  }

  // 显示：内联 $...$ LaTeX 渲染
  bool _enableDollarLatex = true;
  bool get enableDollarLatex => _enableDollarLatex;
  Future<void> setEnableDollarLatex(bool v) async {
    if (_enableDollarLatex == v) return;
    _enableDollarLatex = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayEnableDollarLatexKey, v);
  }

  // 显示：LaTeX 数学公式渲染（内联/块级）
  bool _enableMathRendering = true;
  bool get enableMathRendering => _enableMathRendering;
  Future<void> setEnableMathRendering(bool v) async {
    if (_enableMathRendering == v) return;
    _enableMathRendering = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayEnableMathRenderingKey, v);
  }

  // 显示：使用 Markdown 渲染用户消息
  bool _enableUserMarkdown = true;
  bool get enableUserMarkdown => _enableUserMarkdown;
  Future<void> setEnableUserMarkdown(bool v) async {
    if (_enableUserMarkdown == v) return;
    _enableUserMarkdown = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayEnableUserMarkdownKey, v);
  }

  // 显示：使用 Markdown 渲染推理（思考）内容
  bool _enableReasoningMarkdown = true;
  bool get enableReasoningMarkdown => _enableReasoningMarkdown;
  Future<void> setEnableReasoningMarkdown(bool v) async {
    if (_enableReasoningMarkdown == v) return;
    _enableReasoningMarkdown = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayEnableReasoningMarkdownKey, v);
  }

  // 显示：使用 Markdown 渲染助手消息
  bool _enableAssistantMarkdown = true;
  bool get enableAssistantMarkdown => _enableAssistantMarkdown;
  Future<void> setEnableAssistantMarkdown(bool v) async {
    if (_enableAssistantMarkdown == v) return;
    _enableAssistantMarkdown = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayEnableAssistantMarkdownKey, v);
  }

  // 显示：显示聊天列表日期
  bool _showChatListDate = false;
  bool get showChatListDate => _showChatListDate;
  Future<void> setShowChatListDate(bool v) async {
    if (_showChatListDate == v) return;
    _showChatListDate = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowChatListDateKey, v);
  }

  // 显示：从相册或相机选择后裁剪图片
  bool _imageCropperEnabled = false;
  bool get imageCropperEnabled => _imageCropperEnabled;
  Future<void> setImageCropperEnabled(bool v) async {
    if (_imageCropperEnabled == v) return;
    _imageCropperEnabled = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_imageCropperEnabledKey, v);
  }

  ImageUploadQuality _imageUploadQuality = ImageUploadQuality.balanced;
  ImageUploadQuality get imageUploadQuality => _imageUploadQuality;
  Future<void> setImageUploadQuality(ImageUploadQuality value) async {
    if (_imageUploadQuality == value) return;
    _imageUploadQuality = value;
    notifyListeners();
    await _preferences.setString(_imageUploadQualityKey, value.name);
  }

  int _imageCompressCustomQuality = 85;
  int get imageCompressCustomQuality => _imageCompressCustomQuality;
  Future<void> setImageCompressCustomQuality(int value) async {
    final next = value.clamp(10, 100);
    if (_imageCompressCustomQuality == next) return;
    _imageCompressCustomQuality = next;
    notifyListeners();
    await _preferences.setInt(_imageCompressCustomQualityKey, next);
  }

  bool _imageCompressTransparentEnabled = false;
  bool get imageCompressTransparentEnabled => _imageCompressTransparentEnabled;
  Future<void> setImageCompressTransparentEnabled(bool value) async {
    if (_imageCompressTransparentEnabled == value) return;
    _imageCompressTransparentEnabled = value;
    notifyListeners();
    await _preferences.setBool(_imageCompressTransparentEnabledKey, value);
  }

  ImageCompressConfig resolveImageCompressConfig() {
    return switch (_imageUploadQuality) {
      ImageUploadQuality.original => ImageCompressConfig(
        enabled: false,
        quality: 100,
        maxLongEdge: 1568,
        includeTransparent: _imageCompressTransparentEnabled,
      ),
      ImageUploadQuality.high => ImageCompressConfig(
        enabled: true,
        quality: 90,
        maxLongEdge: 2048,
        includeTransparent: _imageCompressTransparentEnabled,
      ),
      ImageUploadQuality.balanced => ImageCompressConfig(
        enabled: true,
        quality: 85,
        maxLongEdge: 1568,
        includeTransparent: _imageCompressTransparentEnabled,
      ),
      ImageUploadQuality.saver => ImageCompressConfig(
        enabled: true,
        quality: 70,
        maxLongEdge: 1024,
        includeTransparent: _imageCompressTransparentEnabled,
      ),
      ImageUploadQuality.custom => ImageCompressConfig(
        enabled: true,
        quality: _imageCompressCustomQuality,
        maxLongEdge: 1568,
        includeTransparent: _imageCompressTransparentEnabled,
      ),
    };
  }

  // 显示：移动端代码块自动换行
  bool _mobileCodeBlockWrap = false;
  bool get mobileCodeBlockWrap => _mobileCodeBlockWrap;
  Future<void> setMobileCodeBlockWrap(bool v) async {
    if (_mobileCodeBlockWrap == v) return;
    _mobileCodeBlockWrap = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayMobileCodeBlockWrapKey, v);
  }

  // 显示：自动折叠代码块
  bool _autoCollapseCodeBlock = false;
  bool get autoCollapseCodeBlock => _autoCollapseCodeBlock;
  Future<void> setAutoCollapseCodeBlock(bool v) async {
    if (_autoCollapseCodeBlock == v) return;
    _autoCollapseCodeBlock = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayAutoCollapseCodeBlockKey, v);
  }

  // 显示：代码块自动折叠阈值（行数）
  int _autoCollapseCodeBlockLines = 2;
  int get autoCollapseCodeBlockLines => _autoCollapseCodeBlockLines;
  Future<void> setAutoCollapseCodeBlockLines(int v) async {
    final next = v.clamp(1, 999);
    if (_autoCollapseCodeBlockLines == next) return;
    _autoCollapseCodeBlockLines = next;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setInt(_displayAutoCollapseCodeBlockLinesKey, next);
  }

  // 仅桌面端：切换助手时自动切到“话题”标签页
  bool _desktopAutoSwitchTopics = false;
  bool get desktopAutoSwitchTopics => _desktopAutoSwitchTopics;
  Future<void> setDesktopAutoSwitchTopics(bool v) async {
    if (_desktopAutoSwitchTopics == v) return;
    _desktopAutoSwitchTopics = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayDesktopAutoSwitchTopicsKey, v);
  }

  // 仅桌面端：显示系统托盘图标
  bool _desktopShowTray = false;
  bool get desktopShowTray => _desktopShowTray;
  Future<void> setDesktopShowTray(bool v) async {
    if (_desktopShowTray == v) return;
    _desktopShowTray = v;
    if (!_desktopShowTray && _desktopMinimizeToTrayOnClose) {
      _desktopMinimizeToTrayOnClose = false;
    }
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayDesktopShowTrayKey, _desktopShowTray);
    await prefs.setBool(
      _displayDesktopMinimizeToTrayOnCloseKey,
      _desktopMinimizeToTrayOnClose,
    );
  }

  // 仅桌面端：关闭窗口时最小化到托盘
  bool _desktopMinimizeToTrayOnClose = false;
  bool get desktopMinimizeToTrayOnClose => _desktopMinimizeToTrayOnClose;
  Future<void> setDesktopMinimizeToTrayOnClose(bool v) async {
    final next = _desktopShowTray ? v : false;
    if (_desktopMinimizeToTrayOnClose == next) return;
    _desktopMinimizeToTrayOnClose = next;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(
      _displayDesktopMinimizeToTrayOnCloseKey,
      _desktopMinimizeToTrayOnClose,
    );
  }

  // 显示：消息生成时触发触感反馈
  bool _hapticsOnGenerate = false;
  bool get hapticsOnGenerate => _hapticsOnGenerate;
  Future<void> setHapticsOnGenerate(bool v) async {
    if (_hapticsOnGenerate == v) return;
    _hapticsOnGenerate = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayHapticsOnGenerateKey, v);
  }

  // 显示：生成时保持移动端屏幕常亮
  bool _keepScreenOnDuringGeneration = false;
  bool get keepScreenOnDuringGeneration => _keepScreenOnDuringGeneration;
  Future<void> setKeepScreenOnDuringGeneration(bool v) async {
    if (_keepScreenOnDuringGeneration == v) return;
    _keepScreenOnDuringGeneration = v;
    ScreenWakelock.setEnabled(v);
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayKeepScreenOnDuringGenerationKey, v);
  }

  // 显示：抽屉打开/关闭时触发触感反馈
  bool _hapticsOnDrawer = true;
  bool get hapticsOnDrawer => _hapticsOnDrawer;
  Future<void> setHapticsOnDrawer(bool v) async {
    if (_hapticsOnDrawer == v) return;
    _hapticsOnDrawer = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayHapticsOnDrawerKey, v);
  }

  // 显示：全局触感反馈总开关
  bool _hapticsGlobalEnabled = true;
  bool get hapticsGlobalEnabled => _hapticsGlobalEnabled;
  Future<void> setHapticsGlobalEnabled(bool v) async {
    if (_hapticsGlobalEnabled == v) return;
    _hapticsGlobalEnabled = v;
    // 立即应用到服务
    Haptics.setEnabled(v);
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayHapticsGlobalEnabledKey, v);
  }

  // 显示：仅 iOS 风格开关的触感反馈
  bool _hapticsIosSwitch = true;
  bool get hapticsIosSwitch => _hapticsIosSwitch;
  Future<void> setHapticsIosSwitch(bool v) async {
    if (_hapticsIosSwitch == v) return;
    _hapticsIosSwitch = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayHapticsIosSwitchKey, v);
  }

  // 显示：列表项点击触感反馈（例如设置页中的行）
  bool _hapticsOnListItemTap = true;
  bool get hapticsOnListItemTap => _hapticsOnListItemTap;
  Future<void> setHapticsOnListItemTap(bool v) async {
    if (_hapticsOnListItemTap == v) return;
    _hapticsOnListItemTap = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayHapticsOnListItemTapKey, v);
  }

  // 显示：卡片点击触感反馈（例如助手卡片等）
  bool _hapticsOnCardTap = true;
  bool get hapticsOnCardTap => _hapticsOnCardTap;
  Future<void> setHapticsOnCardTap(bool v) async {
    if (_hapticsOnCardTap == v) return;
    _hapticsOnCardTap = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayHapticsOnCardTapKey, v);
  }

  // 显示：显示应用更新通知
  bool _showAppUpdates = true;
  bool get showAppUpdates => _showAppUpdates;
  Future<void> setShowAppUpdates(bool v) async {
    if (_showAppUpdates == v) return;
    _showAppUpdates = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayShowAppUpdatesKey, v);
  }

  // 显示：选择助手时保持侧边栏打开（移动端）
  bool _keepSidebarOpenOnAssistantTap = false;
  bool get keepSidebarOpenOnAssistantTap => _keepSidebarOpenOnAssistantTap;
  Future<void> setKeepSidebarOpenOnAssistantTap(bool v) async {
    if (_keepSidebarOpenOnAssistantTap == v) return;
    _keepSidebarOpenOnAssistantTap = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayKeepSidebarOpenOnAssistantTapKey, v);
  }

  // 显示：切换话题时保持侧边栏打开（移动端）
  bool _keepSidebarOpenOnTopicTap = false;
  bool get keepSidebarOpenOnTopicTap => _keepSidebarOpenOnTopicTap;
  Future<void> setKeepSidebarOpenOnTopicTap(bool v) async {
    if (_keepSidebarOpenOnTopicTap == v) return;
    _keepSidebarOpenOnTopicTap = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayKeepSidebarOpenOnTopicTapKey, v);
  }

  // 显示：关闭侧边栏时保持助手列表展开（移动端）
  bool _keepAssistantListExpandedOnSidebarClose = false;
  bool get keepAssistantListExpandedOnSidebarClose =>
      _keepAssistantListExpandedOnSidebarClose;
  Future<void> setKeepAssistantListExpandedOnSidebarClose(bool v) async {
    if (_keepAssistantListExpandedOnSidebarClose == v) return;
    _keepAssistantListExpandedOnSidebarClose = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_displayKeepAssistantListExpandedOnSidebarCloseKey, v);
  }

  // 网络：请求日志记录（调试）
  bool _requestLogEnabled = true;
  bool get requestLogEnabled => _requestLogEnabled;
  Future<void> setRequestLogEnabled(bool v) async {
    if (_requestLogEnabled == v) return;
    _requestLogEnabled = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_requestLogEnabledKey, v);
    await RequestLogger.setEnabled(v);
  }

  bool _contextLogEnabled = true;
  bool get contextLogEnabled => _contextLogEnabled;
  Future<void> setContextLogEnabled(bool v) async {
    if (_contextLogEnabled == v) return;
    _contextLogEnabled = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_contextLogEnabledKey, v);
    await ContextLogger.setEnabled(v);
  }

  // Flutter：运行时日志记录（调试）
  bool _flutterLogEnabled = false;
  bool get flutterLogEnabled => _flutterLogEnabled;
  Future<void> setFlutterLogEnabled(bool v) async {
    if (_flutterLogEnabled == v) return;
    _flutterLogEnabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_flutterLogEnabledKey, v);
    await FlutterLogger.setEnabled(v);
  }

  Future<void> incrementAppLaunchCount() async {
    final prefs = _preferences;
    final next = (prefs.getInt(_appLaunchCountKey) ?? _appLaunchCount) + 1;
    _appLaunchCount = next;
    await prefs.setInt(_appLaunchCountKey, next);
    notifyListeners();
  }

  // 日志设置：保存输出
  bool _logSaveOutput = false;
  bool get logSaveOutput => _logSaveOutput;
  Future<void> setLogSaveOutput(bool v) async {
    if (_logSaveOutput == v) return;
    _logSaveOutput = v;
    RequestLogger.saveOutput = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_logSaveOutputKey, v);
  }

  // 日志设置：省略内联 base64 图片/文件
  bool _logElideLargePayloads = true;
  bool get logElideLargePayloads => _logElideLargePayloads;
  Future<void> setLogElideLargePayloads(bool v) async {
    if (_logElideLargePayloads == v) return;
    _logElideLargePayloads = v;
    RequestLogger.elideLargePayloads = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_logElideLargePayloadsKey, v);
  }

  // 日志设置：自动删除（天）
  int _logAutoDeleteDays = 0;
  int get logAutoDeleteDays => _logAutoDeleteDays;
  Future<void> setLogAutoDeleteDays(int v) async {
    if (_logAutoDeleteDays == v) return;
    _logAutoDeleteDays = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setInt(_logAutoDeleteDaysKey, v);
    RequestLogger.cleanupLogs(autoDeleteDays: v, maxSizeMB: _logMaxSizeMB);
  }

  // 日志设置：最大日志大小（MB）
  int _logMaxSizeMB = 50;
  int get logMaxSizeMB => _logMaxSizeMB;
  Future<void> setLogMaxSizeMB(int v) async {
    if (_logMaxSizeMB == v) return;
    _logMaxSizeMB = v;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setInt(_logMaxSizeMBKey, v);
    RequestLogger.cleanupLogs(autoDeleteDays: _logAutoDeleteDays, maxSizeMB: v);
  }

  // 搜索服务设置
  Future<void> setSearchServices(List<SearchServiceOptions> services) async {
    _searchServices = List.from(services);
    if (_searchServiceSelected >= _searchServices.length) {
      _searchServiceSelected = _searchServices.isNotEmpty
          ? _searchServices.length - 1
          : 0;
    }
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(
      _searchServicesKey,
      jsonEncode(_searchServices.map((e) => e.toJson()).toList()),
    );
    await prefs.setInt(_searchSelectedKey, _searchServiceSelected);
  }

  Future<void> setSearchCommonOptions(SearchCommonOptions options) async {
    _searchCommonOptions = options;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setString(_searchCommonKey, jsonEncode(options.toJson()));
  }

  Future<void> setSearchServiceSelected(int index) async {
    _searchServiceSelected = index.clamp(
      0,
      _searchServices.isNotEmpty ? _searchServices.length - 1 : 0,
    );
    notifyListeners();
    final prefs = _preferences;
    await prefs.setInt(_searchSelectedKey, _searchServiceSelected);
  }

  Future<void> setSearchEnabled(bool enabled) async {
    _searchEnabled = enabled;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_searchEnabledKey, enabled);
  }

  Future<void> setSearchAutoTestOnLaunch(bool enabled) async {
    _searchAutoTestOnLaunch = enabled;
    notifyListeners();
    final prefs = _preferences;
    await prefs.setBool(_searchAutoTestOnLaunchKey, enabled);
  }

  // 用于设置的组合更新
  Future<void> updateSettings(SettingsProvider newSettings) async {
    if (!listEquals(_searchServices, newSettings._searchServices)) {
      await setSearchServices(newSettings._searchServices);
    }
    if (_searchCommonOptions != newSettings._searchCommonOptions) {
      await setSearchCommonOptions(newSettings._searchCommonOptions);
    }
    if (_searchServiceSelected != newSettings._searchServiceSelected) {
      await setSearchServiceSelected(newSettings._searchServiceSelected);
    }
    if (_searchEnabled != newSettings._searchEnabled) {
      await setSearchEnabled(newSettings._searchEnabled);
    }
    if (_searchAutoTestOnLaunch != newSettings._searchAutoTestOnLaunch) {
      await setSearchAutoTestOnLaunch(newSettings._searchAutoTestOnLaunch);
    }
  }

  SettingsProvider copyWith({
    List<SearchServiceOptions>? searchServices,
    SearchCommonOptions? searchCommonOptions,
    int? searchServiceSelected,
    bool? searchEnabled,
    bool? searchAutoTestOnLaunch,
  }) {
    final copy = SettingsProvider._withoutLoad(_preferences);
    copy._searchServices = searchServices ?? _searchServices;
    copy._searchCommonOptions = searchCommonOptions ?? _searchCommonOptions;
    copy._searchServiceSelected =
        searchServiceSelected ?? _searchServiceSelected;
    copy._searchEnabled = searchEnabled ?? _searchEnabled;
    copy._searchAutoTestOnLaunch =
        searchAutoTestOnLaunch ?? _searchAutoTestOnLaunch;
    copy._ttsServices = _ttsServices;
    copy._selectedTtsServiceId = _selectedTtsServiceId;
    copy._ttsAutoPlayAssistantReplies = _ttsAutoPlayAssistantReplies;
    copy._ttsTextSelectionMode = _ttsTextSelectionMode;
    copy._asrServices = _asrServices;
    copy._selectedAsrServiceId = _selectedAsrServiceId;
    // 复制其他字段
    copy._providersOrder = _providersOrder;
    copy._themeMode = _themeMode;
    copy._themePaletteId = _themePaletteId;
    copy._useDynamicColor = _useDynamicColor;
    copy._customThemes = _customThemes;
    copy._selectedCustomThemeId = _selectedCustomThemeId;
    copy._providerConfigs = _providerConfigs;
    copy._pinnedModels.addAll(_pinnedModels);
    copy._currentModelProvider = _currentModelProvider;
    copy._currentModelId = _currentModelId;
    copy._titleModelProvider = _titleModelProvider;
    copy._titleModelId = _titleModelId;
    copy._titlePrompt = _titlePrompt;
    copy._summaryModelProvider = _summaryModelProvider;
    copy._summaryModelId = _summaryModelId;
    copy._summaryPrompt = _summaryPrompt;
    copy._suggestionModelProvider = _suggestionModelProvider;
    copy._suggestionModelId = _suggestionModelId;
    copy._suggestionPrompt = _suggestionPrompt;
    copy._insertSuggestionOnTapOnly = _insertSuggestionOnTapOnly;
    copy._compressModelProvider = _compressModelProvider;
    copy._compressModelId = _compressModelId;
    copy._compressPrompt = _compressPrompt;
    copy._compressLimitMode = _compressLimitMode;
    copy._compressKeepUserMessages = _compressKeepUserMessages;
    copy._compressMaxChars = _compressMaxChars;
    copy._translateModelProvider = _translateModelProvider;
    copy._translateModelId = _translateModelId;
    copy._translatePrompt = _translatePrompt;
    copy._translateTargetLang = _translateTargetLang;
    copy._ocrModelProvider = _ocrModelProvider;
    copy._ocrModelId = _ocrModelId;
    copy._ocrPrompt = _ocrPrompt;
    copy._ocrEnabled = _ocrEnabled;
    copy._thinkingBudget = _thinkingBudget;
    copy._titleGenerationThinkingEnabled = _titleGenerationThinkingEnabled;
    copy._summaryGenerationThinkingEnabled = _summaryGenerationThinkingEnabled;
    copy._suggestionGenerationThinkingEnabled =
        _suggestionGenerationThinkingEnabled;
    copy._compressGenerationThinkingEnabled =
        _compressGenerationThinkingEnabled;
    copy._translateGenerationThinkingEnabled =
        _translateGenerationThinkingEnabled;
    copy._ocrGenerationThinkingEnabled = _ocrGenerationThinkingEnabled;
    copy._memoryModelProvider = _memoryModelProvider;
    copy._memoryModelId = _memoryModelId;
    copy._memoryModelThinkingEnabled = _memoryModelThinkingEnabled;
    copy._memoryPromptLang = _memoryPromptLang;
    copy._memoryTraceEnabled = _memoryTraceEnabled;
    copy._legacyMemoryMode = _legacyMemoryMode;
    copy._legacyMemoryPromptZh = _legacyMemoryPromptZh;
    copy._legacyMemoryPromptEn = _legacyMemoryPromptEn;
    copy._memoryRulesPromptZh = _memoryRulesPromptZh;
    copy._memoryRulesPromptEn = _memoryRulesPromptEn;
    copy._memoryGatePromptZh = _memoryGatePromptZh;
    copy._memoryGatePromptEn = _memoryGatePromptEn;
    copy._memoryExtractPromptZh = _memoryExtractPromptZh;
    copy._memoryExtractPromptEn = _memoryExtractPromptEn;
    copy._memorySmartAddPromptZh = _memorySmartAddPromptZh;
    copy._memorySmartAddPromptEn = _memorySmartAddPromptEn;
    copy._memorySmartAddBatchPromptZh = _memorySmartAddBatchPromptZh;
    copy._memorySmartAddBatchPromptEn = _memorySmartAddBatchPromptEn;
    copy._memoryProfileDistillPromptZh = _memoryProfileDistillPromptZh;
    copy._memoryProfileDistillPromptEn = _memoryProfileDistillPromptEn;
    copy._memoryMigratePromptZh = _memoryMigratePromptZh;
    copy._memoryMigratePromptEn = _memoryMigratePromptEn;
    copy._memoryMigrationBatchSize = _memoryMigrationBatchSize;
    copy._memoryInjectionMaxItems = _memoryInjectionMaxItems;
    copy._showUserAvatar = _showUserAvatar;
    copy._showModelIcon = _showModelIcon;
    copy._showModelNameTimestamp = _showModelNameTimestamp;
    copy._showTokenStats = _showTokenStats;
    copy._showUserNameTimestamp = _showUserNameTimestamp;
    copy._showUserMessageActions = _showUserMessageActions;
    copy._showThinkingCards = _showThinkingCards;
    copy._showToolCards = _showToolCards;
    copy._showUserName = _showUserName;
    copy._showUserTimestamp = _showUserTimestamp;
    copy._showModelName = _showModelName;
    copy._showModelTimestamp = _showModelTimestamp;
    copy._autoCollapseThinking = _autoCollapseThinking;
    copy._collapseThinkingSteps = _collapseThinkingSteps;
    copy._showToolResultSummary = _showToolResultSummary;
    copy._hideToolResultImages = _hideToolResultImages;
    copy._showRegenerateConfirmDialog = _showRegenerateConfirmDialog;
    copy._showMessageNavButtons = _showMessageNavButtons;
    copy._mobileMessageNavButtonsMode = _mobileMessageNavButtonsMode;
    copy._useNewAssistantAvatarUx = _useNewAssistantAvatarUx;
    copy._showProviderInModelCapsule = _showProviderInModelCapsule;
    copy._showProviderInChatMessage = _showProviderInChatMessage;
    copy._hapticsOnGenerate = _hapticsOnGenerate;
    copy._keepScreenOnDuringGeneration = _keepScreenOnDuringGeneration;
    copy._hapticsOnDrawer = _hapticsOnDrawer;
    copy._hapticsGlobalEnabled = _hapticsGlobalEnabled;
    copy._hapticsIosSwitch = _hapticsIosSwitch;
    copy._hapticsOnListItemTap = _hapticsOnListItemTap;
    copy._hapticsOnCardTap = _hapticsOnCardTap;
    copy._showAppUpdates = _showAppUpdates;
    copy._keepSidebarOpenOnAssistantTap = _keepSidebarOpenOnAssistantTap;
    copy._keepSidebarOpenOnTopicTap = _keepSidebarOpenOnTopicTap;
    copy._keepAssistantListExpandedOnSidebarClose =
        _keepAssistantListExpandedOnSidebarClose;
    copy._requestLogEnabled = _requestLogEnabled;
    copy._contextLogEnabled = _contextLogEnabled;
    copy._flutterLogEnabled = _flutterLogEnabled;
    copy._logSaveOutput = _logSaveOutput;
    copy._logElideLargePayloads = _logElideLargePayloads;
    copy._logAutoDeleteDays = _logAutoDeleteDays;
    copy._logMaxSizeMB = _logMaxSizeMB;
    copy._appLaunchCount = _appLaunchCount;
    copy._newChatOnLaunch = _newChatOnLaunch;
    copy._newChatOnAssistantSwitch = _newChatOnAssistantSwitch;
    copy._insertNewAssistantAtTop = _insertNewAssistantAtTop;
    copy._wideChatLayout = _wideChatLayout;
    copy._newChatAfterDelete = _newChatAfterDelete;
    copy._longPasteAsFile = _longPasteAsFile;
    copy._longPasteAsFileThreshold = _longPasteAsFileThreshold;
    copy._iosBackgroundGenerationEnabled = _iosBackgroundGenerationEnabled;
    copy._iosBackgroundTaskRefreshEnabled = _iosBackgroundTaskRefreshEnabled;
    copy._iosLiveActivityEnabled = _iosLiveActivityEnabled;
    copy._iosBackgroundNotificationsEnabled =
        _iosBackgroundNotificationsEnabled;
    copy._desktopSendShortcut = _desktopSendShortcut;
    copy._desktopMessageNavButtonsMode = _desktopMessageNavButtonsMode;
    copy._chatFontScale = _chatFontScale;
    copy._autoScrollEnabled = _autoScrollEnabled;
    copy._autoScrollIdleSeconds = _autoScrollIdleSeconds;
    copy._enableDollarLatex = _enableDollarLatex;
    copy._enableMathRendering = _enableMathRendering;
    copy._enableUserMarkdown = _enableUserMarkdown;
    copy._enableReasoningMarkdown = _enableReasoningMarkdown;
    copy._enableAssistantMarkdown = _enableAssistantMarkdown;
    copy._showChatListDate = _showChatListDate;
    copy._autoCollapseCodeBlock = _autoCollapseCodeBlock;
    copy._autoCollapseCodeBlockLines = _autoCollapseCodeBlockLines;
    copy._desktopAutoSwitchTopics = _desktopAutoSwitchTopics;
    copy._desktopShowTray = _desktopShowTray;
    copy._desktopMinimizeToTrayOnClose = _desktopMinimizeToTrayOnClose;
    copy._usePureBackground = _usePureBackground;
    copy._chatMessageBackgroundStyle = _chatMessageBackgroundStyle;
    copy._chatBubbleStyleOverrides = _chatBubbleStyleOverrides;
    copy._userChatBubbleStyleOverrides = _userChatBubbleStyleOverrides;
    copy._mobileAssistantEditTabOrder = _mobileAssistantEditTabOrder;
    copy._hiddenMobileAssistantEditTabs = _hiddenMobileAssistantEditTabs;
    copy._mobileAssistantDetailOutlineEnabled =
        _mobileAssistantDetailOutlineEnabled;
    return copy;
  }
}

String _nonEmptyOr(String? value, String fallback) {
  if (value == null || value.trim().isEmpty) return fallback;
  return value;
}

String _normalizeProxyHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']') && h.length > 2) {
    h = h.substring(1, h.length - 1);
  }
  final zoneIndex = h.indexOf('%');
  if (zoneIndex > 0) {
    h = h.substring(0, zoneIndex);
  }
  if (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  return h;
}

bool _shouldBypassProxy(String host, String bypassRules) {
  final h = _normalizeProxyHost(host);
  if (h.isEmpty) return false;

  final rules = bypassRules.split(RegExp(r'[,;\s]+'));
  for (final rawRule in rules) {
    final rule = rawRule.trim();
    if (rule.isEmpty) continue;
    final r = rule.toLowerCase();

    if (r == '*') return true;

    if (r.startsWith('*.') || r.startsWith('*')) {
      final suffix = r.substring(1);
      if (suffix.isNotEmpty && h.endsWith(suffix)) return true;
      continue;
    }

    if (r.contains('/')) {
      final addr = InternetAddress.tryParse(h);
      if (addr != null && _matchesCidr(addr, r)) return true;
      continue;
    }

    if (h == r) return true;
  }

  return false;
}

BigInt _bytesToBigInt(List<int> bytes) {
  var n = BigInt.zero;
  for (final b in bytes) {
    n = (n << 8) | BigInt.from(b);
  }
  return n;
}

BigInt _internetAddressToBigInt(InternetAddress addr) =>
    _bytesToBigInt(addr.rawAddress);

bool _matchesCidr(InternetAddress addr, String cidr) {
  final parts = cidr.split('/');
  if (parts.length != 2) return false;
  final networkStr = parts[0].trim();
  final prefixLen = int.tryParse(parts[1].trim());
  if (prefixLen == null) return false;
  final network = InternetAddress.tryParse(networkStr);
  if (network == null) return false;

  if (addr.type != network.type) return false;
  final totalBits = addr.type == InternetAddressType.IPv4 ? 32 : 128;
  if (prefixLen < 0 || prefixLen > totalBits) return false;

  final mask = prefixLen == 0
      ? BigInt.zero
      : ((BigInt.one << prefixLen) - BigInt.one) << (totalBits - prefixLen);

  final a = _internetAddressToBigInt(addr);
  final n = _internetAddressToBigInt(network);
  return (a & mask) == (n & mask);
}

class _ProxyHttpOverrides extends HttpOverrides {
  final String host;
  final int port;
  final String? username;
  final String? password;
  final String bypassRules;
  _ProxyHttpOverrides({
    required this.host,
    required this.port,
    this.username,
    this.password,
    required this.bypassRules,
  });
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => _shouldBypassProxy(uri.host, bypassRules)
        ? 'DIRECT'
        : 'PROXY $host:$port';
    if (username != null && username!.isNotEmpty) {
      client.addProxyCredentials(
        host,
        port,
        '',
        HttpClientBasicCredentials(username!, password ?? ''),
      );
    }
    return client;
  }
}

class _SocksProxyHttpOverrides extends HttpOverrides {
  final String host;
  final int port;
  final String? username;
  final String? password;
  final String bypassRules;
  _SocksProxyHttpOverrides({
    required this.host,
    required this.port,
    this.username,
    this.password,
    required this.bypassRules,
  });
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    Future<InternetAddress?>? proxyAddrFuture;

    ConnectionTask<Socket> directConnection(Uri uri) {
      if (uri.scheme == 'https') {
        final Future<SecureSocket> socket = SecureSocket.connect(
          uri.host,
          uri.port,
          context: context,
        );
        return ConnectionTask.fromSocket(
          socket,
          () async => (await socket).close(),
        );
      }
      final Future<Socket> socket = Socket.connect(uri.host, uri.port);
      return ConnectionTask.fromSocket(
        socket,
        () async => (await socket).close(),
      );
    }

    Future<InternetAddress?> resolveProxyAddress() async {
      final parsed = InternetAddress.tryParse(host);
      if (parsed != null) return parsed;
      proxyAddrFuture ??= InternetAddress.lookup(
        host,
      ).then((list) => list.isNotEmpty ? list.first : null);
      try {
        return await proxyAddrFuture;
      } catch (_) {
        return null;
      }
    }

    try {
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        if (_shouldBypassProxy(uri.host, bypassRules)) {
          return directConnection(uri);
        }

        final proxyAddr = await resolveProxyAddress();
        if (proxyAddr == null) {
          // 保留先前的行为：如果代理无法配置，则回退为直连。
          return directConnection(uri);
        }

        final proxies = <socks.ProxySettings>[
          socks.ProxySettings(
            proxyAddr,
            port,
            username: username,
            password: password,
          ),
        ];

        final socket = socks.SocksTCPClient.connect(
          proxies,
          InternetAddress(uri.host, type: InternetAddressType.unix),
          uri.port,
        );

        if (uri.scheme == 'https') {
          final Future<SecureSocket> secureSocket;
          return ConnectionTask.fromSocket(
            secureSocket = (await socket).secure(uri.host, context: context),
            () async => (await secureSocket).close(),
          );
        }

        return ConnectionTask.fromSocket(
          socket,
          () async => (await socket).close(),
        );
      };
    } catch (_) {
      // ignore
    }
    return client;
  }
}

enum ProviderKind { openai, google, claude }

// 聊天消息气泡的后台渲染模式
enum ChatMessageBackgroundStyle { defaultStyle, frosted, solid }

enum AndroidBackgroundChatMode { off, on, onNotify }

class ProviderConfig {
  static const _kelivoInPublicApiKey = 'kelivo';

  final String id;
  final bool enabled;
  final String name;
  final String apiKey;
  final String baseUrl;
  final ProviderKind? providerType; // 显式指定 provider 类型，避免误分类
  final String? chatPath; // 仅 openai
  final bool? useResponseApi; // 仅 openai
  final bool? vertexAI; // 仅 google
  final String? location; // 仅 google vertex ai
  final String? projectId; // 仅 google vertex ai
  // 通过服务账号 JSON 使用 Google Vertex AI（粘贴或导入）
  final String? serviceAccountJson; // 仅 google vertex ai
  final List<String> models; // 未来模型管理的占位字段
  // 按逻辑模型键的逐模型覆盖配置。
  // 每个条目可通过 `apiModelId` 指向上游/供应商模型 ID，
  // 使多个逻辑模型以不同参数共享同一个后端模型。
  // {'<key>': {'apiModelId': String?, 'name': String?, 'type': '聊天'|'嵌入', '输入': ['文本','图像'], '输出': [...], '能力': ['工具','推理']}}
  final Map<String, dynamic> modelOverrides;
  // 按提供商自定义请求覆盖项。
  final List<Map<String, String>> customHeaders;
  final List<Map<String, String>> customBody;
  // 按提供商代理
  final bool? proxyEnabled;
  final String? proxyType; // http|https|socks5
  final String? proxyHost;
  final String? proxyPort;
  final String? proxyUsername;
  final String? proxyPassword;
  // 自定义提供商头像（与用户相同的方案，加上内置图标：emoji | url | file | icon | lobehub）
  final String? avatarType; // 'emoji' | 'url' | 'file' | 'icon' | 'lobehub'
  final String? avatarValue;
  // 多密钥模式
  final bool? multiKeyEnabled; // 默认 false
  final List<ApiKeyConfig>? apiKeys; // 启用时使用
  final KeyManagementConfig? keyManagement;
  // AIhubmix 推广头部主动加入
  final bool? aihubmixAppCodeEnabled;
  // OpenAI 兼容服务商的账户余额查询。
  final bool? balanceEnabled;
  final String? balanceApiPath;
  final String? balanceResultPath;
  // Anthropic/OpenRouter Claude 针对稳定系统提示词的提示词缓存。
  final bool? claudePromptCachingEnabled;
  final String? claudePromptCachingTtl;

  static const String claudePromptCachingTtl5m = '5m';
  static const String claudePromptCachingTtl1h = '1h';

  static String resolveClaudePromptCachingTtl(String? value) {
    switch (value?.trim().toLowerCase()) {
      case claudePromptCachingTtl1h:
        return claudePromptCachingTtl1h;
      case claudePromptCachingTtl5m:
      default:
        return claudePromptCachingTtl5m;
    }
  }

  static Map<String, dynamic> claudePromptCacheControl(String? ttl) {
    final cacheControl = <String, dynamic>{'type': 'ephemeral'};
    if (resolveClaudePromptCachingTtl(ttl) == claudePromptCachingTtl1h) {
      cacheControl['ttl'] = claudePromptCachingTtl1h;
    }
    return cacheControl;
  }

  static String resolveProxyType(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'socks5':
        return 'socks5';
      case 'http':
      default:
        return 'http';
    }
  }

  ProviderConfig({
    required this.id,
    required this.enabled,
    required this.name,
    required this.apiKey,
    required this.baseUrl,
    this.providerType,
    this.chatPath,
    this.useResponseApi,
    this.vertexAI,
    this.location,
    this.projectId,
    this.serviceAccountJson,
    this.models = const [],
    this.modelOverrides = const {},
    this.customHeaders = const <Map<String, String>>[],
    this.customBody = const <Map<String, String>>[],
    this.proxyEnabled,
    this.proxyType,
    this.proxyHost,
    this.proxyPort,
    this.proxyUsername,
    this.proxyPassword,
    this.avatarType,
    this.avatarValue,
    this.multiKeyEnabled,
    this.apiKeys,
    this.keyManagement,
    this.aihubmixAppCodeEnabled,
    this.balanceEnabled,
    this.balanceApiPath,
    this.balanceResultPath,
    this.claudePromptCachingEnabled = false,
    this.claudePromptCachingTtl = claudePromptCachingTtl5m,
  });

  // copyWith 可空性控制的哨兵值（允许显式设置为 null）
  static const Object _sentinel = Object();

  ProviderConfig copyWith({
    String? id,
    bool? enabled,
    String? name,
    String? apiKey,
    String? baseUrl,
    ProviderKind? providerType,
    String? chatPath,
    bool? useResponseApi,
    bool? vertexAI,
    String? location,
    String? projectId,
    String? serviceAccountJson,
    List<String>? models,
    Map<String, dynamic>? modelOverrides,
    List<Map<String, String>>? customHeaders,
    List<Map<String, String>>? customBody,
    bool? proxyEnabled,
    String? proxyType,
    String? proxyHost,
    String? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    Object? avatarType = _sentinel,
    Object? avatarValue = _sentinel,
    bool? multiKeyEnabled,
    List<ApiKeyConfig>? apiKeys,
    KeyManagementConfig? keyManagement,
    bool? aihubmixAppCodeEnabled,
    bool? balanceEnabled,
    String? balanceApiPath,
    String? balanceResultPath,
    bool? claudePromptCachingEnabled,
    String? claudePromptCachingTtl,
  }) => ProviderConfig(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    name: name ?? this.name,
    apiKey: apiKey ?? this.apiKey,
    baseUrl: baseUrl ?? this.baseUrl,
    providerType: providerType ?? this.providerType,
    chatPath: chatPath ?? this.chatPath,
    useResponseApi: useResponseApi ?? this.useResponseApi,
    vertexAI: vertexAI ?? this.vertexAI,
    location: location ?? this.location,
    projectId: projectId ?? this.projectId,
    serviceAccountJson: serviceAccountJson ?? this.serviceAccountJson,
    models: models ?? this.models,
    modelOverrides: modelOverrides ?? this.modelOverrides,
    customHeaders: customHeaders ?? this.customHeaders,
    customBody: customBody ?? this.customBody,
    proxyEnabled: proxyEnabled ?? this.proxyEnabled,
    proxyType: proxyType ?? this.proxyType,
    proxyHost: proxyHost ?? this.proxyHost,
    proxyPort: proxyPort ?? this.proxyPort,
    proxyUsername: proxyUsername ?? this.proxyUsername,
    proxyPassword: proxyPassword ?? this.proxyPassword,
    avatarType: (identical(avatarType, _sentinel))
        ? this.avatarType
        : (avatarType as String?),
    avatarValue: (identical(avatarValue, _sentinel))
        ? this.avatarValue
        : (avatarValue as String?),
    multiKeyEnabled: multiKeyEnabled ?? this.multiKeyEnabled,
    apiKeys: apiKeys ?? this.apiKeys,
    keyManagement: keyManagement ?? this.keyManagement,
    aihubmixAppCodeEnabled:
        aihubmixAppCodeEnabled ?? this.aihubmixAppCodeEnabled,
    balanceEnabled: balanceEnabled ?? this.balanceEnabled,
    balanceApiPath: balanceApiPath ?? this.balanceApiPath,
    balanceResultPath: balanceResultPath ?? this.balanceResultPath,
    claudePromptCachingEnabled:
        claudePromptCachingEnabled ?? this.claudePromptCachingEnabled,
    claudePromptCachingTtl:
        claudePromptCachingTtl ?? this.claudePromptCachingTtl,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'enabled': enabled,
    'name': name,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'providerType': providerType?.name,
    'chatPath': chatPath,
    'useResponseApi': useResponseApi,
    'vertexAI': vertexAI,
    'location': location,
    'projectId': projectId,
    'serviceAccountJson': serviceAccountJson,
    'models': models,
    'modelOverrides': modelOverrides,
    'customHeaders': customHeaders,
    'customBody': customBody,
    'proxyEnabled': proxyEnabled,
    'proxyType': proxyType,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    'proxyUsername': proxyUsername,
    'proxyPassword': proxyPassword,
    'avatarType': avatarType,
    'avatarValue': avatarValue,
    'multiKeyEnabled': multiKeyEnabled,
    'apiKeys': apiKeys?.map((e) => e.toJson()).toList(),
    'keyManagement': keyManagement?.toJson(),
    'aihubmixAppCodeEnabled': aihubmixAppCodeEnabled,
    'balanceEnabled': balanceEnabled,
    'balanceApiPath': balanceApiPath,
    'balanceResultPath': balanceResultPath,
    'claudePromptCachingEnabled': claudePromptCachingEnabled,
    'claudePromptCachingTtl': resolveClaudePromptCachingTtl(
      claudePromptCachingTtl,
    ),
  };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) => ProviderConfig(
    id: json['id'] as String? ?? (json['name'] as String? ?? ''),
    enabled: json['enabled'] as bool? ?? true,
    name: json['name'] as String? ?? '',
    apiKey: _apiKeyFromJson(json),
    baseUrl: json['baseUrl'] as String? ?? '',
    providerType: json['providerType'] != null
        ? ProviderKind.values.firstWhere(
            (e) => e.name == json['providerType'],
            orElse: () => classify(json['id'] as String? ?? ''),
          )
        : null,
    chatPath: json['chatPath'] as String?,
    useResponseApi: json['useResponseApi'] as bool?,
    vertexAI: json['vertexAI'] as bool?,
    location: json['location'] as String?,
    projectId: json['projectId'] as String?,
    serviceAccountJson: json['serviceAccountJson'] as String?,
    models:
        (json['models'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
    modelOverrides:
        (json['modelOverrides'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        ) ??
        const {},
    customHeaders: _customRequestRowsFromJson(
      json['customHeaders'],
      keyName: 'name',
      fallbackKeyName: 'key',
    ),
    customBody: _customRequestRowsFromJson(
      json['customBody'],
      keyName: 'key',
      fallbackKeyName: 'name',
    ),
    proxyEnabled: json['proxyEnabled'] as bool?,
    proxyType: json['proxyType'] as String?,
    proxyHost: json['proxyHost'] as String?,
    proxyPort: json['proxyPort'] as String?,
    proxyUsername: json['proxyUsername'] as String?,
    proxyPassword: json['proxyPassword'] as String?,
    avatarType: json['avatarType'] as String?,
    avatarValue: json['avatarValue'] as String?,
    multiKeyEnabled: json['multiKeyEnabled'] as bool?,
    apiKeys: (json['apiKeys'] as List?)
        ?.whereType<Map>()
        .map((e) => ApiKeyConfig.fromJson(e.cast<String, dynamic>()))
        .toList(),
    keyManagement: KeyManagementConfig.fromJson(
      (json['keyManagement'] as Map?)?.cast<String, dynamic>(),
    ),
    aihubmixAppCodeEnabled: json['aihubmixAppCodeEnabled'] as bool?,
    balanceEnabled: json['balanceEnabled'] as bool?,
    balanceApiPath: json['balanceApiPath'] as String?,
    balanceResultPath: json['balanceResultPath'] as String?,
    claudePromptCachingEnabled:
        json['claudePromptCachingEnabled'] as bool? ?? false,
    claudePromptCachingTtl: resolveClaudePromptCachingTtl(
      json['claudePromptCachingTtl'] as String?,
    ),
  );

  static String _apiKeyFromJson(Map<String, dynamic> json) {
    final stored = json['apiKey'] as String? ?? '';
    if (stored.isNotEmpty) return stored;
    final id = json['id'] as String? ?? json['name'] as String? ?? '';
    return id.trim().toLowerCase() == 'kelivoin' ? _kelivoInPublicApiKey : '';
  }

  static List<Map<String, String>> _customRequestRowsFromJson(
    Object? raw, {
    required String keyName,
    required String fallbackKeyName,
  }) {
    if (raw is! List) return const <Map<String, String>>[];
    return raw
        .whereType<Map>()
        .map(
          (entry) => <String, String>{
            keyName: (entry[keyName] ?? entry[fallbackKeyName] ?? '')
                .toString(),
            'value': (entry['value'] ?? '').toString(),
          },
        )
        .toList();
  }

  static ProviderKind classify(String key, {ProviderKind? explicitType}) {
    // 如果提供了显式类型，则使用它
    if (explicitType != null) return explicitType;

    // 否则，根据 key 推断
    final k = key.toLowerCase();
    if (k.contains('gemini') || k.contains('google')) {
      return ProviderKind.google;
    }
    if (k.contains('deepseek') ||
        k.contains('claude') ||
        k.contains('anthropic')) {
      return ProviderKind.claude;
    }
    return ProviderKind.openai;
  }

  static bool isDeepSeek(ProviderConfig config) {
    final baseUri = Uri.tryParse(config.baseUrl.trim());
    final host = baseUri?.host.toLowerCase();
    if (host == 'api.deepseek.com') return true;
    final id = config.id.trim().toLowerCase();
    final name = config.name.trim().toLowerCase();
    return id.contains('deepseek') || name.contains('deepseek');
  }

  static String _defaultBase(String key) {
    final k = key.toLowerCase();
    if (k.contains('tensdaq')) return 'https://tensdaq-api.x-aio.com/v1';
    if (k.contains('kelivoin')) return 'https://text.pollinations.ai/openai';
    if (k.contains('openrouter')) return 'https://openrouter.ai/api/v1';
    if (k.contains('aihubmix')) return 'https://aihubmix.com/v1';
    if (RegExp(r'qwen|aliyun|dashscope').hasMatch(k)) {
      return 'https://dashscope.aliyuncs.com/compatible-mode/v1';
    }
    if (RegExp(r'bytedance|doubao|volces|ark').hasMatch(k)) {
      return 'https://ark.cn-beijing.volces.com/api/v3';
    }
    if (RegExp(r'kimi|moonshot|月之暗面').hasMatch(k)) {
      return 'https://api.moonshot.cn/v1';
    }
    if (k.contains('silicon')) return 'https://api.siliconflow.cn/v1';
    if (k.contains('grok') || k.contains('x.ai') || k.contains('xai')) {
      return 'https://api.x.ai/v1';
    }
    if (k.contains('deepseek')) {
      return 'https://api.deepseek.com/anthropic';
    }
    if (RegExp(r'zhipu|智谱|glm').hasMatch(k)) {
      return 'https://open.bigmodel.cn/api/paas/v4';
    }
    if (k.contains('gemini') || k.contains('google')) {
      return 'https://generativelanguage.googleapis.com/v1beta';
    }
    if (k.contains('claude') || k.contains('anthropic')) {
      return 'https://api.anthropic.com/v1';
    }
    return 'https://api.openai.com/v1';
  }

  static ProviderConfig defaultsFor(String key, {String? displayName}) {
    bool defaultEnabled(String k) {
      final s = k.toLowerCase();
      if (s.contains('tensdaq')) return true;
      if (s.contains('openai')) return true;
      if (s.contains('gemini') || s.contains('google')) return true;
      if (s.contains('silicon')) return true;
      if (s.contains('openrouter')) return true;
      if (s.contains('kelivoin')) return true;
      return false; // 其他项默认禁用
    }

    final kind = classify(key);
    final lowerKey = key.toLowerCase();
    switch (kind) {
      case ProviderKind.google:
        return ProviderConfig(
          id: key,
          enabled: defaultEnabled(key),
          name: displayName ?? key,
          apiKey: '',
          baseUrl: _defaultBase(key),
          providerType: ProviderKind.google,
          vertexAI: false,
          location: '',
          projectId: '',
          serviceAccountJson: '',
          models: const [],
          modelOverrides: const {},
          proxyEnabled: false,
          proxyHost: '',
          proxyPort: '8080',
          proxyUsername: '',
          proxyPassword: '',
          multiKeyEnabled: false,
          apiKeys: const [],
          keyManagement: const KeyManagementConfig(),
          aihubmixAppCodeEnabled: false,
          balanceEnabled: false,
          balanceApiPath: '/credits',
          balanceResultPath: 'data.total_usage',
          claudePromptCachingEnabled: false,
        );
      case ProviderKind.claude:
        return ProviderConfig(
          id: key,
          enabled: defaultEnabled(key),
          name: displayName ?? key,
          apiKey: '',
          baseUrl: _defaultBase(key),
          providerType: ProviderKind.claude,
          models: const [],
          modelOverrides: const {},
          proxyEnabled: false,
          proxyHost: '',
          proxyPort: '8080',
          proxyUsername: '',
          proxyPassword: '',
          multiKeyEnabled: false,
          apiKeys: const [],
          keyManagement: const KeyManagementConfig(),
          aihubmixAppCodeEnabled: false,
          balanceEnabled: _defaultBalanceEnabled(key),
          balanceApiPath: _defaultBalanceApiPath(key),
          balanceResultPath: _defaultBalanceResultPath(key),
          claudePromptCachingEnabled: false,
        );
      case ProviderKind.openai:
        // 对 KelivoIN 的默认模型和覆盖项做特殊处理
        if (lowerKey.contains('kelivoin')) {
          return ProviderConfig(
            id: key,
            enabled: defaultEnabled(key),
            name: displayName ?? key,
            apiKey: _kelivoInPublicApiKey,
            baseUrl: _defaultBase(key),
            providerType: ProviderKind.openai,
            chatPath: null, // UI 中保持为空；代码使用默认 '/chat/completions'
            useResponseApi: false,
            models: const [
              // 'openai-fast',
              'mistral',
              'qwen-coder',
            ],
            modelOverrides: const {
              // 'openai-fast': {
              //   'type': 'chat',
              //   'input': ['text'],
              //   'output': ['text'],
              //   'abilities': ['tool'],
              // },
              'mistral': {
                'type': 'chat',
                'input': ['text'],
                'output': ['text'],
                'abilities': ['tool'],
              },
              'qwen-coder': {
                'type': 'chat',
                'input': ['text'],
                'output': ['text'],
                'abilities': ['tool'],
              },
            },
            proxyEnabled: false,
            proxyHost: '',
            proxyPort: '8080',
            proxyUsername: '',
            proxyPassword: '',
            multiKeyEnabled: false,
            apiKeys: const [],
            keyManagement: const KeyManagementConfig(),
            aihubmixAppCodeEnabled: false,
            balanceEnabled: _defaultBalanceEnabled(key),
            balanceApiPath: _defaultBalanceApiPath(key),
            balanceResultPath: _defaultBalanceResultPath(key),
            claudePromptCachingEnabled: false,
          );
        }
        // 对 SiliconFlow 保留合作模型的能力覆盖，但首次启动不预选模型。
        if (lowerKey.contains('silicon')) {
          return ProviderConfig(
            id: key,
            enabled: defaultEnabled(key),
            name: displayName ?? key,
            apiKey: '',
            baseUrl: _defaultBase(key),
            providerType: ProviderKind.openai,
            chatPath: '/chat/completions',
            useResponseApi: false,
            models: const [],
            modelOverrides: const {
              'THUDM/GLM-4-9B-0414': {
                'type': 'chat',
                'input': ['text'],
                'output': ['text'],
                'abilities': ['tool'],
              },
              'Qwen/Qwen3-8B': {
                'type': 'chat',
                'input': ['text'],
                'output': ['text'],
                'abilities': ['tool', 'reasoning'],
              },
            },
            proxyEnabled: false,
            proxyHost: '',
            proxyPort: '8080',
            proxyUsername: '',
            proxyPassword: '',
            multiKeyEnabled: false,
            apiKeys: const [],
            keyManagement: const KeyManagementConfig(),
            aihubmixAppCodeEnabled: false,
            balanceEnabled: _defaultBalanceEnabled(key),
            balanceApiPath: _defaultBalanceApiPath(key),
            balanceResultPath: _defaultBalanceResultPath(key),
            claudePromptCachingEnabled: false,
          );
        }
        return ProviderConfig(
          id: key,
          enabled: defaultEnabled(key),
          name: displayName ?? key,
          apiKey: '',
          baseUrl: _defaultBase(key),
          providerType: ProviderKind.openai,
          chatPath: '/chat/completions',
          useResponseApi: false,
          models: const [],
          modelOverrides: const {},
          proxyEnabled: false,
          proxyHost: '',
          proxyPort: '8080',
          proxyUsername: '',
          proxyPassword: '',
          multiKeyEnabled: false,
          apiKeys: const [],
          keyManagement: const KeyManagementConfig(),
          aihubmixAppCodeEnabled: lowerKey.contains('aihubmix'),
          balanceEnabled: _defaultBalanceEnabled(key),
          balanceApiPath: _defaultBalanceApiPath(key),
          balanceResultPath: _defaultBalanceResultPath(key),
          claudePromptCachingEnabled: false,
        );
    }
  }

  static String _defaultBalanceApiPath(String key) {
    final k = key.toLowerCase();
    if (k.contains('aihubmix')) return '/user/balance';
    if (k.contains('deepseek')) return '/user/balance';
    if (k.contains('openrouter')) return '/credits';
    if (k.contains('vercel')) return '/credits';
    if (k.contains('silicon')) return '/user/info';
    if (RegExp(r'kimi|moonshot|月之暗面').hasMatch(k)) {
      return '/users/me/balance';
    }
    return '/credits';
  }

  static String _defaultBalanceResultPath(String key) {
    final k = key.toLowerCase();
    if (k.contains('aihubmix')) return 'balance_infos[0].total_balance';
    if (k.contains('deepseek')) return 'balance_infos[0].total_balance';
    if (k.contains('openrouter')) {
      return 'data.total_credits - data.total_usage';
    }
    if (k.contains('vercel')) return 'balance';
    if (k.contains('silicon')) return 'data.totalBalance';
    if (RegExp(r'kimi|moonshot|月之暗面').hasMatch(k)) {
      return 'data.available_balance';
    }
    return 'data.total_usage';
  }

  static bool _defaultBalanceEnabled(String key) {
    final k = key.toLowerCase();
    return k.contains('aihubmix') ||
        k.contains('deepseek') ||
        k.contains('openrouter') ||
        k.contains('vercel') ||
        k.contains('silicon') ||
        RegExp(r'kimi|moonshot|月之暗面').hasMatch(k);
  }
}
