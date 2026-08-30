import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/providers/assistant_group_provider.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';

import '../../support/business_preferences_test_harness.dart';

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
        {'id': 'a', 'name': 'A'},
        {'id': 'b', 'name': 'B'},
        {'id': 'c', 'name': 'C'},
      ]),
    );
  });

  tearDown(() => harness.dispose());

  test('批量删除会保留至少一个助手', () async {
    final provider = AssistantProvider(preferences: session.preferences);
    await provider.loaded;

    expect(await provider.deleteAssistants(const ['a', 'b', 'c']), 2);
    expect(provider.assistants, hasLength(1));
    expect(await provider.deleteAssistants(const ['a']), 0);
  });

  test('批量修改分组并支持移出分组', () async {
    final provider = AssistantGroupProvider(preferences: session.preferences);
    final groupId = await provider.createGroup('Work');

    await provider.assignAssistantsToGroup(const ['a', 'b'], groupId);
    expect(provider.groupOfAssistant('a'), groupId);
    expect(provider.groupOfAssistant('b'), groupId);

    await provider.assignAssistantsToGroup(const ['a', 'b'], null);
    expect(provider.groupOfAssistant('a'), isNull);
    expect(provider.groupOfAssistant('b'), isNull);
  });
}
