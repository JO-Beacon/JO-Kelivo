import 'dart:io';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'dart:async';

import 'package:Kelivo/core/database/generation_run.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/models/mobile_background_settings.dart';
import 'package:Kelivo/core/services/mobile_background.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/controllers/chat_controller.dart';
import 'package:Kelivo/features/home/controllers/chat_actions.dart';
import 'package:Kelivo/features/home/controllers/generation_controller.dart';
import 'package:Kelivo/features/home/controllers/home_view_model.dart';
import 'package:Kelivo/features/home/controllers/stream_controller.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';
import 'package:Kelivo/features/home/services/message_generation_service.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/business_test_harness.dart';

class _MediaPathProvider extends PathProviderPlatform {
  _MediaPathProvider(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _ThrowingFinalizeChatService extends ChatService {
  _ThrowingFinalizeChatService({this.failCompletion = true});
  final bool failCompletion;
  final terminalStates = <GenerationRunState>[];
  final terminalMessages = <ChatMessage>[];

  @override
  Future<GenerationRun?> finalizeGenerationRunSilent({
    required ChatMessage message,
    required List<Map<String, dynamic>> toolEvents,
    required String? generationRunId,
    required GenerationRunState? expectedState,
    required int? expectedStateRevision,
    required GenerationRunState terminalState,
    int? checkpointSeq,
    String? errorCode,
  }) async {
    terminalStates.add(terminalState);
    terminalMessages.add(message);
    if (failCompletion && terminalState == GenerationRunState.completed) {
      throw StateError('persist failed');
    }
    return null;
  }
}

({ChatActions actions, HomeViewModel viewModel}) _actionsFor(
  BuildContext context,
  ChatService service,
  SettingsProvider settings,
  MobileBackgroundCoordinator background,
) {
  final chatController = ChatController(chatService: service);
  final streamController = StreamController(
    chatService: service,
    onStateChanged: () {},
    getSettingsProvider: () => settings,
    getCurrentConversationId: () => 'conversation-1',
  );
  final messageBuilder = MessageBuilderService(
    chatService: service,
    contextProvider: context,
  );
  final generationController = GenerationController(
    chatService: service,
    chatController: chatController,
    streamController: streamController,
    messageBuilderService: messageBuilder,
    contextProvider: context,
    onStateChanged: () {},
    getTitleForLocale: (_) => 'title',
  );
  final messageGeneration = MessageGenerationService(
    chatService: service,
    messageBuilderService: messageBuilder,
    generationController: generationController,
    streamController: streamController,
    contextProvider: context,
  );
  final viewModel = HomeViewModel(
    chatService: service,
    messageBuilderService: messageBuilder,
    messageGenerationService: messageGeneration,
    generationController: generationController,
    streamController: streamController,
    chatController: chatController,
    contextProvider: context,
    getTitleForLocale: (_) => 'title',
  );
  final actions = ChatActions(
    chatService: service,
    chatController: chatController,
    streamController: streamController,
    generationController: generationController,
    messageGenerationService: messageGeneration,
    contextProvider: context,
    viewModel: viewModel,
    backgroundCoordinator: background,
  );
  return (actions: actions, viewModel: viewModel);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const {});

  testWidgets('终态写库失败仍走 failed 收尾并通知 onStreamError', (tester) async {
    final service = _ThrowingFinalizeChatService();
    final settings = SettingsProvider(createBusinessTestPreferences());
    final streamErrors = <String>[];
    var assistantFinishedCount = 0;
    late ChatActions actions;
    const channel = MethodChannel('test.chat_actions.background');
    final notifications = <String?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'sync' ? <String, dynamic>{} : null,
        );
    final background = MobileBackgroundCoordinator(
      platform: TargetPlatform.iOS,
      channel: channel,
      notificationSender: ({required conversationId, title, body}) async {
        expect(service.terminalStates.last, GenerationRunState.failed);
        notifications.add(body);
      },
    );
    addTearDown(background.dispose);
    await background.configure(
      const MobileBackgroundSettings(notificationsEnabled: true),
      await AppLocalizations.delegate.load(const Locale('en')),
    );
    await background.start(
      id: 'assistant-1',
      conversationId: 'conversation-1',
      title: 'Test',
      cancel: () async {},
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ChatService>.value(value: service),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              final graph = _actionsFor(context, service, settings, background);
              actions = graph.actions;
              actions.onStreamError = streamErrors.add;
              actions.onAssistantMessageFinished = (_) {
                assistantFinishedCount++;
              };
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final state = StreamingState(
      GenerationContext(
        assistantMessage: ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'partial',
          conversationId: 'conversation-1',
          isStreaming: true,
        ),
        apiMessages: const [],
        userImagePaths: const [],
        allowImagesApiRouting: false,
        providerKey: 'test',
        modelId: 'test-model',
        assistant: null,
        settings: settings,
        config: ProviderConfig(
          id: 'test',
          enabled: true,
          name: 'Test',
          apiKey: '',
          baseUrl: '',
        ),
        toolDefs: const [],
        supportsReasoning: true,
        enableReasoning: true,
        streamOutput: true,
      ),
    );
    state.fullContentRaw = 'partial';

    await expectLater(
      actions.debugFinishStreaming(state),
      throwsA(isA<StateError>()),
    );
    expect(state.finishHandled, isTrue);
    expect(state.terminalPersisted, isFalse);
    expect(service.terminalStates, [GenerationRunState.completed]);
    expect(background.activeTaskIds, {'assistant-1'});
    expect(notifications, isEmpty);

    await actions.debugHandleStreamError(StateError('persist failed'), state);

    expect(state.terminalPersisted, isTrue);
    expect(service.terminalStates, [
      GenerationRunState.completed,
      GenerationRunState.failed,
    ]);
    expect(streamErrors, ['Bad state: persist failed']);
    expect(assistantFinishedCount, 0);
    expect(background.activeTaskIds, isEmpty);
    expect(notifications, ['Generation failed. Open the chat for details.']);
  });

