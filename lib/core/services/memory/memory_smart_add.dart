import 'dart:convert';

import '../../database/chat_database_repository.dart';
import '../../models/assistant.dart';
import '../../models/memory_entry.dart';
import 'memory_prompts.dart';
import 'memory_repository.dart';
import 'memory_tokenizer.dart';
import 'memory_tools.dart';
import 'memory_trace.dart';

/// Smart Add 动作 (§12.6)。
enum SmartAddAction { neu, merge, conflict, skip }

/// 单个候选项的已解析/已决策结果。
class SmartAddDecision {
  const SmartAddDecision({
    required this.action,
    this.targetId,
    this.mergedContent,
    this.relatedIds = const <String>[],
    this.degraded = false,
  });

  final SmartAddAction action;
  final String? targetId;
  final String? mergedContent;
  final List<String> relatedIds;
  final bool degraded;
}

/// 应用单个 Smart Add 决策的结果。
class SmartAddResult {
  const SmartAddResult({
    required this.action,
    this.id,
    this.content,
    this.reason,
  });

  final SmartAddAction action;
  final String? id;
  final String? content;
  final String? reason;

  Map<String, dynamic> toToolJson() {
    switch (action) {
      case SmartAddAction.skip:
        return {
          'action': 'SKIP',
          if (reason != null) 'reason': reason,
          if (id != null) 'id': id,
        };
      case SmartAddAction.neu:
        return {'action': 'NEW', 'id': id, 'content': content};
      case SmartAddAction.merge:
        return {'action': 'MERGE', 'id': id, 'content': content};
      case SmartAddAction.conflict:
        return {
          'action': 'CONFLICT',
          'id': id,
          'content': content,
          if (reason != null) 'archivedId': reason,
        };
    }
  }
}

/// Smart Add 的输入项（来自 Extract 或 `memory_update`）。
class SmartAddItem {
  const SmartAddItem({
    required this.type,
    required this.content,
    required this.scope,
    this.assistantId,
  });

  final MemoryType type;
  final String content;
  final MemoryScope scope;
  final String? assistantId;
}

/// Smart Add：候选招回、LLM 裁决、NEW/MERGE/CONFLICT/SKIP (§12.6)。
class MemorySmartAdd {
  MemorySmartAdd({required this.repository, required this.chatRepository});

  final MemoryRepository repository;
  final ChatDatabaseRepository chatRepository;

  static const int candidateLimit = 5;

  static String resolvePerItemTemplate({
    required MemoryPromptLang lang,
    String? overrideZh,
    String? overrideEn,
  }) {
    if (lang == MemoryPromptLang.zh) {
      final o = overrideZh?.trim();
      if (o != null && o.isNotEmpty) return o;
      return MemoryPrompts.smartAddZh;
    }
    final o = overrideEn?.trim();
    if (o != null && o.isNotEmpty) return o;
    return MemoryPrompts.smartAddEn;
  }

  static String resolveBatchTemplate({
    required MemoryPromptLang lang,
    String? overrideZh,
    String? overrideEn,
  }) {
    if (lang == MemoryPromptLang.zh) {
      final o = overrideZh?.trim();
      if (o != null && o.isNotEmpty) return o;
      return MemoryPrompts.smartAddBatchZh;
    }
    final o = overrideEn?.trim();
    if (o != null && o.isNotEmpty) return o;
    return MemoryPrompts.smartAddBatchEn;
  }

  static String buildPerItemPrompt({
    required MemoryPromptLang lang,
    required MemoryType type,
    required String newInfo,
    required String entriesText,
    String? overrideZh,
    String? overrideEn,
  }) {
    return resolvePerItemTemplate(
          lang: lang,
          overrideZh: overrideZh,
          overrideEn: overrideEn,
        )
        .replaceAll('{{type}}', MemoryEntry.typeToString(type))
        .replaceAll('{{newInfo}}', newInfo)
        .replaceAll('{{entriesText}}', entriesText);
  }

