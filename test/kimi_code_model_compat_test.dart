import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/providers/model_provider.dart';
import 'package:Kelivo/core/utils/openai_model_compat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Kimi Code models infer image, tool and reasoning capabilities', () {
    for (final id in [
      'k3',
      'k3-256k',
      'kimi-for-coding',
      'kimi-for-coding-highspeed',
      'moonshotai/kimi-for-coding:fast',
      'kimi-k2.8',
      'moonshotai/kimi-k2.8-preview',
    ]) {
      final model = ModelRegistry.infer(ModelInfo(id: id, displayName: id));
      expect(model.id, id);
      expect(model.input, [Modality.text, Modality.image], reason: id);
      expect(model.output, [Modality.text], reason: id);
      expect(
        model.abilities,
        containsAll([ModelAbility.tool, ModelAbility.reasoning]),
        reason: id,
      );
    }
    for (final id in ['k30', 'my-k3', 'kimi-for-coding-other']) {
      final model = ModelRegistry.infer(ModelInfo(id: id, displayName: id));
      expect(model.abilities, isEmpty, reason: id);
      expect(model.input, [Modality.text], reason: id);
      expect(openAIReasoningSupport(id), isNull, reason: id);
    }
  });

  test('Kimi Code effort caps preserve off support', () {
    for (final id in [
      'k3',
      'k3-256k',
      'kimi-for-coding',
      'kimi-k2.8-preview',
    ]) {
      expect(openAINormalizeReasoningEffort('off', id), 'none');
      expect(openAINormalizeReasoningEffort('medium', id), 'high');
      // xhigh 原样发出（以前会被替换成 max），由供应商决定接受还是报错。
      expect(openAINormalizeReasoningEffort('xhigh', id), 'xhigh');
    }
    expect(
      openAINormalizeReasoningEffort('max', 'kimi-for-coding-highspeed'),
      'auto',
    );
    // The open-platform K3 endpoint still requires thinking.
    expect(openAINormalizeReasoningEffort('off', 'kimi-k3'), 'low');
  });
}
