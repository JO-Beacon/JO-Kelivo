import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/models/backup.dart';
import 'package:Kelivo/core/services/backup/data_sync.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';

import 'generated/upstream_kelivo_schema3/schema_v3.dart' as upstream_v3;
import '../../database/generated_schema/schema_v3.dart' as jo_schema_v3;

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;

  @override
  Future<String?> getApplicationCachePath() async => '${root.path}/cache';

  @override
  Future<String?> getTemporaryPath() async => '${root.path}/tmp';
}

Future<String> _sha256(File file) async {
  return (await sha256.bind(file.openRead()).first).toString();
}

Future<File> _createUpstreamSchema3Zip(
  Directory root, {
  bool dropTombstone = false,
}) async {
  final databaseFile = File('${root.path}/upstream.sqlite');
  final database = upstream_v3.DatabaseAtV3(NativeDatabase(databaseFile));
  await database.customSelect('SELECT 1;').getSingle();
  await database.close();

  final createdAt = DateTime.utc(2026, 9, 22).microsecondsSinceEpoch;
  final raw = sqlite.sqlite3.open(databaseFile.path);
  try {
    raw.execute(
      'INSERT INTO conversation_rows '
      '(id, title, created_at, updated_at, version_selections_json) VALUES '
      "('upstream-conv', 'Upstream', $createdAt, $createdAt, '{}');",
    );
    raw.execute(
      'INSERT INTO message_rows '
      '(id, conversation_id, role, timestamp, message_order, sender_id, '
      'extras_json) VALUES '
      "('upstream-msg', 'upstream-conv', 'user', $createdAt, 0, "
      "'assistant-b', '{\"subagent\":true}');",
    );
    raw.execute(
      'INSERT INTO tombstone_rows (scope, entity_id, deleted_at, payload) '
      "VALUES ('conversation', 'deleted-upstream', $createdAt, '{}');",
    );
    raw.execute(
      'INSERT INTO message_part_rows '
      '(conversation_id, revision_id, ordinal, kind, payload, created_at, '
      'updated_at) VALUES '
      "('upstream-conv', 'upstream-msg', 0, 'text', "
      "'upstream answer', $createdAt, "
      '$createdAt);',
    );
    if (dropTombstone) {
      raw.execute('DROP TABLE tombstone_rows;');
    }
  } finally {
    raw.close();
  }

  final settingsFile = File('${root.path}/settings.json');
  await settingsFile.writeAsString('{}');
  final entries = <String, Map<String, Object>>{
    'settings.json': {
      'bytes': await settingsFile.length(),
      'sha256': await _sha256(settingsFile),
    },
    'database/kelivo.db': {
      'bytes': await databaseFile.length(),
      'sha256': await _sha256(databaseFile),
    },
  };
  final manifestFile = File('${root.path}/manifest.json');
  await manifestFile.writeAsString(
    jsonEncode({
      'format': 'kelivo-backup',
      'formatVersion': 2,
      'payloadKind': 'sqlite',
      'createdAtUtc': '2026-09-22T00:00:00.000Z',
      'appVersion': '1.3.0+79',
      'includeChats': true,
      'includeFiles': false,
      'secretsIncluded': true,
      'database': {
        'entry': 'database/kelivo.db',
        'schemaVersion': 3,
        'conversationCount': 1,
        'messageCount': 1,
      },
      'entries': entries,
    }),
  );

  final zipFile = File('${root.path}/upstream.zip');
  final encoder = ZipFileEncoder();
  encoder.create(zipFile.path);
  encoder.addFileSync(manifestFile, 'manifest.json');
  encoder.addFileSync(settingsFile, 'settings.json');
  encoder.addFileSync(databaseFile, 'database/kelivo.db');
  encoder.closeSync();
  return zipFile;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DataSync overwrite stages an upstream schema 3 archive', () async {
    final root = await Directory.systemTemp.createTemp(
      'kelivo_schema3_overwrite_',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root);
    addTearDown(() {
      PathProviderPlatform.instance = previousPathProvider;
    });

    final zipFile = await _createUpstreamSchema3Zip(root);
    final businessDatabase = AppDatabase(NativeDatabase.memory());
    final businessRepository = BusinessRepository(businessDatabase);
    final chatService = ChatService();
    try {
      await chatService.init();
      final dataSync = DataSync(
        chatService: chatService,
        businessRepository: businessRepository,
      );

      await dataSync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: true, includeFiles: false),
        mode: RestoreMode.overwrite,
      );

      final workspace = Directory('${root.path}/.kelivo_restore');
      final runs = await workspace
          .list(followLinks: false)
          .where((entity) => entity is Directory)
          .map((entity) => entity as Directory)
          .where((directory) {
            final name = directory.uri.pathSegments
                .where((segment) => segment.isNotEmpty)
                .last;
            return RegExp(r'^run_[a-f0-9]{32}$').hasMatch(name);
          })
          .toList();
      expect(runs, hasLength(1));
      final candidate = Directory('${runs.single.path}/candidate');
      final manifest =
          jsonDecode(
                await File('${candidate.path}/manifest.json').readAsString(),
              )
              as Map<String, dynamic>;
      final databaseInfo = manifest['database'] as Map<String, dynamic>;
      expect(databaseInfo['schemaVersion'], AppDatabase.currentSchemaVersion);

      final candidateDatabase = File('${candidate.path}/database/kelivo.db');
      final raw = sqlite.sqlite3.open(
        candidateDatabase.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(raw.userVersion, AppDatabase.currentSchemaVersion);
        final row = raw
            .select(
              'SELECT sender_id, extras_json, updated_at FROM message_rows '
              "WHERE id = 'upstream-msg';",
            )
            .single;
        expect(row['sender_id'], 'assistant-b');
        expect(row['extras_json'], '{"subagent":true}');
        expect(
          raw
              .select(
                "SELECT entity_id FROM tombstone_rows WHERE scope = 'conversation';",
              )
              .single['entity_id'],
          'deleted-upstream',
        );
      } finally {
        raw.close();
      }
    } finally {
      await chatService.close();
      await businessDatabase.close();
    }
  });

  test(
    'rejects a JO-AIClient historical schema 3 database in Kelivo import',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jo_schema3_in_kelivo_import_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProviderPlatform(root);
      addTearDown(() {
        PathProviderPlatform.instance = previousPathProvider;
      });

      final databaseFile = File('${root.path}/jo-schema3.sqlite');
      final database = jo_schema_v3.DatabaseAtV3(NativeDatabase(databaseFile));
      await database.customSelect('SELECT 1;').getSingle();
      await database.close();
      final settingsFile = File('${root.path}/settings.json');
      await settingsFile.writeAsString('{}');
      final entries = <String, Map<String, Object>>{
        'settings.json': {
          'bytes': await settingsFile.length(),
          'sha256': await _sha256(settingsFile),
        },
        'database/kelivo.db': {
          'bytes': await databaseFile.length(),
          'sha256': await _sha256(databaseFile),
        },
      };
      final manifestFile = File('${root.path}/manifest.json');
      await manifestFile.writeAsString(
        jsonEncode({
          'format': 'kelivo-backup',
          'formatVersion': 2,
          'payloadKind': 'sqlite',
          'createdAtUtc': '2026-09-24T00:00:00.000Z',
          'appVersion': '0.1.9+9',
          'includeChats': true,
          'includeFiles': false,
          'secretsIncluded': true,
          'database': {
            'entry': 'database/kelivo.db',
            'schemaVersion': 3,
            'conversationCount': 0,
            'messageCount': 0,
          },
          'entries': entries,
        }),
      );
      final zipFile = File('${root.path}/jo-schema3.zip');
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addFileSync(manifestFile, 'manifest.json');
      encoder.addFileSync(settingsFile, 'settings.json');
      encoder.addFileSync(databaseFile, 'database/kelivo.db');
      encoder.closeSync();

      final businessDatabase = AppDatabase(NativeDatabase.memory());
      final businessRepository = BusinessRepository(businessDatabase);
      final chatService = ChatService();
      try {
        final dataSync = DataSync(
          chatService: chatService,
          businessRepository: businessRepository,
        );
        await expectLater(
          dataSync.restoreFromLocalFile(
            zipFile,
            const WebDavConfig(includeChats: true, includeFiles: false),
            mode: RestoreMode.merge,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('kelivo_schema3_payload'),
            ),
          ),
        );
      } finally {
        await chatService.close();
        await businessDatabase.close();
      }
    },
  );

  test('rejects an incomplete upstream schema 3 payload', () async {
    final root = await Directory.systemTemp.createTemp(
      'kelivo_schema3_invalid_',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root);
    addTearDown(() {
      PathProviderPlatform.instance = previousPathProvider;
    });

    final zipFile = await _createUpstreamSchema3Zip(root, dropTombstone: true);
    final businessDatabase = AppDatabase(NativeDatabase.memory());
    final businessRepository = BusinessRepository(businessDatabase);
    final chatService = ChatService();
    try {
      await chatService.init();
      final dataSync = DataSync(
        chatService: chatService,
        businessRepository: businessRepository,
      );

      await expectLater(
        dataSync.restoreFromLocalFile(
          zipFile,
          const WebDavConfig(includeChats: true, includeFiles: false),
          mode: RestoreMode.merge,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('kelivo_schema3_payload'),
          ),
        ),
      );
    } finally {
      await chatService.close();
      await businessDatabase.close();
    }
  });

  test('DataSync imports an upstream Kelivo schema 3 archive', () async {
    final root = await Directory.systemTemp.createTemp(
      'kelivo_schema3_data_sync_',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root);
    addTearDown(() {
      PathProviderPlatform.instance = previousPathProvider;
    });

    final zipFile = await _createUpstreamSchema3Zip(root);
    final businessDatabase = AppDatabase(NativeDatabase.memory());
    final businessRepository = BusinessRepository(businessDatabase);
    final chatService = ChatService();
    try {
      await chatService.init();
      final dataSync = DataSync(
        chatService: chatService,
        businessRepository: businessRepository,
      );

      await dataSync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: true, includeFiles: false),
        mode: RestoreMode.merge,
      );

      expect(dataSync.lastMergeReport?.importedConversations, 1);
      expect(chatService.getConversation('upstream-conv')?.title, 'Upstream');
      expect(
        (await chatService.loadMessagesRange(
          'upstream-conv',
          start: 0,
          limit: 1,
        )).single.content,
        'upstream answer',
      );

      final liveDatabase = File('${root.path}/${AppDatabase.databaseFileName}');
      final raw = sqlite.sqlite3.open(
        liveDatabase.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(raw.userVersion, AppDatabase.currentSchemaVersion);
        final row = raw
            .select(
              'SELECT sender_id, extras_json, updated_at FROM message_rows '
              "WHERE id = 'upstream-msg';",
            )
            .single;
        expect(row['sender_id'], 'assistant-b');
        expect(row['extras_json'], '{"subagent":true}');
        expect(row['updated_at'], isNull);
        expect(
          raw
              .select(
                "SELECT entity_id FROM tombstone_rows WHERE scope = 'conversation';",
              )
              .single['entity_id'],
          'deleted-upstream',
        );
        expect(
          raw.select(
            'SELECT message_id FROM message_tree_edge_rows '
            "WHERE message_id = 'upstream-msg';",
          ),
          hasLength(1),
        );
      } finally {
        raw.close();
      }
    } finally {
      await chatService.close();
      await businessDatabase.close();
    }
  });
}
