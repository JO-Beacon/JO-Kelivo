import 'dart:convert';
import 'dart:io';

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
import 'package:Kelivo/core/models/backup_task_progress.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/models/conversation.dart';
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

Map<String, dynamic> _chatboxFixture() => {
  '__exported_at': '2026-07-18T00:00:00.000Z',
  'settings': {
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
  },
  'chat-sessions-list': [
    {'id': 'assistant-1', 'name': 'Chatbox assistant', 'starred': true},
  ],
  'session:assistant-1': {
    'settings': {
      'provider': 'openai',
      'modelId': 'gpt-test',
      'temperature': 0.5,
    },
    'messages': [
      {'id': 'system-1', 'role': 'system', 'content': 'Imported system prompt'},
      {
        'id': 'message-1',
        'role': 'user',
        'content': 'Hello',
        'aiProvider': 'openai',
        'timestamp': 1784332800000,
        'contentParts': [
          {'type': 'text', 'text': 'Hello'},
          {'type': 'image', 'url': 'https://example.com/pic.png'},
        ],
        'files': [
          {
            'url': 'https://example.com/notes.pdf',
            'name': 'notes.pdf',
            'fileType': 'application/pdf',
          },
        ],
      },
    ],
    'threads': <dynamic>[],
  },
};

String _legacyId(String suffix) => 'chatbox_legacy_1_21_1_$suffix';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('ChatboxImporter SQLite business patch', () {
    late Directory root;
    late AppDatabase database;
    late BusinessRepository businessRepository;
    late ChatService chatService;
    late File backup;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kelivo_chatbox_db_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SharedPreferences.setMockInitialValues({});
      final databaseFile = File('${root.path}/kelivo.db');
      database = AppDatabase.open(file: databaseFile);
      businessRepository = BusinessRepository(database);
      chatService = ChatService(
        existingRepository: ChatDatabaseRepository(
          database,
          databaseFile: databaseFile,
        ),
      );
      backup = await File(
        '${root.path}/chatbox.json',
      ).writeAsString(jsonEncode(_chatboxFixture()), flush: true);
    });

    tearDown(() async {
      await chatService.close();
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'writes providers, assistants, groups, and relationships to SQLite',
      () async {
        final replacedUpload = await File(
          '${root.path}/upload/replace.txt',
        ).create(recursive: true);
        final result = await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        expect(result.providers, 1);
        expect(result.assistants, 1);
        expect(result.conversations, 1);
        expect(result.messages, 1);
        final exported = await BusinessRestoreService(
          businessRepository,
        ).exportSettings();
        final providers =
            jsonDecode(exported['provider_configs_v1'] as String) as Map;
        expect(
          (providers[_legacyId('provider_openai')] as Map)['apiKey'],
          'chatbox-secret',
        );
        expect(
          (providers[_legacyId('provider_openai')] as Map)['name'],
          'OpenAI',
        );
        expect(exported['providers_order_v1'], [_legacyId('provider_openai')]);
        expect(exported['assistants_v1'], contains(_legacyId('assistant-1')));
        final assistants =
            jsonDecode(exported['assistants_v1'] as String) as List;
        expect(
          (assistants.single as Map)['chatModelProvider'],
          _legacyId('provider_openai'),
        );
        expect(exported['assistant_tags_v1'], contains('Chatbox 导入（<1.22）'));
        expect(
          exported['assistant_tag_map_v1'],
          contains(_legacyId('assistant-1')),
        );
        expect(chatService.getAllConversations(), hasLength(1));
        expect(
          (await chatService.loadMessages(
            _legacyId('default_assistant-1'),
          )).single.providerId,
          _legacyId('provider_openai'),
        );
        expect(await replacedUpload.exists(), isFalse);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('provider_configs_v1'), isNull);
        expect(prefs.getString('assistants_v1'), isNull);
        expect(prefs.getString('assistant_tags_v1'), isNull);
      },
    );

    test(
      'maps Chatbox starred sessions to an ordered assistant group without pinning conversations',
      () async {
        final fixture = _chatboxFixture();
        const sessionIds = [
          'starred-old',
          'regular-old',
          'starred-new',
          'regular-new',
        ];
        fixture['chat-sessions-list'] = [
          {'id': sessionIds[0], 'name': 'Starred old', 'starred': true},
          {'id': sessionIds[1], 'name': 'Regular old', 'starred': false},
          {'id': sessionIds[2], 'name': 'Starred new', 'starred': true},
          {'id': sessionIds[3], 'name': 'Regular new', 'starred': false},
        ];
        for (final id in sessionIds) {
          fixture['session:$id'] = {
            'settings': {'provider': 'openai', 'modelId': 'gpt-test'},
            'messages': const <dynamic>[],
            'threads': const <dynamic>[],
          };
        }
        await backup.writeAsString(jsonEncode(fixture), flush: true);

        await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        final exported = await BusinessRestoreService(
          businessRepository,
        ).exportSettings();
        final assistants =
            jsonDecode(exported['assistants_v1'] as String) as List;
        expect(assistants.map((item) => (item as Map)['id']).toList(), [
          _legacyId('starred-old'),
          _legacyId('starred-new'),
          _legacyId('regular-new'),
          _legacyId('regular-old'),
        ]);

        final groups =
            jsonDecode(exported['assistant_tags_v1'] as String) as List;
        expect(groups.map((group) => (group as Map)['name']).toList(), [
          'Chatbox 导入（<1.22）·置顶',
          'Chatbox 导入（<1.22）',
        ]);
        final starredGroupId = (groups.first as Map)['id'];
        final regularGroupId = (groups.last as Map)['id'];
        final assignment =
            jsonDecode(exported['assistant_tag_map_v1'] as String) as Map;
        expect(assignment[_legacyId('starred-old')], starredGroupId);
        expect(assignment[_legacyId('starred-new')], starredGroupId);
        expect(assignment[_legacyId('regular-old')], regularGroupId);
        expect(assignment[_legacyId('regular-new')], regularGroupId);
        expect(
          chatService.getAllConversations().every((c) => !c.isPinned),
          isTrue,
        );
      },
    );

    test(
      'imports custom provider metadata without using its source ID as name',
      () async {
        final fixture = _chatboxFixture();
        final settings = Map<String, dynamic>.from(fixture['settings'] as Map);
        final providers = Map<String, dynamic>.from(
          settings['providers'] as Map,
        );
        providers['my-gateway'] = {
          'apiKey': 'custom-secret',
          'apiHost': 'https://gateway.example.test',
          'models': [
            {'modelId': 'custom-model'},
          ],
        };
        settings['providers'] = providers;
        settings['customProviders'] = [
          {'id': 'my-gateway', 'name': '我的网关', 'type': 'openai'},
        ];
        fixture['settings'] = settings;
        final session = Map<String, dynamic>.from(
          fixture['session:assistant-1'] as Map,
        );
        session['settings'] = {
          ...(session['settings'] as Map),
          'provider': 'my-gateway',
          'modelId': 'custom-model',
        };
        final messages = List<dynamic>.from(session['messages'] as List);
        messages[1] = {...(messages[1] as Map), 'aiProvider': 'my-gateway'};
        session['messages'] = messages;
        fixture['session:assistant-1'] = session;
        await backup.writeAsString(jsonEncode(fixture), flush: true);

        await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        final exported = await BusinessRestoreService(
          businessRepository,
        ).exportSettings();
        final providersOut =
            jsonDecode(exported['provider_configs_v1'] as String) as Map;
        expect(
          (providersOut[_legacyId('provider_my-gateway')] as Map)['name'],
          '我的网关',
        );
        expect(providersOut.keys, contains(_legacyId('provider_openai')));
        final assistants =
            jsonDecode(exported['assistants_v1'] as String) as List;
        expect(
          (assistants.single as Map)['chatModelProvider'],
          _legacyId('provider_my-gateway'),
        );
        expect(
          (await chatService.loadMessages(
            _legacyId('default_assistant-1'),
          )).single.providerId,
          _legacyId('provider_my-gateway'),
        );
      },
    );

    test(
      'imports orphan provider references into a separate disabled group',
      () async {
        final fixture = _chatboxFixture();
        final session = Map<String, dynamic>.from(
          fixture['session:assistant-1'] as Map,
        );
        session['settings'] = {
          ...(session['settings'] as Map),
          'provider': 'removed-provider',
          'modelId': 'removed-model',
        };
        final messages = List<dynamic>.from(session['messages'] as List);
        messages[1] = {
          ...(messages[1] as Map),
          'aiProvider': 'removed-provider',
        };
        session['messages'] = messages;
        fixture['session:assistant-1'] = session;
        await backup.writeAsString(jsonEncode(fixture), flush: true);

        await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        final exported = await BusinessRestoreService(
          businessRepository,
        ).exportSettings();
        final providers =
            jsonDecode(exported['provider_configs_v1'] as String) as Map;
        final removed =
            providers[_legacyId('provider_removed-provider')] as Map;
        expect(removed['name'], 'removed-provider');
        expect(removed['enabled'], isFalse);
        expect(removed['apiKey'], isEmpty);
        expect(
          (await chatService.loadMessages(
            _legacyId('default_assistant-1'),
          )).single.providerId,
          _legacyId('provider_removed-provider'),
        );

        final groups =
            jsonDecode(exported['provider_groups_v1'] as String) as List;
        expect(groups.map((group) => (group as Map)['name']).toList(), [
          'Chatbox 导入（<1.22）',
          'Chatbox 导入（<1.22）·已删除',
        ]);
        final groupByName = <String, String>{
          for (final group in groups)
            (group as Map)['name'].toString(): group['id'].toString(),
        };
        final assignment =
            jsonDecode(exported['provider_group_map_v1'] as String) as Map;
        expect(
          assignment[_legacyId('provider_openai')],
          groupByName['Chatbox 导入（<1.22）'],
        );
        expect(
          assignment[_legacyId('provider_removed-provider')],
          groupByName['Chatbox 导入（<1.22）·已删除'],
        );
      },
    );

    test(
      'puts configured providers with only an unknown ID into the deleted group',
      () async {
        final fixture = _chatboxFixture();
        final settings = Map<String, dynamic>.from(fixture['settings'] as Map);
        final providers = Map<String, dynamic>.from(
          settings['providers'] as Map,
        );
        providers['id-only-provider'] = {
          'apiKey': 'orphan-secret',
          'apiHost': 'https://orphan.example.test',
        };
        settings['providers'] = providers;
        fixture['settings'] = settings;
        await backup.writeAsString(jsonEncode(fixture), flush: true);

        await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        final exported = await BusinessRestoreService(
          businessRepository,
        ).exportSettings();
        final providersOut =
            jsonDecode(exported['provider_configs_v1'] as String) as Map;
        expect(
          (providersOut[_legacyId('provider_id-only-provider')] as Map)['name'],
          'id-only-provider',
        );

        final groups =
            jsonDecode(exported['provider_groups_v1'] as String) as List;
        expect(groups.map((group) => (group as Map)['name']).toList(), [
          'Chatbox 导入（<1.22）',
          'Chatbox 导入（<1.22）·已删除',
        ]);
        final groupByName = <String, String>{
          for (final group in groups)
            (group as Map)['name'].toString(): group['id'].toString(),
        };
        final assignment =
            jsonDecode(exported['provider_group_map_v1'] as String) as Map;
        expect(
          assignment[_legacyId('provider_id-only-provider')],
          groupByName['Chatbox 导入（<1.22）·已删除'],
        );
        expect(
          assignment[_legacyId('provider_openai')],
          groupByName['Chatbox 导入（<1.22）'],
        );
      },
    );

    test('imports used Chatbox AI as disabled provider', () async {
      final fixture = _chatboxFixture();
      final settings = Map<String, dynamic>.from(fixture['settings'] as Map);
      final providers = Map<String, dynamic>.from(settings['providers'] as Map);
      providers['chatbox-ai'] = {
        'apiKey': 'license-like-value',
        'models': [
          {'modelId': 'chatbox-model'},
        ],
      };
      settings['providers'] = providers;
      fixture['settings'] = settings;
      final session = Map<String, dynamic>.from(
        fixture['session:assistant-1'] as Map,
      );
      session['settings'] = {
        ...(session['settings'] as Map),
        'provider': 'chatbox-ai',
        'modelId': 'chatbox-model',
      };
      fixture['session:assistant-1'] = session;
      await backup.writeAsString(jsonEncode(fixture), flush: true);

      await ChatboxImporter.importFromChatbox(
        file: backup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final exported = await BusinessRestoreService(
        businessRepository,
      ).exportSettings();
      final providersOut =
          jsonDecode(exported['provider_configs_v1'] as String) as Map;
      final chatboxAi = providersOut[_legacyId('provider_chatbox-ai')] as Map;
      expect(chatboxAi['name'], 'Chatbox AI');
      expect(chatboxAi['enabled'], isFalse);
      expect(chatboxAi['apiKey'], isEmpty);
      expect(chatboxAi['baseUrl'], 'https://api.openai.com/v1');
      final assistants =
          jsonDecode(exported['assistants_v1'] as String) as List;
      expect(
        (assistants.single as Map)['chatModelProvider'],
        _legacyId('provider_chatbox-ai'),
      );
      expect((assistants.single as Map)['chatModelId'], 'chatbox-model');
    });

    test('does not import unused Chatbox AI provider', () async {
      final fixture = _chatboxFixture();
      final settings = Map<String, dynamic>.from(fixture['settings'] as Map);
      final providers = Map<String, dynamic>.from(settings['providers'] as Map);
      providers['chatbox-ai'] = {'apiKey': 'unused'};
      settings['providers'] = providers;
      fixture['settings'] = settings;
      await backup.writeAsString(jsonEncode(fixture), flush: true);

      await ChatboxImporter.importFromChatbox(
        file: backup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final exported = await BusinessRestoreService(
        businessRepository,
      ).exportSettings();
      final providersOut =
          jsonDecode(exported['provider_configs_v1'] as String) as Map;
      expect(
        providersOut.keys,
        isNot(contains(_legacyId('provider_chatbox-ai'))),
      );
    });

    test('imports Chatbox message forks as active-tree branches', () async {
      final fixture = _chatboxFixture();
      final session = Map<String, dynamic>.from(
        fixture['session:assistant-1'] as Map,
      );
      session['messageForksHash'] = {
        'message-1': {
          'position': 0,
          'lists': [
            {
              'id': 'alternative',
              'messages': [
                {
                  'id': 'fork-answer',
                  'role': 'assistant',
                  'content': 'Alternative answer',
                  'aiProvider': 'openai',
                  'timestamp': 1784332801000,
                },
              ],
            },
          ],
        },
      };
      fixture['session:assistant-1'] = session;
      await backup.writeAsString(jsonEncode(fixture), flush: true);

      final result = await ChatboxImporter.importFromChatbox(
        file: backup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      expect(result.conversations, 1);
      expect(result.messages, 2);
      final tree = await chatService.loadConversationTree(
        _legacyId('default_assistant-1'),
      );
      expect(tree, isNotNull);
      expect(tree!.activePath(), [_legacyId('message-1')]);
      expect(
        tree.edges[_legacyId('fork-answer')]?.parentMessageId,
        _legacyId('message-1'),
      );
      final branchId = tree.branches.keys.singleWhere(
        (id) => id == _legacyId('fork_${_legacyId('message-1')}_alternative'),
      );
      expect(tree.branchPath(branchId), [
        _legacyId('message-1'),
        _legacyId('fork-answer'),
      ]);
    });

    test(
      'preserves nested fork selections from the legacy tree archive',
      () async {
        final fixture = _chatboxFixture();
        final session = Map<String, dynamic>.from(
          fixture['session:assistant-1'] as Map,
        );
        session['messages'] = [
          ...(session['messages'] as List),
          {
            'id': 'current-answer',
            'role': 'assistant',
            'content': 'Current answer',
            'timestamp': 1784332801000,
          },
        ];
        session['messageForksHash'] = {
          'message-1': {
            'position': 1,
            'lists': [
              {
                'id': 'outer-alternative',
                'messages': [
                  {
                    'id': 'outer-answer',
                    'role': 'assistant',
                    'content': 'Outer answer',
                    'timestamp': 1784332801000,
                  },
                ],
              },
              {'id': 'outer-active', 'messages': []},
            ],
            'createdAt': 1784332800000,
          },
          'outer-answer': {
            'position': 1,
            'lists': [
              {
                'id': 'nested-alternative',
                'messages': [
                  {
                    'id': 'nested-answer',
                    'role': 'assistant',
                    'content': 'Nested answer',
                    'timestamp': 1784332802000,
                  },
                ],
              },
              {'id': 'nested-active', 'messages': []},
            ],
            'createdAt': 1784332801000,
          },
        };
        fixture['session:assistant-1'] = session;
        await backup.writeAsString(jsonEncode(fixture), flush: true);

        await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        final tree = await chatService.loadConversationTree(
          _legacyId('default_assistant-1'),
        );
        expect(tree, isNotNull);
        expect(tree!.activePath(), [
          _legacyId('message-1'),
          _legacyId('current-answer'),
        ]);
        final outerBranch =
            tree.branches[_legacyId(
              'fork_${_legacyId('message-1')}_outer-alternative',
            )];
        final nestedBranch =
            tree.branches[_legacyId(
              'fork_${_legacyId('outer-answer')}_nested-alternative',
            )];
        expect(outerBranch, isNotNull);
        expect(nestedBranch, isNotNull);
        expect(tree.branchPath(outerBranch!.id), [
          _legacyId('message-1'),
          _legacyId('outer-answer'),
        ]);
        expect(tree.branchPath(nestedBranch!.id), [
          _legacyId('message-1'),
          _legacyId('outer-answer'),
          _legacyId('nested-answer'),
        ]);
        expect(
          tree.branchSelections[_legacyId('message-1')],
          _legacyId('root_${_legacyId('default_assistant-1')}'),
        );
        expect(
          tree.branchSelections[_legacyId('outer-answer')],
          outerBranch.id,
        );
      },
    );

    test(
      'does not persist a selection for a single-list legacy fork record',
      () async {
        final fixture = _chatboxFixture();
        final session = Map<String, dynamic>.from(
          fixture['session:assistant-1'] as Map,
        );
        session['messages'] = [
          ...(session['messages'] as List),
          {
            'id': 'current-answer',
            'role': 'assistant',
            'content': 'Current answer',
            'timestamp': 1784332801000,
          },
        ];
        session['messageForksHash'] = {
          'message-1': {
            'position': 0,
            'lists': [
              {
                'id': 'legacy-linear-record',
                'messages': [
                  {
                    'id': 'alternative-answer',
                    'role': 'assistant',
                    'content': 'Alternative answer',
                    'timestamp': 1784332801000,
                  },
                ],
              },
            ],
          },
        };
        fixture['session:assistant-1'] = session;
        await backup.writeAsString(jsonEncode(fixture), flush: true);

        await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        final tree = await chatService.loadConversationTree(
          _legacyId('default_assistant-1'),
        );
        expect(tree, isNotNull);
        expect(tree!.branchSelections, isEmpty);
        expect(tree.isIntegrityValid, isTrue);
      },
    );

    test(
      'rolls back all business rows when a later table write fails',
      () async {
        final retainedUpload = await File(
          '${root.path}/upload/keep.txt',
        ).create(recursive: true);
        await retainedUpload.writeAsString('keep');
        await chatService.restoreConversation(
          Conversation(id: 'local-chat', title: 'Keep chat'),
          [
            ChatMessage(
              id: 'local-message',
              role: 'user',
              content: 'Keep message',
              conversationId: 'local-chat',
            ),
          ],
        );
        await BusinessRestoreService(businessRepository).overwrite({
          'provider_configs_v1': jsonEncode({
            'local': {'id': 'local', 'apiKey': 'keep-me'},
          }),
          'providers_order_v1': ['local'],
          'assistants_v1': jsonEncode([
            {'id': 'local-assistant', 'name': 'Keep me'},
          ]),
        });
        final before = await BusinessRestoreService(
          businessRepository,
        ).exportSettings();
        await database.customStatement(
          'CREATE TRIGGER fail_chatbox_assistant_insert '
          'BEFORE INSERT ON assistant_rows BEGIN '
          "SELECT RAISE(ABORT, 'injected failure'); END;",
        );

        await expectLater(
          ChatboxImporter.importFromChatbox(
            file: backup,
            mode: RestoreMode.overwrite,
            businessRepository: businessRepository,
            chatService: chatService,
          ),
          throwsA(anything),
        );

        expect(
          await BusinessRestoreService(businessRepository).exportSettings(),
          before,
        );
        expect(chatService.getConversation('local-chat'), isNotNull);
        expect(
          await chatService.loadMessages('local-chat'),
          contains(
            isA<ChatMessage>()
                .having((message) => message.id, 'id', 'local-message')
                .having(
                  (message) => message.content,
                  'content',
                  'Keep message',
                ),
          ),
        );
        expect(await retainedUpload.exists(), isTrue);

        final reloaded = ChatService(
          existingRepository: ChatDatabaseRepository(
            database,
            databaseFile: File('${root.path}/kelivo.db'),
          ),
        );
        await reloaded.init();
        try {
          expect(reloaded.getConversation('local-chat'), isNotNull);
          expect(
            await reloaded.loadMessages('local-chat'),
            contains(
              isA<ChatMessage>().having(
                (message) => message.id,
                'id',
                'local-message',
              ),
            ),
          );
        } finally {
          await reloaded.close();
        }
      },
    );

    test('merge parses every session before writing any chat rows', () async {
      final businessBefore = await BusinessRestoreService(
        businessRepository,
      ).exportSettings();
      final malformed = _chatboxFixture();
      (malformed['chat-sessions-list'] as List).add({
        'id': 'broken-assistant',
        'name': 'Broken',
        'starred': 'not-a-bool',
      });
      malformed['session:broken-assistant'] = {
        'messages': <dynamic>[],
        'threads': <dynamic>[],
      };
      await backup.writeAsString(jsonEncode(malformed), flush: true);

      await expectLater(
        ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.merge,
          businessRepository: businessRepository,
          chatService: chatService,
        ),
        throwsA(anything),
      );

      expect(
        chatService.getConversation(_legacyId('default_assistant-1')),
        isNull,
      );
      expect(
        await BusinessRestoreService(businessRepository).exportSettings(),
        businessBefore,
      );
    });

    test('merge keeps same-id messages when content differs', () async {
      await chatService.restoreConversation(
        Conversation(id: _legacyId('default_assistant-1'), title: 'Existing'),
        <ChatMessage>[
          ChatMessage(
            id: _legacyId('message-1'),
            role: 'user',
            content: 'Hello',
            conversationId: _legacyId('default_assistant-1'),
          ),
        ],
      );

      final result = await ChatboxImporter.importFromChatbox(
        file: backup,
        mode: RestoreMode.merge,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      expect(result.conversations, 1);
      expect(result.messages, 1);
      final messages = await chatService.loadAllConversationMessages(
        _legacyId('default_assistant-1'),
      );
      expect(messages, hasLength(2));
      expect(
        messages.map((message) => message.content),
        containsAll(<String>['Hello', 'Hello']),
      );
    });

    test(
      'overwrite preserves a moved Chatbox conversation and creates placed copy',
      () async {
        await chatService.restoreConversation(
          Conversation(
            id: _legacyId('default_assistant-1'),
            title: 'Moved locally',
            assistantId: 'local-assistant',
          ),
          <ChatMessage>[
            ChatMessage(
              id: 'local-only',
              role: 'user',
              content: 'Keep me',
              conversationId: _legacyId('default_assistant-1'),
            ),
          ],
        );

        await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        expect(
          chatService.getConversation(_legacyId('default_assistant-1')),
          isNotNull,
        );
        final placed = chatService.getConversation(
          '${_legacyId('default_assistant-1')}_placed',
        );
        expect(placed, isNotNull);
        final placedMessages = await chatService.loadAllConversationMessages(
          placed!.id,
        );
        expect(placedMessages, isNotEmpty);
        expect(chatService.getAllConversations(), hasLength(2));

        await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        expect(
          chatService.getAllConversations(),
          hasLength(2),
          reason: '重复完全覆盖不得生成第三份 _placed 会话',
        );
        final placedMessagesAfterRepeat = await chatService
            .loadAllConversationMessages(placed.id);
        expect(placedMessagesAfterRepeat, hasLength(placedMessages.length));
      },
    );

    test(
      'merge keeps same-id content conflicts in the same conversation',
      () async {
        await chatService.restoreConversation(
          Conversation(id: _legacyId('default_assistant-1'), title: 'Existing'),
          <ChatMessage>[
            ChatMessage(
              id: 'local-revision',
              role: 'user',
              content: 'Local revision',
              conversationId: _legacyId('default_assistant-1'),
              groupId: _legacyId('message-1'),
              version: 0,
            ),
          ],
        );

        final result = await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.merge,
          businessRepository: businessRepository,
          chatService: chatService,
        );

        expect(result.conversations, 1);
        expect(result.messages, 1);
        expect(chatService.getAllConversations(), hasLength(1));
        final messages = await chatService.loadAllConversationMessages(
          _legacyId('default_assistant-1'),
        );
        expect(messages, hasLength(2));
        expect(
          messages.map((message) => message.content),
          containsAll(<String>['Local revision', 'Hello']),
        );
      },
    );

    test(
      'cancellation stops the Chatbox worker before any database write',
      () async {
        final cancelToken = BackupCancelToken();
        addTearDown(cancelToken.dispose);
        cancelToken.cancel();

        await expectLater(
          ChatboxImporter.importFromChatbox(
            file: backup,
            mode: RestoreMode.overwrite,
            businessRepository: businessRepository,
            chatService: chatService,
            cancelToken: cancelToken,
          ),
          throwsA(isA<BackupCancelledException>()),
        );
        expect(chatService.getAllConversations(), isEmpty);
      },
    );

    test('fails closed when chat and business repositories differ', () async {
      await chatService.restoreConversation(
        Conversation(id: 'local-chat', title: 'Keep chat'),
        const <ChatMessage>[],
      );
      final otherFile = File('${root.path}/other.db');
      final otherDatabase = AppDatabase.open(file: otherFile);
      final otherBusinessRepository = BusinessRepository(otherDatabase);
      try {
        final businessBefore = await BusinessRestoreService(
          otherBusinessRepository,
        ).exportSettings();
        await expectLater(
          ChatboxImporter.importFromChatbox(
            file: backup,
            mode: RestoreMode.overwrite,
            businessRepository: otherBusinessRepository,
            chatService: chatService,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'chat_business_database_mismatch',
            ),
          ),
        );

        expect(chatService.getConversation('local-chat'), isNotNull);
        expect(
          chatService.getConversation(_legacyId('default_assistant-1')),
          isNull,
        );
        expect(
          await BusinessRestoreService(
            otherBusinessRepository,
          ).exportSettings(),
          businessBefore,
        );
      } finally {
        await otherDatabase.close();
      }
    });

    test('Chatbox reasoning survives as reasoningText', () async {
      final reasoningBackup = await File('${root.path}/chatbox_reasoning.json')
          .writeAsString(
            jsonEncode({
              '__exported_at': '2026-07-18T00:00:00.000Z',
              'settings': {
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
              },
              'chat-sessions-list': [
                {'id': 'assistant-r', 'name': 'Reasoning', 'starred': false},
              ],
              'session:assistant-r': {
                'settings': {'provider': 'openai', 'modelId': 'gpt-test'},
                'messages': [
                  {
                    'id': 'user-r',
                    'role': 'user',
                    'content': 'Why?',
                    'timestamp': 1784332800000,
                    'contentParts': [
                      {'type': 'text', 'text': 'Why?'},
                    ],
                  },
                  {
                    'id': 'assistant-r-msg',
                    'role': 'assistant',
                    'content': 'Because.',
                    'timestamp': 1784332801000,
                    'contentParts': [
                      {'type': 'reasoning', 'text': 'first thought'},
                      {'type': 'reasoning', 'text': 'second thought'},
                      {'type': 'text', 'text': 'Because.'},
                    ],
                  },
                ],
                'threads': <dynamic>[],
              },
            }),
            flush: true,
          );

      await ChatboxImporter.importFromChatbox(
        file: reasoningBackup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final messages = await chatService.loadMessages(
        _legacyId('default_assistant-r'),
      );
      final assistant = messages.singleWhere(
        (m) => m.id == _legacyId('assistant-r-msg'),
      );
      expect(assistant.reasoningText, 'first thought\nsecond thought');
      expect(assistant.content, 'Because.');
      expect(
        assistant.parts.whereType<ReasoningPart>().single.text,
        'first thought\nsecond thought',
      );
    });

    test('preserves legacy reasoning and storage-backed attachments', () async {
      final legacyBackup = await File('${root.path}/chatbox_legacy_fields.json')
          .writeAsString(
            jsonEncode({
              ..._chatboxFixture(),
              'session:assistant-1': {
                'settings': {'provider': 'openai', 'modelId': 'gpt-test'},
                'messages': [
                  {
                    'id': 'legacy-fields',
                    'role': 'assistant',
                    'model': 'OpenAI (gpt-legacy)',
                    'content': 'Legacy answer',
                    'reasoningContent': 'Legacy thought',
                    'timestamp': 1784332800000,
                    'files': [
                      {
                        'id': 'stored-file',
                        'name': 'report.pdf',
                        'fileType': 'application/pdf',
                        'storageKey': 'file:report.pdf',
                      },
                    ],
                    'pictures': [
                      {'storageKey': 'picture:answer.png'},
                    ],
                  },
                ],
                'threads': <dynamic>[],
              },
            }),
            flush: true,
          );

      await ChatboxImporter.importFromChatbox(
        file: legacyBackup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final message = (await chatService.loadMessages(
        _legacyId('default_assistant-1'),
      )).single;
      expect(message.modelId, 'gpt-legacy');
      expect(message.reasoningText, 'Legacy thought');
      expect(message.content, 'Legacy answer');
      final filePart = message.parts.whereType<FilePart>().single;
      expect(filePart.uri, 'file:report.pdf');
      expect(filePart.unavailable, isTrue);
      final imagePart = message.parts.whereType<ImagePart>().single;
      expect(imagePart.uri, 'picture:answer.png');
      expect(imagePart.unavailable, isTrue);
    });

    test('preserves newline across attachment boundary', () async {
      final splitBackup = await File('${root.path}/chatbox_split.json')
          .writeAsString(
            jsonEncode({
              ..._chatboxFixture(),
              'session:assistant-1': {
                'settings': {'provider': 'openai', 'modelId': 'gpt-test'},
                'messages': [
                  {
                    'id': 'message-split',
                    'role': 'user',
                    'content': 'beforeafter',
                    'timestamp': 1784332800000,
                    'contentParts': [
                      {'type': 'text', 'text': 'before'},
                      {'type': 'image', 'url': 'https://example.com/mid.png'},
                      {'type': 'text', 'text': 'after'},
                    ],
                  },
                ],
                'threads': <dynamic>[],
              },
            }),
            flush: true,
          );

      await ChatboxImporter.importFromChatbox(
        file: splitBackup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final messages = await chatService.loadMessages(
        _legacyId('default_assistant-1'),
      );
      final user = messages.singleWhere(
        (m) => m.id == _legacyId('message-split'),
      );
      expect(
        user.parts.whereType<ImagePart>().single.uri,
        'https://example.com/mid.png',
      );
      expect(
        user.parts.whereType<TextPart>().map((part) => part.text).join(),
        'before\nafter',
      );
      expect(user.content, 'before\nafter');
    });

    test(
      'imports image/file attachments as structured parts without markers',
      () async {
        final result = await ChatboxImporter.importFromChatbox(
          file: backup,
          mode: RestoreMode.overwrite,
          businessRepository: businessRepository,
          chatService: chatService,
        );
        expect(result.messages, 1);
        final messages = await chatService.loadMessages(
          _legacyId('default_assistant-1'),
        );
        final user = messages.singleWhere(
          (m) => m.id == _legacyId('message-1'),
        );
        expect(user.content, 'Hello');
        expect(user.content.contains('[image:'), isFalse);
        expect(user.content.contains('[file:'), isFalse);
        expect(user.parts.whereType<TextPart>().single.text, 'Hello');
        final image = user.parts.whereType<ImagePart>().single;
        expect(image.uri, 'https://example.com/pic.png');
        final file = user.parts.whereType<FilePart>().single;
        expect(file.uri, 'https://example.com/notes.pdf');
        expect(file.name, 'notes.pdf');
        expect(file.mime, 'application/pdf');
        for (final part in user.parts) {
          expect(part.encodePayload().contains('[image:'), isFalse);
          expect(part.encodePayload().contains('[file:'), isFalse);
        }
      },
    );

    test('tool-role import keeps ImagePart attachments', () async {
      final toolBackup = await File('${root.path}/chatbox_tool_image.json')
          .writeAsString(
            jsonEncode({
              ..._chatboxFixture(),
              'session:assistant-1': {
                'settings': {'provider': 'openai', 'modelId': 'gpt-test'},
                'messages': [
                  {
                    'id': 'tool-with-image',
                    'role': 'tool',
                    'aiProvider': 'openai',
                    'name': 'screenshot',
                    'content': 'tool result',
                    'timestamp': 1784332800000,
                    'contentParts': [
                      {
                        'type': 'tool-call',
                        'state': 'result',
                        'toolName': 'screenshot',
                        'args': {'x': 1},
                        'result': 'captured',
                      },
                      {'type': 'image', 'url': 'https://example.com/tool.png'},
                    ],
                  },
                ],
                'threads': <dynamic>[],
              },
            }),
            flush: true,
          );

      await ChatboxImporter.importFromChatbox(
        file: toolBackup,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final messages = await chatService.loadMessages(
        _legacyId('default_assistant-1'),
      );
      final tool = messages.singleWhere(
        (m) => m.id == _legacyId('tool-with-image'),
      );
      expect(tool.role, 'tool');
      expect(tool.providerId, _legacyId('provider_openai'));
      final image = tool.parts.whereType<ImagePart>().single;
      expect(image.uri, 'https://example.com/tool.png');
      final payload = jsonDecode(tool.content) as Map<String, dynamic>;
      expect(payload['tool'], 'screenshot');
      expect(payload['result'], 'captured');
    });

    test('preserves newline across reasoning boundary', () async {
      final reasoningSplit =
          await File('${root.path}/chatbox_reasoning_split.json').writeAsString(
            jsonEncode({
              ..._chatboxFixture(),
              'session:assistant-1': {
                'settings': {'provider': 'openai', 'modelId': 'gpt-test'},
                'messages': [
                  {
                    'id': 'assistant-reasoning-split',
                    'role': 'assistant',
                    'content': 'beforeafter',
                    'timestamp': 1784332800000,
                    'contentParts': [
                      {'type': 'text', 'text': 'before'},
                      {'type': 'reasoning', 'text': 'think'},
                      {'type': 'text', 'text': 'after'},
                    ],
                  },
                ],
                'threads': <dynamic>[],
              },
            }),
            flush: true,
          );

      await ChatboxImporter.importFromChatbox(
        file: reasoningSplit,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
      );

      final messages = await chatService.loadMessages(
        _legacyId('default_assistant-1'),
      );
      final assistant = messages.singleWhere(
        (m) => m.id == _legacyId('assistant-reasoning-split'),
      );
      expect(assistant.reasoningText, 'think');
      expect(
        assistant.parts.whereType<TextPart>().map((part) => part.text).join(),
        'before\nafter',
      );
      expect(assistant.content, 'before\nafter');
    });
  });
}