  testWidgets('继续生成发生错误时，保留此前的工具卡片、图片和文字', (tester) async {
    final service = _ThrowingFinalizeChatService(failCompletion: false);
    final settings = SettingsProvider(createBusinessTestPreferences());
    final background = MobileBackgroundCoordinator(
      platform: TargetPlatform.windows,
    );
    addTearDown(settings.dispose);
    addTearDown(background.dispose);
    late ChatActions actions;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ChatService>.value(value: service),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              actions = _actionsFor(
                context,
                service,
                settings,
                background,
              ).actions;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    const parts = <MessagePart>[
      TextPart('已完成的文字'),
      ReasoningPart('已有思考'),
      ToolCallPart('{"id":"call-1","name":"lookup"}'),
      ImagePart(uri: 'https://example.com/result.png'),
    ];
    final state = StreamingState(
      GenerationContext(
        assistantMessage: ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          parts: parts,
          conversationId: 'conversation-1',
          isStreaming: true,
        ),
        apiMessages: const [],
        userImagePaths: const [],
        allowImagesApiRouting: false,
        providerKey: 'test',
        modelId: 'test-model',
        assistant: null,
        settings: settings,
        config: ProviderConfig(
          id: 'test',
          enabled: true,
          name: 'Test',
          apiKey: '',
          baseUrl: '',
        ),
        toolDefs: const [],
        supportsReasoning: true,
        enableReasoning: true,
        streamOutput: true,
      ),
    );
    await actions.debugHandleStreamError(
      StateError('connection failed'),
      state,
    );
    expect(service.terminalMessages.single.parts.map((p) => p.kind), [
      'text',
      'reasoning',
      'tool_call',
      'image',
    ]);
    expect(service.terminalMessages.single.content, '已完成的文字');
    expect(
      service.terminalMessages.single.parts.whereType<ImagePart>().single.uri,
      'https://example.com/result.png',
    );
  });

  testWidgets('终态图片落盘保留文本和工具的部件顺序', (tester) async {
    final service = _ThrowingFinalizeChatService(failCompletion: false);
    final settings = SettingsProvider(createBusinessTestPreferences());
    final background = MobileBackgroundCoordinator(
      platform: TargetPlatform.windows,
    );
    addTearDown(settings.dispose);
    addTearDown(background.dispose);
    final root = Directory.systemTemp.createTempSync('joaiclient-p10-media-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _MediaPathProvider(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    });
    late ChatActions actions;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ChatService>.value(value: service),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              actions = _actionsFor(
                context,
                service,
                settings,
                background,
              ).actions;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    const data = 'data:image/png;base64,aGVsbG8=';
    final state = StreamingState(
      GenerationContext(
        assistantMessage: ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          parts: const [
            TextPart('![first]($data)'),
            ToolCallPart('{"id":"t","name":"draw"}'),
            ImagePart(uri: data, id: 'second'),
          ],
          conversationId: 'conversation-1',
          isStreaming: true,
        ),
        apiMessages: const [],
        userImagePaths: const [],
        allowImagesApiRouting: false,
        providerKey: 'test',
        modelId: 'test-model',
        assistant: null,
        settings: settings,
        config: ProviderConfig(
          id: 'test',
          enabled: true,
          name: 'Test',
          apiKey: '',
          baseUrl: '',
        ),
        toolDefs: const [],
        supportsReasoning: true,
        enableReasoning: true,
        streamOutput: true,
      ),
    );
    await tester.runAsync(() => actions.debugFinishStreaming(state));
    final parts = service.terminalMessages.single.parts;
    expect(parts.map((p) => p.kind), ['text', 'tool_call', 'image']);
    expect((parts.first as TextPart).text, isNot(contains('data:image')));
    expect((parts.last as ImagePart).uri, isNot(startsWith('data:')));
    expect((parts.last as ImagePart).id, 'second');
  });

  testWidgets(
    'generation waits for narration handoff through the ViewModel callback',
    (tester) async {
      final service = _ThrowingFinalizeChatService(failCompletion: false);
      final settings = SettingsProvider(createBusinessTestPreferences());
      const channel = MethodChannel('test.chat_actions.handoff');
      final owners = <String>{};
      final terminalOwners = <Set<String>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final args = call.arguments;
        if (call.method == 'audioOwner') {
          final map = args as Map;
          if (map['active'] == true) {
            owners.add(map['owner'] as String);
          } else {
            owners.remove(map['owner']);
          }
        } else if (call.method == 'sync' && (args as Map)['terminal'] != null) {
          terminalOwners.add(Set.of(owners));
        }
        return call.method == 'sync' ? <String, dynamic>{} : null;
      });
      final background = MobileBackgroundCoordinator(
        platform: TargetPlatform.iOS,
        channel: channel,
      );
      addTearDown(background.dispose);
      addTearDown(settings.dispose);
      await background.configure(
        const MobileBackgroundSettings(
          iosEnabled: true,
          backgroundSpeechEnabled: true,
        ),
        await AppLocalizations.delegate.load(const Locale('en')),
      );
      await background.start(
        id: 'assistant-1',
        conversationId: 'conversation-1',
        title: 'Test',
        cancel: () async {},
      );
      final preparing = Completer<void>();
      final ready = Completer<void>();
      late ChatActions actions;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<ChatService>.value(value: service),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                final graph = _actionsFor(
                  context,
                  service,
                  settings,
                  background,
                );
                actions = graph.actions;
                actions.onAssistantMessageFinished =
                    graph.viewModel.debugChatActions.onAssistantMessageFinished;
                graph.viewModel.onAssistantMessageFinished = (_) async {
                  expect(service.terminalStates, [
                    GenerationRunState.completed,
                  ]);
                  preparing.complete();
                  await ready.future;
                  await background.setAudioOwner('speechBuffering', true);
                };
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      final state = StreamingState(
        GenerationContext(
          assistantMessage: ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: 'reply',
            conversationId: 'conversation-1',
            isStreaming: true,
          ),
          apiMessages: const [],
          userImagePaths: const [],
          allowImagesApiRouting: false,
          providerKey: 'test',
          modelId: 'test-model',
          assistant: null,
          settings: settings,
          config: ProviderConfig(
            id: 'test',
            enabled: true,
            name: 'Test',
            apiKey: '',
            baseUrl: '',
          ),
          toolDefs: const [],
          supportsReasoning: true,
          enableReasoning: true,
          streamOutput: true,
        ),
      )..fullContentRaw = 'reply';
      final finished = actions.debugFinishStreaming(state);
      await preparing.future;
      await tester.pump(const Duration(milliseconds: 40));
      await background.flush();
      expect(background.activeTaskIds, {'assistant-1'});
      expect(terminalOwners, isEmpty);
      ready.complete();
      await finished;
      await background.flush();
      expect(background.activeTaskIds, isEmpty);
      expect(terminalOwners, [
        {'speechBuffering'},
      ]);
      await background.setAudioOwner('speechBuffering', false);
    },
  );
}
