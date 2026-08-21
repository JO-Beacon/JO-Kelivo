import 'package:flutter/foundation.dart';

@immutable
class MessageTreeEdge {
  const MessageTreeEdge({
    required this.messageId,
    required this.parentMessageId,
  });

  final String messageId;
  final String? parentMessageId;
}

@immutable
class ConversationBranch {
  const ConversationBranch({
    required this.id,
    required this.conversationId,
    required this.tipMessageId,
    this.name = '',
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String? tipMessageId;
  final String name;
  final DateTime createdAt;

  ConversationBranch copyWith({
    String? id,
    String? conversationId,
    String? tipMessageId,
    String? name,
    DateTime? createdAt,
    bool clearTip = false,
  }) {
    return ConversationBranch(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      tipMessageId: clearTip ? null : (tipMessageId ?? this.tipMessageId),
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

@immutable
class ConversationTree {
  ConversationTree({
    required this.conversationId,
    required this.activeBranchId,
    required Map<String, ConversationBranch> branches,
    required Map<String, MessageTreeEdge> edges,
    Map<String, String> branchSelections = const <String, String>{},
  }) : branches = Map.unmodifiable(branches),
       edges = Map.unmodifiable(edges),
       branchSelections = Map.unmodifiable(branchSelections) {
    if (conversationId.isEmpty) {
      throw ArgumentError.value(
        conversationId,
        'conversationId',
        'Conversation id must not be empty.',
      );
    }
    if (!this.branches.containsKey(activeBranchId)) {
      throw ArgumentError.value(
        activeBranchId,
        'activeBranchId',
        'Active branch must exist in branches.',
      );
    }
    for (final branch in this.branches.values) {
      if (branch.conversationId != conversationId) {
        throw ArgumentError.value(
          branch.conversationId,
          'branch.conversationId',
          'All branches must belong to the same conversation.',
        );
      }
    }
    for (final edge in this.edges.values) {
      if (edge.messageId.isEmpty) {
        throw ArgumentError.value(
          edge.messageId,
          'edge.messageId',
          'Message id must not be empty.',
        );
      }
      if (edge.parentMessageId == edge.messageId) {
        throw ArgumentError.value(
          edge.messageId,
          'edge.messageId',
          'A message cannot be its own parent.',
        );
      }
      final parent = edge.parentMessageId;
      if (parent != null && !this.edges.containsKey(parent)) {
        throw ArgumentError.value(
          parent,
          'edge.parentMessageId',
          'Parent message must exist in the tree.',
        );
      }
    }
    for (final branch in this.branches.values) {
      final tip = branch.tipMessageId;
      if (tip != null && !this.edges.containsKey(tip)) {
        throw ArgumentError.value(
          tip,
          'branch.tipMessageId',
          'Branch tip message must exist in the tree.',
        );
      }
    }
    _validateAcyclic();
  }

  factory ConversationTree.linear({
    required String conversationId,
    required List<String> messageIds,
    String activeBranchId = 'root',
    DateTime? createdAt,
  }) {
    final edges = <String, MessageTreeEdge>{};
    String? previous;
    for (final messageId in messageIds) {
      edges[messageId] = MessageTreeEdge(
        messageId: messageId,
        parentMessageId: previous,
      );
      previous = messageId;
    }
    final tip = messageIds.isEmpty ? null : messageIds.last;
    final branches = <String, ConversationBranch>{
      activeBranchId: ConversationBranch(
        id: activeBranchId,
        conversationId: conversationId,
        tipMessageId: tip,
        createdAt: createdAt ?? DateTime.now(),
      ),
    };
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: activeBranchId,
      branches: branches,
      edges: edges,
    );
  }

  final String conversationId;
  final String activeBranchId;
  final Map<String, ConversationBranch> branches;
  final Map<String, MessageTreeEdge> edges;
  final Map<String, String> branchSelections;

  List<String> branchPath(String branchId) {
    final branch = branches[branchId];
    if (branch == null) {
      throw ArgumentError.value(branchId, 'branchId', 'Unknown branch.');
    }
    final tip = branch.tipMessageId;
    if (tip == null) return const <String>[];

    final reversed = <String>[];
    String? cursor = tip;
    while (cursor != null) {
      reversed.add(cursor);
      final edge = edges[cursor];
      if (edge == null) {
        throw StateError('branch_path_edge_missing');
      }
      cursor = edge.parentMessageId;
    }
    return reversed.reversed.toList(growable: false);
  }

  List<String> activePath() => branchPath(activeBranchId);

  /// 选择包含 [messageId] 的最具体分支。
  ///
  /// 共享祖先保持在当前分支上。对于隐藏节点，优先选择所选分支中的该节点；
  /// 否则先选精确命中的分支尖端，再按确定性规则选择匹配分支。
  String? preferredBranchIdForMessage(String messageId) {
    if (!edges.containsKey(messageId)) return null;
    if (isMessageInActivePath(messageId)) return activeBranchId;

    final remembered = branchSelections[messageId];
    if (remembered != null &&
        branches.containsKey(remembered) &&
        branchPath(remembered).contains(messageId)) {
      return remembered;
    }

    final candidates = branches.values
        .where((branch) => branchPath(branch.id).contains(messageId))
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) {
      final leftExact = left.tipMessageId == messageId ? 0 : 1;
      final rightExact = right.tipMessageId == messageId ? 0 : 1;
      if (leftExact != rightExact) return leftExact.compareTo(rightExact);
      final byDepth = branchPath(
        right.id,
      ).length.compareTo(branchPath(left.id).length);
      if (byDepth != 0) return byDepth;
      final byTime = left.createdAt.compareTo(right.createdAt);
      if (byTime != 0) return byTime;
      return left.id.compareTo(right.id);
    });
    return candidates.first.id;
  }

  bool isMessageInActivePath(String messageId) =>
      activePath().contains(messageId);

  /// 将每个子节点映射到包含该节点的分支。
  ///
  /// 结果基于直接父子关系。分支可能在分叉点结束，也可能延续到不同长度，
  /// 因此无法从路径索引直接推断。
  Map<String, List<String>> siblingBranchIdsByMessageId() {
    final childrenByParent = <String?, List<String>>{};
    for (final edge in edges.values) {
      childrenByParent
          .putIfAbsent(edge.parentMessageId, () => <String>[])
          .add(edge.messageId);
    }
    final result = <String, List<String>>{};
    for (final children in childrenByParent.values) {
      if (children.length < 2) continue;
      final branchIds = <String>{};
      for (final branch in branches.values) {
        final path = branchPath(branch.id);
        if (children.any(path.contains)) branchIds.add(branch.id);
      }
      if (branchIds.length < 2) continue;
      final sorted = branchIds.toList(growable: false)
        ..sort((leftId, rightId) {
          final left = branches[leftId]!;
          final right = branches[rightId]!;
          final byTime = left.createdAt.compareTo(right.createdAt);
          if (byTime != 0) return byTime;
          return left.id.compareTo(right.id);
        });
      final siblings = List<String>.unmodifiable(sorted);
      for (final childId in children) {
        result[childId] = siblings;
      }
    }
    return Map<String, List<String>>.unmodifiable(result);
  }

  Map<String?, List<String>> get childrenByParent {
    final result = <String?, List<String>>{};
    for (final edge in edges.values) {
      result
          .putIfAbsent(edge.parentMessageId, () => <String>[])
          .add(edge.messageId);
    }
    for (final children in result.values) {
      children.sort();
    }
    return Map<String?, List<String>>.unmodifiable({
      for (final entry in result.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    });
  }

  List<String> childrenOf(String? parentMessageId) =>
      childrenByParent[parentMessageId] ?? const <String>[];

  ConversationTree appendToActiveBranch(
    String messageId, {
    String? parentMessageId,
    String? branchId,
    String name = '',
    DateTime? createdAt,
    bool activate = false,
  }) {
    if (messageId.isEmpty) {
      throw ArgumentError.value(messageId, 'messageId', 'must not be empty');
    }
    if (edges.containsKey(messageId)) {
      throw ArgumentError.value(
        messageId,
        'messageId',
        'Message already exists in the tree.',
      );
    }
    final targetBranchId = branchId ?? activeBranchId;
    final branch = branches[targetBranchId];
    if (branch == null) {
      throw ArgumentError.value(targetBranchId, 'branchId', 'Unknown branch.');
    }
    final resolvedParent = parentMessageId ?? branch.tipMessageId;
    if (resolvedParent != null && !edges.containsKey(resolvedParent)) {
      throw ArgumentError.value(
        resolvedParent,
        'parentMessageId',
        'Parent message is not in the tree.',
      );
    }

    final nextEdges = Map<String, MessageTreeEdge>.from(edges)
      ..[messageId] = MessageTreeEdge(
        messageId: messageId,
        parentMessageId: resolvedParent,
      );
    final nextBranches = Map<String, ConversationBranch>.from(branches)
      ..[targetBranchId] = branch.copyWith(
        tipMessageId: messageId,
        name: name.isEmpty ? branch.name : name,
        createdAt: createdAt ?? branch.createdAt,
      );
    final nextSelections = (activate || targetBranchId == activeBranchId)
        ? _rememberBranchSelections(
            targetBranchId,
            branches: nextBranches,
            edges: nextEdges,
          )
        : branchSelections;
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: activate ? targetBranchId : activeBranchId,
      branches: nextBranches,
      edges: nextEdges,
      branchSelections: nextSelections,
    );
  }

  ConversationTree createBranch({
    required String branchId,
    required String fromMessageId,
    required String tipMessageId,
    String name = '',
    DateTime? createdAt,
  }) {
    if (branchId.isEmpty) {
      throw ArgumentError.value(branchId, 'branchId', 'must not be empty');
    }
    if (branches.containsKey(branchId)) {
      throw ArgumentError.value(branchId, 'branchId', 'Branch already exists.');
    }
    return createBranchFromParent(
      branchId: branchId,
      parentMessageId: fromMessageId,
      tipMessageId: tipMessageId,
      name: name,
      createdAt: createdAt,
    );
  }

  ConversationTree createBranchFromParent({
    required String branchId,
    required String? parentMessageId,
    required String tipMessageId,
    String name = '',
    DateTime? createdAt,
  }) {
    if (branchId.isEmpty) {
      throw ArgumentError.value(branchId, 'branchId', 'must not be empty');
    }
    if (branches.containsKey(branchId)) {
      throw ArgumentError.value(branchId, 'branchId', 'Branch already exists.');
    }
    if (parentMessageId != null && !edges.containsKey(parentMessageId)) {
      throw ArgumentError.value(
        parentMessageId,
        'parentMessageId',
        'Fork parent is not in the tree.',
      );
    }
    if (edges.containsKey(tipMessageId)) {
      throw ArgumentError.value(
        tipMessageId,
        'tipMessageId',
        'Tip message already exists in the tree.',
      );
    }
    final nextEdges = Map<String, MessageTreeEdge>.from(edges)
      ..[tipMessageId] = MessageTreeEdge(
        messageId: tipMessageId,
        parentMessageId: parentMessageId,
      );
    final nextBranches = Map<String, ConversationBranch>.from(branches)
      ..[branchId] = ConversationBranch(
        id: branchId,
        conversationId: conversationId,
        tipMessageId: tipMessageId,
        name: name,
        createdAt: createdAt ?? DateTime.now(),
      );
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: branchId,
      branches: nextBranches,
      edges: nextEdges,
      branchSelections: _rememberBranchSelections(
        branchId,
        branches: nextBranches,
        edges: nextEdges,
      ),
    );
  }

  ConversationTree switchBranch(String branchId) {
    if (!branches.containsKey(branchId)) {
      throw ArgumentError.value(branchId, 'branchId', 'Unknown branch.');
    }
    final rememberedSelections = _rememberBranchSelections(
      activeBranchId,
      branches: branches,
      edges: edges,
    );
    final nextSelections = _rememberBranchSelections(
      branchId,
      branches: branches,
      edges: edges,
      baseSelections: rememberedSelections,
    );
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: branchId,
      branches: branches,
      edges: edges,
      branchSelections: nextSelections,
    );
  }

