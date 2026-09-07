import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/conversation_tree.dart';

/// 契约 §4.3 修订与 §8 验收不变量：
/// 「删除或切换后，任何从根可达的消息必须仍然可见：要么在活动路径上，
/// 要么其直接父消息仍是分叉锚点。」
void expectVisible(ConversationTree tree, String messageId) {
  expect(
    tree.edges.containsKey(messageId),
    isTrue,
    reason: '$messageId 应仍存在于树中',
  );
  final onActivePath = tree.activePath().contains(messageId);
  final parent = tree.edges[messageId]!.parentMessageId;
  final navigable = tree.childrenOf(parent).length >= 2;
  expect(
    onActivePath || navigable,
    isTrue,
    reason: '$messageId 既不在活动路径上，其直接父消息也不是分叉锚点（搁浅）',
  );
}

/// 契约 §4.3 场景树：m0 ← second-m1 ← {nested-m2, sib-m2}。
///
/// second 在锚点 second-m1 上停留（尖端即锚点），nested 与 sib 从锚点
/// 分叉。活动历史经 second → nested，使「删除当前分支」的回退目标为
/// second（复现用户经由小地图切换的真实路径）。
ConversationTree buildNestedAnchorTree() {
  var tree = ConversationTree.linear(
    conversationId: 'conversation',
    messageIds: const ['m0'],
    createdAt: DateTime.utc(2026, 1, 1),
  );
  tree = tree.createMessageBranch(
    branchId: 'second',
    fromMessageId: 'm0',
    createdAt: DateTime.utc(2026, 1, 2),
  );
  tree = tree.appendToActiveBranch('second-m1', branchId: 'second');
  tree = tree.createMessageBranch(
    branchId: 'nested',
    fromMessageId: 'second-m1',
    createdAt: DateTime.utc(2026, 1, 3),
  );
  tree = tree.appendToActiveBranch('nested-m2', branchId: 'nested');
  tree = tree.createMessageBranch(
    branchId: 'sib',
    fromMessageId: 'second-m1',
    createdAt: DateTime.utc(2026, 1, 4),
  );
  tree = tree.appendToActiveBranch('sib-m2', branchId: 'sib');
  tree = tree.switchBranch('second');
  return tree.switchBranch('nested');
}

