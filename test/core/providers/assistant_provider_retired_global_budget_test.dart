import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/reasoning_request.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';

import '../../support/business_preferences_test_harness.dart';

/// 「全局思考预算」这一层已删除：思考档位只由助手拥有，`null` 等于「自动」。
///
/// 备份里可能还带着旧键 `thinking_budget_v1`，恢复后必须被读一次、落到还没
/// 有档位的助手上，然后清除，否则老数据的档位会静默变成「自动」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BusinessPreferencesTestHarness harness;
  late BusinessPreferencesTestSession session;

  setUp(() async {
    harness = await BusinessPreferencesTestHarness.create();
    session = await harness.open();
  });

  tearDown(() => harness.dispose());

  Future<void> seedAssistants(List<Map<String, Object?>> assistants) =>
      session.preferences.setString('assistants_v1', jsonEncode(assistants));

  test('废弃的全局档位落到还没有档位的助手上，并清除该键', () async {
    await seedAssistants(const [
      {'id': 'untouched', 'name': '没设过'},
      {'id': 'explicit', 'name': '设过', 'thinkingBudget': 32000},
    ]);
    await session.preferences.setInt('thinking_budget_v1', 16000);

    final provider = AssistantProvider(preferences: session.preferences);
    await provider.loaded;

    expect(
      provider.getById('untouched')?.reasoning,
      Assistant.reasoningFromLegacyBudget(16000),
    );
    // 已有显式档位的助手不得被覆盖。
    expect(
      provider.getById('explicit')?.reasoning,
      Assistant.reasoningFromLegacyBudget(32000),
    );
    // 键被消费后清除，因此重复执行是空操作。
    expect(session.preferences.getInt('thinking_budget_v1'), isNull);
  });

  test('没有该键时不改写任何助手', () async {
    await seedAssistants(const [
      {'id': 'a', 'name': 'a'},
    ]);

    final provider = AssistantProvider(preferences: session.preferences);
    await provider.loaded;

    expect(provider.getById('a')?.reasoning, isNull);
  });

  test('所有助手都已有档位时，键仍被清除且不改写任何值', () async {
    await seedAssistants(const [
      {'id': 'a', 'name': 'a', 'thinkingBudget': 0},
    ]);
    await session.preferences.setInt('thinking_budget_v1', 16000);

    final provider = AssistantProvider(preferences: session.preferences);
    await provider.loaded;

    expect(provider.getById('a')?.reasoning, ReasoningRequest.off);
    expect(session.preferences.getInt('thinking_budget_v1'), isNull);
  });
}
