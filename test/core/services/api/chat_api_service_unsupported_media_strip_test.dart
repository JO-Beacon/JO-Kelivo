import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/api/chat_api_helpers.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/utils/multimodal_input_utils.dart';

List<Map<String, dynamic>> _messageWith(
  List<({String uri, String mime})> media, {
  Object? content = 'hi',
}) {
  return [
    <String, dynamic>{
      'role': 'user',
      'content': content,
      multimodalInternalMediaPathsKey: [
        for (final item in media)
          encodeInternalMediaRef(uri: item.uri, mime: item.mime),
      ],
    },
  ];
}

List<String> _refMimes(Map<String, dynamic> message) {
  return [
    for (final ref in parseInternalMediaRefs(
      message[multimodalInternalMediaPathsKey],
    ))
      mimeForInternalMediaRef(ref),
  ];
}

/// 模型只支持音频、不支持图片时，音频不能被图片连坐删掉。
void main() {
  test('只剔图片时，音频引用必须留下来', () async {
    final messages = _messageWith(const [
      (uri: '/tmp/a.png', mime: 'image/png'),
      (uri: '/tmp/memo.wav', mime: 'audio/wav'),
    ]);

    final result = await ChatApiService.stripUnsupportedMediaInputsForTest(
      messages,
      stripImages: true,
      stripAudio: false,
    );

    expect(_refMimes(result.single), ['audio/wav']);
  });

  test('只剔音频时，图片引用与内容部件都保留', () async {
    final content = [
      {'type': 'text', 'text': 'hi'},
      {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AA'},
      },
    ];
    final messages = _messageWith(const [
      (uri: '/tmp/a.png', mime: 'image/png'),
      (uri: '/tmp/memo.wav', mime: 'audio/wav'),
    ], content: content);

    final result = await ChatApiService.stripUnsupportedMediaInputsForTest(
      messages,
      stripImages: false,
      stripAudio: true,
    );

    expect(_refMimes(result.single), ['image/png']);
    expect(result.single['content'], content);
  });

  test('两类都剔时清掉整条媒体引用', () async {
    final messages = _messageWith(const [
      (uri: '/tmp/a.png', mime: 'image/png'),
      (uri: '/tmp/memo.wav', mime: 'audio/wav'),
    ]);

    final result = await ChatApiService.stripUnsupportedMediaInputsForTest(
      messages,
      stripImages: true,
      stripAudio: true,
    );

    expect(result.single.containsKey(multimodalInternalMediaPathsKey), isFalse);
  });

  test('只支持视频的模型：视频引用不被误删', () async {
    final messages = _messageWith(const [
      (uri: '/tmp/a.mp4', mime: 'video/mp4'),
      (uri: '/tmp/memo.wav', mime: 'audio/wav'),
    ]);

    final result = await ChatApiService.stripUnsupportedMediaInputsForTest(
      messages,
      stripImages: true,
      stripAudio: true,
    );

    expect(_refMimes(result.single), ['video/mp4']);
  });
}
