import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/memory_entry.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/memory/legacy_memory_migration.dart';
import 'package:Kelivo/core/services/memory/memory_repository.dart';

import '../../../support/business_test_harness.dart';

ProviderConfig _config() => ProviderConfig(
  id: 'test',
  enabled: true,
  name: 'Test',
  apiKey: 'test-key',
  baseUrl: 'https://example.com',
);

void main() {
  group('LegacyMemoryMigrationService', () {
    test('buildPrompt preserves source text as JSON input', () {
      final prompt = LegacyMemoryMigrationService.buildPrompt(
        batch: const [
          LegacyMemoryMigrationInput(
            legacyId: 1,
            assistantId: 'assistant-1',
            content: '用户喜欢“简洁”的回答。',
          ),
        ],
        ids: const [7],
      );

      expect(prompt, contains('original wording'));
      expect(prompt, contains('用户喜欢'));
      expect(prompt, contains('"id":7'));
    });

    test('parseResponse accepts fenced JSON and restores input order', () {
      final outputs = LegacyMemoryMigrationService.parseResponse(
        '''```json
[
  {"id": 2, "type": "voice", "content": "The user prefers concise replies."},
  {"id": 1, "type": "identity", "content": "The user lives in Tokyo."}
]
```''',
        expectedIds: const [1, 2],
      );

      expect(outputs.map((item) => item.id), [1, 2]);
      expect(outputs.first.type, MemoryType.identity);
      expect(outputs.last.type, MemoryType.voice);
    });

    test('parseResponse allows type-only output when preserving original', () {
      final outputs = LegacyMemoryMigrationService.parseResponse(
        '[{"id":1,"type":"instruction"}]',
        expectedIds: const [1],
        expectContent: false,
      );

      expect(outputs.single.type, MemoryType.instruction);
      expect(outputs.single.content, isEmpty);
    });

    test('migration preserves original wording by default', () async {
      final harness = await createBusinessTestHarness();
      addTearDown(harness.close);
      final repository = MemoryRepository(harness.preferences);
      final service = LegacyMemoryMigrationService(
        repository: repository,
        generateText:
            ({
              required ProviderConfig config,
              required String modelId,
              required String prompt,
              int? thinkingBudget,
            }) async => '[{"id":1,"type":"identity"}]',
      );

      await service.migrate(
        inputs: const [
          LegacyMemoryMigrationInput(
            legacyId: 1,
            assistantId: 'assistant-1',
            content: '  保留原来的空格和措辞。  ',
          ),
        ],
        target: LegacyMemoryMigrationTarget.global,
        config: _config(),
        modelId: 'test-model',
      );

      expect((await repository.readAll()).single.content, '  保留原来的空格和措辞。  ');
    });

    test('migration can use model-organized wording', () async {
      final harness = await createBusinessTestHarness();
      addTearDown(harness.close);
      final repository = MemoryRepository(harness.preferences);
      final service = LegacyMemoryMigrationService(
        repository: repository,
        generateText:
            ({
              required ProviderConfig config,
              required String modelId,
              required String prompt,
              int? thinkingBudget,
            }) async => '[{"id":1,"type":"workflow","content":"整理后的措辞"}]',
      );

      await service.migrate(
        inputs: const [
          LegacyMemoryMigrationInput(
            legacyId: 1,
            assistantId: 'assistant-1',
            content: '旧措辞',
          ),
        ],
        target: LegacyMemoryMigrationTarget.global,
        config: _config(),
        modelId: 'test-model',
        preserveOriginal: false,
      );

      expect((await repository.readAll()).single.content, '整理后的措辞');
    });

    test('parseResponse rejects missing source items', () {
      expect(
        () => LegacyMemoryMigrationService.parseResponse(
          '[{"id":1,"type":"identity","content":"One"}]',
          expectedIds: const [1, 2],
        ),
        throwsFormatException,
      );
    });

    test('parseResponse treats unknown migrate type as invalid item', () {
      expect(
        () => LegacyMemoryMigrationService.parseResponse(
          '[{"id":1,"type":"mystery","content":"One"}]',
          expectedIds: const [1],
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'legacy_memory_response_item_invalid',
          ),
        ),
      );
    });

    test(
      'migration id ignores legacy renumbering but tracks stable fields',
      () {
        const original = LegacyMemoryMigrationInput(
          legacyId: 7,
          assistantId: 'assistant-1',
          content: 'Original',
        );
        const edited = LegacyMemoryMigrationInput(
          legacyId: 7,
          assistantId: 'assistant-1',
          content: 'Edited',
        );
        const renumbered = LegacyMemoryMigrationInput(
          legacyId: 99,
          assistantId: 'assistant-1',
          content: 'Original',
        );
        const padded = LegacyMemoryMigrationInput(
          legacyId: 100,
          assistantId: '  assistant-1\n',
          content: '\tOriginal  ',
        );

        final global = LegacyMemoryMigrationService.migrationIdFor(
          input: original,
          target: LegacyMemoryMigrationTarget.global,
        );
        expect(
          LegacyMemoryMigrationService.migrationIdFor(
            input: original,
            target: LegacyMemoryMigrationTarget.global,
          ),
          global,
        );
        expect(
          LegacyMemoryMigrationService.migrationIdFor(
            input: renumbered,
            target: LegacyMemoryMigrationTarget.global,
          ),
          global,
        );
        expect(
          LegacyMemoryMigrationService.migrationIdFor(
            input: padded,
            target: LegacyMemoryMigrationTarget.global,
          ),
          global,
        );
        expect(
          LegacyMemoryMigrationService.migrationIdFor(
            input: edited,
            target: LegacyMemoryMigrationTarget.global,
          ),
          isNot(global),
        );
        final assistant = LegacyMemoryMigrationService.migrationIdFor(
          input: original,
          target: LegacyMemoryMigrationTarget.assistant,
        );
        expect(assistant, isNot(global));
        expect(
          LegacyMemoryMigrationService.migrationIdFor(
            input: padded,
            target: LegacyMemoryMigrationTarget.assistant,
          ),
          assistant,
        );
      },
    );

    test(
      'repeat migration skips model conversion using persisted receipt',
      () async {
        final harness = await createBusinessTestHarness();
        final repository = MemoryRepository(harness.preferences);
        var generatorCalls = 0;
        final service = LegacyMemoryMigrationService(
          repository: repository,
          generateText:
              ({
                required ProviderConfig config,
                required String modelId,
                required String prompt,
                int? thinkingBudget,
              }) async {
                generatorCalls++;
                return '[{"id":1,"type":"identity","content":"Converted"}]';
              },
        );
        const inputs = <LegacyMemoryMigrationInput>[
          LegacyMemoryMigrationInput(
            legacyId: 42,
            assistantId: 'assistant-1',
            content: 'Legacy source',
          ),
        ];

        final first = await service.migrate(
          inputs: inputs,
          target: LegacyMemoryMigrationTarget.global,
          config: _config(),
          modelId: 'test-model',
          preserveOriginal: false,
        );
        final second = await service.migrate(
          inputs: inputs,
          target: LegacyMemoryMigrationTarget.global,
          config: _config(),
          modelId: 'test-model',
          preserveOriginal: false,
        );

        expect(first.created, 1);
        expect(first.skipped, 0);
        expect(second.created, 0);
        expect(second.skipped, 1);
        expect(generatorCalls, 1);
        final entry = (await repository.readAll()).single;
        expect(
          entry.migrationIds,
          contains(
            LegacyMemoryMigrationService.migrationIdFor(
              input: inputs.single,
              target: LegacyMemoryMigrationTarget.global,
            ),
          ),
        );
      },
    );

    test(
      'content duplicate records receipt and skips model next time',
      () async {
        final harness = await createBusinessTestHarness();
        final repository = MemoryRepository(harness.preferences);
        await repository.create(
          scope: MemoryScope.global,
          type: MemoryType.identity,
          content: 'Already saved',
          source: MemorySource.manual,
        );
        var generatorCalls = 0;
        final service = LegacyMemoryMigrationService(
          repository: repository,
          generateText:
              ({
                required ProviderConfig config,
                required String modelId,
                required String prompt,
                int? thinkingBudget,
              }) async {
                generatorCalls++;
                return '[{"id":1,"type":"identity","content":"Already saved"}]';
              },
        );
        const inputs = <LegacyMemoryMigrationInput>[
          LegacyMemoryMigrationInput(
            legacyId: 9,
            assistantId: 'assistant-1',
            content: 'Old wording',
          ),
        ];

        final first = await service.migrate(
          inputs: inputs,
          target: LegacyMemoryMigrationTarget.global,
          config: _config(),
          modelId: 'test-model',
          preserveOriginal: false,
        );
        final second = await service.migrate(
          inputs: inputs,
          target: LegacyMemoryMigrationTarget.global,
          config: _config(),
          modelId: 'test-model',
          preserveOriginal: false,
        );

        expect(first.created, 0);
        expect(first.skipped, 1);
        expect(second.skipped, 1);
        expect(generatorCalls, 1);
        final entries = await repository.readAll();
        expect(entries, hasLength(1));
        expect(entries.single.source, MemorySource.manual);
        expect(entries.single.migrationIds, hasLength(1));
      },
    );

    test('persists completed batches and retries only unfinished items', () async {
      final harness = await createBusinessTestHarness();
      final repository = MemoryRepository(harness.preferences);
      var failSecond = true;
      var firstCalls = 0;
      var secondCalls = 0;
      final service = LegacyMemoryMigrationService(
        repository: repository,
        batchSize: 1,
        delay: (_) async {},
        generateText:
            ({
              required ProviderConfig config,
              required String modelId,
              required String prompt,
              int? thinkingBudget,
            }) async {
              if (prompt.contains('First legacy memory')) {
                firstCalls++;
                return '[{"id":1,"type":"identity","content":"First converted"}]';
              }
              secondCalls++;
              if (failSecond) {
                throw Exception('ClientException: connection refused');
              }
              return '[{"id":2,"type":"workflow","content":"Second converted"}]';
            },
      );
      const inputs = <LegacyMemoryMigrationInput>[
        LegacyMemoryMigrationInput(
          legacyId: 1,
          assistantId: 'assistant-1',
          content: 'First legacy memory',
        ),
        LegacyMemoryMigrationInput(
          legacyId: 2,
          assistantId: 'assistant-1',
          content: 'Second legacy memory',
        ),
      ];

      final partial = await service.migrate(
        inputs: inputs,
        target: LegacyMemoryMigrationTarget.global,
        config: _config(),
        modelId: 'test-model',
      );
      expect(partial.created, 1);
      expect(partial.failed, 1);
      expect(await repository.readAll(), hasLength(1));

      failSecond = false;
      final resumed = await service.migrate(
        inputs: inputs,
        target: LegacyMemoryMigrationTarget.global,
        config: _config(),
        modelId: 'test-model',
      );
      expect(resumed.created, 1);
      expect(resumed.skipped, 1);
      expect(resumed.failed, 0);
      expect(firstCalls, 1);
      expect(secondCalls, 4);
      expect(await repository.readAll(), hasLength(2));
    });

    test('incomplete model batch splits and preserves every item', () async {
      final harness = await createBusinessTestHarness();
      final repository = MemoryRepository(harness.preferences);
      var calls = 0;
      final service = LegacyMemoryMigrationService(
        repository: repository,
        batchSize: 2,
        delay: (_) async {},
        generateText:
            ({
              required ProviderConfig config,
              required String modelId,
              required String prompt,
              int? thinkingBudget,
            }) async {
              calls++;
              final hasFirst = prompt.contains('First split memory');
              final hasSecond = prompt.contains('Second split memory');
              if (hasFirst && hasSecond) {
                return '[{"id":1,"type":"identity","content":"First"}]';
              }
              if (hasFirst) {
                return '[{"id":1,"type":"identity","content":"First"}]';
              }
              return '[{"id":2,"type":"workflow","content":"Second"}]';
            },
      );

      final result = await service.migrate(
        inputs: const [
          LegacyMemoryMigrationInput(
            legacyId: 1,
            assistantId: 'assistant-1',
            content: 'First split memory',
          ),
          LegacyMemoryMigrationInput(
            legacyId: 2,
            assistantId: 'assistant-1',
            content: 'Second split memory',
          ),
        ],
        target: LegacyMemoryMigrationTarget.global,
        config: _config(),
        modelId: 'test-model',
      );

      expect(result.created, 2);
      expect(result.failed, 0);
      expect(calls, 4);
      expect(await repository.readAll(), hasLength(2));
    });

    test(
      'authentication failure does not split or start later batches',
      () async {
        final harness = await createBusinessTestHarness();
        final repository = MemoryRepository(harness.preferences);
        var calls = 0;
        final service = LegacyMemoryMigrationService(
          repository: repository,
          batchSize: 2,
          delay: (_) async {},
          generateText:
              ({
                required ProviderConfig config,
                required String modelId,
                required String prompt,
                int? thinkingBudget,
              }) async {
                calls++;
                throw Exception('HTTP 401: invalid api key');
              },
        );

        final result = await service.migrate(
          inputs: [
            for (var i = 1; i <= 4; i++)
              LegacyMemoryMigrationInput(
                legacyId: i,
                assistantId: 'assistant-1',
                content: 'Authentication memory $i',
              ),
          ],
          target: LegacyMemoryMigrationTarget.global,
          config: _config(),
          modelId: 'test-model',
        );

        expect(result.created, 0);
        expect(result.failed, 4);
        expect(result.errorMessage, contains('401'));
        expect(calls, 3);
        expect(await repository.readAll(), isEmpty);
      },
    );
  });
}
