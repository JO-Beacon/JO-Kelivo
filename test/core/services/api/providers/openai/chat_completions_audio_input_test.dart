import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/model_spec.dart';
import 'package:Kelivo/core/services/api/providers/openai/chat_completions_api.dart';
import 'package:Kelivo/core/utils/multimodal_input_utils.dart';

Future<List<Map<String, dynamic>>> _build(
  String mime,
  String uri, {
  required bool canImageInput,
  required bool canAudioInput,
}) {
  return buildOpenAIChatCompletionMessages(
    [
      <String, dynamic>{
        'role': 'user',
        'content': 'listen',
        multimodalInternalMediaPathsKey: [
          encodeInternalMediaRef(uri: uri, mime: mime),
        ],
      },
    ],
    canImageInput: canImageInput,
    canAudioInput: canAudioInput,
    allowRemoteImages: true,
    reasoningReplay: ReasoningReplayPolicy.none,
  );
}

Map<String, dynamic>? _audioPart(List<Map<String, dynamic>> messages) {
  final content = messages.single['content'];
  if (content is! List) return null;
  for (final part in content.cast<Map>()) {
    if (part['type'] == 'input_audio') {
      return part.cast<String, dynamic>();
    }
  }
  return null;
}

List<String> _textParts(List<Map<String, dynamic>> messages) {
  final content = messages.single['content'];
  if (content is! List) return [content.toString()];
  return [
    for (final part in content.cast<Map>())
      if (part['type'] == 'text') (part['text'] ?? '').toString(),
  ];
}

/// 音频附件要真正送进请求，不能像以前那样被静默丢弃。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jo_audio_input_');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('模型支持音频时，本地 wav 以 input_audio 送进请求', () async {
    final file = File('${tempDir.path}/memo.wav');
    await file.writeAsBytes(const [1, 2, 3, 4]);

    final messages = await _build(
      'audio/wav',
      file.path,
      canImageInput: true,
      canAudioInput: true,
    );

    final part = _audioPart(messages);
    expect(part, isNotNull);
    expect(part!['input_audio']['format'], 'wav');
    expect(part['input_audio']['data'], base64Encode(const [1, 2, 3, 4]));
    expect(_textParts(messages), contains('listen'));
  });

  test('只支持音频、不支持图片的模型也能把音频发出去', () async {
    final file = File('${tempDir.path}/memo.wav');
    await file.writeAsBytes(const [7, 7, 7]);

    final messages = await _build(
      'audio/wav',
      file.path,
      canImageInput: false,
      canAudioInput: true,
    );

    expect(_audioPart(messages), isNotNull);
    expect(_textParts(messages), contains('listen'));
  });

  test('data URL 形式的 mp3 去掉前缀后再发送', () async {
    final payload = base64Encode(const [9, 8, 7]);

    final messages = await _build(
      'audio/mpeg',
      'data:audio/mpeg;base64,$payload',
      canImageInput: true,
      canAudioInput: true,
    );

    final part = _audioPart(messages);
    expect(part, isNotNull);
    expect(part!['input_audio']['format'], 'mp3');
    expect(part['input_audio']['data'], payload);
    expect(part['input_audio']['data'], isNot(contains('data:')));
  });

  test('协议未列出的容器按扩展名透传，交由上游判断', () async {
    final file = File('${tempDir.path}/memo.m4a');
    await file.writeAsBytes(const [5, 5]);

    final messages = await _build(
      'audio/mp4',
      file.path,
      canImageInput: true,
      canAudioInput: true,
    );

    expect(_audioPart(messages)!['input_audio']['format'], 'm4a');
  });

  test('模型不支持音频时不下发 input_audio（安全网，不能被改坏）', () async {
    final file = File('${tempDir.path}/memo.wav');
    await file.writeAsBytes(const [1, 2, 3, 4]);

    final messages = await _build(
      'audio/wav',
      file.path,
      canImageInput: true,
      canAudioInput: false,
    );

    expect(_audioPart(messages), isNull);
  });

  test('非音频 MIME 永远不会被当成音频下发', () {
    expect(audioContainerToken('image/png', '/tmp/a.png'), isNull);
    expect(audioContainerToken('application/pdf', '/tmp/a.pdf'), isNull);
    expect(audioContainerToken('video/mp4', '/tmp/a.mp4'), isNull);
  });
}
