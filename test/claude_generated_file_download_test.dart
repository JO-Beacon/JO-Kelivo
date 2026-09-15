import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_files.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_provider.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:Kelivo/utils/upload_dedupe.dart';

import 'support/collect_generation.dart';

const _model = 'claude-sonnet-4-6';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

ProviderConfig _config() => ProviderConfig(
  id: 'ClaudeDownloadTest',
  enabled: true,
  name: 'ClaudeDownloadTest',
  apiKey: 'test-key',
  baseUrl: 'https://api.anthropic.com/v1',
  providerType: ProviderKind.claude,
  modelOverrides: {
    _model: {
      'builtInTools': <String>['code_execution'],
    },
  },
);

/// 一轮流式响应：代码执行交回若干个文件，文件前后各有一段文本。
List<Map<String, dynamic>> _fileRunEvents(List<String> fileIds) => [
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'text', 'text': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': 'before '},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'content_block_start',
    'index': 1,
    'content_block': {
      'type': 'server_tool_use',
      'id': 'srvtoolu_run',
      'name': 'bash_code_execution',
      'input': {'command': 'python plot.py'},
    },
  },
  {'type': 'content_block_stop', 'index': 1},
  {
    'type': 'content_block_start',
    'index': 2,
    'content_block': {
      'type': 'bash_code_execution_tool_result',
      'tool_use_id': 'srvtoolu_run',
      'content': {
        'type': 'bash_code_execution_result',
        'stdout': '',
        'stderr': '',
        'return_code': 0,
        'content': [
          for (final id in fileIds)
            {'type': 'code_execution_output', 'file_id': id},
        ],
      },
    },
  },
  {'type': 'content_block_stop', 'index': 2},
  {
    'type': 'content_block_start',
    'index': 3,
    'content_block': {'type': 'text', 'text': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 3,
    'delta': {'type': 'text_delta', 'text': 'after'},
  },
  {'type': 'content_block_stop', 'index': 3},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
  },
  {'type': 'message_stop'},
];

String _sse(List<Map<String, dynamic>> events) {
  final buffer = StringBuffer()
    ..write('event: message_start\n')
    ..write(
      'data: ${jsonEncode({
        'type': 'message_start',
        'message': {
          'id': 'msg_1',
          'role': 'assistant',
          'content': <Object>[],
          'stop_reason': null,
          'usage': {'input_tokens': 1, 'output_tokens': 0},
        },
      })}\n\n',
    );
  for (final event in events) {
    buffer.write('event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n');
  }
  return buffer.toString();
}

/// 一个假的 Messages + Files API：消息流走 SSE，文件元数据与内容按 id 应答。
class _FakeApi extends http.BaseClient {
  _FakeApi({required this.sse});

  final String sse;
  final Map<String, Map<String, dynamic>> metadata = {};
  final Map<String, List<int>> contents = {};
  final List<String> paths = [];
  Duration contentDelay = Duration.zero;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    paths.add(path);
    await request.finalize().toBytes();

    final content = RegExp(r'^/v1/files/([^/]+)/content$').firstMatch(path);
    if (content != null) {
      if (contentDelay > Duration.zero) {
        await Future<void>.delayed(contentDelay);
      }
      return _bytes(contents[content.group(1)!] ?? const <int>[]);
    }
    final meta = RegExp(r'^/v1/files/([^/]+)$').firstMatch(path);
    if (meta != null) {
      return _bytes(
        utf8.encode(jsonEncode(metadata[meta.group(1)!] ?? const {})),
        headers: const {'content-type': 'application/json'},
      );
    }
    return _bytes(
      utf8.encode(sse),
      headers: const {'content-type': 'text/event-stream'},
    );
  }

  http.StreamedResponse _bytes(
    List<int> body, {
    Map<String, String> headers = const {},
  }) => http.StreamedResponse(
    Stream<List<int>>.value(body),
    200,
    headers: headers,
  );
}

