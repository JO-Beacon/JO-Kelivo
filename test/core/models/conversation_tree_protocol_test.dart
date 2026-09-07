import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/conversation_tree.dart';

void main() {
  group('ConversationTree frozen operation protocol', () {
    test('root siblings are branch nodes under an invisible root anchor', () {
      var tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['root-a', 'a1'],
      );
      tree = tree
          .createMessageBranchFromParent(
            branchId: 'root-b-branch',
            fromMessageId: null,
          )
          .appendToActiveBranch('root-b');

      expect(tree.isBranchNode('root-a'), isTrue);
      expect(tree.isBranchNode('root-b'), isTrue);
      expect(tree.isBranchNode('a1'), isFalse);
      expect(tree.childrenOf(null), unorderedEquals(['root-a', 'root-b']));
    });

    test(
      'deleteMessageOnly removes only the target and reattaches children',
      () {
        final tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['a', 'b', 'c', 'd'],
        );

        final updated = tree.deleteMessageOnly('b');

        expect(updated.edges.keys, unorderedEquals(['a', 'c', 'd']));
        expect(updated.edges['c']?.parentMessageId, 'a');
        expect(updated.edges['d']?.parentMessageId, 'c');
        expect(updated.activePath(), ['a', 'c', 'd']);
      },
    );

    test(
      'deleteMessageOnly keeps the active branch when its surviving prefix remains',
      () {
        final tree =
            ConversationTree.linear(
                  conversationId: 'conversation',
                  messageIds: const ['anchor'],
                )
                .createMessageBranch(branchId: 'alt', fromMessageId: 'anchor')
                .appendToActiveBranch('alt-1')
                .appendToActiveBranch('alt-2');
        final selectionsBefore = tree.branchSelections;
        final historyBefore = tree.activeBranchHistory;

        final updated = tree.deleteMessageOnly('alt-2');

        expect(updated.activeBranchId, 'alt');
        expect(updated.activePath(), const ['anchor', 'alt-1']);
        expect(updated.branches['alt']?.tipMessageId, 'alt-1');
        expect(updated.branchSelections, selectionsBefore);
        expect(updated.activeBranchHistory, historyBefore);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageOnly on a hidden nested tip keeps active state unchanged',
      () {
        final tree =
            ConversationTree.linear(
                  conversationId: 'conversation',
                  messageIds: const ['anchor', 'active-1', 'active-2'],
                )
                .createMessageBranch(
                  branchId: 'hidden',
                  fromMessageId: 'anchor',
                )
                .appendToActiveBranch('hidden-1')
                .createMessageBranch(
                  branchId: 'nested',
                  fromMessageId: 'hidden-1',
                )
                .appendToActiveBranch('nested-1')
                .appendToActiveBranch('nested-2')
                .switchBranch('root');
        final selectionsBefore = tree.branchSelections;
        final historyBefore = tree.activeBranchHistory;

        final updated = tree.deleteMessageOnly('nested-2');

        expect(updated.activeBranchId, 'root');
        expect(updated.activePath(), const ['anchor', 'active-1', 'active-2']);
        expect(updated.branches['nested']?.tipMessageId, 'nested-1');
        expect(updated.branchSelections, selectionsBefore);
        expect(updated.activeBranchHistory, historyBefore);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageAndFollowing removes the complete hidden descendant set',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['a', 'b', 'c'],
        );
        tree = tree
            .createMessageBranch(branchId: 'hidden', fromMessageId: 'b')
            .appendToActiveBranch('hidden-c')
            .appendToActiveBranch('hidden-d')
            .switchBranch('root');

        final updated = tree.deleteMessageAndFollowing('b');

        expect(updated.edges.keys, const {'a'});
        expect(updated.branches.keys, const {'root'});
        expect(updated.activePath(), ['a']);
      },
    );

    test(
      'deleteMessageAndFollowing rejects a non-branch leaf without mutation',
      () {
        final tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['leaf'],
        );
        final before = tree.fingerprint;

        expect(
          () => tree.deleteMessageAndFollowing('leaf'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'delete_message_and_following_leaf_not_allowed',
            ),
          ),
        );
        expect(tree.fingerprint, before);
      },
    );

    test(
      'deleteMessageNode keeps the active direct continuation and removes siblings',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['anchor', 'active'],
        );
        tree = tree
            .createMessageBranch(branchId: 'other', fromMessageId: 'anchor')
            .appendToActiveBranch('other-child')
            .switchBranch('root');
        tree = tree.appendToActiveBranch('active-child');

        // 契约 §4.4 修订：收掉整个分叉，只留活动血脉。
        // other 分支（other-child）随分叉一并删除。
        final updated = tree.deleteMessageNode('active');

        expect(updated.edges.containsKey('active'), isFalse);
        expect(updated.edges['active-child']?.parentMessageId, 'anchor');
        expect(updated.edges.containsKey('other-child'), isFalse);
        expect(updated.activePath(), const ['anchor', 'active-child']);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageNode removes every sibling subtree when the target is a leaf',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['anchor'],
        );
        tree = tree
            .createBranch(
              branchId: 'target',
              fromMessageId: 'anchor',
              tipMessageId: 'target-message',
            )
            .createBranch(
              branchId: 'sibling',
              fromMessageId: 'anchor',
              tipMessageId: 'sibling-message',
            )
            .switchBranch('sibling')
            .appendToActiveBranch('sibling-tail')
            .switchBranch('target');

        final updated = tree.deleteMessageNode('target-message');

        expect(updated.edges.keys, const {'anchor'});
        expect(updated.branches.keys, const {'root'});
        expect(updated.activePath(), const ['anchor']);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageNode collapses the whole fork and keeps only the active lineage',
      () {
        // 场景：A 是分叉锚点，A→B1→C1 与 A→B2→C2 两条分支，
        // 当前活动分支是 B2 一侧（C2 在看）。
        // 契约 §4.4 修订语义：对 B2「删除此分支节点」= 收掉 A 下
        // 所有分支子树（B1/C1/B2 全删），仅活动血脉 C2 重挂 A。
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['A'],
        );
        tree = tree
            .createMessageBranch(branchId: 'b1', fromMessageId: 'A')
            .appendToActiveBranch('B1')
            .appendToActiveBranch('C1')
            .switchBranch('root')
            .createMessageBranch(branchId: 'b2', fromMessageId: 'A')
            .appendToActiveBranch('B2')
            .appendToActiveBranch('C2');

        final updated = tree.deleteMessageNode('B2');

        expect(updated.edges.keys, const {'A', 'C2'});
        expect(updated.edges['C2']?.parentMessageId, 'A');
        expect(updated.activePath(), const ['A', 'C2']);
        expect(updated.siblingBranchIdsByMessageId(), isEmpty);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageNode collapses the fork even when the active lineage is the sibling side',
      () {
        // 活动分支在 B1 一侧时，对 B2「删除此分支节点」同样收掉
        // 整个 A 分叉：B2/C2 删除，B1 的活动血脉 C1 重挂 A。
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['A'],
        );
        tree = tree
            .createMessageBranch(branchId: 'b1', fromMessageId: 'A')
            .appendToActiveBranch('B1')
            .appendToActiveBranch('C1')
            .switchBranch('root')
            .createMessageBranch(branchId: 'b2', fromMessageId: 'A')
            .appendToActiveBranch('B2')
            .appendToActiveBranch('C2')
            .switchBranch('b1');

        final updated = tree.deleteMessageNode('B2');

        expect(updated.edges.keys, const {'A', 'B1', 'C1'});
        expect(updated.edges['B1']?.parentMessageId, 'A');
        expect(updated.activePath(), const ['A', 'B1', 'C1']);
        expect(updated.siblingBranchIdsByMessageId(), isEmpty);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageNode keeps only the active direct child when the target itself forks',
      () {
        // 目标 B2 自己也是分叉锚点（下有 C2、C3 两子）：收掉 A 下
        // 全部分支后，仅保留 B2 的活动直接子（C2 血脉）重挂 A。
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['A'],
        );
        tree = tree
            .createMessageBranch(branchId: 'b1', fromMessageId: 'A')
            .appendToActiveBranch('B1')
            .appendToActiveBranch('C1')
            .switchBranch('root')
            .createMessageBranch(branchId: 'b2', fromMessageId: 'A')
            .appendToActiveBranch('B2')
            .createMessageBranch(branchId: 'c3', fromMessageId: 'B2')
            .appendToActiveBranch('C3')
            .switchBranch('b2')
            .appendToActiveBranch('C2');

        final updated = tree.deleteMessageNode('B2');

        expect(updated.edges.keys, const {'A', 'C2'});
        expect(updated.edges['C2']?.parentMessageId, 'A');
        expect(updated.activePath(), const ['A', 'C2']);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageNodes collapses the fork per selected node and drops targets outside any active lineage',
      () {
        // 多选统一为「删除此分支节点」语义（契约 §4.4 修订）：
        // 选中 B2 → 收 A 下全部分支、保留 C2 血脉；随后 C2 也在
        // 选中集合（无子可留）→ C2 一并删除。终态只剩 A。
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['A'],
        );
        tree = tree
            .createMessageBranch(branchId: 'b1', fromMessageId: 'A')
            .appendToActiveBranch('B1')
            .appendToActiveBranch('C1')
            .switchBranch('root')
            .createMessageBranch(branchId: 'b2', fromMessageId: 'A')
            .appendToActiveBranch('B2')
            .appendToActiveBranch('C2');

        final updated = tree.deleteMessageNodes({'B2', 'C2'});

        expect(updated.edges.keys, const {'A'});
        expect(updated.activePath(), const ['A']);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageNodes removes a non-branch leaf without touching sibling forks',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['parent', 'active', 'active-child'],
        );
        tree = tree
            .createMessageBranch(branchId: 'sibling', fromMessageId: 'parent')
            .appendToActiveBranch('sibling-child')
            .switchBranch('root');

        // active-child 是叶子且父节点 active 只有它一个子 → 非分支
        // 节点：删除该消息本身；parent 处的分叉保持原样。
        final updated = tree.deleteMessageNodes({'active-child'});

        expect(updated.edges.containsKey('active-child'), isFalse);
        expect(updated.edges['active']?.parentMessageId, 'parent');
        expect(updated.edges.containsKey('sibling-child'), isTrue);
        expect(updated.branches.keys, containsAll(['root', 'sibling']));
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteMessageNodes keeps unselected descendants when a non-branch ancestor is selected',
      () {
        final tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['parent', 'first', 'middle', 'second', 'tail'],
        );

        // 线性链上没有分叉，first/second 均为非分支节点：删除消息
        // 本身，未选中后代沿链上提。
        final updated = tree.deleteMessageNodes({'first', 'second'});

        expect(updated.edges.keys, const {'parent', 'middle', 'tail'});
        expect(updated.edges['middle']?.parentMessageId, 'parent');
        expect(updated.edges['tail']?.parentMessageId, 'middle');
        expect(updated.activePath(), const ['parent', 'middle', 'tail']);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleteAllBranches removes every subtree below the same anchor only',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['before', 'anchor'],
        );
        tree = tree
            .createMessageBranch(branchId: 'left', fromMessageId: 'anchor')
            .appendToActiveBranch('left-child')
            .switchBranch('root')
            .appendToActiveBranch('right')
            .appendToActiveBranch('right-child');

        final updated = tree.deleteAllBranches('right');

        expect(updated.edges.keys, const {'before', 'anchor'});
        expect(updated.edges['anchor']?.parentMessageId, 'before');
        expect(updated.activePath(), ['before', 'anchor']);
      },
    );

    test(
      'deleteAllBranches keeps ancestor branches outside the target anchor',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['before', 'anchor', 'ancestor-tail'],
        );
        tree = tree
            .createMessageBranch(
              branchId: 'ancestor-alt',
              fromMessageId: 'anchor',
            )
            .appendToActiveBranch('ancestor-alt-tail')
            .switchBranch('root')
            .createMessageBranch(
              branchId: 'nested-a',
              fromMessageId: 'ancestor-tail',
            )
            .appendToActiveBranch('nested-a-tail')
            .switchBranch('root')
            .appendToActiveBranch('nested-b-tail')
            .appendToActiveBranch('nested-b-child');

        final updated = tree.deleteAllBranches('nested-b-tail');

        expect(updated.edges.keys, const {
          'before',
          'anchor',
          'ancestor-tail',
          'ancestor-alt-tail',
        });
        expect(updated.branches.keys, containsAll(['root', 'ancestor-alt']));
        expect(updated.branchPath('root'), const [
          'before',
          'anchor',
          'ancestor-tail',
        ]);
        expect(updated.branchPath('ancestor-alt'), const [
          'before',
          'anchor',
          'ancestor-alt-tail',
        ]);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test('invalid branch operation fails without changing the source tree', () {
      final tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['a', 'b'],
      );
      final before = tree.fingerprint;

      expect(() => tree.deleteMessageNode('b'), throwsStateError);
      expect(() => tree.deleteMessageOnly('missing'), throwsStateError);
      expect(tree.fingerprint, before);
    });

    test('tree transform result exposes one authoritative deletion diff', () {
      final tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['a', 'b', 'c'],
      );
      final result = tree.deleteMessageAndFollowingResult('b');

      expect(result.before, same(tree));
      expect(result.after.edges.keys, const {'a'});
      expect(result.deletedMessageIds, const {'b', 'c'});
      expect(result.previousActiveBranchId, 'root');
      expect(result.activeBranchId, 'root');
      expect(result.activeBranchChanged, isFalse);
    });

    test(
      'deleting the active branch falls back through explicit activity history',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['anchor'],
        );
        tree = tree
            .createMessageBranch(branchId: 'branch-a', fromMessageId: 'anchor')
            .appendToActiveBranch('a1')
            .switchBranch('root')
            .createMessageBranch(branchId: 'branch-b', fromMessageId: 'anchor')
            .appendToActiveBranch('b1')
            .switchBranch('branch-a')
            .switchBranch('branch-b');

        final updated = tree.deleteCurrentBranch('b1');

        // 契约 §4.3 修订：branch-b 删除后 anchor 锚点降级（仅剩 a1），
        // 停锚分支 root 继承覆盖分支 branch-a 的尖端，branch-a 记录被
        // 吸收清理。回退首选 branch-a 已并入 root，活动分支落到 root，
        // 其内容 a1 保持可见（可达即可见，契约 §8）。
        expect(updated.activeBranchId, 'root');
        expect(updated.activeBranchHistory, isNot(contains('branch-b')));
        expect(updated.activePath(), ['anchor', 'a1']);
        expect(updated.branches['root']?.tipMessageId, 'a1');
        expect(updated.branches.containsKey('branch-a'), isFalse);
        expect(updated.branches.containsKey('branch-b'), isFalse);
      },
    );

    test(
      'deleting the original branch after cloning a leaf sibling activates the clone',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['parent', 'original', 'following'],
        );
        tree = tree
            .createBranch(
              branchId: 'clone',
              fromMessageId: 'parent',
              tipMessageId: 'clone-message',
            )
            .switchBranch('root');

        final updated = tree.deleteCurrentBranch('original');

        expect(updated.activePath(), const ['parent', 'clone-message']);
        expect(updated.activeBranchId, 'clone');
        expect(updated.siblingBranchIdsByMessageId(), isEmpty);
        expect(() => updated.validateIntegrity(), returnsNormally);
      },
    );

    test(
      'deleting a branch uses recent branch ids when tree history is incomplete',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['parent', 'original', 'following'],
        );
        tree = tree
            .createBranch(
              branchId: 'clone',
              fromMessageId: 'parent',
              tipMessageId: 'clone-message',
            )
            .switchBranch('root');
        tree = ConversationTree(
          conversationId: tree.conversationId,
          activeBranchId: tree.activeBranchId,
          branches: tree.branches,
          edges: tree.edges,
          branchSelections: tree.branchSelections,
          activeBranchHistory: const <String>[],
        );

        final updated = tree.deleteCurrentBranch(
          'original',
          recentBranchIds: const <String>['clone'],
        );

        expect(updated.activeBranchId, 'clone');
        expect(updated.activePath(), const ['parent', 'clone-message']);
      },
    );

    test(
      'deleting the active branch fails when activity history has no survivor',
      () {
        final tree = ConversationTree(
          conversationId: 'conversation',
          activeBranchId: 'active',
          branches: {
            'previous': ConversationBranch(
              id: 'previous',
              conversationId: 'conversation',
              tipMessageId: 'previous-message',
              createdAt: DateTime.utc(2026),
            ),
            'active': ConversationBranch(
              id: 'active',
              conversationId: 'conversation',
              tipMessageId: 'active-message',
              createdAt: DateTime.utc(2026, 1, 2),
            ),
          },
          edges: const {
            'anchor': MessageTreeEdge(
              messageId: 'anchor',
              parentMessageId: null,
            ),
            'previous-message': MessageTreeEdge(
              messageId: 'previous-message',
              parentMessageId: 'anchor',
            ),
            'active-message': MessageTreeEdge(
              messageId: 'active-message',
              parentMessageId: 'anchor',
            ),
          },
        );
        final before = tree.fingerprint;

        expect(
          () => tree.deleteCurrentBranch('active-message'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'delete_current_branch_history_unavailable',
            ),
          ),
        );
        expect(tree.fingerprint, before);
      },
    );
  });
}
