import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/conversation_tree.dart';

void main() {
  group('ConversationTree.linear', () {
    test('migrates a linear conversation into one root branch', () {
      final tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['u1', 'a1', 'u2', 'a2'],
      );

      expect(tree.activeBranchId, 'root');
      expect(tree.activePath(), const ['u1', 'a1', 'u2', 'a2']);
      expect(tree.branches['root']?.tipMessageId, 'a2');
    });

    test('keeps an empty conversation as an empty root branch', () {
      final tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const <String>[],
      );

      expect(tree.activePath(), isEmpty);
      expect(tree.branches['root']?.tipMessageId, isNull);
    });
  });

  group('ConversationTree branching', () {
    test('createBranch forks from an existing message and switches to it', () {
      final base = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['u1', 'a1', 'u2'],
      );

      final tree = base.createBranch(
        branchId: 'branch-a2',
        fromMessageId: 'u1',
        tipMessageId: 'a2-alt',
      );

      expect(tree.activeBranchId, 'branch-a2');
      expect(tree.activePath(), const ['u1', 'a2-alt']);
      expect(tree.branchPath('root'), const ['u1', 'a1', 'u2']);
    });

    test('appendToActiveBranch writes the next edge on the active tip', () {
      final base = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['u1', 'a1'],
      );

      final tree = base.appendToActiveBranch('u2');

      expect(tree.activePath(), const ['u1', 'a1', 'u2']);
      expect(tree.edges['u2']?.parentMessageId, 'a1');
    });

    test('sibling map only exposes divergent message slots', () {
      final legacy = ConversationTree(
        conversationId: 'conversation',
        activeBranchId: 'root',
        branches: <String, ConversationBranch>{
          'root': ConversationBranch(
            id: 'root',
            conversationId: 'conversation',
            tipMessageId: 'u2',
            createdAt: DateTime(2026, 1, 1),
          ),
          'legacy-a1-v0': ConversationBranch(
            id: 'legacy-a1-v0',
            conversationId: 'conversation',
            tipMessageId: 'a1-v0',
            createdAt: DateTime(2026, 1, 2),
          ),
        },
        edges: const <String, MessageTreeEdge>{
          'u1': MessageTreeEdge(messageId: 'u1', parentMessageId: null),
          'a1-v0': MessageTreeEdge(messageId: 'a1-v0', parentMessageId: 'u1'),
          'a1-v1': MessageTreeEdge(messageId: 'a1-v1', parentMessageId: 'u1'),
          'u2': MessageTreeEdge(messageId: 'u2', parentMessageId: 'a1-v1'),
        },
      );

      final siblings = legacy.siblingBranchIdsByMessageId();

      expect(siblings.keys, unorderedEquals(['a1-v0', 'a1-v1']));
      expect(siblings['a1-v1'], ['root', 'legacy-a1-v0']);
      expect(siblings.containsKey('u1'), isFalse);
    });

    test('prefers the most specific hidden branch for a message', () {
      final base = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['u1', 'a1'],
      );
      final firstFork = base
          .forkBranch(branchId: 'branch-first', fromMessageId: 'u1')
          .appendToActiveBranch('a1-first');
      final tree = firstFork
          .switchBranch('root')
          .forkBranch(branchId: 'branch-second', fromMessageId: 'u1')
          .appendToActiveBranch('a1-second');

      expect(tree.preferredBranchIdForMessage('a1'), 'root');
      expect(tree.preferredBranchIdForMessage('a1-first'), 'branch-first');
      expect(tree.preferredBranchIdForMessage('a1-second'), 'branch-second');
      expect(tree.preferredBranchIdForMessage('u1'), tree.activeBranchId);
      expect(tree.preferredBranchIdForMessage('missing'), isNull);
    });

    test('remembers the selected branch below a shared hidden prefix', () {
      final base = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['root', 'a'],
      );
      final a1 = base
          .forkBranch(branchId: 'a1', fromMessageId: 'a')
          .appendToActiveBranch('a1-tail');
      final a2 = a1
          .switchBranch('root')
          .forkBranch(branchId: 'a2', fromMessageId: 'a')
          .appendToActiveBranch('a2-tail');
      final tree = a2
          .switchBranch('a1')
          .switchBranch('root')
          .forkBranch(branchId: 'b', fromMessageId: 'root')
          .appendToActiveBranch('b-tail');

      expect(tree.preferredBranchIdForMessage('a'), 'a1');
    });

    test('records the active branch before switching away from it', () {
      final base = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['root', 'a'],
      );
      final a1 = base
          .forkBranch(branchId: 'a1', fromMessageId: 'a')
          .appendToActiveBranch('a1-tail');
      final withBranches = a1
          .switchBranch('root')
          .forkBranch(branchId: 'a2', fromMessageId: 'a')
          .appendToActiveBranch('a2-tail')
          .forkBranchFromParent(branchId: 'b', fromMessageId: null)
          .appendToActiveBranch('b-tail');
      final activeA1WithoutMemory = ConversationTree(
        conversationId: withBranches.conversationId,
        activeBranchId: 'a1',
        branches: withBranches.branches,
        edges: withBranches.edges,
      );

      final switchedToB = activeA1WithoutMemory.switchBranch('b');

      expect(switchedToB.preferredBranchIdForMessage('a'), 'a1');
    });

    test('sibling map does not treat a branch prefix as a sibling fork', () {
      final tree = ConversationTree(
        conversationId: 'conversation',
        activeBranchId: 'continuation',
        branches: <String, ConversationBranch>{
          'root': ConversationBranch(
            id: 'root',
            conversationId: 'conversation',
            tipMessageId: 'edited-a1',
            createdAt: DateTime(2026),
          ),
          'continuation': ConversationBranch(
            id: 'continuation',
            conversationId: 'conversation',
            tipMessageId: 'new-a2',
            createdAt: DateTime(2026, 1, 1),
          ),
        },
        edges: const <String, MessageTreeEdge>{
          'u1': MessageTreeEdge(messageId: 'u1', parentMessageId: null),
          'a1': MessageTreeEdge(messageId: 'a1', parentMessageId: 'u1'),
          'edited-a1': MessageTreeEdge(
            messageId: 'edited-a1',
            parentMessageId: 'a1',
          ),
          'new-a2': MessageTreeEdge(
            messageId: 'new-a2',
            parentMessageId: 'edited-a1',
          ),
        },
      );

      final siblings = tree.siblingBranchIdsByMessageId();

      expect(siblings['new-a2'], isNull);
      expect(siblings.containsKey('edited-a1'), isFalse);
    });

    test(
      'forkBranch opens a branch at an existing message without a new edge',
      () {
        final base = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['u1', 'a1', 'u2'],
        );

        final tree = base.forkBranch(branchId: 'alt', fromMessageId: 'u1');

        expect(tree.activeBranchId, 'alt');
        expect(tree.activePath(), const ['u1']);
        expect(tree.branchPath('root'), const ['u1', 'a1', 'u2']);
        expect(tree.branches['alt']?.tipMessageId, 'u1');

        final continued = tree.appendToActiveBranch('a1-alt');
        expect(continued.activePath(), const ['u1', 'a1-alt']);
        expect(continued.edges['a1-alt']?.parentMessageId, 'u1');
      },
    );
  });

  group('ConversationTree deletion', () {
    test('deletes only the selected descendant chain', () {
      final base = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['u1', 'a1', 'u2', 'a2'],
      );
      final branched = base.createBranch(
        branchId: 'other',
        fromMessageId: 'u1',
        tipMessageId: 'a1-alt',
      );

      final afterDelete = branched.switchBranch('root').deleteMessage('a1');

      expect(afterDelete.branches.containsKey('root'), isFalse);
      expect(afterDelete.activePath(), const ['u1', 'a1-alt']);
      expect(afterDelete.edges.containsKey('u2'), isFalse);
      expect(afterDelete.edges.containsKey('a2'), isFalse);
      expect(afterDelete.branchPath('other'), const ['u1', 'a1-alt']);
    });

    test('falls back to the root branch when active tip is deleted', () {
      final base = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['u1', 'a1'],
      );
      final branched = base.createBranch(
        branchId: 'other',
        fromMessageId: 'u1',
        tipMessageId: 'a1-alt',
      );

      final afterDelete = branched.deleteMessage('a1-alt');

      expect(afterDelete.activeBranchId, 'root');
      expect(afterDelete.activePath(), const ['u1', 'a1']);
    });

    test(
      'removeMessageOnly removes a middle message and keeps both branches',
      () {
        final base = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['u1', 'a1', 'u2', 'a2'],
        );
        final branched = base
            .forkBranch(branchId: 'alt', fromMessageId: 'u1')
            .appendToActiveBranch('a1-alt')
            .appendToActiveBranch('u2-alt');

        final afterRemove = branched
            .switchBranch('root')
            .removeMessageOnly('a1');

        expect(afterRemove.activeBranchId, 'root');
        expect(afterRemove.activePath(), const ['u1', 'u2', 'a2']);
        expect(afterRemove.edges['u2']?.parentMessageId, 'u1');
        expect(afterRemove.branchPath('alt'), const ['u1', 'a1-alt', 'u2-alt']);
      },
    );
  });

  group('ConversationTree validation', () {
    test('rejects unknown active branch', () {
      expect(
        () => ConversationTree(
          conversationId: 'conversation',
          activeBranchId: 'missing',
          branches: const <String, ConversationBranch>{},
          edges: const <String, MessageTreeEdge>{},
        ),
        throwsArgumentError,
      );
    });

    test('rejects a self-parenting edge', () {
      expect(
        () => ConversationTree(
          conversationId: 'conversation',
          activeBranchId: 'root',
          branches: {
            'root': ConversationBranch(
              id: 'root',
              conversationId: 'conversation',
              tipMessageId: 'm1',
              createdAt: DateTime(2026),
            ),
          },
          edges: const {
            'm1': MessageTreeEdge(messageId: 'm1', parentMessageId: 'm1'),
          },
        ),
        throwsArgumentError,
      );
    });

    test('rejects an edge whose parent is missing', () {
      expect(
        () => ConversationTree(
          conversationId: 'conversation',
          activeBranchId: 'root',
          branches: {
            'root': ConversationBranch(
              id: 'root',
              conversationId: 'conversation',
              tipMessageId: 'm2',
              createdAt: DateTime(2026),
            ),
          },
          edges: const {
            'm2': MessageTreeEdge(messageId: 'm2', parentMessageId: 'missing'),
          },
        ),
        throwsArgumentError,
      );
    });

    test('rejects a cyclic tree', () {
      expect(
        () => ConversationTree(
          conversationId: 'conversation',
          activeBranchId: 'root',
          branches: {
            'root': ConversationBranch(
              id: 'root',
              conversationId: 'conversation',
              tipMessageId: 'm1',
              createdAt: DateTime(2026),
            ),
          },
          edges: const {
            'm1': MessageTreeEdge(messageId: 'm1', parentMessageId: 'm2'),
            'm2': MessageTreeEdge(messageId: 'm2', parentMessageId: 'm1'),
          },
        ),
        throwsArgumentError,
      );
    });
  });
}
