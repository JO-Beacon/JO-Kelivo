import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/assistant_group_provider.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/features/home/widgets/side_drawer.dart';

import '../../../support/business_preferences_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 布局：entries = [hGA, a1, a2, hGB, b1]，a1/a2 归 GA，b1 归 GB。
  Future<
    ({
      AssistantProvider ap,
      AssistantGroupProvider gp,
      String a1,
      String a2,
      String b1,
      String gA,
      String gB,
    })
  >
  seed() async {
    final harness = await BusinessPreferencesTestHarness.create();
    final session = await harness.open();
    addTearDown(harness.dispose);

    final ap = AssistantProvider(preferences: session.preferences);
    await ap.loaded;
    final gp = AssistantGroupProvider(preferences: session.preferences);
    await gp.loaded;

    for (final name in ['a1', 'a2', 'b1']) {
      await ap.addAssistant(name: name);
    }
    final ids = ap.assistants.map((a) => a.id).toList();
    final gA = await gp.createGroup('GA');
    final gB = await gp.createGroup('GB');
    await gp.assignAssistantsToGroup([ids[0], ids[1]], gA);
    await gp.assignAssistantsToGroup([ids[2]], gB);
    return (ap: ap, gp: gp, a1: ids[0], a2: ids[1], b1: ids[2], gA: gA, gB: gB);
  }

  test('跨组落位必须跟随框架预览：插在谁之前就排在谁之前', () async {
    final s = await seed();

    // 框架路径 (4,2)：预览里 b1 落在 a1 与 a2 之间（a2 之前）。
    // 历史 bug：曾在此"纠正"为组尾（a2 之后），与预览冲突 → 松手跳一格。
    final drop = resolveAssistantDropTarget(
      oldIndex: 4,
      newIndex: 2,
      length: 5,
    );
    expect(drop.neighborIndex, 2);
    expect(drop.insertAfter, isFalse);

    s.gp.applyGroupAssignment(s.b1, s.gA);
    s.ap.applyOrderRelativeTo(
      assistantId: s.b1,
      targetId: s.a2,
      insertAfter: drop.insertAfter,
    );
    s.ap.notifyAssistantDirectoryChanged();
    s.gp.notifyAssignmentChanged();
    await s.gp.persistAssignment();
    await s.ap.persistAssistantOrder();

    final order = s.ap.assistants.map((a) => a.name).toList();
    expect(s.gp.groupOfAssistant(s.b1), s.gA);
    // 预览是"a2 之前"，落位就必须是 a2 之前。
    expect(order.indexOf('b1'), order.indexOf('a2') - 1);
  });

  test('贴着分组标题上方松手＝加入上一组并排在末尾', () async {
    final s = await seed();

    // 框架路径 (4,3)：预览里 b1 落在 a2 与 hGB 之间（GA 组末尾）。
    final drop = resolveAssistantDropTarget(
      oldIndex: 4,
      newIndex: 3,
      length: 5,
    );
    expect(drop.neighborIndex, 3); // hGB 标题
    expect(drop.insertAfter, isFalse);

    const isHeader = [true, false, false, true, false];
    const groupIds = ['GA', 'GA', 'GA', 'GB', 'GB'];
    const assistantIds = [null, 'a1', 'a2', null, 'b1'];
    final placement = resolveAssistantDropPlacement(
      neighborIndex: drop.neighborIndex,
      insertAfter: drop.insertAfter,
      isHeader: isHeader,
      groupIds: groupIds,
      assistantIds: assistantIds,
      firstMemberOf: (g) => g == 'GA' ? s.a1 : s.b1,
      lastMemberOf: (g) => g == 'GA' ? s.a2 : s.b1,
    );
    expect(placement.groupId, 'GA');
    expect(placement.anchorId, s.a2);
    expect(placement.insertAfter, isTrue);

    s.gp.applyGroupAssignment(s.b1, s.gA);
    s.ap.applyOrderRelativeTo(
      assistantId: s.b1,
      targetId: placement.anchorId!,
      insertAfter: placement.insertAfter,
    );
    s.ap.notifyAssistantDirectoryChanged();
    s.gp.notifyAssignmentChanged();
    await s.gp.persistAssignment();
    await s.ap.persistAssistantOrder();

    final order = s.ap.assistants.map((a) => a.name).toList();
    expect(s.gp.groupOfAssistant(s.b1), s.gA);
    expect(order.indexOf('b1'), order.indexOf('a2') + 1);
  });

  test('拖到组标题上方的缝隙＝未分组段末尾（跨组跳走真凶的回归测试）', () async {
    // 独立布局（全局顺序即创建顺序 u1, g1, u2, g2；GA 组含 g1、g2）：
    //   entries = [u1, u2, hGA, g1, g2]
    // 把 g1 从 GA 组拖到 u2 与 hGA 标题之间的缝隙（= 未分组段末尾）。
    // 历史 bug：未分组段不在分组索引里，锚点解析为 null → 整个重排序
    // 被跳过 → g1 留在原全局位置，落进未分组后显示在 u1 与 u2 之间，
    // 而松手预览是"u2 之后、标题之前"（2026-09-08 拖拽日志实测确认）。
    final harness = await BusinessPreferencesTestHarness.create();
    final session = await harness.open();
    addTearDown(harness.dispose);
    final ap = AssistantProvider(preferences: session.preferences);
    await ap.loaded;
    final gp = AssistantGroupProvider(preferences: session.preferences);
    await gp.loaded;
    for (final name in ['u1', 'g1', 'u2', 'g2']) {
      await ap.addAssistant(name: name);
    }
    final ids = ap.assistants.map((a) => a.id).toList();
    final u2 = ids[2];
    final g1 = ids[1];
    final gA = await gp.createGroup('GA');
    await gp.assignAssistantsToGroup([ids[1], ids[3]], gA);

    final drop = resolveAssistantDropTarget(
      oldIndex: 3, // g1
      newIndex: 2, // 移除 g1 后插在 hGA 之前
      length: 5,
    );
    expect(drop.neighborIndex, 2); // hGA 标题
    expect(drop.insertAfter, isFalse);

    const isHeader = [false, false, true, false, false];
    const groupIds = [null, null, 'GA', 'GA', 'GA'];
    const assistantIds = ['u1', 'u2', null, 'g1', 'g2'];
    // 生产接线：未分组段的成员从 ungrouped 列表取，不从 groupedByGroup 取。
    const ungroupedIds = ['u1', 'u2'];
    final placement = resolveAssistantDropPlacement(
      neighborIndex: drop.neighborIndex,
      insertAfter: drop.insertAfter,
      isHeader: isHeader,
      groupIds: groupIds,
      assistantIds: assistantIds,
      firstMemberOf: (g) => g == null ? ungroupedIds.first : 'g1',
      lastMemberOf: (g) => g == null ? ungroupedIds.last : 'g2',
    );
    // 缝隙归属未分组段末尾：锚点必须是 u2（修复前这里是 null）。
    expect(placement.groupId, isNull);
    expect(placement.anchorId, 'u2');
    expect(placement.insertAfter, isTrue);

    gp.applyGroupAssignment(g1, null);
    ap.applyOrderRelativeTo(
      assistantId: g1,
      targetId: u2,
      insertAfter: placement.insertAfter,
    );
    ap.notifyAssistantDirectoryChanged();
    gp.notifyAssignmentChanged();
    await gp.persistAssignment();
    await ap.persistAssistantOrder();

    // 落位结果：g1 排在 u2 之后（= 未分组段末尾，紧贴 GA 标题上方）。
    final order = ap.assistants.map((a) => a.name).toList();
    expect(gp.groupOfAssistant(g1), isNull);
    expect(order.indexOf('g1'), order.indexOf('u2') + 1);
    expect(order.indexOf('g1'), order.indexOf('u1') + 2);
  });

  test('拖入折叠的分组前会先展开它（否则助手投进去就看不见）', () async {
    final s = await seed();
    await s.gp.setGroupCollapsed(s.gA, true);
    expect(s.gp.isGroupCollapsed(s.gA), isTrue);

    // 生产链路：落点组折叠时先展开，再做换组与落位。
    if (s.gp.isGroupCollapsed(s.gA)) {
      await s.gp.setGroupCollapsed(s.gA, false);
    }
    expect(s.gp.isGroupCollapsed(s.gA), isFalse);

    s.gp.applyGroupAssignment(s.b1, s.gA);
    s.ap.applyOrderRelativeTo(
      assistantId: s.b1,
      targetId: s.a2,
      insertAfter: false,
    );
    s.ap.notifyAssistantDirectoryChanged();
    s.gp.notifyAssignmentChanged();
    await s.gp.persistAssignment();
    await s.ap.persistAssistantOrder();
    expect(s.gp.groupOfAssistant(s.b1), s.gA);
    expect(s.gp.isGroupCollapsed(s.gA), isFalse);
  });
}
