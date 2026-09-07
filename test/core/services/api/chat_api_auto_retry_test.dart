import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/models/auto_retry_options.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/api/retry_policy.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

ProviderConfig _config(
  String baseUrl, {
  String modelId = 'gpt-auto-retry-test',
  List<String> output = const ['text'],
  List<String> builtInTools = const [],
}) {
  return ProviderConfig(
    id: 'AutoRetryTest',
    enabled: true,
    name: 'AutoRetryTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    models: [modelId],
    modelOverrides: {
      modelId: {
        'type': 'chat',
        'input': ['text'],
        'output': output,
        if (builtInTools.isNotEmpty) 'builtInTools': builtInTools,
      },
    },
  );
}

const _fastRetry = AutoRetryOptions(
  enabled: true,
  maxRetries: 2,
  initialDelay: Duration.zero,
  maxDelay: Duration.zero,
  jitter: false,
);

void main() {
  tearDown(() {
    AutoRetryConfig.current = const AutoRetryOptions.defaults();
  });

  test('text request retries 429 before output and then succeeds', () async {
    AutoRetryConfig.current = _fastRetry;
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      if (requests == 1) {
        request.response.statusCode = HttpStatus.tooManyRequests;
        request.response.write('rate limit');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'ok'},
            },
          ],
        })}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });

    final events = await ChatApiService.sendMessageStreamEvents(
      config: _config('http://${server.address.address}:${server.port}/v1'),
      modelId: 'gpt-auto-retry-test',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
    ).toList();

    expect(requests, 2);
    expect(events.whereType<TextDelta>().map((event) => event.text), ['ok']);
  });

  test('disabled setting performs only one request', () async {
    AutoRetryConfig.current = _fastRetry.copyWith(enabled: false);
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('rate limit');
      await request.response.close();
    });

    await expectLater(
      ChatApiService.sendMessageStreamEvents(
        config: _config('http://${server.address.address}:${server.port}/v1'),
        modelId: 'gpt-auto-retry-test',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ).toList(),
      throwsA(anything),
    );
    expect(requests, 1);
  });

  test('legacy text stream retries 429 before output and succeeds', () async {
    AutoRetryConfig.current = _fastRetry;
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      if (requests == 1) {
        request.response.statusCode = HttpStatus.tooManyRequests;
        request.response.write('rate limit');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'translated'},
            },
          ],
        })}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });

    final chunks = await ChatApiService.sendMessageStream(
      config: _config('http://${server.address.address}:${server.port}/v1'),
      modelId: 'gpt-auto-retry-test',
      messages: const [
        {'role': 'user', 'content': 'translate'},
      ],
    ).toList();

    expect(requests, 2);
    expect(chunks.map((chunk) => chunk.content).join(), 'translated');
  });

  test('legacy stream with client tools is never replayed', () async {
    AutoRetryConfig.current = _fastRetry;
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('rate limit');
      await request.response.close();
    });

    await expectLater(
      ChatApiService.sendMessageStream(
        config: _config('http://${server.address.address}:${server.port}/v1'),
        modelId: 'gpt-auto-retry-test',
        messages: const [
          {'role': 'user', 'content': 'run a tool'},
        ],
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'side_effect',
              'description': 'test',
              'parameters': {'type': 'object'},
            },
          },
        ],
      ).toList(),
      throwsA(anything),
    );

    expect(requests, 1);
  });

  test('cancelRequest interrupts a legacy stream retry delay', () async {
    const requestId = 'legacy-auto-retry-cancel-test';
    AutoRetryConfig.current = const AutoRetryOptions(
      enabled: true,
      maxRetries: 2,
      initialDelay: Duration(seconds: 8),
      maxDelay: Duration(seconds: 8),
      jitter: false,
    );
    var requests = 0;
    final firstResponse = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('rate limit');
      await request.response.close();
      if (!firstResponse.isCompleted) firstResponse.complete();
    });

    final stopwatch = Stopwatch()..start();
    final done = ChatApiService.sendMessageStream(
      config: _config('http://${server.address.address}:${server.port}/v1'),
      modelId: 'gpt-auto-retry-test',
      messages: const [
        {'role': 'user', 'content': 'translate'},
      ],
      requestId: requestId,
    ).toList();
    await firstResponse.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ChatApiService.cancelRequest(requestId);

    await expectLater(done, throwsA(anything));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(requests, 1);
  });

  test(
    'generateText retries 429 and returns the successful response',
    () async {
      AutoRetryConfig.current = _fastRetry;
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests++;
        await request.drain();
        if (requests == 1) {
          request.response.statusCode = HttpStatus.tooManyRequests;
          request.response.write('rate limit');
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'summary'},
              },
            ],
          }),
        );
        await request.response.close();
      });

      final result = await ChatApiService.generateText(
        config: _config('http://${server.address.address}:${server.port}/v1'),
        modelId: 'gpt-auto-retry-test',
        prompt: 'summarize',
      );

      expect(requests, 2);
      expect(result, 'summary');
    },
  );

  test('disabled setting does not retry generateText', () async {
    AutoRetryConfig.current = _fastRetry.copyWith(enabled: false);
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('rate limit');
      await request.response.close();
    });

    await expectLater(
      ChatApiService.generateText(
        config: _config('http://${server.address.address}:${server.port}/v1'),
        modelId: 'gpt-auto-retry-test',
        prompt: 'summarize',
      ),
      throwsA(anything),
    );
    expect(requests, 1);
  });

  test('generateText with a server tool is never replayed', () async {
    AutoRetryConfig.current = _fastRetry;
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('rate limit');
      await request.response.close();
    });

    await expectLater(
      ChatApiService.generateText(
        config: _config(
          'http://${server.address.address}:${server.port}/v1',
          builtInTools: const ['search'],
        ),
        modelId: 'gpt-auto-retry-test',
        prompt: 'summarize',
      ),
      throwsA(anything),
    );
    expect(requests, 1);
  });

  test('image-output request is never replayed', () async {
    AutoRetryConfig.current = _fastRetry;
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('rate limit');
      await request.response.close();
    });

    await expectLater(
      ChatApiService.sendMessageStreamEvents(
        config: _config(
          'http://${server.address.address}:${server.port}/v1',
          output: const ['text', 'image'],
        ),
        modelId: 'gpt-auto-retry-test',
        messages: const [
          {'role': 'user', 'content': 'draw'},
        ],
      ).toList(),
      throwsA(anything),
    );
    expect(requests, 1);
  });

  test('cancelRequest interrupts the retry delay', () async {
    const requestId = 'auto-retry-cancel-test';
    AutoRetryConfig.current = const AutoRetryOptions(
      enabled: true,
      maxRetries: 2,
      initialDelay: Duration(seconds: 8),
      maxDelay: Duration(seconds: 8),
      jitter: false,
    );
    var requests = 0;
    final firstResponse = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('rate limit');
      await request.response.close();
      if (!firstResponse.isCompleted) firstResponse.complete();
    });

    final stopwatch = Stopwatch()..start();
    final done = ChatApiService.sendMessageStreamEvents(
      config: _config('http://${server.address.address}:${server.port}/v1'),
      modelId: 'gpt-auto-retry-test',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      requestId: requestId,
    ).toList();
    await firstResponse.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ChatApiService.cancelRequest(requestId);

    await expectLater(done, throwsA(anything));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(requests, 1);
  });

  test('a replacement request cancels the old backoff session', () async {
    const requestId = 'auto-retry-replacement-test';
    AutoRetryConfig.current = const AutoRetryOptions(
      enabled: true,
      maxRetries: 2,
      initialDelay: Duration(seconds: 8),
      maxDelay: Duration(seconds: 8),
      jitter: false,
    );
    var requests = 0;
    final firstResponse = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain();
      if (requests == 1) {
        request.response.statusCode = HttpStatus.tooManyRequests;
        request.response.write('rate limit');
        await request.response.close();
        firstResponse.complete();
        return;
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'new'},
            },
          ],
        })}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    final config = _config(
      'http://${server.address.address}:${server.port}/v1',
    );
    final firstError = ChatApiService.sendMessageStreamEvents(
      config: config,
      modelId: 'gpt-auto-retry-test',
      messages: const [
        {'role': 'user', 'content': 'old'},
      ],
      requestId: requestId,
    ).toList().then<Object?>((_) => null, onError: (Object error) => error);
    await firstResponse.future;

    final replacement = await ChatApiService.sendMessageStreamEvents(
      config: config,
      modelId: 'gpt-auto-retry-test',
      messages: const [
        {'role': 'user', 'content': 'new'},
      ],
      requestId: requestId,
    ).toList();

    expect(await firstError, isA<http.ClientException>());
    expect(requests, 2);
    expect(replacement.whereType<TextDelta>().map((event) => event.text), [
      'new',
    ]);
  });
}
