import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/home/widgets/side_drawer.dart';

void main() {
  group('resolveAssistantDropTarget', () {
    test('dragging down stops right after the neighbour it was dropped on', () {
      // 框架实测值：4 项，把第 1 项往下拖过 1.6 格 -> old=0 new=2，
      // 期望结果 [B, C, A, D]，也就是插到 D 之前。
      final drop = resolveAssistantDropTarget(
        oldIndex: 0,
        newIndex: 2,
        length: 4,
      );

      expect(drop.neighborIndex, 3);
      expect(drop.insertAfter, isFalse);
    });

    test('dragging down a single step still moves one slot', () {
      // old=0 new=1 表示移除后插到索引 1，即 [B, A, C, D]：落点是 C。
      // 旧实现在这里再减一，把落点算成被拖项自己，导致完全无反应。
      final drop = resolveAssistantDropTarget(
        oldIndex: 0,
        newIndex: 1,
        length: 4,
      );

      expect(drop.neighborIndex, 2);
      expect(drop.insertAfter, isFalse);
    });

    test('dragging up stops right before the neighbour', () {
      // 框架实测值：把第 4 项往上拖两格 -> old=3 new=1，期望 [A, D, B, C]。
      final drop = resolveAssistantDropTarget(
        oldIndex: 3,
        newIndex: 1,
        length: 4,
      );

      expect(drop.neighborIndex, 1);
      expect(drop.insertAfter, isFalse);
    });

    test('dropping past the last entry appends after it', () {
      final drop = resolveAssistantDropTarget(
        oldIndex: 0,
        newIndex: 3,
        length: 4,
      );

      expect(drop.neighborIndex, 3);
      expect(drop.insertAfter, isTrue);
    });

    test('out of range indexes are clamped instead of dropped', () {
      final below = resolveAssistantDropTarget(
        oldIndex: 2,
        newIndex: -5,
        length: 4,
      );
      expect(below.neighborIndex, 0);
      expect(below.insertAfter, isFalse);

      final above = resolveAssistantDropTarget(
        oldIndex: 0,
        newIndex: 99,
        length: 4,
      );
      expect(above.neighborIndex, 3);
      expect(above.insertAfter, isTrue);
    });
  });

  group('resolveAssistantDropPlacement', () {
    // 列表布局：U1(未分组), H_A(组A标题), A1, A2, H_B(组B标题), B1
    const isHeader = [false, true, false, false, true, false];
    const groupIds = [null, 'gA', 'gA', 'gA', 'gB', 'gB'];
    const assistantIds = ['U1', null, 'A1', 'A2', null, 'B1'];
    const entries = {
      null: ['U1'],
      'gA': ['A1', 'A2'],
      'gB': ['B1'],
    };
    String? firstOf(String? g) => entries[g]?.first;
    String? lastOf(String? g) => entries[g]?.last;

    AssistantDropPlacement place(int neighbor, bool after) =>
        resolveAssistantDropPlacement(
          neighborIndex: neighbor,
          insertAfter: after,
          isHeader: isHeader,
          groupIds: groupIds,
          assistantIds: assistantIds,
          firstMemberOf: firstOf,
          lastMemberOf: lastOf,
        );

    test('assistant neighbour keeps its group and position', () {
      final p = place(3, false); // 插在 A2 之前
      expect(p.groupId, 'gA');
      expect(p.anchorId, 'A2');
      expect(p.insertAfter, isFalse);
    });

    test('after a header joins that group at first position', () {
      final p = place(1, true); // H_A 之后
      expect(p.groupId, 'gA');
      expect(p.anchorId, 'A1');
      expect(p.insertAfter, isFalse);
    });

    test('before a header lands at the END of the previous group', () {
      // B01 第二阶段根因：拖到组A末尾与组B标题之间的缝隙，邻居是 H_B、
      // 插在它之前 —— 语义应是"组A末尾"，而不是"加入组B排第一"。
      final p = place(4, false); // H_B 之前
      expect(p.groupId, 'gA');
      expect(p.anchorId, 'A2');
      expect(p.insertAfter, isTrue);
    });

    test('before an ungrouped-side header moves out of group', () {
      // H_A 之前上面是未分组助手 U1：应移出分组并排在 U1 之后。
      final p = place(1, false);
      expect(p.groupId, isNull);
      expect(p.anchorId, 'U1');
      expect(p.insertAfter, isTrue);
    });

    test('header as first entry falls back to its first position', () {
      final p0 = place(0, false);
      expect(p0.groupId, isNull);
      expect(p0.anchorId, 'U1');
      expect(p0.insertAfter, isFalse);
    });
  });
}
