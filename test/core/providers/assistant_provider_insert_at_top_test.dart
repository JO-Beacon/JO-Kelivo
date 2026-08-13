import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/assistant_provider.dart';

import '../../support/business_preferences_test_harness.dart';

Future<AssistantProvider> _loadProvider(
  BusinessPreferencesTestSession session,
) async {
  final provider = AssistantProvider(preferences: session.preferences);
  await provider.loaded;
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BusinessPreferencesTestHarness harness;
  late BusinessPreferencesTestSession session;

  setUp(() async {
    harness = await BusinessPreferencesTestHarness.create();
    session = await harness.open();
    await session.preferences.setString(
      'assistants_v1',
      jsonEncode(const [
        {'id': 'assistant-a', 'name': 'A'},
        {'id': 'assistant-b', 'name': 'B'},
      ]),
    );
  });

  tearDown(() => harness.dispose());

  test('default creation and duplication preserve upstream ordering', () async {
    final provider = await _loadProvider(session);

    final addedId = await provider.addAssistant(name: 'C');
    final copiedId = await provider.duplicateAssistant('assistant-a');

    expect(provider.assistants.map((assistant) => assistant.id), [
      'assistant-a',
      copiedId,
      'assistant-b',
      addedId,
    ]);
  });

  test('creation and duplication can place the result at the top', () async {
    final provider = await _loadProvider(session);

    final addedId = await provider.addAssistant(name: 'C', insertAtTop: true);
    final copiedId = await provider.duplicateAssistant(
      'assistant-b',
      insertAtTop: true,
    );

    expect(provider.assistants.map((assistant) => assistant.id), [
      copiedId,
      addedId,
      'assistant-a',
      'assistant-b',
    ]);

    final reloaded = await _loadProvider(session);
    expect(reloaded.assistants.map((assistant) => assistant.id), [
      copiedId,
      addedId,
      'assistant-a',
      'assistant-b',
    ]);
  });

  test('missing source does not change ordering in top mode', () async {
    final provider = await _loadProvider(session);

    final copiedId = await provider.duplicateAssistant(
      'missing',
      insertAtTop: true,
    );

    expect(copiedId, isNull);
    expect(provider.assistants.map((assistant) => assistant.id), [
      'assistant-a',
      'assistant-b',
    ]);
  });
}
