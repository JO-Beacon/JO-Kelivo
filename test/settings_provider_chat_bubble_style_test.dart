import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/business_settings_router.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/theme/chat_bubble_style.dart';

import 'support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bubble style overrides default to empty', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    expect(settings.chatBubbleStyleOverrides, const ChatBubbleStyleOverrides());
    expect(settings.chatBubbleStyleOverrides.isDefault, isTrue);
  });

  test('persists and reloads bubble style overrides', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    const next = ChatBubbleStyleOverrides(
      backgroundArgbLight: 0xFF112233,
      frostedOpacity: 0.4,
      blurSigma: 22,
      cornerRadius: 8,
    );
    await settings.setChatBubbleStyleOverrides(next);

    expect(settings.chatBubbleStyleOverrides, next);
    expect(
      harness.preferences.getString('chat_bubble_style_overrides_v1'),
      jsonEncode(next.toJson()),
    );

    final reloaded = SettingsProvider(harness.preferences);
    await reloaded.loaded;
    expect(reloaded.chatBubbleStyleOverrides, next);
  });

  test('reset persists an empty override object', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;
    await settings.setChatBubbleStyleOverrides(
      const ChatBubbleStyleOverrides(blurSigma: 9),
    );
    await settings.setChatBubbleStyleOverrides(
      const ChatBubbleStyleOverrides(),
    );

    expect(settings.chatBubbleStyleOverrides.isDefault, isTrue);
    expect(
      harness.preferences.getString('chat_bubble_style_overrides_v1'),
      '{}',
    );
  });

  test('backup registry classifies the overrides key as a preference', () {
    expect(
      BusinessKeyRegistry.classify('chat_bubble_style_overrides_v1'),
      BusinessKeyDisposition.preference,
    );
    expect(
      BusinessKeyRegistry.preferenceKeys,
      contains('chat_bubble_style_overrides_v1'),
    );
    expect(
      BusinessKeyRegistry.classify('chat_bubble_style_overrides_user_v1'),
      BusinessKeyDisposition.preference,
    );
    expect(
      BusinessKeyRegistry.preferenceKeys,
      contains('chat_bubble_style_overrides_user_v1'),
    );
  });

  test(
    'user style falls back to the legacy assistant style before split',
    () async {
      const assistant = ChatBubbleStyleOverrides(
        backgroundArgbLight: 0xFF112233,
        cornerRadius: 9,
      );
      final harness = await createBusinessTestHarness(
        initial: {
          'chat_bubble_style_overrides_v1': jsonEncode(assistant.toJson()),
        },
      );
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;

      expect(settings.assistantChatBubbleStyleOverrides, assistant);
      expect(settings.userChatBubbleStyleOverrides, assistant);
      expect(settings.chatBubbleStyleOverridesFor(isUser: true), assistant);
    },
  );

  test('first assistant edit snapshots legacy style for the user', () async {
    const previous = ChatBubbleStyleOverrides(cornerRadius: 9);
    const next = ChatBubbleStyleOverrides(cornerRadius: 20);
    final harness = await createBusinessTestHarness(
      initial: {
        'chat_bubble_style_overrides_v1': jsonEncode(previous.toJson()),
      },
    );
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    await settings.setChatBubbleStyleOverridesForRole(
      isUser: false,
      value: next,
    );

    expect(settings.assistantChatBubbleStyleOverrides, next);
    expect(settings.userChatBubbleStyleOverrides, previous);
    expect(
      harness.preferences.getString('chat_bubble_style_overrides_user_v1'),
      jsonEncode(previous.toJson()),
    );
  });

  test('overlapping assistant edits persist the latest value', () async {
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    const shared = ChatBubbleStyleOverrides(
      backgroundArgbLight: 0xFF112233,
      cornerRadius: 8,
    );
    await settings.setChatBubbleStyleOverrides(shared);

    const assistantA = ChatBubbleStyleOverrides(cornerRadius: 2);
    const assistantB = ChatBubbleStyleOverrides(cornerRadius: 4);
    final first = settings.setChatBubbleStyleOverridesForRole(
      isUser: false,
      value: assistantA,
    );
    final second = settings.setChatBubbleStyleOverridesForRole(
      isUser: false,
      value: assistantB,
    );
    await first;
    await second;

    expect(settings.assistantChatBubbleStyleOverrides, assistantB);
    expect(settings.userChatBubbleStyleOverrides, shared);
    expect(
      harness.preferences.getString('chat_bubble_style_overrides_v1'),
      jsonEncode(assistantB.toJson()),
    );
    expect(
      harness.preferences.getString('chat_bubble_style_overrides_user_v1'),
      jsonEncode(shared.toJson()),
    );

    final reloaded = SettingsProvider(harness.preferences);
    await reloaded.loaded;
    expect(reloaded.assistantChatBubbleStyleOverrides, assistantB);
    expect(reloaded.userChatBubbleStyleOverrides, shared);
  });

  test('user and assistant styles persist independently', () async {
    const assistant = ChatBubbleStyleOverrides(cornerRadius: 20);
    const user = ChatBubbleStyleOverrides(cornerRadius: 4);
    final harness = await createBusinessTestHarness(initial: {});
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    await settings.setChatBubbleStyleOverridesForRole(
      isUser: true,
      value: user,
    );
    await settings.setChatBubbleStyleOverridesForRole(
      isUser: false,
      value: assistant,
    );

    final reloaded = SettingsProvider(harness.preferences);
    await reloaded.loaded;
    expect(reloaded.userChatBubbleStyleOverrides, user);
    expect(reloaded.assistantChatBubbleStyleOverrides, assistant);
  });

  test(
    'reset clears the user split and restores shared assistant style',
    () async {
      const assistant = ChatBubbleStyleOverrides(cornerRadius: 20);
      const user = ChatBubbleStyleOverrides(cornerRadius: 4);
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;
      await settings.setChatBubbleStyleOverridesForRole(
        isUser: true,
        value: user,
      );
      await settings.setChatBubbleStyleOverridesForRole(
        isUser: false,
        value: assistant,
      );

      await settings.setChatBubbleStyleOverrides(assistant);

      expect(settings.userChatBubbleStyleOverrides, assistant);
      expect(
        harness.preferences.getString('chat_bubble_style_overrides_user_v1'),
        isNull,
      );
    },
  );

  test('corrupt user style falls back to the assistant style', () async {
    const assistant = ChatBubbleStyleOverrides(cornerRadius: 20);
    final harness = await createBusinessTestHarness(
      initial: {
        'chat_bubble_style_overrides_v1': jsonEncode(assistant.toJson()),
        'chat_bubble_style_overrides_user_v1': '{not-json',
      },
    );
    final settings = SettingsProvider(harness.preferences);
    await settings.loaded;

    expect(settings.userChatBubbleStyleOverrides, assistant);
  });
}
