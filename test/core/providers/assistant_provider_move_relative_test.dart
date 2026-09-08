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
        {'id': 'assistant-c', 'name': 'C'},
        {'id': 'assistant-d', 'name': 'D'},
      ]),
    );
  });

  tearDown(() => harness.dispose());

  List<String> ids(AssistantProvider provider) =>
      provider.assistants.map((assistant) => assistant.id).toList();

  test('moves an assistant right after the drop neighbour', () async {
    final provider = await _loadProvider(session);

    await provider.moveAssistantRelativeTo(
      assistantId: 'assistant-a',
      targetId: 'assistant-c',
      insertAfter: true,
    );

    expect(ids(provider), [
      'assistant-b',
      'assistant-c',
      'assistant-a',
      'assistant-d',
    ]);
  });

  test('moves an assistant right before the drop neighbour', () async {
    final provider = await _loadProvider(session);

    await provider.moveAssistantRelativeTo(
      assistantId: 'assistant-d',
      targetId: 'assistant-b',
      insertAfter: false,
    );

    expect(ids(provider), [
      'assistant-a',
      'assistant-d',
      'assistant-b',
      'assistant-c',
    ]);
  });

  test('keeps the order untouched when the neighbour is unknown', () async {
    final provider = await _loadProvider(session);

    await provider.moveAssistantRelativeTo(
      assistantId: 'assistant-a',
      targetId: 'assistant-missing',
      insertAfter: true,
    );

    expect(ids(provider), [
      'assistant-a',
      'assistant-b',
      'assistant-c',
      'assistant-d',
    ]);
  });

  test('moving onto itself is a no-op', () async {
    final provider = await _loadProvider(session);

    await provider.moveAssistantRelativeTo(
      assistantId: 'assistant-b',
      targetId: 'assistant-b',
      insertAfter: true,
    );

    expect(ids(provider), [
      'assistant-a',
      'assistant-b',
      'assistant-c',
      'assistant-d',
    ]);
  });
}
