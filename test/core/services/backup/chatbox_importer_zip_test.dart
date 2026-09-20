import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/business_restore_service.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/backup.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/services/backup/backup_cancel_token.dart';
import 'package:Kelivo/core/services/backup/chatbox_backup_archive.dart';
import 'package:Kelivo/core/services/backup/chatbox_importer.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

String _legacyId(String suffix) => 'chatbox_legacy_1_21_1_$suffix';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('ChatboxImporter ZIP v2', () {
    late Directory root;
    late AppDatabase database;
    late BusinessRepository businessRepository;
    late ChatDatabaseRepository chatRepository;
    late ChatService chatService;
    late File backup;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_chatbox_zip_db_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SharedPreferences.setMockInitialValues({});
      final databaseFile = File('${root.path}/kelivo.db');
      database = AppDatabase.open(file: databaseFile);
      businessRepository = BusinessRepository(database);
      chatRepository = ChatDatabaseRepository(
        database,
        databaseFile: databaseFile,
      );
      chatService = ChatService(existingRepository: chatRepository);
      backup = File('${root.path}/chatbox-backup.zip');
    });

    tearDown(() async {
      await chatService.close();
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<void> writeZip({
      Map<String, dynamic>? settings,
      Map<String, dynamic>? session,
      List<Map<String, dynamic>> resources = const [],
      int formatVersion = 2,
    }) async {
      await backup.writeAsBytes(
        _encodeChatboxZipV2(
          settings: settings,
          session: session,
          resources: resources,
          formatVersion: formatVersion,
        ),
        flush: true,
      );
    }

    test(
      'imports a ZIP v2 session with its image materialized locally',
      () async {
        final png = _pngBytes();
        await writeZip(
          settings: _settings(),
          session: _session(imageStorageKey: 'picture:test', withFork: true),
          resources: [
            _resource(
              id: 'resource-000001',
              storageKey: 'picture:test',
              bytes: png,
            ),
          ],
        );

        final result = await ChatboxImporter.importFromChatboxArchive(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        expect(result.providers, 1);
        expect(result.conversations, 1);

        final conversationId = _legacyId('default_assistant-1');
        final messages = await chatService.loadAllConversationMessages(
          conversationId,
        );
        final images = messages
            .expand((message) => message.parts)
            .whereType<ImagePart>()
            .toList();
        expect(images, hasLength(1));
        expect(
          images.single.unavailable,
          isFalse,
          reason: '随包带来的图片必须可用，不能显示成不可用框',
        );

        // 资源字节确实落在 upload/chatbox 下。
        final upload = Directory('${root.path}/upload/chatbox');
        expect(await upload.exists(), isTrue);
        final written = (await upload.list().toList())
            .whereType<File>()
            .toList();
        expect(written, isNotEmpty);
        expect(await written.first.readAsBytes(), png);

        // 资源必须登记成消息资产；否则会被后续无主文件清理删掉。
        final assetRows = await database
            .customSelect('SELECT COUNT(*) AS n FROM message_asset_rows;')
            .getSingle();
        expect(
          assetRows.read<int>('n'),
          greaterThan(0),
          reason: '导入的图片必须登记进 message_asset_rows',
        );
        final decoded = await ChatboxBackupArchive.readZipV2(
          bytes: await backup.readAsBytes(),
          stagingDir: Directory('${root.path}/verify_staging'),
          resourceDestDir: '${root.path}/verify_dest',
        );
        expect(decoded.stagedResourceFiles, hasLength(1));
      },
    );

    test('preserves Chatbox fork branches from a ZIP v2 session', () async {
      await writeZip(
        settings: _settings(),
        session: _session(imageStorageKey: 'unused', withFork: true),
      );

      await ChatboxImporter.importFromChatboxArchive(
        file: backup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final tree = await chatService.loadConversationTree(
        _legacyId('default_assistant-1'),
      );
      expect(tree, isNotNull);
      expect(tree!.isIntegrityValid, isTrue);
      expect(tree.activePath(), [
        _legacyId('message-1'),
        _legacyId('current-answer'),
      ]);
      expect(tree.branches, isNotEmpty);
    });

    test('rejects a corrupted ZIP and leaves no imported rows', () async {
      await writeZip(
        settings: _settings(),
        session: _session(imageStorageKey: 'unused', withFork: false),
      );

      final bytes = await backup.readAsBytes();
      bytes[bytes.length ~/ 2] = bytes[bytes.length ~/ 2] ^ 0xFF;
      await backup.writeAsBytes(bytes, flush: true);

      await expectLater(
        ChatboxImporter.importFromChatboxArchive(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        ),
        throwsA(anything),
      );

      expect(chatService.getAllCompleteConversations(), isEmpty);
      final upload = Directory('${root.path}/upload/chatbox');
      if (await upload.exists()) {
        expect(await upload.list().toList(), isEmpty);
      }
    });

    test('honours cancellation before writing anything', () async {
      await writeZip(
        settings: _settings(),
        session: _session(imageStorageKey: 'unused', withFork: false),
      );
      final token = BackupCancelToken()..cancel();

      await expectLater(
        ChatboxImporter.importFromChatboxArchive(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
          cancelToken: token,
        ),
        throwsA(isA<BackupCancelledException>()),
      );

      expect(chatService.getAllCompleteConversations(), isEmpty);
    });

    test('rejects an unsupported archive version', () async {
      await writeZip(
        settings: _settings(),
        session: _session(imageStorageKey: 'unused', withFork: false),
        formatVersion: 3,
      );

      await expectLater(
        ChatboxImporter.importFromChatboxArchive(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        ),
        throwsA(
          isA<ChatboxArchiveException>().having(
            (e) => e.message,
            'message',
            contains('formatVersion: 3'),
          ),
        ),
      );
    });

    test('keeps archive imports in their own assistant group', () async {
      await writeZip(
        settings: _settings(),
        session: _session(imageStorageKey: 'unused', withFork: false),
      );

      await ChatboxImporter.importFromChatboxArchive(
        file: backup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final exported = await BusinessRestoreService(
        businessRepository,
      ).exportSettings();
      final groups =
          jsonDecode(exported['assistant_tags_v1'] as String) as List;
      final names = groups
          .map((group) => (group as Map)['name'].toString())
          .toList();
      expect(
        names.any((name) => name.contains('\u22651.22')),
        isTrue,
        reason:
            '\u65b0\u7248\u4ea7\u7269\u5fc5\u987b\u843d\u5728\u81ea\u5df1\u7684\u5206\u7ec4\u91cc',
      );
      expect(
        names.any((name) => name.contains('<1.22')),
        isFalse,
        reason:
            '\u65b0\u7248\u4ea7\u7269\u4e0d\u5f97\u6df7\u8fdb\u65e7\u7248\u5206\u7ec4',
      );
    });

    test('refuses overwrite when the archive carries no sessions', () async {
      await writeZip(settings: _settings());

      await expectLater(
        ChatboxImporter.importFromChatboxArchive(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        ),
        throwsA(isA<ChatboxImportException>()),
      );
    });
  });
}

Uint8List _pngBytes() => Uint8List.fromList(
  base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
  ),
);

Map<String, dynamic> _settings() => {
  'providers': {
    'openai': {
      'apiKey': 'chatbox-secret',
      'apiHost': 'https://api.example.test',
      'apiPath': '/v1/chat/completions',
      'models': [
        {'modelId': 'gpt-test'},
      ],
    },
  },
};

Map<String, dynamic> _session({
  required String imageStorageKey,
  required bool withFork,
}) => {
  'id': 'assistant-1',
  'name': 'Chatbox assistant',
  'settings': {'provider': 'openai', 'modelId': 'gpt-test', 'temperature': 0.5},
  'messages': [
    {'id': 'system-1', 'role': 'system', 'content': 'Imported system prompt'},
    {
      'id': 'message-1',
      'role': 'user',
      'contentParts': [
        {'type': 'text', 'text': 'Hello'},
        if (imageStorageKey != 'unused')
          {'type': 'image', 'storageKey': imageStorageKey},
      ],
      'aiProvider': 'openai',
      'timestamp': 1784332800000,
    },
    if (withFork)
      {
        'id': 'current-answer',
        'role': 'assistant',
        'content': 'Current answer',
        'timestamp': 1784332801000,
      },
  ],
  'threads': <dynamic>[],
  if (withFork)
    'messageForksHash': {
      'message-1': {
        'position': 1,
        'lists': [
          {
            'id': 'alternative',
            'messages': [
              {
                'id': 'alternative-answer',
                'role': 'assistant',
                'content': 'Alternative answer',
                'timestamp': 1784332800500,
              },
            ],
          },
          {'id': 'active', 'messages': <dynamic>[]},
        ],
        'createdAt': 1784332800000,
      },
    },
};

Map<String, dynamic> _resource({
  required String id,
  required String storageKey,
  required List<int> bytes,
}) {
  return {
    'id': id,
    'storageKey': storageKey,
    'path': 'sessions/assistant-1/resources/$id.png',
    'bytes': bytes,
  };
}

Uint8List _encodeChatboxZipV2({
  Map<String, dynamic>? settings,
  Map<String, dynamic>? session,
  List<Map<String, dynamic>> resources = const [],
  int formatVersion = 2,
}) {
  final files = <String, List<int>>{};
  Map<String, dynamic>? settingsDesc;
  if (settings != null) {
    final bytes = utf8.encode(jsonEncode(settings));
    files['settings.json'] = bytes;
    settingsDesc = _descriptor('settings.json', bytes);
  }

  final sessionEntries = <Map<String, dynamic>>[];
  if (session != null) {
    final bytes = utf8.encode(jsonEncode(session));
    const path = 'sessions/assistant-1/session.json';
    files[path] = bytes;
    sessionEntries.add({
      ..._descriptor(path, bytes),
      'id': session['id'],
      'meta': {
        'id': session['id'],
        'name': session['name'],
        'starred': false,
        'sortOrder': 1,
        'createdAt': 1,
      },
      'resourceIds': [for (final resource in resources) resource['id']],
    });
  }

  final resourceEntries = <Map<String, dynamic>>[];
  for (final resource in resources) {
    final path = resource['path'] as String;
    final bytes = resource['bytes'] as List<int>;
    files[path] = bytes;
    resourceEntries.add({
      ..._descriptor(path, bytes),
      'id': resource['id'],
      'originalStorageKeys': [resource['storageKey']],
      'sessionIds': ['assistant-1'],
      'scope': 'session',
      'encoding': resource['encoding'] ?? 'data-url-base64',
      'mimeType': resource['mimeType'] ?? 'image/png',
      'kind': resource['kind'] ?? 'image',
    });
  }

  final manifest = <String, dynamic>{
    'format': 'chatbox-backup',
    'formatVersion': formatVersion,
    'exportedAt': '2026-07-18T00:00:00.000Z',
    'application': {'name': 'Chatbox', 'version': '1.22.0', 'platform': 'test'},
    'exportItems': [
      if (settings != null) 'setting',
      if (session != null) 'conversations',
    ],
    'data': {if (settingsDesc != null) 'settings': settingsDesc},
    'sessions': sessionEntries,
    'resources': resourceEntries,
    'warnings': <dynamic>[],
    'stats': {
      'sessionCount': sessionEntries.length,
      'resourceCount': resourceEntries.length,
      'deduplicatedResourceCount': 0,
      'warningCount': 0,
    },
  };
  files['manifest.json'] = utf8.encode(jsonEncode(manifest));
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

Map<String, dynamic> _descriptor(String path, List<int> bytes) => {
  'path': path,
  'size': bytes.length,
  'checksum': {
    'algorithm': 'sha256',
    'value': sha256.convert(bytes).toString(),
  },
};
