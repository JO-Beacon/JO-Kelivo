import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

@immutable
class ConversationTreeIntegrityIssue {
  const ConversationTreeIntegrityIssue({
    required this.code,
    required this.subject,
    required this.message,
  });

  final String code;
  final String subject;
  final String message;

  @override
  String toString() => '$code($subject): $message';
}

class ConversationTreeIntegrityException implements Exception {
  ConversationTreeIntegrityException(
    Iterable<ConversationTreeIntegrityIssue> issues, {
    this.conversationId,
    this.fingerprint,
    this.schemaVersion,
  }) : issues = List.unmodifiable(issues);

  final List<ConversationTreeIntegrityIssue> issues;
  final String? conversationId;
  final String? fingerprint;
  final int? schemaVersion;

  @override
  String toString() {
    final metadata = <String>[
      if (conversationId != null) 'conversationId=$conversationId',
      if (fingerprint != null) 'fingerprint=$fingerprint',
      if (schemaVersion != null) 'schemaVersion=$schemaVersion',
    ];
    final prefix = metadata.isEmpty ? '' : ' (${metadata.join(', ')})';
    return 'Conversation tree is invalid$prefix:\n'
        '${issues.map((issue) => ' - $issue').join('\n')}';
  }
}

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
class ConversationTreeTransformResult {
  const ConversationTreeTransformResult({
    required this.before,
    required this.after,
    required this.deletedMessageIds,
  });

  final ConversationTree before;
  final ConversationTree after;
  final Set<String> deletedMessageIds;

  String get previousActiveBranchId => before.activeBranchId;
  String get activeBranchId => after.activeBranchId;
  bool get activeBranchChanged => before.activeBranchId != after.activeBranchId;
  List<String> get activeBranchHistory => after.activeBranchHistory;
}

@immutable
class ConversationBranch {
  const ConversationBranch({
    required this.id,
    required this.conversationId,
    required this.tipMessageId,
    this.name = '',
    required this.createdAt,
    this.parentBranchId,
    this.forkAnchorMessageId,
  });

  final String id;
  final String conversationId;
  final String? tipMessageId;
  final String name;
  final DateTime createdAt;
  final String? parentBranchId;
  final String? forkAnchorMessageId;

