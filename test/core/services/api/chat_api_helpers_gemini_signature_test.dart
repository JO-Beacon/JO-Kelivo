import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/api/chat_api_helpers.dart';

void main() {
  group('Gemini 正文签名的收集', () {
    test('内置工具轮次跳过 toolCall 与 toolResponse 的签名', () {
      final comment = collectThoughtSigCommentFromParts([
        {
          'toolCall': {'name': 'google_search'},
          'thoughtSignature': 'sig-tool-call',
        },
        {
          'toolResponse': {'name': 'google_search'},
          'thoughtSignature': 'sig-tool-response',
        },
        {'text': 'Grounded answer.'},
        {'text': '', 'thoughtSignature': 'sig-text'},
      ]);

      expect(comment, contains('sig-text'));
      expect(comment, isNot(contains('sig-tool-call')));
      expect(comment, isNot(contains('sig-tool-response')));
    });

    test('正文为空的尾部 part 仍能收下本轮签名', () {
      final comment = collectThoughtSigCommentFromParts([
        {'text': '正文', 'thoughtSignature': 'sig-first'},
        {'text': '', 'thoughtSignature': 'sig-later'},
      ]);

      // 一轮只取第一个正文签名。
      expect(comment, contains('sig-first'));
      expect(comment, isNot(contains('sig-later')));
    });

    test('思考 part 与内联图片 part 不占用正文签名位', () {
      final comment = collectThoughtSigCommentFromParts([
        {'text': '推理', 'thought': true, 'thoughtSignature': 'sig-thought'},
        {
          'inlineData': {'mimeType': 'image/png', 'data': 'AA=='},
          'thoughtSignature': 'sig-image',
        },
        {'text': '答案', 'thoughtSignature': 'sig-text'},
      ]);

      expect(comment, contains('sig-text'));
      expect(comment, isNot(contains('sig-thought')));
      // 内联图片的签名走图片通道，不占正文位。
      expect(comment, contains('sig-image'));
    });
  });
}
