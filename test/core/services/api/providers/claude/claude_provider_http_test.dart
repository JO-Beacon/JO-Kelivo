import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_container.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_files.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_provider.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:Kelivo/core/utils/multimodal_input_utils.dart';

const _model = 'claude-sonnet-4-5-20250929';

ProviderConfig _config({List<String> builtInTools = const ['code_execution']}) {
  return ProviderConfig(
    id: 'ClaudeHttpTest',
    enabled: true,
    name: 'ClaudeHttpTest',
    apiKey: 'test-key',
    baseUrl: 'https://api.anthropic.com/v1',
    providerType: ProviderKind.claude,
    modelOverrides: {
      _model: {'builtInTools': builtInTools},
    },
  );
}

Map<String, dynamic> _doc(File file, String name, String mime) => {
  'uri': file.path,
  'name': name,
  'mime': mime,
};

class _RecordedRequest {
  _RecordedRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;
}

class _ClaudeFakeClient extends http.BaseClient {
  final requests = <_RecordedRequest>[];
  String? staleContainer;
  bool _staleReturned = false;
  bool emitPauseTurn = false;
  int _messageResponses = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final body = utf8.decode(bytes);
    requests.add(
      _RecordedRequest(
        request.method,
        request.url,
        Map<String, String>.from(request.headers),
        body,
      ),
    );

    if (request.url.path.endsWith('/files')) {
      final match = RegExp(r'filename="([^"]+)"').firstMatch(body);
      final name = match?.group(1) ?? 'upload';
      return _jsonResponse({'id': 'file_$name'});
    }

    final decoded = jsonDecode(body) as Map<String, dynamic>;
    if (!_staleReturned &&
        staleContainer != null &&
        decoded['container'] == staleContainer) {
      _staleReturned = true;
      return _response(
        jsonEncode({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'message': 'Container $staleContainer not found',
          },
        }),
        400,
      );
    }
    if (emitPauseTurn && _messageResponses++ == 0) {
      return _jsonResponse({
        'id': 'msg_pause',
        'role': 'assistant',
        'content': [
          {
            'type': 'server_tool_use',
            'id': 'srv_1',
            'name': 'bash_code_execution',
            'input': {'command': 'print(1)'},
          },
          {
            'type': 'bash_code_execution_tool_result',
            'tool_use_id': 'srv_1',
            'content': {'stdout': '1', 'return_code': 0},
          },
        ],
        'stop_reason': 'pause_turn',
      });
    }
    return _jsonResponse({
      'id': 'msg_1',
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'ok'},
      ],
      'stop_reason': 'end_turn',
      'usage': {'input_tokens': 1, 'output_tokens': 1},
    });
  }

  http.StreamedResponse _jsonResponse(Object body) => _response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );

  http.StreamedResponse _response(
    String body,
    int status, {
    Map<String, String> headers = const {},
  }) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
    headers: headers,
  );
}

List<Map<String, dynamic>> _messagesBlocks(_RecordedRequest request) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final messages = (body['messages'] as List).cast<Map>();
  return (messages.last['content'] as List).cast<Map<String, dynamic>>();
}

