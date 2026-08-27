import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/token_usage.dart';

void main() {
  group('TokenUsage', () {
    test(
      'merge preserves explicit total when split token fields are missing',
      () {
        final merged = const TokenUsage().merge(
          const TokenUsage(totalTokens: 895),
        );

        expect(merged.promptTokens, 0);
        expect(merged.completionTokens, 0);
        expect(merged.cachedTokens, 0);
        expect(merged.totalTokens, 895);
      },
    );

    test('accumulate adds token usage from separate tool rounds', () {
      final total =
          const TokenUsage(
            promptTokens: 100,
            completionTokens: 20,
            cachedTokens: 5,
          ).accumulate(
            const TokenUsage(
              promptTokens: 80,
              completionTokens: 30,
              cachedTokens: 2,
            ),
          );

      expect(total.promptTokens, 180);
      expect(total.completionTokens, 50);
      expect(total.cachedTokens, 7);
      expect(total.totalTokens, 230);
    });
  });
}