void main() {
  group('删除当前分支的锚点降级合并（契约 §4.3 修订）', () {
    test('嵌套分支删除后，唯一存活兄弟并入停锚分支并保持可见', () {
      final before = buildNestedAnchorTree();
      expect(before.activeBranchId, 'nested');

      final after = before.deleteCurrentBranch('nested-m2');

      // 回退目标仍是 second（契约：删除后切回上一个活动分支）。
      expect(after.activeBranchId, 'second');
      // 锚点降级合并：second 继承合并后的尖端，sib 作为重复记录剔除。
      expect(after.branches['second']?.tipMessageId, 'sib-m2');
      expect(after.branches.containsKey('sib'), isFalse);
      expect(after.branches.keys, {'root', 'second'});
      // 存活子及其后续必须可见（§8 不变量）。
      expect(after.activePath(), const ['m0', 'second-m1', 'sib-m2']);
      expectVisible(after, 'second-m1');
      expectVisible(after, 'sib-m2');
      // 没有多删：nested-m2 之外的消息都在。
      expect(after.edges.containsKey('nested-m2'), isFalse);
      expect(after.edges.containsKey('sib-m2'), isTrue);
      expect(after.validateIntegrity, returnsNormally);
    });

    test('删除另一侧（sib）同样触发合并，nested 内容保持可见', () {
      var tree = buildNestedAnchorTree();
      tree = tree.switchBranch('sib');

      final after = tree.deleteCurrentBranch('sib-m2');

      expect(after.branches['second']?.tipMessageId, 'nested-m2');
      expect(after.branches.containsKey('nested'), isFalse);
      expectVisible(after, 'nested-m2');
      expect(after.validateIntegrity, returnsNormally);
    });

    test('简单两分支：停锚的 root 吸收存活兄弟，不留下搁浅记录', () {
      var tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['m0', 'm1'],
        createdAt: DateTime.utc(2026, 1, 1),
      );
      tree = tree.createMessageBranch(branchId: 'b', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('b-m2', branchId: 'b');
      tree = tree.createMessageBranch(branchId: 'c', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('c-m2', branchId: 'c');

      final after = tree.deleteCurrentBranch('c-m2');

      // m1 从两个直接子降级为一个：root（停在 m1 的停锚分支）吸收 b。
      expect(after.branches.keys, {'root'});
      expect(after.branches['root']?.tipMessageId, 'b-m2');
      // 回退目标 b 已被合并，跳到继承者 root，内容仍然完整可见。
      expect(after.activeBranchId, 'root');
      expect(after.activePath(), const ['m0', 'm1', 'b-m2']);
      expectVisible(after, 'b-m2');
      expect(after.validateIntegrity, returnsNormally);
    });

    test('三分支删除一个不降级：不合并、记录保持原样', () {
      var tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['m0', 'm1'],
        createdAt: DateTime.utc(2026, 1, 1),
      );
      tree = tree.createMessageBranch(branchId: 'b', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('b-m2', branchId: 'b');
      tree = tree.createMessageBranch(branchId: 'c', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('c-m2', branchId: 'c');
      tree = tree.createMessageBranch(branchId: 'd', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('d-m2', branchId: 'd');

      final after = tree.deleteCurrentBranch('d-m2');

      // m1 仍有两个直接子（b-m2、c-m2），锚点未降级，不得合并。
      expect(after.branches.keys, {'root', 'b', 'c'});
      expect(after.branches['root']?.tipMessageId, 'm1');
      expect(after.branches['b']?.tipMessageId, 'b-m2');
      expect(after.branches['c']?.tipMessageId, 'c-m2');
      expectVisible(after, 'b-m2');
      expectVisible(after, 'c-m2');
      expect(after.validateIntegrity, returnsNormally);
    });

    test('存活子已位于穿过锚点的分支路径上时，无需合并', () {
      var tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['m0', 'm1', 'm2'],
        createdAt: DateTime.utc(2026, 1, 1),
      );
      tree = tree.createMessageBranch(
        branchId: 'c-branch',
        fromMessageId: 'm1',
      );
      tree = tree.appendToActiveBranch('c-m2', branchId: 'c-branch');

      final after = tree.deleteCurrentBranch('c-m2');

      // 存活子 m2 位于 root 穿过锚点 m1 的路径上：路径自然连续，不合并。
      expect(after.branches.keys, {'root'});
      expect(after.branches['root']?.tipMessageId, 'm2');
      expect(after.activePath(), const ['m0', 'm1', 'm2']);
      expectVisible(after, 'm2');
      expect(after.validateIntegrity, returnsNormally);
    });

    test('幸存者的子分支保留，父关系改挂到合并后的分支', () {
      var tree = buildNestedAnchorTree();
      // 在 sib-m2 下再分叉（先切到 sib 以便从 sib-m2 延伸）。
      tree = tree.switchBranch('sib');
      tree = tree.createMessageBranch(
        branchId: 'sibA',
        fromMessageId: 'sib-m2',
        createdAt: DateTime.utc(2026, 1, 5),
      );
      tree = tree.appendToActiveBranch('sibA-m3', branchId: 'sibA');
      tree = tree.createMessageBranch(
        branchId: 'sibB',
        fromMessageId: 'sib-m2',
        createdAt: DateTime.utc(2026, 1, 6),
      );
      tree = tree.appendToActiveBranch('sibB-m3', branchId: 'sibB');
      tree = tree.switchBranch('second');
      tree = tree.switchBranch('nested');

      final after = tree.deleteCurrentBranch('nested-m2');

      // second 吸收 sib 的尖端；sib-m2 仍是分叉锚点（两个直接子）。
      expect(after.branches['second']?.tipMessageId, 'sib-m2');
      expect(after.branches.containsKey('sib'), isFalse);
      expect(after.branches.containsKey('sibA'), isTrue);
      expect(after.branches.containsKey('sibB'), isTrue);
      // sibA 的父分支原本是 sib，改挂到合并后的 second。
      expect(after.branches['sibA']?.parentBranchId, 'second');
      expect(after.childrenOf('sib-m2').length, 2);
      expectVisible(after, 'sib-m2');
      expectVisible(after, 'sibA-m3');
      expectVisible(after, 'sibB-m3');
      expect(after.validateIntegrity, returnsNormally);
    });

    test('多条停锚分支由创建最早者继承', () {
      var tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['m0', 'm1'],
        createdAt: DateTime.utc(2026, 1, 1),
      );
      // x 停在 m1 且创建时间早于 root，成为继承者。
      tree = tree.createMessageBranch(
        branchId: 'x',
        fromMessageId: 'm1',
        createdAt: DateTime.utc(2025, 12, 31),
      );
      tree = tree.switchBranch('root');
      tree = tree.createMessageBranch(branchId: 'b', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('b-m2', branchId: 'b');
      tree = tree.createMessageBranch(branchId: 'c', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('c-m2', branchId: 'c');

      final after = tree.deleteCurrentBranch('c-m2');

      expect(after.branches.keys, {'x'});
      expect(after.branches['x']?.tipMessageId, 'b-m2');
      expect(after.activeBranchId, 'x');
      expect(after.activePath(), const ['m0', 'm1', 'b-m2']);
      expectVisible(after, 'b-m2');
      expect(after.validateIntegrity, returnsNormally);
    });

    test('中间层停锚记录吸收回退链（删除后活动分支回滚为停锚）', () {
      var tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['m0', 'm1'],
        createdAt: DateTime.utc(2026, 1, 1),
      );
      tree = tree.createMessageBranch(branchId: 'x', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('x-m2', branchId: 'x');
      tree = tree.createMessageBranch(branchId: 'y', fromMessageId: 'x-m2');
      tree = tree.appendToActiveBranch('y-m3', branchId: 'y');
      tree = tree.createMessageBranch(branchId: 'z', fromMessageId: 'x-m2');
      tree = tree.appendToActiveBranch('z-m3', branchId: 'z');

      final after = tree.deleteCurrentBranch('z-m3');

      // x-m2 从两个直接子降级为一个：x（停在 x-m2）吸收 y 侧。
      expect(after.branches.keys, {'root', 'x'});
      expect(after.branches['x']?.tipMessageId, 'y-m3');
      expect(after.activePath(), const ['m0', 'm1', 'x-m2', 'y-m3']);
      expectVisible(after, 'y-m3');
      expect(after.validateIntegrity, returnsNormally);
    });
  });

  group('删除此分支节点（§4.4）的锚点降级合并', () {
    test('活动路径止于目标时无血脉可保，锚点下分支全清', () {
      var tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['m0', 'm1'],
        createdAt: DateTime.utc(2026, 1, 1),
      );
      tree = tree.createMessageBranch(branchId: 'b', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('b-m2', branchId: 'b');
      tree = tree.createMessageBranch(branchId: 'c', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('c-m2', branchId: 'c');
      tree = tree.createMessageBranch(branchId: 'c1', fromMessageId: 'c-m2');
      tree = tree.appendToActiveBranch('c1-m3', branchId: 'c1');
      tree = tree.createMessageBranch(branchId: 'c2', fromMessageId: 'c-m2');
      tree = tree.appendToActiveBranch('c2-m3', branchId: 'c2');
      // 切回尖端停在 c-m2 的 c，活动路径恰好止于目标分支节点。
      tree = tree.switchBranch('c');

      final after = tree.deleteMessageNode('c-m2');

      // 契约 §4.4 修订：目标即活动末端，没有血脉可保，m1 下全部分支
      // （b 侧与 c 侧含 c1/c2 子分支）一并删除，与「删除所有分支」一致。
      expect(after.branches.keys, {'root'});
      expect(after.branches['root']?.tipMessageId, 'm1');
      expect(after.activePath(), const ['m0', 'm1']);
      expect(after.edges.containsKey('b-m2'), isFalse);
      expect(after.edges.containsKey('c1-m3'), isFalse);
      expect(after.validateIntegrity, returnsNormally);
    });

    test('活动血脉提拔后锚点降级，合并入停锚分支', () {
      var tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['m0', 'm1'],
        createdAt: DateTime.utc(2026, 1, 1),
      );
      tree = tree.createMessageBranch(branchId: 'b', fromMessageId: 'm1');
      tree = tree.appendToActiveBranch('b-m2', branchId: 'b');
      // root 一侧活动血脉延续到 m2-tail；目标 b-m2 是兄弟侧分支节点。
      tree = tree.switchBranch('root').appendToActiveBranch('m2-tail');

      final after = tree.deleteMessageNode('b-m2');

      // m1 下只剩提拔血脉 m2-tail（原本就是 root 的直接子），
      // 锚点降级合并后 root 吸收全部内容，b 分支随分叉消失。
      expect(after.branches.keys, {'root'});
      expect(after.branches['root']?.tipMessageId, 'm2-tail');
      expect(after.activePath(), const ['m0', 'm1', 'm2-tail']);
      expect(after.edges.containsKey('b-m2'), isFalse);
      expect(after.validateIntegrity, returnsNormally);
    });
  });

  group('存量降级锚点归一化（契约阶段 2）', () {
    ConversationTree strandedTree() {
      // 手工构造历史 BUG 产生的搁浅状态：second 停在锚点 second-m1，
      // sib 覆盖唯一存活子 sib-m2，但既不在活动路径也无分支导航。
      return ConversationTree(
        conversationId: 'conversation',
        activeBranchId: 'second',
        branches: {
          'root': ConversationBranch(
            id: 'root',
            conversationId: 'conversation',
            tipMessageId: 'm0',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          'second': ConversationBranch(
            id: 'second',
            conversationId: 'conversation',
            tipMessageId: 'second-m1',
            parentBranchId: 'root',
            forkAnchorMessageId: 'm0',
            createdAt: DateTime.utc(2026, 1, 2),
          ),
          'sib': ConversationBranch(
            id: 'sib',
            conversationId: 'conversation',
            tipMessageId: 'sib-m2',
            parentBranchId: 'second',
            forkAnchorMessageId: 'second-m1',
            createdAt: DateTime.utc(2026, 1, 3),
          ),
        },
        edges: const {
          'm0': MessageTreeEdge(messageId: 'm0', parentMessageId: null),
          'second-m1': MessageTreeEdge(
            messageId: 'second-m1',
            parentMessageId: 'm0',
          ),
          'sib-m2': MessageTreeEdge(
            messageId: 'sib-m2',
            parentMessageId: 'second-m1',
          ),
        },
        activeBranchHistory: const ['sib', 'root'],
      );
    }

    test('归一化修复搁浅分支并保持活动分支不变', () {
      final tree = strandedTree();

      final normalized = tree.normalizeDegradedAnchors();

      expect(normalized.activeBranchId, 'second');
      expect(normalized.branches['second']?.tipMessageId, 'sib-m2');
      expect(normalized.branches.containsKey('sib'), isFalse);
      expect(normalized.activePath(), const ['m0', 'second-m1', 'sib-m2']);
      expectVisible(normalized, 'sib-m2');
      expect(normalized.validateIntegrity, returnsNormally);
    });

    test('归一化幂等：重复执行结果不变', () {
      final normalized = strandedTree().normalizeDegradedAnchors();

      final again = normalized.normalizeDegradedAnchors();

      expect(again.fingerprint, normalized.fingerprint);
    });

    test('活动分支停在更高停锚点时，归一化沿链向下延伸', () {
      // active 停在 m0（root），整条 second-m1 → sib-m2 链搁浅。
      final tree = ConversationTree(
        conversationId: 'conversation',
        activeBranchId: 'root',
        branches: {
          'root': ConversationBranch(
            id: 'root',
            conversationId: 'conversation',
            tipMessageId: 'm0',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
          'second': ConversationBranch(
            id: 'second',
            conversationId: 'conversation',
            tipMessageId: 'second-m1',
            parentBranchId: 'root',
            forkAnchorMessageId: 'm0',
            createdAt: DateTime.utc(2026, 1, 2),
          ),
          'sib': ConversationBranch(
            id: 'sib',
            conversationId: 'conversation',
            tipMessageId: 'sib-m2',
            parentBranchId: 'second',
            forkAnchorMessageId: 'second-m1',
            createdAt: DateTime.utc(2026, 1, 3),
          ),
        },
        edges: const {
          'm0': MessageTreeEdge(messageId: 'm0', parentMessageId: null),
          'second-m1': MessageTreeEdge(
            messageId: 'second-m1',
            parentMessageId: 'm0',
          ),
          'sib-m2': MessageTreeEdge(
            messageId: 'sib-m2',
            parentMessageId: 'second-m1',
          ),
        },
        activeBranchHistory: const ['second', 'sib'],
      );

      final normalized = tree.normalizeDegradedAnchors();

      // 归一化按形态级联收敛：root 继承合并链的全部内容，
      // 中间层停锚残迹（second、sib）一并清理。
      expect(normalized.activeBranchId, 'root');
      expect(normalized.branches['root']?.tipMessageId, 'sib-m2');
      expect(normalized.branches.keys, {'root'});
      expect(normalized.activePath(), const ['m0', 'second-m1', 'sib-m2']);
      expectVisible(normalized, 'sib-m2');
      expect(normalized.validateIntegrity, returnsNormally);
    });
  });
}
