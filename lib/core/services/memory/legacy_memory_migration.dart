import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../models/memory_entry.dart';
import '../../providers/settings_provider.dart';
import '../api/chat_api_service.dart';
import 'memory_prompts.dart';
import 'memory_repository.dart';
import 'memory_smart_add.dart';

enum LegacyMemoryMigrationTarget { global, assistant }

enum LegacyMemoryMigrationPhase { analyzing, writing }

class LegacyMemoryMigrationInput {
  const LegacyMemoryMigrationInput({
    required this.legacyId,
    required this.assistantId,
    required this.content,
  });

  final int legacyId;
  final String assistantId;
  final String content;
}

class LegacyMemoryMigrationProgress {
  const LegacyMemoryMigrationProgress({
    required this.phase,
    required this.processed,
    required this.total,
  });

  final LegacyMemoryMigrationPhase phase;
  final int processed;
  final int total;

  double get fraction {
    if (total == 0) return 1;
    final phaseOffset = phase == LegacyMemoryMigrationPhase.writing ? total : 0;
    return ((phaseOffset + processed) / (total * 2)).clamp(0, 1).toDouble();
  }
}

class LegacyMemoryMigrationResult {
  const LegacyMemoryMigrationResult({
    required this.created,
    required this.skipped,
    this.failed = 0,
    this.errorMessage,
  });

  final int created;
  final int skipped;
  final int failed;
  final String? errorMessage;
}

typedef LegacyMemoryTextGenerator =
    Future<String> Function({
      required ProviderConfig config,
      required String modelId,
      required String prompt,
      int? thinkingBudget,
    });

class LegacyMemoryMigrationService {
  LegacyMemoryMigrationService({
    required this.repository,
    LegacyMemoryTextGenerator? generateText,
    int batchSize = LegacyMemoryMigrationService.batchSize,
    Future<void> Function(Duration duration)? delay,
    this.generateCallLimit,
  }) : _batchSize = batchSize.clamp(1, 24),
       _generateText = generateText ?? ChatApiService.generateText,
       _delay = delay ?? ((duration) => Future<void>.delayed(duration));

  static const int batchSize = 12;
  static const int _maxAttempts = 3;

  final MemoryRepository repository;
  final LegacyMemoryTextGenerator _generateText;
  final int _batchSize;
  final int? generateCallLimit;
  final Future<void> Function(Duration duration) _delay;
  final Random _random = Random();

  Future<LegacyMemoryMigrationResult> migrate({
    required List<LegacyMemoryMigrationInput> inputs,
    required LegacyMemoryMigrationTarget target,
    required ProviderConfig config,
    required String modelId,
    void Function(LegacyMemoryMigrationProgress progress)? onProgress,
    bool preserveOriginal = true,
    String? promptTemplate,
  }) async {
    if (inputs.isEmpty) {
      return const LegacyMemoryMigrationResult(created: 0, skipped: 0);
    }

    final existing = await repository.readAll();
    final knownMigrationIds = <String>{
      for (final entry in existing) ...entry.migrationIds,
    };
    final pending = <_PendingLegacyMemory>[];
    var skipped = 0;
    for (var i = 0; i < inputs.length; i++) {
      final input = inputs[i];
      final scope = target == LegacyMemoryMigrationTarget.global
          ? MemoryScope.global
          : MemoryScope.assistant;
      final assistantId = scope == MemoryScope.assistant
          ? input.assistantId
          : null;
      if (scope == MemoryScope.assistant &&
          (assistantId == null || assistantId.trim().isEmpty)) {
        throw const FormatException('legacy_memory_assistant_missing');
      }
      final migrationId = migrationIdFor(input: input, target: target);
      if (knownMigrationIds.contains(migrationId)) {
        skipped++;
        continue;
      }
      pending.add(
        _PendingLegacyMemory(
          promptId: i + 1,
          input: input,
          scope: scope,
          assistantId: assistantId,
          migrationId: migrationId,
        ),
      );
    }

    var created = 0;
    var failed = 0;
    String? errorMessage;
    var processed = skipped;
    final template =
        promptTemplate ??
        (preserveOriginal
            ? MemoryPrompts.migratePreserveEn
            : MemoryPrompts.migrateEn);

    void report(LegacyMemoryMigrationPhase phase) {
      onProgress?.call(
        LegacyMemoryMigrationProgress(
          phase: phase,
          processed: processed,
          total: inputs.length,
        ),
      );
    }

    report(LegacyMemoryMigrationPhase.analyzing);
    if (pending.isEmpty) {
      return LegacyMemoryMigrationResult(created: 0, skipped: skipped);
    }

    final run = _MigrationRun(
      generateCallLimit: generateCallLimit ?? pending.length * 3,
    );
    for (var start = 0; start < pending.length; start += _batchSize) {
      if (run.stopped) {
        failed += pending.length - start;
        errorMessage ??= run.stopReason;
        processed = inputs.length;
        report(LegacyMemoryMigrationPhase.writing);
        break;
      }
      final end = start + _batchSize < pending.length
          ? start + _batchSize
          : pending.length;
      final batch = pending.sublist(start, end);
      final outcome = await _convertBatchWithRetry(
        batch,
        run: run,
        config: config,
        modelId: modelId,
        preserveOriginal: preserveOriginal,
        promptTemplate: template,
      );
      created += outcome.created;
      skipped += outcome.skipped;
      failed += outcome.failed;
      errorMessage = outcome.errorMessage ?? errorMessage;
      processed += batch.length;
      report(LegacyMemoryMigrationPhase.writing);
    }

    return LegacyMemoryMigrationResult(
      created: created,
      skipped: skipped,
      failed: failed,
      errorMessage: errorMessage,
    );
  }

