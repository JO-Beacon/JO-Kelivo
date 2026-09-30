import "support/business_test_harness.dart";
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/model_provider.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/model_spec.dart';
import 'package:Kelivo/core/models/reasoning_request.dart';
import 'package:Kelivo/core/services/model_spec/model_defaults_guesser.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider reasoning support', () {
    test('default Claude and OpenRouter presets do not add latest models', () {
      final claude = ProviderConfig.defaultsFor('Claude');
      final openRouter = ProviderConfig.defaultsFor('OpenRouter');

      expect(claude.models, isEmpty);
      expect(claude.modelOverrides, isEmpty);
      expect(openRouter.models, isEmpty);
      expect(openRouter.modelOverrides, isEmpty);
    });

    test('default Zhipu preset stays user-configured only', () {
      final zhipu = ProviderConfig.defaultsFor('Zhipu AI');

      expect(zhipu.baseUrl, 'https://open.bigmodel.cn/api/paas/v4');
      expect(zhipu.models, isEmpty);
      expect(zhipu.modelOverrides, isEmpty);
    });

    test('default Moonshot preset stays user-configured only', () {
      final moonshot = ProviderConfig.defaultsFor('Moonshot');

      expect(moonshot.baseUrl, 'https://api.moonshot.cn/v1');
      expect(moonshot.models, isEmpty);
      expect(moonshot.modelOverrides, isEmpty);
    });

    test('built-in provider order does not add Kimi preset', () async {
      final harness = await createBusinessTestHarness(
        initial: {
          'providers_order_v1': <String>['OpenAI', 'Zhipu AI', 'Grok'],
          'provider_configs_v1': jsonEncode({
            for (final id in const ['OpenAI', 'Zhipu AI', 'Grok'])
              id: ProviderConfig.defaultsFor(id).toJson(),
          }),
        },
      );
      final settings = SettingsProvider(harness.preferences);

      await settings.loaded;

      expect(settings.providersOrder, isNot(contains('Kimi')));
      expect(settings.providersOrder.take(3), ['OpenAI', 'Zhipu AI', 'Grok']);
    });

    test('latest model ids infer only their documented capabilities', () {
      final glm = ModelDefaultsGuesser.guess('glm-5.2');
      final kimiK2 = ModelDefaultsGuesser.guess('kimi-k2.7-code');
      final kimiK3 = ModelDefaultsGuesser.guess('kimi-k3');
      final muse = ModelDefaultsGuesser.guess('muse-spark-1.1');

      expect(glm.input, const [Modality.text]);
      expect(glm.output, const [Modality.text]);
      expect(
        glm.abilities,
        containsAll([ModelAbility.tool, ModelAbility.reasoning]),
      );
      for (final model in [kimiK2, kimiK3, muse]) {
        expect(model.input, contains(Modality.image));
        expect(model.output, const [Modality.text]);
        expect(
          model.abilities,
          containsAll([ModelAbility.tool, ModelAbility.reasoning]),
        );
      }
    });

    test('OpenRouter can be routed through Anthropic format explicitly', () {
      final cfg = ProviderConfig(
        id: 'OpenRouterAnthropic',
        enabled: true,
        name: 'OpenRouter Anthropic',
        apiKey: 'test-key',
        baseUrl: 'https://openrouter.ai/api',
        providerType: ProviderKind.claude,
        models: const ['anthropic/claude-fable-5'],
      );

      expect(
        ProviderConfig.classify(cfg.id, explicitType: cfg.providerType),
        ProviderKind.claude,
      );
    });

    group('title generation thinking', () {
      final reasoning1024 = ReasoningRequest(
        ReasoningLevel.low,
        budgetTokens: 1024,
      );
      Assistant assistantWith(ReasoningRequest r) =>
          Assistant(id: 'a', name: 'a', reasoning: r);

      test('defaults to disabled', () async {
        final harness = await createBusinessTestHarness(
          initial: {'thinking_budget_v1': 16000},
        );
        final settings = SettingsProvider(harness.preferences);

        await settings.loaded;

        expect(settings.titleGenerationThinkingEnabled, isFalse);
        expect(
          settings.titleGenerationReasoningFor(null),
          ReasoningRequest.off,
        );
        expect(
          settings.titleGenerationReasoningFor(assistantWith(reasoning1024)),
          ReasoningRequest.off,
        );
      });

      test(
        'disabled title generation thinking resolves to off budget',
        () async {
          final harness = await createBusinessTestHarness(initial: {});
          final settings = SettingsProvider(harness.preferences);

          await settings.loaded;
          await settings.setTitleGenerationThinkingEnabled(true);
          await settings.setTitleGenerationThinkingEnabled(false);

          expect(settings.titleGenerationThinkingEnabled, isFalse);
          expect(
            settings.titleGenerationReasoningFor(null),
            ReasoningRequest.off,
          );
          expect(
            settings.titleGenerationReasoningFor(assistantWith(reasoning1024)),
            ReasoningRequest.off,
          );

          final prefs = harness.preferences;
          expect(
            prefs.getBool('title_generation_thinking_enabled_v1'),
            isFalse,
          );
        },
      );

      test('loads persisted disabled state', () async {
        final harness = await createBusinessTestHarness(
          initial: {'title_generation_thinking_enabled_v1': false},
        );
        final settings = SettingsProvider(harness.preferences);

        await settings.loaded;

        expect(settings.titleGenerationThinkingEnabled, isFalse);
        expect(
          settings.titleGenerationReasoningFor(assistantWith(reasoning1024)),
          ReasoningRequest.off,
        );
      });

      test('reset restores disabled default', () async {
        final harness = await createBusinessTestHarness(
          initial: {
            'title_generation_thinking_enabled_v1': true,
            'thinking_budget_v1': 64000,
          },
        );
        final settings = SettingsProvider(harness.preferences);

        await settings.loaded;
        await settings.resetTitleGenerationThinkingEnabled();

        expect(settings.titleGenerationThinkingEnabled, isFalse);
        expect(
          settings.titleGenerationReasoningFor(null),
          ReasoningRequest.off,
        );

        final prefs = harness.preferences;
        expect(prefs.getBool('title_generation_thinking_enabled_v1'), isFalse);
      });

      test(
        'all utility model thinking toggles default off and persist',
        () async {
          final harness = await createBusinessTestHarness(
            initial: {'thinking_budget_v1': 16000},
          );
          final settings = SettingsProvider(harness.preferences);

          await settings.loaded;

          expect(
            settings.summaryGenerationReasoningFor(
              assistantWith(reasoning1024),
            ),
            ReasoningRequest.off,
          );
          expect(
            settings.suggestionGenerationReasoningFor(
              assistantWith(reasoning1024),
            ),
            ReasoningRequest.off,
          );
          expect(
            settings.compressGenerationReasoningFor(
              assistantWith(reasoning1024),
            ),
            ReasoningRequest.off,
          );
          expect(
            settings.translateGenerationReasoningFor(
              assistantWith(reasoning1024),
            ),
            ReasoningRequest.off,
          );
          expect(
            settings.ocrGenerationReasoningFor(assistantWith(reasoning1024)),
            ReasoningRequest.off,
          );

          await settings.setSummaryGenerationThinkingEnabled(true);
          await settings.setSuggestionGenerationThinkingEnabled(true);
          await settings.setCompressGenerationThinkingEnabled(true);
          await settings.setTranslateGenerationThinkingEnabled(true);
          await settings.setOcrGenerationThinkingEnabled(true);

          // 全局思考预算已废弃：助手没设档位就是“自动”，不再有第二处兜底。
          // 备份里残留的 thinking_budget_v1 也不再被 SettingsProvider 读取。
          expect(
            settings.summaryGenerationReasoningFor(null),
            ReasoningRequest.auto,
          );
          expect(
            settings.suggestionGenerationReasoningFor(
              assistantWith(reasoning1024),
            ),
            reasoning1024,
          );
          expect(
            settings.compressGenerationReasoningFor(
              assistantWith(reasoning1024),
            ),
            reasoning1024,
          );
          expect(
            settings.translateGenerationReasoningFor(
              assistantWith(reasoning1024),
            ),
            reasoning1024,
          );
          expect(
            settings.ocrGenerationReasoningFor(assistantWith(reasoning1024)),
            reasoning1024,
          );
          expect(
            harness.preferences.getBool(
              'summary_generation_thinking_enabled_v1',
            ),
            isTrue,
          );
          expect(
            harness.preferences.getBool(
              'suggestion_generation_thinking_enabled_v1',
            ),
            isTrue,
          );
          expect(
            harness.preferences.getBool(
              'compress_generation_thinking_enabled_v1',
            ),
            isTrue,
          );
          expect(
            harness.preferences.getBool(
              'translate_generation_thinking_enabled_v1',
            ),
            isTrue,
          );
          expect(
            harness.preferences.getBool('ocr_generation_thinking_enabled_v1'),
            isTrue,
          );
        },
      );
    });

    test(
      'Claude latest models expose xhigh and max reasoning without presets',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);

        await settings.loaded;
        await settings.setProviderConfig(
          'Claude',
          ProviderConfig(
            id: 'Claude',
            enabled: true,
            name: 'Claude',
            apiKey: 'test-key',
            baseUrl: 'https://api.anthropic.com/v1',
            providerType: ProviderKind.claude,
            models: const [
              'claude-fable-5-1',
              'claude-fable-5',
              'claude-mythos-5',
              'claude-opus-4-8',
              'claude-opus-5',
              'claude-sonnet-5',
            ],
          ),
        );

        expect(settings.getProviderConfig('Claude').models, [
          'claude-fable-5-1',
          'claude-fable-5',
          'claude-mythos-5',
          'claude-opus-4-8',
          'claude-opus-5',
          'claude-sonnet-5',
        ]);
      },
    );
  });
}
