import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_role_normalizer.dart';

import 'support/collect_generation.dart';

ProviderConfig _claudeConfig(String baseUrl) {
  return ProviderConfig(
    id: 'ClaudeFirstTurnTest',
    enabled: true,
    name: 'ClaudeFirstTurnTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.claude,
  );
}

/// The translate/OCR path reaches Anthropic through `sendMessageStream`, whose
/// message assembly is its own copy of the one the chat path uses.
Future<Map<String, dynamic>> _captureClaudeRequestBody(
  List<Map<String, dynamic>> messages,
) async {
  late Map<String, dynamic> requestBody;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() async {
    await server.close(force: true);
  });

  server.listen((request) async {
    requestBody = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
        .cast<String, dynamic>();
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'id': 'msg_1',
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      }),
    );
    await request.response.close();
  });

  final chunks = await ChatApiService.sendMessageStream(
    config: _claudeConfig('http://${server.address.address}:${server.port}'),
    modelId: 'claude-sonnet-4-5-20250929',
    messages: messages,
    stream: false,
  ).toList();

  expect(chunks.isGenerationDone, isTrue);
  return requestBody;
}

void main() {
  tearDown(() {
    ClaudeFirstTurnPlaceholderConfig.enabled = false;
    ClaudeFirstTurnPlaceholderConfig.text = claudeFirstTurnPlaceholder;
  });

  test('an assistant-first history is opened by a user placeholder', () async {
    ClaudeFirstTurnPlaceholderConfig.enabled = true;

    final body = await _captureClaudeRequestBody([
      {'role': 'assistant', 'content': 'the reply the branch starts on'},
      {'role': 'user', 'content': 'carry on'},
    ]);

    final messages = (body['messages'] as List).cast<Map>();
    expect(messages.first['role'], 'user');
    expect(messages.first['content'], claudeFirstTurnPlaceholder);
    expect(messages[1]['content'], 'the reply the branch starts on');
    expect(messages[2]['content'], 'carry on');
  });

  test('a system prompt ahead of a user turn adds no placeholder', () async {
    final body = await _captureClaudeRequestBody([
      {'role': 'system', 'content': 'be brief'},
      {'role': 'user', 'content': 'hello'},
    ]);

    final messages = (body['messages'] as List).cast<Map>();
    expect(messages, hasLength(1));
    expect(messages.single['role'], 'user');
    expect(messages.single['content'], 'hello');
    expect(body['system'], 'be brief');
  });

  // The assertions above compare against the constant on both sides, so they
  // would follow it anywhere — including to a value the API refuses. An empty
  // text block is a 400, and a whitespace-only one is sanitised away by some
  // clients, so the filler has to survive both.
  test('the placeholder is content the API accepts as a text block', () {
    expect(claudeFirstTurnPlaceholder, isNotEmpty);
    expect(claudeFirstTurnPlaceholder.trim(), isNotEmpty);
  });

  test('a custom filler goes out instead of the default one', () async {
    ClaudeFirstTurnPlaceholderConfig.enabled = true;
    ClaudeFirstTurnPlaceholderConfig.text = ' 下划线_ ';

    final body = await _captureClaudeRequestBody([
      {'role': 'assistant', 'content': 'the reply the branch starts on'},
    ]);

    final messages = (body['messages'] as List).cast<Map>();
    expect(messages.first['role'], 'user');
    expect(messages.first['content'], '下划线_');
  });

  // The setting ships off, so an assistant-first history goes out untouched
  // until someone turns it on.
  test('by default the conversation is sent as it stands', () async {
    final body = await _captureClaudeRequestBody([
      {'role': 'assistant', 'content': 'the reply the branch starts on'},
      {'role': 'user', 'content': 'carry on'},
    ]);

    final messages = (body['messages'] as List).cast<Map>();
    expect(messages, hasLength(2));
    expect(messages.first['role'], 'assistant');
    expect(messages.first['content'], 'the reply the branch starts on');
  });
}