  Future<_BatchWriteOutcome> _convertBatchWithRetry(
    List<_PendingLegacyMemory> batch, {
    required _MigrationRun run,
    required ProviderConfig config,
    required String modelId,
    required bool preserveOriginal,
    required String promptTemplate,
  }) async {
    if (batch.isEmpty) {
      return const _BatchWriteOutcome(created: 0, skipped: 0, failed: 0);
    }
    if (run.stopped || !run.hasBudget) {
      run.stopped = true;
      run.stopReason ??= 'legacy_memory_request_budget_exceeded';
      return _BatchWriteOutcome(
        created: 0,
        skipped: 0,
        failed: batch.length,
        errorMessage: run.stopReason,
      );
    }

    Object? lastError;
    var lastKind = _MigrationFailureKind.stopAfterRetry;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        return await _convertAndWriteBatch(
          batch,
          run: run,
          config: config,
          modelId: modelId,
          preserveOriginal: preserveOriginal,
          promptTemplate: promptTemplate,
        );
      } catch (error) {
        lastError = error;
        lastKind = _classifyMigrationFailure(error);
        if (lastKind == _MigrationFailureKind.stopNow) {
          run.stopped = true;
          run.stopReason = error.toString();
          return _BatchWriteOutcome(
            created: 0,
            skipped: 0,
            failed: batch.length,
            errorMessage: run.stopReason,
          );
        }
        if (lastKind == _MigrationFailureKind.split &&
            attempt >= 2 &&
            batch.length > 1) {
          return _splitAndRetry(
            batch,
            run: run,
            config: config,
            modelId: modelId,
            preserveOriginal: preserveOriginal,
            promptTemplate: promptTemplate,
          );
        }
        if (attempt < _maxAttempts) {
          await _delay(_backoffAfter(attempt));
        }
      }
    }

    if (lastKind == _MigrationFailureKind.split && batch.length > 1) {
      return _splitAndRetry(
        batch,
        run: run,
        config: config,
        modelId: modelId,
        preserveOriginal: preserveOriginal,
        promptTemplate: promptTemplate,
      );
    }
    if (lastKind == _MigrationFailureKind.stopAfterRetry) {
      run.stopped = true;
      run.stopReason = lastError?.toString();
    }
    return _BatchWriteOutcome(
      created: 0,
      skipped: 0,
      failed: batch.length,
      errorMessage: lastError?.toString(),
    );
  }

  Future<_BatchWriteOutcome> _splitAndRetry(
    List<_PendingLegacyMemory> batch, {
    required _MigrationRun run,
    required ProviderConfig config,
    required String modelId,
    required bool preserveOriginal,
    required String promptTemplate,
  }) async {
    final middle = batch.length ~/ 2;
    final left = await _convertBatchWithRetry(
      batch.sublist(0, middle),
      run: run,
      config: config,
      modelId: modelId,
      preserveOriginal: preserveOriginal,
      promptTemplate: promptTemplate,
    );
    final right = await _convertBatchWithRetry(
      batch.sublist(middle),
      run: run,
      config: config,
      modelId: modelId,
      preserveOriginal: preserveOriginal,
      promptTemplate: promptTemplate,
    );
    return _BatchWriteOutcome(
      created: left.created + right.created,
      skipped: left.skipped + right.skipped,
      failed: left.failed + right.failed,
      errorMessage: right.errorMessage ?? left.errorMessage,
    );
  }

  Future<_BatchWriteOutcome> _convertAndWriteBatch(
    List<_PendingLegacyMemory> batch, {
    required _MigrationRun run,
    required ProviderConfig config,
    required String modelId,
    required bool preserveOriginal,
    required String promptTemplate,
  }) async {
    if (!run.hasBudget) {
      throw const _LegacyMemoryMigrationStop(
        'legacy_memory_request_budget_exceeded',
      );
    }
    run.generateCalls++;
    final ids = <int>[for (final item in batch) item.promptId];
    final response = await _generateText(
      config: config,
      modelId: modelId,
      prompt: buildPrompt(
        batch: [for (final item in batch) item.input],
        ids: ids,
        template: promptTemplate,
      ),
      thinkingBudget: 0,
    );
    final converted = parseResponse(
      response,
      expectedIds: ids,
      expectContent: !preserveOriginal,
    );
    final write = await repository.createMany(<MemoryCreateDraft>[
      for (var i = 0; i < batch.length; i++)
        MemoryCreateDraft(
          scope: batch[i].scope,
          assistantId: batch[i].assistantId,
          type: converted[i].type,
          content: preserveOriginal
              ? batch[i].input.content
              : converted[i].content,
          source: MemorySource.extracted,
          migrationId: batch[i].migrationId,
        ),
    ]);
    return _BatchWriteOutcome(
      created: write.created,
      skipped: write.skipped,
      failed: 0,
    );
  }

  Duration _backoffAfter(int failedAttempt) {
    final baseMilliseconds = switch (failedAttempt) {
      1 => 1000,
      2 => 2000,
      _ => 4000,
    };
    return Duration(milliseconds: baseMilliseconds + _random.nextInt(201));
  }

  static String buildPrompt({
    required List<LegacyMemoryMigrationInput> batch,
    required List<int> ids,
    String? template,
    bool preserveOriginal = true,
  }) {
    if (batch.length != ids.length) {
      throw ArgumentError('batch and ids must have the same length');
    }
    final items = <Map<String, Object>>[
      for (var i = 0; i < batch.length; i++)
        <String, Object>{'id': ids[i], 'content': batch[i].content},
    ];
    final resolved =
        template ??
        (preserveOriginal
            ? MemoryPrompts.migratePreserveEn
            : MemoryPrompts.migrateEn);
    return resolved.replaceFirst('{{items}}', jsonEncode(items));
  }

  static String migrationIdFor({
    required LegacyMemoryMigrationInput input,
    required LegacyMemoryMigrationTarget target,
  }) {
    final assistantId = input.assistantId.trim();
    final content = input.content.trim();
    final scope = target == LegacyMemoryMigrationTarget.global
        ? MemoryScope.global
        : MemoryScope.assistant;
    final targetAssistantId = scope == MemoryScope.assistant
        ? assistantId
        : null;
    final contentHash = sha256.convert(utf8.encode(content)).toString();
    final identity = jsonEncode(<Object?>[
      assistantId,
      contentHash,
      MemoryEntry.scopeToString(scope),
      targetAssistantId,
    ]);
    return 'legacy_memory_v1:${sha256.convert(utf8.encode(identity))}';
  }

  static List<LegacyMemoryMigrationOutput> parseResponse(
    String response, {
    required List<int> expectedIds,
    bool expectContent = true,
  }) {
    final decoded = MemorySmartAdd.extractJson(response);
    if (decoded is! List) {
      throw const FormatException('legacy_memory_response_not_array');
    }

    final byId = <int, LegacyMemoryMigrationOutput>{};
    for (final raw in decoded) {
      if (raw is! Map) {
        throw const FormatException('legacy_memory_response_item_invalid');
      }
      final id = switch (raw['id']) {
        final int value => value,
        final num value => value.toInt(),
        final String value => int.tryParse(value),
        _ => null,
      };
      final typeValue = raw['type']?.toString().trim().toLowerCase();
      final content = raw['content']?.toString().trim() ?? '';
      if (id == null ||
          typeValue == null ||
          typeValue.isEmpty ||
          (expectContent && content.isEmpty)) {
        throw const FormatException('legacy_memory_response_item_invalid');
      }
      final MemoryType type;
      try {
        type = MemoryEntry.typeFromString(typeValue);
      } on FormatException {
        throw const FormatException('legacy_memory_response_item_invalid');
      }
      if (byId.containsKey(id)) {
        throw const FormatException('legacy_memory_response_duplicate_id');
      }
      byId[id] = LegacyMemoryMigrationOutput(
        id: id,
        type: type,
        content: content,
      );
    }

    if (byId.length != expectedIds.length ||
        expectedIds.any((id) => !byId.containsKey(id))) {
      throw const FormatException('legacy_memory_response_incomplete');
    }
    return <LegacyMemoryMigrationOutput>[
      for (final id in expectedIds) byId[id]!,
    ];
  }

  static _MigrationFailureKind _classifyMigrationFailure(Object error) {
    if (error is _LegacyMemoryMigrationStop) {
      return _MigrationFailureKind.stopNow;
    }
    if (_isSplittableMigrationError(error)) {
      return _MigrationFailureKind.split;
    }
    return _MigrationFailureKind.stopAfterRetry;
  }

  static bool _isSplittableMigrationError(Object error) {
    if (error is FormatException) {
      final message = error.message.toLowerCase();
      if (message.contains('legacy_memory_response')) return true;
    }
    final message = error.toString().toLowerCase();
    return message.contains('legacy_memory_response') ||
        message.contains('payload too large') ||
        message.contains('context_length') ||
        message.contains('context length') ||
        message.contains('too many tokens') ||
        message.contains('maximum context') ||
        message.contains('max context') ||
        message.contains('http 413') ||
        message.contains('status code 413') ||
        message.contains('status: 413');
  }
}