  ConversationTree deleteMessage(String messageId) {
    if (!edges.containsKey(messageId)) return this;
    final removedIds = _descendantsOf(messageId).toSet()..add(messageId);
    final nextEdges = Map<String, MessageTreeEdge>.from(edges)
      ..removeWhere((id, _) => removedIds.contains(id));
    final affectedBranches = <ConversationBranch>[];
    final nextBranches = <String, ConversationBranch>{};
    for (final branch in branches.values) {
      final tip = branch.tipMessageId;
      if (tip != null && removedIds.contains(tip)) {
        affectedBranches.add(branch);
      } else {
        nextBranches[branch.id] = branch;
      }
    }

    if (nextBranches.isEmpty) {
      final fallback = _chooseFallbackBranch({
        for (final branch in affectedBranches) branch.id: branch,
      });
      if (fallback == null) throw StateError('cannot_delete_last_branch');
      var fallbackTip = fallback.tipMessageId;
      while (fallbackTip != null && removedIds.contains(fallbackTip)) {
        fallbackTip = edges[fallbackTip]?.parentMessageId;
      }
      nextBranches[fallback.id] = fallback.copyWith(
        tipMessageId: fallbackTip,
        clearTip: fallbackTip == null,
      );
    }

    final nextActiveBranchId = nextBranches.containsKey(activeBranchId)
        ? activeBranchId
        : _fallbackBranchId(nextBranches);
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: nextActiveBranchId,
      branches: nextBranches,
      edges: nextEdges,
      branchSelections: _pruneBranchSelections(
        branches: nextBranches,
        edges: nextEdges,
      ),
    );
  }

  /// 删除 [messageId] 及其所有后代。子树保持完整。
  ConversationTree deleteSubtree(String messageId) => deleteMessage(messageId);
  ConversationTree removeMessageOnly(String messageId) {
    final removed = edges[messageId];
    if (removed == null) return this;
    final nextEdges = Map<String, MessageTreeEdge>.from(edges)
      ..remove(messageId);
    for (final edge in nextEdges.values.toList(growable: false)) {
      if (edge.parentMessageId == messageId) {
        nextEdges[edge.messageId] = MessageTreeEdge(
          messageId: edge.messageId,
          parentMessageId: removed.parentMessageId,
        );
      }
    }
    final nextBranches = Map<String, ConversationBranch>.from(branches);
    for (final entry in nextBranches.entries.toList(growable: false)) {
      if (entry.value.tipMessageId == messageId) {
        nextBranches[entry.key] = entry.value.copyWith(
          tipMessageId: removed.parentMessageId,
          clearTip: removed.parentMessageId == null,
        );
      }
    }
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: activeBranchId,
      branches: nextBranches,
      edges: nextEdges,
      branchSelections: _pruneBranchSelections(
        branches: nextBranches,
        edges: nextEdges,
      ),
    );
  }

  ConversationTree forkBranch({
    required String branchId,
    required String fromMessageId,
    String name = '',
    DateTime? createdAt,
  }) => forkBranchFromParent(
    branchId: branchId,
    fromMessageId: fromMessageId,
    name: name,
    createdAt: createdAt,
  );

  ConversationTree forkBranchFromParent({
    required String branchId,
    required String? fromMessageId,
    String name = '',
    DateTime? createdAt,
  }) {
    if (branchId.isEmpty) {
      throw ArgumentError.value(branchId, 'branchId', 'must not be empty');
    }
    if (branches.containsKey(branchId)) {
      throw ArgumentError.value(branchId, 'branchId', 'Branch already exists.');
    }
    if (fromMessageId != null && !edges.containsKey(fromMessageId)) {
      throw ArgumentError.value(
        fromMessageId,
        'fromMessageId',
        'Fork point is not in the tree.',
      );
    }
    final nextBranches = Map<String, ConversationBranch>.from(branches)
      ..[branchId] = ConversationBranch(
        id: branchId,
        conversationId: conversationId,
        tipMessageId: fromMessageId,
        name: name,
        createdAt: createdAt ?? DateTime.now(),
      );
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: branchId,
      branches: nextBranches,
      edges: edges,
      branchSelections: _rememberBranchSelections(
        branchId,
        branches: nextBranches,
        edges: edges,
      ),
    );
  }

  Map<String, String> _rememberBranchSelections(
    String branchId, {
    required Map<String, ConversationBranch> branches,
    required Map<String, MessageTreeEdge> edges,
    Map<String, String>? baseSelections,
  }) {
    final result = Map<String, String>.from(baseSelections ?? branchSelections);
    final selectedPath = _branchPathFor(branchId, branches, edges);
    for (var index = 0; index + 1 < selectedPath.length; index++) {
      final messageId = selectedPath[index];
      final selectedChildId = selectedPath[index + 1];
      final childIds = <String>{};
      for (final branch in branches.values) {
        final path = _branchPathFor(branch.id, branches, edges);
        final messageIndex = path.indexOf(messageId);
        if (messageIndex >= 0 && messageIndex + 1 < path.length) {
          childIds.add(path[messageIndex + 1]);
        }
      }
      if (childIds.length > 1 && childIds.contains(selectedChildId)) {
        result[messageId] = branchId;
      }
    }
    return result;
  }

  Map<String, String> _pruneBranchSelections({
    required Map<String, ConversationBranch> branches,
    required Map<String, MessageTreeEdge> edges,
  }) {
    final result = <String, String>{};
    for (final entry in branchSelections.entries) {
      final branch = branches[entry.value];
      if (branch == null || !edges.containsKey(entry.key)) continue;
      final path = _branchPathFor(entry.value, branches, edges);
      final messageIndex = path.indexOf(entry.key);
      if (messageIndex >= 0 && messageIndex + 1 < path.length) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  static List<String> _branchPathFor(
    String branchId,
    Map<String, ConversationBranch> branches,
    Map<String, MessageTreeEdge> edges,
  ) {
    final tip = branches[branchId]?.tipMessageId;
    if (tip == null) return const <String>[];
    final reversed = <String>[];
    String? cursor = tip;
    while (cursor != null) {
      reversed.add(cursor);
      final edge = edges[cursor];
      if (edge == null) throw StateError('branch_path_edge_missing');
      cursor = edge.parentMessageId;
    }
    return reversed.reversed.toList(growable: false);
  }

  Set<String> _descendantsOf(String messageId) {
    final children = <String, List<String>>{};
    for (final edge in edges.values) {
      final parent = edge.parentMessageId;
      if (parent != null) {
        children.putIfAbsent(parent, () => <String>[]).add(edge.messageId);
      }
    }
    final result = <String>{};
    final pending = <String>[messageId];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      for (final child in children[current] ?? const <String>[]) {
        if (result.add(child)) pending.add(child);
      }
    }
    return result;
  }

  String _fallbackBranchId(Map<String, ConversationBranch> branches) {
    if (branches.isEmpty) {
      throw StateError('cannot_delete_last_branch');
    }
    return _chooseFallbackBranch(branches)!.id;
  }

  ConversationBranch? _chooseFallbackBranch(
    Map<String, ConversationBranch> candidates,
  ) {
    if (candidates.isEmpty) return null;
    final root = candidates['root'] ?? candidates['root-$conversationId'];
    if (root != null) return root;
    final sorted = candidates.values.toList(growable: false)
      ..sort((left, right) {
        final byTime = left.createdAt.compareTo(right.createdAt);
        if (byTime != 0) return byTime;
        return left.id.compareTo(right.id);
      });
    return sorted.first;
  }

  void _validateAcyclic() {
    final visiting = <String>{};
    final visited = <String>{};

    void visit(String messageId) {
      if (visiting.contains(messageId)) {
        throw ArgumentError.value(
          messageId,
          'edges',
          'Message tree contains a cycle.',
        );
      }
      if (visited.contains(messageId)) return;
      visiting.add(messageId);
      final parent = edges[messageId]?.parentMessageId;
      if (parent != null) visit(parent);
      visiting.remove(messageId);
      visited.add(messageId);
    }

    for (final messageId in edges.keys) {
      visit(messageId);
    }
  }
}
