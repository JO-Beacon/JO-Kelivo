import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider insert assistants at top', () {
    test('defaults to disabled', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.insertNewAssistantAtTop, isFalse);
    });

    test('loads persisted enabled value', () async {
      SharedPreferences.setMockInitialValues({
        'display_insert_new_assistant_at_top_v1': true,
      });
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.insertNewAssistantAtTop, isTrue);
    });

    test('persists toggle changes to preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();
      await settings.setInsertNewAssistantAtTop(true);

      expect(settings.insertNewAssistantAtTop, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('display_insert_new_assistant_at_top_v1'), isTrue);
    });
  });

  group('SettingsProvider wide chat layout', () {
    test('defaults to disabled', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.wideChatLayout, isFalse);
    });

    test('loads persisted enabled value', () async {
      SharedPreferences.setMockInitialValues({
        'display_wide_chat_layout_v1': true,
      });
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.wideChatLayout, isTrue);
    });

    test('loads legacy persisted enabled value', () async {
      SharedPreferences.setMockInitialValues({
        'display_desktop_wide_chat_layout_v1': true,
      });
      final settings = SettingsProvider();

      await _waitForSettingsLoad();

      expect(settings.wideChatLayout, isTrue);
    });

    test('persists toggle changes to preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();
      await settings.setWideChatLayout(true);

      expect(settings.wideChatLayout, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('display_wide_chat_layout_v1'), isTrue);
    });
  });
}
