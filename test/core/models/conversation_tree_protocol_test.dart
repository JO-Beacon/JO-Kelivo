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

        final updated = tree.deleteMessageNode('active');

        expect(updated.edges.containsKey('active'), isFalse);
        expect(updated.edges['active-child']?.parentMessageId, 'anchor');
        expect(updated.edges.containsKey('other-child'), isTrue);
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

        expect(updated.activeBranchId, 'branch-a');
        expect(updated.activeBranchHistory, isNot(contains('branch-b')));
        expect(updated.activePath(), ['anchor', 'a1']);
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
