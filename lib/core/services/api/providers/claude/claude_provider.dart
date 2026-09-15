import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../models/token_usage.dart';
import '../../../../providers/model_provider.dart';
import '../../../../providers/settings_provider.dart';
import '../../../../utils/multimodal_input_utils.dart';
import '../../builtin_tools.dart';
import '../../chat_api_helpers.dart';
import '../../generation/tool_loop_runner.dart';
import '../../google_service_account_auth.dart';
import '../../stream/sse_framing.dart';
import '../../stream/stream_chunk.dart';
import '../../stream/stream_chunk_emit.dart';
import '../../stream/stream_chunk_ids.dart';
import '../google/google_provider.dart' show downloadRemoteAsBase64;
import 'claude_decoder.dart';
import 'claude_container.dart';
import 'claude_files.dart';
import 'claude_history.dart';

int _defaultClaudeMaxOutputTokens(String modelId) {
  final lower = modelId.trim().toLowerCase();
  if (RegExp(
    r'claude-(?:fable-5|mythos-5|opus-(?:5|4-8)|sonnet-5)(?:$|[._:@/-])',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return 128000;
  }
  return 64000;
}

/// Vertex AI 上 Claude 各模型的输出上限，依据 Google Vertex AI 的模型说明。
///
/// **只在 Vertex 端点上使用**：官方 Anthropic 端点沿用上面的通用规则。
/// Vertex 不认通用规则的理由是老模型的上限比 64000 小得多，按 64000 发会被拒。
///
/// 前 16 款与上游同名表逐字一致；末尾三款是上游表未收录、但本仓库的 Vertex
/// 模型清单会注入的模型（见 `model_provider.dart` 的 `knownClaude`），若不补，
/// 它们会落到兜底 4096，其中 `claude-3-7-sonnet@20250219` 会明显截断回答。
int claudeVertexMaxOutputTokens(String modelId) {
  switch (modelId) {
    case 'claude-fable-5-1':
    case 'claude-fable-5':
    case 'claude-opus-5':
    case 'claude-opus-4-8':
    case 'claude-opus-4-7':
    case 'claude-opus-4-6':
    case 'claude-sonnet-5':
    case 'claude-sonnet-4-6':
      return 128000;
    case 'claude-opus-4-5@20251101':
    case 'claude-sonnet-4-5@20250929':
    case 'claude-haiku-4-5@20251001':
    case 'claude-sonnet-4@20250514':
      return 64000;
    case 'claude-opus-4-1@20250805':
    case 'claude-opus-4@20250514':
      return 32000;
    case 'claude-3-haiku@20240307':
      return 8000;
    case 'claude-3-5-sonnet@20240620':
    case 'claude-3-5-sonnet-v2@20241022':
      return 8192;
    // 以下三款上游表未覆盖（本仓库的 Vertex 模型清单里有）
    case 'claude-3-7-sonnet@20250219':
      return 64000;
    case 'claude-3-5-haiku@20241022':
      return 8192;
    case 'claude-3-opus@20240229':
      return 4096;
    default:
      // 更老的模型
      return 4096;
  }
}

Stream<StreamChunk> sendClaudeStreamEvents(
  http.Client client,
  ProviderConfig config,
  String modelId,
  List<Map<String, dynamic>> messages, {
  List<String>? userImagePaths,
  int? thinkingBudget,
  double? temperature,
  double? topP,
  int? maxTokens,
  List<Map<String, dynamic>>? tools,
  ToolCallHandler? onToolCall,
  Map<String, String>? extraHeaders,
  Map<String, dynamic>? extraBody,
  bool stream = true,
  bool builtInSearchOnly = false,
  bool skipImageParsing = false,
  StreamRoundRunner? retryRound,
}) async* {
  final upstreamModelId = apiModelId(config, modelId);
  final isVertex = config.vertexAI == true;
  // 端点和请求头在各工具轮次之间保持不变。
  final base = config.baseUrl.endsWith('/')
      ? config.baseUrl.substring(0, config.baseUrl.length - 1)
      : config.baseUrl;
  final url = isVertex
      ? _vertexClaudeUrl(config, upstreamModelId, stream: stream)
      : Uri.parse('$base/messages');

  final isReasoning = effectiveModelInfo(
    config,
    modelId,
  ).abilities.contains(ModelAbility.reasoning);
  final skipRedactedThinkingBlocks = BuiltInToolsHelper.isOpenRouterProvider(
    config,
  );

  // 提取系统提示（Anthropic 使用顶层 `system` 字段）。
  String systemPrompt = '';
  final nonSystemMessages = <Map<String, dynamic>>[];
  for (final m in messages) {
    final role = (m['role'] ?? '').toString();
    if (role == 'system') {
      final s = (m['content'] ?? '').toString();
      if (s.isNotEmpty) {
        systemPrompt = systemPrompt.isEmpty ? s : '$systemPrompt\n\n$s';
      }
      continue;
    }
    // 转换时保留媒体路径；最终 Anthropic 请求体不会直接发送这些字段，下面会重建 role/content。
    nonSystemMessages.add(
      Map<String, dynamic>.from(m)
        ..remove(multimodalInternalRevisionIdKey)
        ..['role'] = role.isEmpty ? 'user' : role,
    );
  }

  // 使用统一历史适配器重建 Anthropic 消息，保留多响应轮次、服务端工具结果、
  // pause_turn 和附件引用的协议顺序。
  final history = ClaudeHistory(
    replayServerToolBlocks:
        !isVertex && BuiltInToolsHelper.isOfficialAnthropicEndpoint(config),
    skipRedactedThinkingBlocks: skipRedactedThinkingBlocks,
    skipImageParsing: skipImageParsing,
    userImagePaths: userImagePaths,
    // Vertex 不接受 URL 图片源，远程媒体必须先下载再内联为 base64。
    remoteMediaBase64: isVertex
        ? (url) => downloadRemoteAsBase64(client, config, url)
        : null,
  );
  final initialMessages = await history.build(nonSystemMessages);

  // 将 OpenAI 风格工具映射为 Anthropic 自定义工具（客户端工具）。
  List<Map<String, dynamic>>? anthropicTools;
  if (tools != null && tools.isNotEmpty) {
    anthropicTools = [];
    for (final t in tools) {
      final fn = (t['function'] as Map<String, dynamic>?);
      if (fn == null) continue;
      final name = (fn['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final desc = (fn['description'] ?? '').toString();
      final params =
          (fn['parameters'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{'type': 'object'};
      anthropicTools.add({
        'name': name,
        if (desc.isNotEmpty) 'description': desc,
        'input_schema': params,
      });
    }
  }

  // 汇总最终工具列表：客户端工具、服务端工具和内置 web_search。
  final List<Map<String, dynamic>> allTools = [];
  final declaredNames = <String>{};
  if (anthropicTools != null && anthropicTools.isNotEmpty) {
    for (final tool in anthropicTools) {
      final name = (tool['name'] ?? '').toString();
      if (name.isNotEmpty && declaredNames.add(name)) allTools.add(tool);
    }
  }
  if (tools != null && tools.isNotEmpty) {
    for (final t in tools) {
      final type = (t['type'] ?? '').toString();
      final name = (t['name'] ?? '').toString();
      if (type.startsWith('web_search_') &&
          name.isNotEmpty &&
          declaredNames.add(name)) {
        allTools.add(t);
      }
    }
  }
  // 后台调用（标题／摘要等）只注入搜索：托管抓取或容器执行既不合约定、也会被计费。
  // Vertex 上的 Claude 与上游一致，不做收窄。
  final builtIns = builtInSearchOnly && !isVertex
      ? builtInTools(
          config,
          modelId,
        ).where((name) => name == BuiltInToolNames.search).toSet()
      : builtInTools(config, modelId);
  if (builtIns.contains(BuiltInToolNames.search)) {
    Map<String, dynamic> ws = const <String, dynamic>{};
    try {
      final ov = config.modelOverrides[modelId];
      if (ov is Map && ov['webSearch'] is Map) {
        ws = (ov['webSearch'] as Map).cast<String, dynamic>();
      }
    } catch (_) {}
    final searchToolType = BuiltInToolsHelper.claudeBuiltInSearchToolType(
      cfg: config,
      modelId: modelId,
    );
    final entry = <String, dynamic>{
      'type': searchToolType,
      'name': 'web_search',
    };
    if (ws['max_uses'] is int && (ws['max_uses'] as int) > 0) {
      entry['max_uses'] = ws['max_uses'];
    }
    if (ws['allowed_domains'] is List) {
      entry['allowed_domains'] = List<String>.from(
        (ws['allowed_domains'] as List).map((e) => e.toString()),
      );
    }
    if (ws['blocked_domains'] is List) {
      entry['blocked_domains'] = List<String>.from(
        (ws['blocked_domains'] as List).map((e) => e.toString()),
      );
    }
    if (ws['user_location'] is Map) {
      entry['user_location'] = (ws['user_location'] as Map)
          .cast<String, dynamic>();
    }
    // web_search 的 20260209 版本依赖 code execution 才能执行搜索片段，
    // 缺失时服务端会拒绝该工具组合。
    if (searchToolType == 'web_search_20260209' &&
        declaredNames.add('code_execution')) {
      allTools.add(<String, dynamic>{
        'type': 'code_execution_20250825',
        'name': 'code_execution',
      });
    }
    if (declaredNames.add('web_search')) allTools.add(entry);
  }
  for (final entry in BuiltInToolsHelper.claudeServerToolEntries(
    cfg: config,
    modelId: modelId,
    enabled: builtIns,
  )) {
    final name = (entry['name'] ?? '').toString();
    if (name.isNotEmpty && declaredNames.add(name)) allTools.add(entry);
  }

  final hasCodeExecution = allTools.any(
    (tool) =>
        (tool['name'] ?? '').toString() == 'code_execution' &&
        (tool['type'] ?? '').toString().startsWith('code_execution_'),
  );
  final dataFiles = history.dataFiles;
  final unseenDataFiles = history.unseenDataFiles;
  final turnDataFiles = history.turnDataFiles;

  // 请求头在各轮次之间保持不变。
  final vertexToken = isVertex ? await _vertexAccessToken(config) : null;
  final baseHeaders = customHeaders(
    config,
    modelId,
    baseHeaders: <String, String>{
      'Content-Type': 'application/json',
      'Accept': stream ? 'text/event-stream' : 'application/json',
      if (isVertex && vertexToken != null && vertexToken.isNotEmpty)
        'Authorization': 'Bearer $vertexToken',
      if (isVertex && (config.projectId ?? '').trim().isNotEmpty)
        'X-Goog-User-Project': config.projectId!.trim(),
      if (!isVertex) 'x-api-key': effectiveApiKey(config),
      if (!isVertex) 'anthropic-version': '2023-06-01',
    },
    assistantHeaders: extraHeaders,
  );

  // 跨轮次维护会话内容。
  List<Map<String, dynamic>> convo = List<Map<String, dynamic>>.from(
    initialMessages,
  );
  String? carriedContainerId = history.storedContainer?.id;

  final uploadedPaths = <String>{};
  final turnFileUris = {for (final doc in turnDataFiles) doc.uri};
  final turnResponses = <List<Map<String, dynamic>>>[];
  Future<void> uploadDataFiles() async {
    if (!hasCodeExecution || dataFiles.isEmpty || convo.isEmpty) return;
    final blocks = <Map<String, dynamic>>[];
    final source = carriedContainerId == null ? dataFiles : unseenDataFiles;
    for (final doc in source) {
      if (!uploadedPaths.add(doc.uri)) continue;
      try {
        final fileId = await uploadClaudeFile(
          client: client,
          base: base,
          headers: baseHeaders,
          path: doc.uri,
          name: doc.name,
          mime: doc.mime,
        );
        blocks.add({'type': 'container_upload', 'file_id': fileId});
      } on ClaudeFileUploadException catch (e) {
        if (turnFileUris.contains(doc.uri)) rethrow;
        blocks.add({'type': 'text', 'text': e.toString()});
      }
    }
    if (blocks.isEmpty) return;
    final index = convo.lastIndexWhere(
      (message) => (message['role'] ?? '').toString() == 'user',
    );
    if (index < 0) return;
    final last = convo[index];
    final content = last['content'];
    convo[index] = {
      ...last,
      'content': [
        if (content is List)
          ...content
        else if ((content ?? '').toString().isNotEmpty)
          {'type': 'text', 'text': content.toString()},
        ...blocks,
      ],
    };
  }

  await uploadDataFiles();
  TokenUsage? totalUsage;
  var streamRound = 0;
  var pendingCalls = <EmitToolCall>[];
  var lastAssistantBlocks = <Map<String, dynamic>>[];
  var lastStreamResults = <Map<String, dynamic>>[];
  var lastText = '';
  var pauseTurn = false;

  /// One file is downloaded at most once per request, however many rounds and
  /// however many blocks report it.
  final downloadedFileIds = <String>{};

  yield* runProviderToolRounds(
    retryRound: retryRound,
    sendRound: () async* {
      final omitSamplingParams = claudeShouldOmitSamplingParams(
        upstreamModelId,
        thinkingBudget,
      );
      final compatibleTopP = claudeCompatibleTopP(
        upstreamModelId,
        thinkingBudget,
        topP,
      );
      final thinking = isReasoning
          ? claudeThinkingConfig(
              upstreamModelId,
              thinkingBudget,
              config: config,
            )
          : null;
      final outputConfig = isReasoning
          ? claudeOutputConfig(upstreamModelId, thinkingBudget, config: config)
          : null;

      // 为当前轮次准备请求体。
      final body = <String, dynamic>{
        if (!isVertex) 'model': upstreamModelId,
        if (isVertex) 'anthropic_version': 'vertex-2023-10-16',
        'max_tokens':
            maxTokens ??
            (isVertex
                ? claudeVertexMaxOutputTokens(upstreamModelId)
                : _defaultClaudeMaxOutputTokens(upstreamModelId)),
        'messages': convo,
        'stream': stream,
        if (systemPrompt.isNotEmpty) 'system': systemPrompt,
        if (!isVertex && config.claudePromptCachingEnabled == true)
          'cache_control': ProviderConfig.claudePromptCacheControl(
            config.claudePromptCachingTtl,
          ),
        if (!omitSamplingParams &&
            !isClaudeReasoningEnabled(thinkingBudget) &&
            temperature != null)
          'temperature': temperature,
        if (compatibleTopP != null) 'top_p': compatibleTopP,
        if (allTools.isNotEmpty) 'tools': allTools,
        if (allTools.isNotEmpty) 'tool_choice': {'type': 'auto'},
        if (hasCodeExecution &&
            carriedContainerId != null &&
            carriedContainerId!.isNotEmpty)
          'container': carriedContainerId,
        if (thinking != null) 'thinking': thinking,
        if (outputConfig != null) 'output_config': outputConfig,
      };
      final extraClaude = customBody(config, modelId, assistantBody: extraBody);
      if (extraClaude.isNotEmpty) {
        body.addAll(extraClaude);
      }

      final request = http.Request('POST', url);
      request.headers.addAll(baseHeaders);
      request.body = jsonEncode(body);

      var response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorBody = await response.stream.bytesToString();
        final stale =
            hasCodeExecution &&
            carriedContainerId != null &&
            isClaudeStaleContainerError(response.statusCode, errorBody);
        if (!stale) {
          throw HttpException('HTTP ${response.statusCode}: $errorBody');
        }
        carriedContainerId = null;
        body.remove('container');
        await uploadDataFiles();
        final retry = http.Request('POST', url);
        retry.headers.addAll(baseHeaders);
        retry.body = jsonEncode(body);
        response = await client.send(retry);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final retryBody = await response.stream.bytesToString();
          throw HttpException('HTTP ${response.statusCode}: $retryBody');
        }
      }

      pendingCalls = [];
      lastStreamResults = [];
      lastText = '';
      lastAssistantBlocks = [];
      pauseTurn = false;

      // 非流式路径：解析完整 JSON，处理 tool_use，必要时继续工具循环。
      if (!stream) {
        final txt = await decodeUtf8Stream(response.stream);
        final obj = jsonDecode(txt) as Map;
        // 统计用量。
        try {
          final u = (obj['usage'] as Map?)?.cast<String, dynamic>();
          if (u != null) {
            totalUsage = (totalUsage ?? const TokenUsage()).merge(
              claudeUsageFromMap(u),
            );
          }
        } catch (_) {}
        final content = (obj['content'] as List?) ?? const <dynamic>[];
        final List<Map<String, dynamic>> assistantBlocks =
            <Map<String, dynamic>>[];
        final Map<String, Map<String, dynamic>> toolUses =
            <String, Map<String, dynamic>>{}; // 按 id 映射工具名称和参数。
        final buf = StringBuffer();
        for (final it in content) {
          if (it is! Map) continue;
          final type = (it['type'] ?? '').toString();
          if (type == 'text') {
            final t = (it['text'] ?? '').toString();
            if (t.isNotEmpty) {
              assistantBlocks.add({'type': 'text', 'text': t});
              buf.write(t);
            }
          } else if (type == 'thinking' ||
              (type == 'redacted_thinking' && !skipRedactedThinkingBlocks)) {
            // 为工具续轮原样保留思考分片；启用思考时，下一次请求必须以 thinking 或
            // redacted_thinking 分片开头发送上一条 assistant 消息。
            try {
              assistantBlocks.add(
                Map<String, dynamic>.from(it.cast<String, dynamic>()),
              );
            } catch (_) {}
          } else if (type == 'tool_use') {
            final id = (it['id'] ?? '').toString();
            final name = (it['name'] ?? '').toString();
            final args =
                (it['input'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{};
            if (id.isNotEmpty) {
              toolUses[id] = {'name': name, 'args': args};
              assistantBlocks.add({
                'type': 'tool_use',
                'id': id,
                'name': name,
                'input': args,
              });
            }
          }
        }
        final serverDecoder = ClaudeStreamDecoder(
          serverToolNames: {
            for (final tool in allTools)
              if ((tool['type'] ?? '').toString().startsWith('web_') ||
                  (tool['type'] ?? '').toString().startsWith('code_execution_'))
                (tool['name'] ?? '').toString(),
          },
        );
        final responseContainer = (obj['container'] is Map)
            ? (obj['container'] as Map)['id']?.toString()
            : null;
        final serverBlocks = [
          for (final item in content)
            if (item is Map) item.cast<String, dynamic>(),
        ];
        for (final chunk in serverDecoder.decodeCompleteServerTools(
          serverBlocks,
        )) {
          yield chunk;
          if (chunk case ServerToolEnd(:final output)) {
            for (final fileId in claudeGeneratedFileIds(output)) {
              if (!downloadedFileIds.add(fileId)) continue;
              final file = await downloadClaudeGeneratedFile(
                client: client,
                base: base,
                headers: baseHeaders,
                fileId: fileId,
              );
              if (file != null) yield file;
            }
          }
        }
        // The complete response already contains the authoritative block
        // order; keep it intact for Anthropic replay.
        assistantBlocks
          ..clear()
          ..addAll(serverBlocks);
        final responseHasTool = assistantBlocks.any(
          (block) =>
              block['type'] == 'tool_use' || block['type'] == 'server_tool_use',
        );
        if (responseHasTool || turnResponses.isNotEmpty) {
          turnResponses.add([
            for (final block in assistantBlocks)
              Map<String, dynamic>.from(block),
          ]);
          yield ProviderArtifact(
            kind: 'claude_turn',
            payload: jsonEncode(turnResponses),
          );
        }
        if (hasCodeExecution &&
            responseContainer != null &&
            responseContainer.isNotEmpty) {
          yield ProviderArtifact(
            kind: 'claude_container',
            payload: ClaudeContainerRef(id: responseContainer).encode(),
          );
        }
        lastAssistantBlocks = assistantBlocks;
        lastText = buf.toString();
        if (toolUses.isNotEmpty && onToolCall != null) {
          pendingCalls = [
            for (final e in toolUses.entries)
              emitToolCall(
                id: e.key,
                name: (e.value['name'] ?? '').toString(),
                arguments: (e.value['args'] as Map<String, dynamic>),
                metadata: {
                  'anthropic': {
                    'assistant_blocks': assistantBlocks,
                    if (responseContainer != null &&
                        responseContainer.isNotEmpty)
                      'container_id': responseContainer,
                  },
                },
              ),
          ];
        }
        if (toolUses.isEmpty) {
          pauseTurn = (obj['stop_reason'] ?? '').toString() == 'pause_turn';
        }
        return;
      }

      final sse = response.stream.transform(utf8.decoder);
      final decoder = ClaudeStreamDecoder(
        skipRedactedThinkingBlocks: skipRedactedThinkingBlocks,
        serverToolNames: {
          for (final tool in allTools)
            if ((tool['type'] ?? '').toString().startsWith('web_') ||
                (tool['type'] ?? '').toString().startsWith('code_execution_'))
              (tool['name'] ?? '').toString(),
        },
        sourceId: 'round-${streamRound++}',
      );
      final executedToolIds = <String>{};
      // Downloads run alongside the stream: awaiting one here would leave the
      // SSE events unread, and the text after the tool frozen, for as long as
      // the file takes.
      final downloads = <Future<GeneratedFile?>>[];
      var streamCompleted = false;
      void collectDownloads(Object? output) {
        for (final fileId in claudeGeneratedFileIds(output)) {
          if (!downloadedFileIds.add(fileId)) continue;
          downloads.add(
            downloadClaudeGeneratedFile(
              client: client,
              base: base,
              headers: baseHeaders,
              fileId: fileId,
            ),
          );
        }
      }

      try {
        await for (final event in parseSseEventStrings(sse)) {
          throwIfInBandStreamError(event.data);
          final decoded = decoder.accept(event);
          for (final chunk in decoded.chunks) {
            yield chunk;
            if (chunk case ServerToolEnd(:final output)) {
              collectDownloads(output);
            }
            if (chunk is ToolCallEnd &&
                decoder.isClientTool(chunk.id) &&
                onToolCall != null &&
                executedToolIds.add(chunk.id)) {
              final tool = decoder.clientTools[chunk.id]!;
              final args = tool.decodedArguments;
              final call = emitToolCall(
                id: tool.id,
                name: tool.name,
                arguments: args,
                metadata: {
                  'anthropic': {'assistant_blocks': decoder.assistantBlocks},
                },
              );
              await for (final resultChunk in executeClientTools(
                calls: [call],
                onToolCall: onToolCall,
                usage: decoder.usage,
                totalTokens: decoder.usage?.totalTokens ?? 0,
              )) {
                if (resultChunk is ToolCallResult) {
                  decoder.recordToolResult(
                    tool.id,
                    (resultChunk.output ?? '').toString(),
                  );
                }
                yield resultChunk;
              }
            }
          }
          if (decoded.completed) break;
        }
        streamCompleted = true;
      } finally {
        // A turn that stops here — cancelled, or on an in-band error — still
        // sees its downloads out rather than closing the client under them;
        // what they wrote has no message to go to, so it is removed again.
        final files = await Future.wait(downloads);
        if (!streamCompleted) {
          for (final file in files) {
            if (file != null) await discardClaudeGeneratedFile(file);
          }
        }
      }
      for (final chunk in decoder.onClosed()) {
        yield chunk;
        if (chunk case ServerToolEnd(:final output)) {
          collectDownloads(output);
        }
      }
      for (final download in downloads) {
        final file = await download;
        if (file != null) yield file;
      }

      final usage = decoder.usage;
      final assistantBlocks = decoder.assistantBlocks;
      final lastStopReason = decoder.lastStopReason;
      final toolResultsContent = decoder.toolResults;

      totalUsage = usage ?? totalUsage;
      final responseHasTool = assistantBlocks.any(
        (block) =>
            block['type'] == 'tool_use' || block['type'] == 'server_tool_use',
      );
      if (responseHasTool || turnResponses.isNotEmpty) {
        turnResponses.add([
          for (final block in assistantBlocks) Map<String, dynamic>.from(block),
        ]);
        yield ProviderArtifact(
          kind: 'claude_turn',
          payload: jsonEncode(turnResponses),
        );
      }
      if (hasCodeExecution &&
          decoder.containerId != null &&
          decoder.containerId!.isNotEmpty) {
        carriedContainerId = decoder.containerId;
        yield ProviderArtifact(
          kind: 'claude_container',
          payload: ClaudeContainerRef(id: decoder.containerId!).encode(),
        );
      }

      lastAssistantBlocks = assistantBlocks;
      if (decoder.clientTools.isEmpty) {
        pauseTurn = (lastStopReason ?? '') == 'pause_turn';
        return;
      }

      pendingCalls = [
        for (final tool in decoder.clientTools.values)
          emitToolCall(
            id: tool.id,
            name: tool.name,
            arguments: tool.decodedArguments,
            metadata: {
              'anthropic': {'assistant_blocks': assistantBlocks},
            },
          ),
      ];
      for (final tool in decoder.clientTools.values) {
        var res = toolResultsContent[tool.id] ?? '';
        if (res.isEmpty && onToolCall != null) {
          res = await onToolCall(
            tool.name,
            tool.decodedArguments,
            toolCallId: tool.id,
          );
        }
        lastStreamResults.add({
          'type': 'tool_result',
          'tool_use_id': tool.id,
          if (res.isNotEmpty) 'content': res,
        });
      }
    },
    takeCalls: () => pendingCalls,
    continueWithoutCalls: () => pauseTurn,
    executeAfterRound: !stream,
    emitCalls: !stream,
    onToolCall: onToolCall,
    append: (executed) {
      if (pauseTurn) {
        convo = [
          ...convo,
          {'role': 'assistant', 'content': lastAssistantBlocks},
        ];
        return;
      }
      final results = stream
          ? lastStreamResults
          : [
              for (final item in executed)
                <String, dynamic>{
                  'type': 'tool_result',
                  'tool_use_id': item.call.id,
                  'content': item.content,
                },
            ];
      convo = [
        ...convo,
        {'role': 'assistant', 'content': lastAssistantBlocks},
        {'role': 'user', 'content': results},
      ];
    },
    finish: () => emitDone(
      ids: StreamChunkIds('finish'),
      content: lastText,
      usage: totalUsage,
      totalTokens: totalUsage?.totalTokens ?? 0,
    ),
    usageOf: () => totalUsage,
  );
}

Uri _vertexClaudeUrl(
  ProviderConfig config,
  String modelId, {
  required bool stream,
}) {
  final location = (config.location ?? 'us-central1').trim();
  final projectId = (config.projectId ?? '').trim();
  final host = location.toLowerCase() == 'global'
      ? 'aiplatform.googleapis.com'
      : '$location-aiplatform.googleapis.com';
  final endpoint = stream ? 'streamRawPredict' : 'rawPredict';
  return Uri.parse(
    'https://$host/v1/projects/$projectId/locations/$location/'
    'publishers/anthropic/models/$modelId:$endpoint',
  );
}

Future<String?> _vertexAccessToken(ProviderConfig config) async {
  final json = (config.serviceAccountJson ?? '').trim();
  if (json.isEmpty) {
    // 兼容把临时 OAuth token 直接填入 apiKey 的配置。
    final key = config.apiKey.trim();
    return key.isEmpty ? null : key;
  }
  return GoogleServiceAccountAuth.getAccessTokenFromJson(json);
}
