import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/chat_input_data.dart';
import 'package:Kelivo/core/models/model_spec.dart';
import 'package:Kelivo/core/services/api/chat_api_helpers.dart';
import 'package:Kelivo/core/utils/multimodal_input_utils.dart';
import 'package:Kelivo/features/home/services/message_generation_service.dart';

ModelSpec _spec(List<Modality> input) =>
    ModelSpec(id: 'test-model', displayName: 'test-model', input: input);

DocumentAttachment _doc(String mime, {required String name}) =>
    DocumentAttachment(path: '/tmp/$name', fileName: name, mime: mime);

/// 附件按模型输入能力把关：读不了就当场拦住并告知，不静默丢弃。
void main() {
  group('unsupportedInputModalities', () {
    test('模型读不了的图片、音频、视频都会被列出', () {
      final input = ChatInputData(
        text: 'hi',
        imagePaths: const ['/tmp/a.png'],
        documents: [
          _doc('audio/mpeg', name: 'a.mp3'),
          _doc('video/mp4', name: 'a.mp4'),
        ],
      );

      expect(unsupportedInputModalities(input, _spec(const [Modality.text])), [
        Modality.image,
        Modality.audio,
        Modality.video,
      ]);
    });

    test('模型支持的能力不会被列出', () {
      final input = ChatInputData(
        text: 'hi',
        imagePaths: const ['/tmp/a.png'],
        documents: [_doc('audio/mpeg', name: 'a.mp3')],
      );

      expect(
        unsupportedInputModalities(
          input,
          _spec(const [Modality.text, Modality.image, Modality.audio]),
        ),
        isEmpty,
      );
    });

    test('OCR 打开时图片不算不支持（它会被转成文本发出去）', () {
      final input = ChatInputData(text: 'hi', imagePaths: const ['/tmp/a.png']);

      expect(
        unsupportedInputModalities(
          input,
          _spec(const [Modality.text]),
          ocrActive: true,
        ),
        isEmpty,
      );
    });

    test('文档不受能力约束', () {
      final input = ChatInputData(
        text: 'hi',
        documents: [
          _doc('application/pdf', name: 'a.pdf'),
          _doc('text/plain', name: 'a.txt'),
        ],
      );

      expect(
        unsupportedInputModalities(input, _spec(const [Modality.text])),
        isEmpty,
      );
    });

    test('错误码带前缀与能力名，供上层翻成用户文案', () {
      expect(
        attachmentUnsupportedErrorCode(const [Modality.image, Modality.video]),
        'attachment_unsupported:image,video',
      );
      expect(
        attachmentUnsupportedErrorCode(const []),
        'attachment_unsupported:',
      );
    });
  });

  group('官方 OpenAI 接口的音频容器闸门', () {
    test('只认官方域名，网关与空值都不算', () {
      expect(isOfficialOpenAIEndpoint('https://api.openai.com/v1'), isTrue);
      expect(isOfficialOpenAIEndpoint('https://api.openai.com'), isTrue);
      expect(isOfficialOpenAIEndpoint('https://api.openai.com/v1/'), isTrue);
      expect(
        isOfficialOpenAIEndpoint('https://gateway.example.com/v1'),
        isFalse,
      );
      expect(isOfficialOpenAIEndpoint('https://openrouter.ai/api/v1'), isFalse);
      expect(isOfficialOpenAIEndpoint(''), isFalse);
      expect(isOfficialOpenAIEndpoint('不是地址'), isFalse);
    });

    test('容器归类：别名归到 wav／mp3，其它按扩展名或子类型', () {
      expect(audioContainerToken('audio/x-wav', '/tmp/a.wav'), 'wav');
      expect(audioContainerToken('audio/mpeg', '/tmp/a.mp3'), 'mp3');
      expect(audioContainerToken('audio/mp4', '/tmp/memo.m4a'), 'm4a');
      expect(audioContainerToken('audio/flac', '/tmp/a.flac'), 'flac');
      expect(audioContainerToken('image/png', '/tmp/a.png'), isNull);
    });

    test('本次输入里 m4a 会被指出，wav 与 mp3 放行', () {
      final m4a = ChatInputData(
        text: 'hi',
        documents: [_doc('audio/mp4', name: 'memo.m4a')],
      );
      expect(unsupportedOfficialOpenAIAudioContainers(m4a), ['m4a']);

      final ok = ChatInputData(
        text: 'hi',
        documents: [
          _doc('audio/mpeg', name: 'a.mp3'),
          _doc('audio/wav', name: 'b.wav'),
        ],
      );
      expect(unsupportedOfficialOpenAIAudioContainers(ok), isEmpty);
    });

    test('历史消息里的容器同样会被指出，多个按名排序', () {
      final messages = [
        <String, dynamic>{
          'role': 'user',
          'content': 'hi',
          multimodalInternalMediaPathsKey: [
            encodeInternalMediaRef(uri: '/tmp/a.ogg', mime: 'audio/ogg'),
            encodeInternalMediaRef(uri: '/tmp/b.m4a', mime: 'audio/mp4'),
            encodeInternalMediaRef(uri: '/tmp/c.mp3', mime: 'audio/mpeg'),
          ],
        },
      ];
      expect(officialOpenAIAudioContainerConflictsInApiMessages(messages), [
        'm4a',
        'ogg',
      ]);
    });

    test('闸门优先级：先报能力不足，能力没问题才报容器', () {
      expect(
        attachmentGateError(
          unsupportedModalities: const [Modality.audio],
          unsupportedAudioContainers: const ['m4a'],
        ),
        'attachment_unsupported:audio',
      );
      expect(
        attachmentGateError(
          unsupportedModalities: const [],
          unsupportedAudioContainers: const ['m4a'],
        ),
        'audio_container_unsupported:m4a',
      );
      expect(
        attachmentGateError(
          unsupportedModalities: const [],
          unsupportedAudioContainers: const [],
        ),
        isNull,
      );
    });
  });
}
