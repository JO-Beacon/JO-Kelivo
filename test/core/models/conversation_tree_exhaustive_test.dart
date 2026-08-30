import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/conversation_tree.dart';

void main() {
  group('ConversationTree transition invariants', () {
    test(
      'covers empty anchors, shared prefixes, nested branches and switches',
      () {
        var tree = ConversationTree.linear(
          conversationId: 'conversation',
          messageIds: const ['m0', 'm1', 'm2'],
        );
        _expectValid(tree);

        tree = tree.createMessageBranchFromParent(
          branchId: 'empty-root',
          fromMessageId: null,
        );
        _expectValid(tree);
        expect(tree.activePath(), isEmpty);

        tree = tree.appendToActiveBranch('empty-m0');
        tree = tree.appendToActiveBranch('empty-m1');
        _expectValid(tree);

        tree = tree.switchBranch('root');
        tree = tree.createMessageBranch(branchId: 'first', fromMessageId: 'm0');
        tree = tree.appendToActiveBranch('first-m1');
        tree = tree.appendToActiveBranch('first-m2');
        _expectValid(tree);

        tree = tree.switchBranch('root');
        tree = tree.createMessageBranch(
          branchId: 'second',
          fromMessageId: 'm0',
        );
        tree = tree.appendToActiveBranch('second-m1');
        tree = tree.createMessageBranch(
          branchId: 'nested',
          fromMessageId: 'second-m1',
        );
        tree = tree.appendToActiveBranch('nested-m2');
        _expectValid(tree);

        for (final branchId in tree.branches.keys.toList(growable: false)) {
          final switched = tree.switchBranch(branchId);
          _expectValid(switched);
          expect(switched.activeBranchId, branchId);
          expect(switched.activePath(), switched.branchPath(branchId));
        }
      },
    );

    test('every removable node preserves a valid tree and reachable edges', () {
      final base = _complexTree();
      final violations = <String>[];
      for (final messageId in base.edges.keys.toList(growable: false)) {
        final deleted = base.deleteMessage(messageId);
        try {
          _expectValid(deleted);
        } catch (_) {
          violations.add(
            'deleteMessage($messageId): edges=${deleted.edges.keys.toList()} '
            'branches=${deleted.branches.map((id, b) => MapEntry(id, b.tipMessageId))}',
          );
        }
        final removed = base.removeMessageOnly(messageId);
        try {
          _expectValid(removed);
        } catch (_) {
          violations.add(
            'removeMessageOnly($messageId): edges=${removed.edges.keys.toList()} '
            'branches=${removed.branches.map((id, b) => MapEntry(id, b.tipMessageId))}',
          );
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test(
      'append targets and activation do not corrupt another active path',
      () {
        var tree = _complexTree().switchBranch('root');
        final rootPathBefore = tree.activePath();

        tree = tree.appendToActiveBranch('inactive-tail', branchId: 'first');
        _expectValid(tree);
        expect(tree.activeBranchId, 'root');
        expect(tree.activePath(), rootPathBefore);
        expect(tree.branchPath('first'), contains('inactive-tail'));

        tree = tree.appendToActiveBranch(
          'activated-tail',
          branchId: 'first',
          activate: true,
        );
        _expectValid(tree);
        expect(tree.activeBranchId, 'first');
        expect(tree.activePath().last, 'activated-tail');
      },
    );

    test('invalid transitions fail without mutating the source tree', () {
      final tree = _complexTree();
      final edgesBefore = tree.edges;
      final branchesBefore = tree.branches;

      expect(() => tree.switchBranch('missing'), throwsArgumentError);
      expect(() => tree.appendToActiveBranch('m0'), throwsArgumentError);
      expect(
        () => tree.appendToActiveBranch('new', branchId: 'missing'),
        throwsArgumentError,
      );
      expect(
        () =>
            tree.createMessageBranch(branchId: 'new', fromMessageId: 'missing'),
        throwsArgumentError,
      );
      expect(
        () => tree.createMessageBranch(branchId: 'root', fromMessageId: 'm0'),
        throwsArgumentError,
      );
      expect(tree.deleteMessage('missing').edges, same(edgesBefore));
      expect(tree.removeMessageOnly('missing').edges, same(edgesBefore));
      expect(tree.branches, same(branchesBefore));
    });

    test('deleting the only message leaves a valid empty root branch', () {
      final tree = ConversationTree.linear(
        conversationId: 'conversation',
        messageIds: const ['only'],
      );

      final afterCascade = tree.deleteMessage('only');
      _expectValid(afterCascade);
      expect(afterCascade.activePath(), isEmpty);
      expect(afterCascade.branches.keys, const ['root']);

      final afterLocal = tree.removeMessageOnly('only');
      _expectValid(afterLocal);
      expect(afterLocal.activePath(), isEmpty);
      expect(afterLocal.branches.keys, const ['root']);
    });

    test('nested sibling projection stays local to each fork point', () {
      final tree = _complexTree();
      final siblings = tree.siblingBranchIdsByMessageId();

      expect(siblings['m1'], unorderedEquals(['root', 'first', 'nested']));
      expect(
        siblings['first-m1'],
        unorderedEquals(['root', 'first', 'nested']),
      );
      expect(
        siblings['second-m1'],
        unorderedEquals(['root', 'first', 'nested']),
      );
      expect(siblings['nested-m2'], isNull);
      expect(siblings['m0'], isNull);
    });

    test(
      'repeated switches and deletions keep branch selections applicable',
      () {
        var tree = _complexTree();
        final branchIds = tree.branches.keys.toList(growable: false);
        for (var i = 0; i < 4; i++) {
          tree = tree.switchBranch(branchIds[i % branchIds.length]);
          _expectValid(tree);
        }

        for (final messageId in const ['nested-m2', 'second-m1', 'm0']) {
          tree = tree.removeMessageOnly(messageId);
          _expectValid(tree);
        }
      },
    );

    test('deterministic operation walk checks every transition shape', () {
      var tree = _complexTree();
      var nextMessage = 0;
      var nextBranch = 0;
      var seed = 0x5eed1234;
      final violations = <String>[];

      for (var step = 0; step < 400; step++) {
        try {
          _expectValid(tree);
        } catch (_) {
          violations.add(
            'before step $step: edges=${tree.edges.keys.toList()} branches=${tree.branches.map((id, b) => MapEntry(id, b.tipMessageId))}',
          );
          break;
        }
        final choices = <void Function()>[];
        final labels = <String>[];

        for (final branchId in tree.branches.keys) {
          choices.add(() => tree = tree.switchBranch(branchId));
          labels.add('switch($branchId)');
        }
        choices.add(() {
          tree = tree.appendToActiveBranch('walk-m${nextMessage++}');
        });
        labels.add('append(active)');
        for (final messageId in tree.edges.keys) {
          choices.add(() {
            final branchId = 'walk-b${nextBranch++}';
            tree = tree.createMessageBranch(
              branchId: branchId,
              fromMessageId: messageId,
            );
          });
          labels.add('createBranch($messageId)');
          choices.add(() {
            tree = tree.removeMessageOnly(messageId);
          });
          labels.add('removeOnly($messageId)');
          choices.add(() {
            tree = tree.deleteMessage(messageId);
          });
          labels.add('delete($messageId)');
        }

        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        final choice = seed % choices.length;
        try {
          choices[choice]();
          _expectValid(tree);
        } catch (_) {
          violations.add(
            'step $step ${labels[choice]}: edges=${tree.edges.keys.toList()} '
            'branches=${tree.branches.map((id, b) => MapEntry(id, b.tipMessageId))}',
          );
          break;
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test(
      'bounded state space keeps selections and sibling projections closed',
      () {
        final failures = <String>[];
        final visited = <String>{};
        var nextMessage = 0;
        var nextBranch = 0;

        void walk(ConversationTree tree, int depth, String trace) {
          final signature = _signature(tree);
          final visitKey = '$depth:$signature';
          if (!visited.add(visitKey)) return;

          try {
            _expectBranchMetadata(tree);
          } catch (error) {
            failures.add('$trace -> $signature: $error');
            return;
          }
          if (depth == 0 || visited.length > 5000) return;

          final actions =
              <({String name, ConversationTree Function() apply})>[];
          for (final branchId in tree.branches.keys) {
            actions.add((
              name: 'switch($branchId)',
              apply: () => tree.switchBranch(branchId),
            ));
          }
          final appendedId = 'space-m${nextMessage++}';
          actions.add((
            name: 'append($appendedId)',
            apply: () => tree.appendToActiveBranch(appendedId),
          ));
          for (final messageId in tree.edges.keys.toList(growable: false)) {
            final branchId = 'space-b${nextBranch++}';
            actions.add((
              name: 'anchor($branchId@$messageId)',
              apply: () => tree.createMessageBranch(
                branchId: branchId,
                fromMessageId: messageId,
              ),
            ));
            actions.add((
              name: 'removeOnly($messageId)',
              apply: () => tree.removeMessageOnly(messageId),
            ));
            actions.add((
              name: 'delete($messageId)',
              apply: () => tree.deleteMessage(messageId),
            ));
          }

          for (final action in actions) {
            try {
              final next = action.apply();
              walk(next, depth - 1, '$trace/${action.name}');
            } catch (error) {
              failures.add('$trace/${action.name} throws $error');
            }
            if (visited.length > 5000) break;
          }
        }

        walk(_complexTree(), 4, 'start');
        expect(failures, isEmpty, reason: failures.take(20).join('\n'));
      },
    );

    test('batch cascade deletion is independent of input order', () {
      final tree = _complexTree();
      final left = tree.deleteMessages(const ['first-m2', 'second-m1']);
      final right = tree.deleteMessages(const ['second-m1', 'first-m2']);

      expect(_signature(left), _signature(right));
      _expectValid(left);
      _expectValid(right);
    });

    test('batch local deletion is independent of input order', () {
      final tree = _complexTree();
      final left = tree.removeMessagesOnly(const ['m1', 'first-m1']);
      final right = tree.removeMessagesOnly(const ['first-m1', 'm1']);

      expect(_signature(left), _signature(right));
      _expectValid(left);
      _expectValid(right);
    });
  });
}

ConversationTree _complexTree() {
  var tree = ConversationTree.linear(
    conversationId: 'conversation',
    messageIds: const ['m0', 'm1', 'm2'],
  );
  tree = tree
      .createMessageBranch(branchId: 'first', fromMessageId: 'm0')
      .appendToActiveBranch('first-m1')
      .appendToActiveBranch('first-m2');
  tree = tree
      .switchBranch('root')
      .createMessageBranch(branchId: 'second', fromMessageId: 'm0')
      .appendToActiveBranch('second-m1')
      .createMessageBranch(branchId: 'nested', fromMessageId: 'second-m1')
      .appendToActiveBranch('nested-m2');
  return tree;
}

void _expectValid(ConversationTree tree) {
  expect(tree.branches, isNotEmpty);
  expect(
    tree.branches,
    containsPair(tree.activeBranchId, isA<ConversationBranch>()),
  );

  final reachable = <String>{};
  for (final branch in tree.branches.values) {
    final path = tree.branchPath(branch.id);
    expect(path, orderedEquals(path.toSet().toList()));
    reachable.addAll(path);
    for (var i = 1; i < path.length; i++) {
      expect(tree.edges[path[i]]?.parentMessageId, path[i - 1]);
    }
    if (branch.tipMessageId != null) {
      expect(path.last, branch.tipMessageId);
    }
  }

  expect(reachable, containsAll(tree.edges.keys));
  for (final entry in tree.edges.entries) {
    expect(entry.key, entry.value.messageId);
    final parent = entry.value.parentMessageId;
    if (parent != null) expect(tree.edges, contains(parent));
  }

  for (final entry in tree.branchSelections.entries) {
    final branch = tree.branches[entry.value];
    expect(branch, isNotNull);
    final path = tree.branchPath(entry.value);
    final index = path.indexOf(entry.key);
    expect(index, greaterThanOrEqualTo(0));
    expect(index, lessThan(path.length - 1));
  }
}

void _expectBranchMetadata(ConversationTree tree) {
  expect(tree.branches, isNotEmpty);
  expect(tree.branches, contains(tree.activeBranchId));
  expect(tree.activePath(), tree.branchPath(tree.activeBranchId));

  for (final entry in tree.branchSelections.entries) {
    final branch = tree.branches[entry.value];
    expect(branch, isNotNull);
    final path = tree.branchPath(entry.value);
    final index = path.indexOf(entry.key);
    expect(index, greaterThanOrEqualTo(0));
    expect(index, lessThan(path.length - 1));
  }

  final siblings = tree.siblingBranchIdsByMessageId();
  expect(tree.siblingBranchIdsByMessageId(), equals(siblings));
  for (final entry in siblings.entries) {
    final edge = tree.edges[entry.key];
    expect(edge, isNotNull);
    expect(tree.childrenOf(edge!.parentMessageId).length, greaterThan(1));
    expect(entry.value, isNotEmpty);
    final representedChildren = <String>{};
    final parentMessageId = edge.parentMessageId;
    for (final branchId in entry.value) {
      expect(tree.branches, contains(branchId));
      final path = tree.branchPath(branchId);
      final parentIndex = parentMessageId == null
          ? -1
          : path.indexOf(parentMessageId);
      if (parentIndex + 1 < path.length &&
          (parentMessageId == null || parentIndex >= 0)) {
        representedChildren.add(path[parentIndex + 1]);
      }
    }
    expect(representedChildren, contains(entry.key));
    expect(representedChildren.length, entry.value.length);
  }

  for (final messageId in tree.edges.keys) {
    final preferred = tree.preferredBranchIdForMessage(messageId);
    if (preferred == null) continue;
    expect(tree.branches, contains(preferred));
    expect(tree.branchPath(preferred), contains(messageId));
    if (tree.isMessageInActivePath(messageId)) {
      expect(preferred, tree.activeBranchId);
    }
  }
}

String _signature(ConversationTree tree) {
  final branches = tree.branches.entries
      .map((entry) => '${entry.key}=${entry.value.tipMessageId}')
      .join(',');
  final edges = tree.edges.entries
      .map((entry) => '${entry.key}<-${entry.value.parentMessageId}')
      .join(',');
  final selections = tree.branchSelections.entries
      .map((entry) => '${entry.key}->${entry.value}')
      .join(',');
  return 'active=${tree.activeBranchId}|branches=$branches|edges=$edges|selections=$selections';
}