enum _MigrationFailureKind { split, stopAfterRetry, stopNow }

class _LegacyMemoryMigrationStop implements Exception {
  const _LegacyMemoryMigrationStop(this.message);

  final String message;

  @override
  String toString() => message;
}

class _MigrationRun {
  _MigrationRun({required this.generateCallLimit});

  final int generateCallLimit;
  int generateCalls = 0;
  bool stopped = false;
  String? stopReason;

  bool get hasBudget => !stopped && generateCalls < generateCallLimit;
}

class _PendingLegacyMemory {
  const _PendingLegacyMemory({
    required this.promptId,
    required this.input,
    required this.scope,
    required this.assistantId,
    required this.migrationId,
  });

  final int promptId;
  final LegacyMemoryMigrationInput input;
  final MemoryScope scope;
  final String? assistantId;
  final String migrationId;
}

class _BatchWriteOutcome {
  const _BatchWriteOutcome({
    required this.created,
    required this.skipped,
    required this.failed,
    this.errorMessage,
  });

  final int created;
  final int skipped;
  final int failed;
  final String? errorMessage;
}

class LegacyMemoryMigrationOutput {
  const LegacyMemoryMigrationOutput({
    required this.id,
    required this.type,
    required this.content,
  });

  final int id;
  final MemoryType type;
  final String content;
}
