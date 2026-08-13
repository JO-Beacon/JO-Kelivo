import 'dart:convert';

Map<String, Object> jo015BusinessSettingsFixture() => <String, Object>{
  'display_lazy_history_enabled_v1': false,
  'display_insert_new_assistant_at_top_v1': true,
  'display_wide_chat_layout_v1': false,
  'display_desktop_wide_chat_layout_v1': true,
  'provider_configs_v1': jsonEncode({
    'deepseek': {
      'id': 'deepseek',
      'enabled': true,
      'name': 'DeepSeek',
      'apiKey': 'jo-015-anthropic-key',
      'baseUrl': 'https://api.deepseek.com/anthropic',
      'providerType': 'claude',
      'models': ['deepseek-chat'],
      'modelOverrides': {
        'deepseek-chat': {
          'type': 'chat',
          'input': ['text'],
          'output': ['text'],
          'abilities': ['tool'],
        },
      },
    },
    'deepseek-openai-explicit': {
      'id': 'deepseek-openai-explicit',
      'enabled': true,
      'name': 'DeepSeek OpenAI',
      'apiKey': '',
      'baseUrl': 'https://api.deepseek.com/v1',
      'providerType': 'openai',
      'chatPath': '/chat/completions',
      'models': ['deepseek-reasoner'],
      'modelOverrides': <String, Object>{},
    },
  }),
  'providers_order_v1': <String>['deepseek', 'deepseek-openai-explicit'],
};

Map<String, Object?> jo015BusinessSettingsProjection(
  Map<String, Object?> source,
) => <String, Object?>{
  for (final key in const <String>[
    'display_lazy_history_enabled_v1',
    'display_insert_new_assistant_at_top_v1',
    'display_wide_chat_layout_v1',
    'display_desktop_wide_chat_layout_v1',
    'providers_order_v1',
  ])
    key: source[key],
  'provider_configs_v1': jsonDecode(source['provider_configs_v1']! as String),
};