  ConversationBranch copyWith({
    String? id,
    String? conversationId,
    String? tipMessageId,
    String? name,
    DateTime? createdAt,
    String? parentBranchId,
    String? forkAnchorMessageId,
    bool clearTip = false,
    bool clearParentBranch = false,
    bool clearForkAnchor = false,
  }) {
    return ConversationBranch(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      tipMessageId: clearTip ? null : (tipMessageId ?? this.tipMessageId),
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      parentBranchId: clearParentBranch
          ? null
          : (parentBranchId ?? this.parentBranchId),
      forkAnchorMessageId: clearForkAnchor
          ? null
          : (forkAnchorMessageId ?? this.forkAnchorMessageId),
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
    List<String> activeBranchHistory = const <String>[],
  }) : branches = Map.unmodifiable(branches),
       edges = Map.unmodifiable(edges),
       branchSelections = Map.unmodifiable(branchSelections),
       activeBranchHistory = List.unmodifiable(activeBranchHistory) {
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

  /// 从持久化快照构造模型但跳过前置校验，供诊断流程保留非法原始数据。
  ///
  /// 调用方必须立即运行 [integrityIssues]，不得把结果交给普通树变换。
  ConversationTree.unsafe({
    required this.conversationId,
    required this.activeBranchId,
    required Map<String, ConversationBranch> branches,
    required Map<String, MessageTreeEdge> edges,
    Map<String, String> branchSelections = const <String, String>{},
    List<String> activeBranchHistory = const <String>[],
  }) : branches = Map.unmodifiable(branches),
       edges = Map.unmodifiable(edges),
       branchSelections = Map.unmodifiable(branchSelections),
       activeBranchHistory = List.unmodifiable(activeBranchHistory);

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
  final List<String> activeBranchHistory;

  /// 返回当前快照中所有可诊断的完整性问题。
  ///
  /// 构造函数只拒绝无法安全表示的局部结构错误；加载旧数据时，调用方
  /// 应先保留原始快照，再用本方法决定是否进入非法树展示流程。
  List<ConversationTreeIntegrityIssue> integrityIssues() {
    final issues = <ConversationTreeIntegrityIssue>[];

    if (conversationId.isEmpty) {
      issues.add(
        const ConversationTreeIntegrityIssue(
          code: 'empty_conversation_id',
          subject: 'conversationId',
          message: '会话 ID 不能为空。',
        ),
      );
    }
    if (!branches.containsKey(activeBranchId)) {
      issues.add(
        ConversationTreeIntegrityIssue(
          code: 'active_branch_missing',
          subject: activeBranchId,
          message: '活动分支不存在。',
        ),
      );
    }

    for (final entry in branches.entries) {
      final branch = entry.value;
      if (entry.key.isEmpty || branch.id.isEmpty) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'empty_branch_id',
            subject: entry.key,
            message: '分支 ID 不能为空。',
          ),
        );
      }
      if (entry.key != branch.id) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'branch_key_mismatch',
            subject: entry.key,
            message: '分支记录的键与其 ID 不一致。',
          ),
        );
      }
      if (branch.conversationId != conversationId) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'branch_conversation_mismatch',
            subject: branch.id,
            message: '分支不属于当前会话。',
          ),
        );
      }
      final parentBranchId = branch.parentBranchId;
      if (parentBranchId == branch.id) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'branch_parent_self',
            subject: branch.id,
            message: '分支不能把自身作为父分支。',
          ),
        );
      } else if (parentBranchId != null &&
          !branches.containsKey(parentBranchId)) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'branch_parent_missing',
            subject: branch.id,
            message: '分支父关系指向不存在的分支。',
          ),
        );
      }
      final forkAnchorMessageId = branch.forkAnchorMessageId;
      if (forkAnchorMessageId != null &&
          !edges.containsKey(forkAnchorMessageId)) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'branch_anchor_missing',
            subject: branch.id,
            message: '分支锚点消息不存在。',
          ),
        );
      }
      final tip = branch.tipMessageId;
      if (tip != null && !edges.containsKey(tip)) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'branch_tip_missing',
            subject: branch.id,
            message: '分支尖端消息不存在。',
          ),
        );
      }
    }

    for (final branchId in activeBranchHistory) {
      if (!branches.containsKey(branchId)) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'active_history_branch_missing',
            subject: branchId,
            message: '活动历史包含不存在的分支。',
          ),
        );
      }
    }

    for (final entry in edges.entries) {
      final edge = entry.value;
      if (entry.key.isEmpty || edge.messageId.isEmpty) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'empty_message_id',
            subject: entry.key,
            message: '消息 ID 不能为空。',
          ),
        );
      }
      if (entry.key != edge.messageId) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'edge_key_mismatch',
            subject: entry.key,
            message: '边记录的键与其消息 ID 不一致。',
          ),
        );
      }
      final parent = edge.parentMessageId;
      if (parent != null && !edges.containsKey(parent)) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'edge_parent_missing',
            subject: edge.messageId,
            message: '边的父消息不存在。',
          ),
        );
      }
    }

    final cycleMessages = _cycleMessages();
    for (final messageId in cycleMessages) {
      issues.add(
        ConversationTreeIntegrityIssue(
          code: 'cycle',
          subject: messageId,
          message: '消息树包含环。',
        ),
      );
    }

    final reachable = _reachableMessageIds();
    for (final messageId in edges.keys) {
      if (!reachable.contains(messageId)) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'unreachable_edge',
            subject: messageId,
            message: '边不能从任何存活分支尖端回溯到达。',
          ),
        );
      }
    }

    for (final entry in branchSelections.entries) {
      final messageId = entry.key;
      final branchId = entry.value;
      final branch = branches[branchId];
      final path = branch == null ? null : _safeBranchPath(branchId);
      final index = path?.indexOf(messageId) ?? -1;
      if (branch == null) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'selection_branch_missing',
            subject: messageId,
            message: '选择记忆指向不存在的分支 $branchId。',
          ),
        );
      } else if (!edges.containsKey(messageId) || path == null || index < 0) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'selection_invalid',
            subject: messageId,
            message: '选择记忆不在目标分支的有效分叉点上。',
          ),
        );
      } else if (index + 1 < path.length && childrenOf(messageId).length < 2) {
        issues.add(
          ConversationTreeIntegrityIssue(
            code: 'selection_not_fork',
            subject: messageId,
            message: '选择记忆指向的消息没有多个直接后继。',
          ),
        );
      }
    }

    issues.sort((left, right) {
      final byCode = left.code.compareTo(right.code);
      if (byCode != 0) return byCode;
      final bySubject = left.subject.compareTo(right.subject);
      if (bySubject != 0) return bySubject;
      return left.message.compareTo(right.message);
    });
    return List.unmodifiable(issues);
  }

  /// 校验失败时抛出包含全部问题的异常；成功时不返回值。
  void validateIntegrity() {
    final issues = integrityIssues();
    if (issues.isNotEmpty) {
      throw ConversationTreeIntegrityException(
        issues,
        conversationId: conversationId,
        fingerprint: fingerprint,
      );
    }
  }

  bool get isIntegrityValid => integrityIssues().isEmpty;

  /// 树结构的规范化 SHA-256 指纹，不依赖 Map 的插入顺序。
  String get fingerprint {
    final sortedEdgeIds = edges.keys.toList()..sort();
    final sortedBranchIds = branches.keys.toList()..sort();
    final sortedSelectionKeys = branchSelections.keys.toList()..sort();
    final rootIds =
        edges.values
            .where((edge) => edge.parentMessageId == null)
            .map((edge) => edge.messageId)
            .toList()
          ..sort();
    final canonical = <String, Object?>{
      'conversationId': conversationId,
      'activeBranchId': activeBranchId,
      'edges': [
        for (final id in sortedEdgeIds) [id, edges[id]!.parentMessageId],
      ],
      'branches': [
        for (final id in sortedBranchIds)
          [
            id,
            branches[id]!.conversationId,
            branches[id]!.tipMessageId,
            branches[id]!.name,
            branches[id]!.createdAt.toUtc().microsecondsSinceEpoch,
            branches[id]!.parentBranchId,
            branches[id]!.forkAnchorMessageId,
          ],
      ],
      'branchSelections': [
        for (final id in sortedSelectionKeys) [id, branchSelections[id]],
      ],
      'roots': rootIds,
      'paths': [
        for (final id in sortedBranchIds) [id, _safeBranchPath(id)],
      ],
      'activePath': _safeBranchPath(activeBranchId),
      'activeBranchHistory': activeBranchHistory,
    };
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

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

  /// 将每个直接子节点映射到该分叉点的代表分支。
  ///
  /// 同一个直接子节点下可能继续存在更深的分支。不能把这些后代分支
  /// 全部暴露在当前分叉点，否则树会被投影成扁平的全局分支列表。每个
  /// 子节点只保留一个代表：优先当前活动分支，其次是该分叉点记忆的选择，
  /// 最后按路径深度和创建时间取稳定结果。
  Map<String, List<String>> siblingBranchIdsByMessageId() {
    final childrenByParent = <String?, List<String>>{};
    for (final edge in edges.values) {
      childrenByParent
          .putIfAbsent(edge.parentMessageId, () => <String>[])
          .add(edge.messageId);
    }
    final result = <String, List<String>>{};
    for (final entry in childrenByParent.entries) {
      final parentMessageId = entry.key;
      final children = entry.value;
      if (children.length < 2) continue;

      final representativeByChild = <String, String>{};
      for (final childId in children) {
        final candidates = <ConversationBranch>[];
        for (final branch in branches.values) {
          final path = branchPath(branch.id);
          final childIndex = path.indexOf(childId);
          final isDirectChild = parentMessageId == null
              ? childIndex == 0
              : childIndex > 0 && path[childIndex - 1] == parentMessageId;
          if (isDirectChild) candidates.add(branch);
        }
        if (candidates.isEmpty) continue;

        final active = branches[activeBranchId];
        final rememberedId = parentMessageId == null
            ? null
            : branchSelections[parentMessageId];
        final preferred = candidates.firstWhere(
          (branch) => branch.id == active?.id,
          orElse: () => candidates.firstWhere(
            (branch) => branch.id == rememberedId,
            orElse: () => candidates.reduce((left, right) {
              final leftPathLength = branchPath(left.id).length;
              final rightPathLength = branchPath(right.id).length;
              if (leftPathLength != rightPathLength) {
                return leftPathLength < rightPathLength ? left : right;
              }
              final byTime = left.createdAt.compareTo(right.createdAt);
              if (byTime != 0) return byTime < 0 ? left : right;
              return left.id.compareTo(right.id) <= 0 ? left : right;
            }),
          ),
        );
        representativeByChild[childId] = preferred.id;
      }

      final branchIds = representativeByChild.values.toSet();
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
      for (final childId in representativeByChild.keys) {
        if (siblings.contains(representativeByChild[childId])) {
          result[childId] = siblings;
        }
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

  /// 返回消息的全部严格后代，包含隐藏和嵌套分支。
  Set<String> descendantsOf(String messageId) {
    if (!edges.containsKey(messageId)) {
      throw StateError('message_not_found');
    }
    return Set<String>.unmodifiable(_descendantsOf(messageId));
  }

  /// 是否为分支节点。根级多个消息共享不可见虚拟根分叉锚点。
  bool isBranchNode(String messageId) {
    final edge = edges[messageId];
    if (edge == null) {
      throw StateError('message_not_found');
    }
    return childrenOf(edge.parentMessageId).length > 1;
  }

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
      activeBranchHistory: activate && targetBranchId != activeBranchId
          ? [
              activeBranchId,
              ...activeBranchHistory.where((id) => id != targetBranchId),
            ].take(32).toList(growable: false)
          : activeBranchHistory,
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
        'Message branch parent is not in the tree.',
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
        parentBranchId: _branchIdForAnchor(parentMessageId),
        forkAnchorMessageId: parentMessageId,
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
      activeBranchHistory: [
        activeBranchId,
        ...activeBranchHistory.where((id) => id != branchId),
      ].take(32).toList(growable: false),
    );
  }

  ConversationTree switchBranch(String branchId) {
    if (!branches.containsKey(branchId)) {
      throw ArgumentError.value(branchId, 'branchId', 'Unknown branch.');
    }
    if (branchId == activeBranchId) return this;
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
      activeBranchHistory: [
        activeBranchId,
        ...activeBranchHistory.where((id) => id != branchId),
      ].take(32).toList(growable: false),
    );
  }

  ConversationTree deleteMessage(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) => deleteMessages({messageId}, recentBranchIds: recentBranchIds);

  ConversationTreeTransformResult deleteMessageOnlyResult(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final updated = deleteMessageOnly(
      messageId,
      recentBranchIds: recentBranchIds,
    );
    return _transformResult(updated);
  }

  ConversationTreeTransformResult deleteMessageAndFollowingResult(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final updated = deleteMessageAndFollowing(
      messageId,
      recentBranchIds: recentBranchIds,
    );
    return _transformResult(updated);
  }

  ConversationTreeTransformResult deleteCurrentBranchResult(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final updated = deleteCurrentBranch(
      messageId,
      recentBranchIds: recentBranchIds,
    );
    return _transformResult(updated);
  }

  ConversationTreeTransformResult deleteMessageNodeResult(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final updated = deleteMessageNode(
      messageId,
      recentBranchIds: recentBranchIds,
    );
    return _transformResult(updated);
  }

  ConversationTreeTransformResult deleteAllBranchesResult(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final updated = deleteAllBranches(
      messageId,
      recentBranchIds: recentBranchIds,
    );
    return _transformResult(updated);
  }

  /// 删除单条消息并把其直接子节点重挂到原父节点。
  ConversationTree deleteMessageOnly(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    _requireMessageOperationTarget(
      messageId,
      operation: 'delete_message_only',
      allowBranchNode: false,
      allowLeaf: true,
    );
    return removeMessageOnly(messageId, recentBranchIds: recentBranchIds);
  }

  /// 删除消息及其全部后代（包括隐藏和嵌套分支）。
  ConversationTree deleteMessageAndFollowing(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    _requireMessageOperationTarget(
      messageId,
      operation: 'delete_message_and_following',
      allowBranchNode: false,
      allowLeaf: false,
    );
    return deleteMessages({messageId}, recentBranchIds: recentBranchIds);
  }

  /// 删除分支节点本身，并保留当前活动直接后继。
  ConversationTree deleteMessageNode(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    _requireMessageOperationTarget(
      messageId,
      operation: 'delete_message_node',
      allowBranchNode: true,
      allowLeaf: true,
    );
    if (!isBranchNode(messageId)) {
      throw StateError('delete_message_node_requires_branch_node');
    }
    return deleteNodeKeepActiveBranch(
      messageId,
      recentBranchIds: recentBranchIds,
    );
  }

  /// 删除目标分支节点所属锚点下的全部直接子树。
  ConversationTree deleteAllBranches(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    _requireMessageOperationTarget(
      messageId,
      operation: 'delete_all_branches',
      allowBranchNode: true,
      allowLeaf: false,
    );
    if (!isBranchNode(messageId)) {
      throw StateError('delete_all_branches_requires_branch_node');
    }
    final parent = edges[messageId]!.parentMessageId;
    return deleteMessages(childrenOf(parent), recentBranchIds: recentBranchIds);
  }

  /// 在同一棵旧树快照上删除多个节点及其全部后代。
  ///
  /// 目标集合先求并集，再一次性重建边和分支，因而结果不依赖调用方
  /// 传入集合的遍历顺序。
  ConversationTree deleteMessages(
    Iterable<String> messageIds, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final targets = messageIds.where(edges.containsKey).toSet();
    if (targets.isEmpty) return this;
    final previousActivePath = activePath();
    final removedIds = <String>{};
    for (final messageId in targets) {
      removedIds
        ..add(messageId)
        ..addAll(_descendantsOf(messageId));
    }
    final nextEdges = Map<String, MessageTreeEdge>.from(edges)
      ..removeWhere((id, _) => removedIds.contains(id));
    final affectedBranches = <ConversationBranch>[];
    final retainedCandidates = <ConversationBranch>[];
    final nextBranches = <String, ConversationBranch>{};
    final branchPaths = <String, List<String>>{
      for (final branch in branches.values)
        branch.id: _branchPathFor(branch.id, branches, edges),
    };
    for (final branch in branches.values) {
      final tip = branch.tipMessageId;
      if (tip != null && removedIds.contains(tip)) {
        affectedBranches.add(branch);
        String? retainedTip = tip;
        while (retainedTip != null && removedIds.contains(retainedTip)) {
          retainedTip = edges[retainedTip]?.parentMessageId;
        }

        if (retainedTip == null) {
          continue;
        }
        final branchPath = _branchPathFor(branch.id, branches, edges);
        final retainedIndex = branchPath.indexOf(retainedTip);
        if (retainedIndex < 0) continue;
        final retainedPath = branchPath.take(retainedIndex + 1);
        final parentBranchPath = branch.parentBranchId == null
            ? null
            : branchPaths[branch.parentBranchId!];
        final unaffectedMessageIds = <String>{};
        if (parentBranchPath == null) {
          for (final other in branches.values) {
            if (other.id == branch.id) continue;
            final otherTip = other.tipMessageId;
            if (otherTip == null || removedIds.contains(otherTip)) continue;
            unaffectedMessageIds.addAll(branchPaths[other.id] ?? const []);
          }
        }
        final hasDivergentPrefix = parentBranchPath != null
            ? retainedPath.any((id) => !parentBranchPath.contains(id))
            : retainedPath.any((id) => !unaffectedMessageIds.contains(id));
        if (hasDivergentPrefix) {
          retainedCandidates.add(branch.copyWith(tipMessageId: retainedTip));
        }
      } else {
        nextBranches[branch.id] = branch;
      }
    }

    for (final branch in retainedCandidates) {
      nextBranches[branch.id] = branch;
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

    final fallbackIds = <String>[...activeBranchHistory, ...recentBranchIds];
    for (final messageId in targets) {
      final remembered = branchSelections[messageId];
      if (remembered != null) fallbackIds.add(remembered);
      final parent = edges[messageId]?.parentMessageId;
      for (final childId in childrenOf(parent)) {
        if (childId == messageId) continue;
        for (final branch in branches.values) {
          if (_branchPathFor(branch.id, branches, edges).contains(childId)) {
            fallbackIds.add(branch.id);
          }
        }
      }
    }
    final nextSelections = Map<String, String>.from(branchSelections);
    for (final messageId in targets) {
      final parent = edges[messageId]?.parentMessageId;
      if (parent == null) continue;
      final survivingChildren = nextEdges.values
          .where((edge) => edge.parentMessageId == parent)
          .map((edge) => edge.messageId)
          .toList(growable: false);
      if (survivingChildren.length < 2) {
        nextSelections.remove(parent);
        continue;
      }
      final remembered = nextSelections[parent];
      if (remembered != null && nextBranches.containsKey(remembered)) {
        final path = _branchPathFor(remembered, nextBranches, nextEdges);
        final parentIndex = path.indexOf(parent);
        if (parentIndex >= 0 &&
            parentIndex + 1 < path.length &&
            survivingChildren.contains(path[parentIndex + 1])) {
          continue;
        }
      }
      final candidates = <ConversationBranch>[];
      for (final branch in nextBranches.values) {
        final path = _branchPathFor(branch.id, nextBranches, nextEdges);
        final index = path.indexOf(parent);
        if (index >= 0 &&
            index + 1 < path.length &&
            survivingChildren.contains(path[index + 1])) {
          candidates.add(branch);
        }
      }
      candidates.sort((left, right) {
        final byDepth = _branchPathFor(left.id, nextBranches, nextEdges).length
            .compareTo(
              _branchPathFor(right.id, nextBranches, nextEdges).length,
            );
        if (byDepth != 0) return byDepth;
        final byTime = left.createdAt.compareTo(right.createdAt);
        if (byTime != 0) return byTime;
        return left.id.compareTo(right.id);
      });
      if (candidates.isNotEmpty) nextSelections[parent] = candidates.first.id;
    }
    final prunedEdges = _pruneUnreachableEdges(nextBranches, nextEdges);
    final normalizedBranches = _normalizeBranchRelations(
      nextBranches,
      prunedEdges,
    );
    final nextActiveBranchId = nextBranches.containsKey(activeBranchId)
        ? activeBranchId
        : _fallbackBranchId(
            nextBranches,
            preferredBranchIds: fallbackIds,
            preferredPath: previousActivePath,
            pathEdges: nextEdges,
          );
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: nextActiveBranchId,
      branches: normalizedBranches,
      edges: prunedEdges,
      branchSelections: _pruneBranchSelections(
        branches: normalizedBranches,
        edges: prunedEdges,
        baseSelections: nextSelections,
      ),
      activeBranchHistory: _pruneActiveBranchHistory(
        normalizedBranches,
        nextActiveBranchId,
        additional: fallbackIds,
      ),
    );
  }

  /// 删除 [messageId] 及其所有后代。子树保持完整。
  ConversationTree deleteSubtree(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) => deleteMessage(messageId, recentBranchIds: recentBranchIds);

  /// 删除 [messageId] 所在逻辑分支的后续消息，保留公共父节点与兄弟分支。
  ///
  /// 分支可能从某个助手消息继续创建子分支。此时该助手消息仍会被父
  /// 分支引用，但它属于当前分叉的首个独有节点，必须和后续消息一起
  /// 删除；否则删除 C2 会留下 C 这个“半条分支”。
  ConversationTree deleteCurrentBranch(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    _requireMessageOperationTarget(
      messageId,
      operation: 'delete_current_branch',
      allowBranchNode: true,
      allowLeaf: true,
    );
    if (!isBranchNode(messageId)) {
      throw StateError('delete_current_branch_requires_branch_node');
    }
    if (!isMessageInActivePath(messageId)) {
      throw StateError('delete_current_branch_target_not_active');
    }
    final removedIds = <String>{messageId}..addAll(_descendantsOf(messageId));
    final fallbackHistory = <String>[];
    for (final branchId in activeBranchHistory) {
      if (branchId == activeBranchId || fallbackHistory.contains(branchId)) {
        continue;
      }
      final branch = branches[branchId];
      if (branch == null) continue;
      final tip = branch.tipMessageId;
      if (tip != null && removedIds.contains(tip)) continue;
      fallbackHistory.add(branchId);
    }
    if (fallbackHistory.isEmpty) {
      throw StateError('delete_current_branch_history_unavailable');
    }
    return deleteMessages({messageId}, recentBranchIds: fallbackHistory);
  }

  /// 批量局部删除；先处理更深节点，避免输入排列影响重挂接结果。
  ConversationTree removeMessagesOnly(
    Iterable<String> messageIds, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final targets = messageIds.where(edges.containsKey).toList(growable: false)
      ..sort((left, right) {
        final byDepth = _pathDepth(right).compareTo(_pathDepth(left));
        if (byDepth != 0) return byDepth;
        return left.compareTo(right);
      });
    var result = this;
    for (final messageId in targets) {
      result = result.removeMessageOnly(
        messageId,
        recentBranchIds: recentBranchIds,
      );
    }
    return result;
  }

  /// 仅删除 [messageId]；若它是分叉末端的唯一消息，同时移除该分支。
  ConversationTree removeMessageOnly(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final removed = edges[messageId];
    if (removed == null) return this;

    // 删除分支尖端后，只有当尖端之前没有任何独有前缀时，分支才会
    // 变成空锚点并需要移除。若父节点仍属于该分支的独有前缀，尖端应
    // 回退到父节点，否则清理不可达边时会把这条仍有效的分支消息一起裁掉。
    final branchPaths = <String, List<String>>{
      for (final branch in branches.values)
        branch.id: _branchPathFor(branch.id, branches, edges),
    };
    final terminalBranchIds = <String>{};
    final branchTipReplacements = <String, String>{};
    for (final branch in branches.values) {
      if (branch.tipMessageId != messageId) continue;
      final parentMessageId = removed.parentMessageId;
      final path = branchPaths[branch.id] ?? const <String>[];
      final targetIndex = path.lastIndexOf(messageId);
      final prefix = targetIndex <= 0
          ? const <String>[]
          : path.take(targetIndex);
      final hasDivergentPrefix = branchPaths.entries.any(
        (entry) =>
            entry.key != branch.id &&
            prefix.any((prefixId) => !entry.value.contains(prefixId)),
      );
      if (parentMessageId == null || !hasDivergentPrefix) {
        terminalBranchIds.add(branch.id);
      } else {
        branchTipReplacements[branch.id] = parentMessageId;
      }
    }

    // 删除分叉点时，活动分支可能正好停在被删节点。先根据删除前
    // 记录的分支选择找到一个仍包含后续消息的分支，避免活动路径退回
    // 父节点后把后续内容全部留在主聊天区之外。
    String? continuationBranchId;
    final rememberedContinuation = branchSelections[messageId];
    if (rememberedContinuation != null) {
      final path = _branchPathFor(rememberedContinuation, branches, edges);
      final index = path.indexOf(messageId);
      if (index >= 0 && index + 1 < path.length) {
        continuationBranchId = rememberedContinuation;
      }
    }
    if (continuationBranchId == null) {
      final candidates = <ConversationBranch>[];
      for (final branch in branches.values) {
        final path = _branchPathFor(branch.id, branches, edges);
        final index = path.indexOf(messageId);
        if (index >= 0 && index + 1 < path.length) {
          candidates.add(branch);
        }
      }
      continuationBranchId = _chooseFallbackBranch({
        for (final branch in candidates) branch.id: branch,
      })?.id;
    }

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
    final nextBranches = <String, ConversationBranch>{};
    for (final branch in branches.values) {
      if (!terminalBranchIds.contains(branch.id)) {
        nextBranches[branch.id] = branchTipReplacements.containsKey(branch.id)
            ? branch.copyWith(tipMessageId: branchTipReplacements[branch.id])
            : branch;
      }
    }
    if (nextBranches.isEmpty) {
      final fallback = _chooseFallbackBranch({
        for (final branch in branches.values)
          if (terminalBranchIds.contains(branch.id)) branch.id: branch,
      });
      if (fallback == null) throw StateError('cannot_delete_last_branch');
      nextBranches[fallback.id] = fallback.copyWith(
        tipMessageId: removed.parentMessageId,
        clearTip: removed.parentMessageId == null,
      );
    }

    final nextSelections = Map<String, String>.from(branchSelections)
      ..remove(messageId);
    if (removed.parentMessageId != null && continuationBranchId != null) {
      final survivingChildren = nextEdges.values
          .where((edge) => edge.parentMessageId == removed.parentMessageId)
          .map((edge) => edge.messageId)
          .toList(growable: false);
      if (survivingChildren.length >= 2) {
        nextSelections[removed.parentMessageId!] = continuationBranchId;
      } else {
        nextSelections.remove(removed.parentMessageId);
      }
    }
    // 尖端删除后，分支可能已回退到仍存活的独有前缀；只要分支记录仍在，
    // 普通消息删除不得借此触发活动分支回退。
    final nextActiveBranchId = nextBranches.containsKey(activeBranchId)
        ? activeBranchId
        : _fallbackBranchId(
            nextBranches,
            preferredBranchIds: [
              ...recentBranchIds,
              if (continuationBranchId != null) continuationBranchId,
            ],
          );
    final prunedEdges = _pruneUnreachableEdges(nextBranches, nextEdges);
    final normalizedBranches = _normalizeBranchRelations(
      nextBranches,
      prunedEdges,
    );
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: nextActiveBranchId,
      branches: normalizedBranches,
      edges: prunedEdges,
      branchSelections: _pruneBranchSelections(
        branches: normalizedBranches,
        edges: prunedEdges,
        baseSelections: nextSelections,
      ),
      activeBranchHistory: _pruneActiveBranchHistory(
        normalizedBranches,
        nextActiveBranchId,
        additional: [
          ...activeBranchHistory,
          ...recentBranchIds,
          if (continuationBranchId != null) continuationBranchId,
        ],
      ),
    );
  }

  /// 删除活动路径上的分叉节点，同时只保留该节点后的活动后继。
  ///
  /// 目标节点的兄弟分支不受影响；目标节点下的非活动直接子树会被删除，
  /// 活动直接子节点则重挂到目标节点的父节点。非分叉节点不执行此操作，
  /// 由消息菜单层保证该入口只对分叉节点开放。
  ConversationTree deleteNodeKeepActiveBranch(
    String messageId, {
    Iterable<String> recentBranchIds = const <String>[],
  }) {
    final activePath = this.activePath();
    final targetIndex = activePath.indexOf(messageId);
    if (targetIndex < 0) return this;

    final removed = edges[messageId];
    if (removed == null || childrenOf(removed.parentMessageId).length < 2) {
      return this;
    }

    final activeContinuation = targetIndex + 1 < activePath.length
        ? activePath[targetIndex + 1]
        : null;
    final directChildren = childrenOf(messageId);
    final removedIds = <String>{messageId};
    for (final childId in directChildren) {
      if (childId == activeContinuation) continue;
      removedIds
        ..add(childId)
        ..addAll(_descendantsOf(childId));
    }

    final nextEdges = Map<String, MessageTreeEdge>.from(edges)
      ..removeWhere((id, _) => removedIds.contains(id));
    if (activeContinuation != null &&
        nextEdges.containsKey(activeContinuation)) {
      nextEdges[activeContinuation] = MessageTreeEdge(
        messageId: activeContinuation,
        parentMessageId: removed.parentMessageId,
      );
    }

    final nextBranches = <String, ConversationBranch>{};
    for (final branch in branches.values) {
      final tip = branch.tipMessageId;
      if (tip != null && removedIds.contains(tip)) continue;
      nextBranches[branch.id] = branch;
    }
    if (nextBranches.isEmpty) throw StateError('cannot_delete_last_branch');

    final baseSelections = Map<String, String>.from(branchSelections)
      ..removeWhere(
        (message, branchId) =>
            removedIds.contains(message) || !nextBranches.containsKey(branchId),
      );
    final nextSelections = _rememberBranchSelections(
      activeBranchId,
      branches: nextBranches,
      edges: nextEdges,
      baseSelections: baseSelections,
    );
    final prunedEdges = _pruneUnreachableEdges(nextBranches, nextEdges);
    final normalizedBranches = _normalizeBranchRelations(
      nextBranches,
      prunedEdges,
    );
    final nextActiveBranchId = nextBranches.containsKey(activeBranchId)
        ? activeBranchId
        : _fallbackBranchId(nextBranches, preferredBranchIds: recentBranchIds);
    return ConversationTree(
      conversationId: conversationId,
      activeBranchId: nextActiveBranchId,
      branches: normalizedBranches,
      edges: prunedEdges,
      branchSelections: _pruneBranchSelections(
        branches: normalizedBranches,
        edges: prunedEdges,
        baseSelections: nextSelections,
      ),
      activeBranchHistory: _pruneActiveBranchHistory(
        normalizedBranches,
        nextActiveBranchId,
        additional: recentBranchIds,
      ),
    );
  }

  ConversationTree createMessageBranch({
    required String branchId,
    required String fromMessageId,
    String name = '',
    DateTime? createdAt,
  }) => createMessageBranchFromParent(
    branchId: branchId,
    fromMessageId: fromMessageId,
    name: name,
    createdAt: createdAt,
  );

  ConversationTree createMessageBranchFromParent({
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
        'Message branch point is not in the tree.',
      );
    }
    final nextBranches = Map<String, ConversationBranch>.from(branches)
      ..[branchId] = ConversationBranch(
        id: branchId,
        conversationId: conversationId,
        tipMessageId: fromMessageId,
        name: name,
        createdAt: createdAt ?? DateTime.now(),
        parentBranchId: _branchIdForAnchor(fromMessageId),
        forkAnchorMessageId: fromMessageId,
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
      activeBranchHistory: [
        activeBranchId,
        ...activeBranchHistory.where((id) => id != branchId),
      ].take(32).toList(growable: false),
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
    Map<String, String>? baseSelections,
  }) {
    final result = <String, String>{};
    for (final entry in (baseSelections ?? branchSelections).entries) {
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

  List<String>? _safeBranchPath(String branchId) {
    final branch = branches[branchId];
    if (branch == null || branch.tipMessageId == null) {
      return branch == null ? null : const <String>[];
    }
    final reversed = <String>[];
    final visited = <String>{};
    String? cursor = branch.tipMessageId;
    while (cursor != null) {
      if (!visited.add(cursor)) return null;
      final edge = edges[cursor];
      if (edge == null) return null;
      reversed.add(cursor);
      cursor = edge.parentMessageId;
    }
    return reversed.reversed.toList(growable: false);
  }

  Set<String> _cycleMessages() {
    final visiting = <String>{};
    final visited = <String>{};
    final cycles = <String>{};

    void visit(String messageId) {
      if (visiting.contains(messageId)) {
        cycles.add(messageId);
        return;
      }
      if (!visited.add(messageId)) return;
      visiting.add(messageId);
      final parent = edges[messageId]?.parentMessageId;
      if (parent != null && edges.containsKey(parent)) visit(parent);
      visiting.remove(messageId);
    }

    for (final messageId in edges.keys) {
      visit(messageId);
    }
    return cycles;
  }

  Set<String> _reachableMessageIds() {
    final reachable = <String>{};
    for (final branch in branches.values) {
      final path = _safeBranchPath(branch.id);
      if (path != null) reachable.addAll(path);
    }
    return reachable;
  }

  static Map<String, MessageTreeEdge> _pruneUnreachableEdges(
    Map<String, ConversationBranch> branches,
    Map<String, MessageTreeEdge> edges,
  ) {
    final reachable = <String>{};
    for (final branch in branches.values) {
      final visited = <String>{};
      String? cursor = branch.tipMessageId;
      while (cursor != null && visited.add(cursor)) {
        final edge = edges[cursor];
        if (edge == null) break;
        reachable.add(cursor);
        cursor = edge.parentMessageId;
      }
    }
    return <String, MessageTreeEdge>{
      for (final entry in edges.entries)
        if (reachable.contains(entry.key)) entry.key: entry.value,
    };
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

  String? _branchIdForAnchor(String? messageId) {
    if (messageId == null) return null;
    return preferredBranchIdForMessage(messageId);
  }

  Map<String, ConversationBranch> _normalizeBranchRelations(
    Map<String, ConversationBranch> nextBranches,
    Map<String, MessageTreeEdge> nextEdges,
  ) {
    final result = <String, ConversationBranch>{};
    for (final branch in nextBranches.values) {
      var parentBranchId = branch.parentBranchId;
      final visitedBranches = <String>{};
      while (parentBranchId != null &&
          !nextBranches.containsKey(parentBranchId) &&
          visitedBranches.add(parentBranchId)) {
        parentBranchId = branches[parentBranchId]?.parentBranchId;
      }
      if (parentBranchId != null && !nextBranches.containsKey(parentBranchId)) {
        parentBranchId = null;
      }

      var forkAnchorMessageId = branch.forkAnchorMessageId;
      final visitedMessages = <String>{};
      while (forkAnchorMessageId != null &&
          !nextEdges.containsKey(forkAnchorMessageId) &&
          visitedMessages.add(forkAnchorMessageId)) {
        forkAnchorMessageId = edges[forkAnchorMessageId]?.parentMessageId;
      }
      if (forkAnchorMessageId != null &&
          !nextEdges.containsKey(forkAnchorMessageId)) {
        forkAnchorMessageId = null;
      }

      result[branch.id] = branch.copyWith(
        parentBranchId: parentBranchId,
        forkAnchorMessageId: forkAnchorMessageId,
        clearParentBranch: parentBranchId == null,
        clearForkAnchor: forkAnchorMessageId == null,
      );
    }
    return result;
  }

  ConversationTreeTransformResult _transformResult(ConversationTree updated) {
    return ConversationTreeTransformResult(
      before: this,
      after: updated,
      deletedMessageIds: Set<String>.unmodifiable(
        edges.keys.where((id) => !updated.edges.containsKey(id)),
      ),
    );
  }

  List<String> _pruneActiveBranchHistory(
    Map<String, ConversationBranch> nextBranches,
    String nextActiveBranchId, {
    Iterable<String> additional = const <String>[],
  }) {
    final result = <String>[];
    for (final branchId in [...activeBranchHistory, ...additional]) {
      if (branchId == nextActiveBranchId ||
          !nextBranches.containsKey(branchId) ||
          result.contains(branchId)) {
        continue;
      }
      result.add(branchId);
      if (result.length == 32) break;
    }
    return result;
  }

  void _requireMessageOperationTarget(
    String messageId, {
    required String operation,
    required bool allowBranchNode,
    required bool allowLeaf,
  }) {
    if (!edges.containsKey(messageId)) {
      throw StateError('${operation}_message_not_found');
    }
    if (!allowBranchNode && isBranchNode(messageId)) {
      throw StateError('${operation}_branch_node_not_allowed');
    }
    if (!allowLeaf && childrenOf(messageId).isEmpty) {
      throw StateError('${operation}_leaf_not_allowed');
    }
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

  int _pathDepth(String messageId) {
    var depth = 0;
    String? cursor = messageId;
    final visited = <String>{};
    while (cursor != null && visited.add(cursor)) {
      final parent = edges[cursor]?.parentMessageId;
      if (parent == null) break;
      depth++;
      cursor = parent;
    }
    return depth;
  }

  String _fallbackBranchId(
    Map<String, ConversationBranch> branches, {
    Iterable<String> preferredBranchIds = const <String>[],
    List<String>? preferredPath,
    Map<String, MessageTreeEdge>? pathEdges,
  }) {
    if (branches.isEmpty) {
      throw StateError('cannot_delete_last_branch');
    }
    // 显式活动历史优先于任何路径相似度推导。调用方传入的候选顺序
    // 已经代表“上一个、上上个活动分支”的时间顺序。
    for (final branchId in preferredBranchIds) {
      if (branches.containsKey(branchId)) return branchId;
    }
    if (preferredPath != null && preferredPath.isNotEmpty) {
      // 删除活动分支后优先保留旧路径前缀，避免切到 root 造成历史消息看似消失。
      final edgesForPath = pathEdges ?? edges;
      final prefixLengths = <String, int>{};
      var longestPrefix = 0;
      for (final branch in branches.values) {
        final path = _branchPathFor(branch.id, branches, edgesForPath);
        var prefixLength = 0;
        while (prefixLength < preferredPath.length &&
            prefixLength < path.length &&
            preferredPath[prefixLength] == path[prefixLength]) {
          prefixLength++;
        }
        prefixLengths[branch.id] = prefixLength;
        if (prefixLength > longestPrefix) longestPrefix = prefixLength;
      }
      if (longestPrefix > 0) {
        final prefixCandidates = <String, ConversationBranch>{
          for (final branch in branches.values)
            if (prefixLengths[branch.id] == longestPrefix) branch.id: branch,
        };
        for (final branchId in preferredBranchIds) {
          if (prefixCandidates.containsKey(branchId)) return branchId;
        }
        return _chooseFallbackBranch(prefixCandidates)!.id;
      }
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