/// upload 目录里的文件名，按落盘顺序。
List<String> _names(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .map((file) => file.uri.pathSegments.last)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jo_claude_download_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('claudeGeneratedFileName keeps the extension when it trims', () {
    final long = '${'a' * 400}.png';
    final trimmed = claudeGeneratedFileName(long);
    expect(trimmed.length, 255);
    expect(trimmed.endsWith('.png'), isTrue);
    // 短的照旧原样返回。
    expect(claudeGeneratedFileName('chart.png'), 'chart.png');
  });

  test(
    'findIdenticalDigest finds a stored copy and skips the caller\'s own',
    () async {
      final dir = Directory(p.join(tempDir.path, 'dedupe'))
        ..createSync(recursive: true);
      final bytes = <int>[1, 2, 3, 4];
      final stored = File(p.join(dir.path, 'chart.png'))
        ..writeAsBytesSync(bytes);
      final digest = sha256.convert(bytes).bytes;

      // 不排除时找得到；把自己排除掉就只剩「没有别的」。
      expect(
        await UploadDedupe.findIdenticalDigest(
          dir,
          bytes.length,
          digest,
          'chart.png',
        ),
        stored.path,
      );
      expect(
        await UploadDedupe.findIdenticalDigest(
          dir,
          bytes.length,
          digest,
          'chart.png',
          exclude: stored.path,
        ),
        isNull,
      );
      // 内容不同的同名文件不是副本。
      final other = Directory(p.join(tempDir.path, 'other'))
        ..createSync(recursive: true);
      File(p.join(other.path, 'chart.png')).writeAsBytesSync(<int>[9, 9, 9, 9]);
      expect(
        await UploadDedupe.findIdenticalDigest(other, 4, digest, 'chart.png'),
        isNull,
      );
    },
  );

  test('a slow file download does not hold up the text after it', () async {
    final api = _FakeApi(sse: _sse(_fileRunEvents(['file_chart'])))
      ..contentDelay = const Duration(milliseconds: 300)
      ..metadata['file_chart'] = {
        'id': 'file_chart',
        'filename': 'chart.png',
        'mime_type': 'image/png',
        'size_bytes': 4,
        'downloadable': true,
      }
      ..contents['file_chart'] = <int>[1, 2, 3, 4];
    addTearDown(api.close);

    final chunks = await sendClaudeStreamEvents(api, _config(), _model, [
      {'role': 'user', 'content': 'plot'},
    ]).toList();

    expect(chunks.joinedContent, 'before after');
    final file = chunks.indexWhere((chunk) => chunk is GeneratedFile);
    final lastText = chunks.lastIndexWhere((chunk) => chunk is TextDelta);
    expect(file, greaterThan(lastText), reason: '文本不能等下载');
    expect((chunks[file] as GeneratedFile).name, 'chart.png');
  });

  test(
    'an identical copy already stored is reused and the fresh download dropped',
    () async {
      final api = _FakeApi(sse: '')
        ..metadata['file_1'] = {
          'id': 'file_1',
          'filename': 'chart.png',
          'mime_type': 'image/png',
          'size_bytes': 4,
          'downloadable': true,
        }
        ..contents['file_1'] = <int>[1, 2, 3, 4];
      addTearDown(api.close);

      Future<GeneratedFile?> download() => downloadClaudeGeneratedFile(
        client: api,
        base: 'https://api.anthropic.com/v1',
        headers: const {'x-api-key': 'sk-test'},
        fileId: 'file_1',
      );

      final first = await download();
      final second = await download();

      expect(second!.uri, first!.uri, reason: '同一份内容只留一份');
      // 边下边写时它拿的是带序号的名字，不能和原件并排留下。
      expect(_names(tempDir), ['chart.png']);
    },
  );

  test('a chart the API cannot type is still a chart', () async {
    final api = _FakeApi(sse: _sse(_fileRunEvents(['file_chart'])));
    addTearDown(api.close);
    api.metadata['file_chart'] = {
      'id': 'file_chart',
      'filename': 'chart.png',
      'mime_type': 'application/octet-stream',
      'size_bytes': 4,
      'downloadable': true,
    };
    api.contents['file_chart'] = <int>[1, 2, 3, 4];

    final chunks = await sendClaudeStreamEvents(api, _config(), _model, [
      {'role': 'user', 'content': 'plot'},
    ]).toList();

    final file = chunks.whereType<GeneratedFile>().single;
    expect(file.mime, 'image/png');
  });

  test(
    'a cancelled turn discards its own download, not a shared one',
    () async {
      final api = _FakeApi(sse: '')
        ..metadata['file_1'] = {
          'id': 'file_1',
          'filename': 'chart.png',
          'mime_type': 'image/png',
          'size_bytes': 4,
          'downloadable': true,
        }
        ..contents['file_1'] = <int>[1, 2, 3, 4];
      addTearDown(api.close);

      Future<GeneratedFile?> download() => downloadClaudeGeneratedFile(
        client: api,
        base: 'https://api.anthropic.com/v1',
        headers: const {'x-api-key': 'sk-test'},
        fileId: 'file_1',
      );

      // 没人引用的文件跟着被取消的轮次一起走。
      final own = await download();
      await discardClaudeGeneratedFile(own!);
      expect(_names(tempDir), isEmpty);

      // 两轮画出同一张图、第二轮被取消：它找到的是第一轮的文件，留下。
      await download();
      final shared = await download();
      await discardClaudeGeneratedFile(shared!);
      expect(_names(tempDir), ['chart.png']);
    },
  );
}