  static String buildBatchPrompt({
    required MemoryPromptLang lang,
    required String itemsText,
    required String entriesText,
    String? overrideZh,
    String? overrideEn,
  }) {
    return resolveBatchTemplate(
          lang: lang,
          overrideZh: overrideZh,
          overrideEn: overrideEn,
        )
        .replaceAll('{{itemsText}}', itemsText)
        .replaceAll('{{entriesText}}', entriesText);
  }

  static String formatEntriesPerItem(List<MemoryEntry> entries) {
    if (entries.isEmpty) return '';
    final buf = StringBuffer();
    for (final e in entries) {
      buf.writeln('${e.id} ${e.content}');
    }
    return buf.toString().trimRight();
  }

  static String formatEntriesBatched(List<MemoryEntry> entries) {
    if (entries.isEmpty) return '';
    final buf = StringBuffer();
    for (final e in entries) {
      buf.writeln('${e.id} (${MemoryEntry.typeToString(e.type)}) ${e.content}');
    }
    return buf.toString().trimRight();
  }

  static String formatItemsText(List<SmartAddItem> items) {
    final buf = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      buf.writeln(
        '[${i + 1}] ${MemoryEntry.typeToString(item.type)} ${item.content}',
      );
    }
    return buf.toString().trimRight();
  }

  /// 候选招回 (§12.6)：OR + 命中，用同类型近期条目补足到 5 条。
  Future<List<MemoryEntry>> candidatesFor({
    required String? assistantId,
    required MemoryType type,
    required String newInfo,
  }) async {
    final tokens = MemoryTokenizer.tokenize(newInfo);
    final escaped = [for (final t in tokens) MemoryTokenizer.escapeLike(t)];

    var base = <MemoryEntry>[];
    if (escaped.isNotEmpty) {
      // 复制：search 可能返回不可修改的常量空列表。
      base = List<MemoryEntry>.of(
        await chatRepository.searchMemories(
          assistantId: assistantId,
          tokens: escaped,
          type: type,
          matchAll: false,
          limit: candidateLimit,
        ),
      );
    }

    if (base.length >= candidateLimit) return base;

    final recent = List<MemoryEntry>.of(
      await chatRepository.queryVisibleMemories(
        assistantId: assistantId,
        type: type,
      ),
    );
    recent.sort((a, b) {
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      if (byUpdated != 0) return byUpdated;
      return a.id.compareTo(b.id);
    });
    final seen = {for (final e in base) e.id};
    for (final e in recent) {
      if (base.length >= candidateLimit) break;
      if (seen.contains(e.id)) continue;
      base.add(e);
      seen.add(e.id);
    }
    return base;
  }

  static Object? extractJson(String response) {
    var text = response.trim();
    final fence = RegExp(
      r'```(?:json)?\s*([\s\S]*?)```',
      caseSensitive: false,
    ).firstMatch(text);
    if (fence != null) {
      text = fence.group(1)!.trim();
    }
    final startObj = text.indexOf('{');
    final startArr = text.indexOf('[');
    int start;
    if (startObj < 0 && startArr < 0) return null;
    if (startObj < 0) {
      start = startArr;
    } else if (startArr < 0) {
      start = startObj;
    } else {
      start = startObj < startArr ? startObj : startArr;
    }
    final endObj = text.lastIndexOf('}');
    final endArr = text.lastIndexOf(']');
    final end = endObj > endArr ? endObj : endArr;
    if (end <= start) return null;
    try {
      return jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }

  static SmartAddAction? _parseAction(dynamic raw) {
    final s = raw?.toString().trim().toUpperCase();
    switch (s) {
      case 'NEW':
        return SmartAddAction.neu;
      case 'MERGE':
        return SmartAddAction.merge;
      case 'CONFLICT':
        return SmartAddAction.conflict;
      case 'SKIP':
        return SmartAddAction.skip;
      default:
        return null;
    }
  }

  /// 依据 [candidateIds] 校验/降级单个决策 (§12.6)。
  static SmartAddDecision normalizeDecision(
    SmartAddDecision decision,
    Set<String> candidateIds, {
    Set<String>? mergeableIds,
  }) {
    var action = decision.action;
    var targetId = decision.targetId;
    var merged = decision.mergedContent;
    final related = [
      for (final id in decision.relatedIds)
        if (candidateIds.contains(id)) id,
    ];
    final mergeTargets = mergeableIds ?? candidateIds;

    if (action == SmartAddAction.merge || action == SmartAddAction.conflict) {
      if (targetId == null || !mergeTargets.contains(targetId)) {
        action = SmartAddAction.neu;
        targetId = null;
        merged = null;
      }
    }
    if (action == SmartAddAction.merge) {
      final mc = merged?.trim() ?? '';
      if (mc.isEmpty) {
        return const SmartAddDecision(
          action: SmartAddAction.skip,
          degraded: true,
        );
      }
    }
    return SmartAddDecision(
      action: action,
      targetId: targetId,
      mergedContent: merged,
      relatedIds: related,
      degraded: decision.degraded,
    );
  }

  /// 解析单项 JSON 响应。返回 null 时由调用方降级。
  static SmartAddDecision? parsePerItem(String response) {
    final decoded = extractJson(response);
    if (decoded is! Map) return null;
    final action = _parseAction(decoded['action']);
    if (action == null) return null;
    final relatedRaw = decoded['relatedIds'];
    final related = <String>[];
    if (relatedRaw is List) {
      for (final r in relatedRaw) {
        final id = r?.toString();
        if (id != null && id.isNotEmpty) related.add(id);
      }
    }
    final target = decoded['targetId']?.toString();
    final merged = decoded['mergedContent']?.toString();
    return SmartAddDecision(
      action: action,
      targetId: (target == null || target.isEmpty || target == 'null')
          ? null
          : target,
      mergedContent: merged,
      relatedIds: related,
    );
  }

  /// 解析批量 JSON。缺失索引留 null 以供降级。
  static List<SmartAddDecision?>? parseBatch(String response, int count) {
    final decoded = extractJson(response);
    if (decoded is! Map) return null;
    final results = decoded['results'];
    if (results is! List) return null;

    final byIndex = <int, SmartAddDecision>{};
    for (final item in results) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final index = map['index'];
      final idx = index is int ? index : int.tryParse(index?.toString() ?? '');
      if (idx == null || idx < 1 || idx > count) continue;
      final action = _parseAction(map['action']);
      if (action == null) continue;
      final relatedRaw = map['relatedIds'];
      final related = <String>[];
      if (relatedRaw is List) {
        for (final r in relatedRaw) {
          final id = r?.toString();
          if (id != null && id.isNotEmpty) related.add(id);
        }
      }
      final target = map['targetId']?.toString();
      byIndex[idx] = SmartAddDecision(
        action: action,
        targetId: (target == null || target.isEmpty || target == 'null')
            ? null
            : target,
        mergedContent: map['mergedContent']?.toString(),
        relatedIds: related,
      );
    }

    return [for (var i = 1; i <= count; i++) byIndex[i]];
  }

  /// 完全重复 → SKIP；否则 NEW（无 LLM / JSON 异常时的降级路径）。
  Future<SmartAddDecision> degradeDecision({
    required String? visibilityAssistantId,
    required MemoryType type,
    required String content,
  }) async {
    final exact = await chatRepository.findExactMemory(
      assistantId: visibilityAssistantId,
      type: type,
      contentNormalized: MemoryEntry.normalizeContent(content),
    );
    if (exact != null) {
      return SmartAddDecision(
        action: SmartAddAction.skip,
        targetId: exact.id,
        degraded: true,
      );
    }
    return const SmartAddDecision(action: SmartAddAction.neu, degraded: true);
  }

  /// 读取条目当前内容，仅用于 trace 的前后值。
  Future<String?> _contentBefore(String? id) async {
    if (id == null) return null;
    try {
      final found = await chatRepository.memoriesByIds([id]);
      return found.isEmpty ? null : found.first.content;
    } catch (_) {
      return null;
    }
  }

  Future<SmartAddResult> applyDecision({
    required SmartAddItem item,
    required SmartAddDecision decision,
    required Set<String> candidateIds,
    required MemorySource source,
    MemoryTraceStep? traceStep,
    Set<String>? mergeableIds,
  }) async {
    final normalized = normalizeDecision(
      decision,
      candidateIds,
      mergeableIds: mergeableIds,
    );
    final typeLabel = MemoryEntry.typeToString(item.type);
    switch (normalized.action) {
      case SmartAddAction.skip:
        return SmartAddResult(
          action: SmartAddAction.skip,
          id: normalized.targetId,
          reason: normalized.degraded ? 'duplicate' : null,
        );
      case SmartAddAction.neu:
        final created = await repository.create(
          scope: item.scope,
          assistantId: item.scope == MemoryScope.assistant
              ? item.assistantId
              : null,
          type: item.type,
          content: item.content,
          source: source,
        );
        for (final rid in normalized.relatedIds) {
          await repository.linkBidirectional(created.id, rid);
        }
        traceStep?.addMutation(
          MemoryTraceMutation(
            kind: MemoryTraceMutationKind.memoryCreated,
            targetId: created.id,
            label: '$typeLabel · ${MemoryEntry.scopeToString(item.scope)}',
            after: created.content,
          ),
        );
        for (final rid in normalized.relatedIds) {
          traceStep?.addMutation(
            MemoryTraceMutation(
              kind: MemoryTraceMutationKind.memoryLinked,
              targetId: created.id,
              label: rid,
            ),
          );
        }
        return SmartAddResult(
          action: SmartAddAction.neu,
          id: created.id,
          content: created.content,
        );
      case SmartAddAction.merge:
        final before = traceStep == null
            ? null
            : await _contentBefore(normalized.targetId);
        final updated = await repository.updateContent(
          normalized.targetId!,
          normalized.mergedContent!.trim(),
        );
        traceStep?.addMutation(
          MemoryTraceMutation(
            kind: MemoryTraceMutationKind.memoryMerged,
            targetId: updated?.id ?? normalized.targetId,
            label: typeLabel,
            before: before,
            after: updated?.content ?? normalized.mergedContent,
          ),
        );
        return SmartAddResult(
          action: SmartAddAction.merge,
          id: updated?.id ?? normalized.targetId,
          content: updated?.content ?? normalized.mergedContent,
        );
      case SmartAddAction.conflict:
        final oldId = normalized.targetId!;
        final before = traceStep == null ? null : await _contentBefore(oldId);
        await repository.archive(oldId);
        final created = await repository.create(
          scope: item.scope,
          assistantId: item.scope == MemoryScope.assistant
              ? item.assistantId
              : null,
          type: item.type,
          content: item.content,
          source: source,
        );
        await repository.linkBidirectional(created.id, oldId);
        for (final rid in normalized.relatedIds) {
          if (rid == oldId) continue;
          await repository.linkBidirectional(created.id, rid);
        }
        traceStep?.addMutation(
          MemoryTraceMutation(
            kind: MemoryTraceMutationKind.memoryArchived,
            targetId: oldId,
            label: typeLabel,
            before: before,
          ),
        );
        traceStep?.addMutation(
          MemoryTraceMutation(
            kind: MemoryTraceMutationKind.memoryCreated,
            targetId: created.id,
            label: '$typeLabel · ${MemoryEntry.scopeToString(item.scope)}',
            after: created.content,
          ),
        );
        return SmartAddResult(
          action: SmartAddAction.conflict,
          id: created.id,
          content: created.content,
          reason: oldId,
        );
    }
  }

  /// 对单个项运行 Smart Add（`memory_update` / perItem 模式）。
  Future<SmartAddResult> addOne({
    required SmartAddItem item,
    required String visibilityAssistantId,
    required MemorySource source,
    required MemoryPromptLang lang,
    Future<String> Function(String prompt)? llmCall,
    String? overrideZh,
    String? overrideEn,
    MemoryTraceStep? traceStep,
  }) async {
    // 快速路径：完全重复 (§12.6)。
    final exact = await chatRepository.findExactMemory(
      assistantId: visibilityAssistantId,
      type: item.type,
      contentNormalized: MemoryEntry.normalizeContent(item.content),
    );
    if (exact != null) {
      return SmartAddResult(
        action: SmartAddAction.skip,
        id: exact.id,
        reason: 'duplicate',
      );
    }

    final candidates = await candidatesFor(
      assistantId: visibilityAssistantId,
      type: item.type,
      newInfo: item.content,
    );
    final candidateIds = {for (final e in candidates) e.id};
    final mergeableIds = {
      for (final entry in candidates)
        if (entry.scope == item.scope && entry.assistantId == item.assistantId)
          entry.id,
    };

    SmartAddDecision decision;
    if (llmCall == null) {
      decision = await degradeDecision(
        visibilityAssistantId: visibilityAssistantId,
        type: item.type,
        content: item.content,
      );
    } else {
      final prompt = buildPerItemPrompt(
        lang: lang,
        type: item.type,
        newInfo: item.content,
        entriesText: formatEntriesPerItem(candidates),
        overrideZh: overrideZh,
        overrideEn: overrideEn,
      );
      traceStep?.appendPrompt(prompt);
      try {
        final raw = await llmCall(prompt);
        traceStep?.appendResponse(raw);
        final parsed = parsePerItem(raw);
        decision =
            parsed ??
            await degradeDecision(
              visibilityAssistantId: visibilityAssistantId,
              type: item.type,
              content: item.content,
            );
      } catch (e) {
        traceStep?.appendResponse('<request failed> $e');
        decision = await degradeDecision(
          visibilityAssistantId: visibilityAssistantId,
          type: item.type,
          content: item.content,
        );
      }
    }

    return applyDecision(
      item: item,
      decision: decision,
      candidateIds: candidateIds,
      mergeableIds: mergeableIds,
      source: source,
      traceStep: traceStep,
    );
  }

  /// 对多项运行 Smart Add（批量或 perItem）。
  ///
  /// 返回结果顺序与 [items] 一致，并附带是否发生过任何身份级
  /// NEW/MERGE/CONFLICT（供 Distiller 使用）。
  Future<({List<SmartAddResult> results, bool identityChanged})> addMany({
    required List<SmartAddItem> items,
    required String visibilityAssistantId,
    required MemorySource source,
    required MemoryPromptLang lang,
    required MemorySmartAddMode mode,
    Future<String> Function(String prompt)? llmCall,
    String? perItemOverrideZh,
    String? perItemOverrideEn,
    String? batchOverrideZh,
    String? batchOverrideEn,
    MemoryTraceStep? traceStep,
  }) async {
    if (items.isEmpty) {
      return (results: <SmartAddResult>[], identityChanged: false);
    }

    if (mode == MemorySmartAddMode.perItem || llmCall == null) {
      final results = <SmartAddResult>[];
      var identityChanged = false;
      for (final item in items) {
        final r = await addOne(
          item: item,
          visibilityAssistantId: visibilityAssistantId,
          source: source,
          lang: lang,
          llmCall: llmCall,
          overrideZh: perItemOverrideZh,
          overrideEn: perItemOverrideEn,
          traceStep: traceStep,
        );
        results.add(r);
        if (item.type == MemoryType.identity &&
            (r.action == SmartAddAction.neu ||
                r.action == SmartAddAction.merge ||
                r.action == SmartAddAction.conflict)) {
          identityChanged = true;
        }
      }
      return (results: results, identityChanged: identityChanged);
    }

    // 批量路径
    final perItemCandidates = <List<MemoryEntry>>[];
    final union = <String, MemoryEntry>{};
    final decisions = <SmartAddDecision?>[];

    for (final item in items) {
      final exact = await chatRepository.findExactMemory(
        assistantId: visibilityAssistantId,
        type: item.type,
        contentNormalized: MemoryEntry.normalizeContent(item.content),
      );
      if (exact != null) {
        perItemCandidates.add(const []);
        decisions.add(
          SmartAddDecision(action: SmartAddAction.skip, targetId: exact.id),
        );
        continue;
      }
      final cands = await candidatesFor(
        assistantId: visibilityAssistantId,
        type: item.type,
        newInfo: item.content,
      );
      perItemCandidates.add(cands);
      for (final e in cands) {
        union[e.id] = e;
      }
      decisions.add(null); // 由 LLM 填充
    }

    final needLlm = decisions.any((d) => d == null);
    List<SmartAddDecision?>? batchParsed;
    if (needLlm) {
      final pendingItems = <SmartAddItem>[];
      final pendingIndexes = <int>[];
      for (var i = 0; i < items.length; i++) {
        if (decisions[i] != null) continue;
        pendingItems.add(items[i]);
        pendingIndexes.add(i);
      }
      // 仅以待处理项重新编为 1..N 供批量 prompt 会破坏
      // 约定（索引覆盖整个 {{itemsText}}）。把仍需决策的所有项
      // 连同其原始 1 基索引发送，组成仅含这些项的连续 itemsText——
      // 更简单的做法：把所有非完全重复的项作为 [1]..[k] 发送并反向映射。
      final prompt = buildBatchPrompt(
        lang: lang,
        itemsText: formatItemsText(pendingItems),
        entriesText: formatEntriesBatched(union.values.toList(growable: false)),
        overrideZh: batchOverrideZh,
        overrideEn: batchOverrideEn,
      );
      traceStep?.appendPrompt(prompt);
      try {
        final raw = await llmCall(prompt);
        traceStep?.appendResponse(raw);
        batchParsed = parseBatch(raw, pendingItems.length);
        if (batchParsed == null) {
          for (var j = 0; j < pendingIndexes.length; j++) {
            final idx = pendingIndexes[j];
            decisions[idx] = await degradeDecision(
              visibilityAssistantId: visibilityAssistantId,
              type: items[idx].type,
              content: items[idx].content,
            );
          }
        } else {
          for (var j = 0; j < pendingIndexes.length; j++) {
            final idx = pendingIndexes[j];
            final parsed = batchParsed[j];
            decisions[idx] =
                parsed ??
                await degradeDecision(
                  visibilityAssistantId: visibilityAssistantId,
                  type: items[idx].type,
                  content: items[idx].content,
                );
          }
        }
      } catch (e) {
        traceStep?.appendResponse('<request failed> $e');
        for (final idx in pendingIndexes) {
          decisions[idx] = await degradeDecision(
            visibilityAssistantId: visibilityAssistantId,
            type: items[idx].type,
            content: items[idx].content,
          );
        }
      }
    }

    final results = <SmartAddResult>[];
    var identityChanged = false;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final candidateIds = {for (final e in perItemCandidates[i]) e.id};
      final mergeableIds = {
        for (final entry in perItemCandidates[i])
          if (entry.scope == item.scope &&
              entry.assistantId == item.assistantId)
            entry.id,
      };
      // 批量模式下也允许来自并集的 relatedIds / targetId
      // （entriesText 即并集）。§12.6：relatedIds 不在该项的*候选集*内
      // ——使用该项的逐项候选。
      final decision =
          decisions[i] ??
          await degradeDecision(
            visibilityAssistantId: visibilityAssistantId,
            type: item.type,
            content: item.content,
          );
      final result = await applyDecision(
        item: item,
        decision: decision,
        candidateIds: candidateIds,
        mergeableIds: mergeableIds,
        source: source,
        traceStep: traceStep,
      );
      results.add(result);
      if (item.type == MemoryType.identity &&
          (result.action == SmartAddAction.neu ||
              result.action == SmartAddAction.merge ||
              result.action == SmartAddAction.conflict)) {
        identityChanged = true;
      }
    }
    return (results: results, identityChanged: identityChanged);
  }

  /// 在 [policy] 下为 Extract 项解析写入作用域。
  static MemoryScope resolveScopeForExtracted({
    required MemoryWriteScope policy,
    required String? scopeAttr,
  }) {
    return MemoryTools.resolveWriteScope(policy, scopeAttr);
  }
}
