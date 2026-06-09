import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';

Future<AssistantProvider> _createLoadedProvider() async {
  SharedPreferences.setMockInitialValues({
    'assistants_v1': Assistant.encodeList(const [
      Assistant(id: 'assistant-a', name: 'A'),
      Assistant(id: 'assistant-b', name: 'B'),
    ]),
    'current_assistant_id_v1': 'assistant-a',
  });

  final provider = AssistantProvider();
  for (var i = 0; i < 25; i++) {
    if (provider.assistants.length == 2) return provider;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AssistantProvider insert at top', () {
    test('addAssistant appends by default', () async {
      final provider = await _createLoadedProvider();

      final id = await provider.addAssistant(name: 'C');

      expect(provider.assistants.map((assistant) => assistant.id), [
        'assistant-a',
        'assistant-b',
        id,
      ]);
    });

    test('addAssistant inserts at top when requested', () async {
      final provider = await _createLoadedProvider();

      final id = await provider.addAssistant(name: 'C', insertAtTop: true);

      expect(provider.assistants.map((assistant) => assistant.id), [
        id,
        'assistant-a',
        'assistant-b',
      ]);
    });

    test('duplicateAssistant inserts copy after source by default', () async {
      final provider = await _createLoadedProvider();

      final id = await provider.duplicateAssistant('assistant-b');

      expect(id, isNotNull);
      expect(provider.assistants.map((assistant) => assistant.id), [
        'assistant-a',
        'assistant-b',
        id,
      ]);
    });

    test('duplicateAssistant inserts copy at top when requested', () async {
      final provider = await _createLoadedProvider();

      final id = await provider.duplicateAssistant(
        'assistant-b',
        insertAtTop: true,
      );

      expect(id, isNotNull);
      expect(provider.assistants.map((assistant) => assistant.id), [
        id,
        'assistant-a',
        'assistant-b',
      ]);
    });
  });
}