void main() {
  late Directory tempDir;
  late File stock;
  late File sales;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jo_aiclient_claude_http_');
    stock = File('${tempDir.path}/stock.xlsx')..writeAsBytesSync([1, 2, 3]);
    sales = File('${tempDir.path}/sales.csv')..writeAsStringSync('a,b\n1,2\n');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'uploads data files as container_upload blocks before the message',
    () async {
      final client = _ClaudeFakeClient();
      addTearDown(client.close);

      await sendClaudeStreamEvents(client, _config(), _model, [
        {
          'role': 'user',
          'content': 'analyse',
          multimodalInternalDocumentPathsKey: [
            _doc(stock, 'stock.xlsx', 'application/vnd.ms-excel'),
            _doc(sales, 'sales.csv', 'text/csv'),
          ],
        },
      ], stream: false).toList();

      expect(client.requests.map((request) => request.url.path), [
        '/v1/files',
        '/v1/files',
        '/v1/messages',
      ]);
      final message = client.requests.last;
      final body = jsonDecode(message.body) as Map<String, dynamic>;
      expect(body['container'], isNull);
      expect(_messagesBlocks(message).map((block) => block['type']), [
        'text',
        'container_upload',
        'container_upload',
      ]);
      expect(
        _messagesBlocks(message).skip(1).map((block) => block['file_id']),
        ['file_stock.xlsx', 'file_sales.csv'],
      );
    },
  );

  test('a missing current-turn file prevents the messages request', () async {
    final client = _ClaudeFakeClient();
    addTearDown(client.close);
    final missing = File('${tempDir.path}/missing.csv');

    await expectLater(
      sendClaudeStreamEvents(client, _config(), _model, [
        {
          'role': 'user',
          'content': 'analyse',
          multimodalInternalDocumentPathsKey: [
            _doc(missing, 'missing.csv', 'text/csv'),
          ],
        },
      ], stream: false).toList(),
      throwsA(isA<ClaudeFileUploadException>()),
    );
    expect(client.requests, isEmpty);
  });

  test(
    'an expired container retries once and reuses the current upload',
    () async {
      final client = _ClaudeFakeClient()..staleContainer = 'container_old';
      addTearDown(client.close);

      await sendClaudeStreamEvents(client, _config(), _model, [
        {
          'role': 'user',
          'content': 'first',
          multimodalInternalDocumentPathsKey: [
            _doc(stock, 'stock.xlsx', 'application/vnd.ms-excel'),
          ],
        },
        {
          'role': 'assistant',
          'content': 'ran code',
          multimodalInternalClaudeContainerKey: const ClaudeContainerRef(
            id: 'container_old',
          ).encode(),
        },
        {
          'role': 'user',
          'content': 'second',
          multimodalInternalDocumentPathsKey: [
            _doc(sales, 'sales.csv', 'text/csv'),
          ],
        },
      ], stream: false).toList();

      expect(client.requests.map((request) => request.url.path), [
        '/v1/files',
        '/v1/messages',
        '/v1/files',
        '/v1/messages',
      ]);
      final firstBody =
          jsonDecode(client.requests[1].body) as Map<String, dynamic>;
      final retryBody =
          jsonDecode(client.requests[3].body) as Map<String, dynamic>;
      expect(firstBody['container'], 'container_old');
      expect(retryBody['container'], isNull);
      expect(
        _messagesBlocks(
          client.requests[3],
        ).skip(1).map((block) => block['file_id']),
        ['file_sales.csv', 'file_stock.xlsx'],
      );
    },
  );

  test(
    'without code execution, stored containers and files stay out of the request',
    () async {
      final client = _ClaudeFakeClient();
      addTearDown(client.close);

      await sendClaudeStreamEvents(
        client,
        _config(builtInTools: const ['web_fetch']),
        _model,
        [
          {
            'role': 'assistant',
            'content': 'ran code',
            multimodalInternalClaudeContainerKey: const ClaudeContainerRef(
              id: 'container_old',
            ).encode(),
          },
          {
            'role': 'user',
            'content': 'second',
            multimodalInternalDocumentPathsKey: [
              _doc(sales, 'sales.csv', 'text/csv'),
            ],
          },
        ],
        stream: false,
      ).toList();

      expect(client.requests.map((request) => request.url.path), [
        '/v1/messages',
      ]);
      final body =
          jsonDecode(client.requests.single.body) as Map<String, dynamic>;
      expect(body['container'], isNull);
      expect(client.requests.single.body, isNot(contains('container_upload')));
    },
  );

  test(
    'a same-named client tool does not activate the hosted container path',
    () async {
      final client = _ClaudeFakeClient();
      addTearDown(client.close);

      await sendClaudeStreamEvents(
        client,
        _config(),
        _model,
        [
          {
            'role': 'user',
            'content': 'run locally',
            multimodalInternalDocumentPathsKey: [
              _doc(sales, 'sales.csv', 'text/csv'),
            ],
          },
        ],
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'code_execution',
              'parameters': {'type': 'object'},
            },
          },
        ],
        stream: false,
      ).toList();

      expect(client.requests.map((request) => request.url.path), [
        '/v1/messages',
      ]);
      expect(client.requests.single.body, isNot(contains('container_upload')));
      final body =
          jsonDecode(client.requests.single.body) as Map<String, dynamic>;
      expect((body['tools'] as List).single['input_schema'], isNotNull);
      expect(body['container'], isNull);
    },
  );

  test(
    'a pause_turn response is followed by text and recorded as one turn',
    () async {
      final client = _ClaudeFakeClient()..emitPauseTurn = true;
      addTearDown(client.close);

      final events = await sendClaudeStreamEvents(
        client,
        _config(),
        _model,
        const [
          {'role': 'user', 'content': 'run code'},
        ],
        stream: false,
      ).toList();

      expect(
        client.requests.where(
          (request) => request.url.path.endsWith('/messages'),
        ),
        hasLength(2),
      );
      final artifacts = events
          .whereType<ProviderArtifact>()
          .where((artifact) => artifact.kind == 'claude_turn')
          .map((artifact) => jsonDecode(artifact.payload) as List)
          .toList();
      expect(artifacts.map((responses) => responses.length), [1, 2]);
      expect((artifacts.last[1] as List).single['text'], 'ok');
    },
  );
}
