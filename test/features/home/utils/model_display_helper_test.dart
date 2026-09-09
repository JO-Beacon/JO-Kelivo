import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/home/utils/model_display_helper.dart';

import '../../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;

  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.setCurrentModel('global', 'global-model');
  });

  Assistant assistant({String? provider, String? model}) => Assistant(
    id: 'assistant',
    name: 'Assistant',
    chatModelProvider: provider,
    chatModelId: model,
  );

  Conversation conversation({String? provider, String? model}) => Conversation(
    title: 'Chat',
    chatModelProvider: provider,
    chatModelId: model,
  );

  test('resolves conversation, assistant, then global in order', () {
    expect(
      resolveChatModel(
        settings,
        conversation: conversation(provider: 'conversation', model: 'c'),
        assistant: assistant(provider: 'assistant', model: 'a'),
      ),
      (providerKey: 'conversation', modelId: 'c'),
    );
    expect(
      resolveChatModel(
        settings,
        conversation: conversation(),
        assistant: assistant(provider: 'assistant', model: 'a'),
      ),
      (providerKey: 'assistant', modelId: 'a'),
    );
    expect(resolveChatModel(settings, conversation: conversation()), (
      providerKey: 'global',
      modelId: 'global-model',
    ));
  });

  test('half a conversation override is ignored as a unit', () {
    final resolved = resolveChatModel(
      settings,
      conversation: conversation(provider: 'conversation'),
      assistant: assistant(provider: 'assistant', model: 'a'),
    );

    expect(resolved.providerKey, 'assistant');
    expect(resolved.modelId, 'a');
  });

  test('每个对话独立模型默认开启', () {
    expect(settings.perChatModelEnabled, isTrue);
  });

  test('关闭后会话层整体跳过，重新开启仍生效', () async {
    await settings.setPerChatModelEnabled(false);
    final off = resolveChatModel(
      settings,
      conversation: conversation(provider: 'conversation', model: 'c'),
      assistant: assistant(provider: 'assistant', model: 'a'),
    );
    expect(off.providerKey, 'assistant');
    expect(off.modelId, 'a');

    // 会话上的设置只是被忽略，没有被清除。
    await settings.setPerChatModelEnabled(true);
    final on = resolveChatModel(
      settings,
      conversation: conversation(provider: 'conversation', model: 'c'),
      assistant: assistant(provider: 'assistant', model: 'a'),
    );
    expect(on.providerKey, 'conversation');
    expect(on.modelId, 'c');
  });

  test('display and active ids use the same resolved model', () {
    final conversationModel = conversation(
      provider: 'conversation',
      model: 'conversation-model',
    );
    final ids = getActiveModelIds(
      settings,
      conversation: conversationModel,
      assistant: assistant(provider: 'assistant', model: 'assistant-model'),
    );
    final display = getModelDisplayInfo(
      settings,
      conversation: conversationModel,
      assistant: assistant(provider: 'assistant', model: 'assistant-model'),
    );

    expect(ids.providerKey, 'conversation');
    expect(ids.modelId, 'conversation-model');
    expect(display.providerKey, ids.providerKey);
    expect(display.modelId, ids.modelId);
  });
}
