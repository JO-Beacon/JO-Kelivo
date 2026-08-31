import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/database/business_restore_service.dart';
import 'package:Kelivo/core/models/backup.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/services/backup/deepseek_importer.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/providers/assistant_group_provider.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';

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

Map<String, dynamic> _fixture() => {
  'id': 'conversation-1',
  'title': 'DeepSeek 测试会话',
  'inserted_at': '05/12/2026 14:18:04',
  'updated_at': '05/12/2026 14:24:11',
  'mapping': {
    'root': {
      'id': 'root',
      'parent': null,
      'children': ['request'],
      'message': null,
    },
    'request': {
      'id': 'request',
      'parent': 'root',
      'children': ['answer-a', 'answer-b'],
      'message': {
        'model': 'deepseek-reasoner',
        'inserted_at': '05/12/2026 14:23:50',
        'fragments': [
          {'type': 'REQUEST', 'content': '你好'},
          {
            'type': 'FILE',
            'files': [
              {'file_id': 'file-1', 'file_name': 'notes.pdf', 'file_size': 12},
            ],
          },
        ],
      },
    },
    'answer-a': {
      'id': 'answer-a',
      'parent': 'request',
      'children': [],
      'message': {
        'model': 'deepseek-reasoner',
        'inserted_at': '05/12/2026 14:23:51',
        'fragments': [
          {'type': 'THINK', 'content': '思考'},
          {'type': 'TOOL_SEARCH', 'results': []},
          {'type': 'RESPONSE', 'content': '答案 A'},
        ],
      },
    },
    'answer-b': {
      'id': 'answer-b',
      'parent': 'request',
      'children': [],
      'message': {
        'model': 'deepseek-reasoner',
        'inserted_at': '05/12/2026 14:23:52',
        'fragments': [
          {'type': 'THINK', 'content': '另一条思考'},
          {'type': 'RESPONSE', 'content': '答案 B'},
        ],
      },
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory root;
  late AppDatabase database;
  late BusinessRepository businessRepository;
  late BusinessPreferences preferences;
  late ChatService chatService;
  late AssistantProvider assistantProvider;
  late AssistantGroupProvider assistantGroupProvider;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kelivo_deepseek_');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    final databaseFile = File('${root.path}/kelivo.db');
    database = AppDatabase.open(file: databaseFile);
    businessRepository = BusinessRepository(database);
    preferences = BusinessPreferences(businessRepository);
    await preferences.load();
    chatService = ChatService(
      existingRepository: ChatDatabaseRepository(
        database,
        databaseFile: databaseFile,
      ),
    );
    assistantProvider = AssistantProvider(
      preferences: preferences,
      businessRepository: businessRepository,
      chatService: chatService,
    );
    assistantGroupProvider = AssistantGroupProvider(preferences: preferences);
    await assistantProvider.loaded;
    await assistantGroupProvider.loaded;
  });

  tearDown(() async {
    await chatService.close();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'imports the DeepSeek ZIP tree and preserves structured fragments',
    () async {
      final archive = Archive()
        ..add(ArchiveFile.string('user.json', '{}'))
        ..add(
          ArchiveFile.string('conversations.json', jsonEncode([_fixture()])),
        );
      final file = File('${root.path}/deepseek.zip')
        ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));

      final result = await DeepSeekImporter.importFromDeepSeek(
        file: file,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );

      expect(result.conversations, 1);
      expect(result.messages, 3);
      final messages = await chatService.loadAllConversationMessages(
        'deepseek_conversation-1',
      );
      expect(messages, hasLength(3));
      expect(messages.first.role, 'user');
      expect(
        messages.first.parts.whereType<FilePart>().single.unavailable,
        isTrue,
      );
      expect(messages[1].parts.whereType<ReasoningPart>().single.text, '思考');
      expect(
        messages[1].parts.whereType<UnknownPart>().single.rawKind,
        'deepseek_tool',
      );
      expect(messages[2].content, '答案 B');

      final tree = await chatService.loadConversationTree(
        'deepseek_conversation-1',
      );
      expect(tree, isNotNull);
      expect(tree!.branches, hasLength(2));
      expect(tree.branchSelections, hasLength(1));
      expect(tree.isIntegrityValid, isTrue);
      final assistant = assistantProvider.getById(
        'deepseek_conversation-1_assistant',
      );
      expect(assistant, isNotNull);
      expect(assistant!.name, 'DeepSeek 测试会话');
      expect(assistant.chatModelProvider, 'deepseek_web');
      expect(assistant.chatModelId, 'deepseek-reasoner');
      expect(
        chatService.getConversation('deepseek_conversation-1')!.assistantId,
        assistant.id,
      );
      final groupId = assistantGroupProvider.groupOfAssistant(assistant.id);
      expect(groupId, isNotNull);
      expect(
        assistantGroupProvider.groups
            .singleWhere((group) => group.id == groupId)
            .name,
        'DeepSeek Web 导入',
      );

      final exported = await BusinessRestoreService(
        businessRepository,
      ).exportSettings();
      final providers =
          jsonDecode(exported['provider_configs_v1'] as String) as Map;
      final webProvider = providers['deepseek_web'] as Map;
      expect(webProvider['enabled'], isFalse);
      expect(webProvider['name'], 'DeepSeek Web');
      expect(webProvider['apiKey'], '');
      expect(webProvider['baseUrl'], '');
      expect(webProvider['providerType'], 'openai');
      expect(webProvider['models'], ['deepseek-reasoner']);
      expect(exported['providers_order_v1'], contains('deepseek_web'));
    },
  );

  test('merge is idempotent for an unchanged DeepSeek conversation', () async {
    final file = File('${root.path}/deepseek.json')
      ..writeAsStringSync(jsonEncode([_fixture()]));
    final first = await DeepSeekImporter.importFromDeepSeek(
      file: file,
      mode: RestoreMode.merge,
      businessRepository: businessRepository,
      chatService: chatService,
      assistantProvider: assistantProvider,
      assistantGroupProvider: assistantGroupProvider,
      assistantGroupName: 'DeepSeek Web 导入',
      providerName: 'DeepSeek Web',
    );
    final second = await DeepSeekImporter.importFromDeepSeek(
      file: file,
      mode: RestoreMode.merge,
      businessRepository: businessRepository,
      chatService: chatService,
      assistantProvider: assistantProvider,
      assistantGroupProvider: assistantGroupProvider,
      assistantGroupName: 'DeepSeek Web 导入',
      providerName: 'DeepSeek Web',
    );
    expect(first.conversations, 1);
    expect(second.conversations, 0);
    expect(chatService.getAllConversations(), hasLength(1));
  });

  test(
    'merge keeps a moved DeepSeek conversation in its current assistant',
    () async {
      final file = File('${root.path}/deepseek.json')
        ..writeAsStringSync(jsonEncode([_fixture()]));
      await DeepSeekImporter.importFromDeepSeek(
        file: file,
        mode: RestoreMode.merge,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );
      final ordinaryAssistantId = await assistantProvider.addAssistant(
        name: '普通助手',
      );
      await chatService.moveConversationToAssistant(
        conversationId: 'deepseek_conversation-1',
        assistantId: ordinaryAssistantId,
      );

      final result = await DeepSeekImporter.importFromDeepSeek(
        file: file,
        mode: RestoreMode.merge,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );

      expect(result.conversations, 0);
      expect(chatService.getAllConversations(), hasLength(1));
      expect(
        chatService.getConversation('deepseek_conversation-1')!.assistantId,
        ordinaryAssistantId,
      );
    },
  );

  test(
    'merge keeps same-id DeepSeek message conflicts in one conversation',
    () async {
      final firstFile = File('${root.path}/deepseek-first.json')
        ..writeAsStringSync(jsonEncode([_fixture()]));
      await DeepSeekImporter.importFromDeepSeek(
        file: firstFile,
        mode: RestoreMode.merge,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );

      final changed = _fixture();
      (((changed['mapping'] as Map)['request'] as Map)['message']
          as Map)['fragments'] = [
        {'type': 'REQUEST', 'content': '改过的提问'},
      ];
      final secondFile = File('${root.path}/deepseek-second.json')
        ..writeAsStringSync(jsonEncode([changed]));
      final result = await DeepSeekImporter.importFromDeepSeek(
        file: secondFile,
        mode: RestoreMode.merge,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );

      expect(result.conversations, 1);
      expect(result.messages, 3);
      final messages = await chatService.loadAllConversationMessages(
        'deepseek_conversation-1',
      );
      expect(messages, hasLength(6));
      expect(messages.map((message) => message.content), contains('你好'));
      expect(messages.map((message) => message.content), contains('改过的提问'));
    },
  );

  test(
    'merge updates imported assistant model fields without replacing its name',
    () async {
      final firstFile = File('${root.path}/deepseek-first.json')
        ..writeAsStringSync(jsonEncode([_fixture()]));
      await DeepSeekImporter.importFromDeepSeek(
        file: firstFile,
        mode: RestoreMode.merge,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );
      final assistantId = 'deepseek_conversation-1_assistant';
      await assistantProvider.updateAssistant(
        assistantProvider
            .getById(assistantId)!
            .copyWith(name: '本地助手名称', chatModelId: 'local-model'),
      );

      final changed = _fixture();
      for (final node in (changed['mapping'] as Map).values) {
        if (node is Map && node['message'] is Map) {
          (node['message'] as Map)['model'] = 'deepseek-chat';
        }
      }
      final secondFile = File('${root.path}/deepseek-second.json')
        ..writeAsStringSync(jsonEncode([changed]));
      await DeepSeekImporter.importFromDeepSeek(
        file: secondFile,
        mode: RestoreMode.merge,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );

      final assistant = assistantProvider.getById(assistantId);
      expect(assistant, isNotNull);
      expect(assistant!.name, '本地助手名称');
      expect(assistant.chatModelId, 'deepseek-chat');
    },
  );

  test('merge keeps a DeepSeek assistant in a locally moved group', () async {
    final file = File('${root.path}/deepseek.json')
      ..writeAsStringSync(jsonEncode([_fixture()]));
    await DeepSeekImporter.importFromDeepSeek(
      file: file,
      mode: RestoreMode.merge,
      businessRepository: businessRepository,
      chatService: chatService,
      assistantProvider: assistantProvider,
      assistantGroupProvider: assistantGroupProvider,
      assistantGroupName: 'DeepSeek Web 导入',
      providerName: 'DeepSeek Web',
    );
    final assistantId = 'deepseek_conversation-1_assistant';
    final localGroupId = await assistantGroupProvider.createGroup('本地分组');
    await assistantGroupProvider.assignAssistantToGroup(
      assistantId,
      localGroupId,
    );

    final changed = _fixture();
    (((changed['mapping'] as Map)['request'] as Map)['message']
        as Map)['fragments'] = [
      {'type': 'REQUEST', 'content': '新的提问'},
    ];
    final changedFile = File('${root.path}/deepseek-changed.json')
      ..writeAsStringSync(jsonEncode([changed]));
    await DeepSeekImporter.importFromDeepSeek(
      file: changedFile,
      mode: RestoreMode.merge,
      businessRepository: businessRepository,
      chatService: chatService,
      assistantProvider: assistantProvider,
      assistantGroupProvider: assistantGroupProvider,
      assistantGroupName: 'DeepSeek Web 导入',
      providerName: 'DeepSeek Web',
    );

    expect(assistantGroupProvider.groupOfAssistant(assistantId), localGroupId);
  });

  test(
    'overwrite preserves a moved conversation and updates one placed copy',
    () async {
      final file = File('${root.path}/deepseek.json')
        ..writeAsStringSync(jsonEncode([_fixture()]));
      await DeepSeekImporter.importFromDeepSeek(
        file: file,
        mode: RestoreMode.merge,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );
      final ordinaryAssistantId = await assistantProvider.addAssistant(
        name: '普通助手',
      );
      final ordinaryConversation = await chatService.createConversation(
        title: '普通会话',
        assistantId: ordinaryAssistantId,
      );
      await chatService.moveConversationToAssistant(
        conversationId: 'deepseek_conversation-1',
        assistantId: ordinaryAssistantId,
      );

      final firstOverwrite = await DeepSeekImporter.importFromDeepSeek(
        file: file,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );
      expect(firstOverwrite.conversations, 1);
      expect(chatService.getAllConversations(), hasLength(3));
      expect(chatService.getConversation(ordinaryConversation.id), isNotNull);
      expect(
        chatService.getConversation('deepseek_conversation-1')!.assistantId,
        ordinaryAssistantId,
      );
      final placed = chatService.getConversation(
        'deepseek_conversation-1_placed',
      );
      expect(placed, isNotNull);
      expect(placed!.assistantId, 'deepseek_conversation-1_assistant');
      expect(
        (await chatService.loadAllConversationMessages(placed.id)),
        hasLength(3),
      );

      final secondOverwrite = await DeepSeekImporter.importFromDeepSeek(
        file: file,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      );
      expect(secondOverwrite.conversations, 1);
      expect(chatService.getAllConversations(), hasLength(3));
      expect(
        await chatService.loadAllConversationMessages(
          'deepseek_conversation-1_placed',
        ),
        hasLength(3),
      );
      expect(assistantProvider.getById(ordinaryAssistantId), isNotNull);
    },
  );

  test('collects distinct models into the DeepSeek Web provider', () async {
    final conversationA = _fixture();
    final conversationB = _fixture()
      ..['id'] = 'conversation-2'
      ..['title'] = '第二个会话';
    (conversationB['mapping'] as Map)['answer-b'] = {
      'id': 'answer-b',
      'parent': 'request',
      'children': <String>[],
      'message': {
        'model': 'deepseek-chat',
        'inserted_at': '05/12/2026 14:23:52',
        'fragments': [
          {'type': 'RESPONSE', 'content': '另一种模型的回答'},
        ],
      },
    };
    final file = File('${root.path}/deepseek.json')
      ..writeAsStringSync(jsonEncode([conversationA, conversationB]));

    await DeepSeekImporter.importFromDeepSeek(
      file: file,
      mode: RestoreMode.merge,
      businessRepository: businessRepository,
      chatService: chatService,
      assistantProvider: assistantProvider,
      assistantGroupProvider: assistantGroupProvider,
      assistantGroupName: 'DeepSeek Web 导入',
      providerName: 'DeepSeek Web',
    );

    final exported = await BusinessRestoreService(
      businessRepository,
    ).exportSettings();
    final providers =
        jsonDecode(exported['provider_configs_v1'] as String) as Map;
    final models = (providers['deepseek_web'] as Map)['models'] as List;
    expect(models, containsAll(['deepseek-reasoner', 'deepseek-chat']));
    expect(models.toSet(), hasLength(models.length));
  });

  test('skips the DeepSeek Web provider when no model is present', () async {
    final conversation = _fixture();
    for (final node in (conversation['mapping'] as Map).values) {
      if (node is Map && node['message'] is Map) {
        (node['message'] as Map).remove('model');
      }
    }
    final file = File('${root.path}/deepseek.json')
      ..writeAsStringSync(jsonEncode([conversation]));

    await DeepSeekImporter.importFromDeepSeek(
      file: file,
      mode: RestoreMode.merge,
      businessRepository: businessRepository,
      chatService: chatService,
      assistantProvider: assistantProvider,
      assistantGroupProvider: assistantGroupProvider,
      assistantGroupName: 'DeepSeek Web 导入',
      providerName: 'DeepSeek Web',
    );

    final exported = await BusinessRestoreService(
      businessRepository,
    ).exportSettings();
    final providers =
        jsonDecode(exported['provider_configs_v1'] as String) as Map;
    expect(providers.containsKey('deepseek_web'), isFalse);
    final assistant = assistantProvider.getById(
      'deepseek_conversation-1_assistant',
    );
    expect(assistant, isNotNull);
    expect(assistant!.chatModelProvider, isNull);
    expect(assistant.chatModelId, isNull);
  });

  test('merge keeps a user-configured DeepSeek Web provider intact', () async {
    final file = File('${root.path}/deepseek.json')
      ..writeAsStringSync(jsonEncode([_fixture()]));
    Future<void> importOnce() => DeepSeekImporter.importFromDeepSeek(
      file: file,
      mode: RestoreMode.merge,
      businessRepository: businessRepository,
      chatService: chatService,
      assistantProvider: assistantProvider,
      assistantGroupProvider: assistantGroupProvider,
      assistantGroupName: 'DeepSeek Web 导入',
      providerName: 'DeepSeek Web',
    );

    await importOnce();

    // 模拟用户手动启用了占位供应商并填入真实配置。
    final restore = BusinessRestoreService(businessRepository);
    final exported = await restore.exportSettings();
    final providers =
        jsonDecode(exported['provider_configs_v1'] as String) as Map;
    final configured =
        (providers['deepseek_web'] as Map).map(
            (key, value) => MapEntry(key.toString(), value),
          )
          ..['name'] = '我的 DeepSeek'
          ..['enabled'] = true
          ..['apiKey'] = 'user-secret';
    providers['deepseek_web'] = configured;
    exported['provider_configs_v1'] = jsonEncode(providers);
    await restore.overwrite(exported);

    // 会话本身已存在，merge 跳过会话写入，但供应商配置不得被覆盖。
    await importOnce();

    final reExported = await BusinessRestoreService(
      businessRepository,
    ).exportSettings();
    final merged =
        jsonDecode(reExported['provider_configs_v1'] as String) as Map;
    final webProvider = merged['deepseek_web'] as Map;
    expect(webProvider['name'], '我的 DeepSeek');
    expect(webProvider['enabled'], isTrue);
    expect(webProvider['apiKey'], 'user-secret');
    expect(webProvider['models'], ['deepseek-reasoner']);
  });

  test('merges the model union across DeepSeek imports', () async {
    final firstFile = File('${root.path}/first.json')
      ..writeAsStringSync(jsonEncode([_fixture()]));
    final conversation = _fixture()..['id'] = 'conversation-2';
    for (final node in (conversation['mapping'] as Map).values) {
      if (node is Map && node['message'] is Map) {
        (node['message'] as Map)['model'] = 'deepseek-chat';
      }
    }
    final secondFile = File('${root.path}/second.json')
      ..writeAsStringSync(jsonEncode([conversation]));

    Future<void> importFile(File file) => DeepSeekImporter.importFromDeepSeek(
      file: file,
      mode: RestoreMode.merge,
      businessRepository: businessRepository,
      chatService: chatService,
      assistantProvider: assistantProvider,
      assistantGroupProvider: assistantGroupProvider,
      assistantGroupName: 'DeepSeek Web 导入',
      providerName: 'DeepSeek Web',
    );

    await importFile(firstFile);
    await importFile(secondFile);

    final exported = await BusinessRestoreService(
      businessRepository,
    ).exportSettings();
    final providers =
        jsonDecode(exported['provider_configs_v1'] as String) as Map;
    final models = (providers['deepseek_web'] as Map)['models'] as List;
    expect(models, containsAll(['deepseek-reasoner', 'deepseek-chat']));
  });

  test('rejects an archive without conversations.json', () async {
    final archive = Archive()..add(ArchiveFile.string('user.json', '{}'));
    final file = File('${root.path}/invalid.zip')
      ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    expect(
      () => DeepSeekImporter.importFromDeepSeek(
        file: file,
        mode: RestoreMode.overwrite,
        businessRepository: businessRepository,
        chatService: chatService,
        assistantProvider: assistantProvider,
        assistantGroupProvider: assistantGroupProvider,
        assistantGroupName: 'DeepSeek Web 导入',
        providerName: 'DeepSeek Web',
      ),
      throwsA(isA<DeepSeekImportException>()),
    );
  });
}
