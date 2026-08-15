import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/services/logging/context_log_models.dart';
import 'package:Kelivo/core/services/logging/context_logger.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;
  Completer<void>? pathRequested;
  Completer<void>? pathGate;

  Future<String?> _getPath() async {
    pathRequested?.complete();
    await pathGate?.future;
    return path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() => _getPath();

  @override
  Future<String?> getApplicationSupportPath() => _getPath();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late _FakePathProviderPlatform fakePathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_context_logs_');
    previousPathProvider = PathProviderPlatform.instance;
    fakePathProvider = _FakePathProviderPlatform(tempDir.path);
    PathProviderPlatform.instance = fakePathProvider;
    await ContextLogger.setEnabled(false);
  });

  tearDown(() async {
    await ContextLogger.setEnabled(false);
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('disabled logger writes nothing', () async {
    ContextLogger.logPrepared(
      apiMessages: [
        {'role': 'user', 'content': 'hi'},
      ],
      conversationId: 'c1',
      assistantName: 'A',
      provider: 'p',
      model: 'm',
    );
    await ContextLogger.setEnabled(false);
    final logFile = File(
      '${tempDir.path}/logs/${ContextLogger.activeFileName}',
    );
    expect(await logFile.exists(), isFalse);
  });

  test('enabled logger writes one jsonl snapshot', () async {
    await ContextLogger.setEnabled(true);
    ContextLogger.logPrepared(
      apiMessages: [
        {
          'role': 'system',
          'content': 'sys\n\nrules',
          kelivoContextSegmentsKey: [
            ContextSegmentTags.item(
              source: ContextSource.systemPrompt,
              length: 3,
            ),
            ContextSegmentTags.item(
              source: ContextSource.memoryRules,
              length: 7,
            ),
          ],
        },
        {'role': 'user', 'content': 'hello'},
      ],
      conversationId: 'c1',
      assistantName: 'Kelivo',
      provider: 'openai',
      model: 'gpt-4.1',
    );
    await ContextLogger.setEnabled(false);

    final logFile = File(
      '${tempDir.path}/logs/${ContextLogger.activeFileName}',
    );
    expect(await logFile.exists(), isTrue);
    final lines = (await logFile.readAsString())
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    expect(lines, hasLength(1));
    final snapshot = ContextLogSnapshot.fromJson(
      jsonDecode(lines.single) as Map<String, dynamic>,
    );
    expect(snapshot.conversationId, 'c1');
    expect(snapshot.model, 'gpt-4.1');
    expect(snapshot.messages, hasLength(2));
    expect(
      snapshot.messages.first.segments.first.source,
      ContextSource.systemPrompt,
    );
    expect(
      snapshot.messages.first.segments.last.source,
      ContextSource.memoryRules,
    );
    expect(snapshot.totalTokens, greaterThan(0));
  });

  test(
    'disabling waits for an in-flight write and releases the file',
    () async {
      final pathRequested = Completer<void>();
      final pathGate = Completer<void>();
      fakePathProvider
        ..pathRequested = pathRequested
        ..pathGate = pathGate;
      await ContextLogger.setEnabled(true);
      ContextLogger.logPrepared(
        apiMessages: const [
          {'role': 'user', 'content': 'queued context'},
        ],
        conversationId: 'c2',
        assistantName: 'Assistant',
        provider: 'provider',
        model: 'model',
      );
      await pathRequested.future;

      final disabled = ContextLogger.setEnabled(false);
      pathGate.complete();
      await disabled;

      final active = File(
        '${tempDir.path}/logs/${ContextLogger.activeFileName}',
      );
      expect(await active.readAsString(), contains('queued context'));
      await active.delete();
      expect(await active.exists(), isFalse);
    },
  );
}
