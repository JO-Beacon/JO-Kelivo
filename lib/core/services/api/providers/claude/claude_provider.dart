import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../models/provider_oauth.dart';
import '../../../../models/token_usage.dart';
import '../../../../providers/model_provider.dart';
import '../../../../providers/settings_provider.dart';
import '../../../../utils/multimodal_input_utils.dart';
import '../../../../../utils/mcp_structured_image.dart';
import '../../builtin_tools.dart';
import '../../chat_api_helpers.dart';
import '../../generation/tool_loop_runner.dart';
import '../../../auth/claude_oauth_request.dart';
import '../../google_service_account_auth.dart';
import '../../stream/sse_framing.dart';
import '../../stream/stream_chunk.dart';
import '../../stream/stream_chunk_emit.dart';
import '../../stream/stream_chunk_ids.dart';
import '../google/google_provider.dart' show downloadRemoteAsBase64;
import 'claude_container.dart';
import 'claude_decoder.dart';
import 'claude_files.dart';
import 'claude_history.dart';

export 'claude_history.dart'
    show
        normalizeClaudeImageMime,
        isClaudeSupportedImageMime,
        claudeToolResultContent;

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
  final replayServerToolBlocks =
      !isVertex && BuiltInToolsHelper.isOfficialAnthropicEndpoint(config);

  // 取出 system prompt（Anthropic 用顶层的 `system` 字段）
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
    // 变换过程中保留 media-paths；它们不会出现在最终发给 Anthropic 的
    // 请求体里（角色与内容在下面重建）。
    nonSystemMessages.add(
      Map<String, dynamic>.from(m)
        ..remove(multimodalInternalRevisionIdKey)
        ..remove(multimodalInternalGeminiThoughtSignatureKey)
        ..['role'] = role.isEmpty ? 'user' : role,
    );
  }

  final history = ClaudeHistory(
    replayServerToolBlocks: replayServerToolBlocks,
    skipRedactedThinkingBlocks: skipRedactedThinkingBlocks,
    skipImageParsing: skipImageParsing,
    userImagePaths: userImagePaths,
    // Vertex 不接受 URL 图片源，远程媒体必须先下载再内联为 base64。
    remoteMediaBase64: isVertex
        ? (url) => downloadRemoteAsBase64(client, config, url)
        : null,
  );
  final initialMessages = await history.build(nonSystemMessages);

  // 把 OpenAI 风格的 tools 映射成 Anthropic 的 custom tools（客户端工具）
  List<Map<String, dynamic>>? anthropicTools;
  if (tools != null && tools.isNotEmpty) {
    anthropicTools = [];
    for (final t in tools) {
      final fn = (t['function'] as Map<String, dynamic>?);
      if (fn == null) continue;
      final name = BuiltInToolsHelper.claimedToolName(t);
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

  // 汇总最终的 tools 列表：客户端工具 ＋ 服务端工具 ＋ 内置 web_search
  final List<Map<String, dynamic>> allTools = [];
  if (anthropicTools != null && anthropicTools.isNotEmpty) {
    allTools.addAll(anthropicTools);
  }
  // Anthropic 会拒绝 `tools` 里出现两个同名条目，而 MCP 服务器完全可以
  // 暴露一个叫 `web_search`／`web_fetch`／`code_execution` 的工具。客户端
  // 工具是调用方按名字点名要的，所以与之同名的托管条目会被丢弃，而不是
  // 一起发出去。
  final claimedToolNames = <String>{
    for (final t in allTools) (t['name'] ?? '').toString(),
  };
  void addHostedTool(Map<String, dynamic> tool) {
    if (claimedToolNames.add((tool['name'] ?? '').toString())) {
      allTools.add(tool);
    }
  }

  if (tools != null && tools.isNotEmpty) {
    for (final t in tools) {
      final type = (t['type'] ?? '').toString();
      if (type.startsWith('web_search_')) {
        addHostedTool(t);
      }
    }
  }
  // 工具类调用（生成标题／摘要）只该注入搜索；在这类调用里跑托管 fetch
  // 或容器，既不合约定也会产生计费。
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
    // 本仓库自有：web_search 的 20260209 版本依赖 code execution 才能执行
    // 搜索片段，缺失时服务端会拒绝该工具组合。
    //
    // ⛔ 上游已改成另一套做法：把标记名（20260209）映射成实际发送的
    // `web_search_20260318`（见 builtin_tools 的 claudeSearchToolTypeDynamic），
    // 那套不需要补这个工具。本仓库的 claudeBuiltInSearchToolType 仍直接发
    // 20260209，且搜索结果版本的说明写在用户可见文案里，所以这段必须保留。
    if (searchToolType == 'web_search_20260209') {
      addHostedTool(<String, dynamic>{
        'type': 'code_execution_20250825',
        'name': 'code_execution',
      });
    }
    addHostedTool(entry);
  }
  for (final entry in BuiltInToolsHelper.claudeServerToolEntries(
    cfg: config,
    modelId: modelId,
    enabled: builtIns,
  )) {
    addHostedTool(entry);
  }

  // 客户端工具用 `input_schema` 声明，Anthropic 托管工具用 `type` 声明。
  // 解码器要靠后者才能识别被降级的区块。
  final declaredServerToolNames = <String>{
    for (final t in allTools)
      if (t['input_schema'] == null && (t['type'] ?? '').toString().isNotEmpty)
        (t['name'] ?? '').toString(),
  }..remove('');
  // `container` 参数只有和用到它的工具同时出现时才被接受。
  final hasCodeExecution = declaredServerToolNames.contains('code_execution');
  // 消息构建器依据同一个判定从提示词里省略掉的数据文件，改为上传到容器。
  // 要让 `container_upload` 被接受，这个工具必须在本次请求里；而工具类
  // 调用则永远不会声明它。
  final uploadsDataFiles =
      hasCodeExecution &&
      BuiltInToolsHelper.sendsDataFilesToSandbox(
        cfg: config,
        modelId: modelId,
        clientTools: tools ?? const [],
      );

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

  // 跨轮次维持的会话内容
  List<Map<String, dynamic>> convo = List<Map<String, dynamic>>.from(
    initialMessages,
  );
  TokenUsage? totalUsage;
  var streamRound = 0;
  var pendingCalls = <EmitToolCall>[];
  var lastAssistantBlocks = <Map<String, dynamic>>[];
  // 在本次回合的每一轮之间传递 —— 客户端工具之后、pause 之后都算 —— 并
  // 在每轮之后存下来，好让下一个回合也从这个容器继续。
  ClaudeContainerRef? container = history.storedContainer;
  // 本回合目前为止的每一个响应；每轮之后都存到消息上，好让这个回合能按
  // 它当时的响应序列重放。没有工具调用的回合只靠文本重放，不存东西。
  final turnResponses = <List<Map<String, dynamic>>>[];
  Stream<StreamChunk> recordTurn(List<Map<String, dynamic>> response) async* {
    turnResponses.add(response);
    if (toolUseIdsInBlocks(turnResponses.expand((b) => b)).isNotEmpty) {
      yield ProviderArtifact(
        kind: claudeTurnArtifactKind,
        payload: encodeClaudeTurn(turnResponses),
      );
    }
    // 现在就存到本回合的消息上（而不是等到最后 —— 被取消的回合永远走不到
    // 最后），好让下一个回合能在同一个容器里继续。
    if (hasCodeExecution && container != null) {
      yield ProviderArtifact(
        kind: claudeContainerArtifactKind,
        payload: container!.encode(),
      );
    }
  }

  final downloadedFileIds = <String>{};
  var lastStreamResults = <Map<String, dynamic>>[];
  final nonStreamText = StringBuffer();
  var pauseTurn = false;

  // 沿用中的容器只收它还没见过的文件；新建的容器（没存过，或存的那个已
  // 过期）则收下用户附带的全部文件。两种情况下上传都挂在最后一条用户消息
  // 上，每个文件只传一次。本回合要用到、却传不上去的文件，会在发出任何请求
  // 之前让本回合失败；若是更早回合的文件，则改为上报那一次的问题，免得很久
  // 以前丢的一个附件把整段对话终结掉。
  final uploadedPaths = <String>{};
  final turnFileUris = {for (final doc in history.turnDataFiles) doc.uri};
  Future<void> uploadDataFiles() async {
    if (!uploadsDataFiles) return;
    final blocks = <Map<String, dynamic>>[];
    for (final doc
        in container == null ? history.dataFiles : history.unseenDataFiles) {
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
    final last = convo.last;
    final content = last['content'];
    convo[convo.length - 1] = {
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
      final thinkingModelId = config.oauthProvider == OAuthProvider.kimi
          ? modelId
          : upstreamModelId;
      final thinking = isReasoning
          ? claudeThinkingConfig(
              thinkingModelId,
              thinkingBudget,
              config: config,
            )
          : null;
      final outputConfig = isReasoning
          ? claudeOutputConfig(thinkingModelId, thinkingBudget, config: config)
          : null;

      // 每轮单独准备请求体
      final body = <String, dynamic>{
        if (!isVertex) 'model': upstreamModelId,
        if (isVertex) 'anthropic_version': 'vertex-2023-10-16',
        'max_tokens':
            maxTokens ??
            (config.oauthProvider == OAuthProvider.kimi
                ? 32000
                : (isVertex
                      ? claudeVertexMaxOutputTokens(upstreamModelId)
                      : _defaultClaudeMaxOutputTokens(upstreamModelId))),
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
        if (thinking != null) 'thinking': thinking,
        if (outputConfig != null) 'output_config': outputConfig,
        if (hasCodeExecution && container != null) 'container': container!.id,
      };
      final extraClaude = customBody(config, modelId, assistantBody: extraBody);
      if (extraClaude.isNotEmpty) {
        body.addAll(extraClaude);
      }

      http.Request buildRequest() {
        final request = http.Request('POST', url);
        request.headers.addAll(baseHeaders);
        request.body = jsonEncode(body);
        return request;
      }

      var response = await client.send(buildRequest());
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorBody = await response.stream.bytesToString();
        // 存下来的容器可能从上一回合起就过期了；丢掉它，让这一轮开一个
        // 新的。
        final staleContainer =
            body.containsKey('container') &&
            isClaudeStaleContainerError(response.statusCode, errorBody);
        if (!staleContainer) {
          throw HttpException('HTTP ${response.statusCode}: $errorBody');
        }
        container = null;
        body.remove('container');
        await uploadDataFiles();
        response = await client.send(buildRequest());
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final retryBody = await response.stream.bytesToString();
          throw HttpException('HTTP ${response.statusCode}: $retryBody');
        }
      }

      pendingCalls = [];
      lastStreamResults = [];
      lastAssistantBlocks = [];
      pauseTurn = false;

      // 非流式路径：解析完整 JSON、处理 tool_use，需要时继续循环。
      if (!stream) {
        final txt = await decodeUtf8Stream(response.stream);
        final obj = jsonDecode(txt) as Map;
        // 用量
        try {
          final u = (obj['usage'] as Map?)?.cast<String, dynamic>();
          if (u != null) {
            totalUsage = (totalUsage ?? const TokenUsage()).merge(
              claudeUsageFromMap(u),
            );
          }
        } catch (_) {}
        container =
            ClaudeContainerRef.fromResponse(obj['container']) ?? container;
        final content = (obj['content'] as List?) ?? const <dynamic>[];
        final List<Map<String, dynamic>> assistantBlocks =
            <Map<String, dynamic>>[];
        final Map<String, Map<String, dynamic>> toolUses =
            <String, Map<String, dynamic>>{}; // id -> {name,args}
        for (final it in content) {
          if (it is! Map) continue;
          final type = (it['type'] ?? '').toString();
          if (type == 'text') {
            final t = (it['text'] ?? '').toString();
            if (t.isNotEmpty) {
              assistantBlocks.add({'type': 'text', 'text': t});
            }
          } else if (type == 'thinking' ||
              (type == 'redacted_thinking' && !skipRedactedThinkingBlocks)) {
            // 为工具调用的续轮原样保留 thinking 区块。开启思考时，下一次
            // 请求必须以一条 thinking／redacted_thinking 区块开头的助手
            // 消息收尾。
            try {
              assistantBlocks.add(
                Map<String, dynamic>.from(it.cast<String, dynamic>()),
              );
            } catch (_) {}
          } else if (type == 'tool_use') {
            final id = (it['id'] ?? '').toString();
            final rawName = (it['name'] ?? '').toString();
            final name = config.oauthProvider == OAuthProvider.claude
                ? decodeClaudeOAuthToolName(rawName)
                : rawName;
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
          } else if (type == 'server_tool_use' ||
              type.endsWith('_tool_result')) {
            // 托管调用及其结果属于模型自己的这一轮：续轮里丢掉其中任何
            // 一个都会被拒绝。
            try {
              assistantBlocks.add(
                Map<String, dynamic>.from(it.cast<String, dynamic>()),
              );
            } catch (_) {}
            for (final fileId in claudeGeneratedFileIds(it['content'])) {
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
        // 续轮会把这些发出去，所以它们要和重放历史一样过一遍清理；存下来
        // 的那份保持完整。
        lastAssistantBlocks = history.sanitize(assistantBlocks);
        nonStreamText.write(joinedTextOfBlocks(assistantBlocks));
        final decoder = ClaudeStreamDecoder(
          decodeToolName: config.oauthProvider == OAuthProvider.claude
              ? decodeClaudeOAuthToolName
              : null,
          skipRedactedThinkingBlocks: skipRedactedThinkingBlocks,
          serverToolNames: declaredServerToolNames,
          sourceId: 'round-${streamRound++}',
        );
        for (final chunk in decoder.decodeCompleteServerTools(
          assistantBlocks,
        )) {
          yield chunk;
        }
        yield* recordTurn(assistantBlocks);
        if (toolUses.isEmpty) {
          // 超出轮次上限的托管工具会请求续跑，而前面没有需要先回答的
          // 客户端工具。
          pauseTurn = (obj['stop_reason'] ?? '').toString() == 'pause_turn';
        }
        if (toolUses.isNotEmpty && onToolCall != null) {
          pendingCalls = [
            for (final e in toolUses.entries)
              emitToolCall(
                id: e.key,
                name: (e.value['name'] ?? '').toString(),
                arguments: (e.value['args'] as Map<String, dynamic>),
              ),
          ];
        }
        return;
      }

      final sse = response.stream.transform(utf8.decoder);
      final decoder = ClaudeStreamDecoder(
        decodeToolName: config.oauthProvider == OAuthProvider.claude
            ? decodeClaudeOAuthToolName
            : null,
        skipRedactedThinkingBlocks: skipRedactedThinkingBlocks,
        initialUsage: totalUsage,
        serverToolNames: declaredServerToolNames,
        sourceId: 'round-${streamRound++}',
      );
      final executedToolIds = <String>{};
      // 下载与流并行进行：在这里 await 一次，会让 SSE 事件在那段时间里
      // 无人读取，工具之后的文本也会一直冻住。
      final downloads = <Future<GeneratedFile?>>[];
      var streamCompleted = false;

      try {
        await for (final event in parseSseEventStrings(sse)) {
          throwIfInBandStreamError(event.data);
          final decoded = decoder.accept(event);
          for (final chunk in decoded.chunks) {
            yield chunk;
            if (chunk is ServerToolEnd) {
              // 代码执行上报的是它写了什么，给的是卡片用不上的 id；所以
              // 这里把字节取回来，由消息自己承载文件。
              for (final fileId in claudeGeneratedFileIds(chunk.output)) {
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
        // 在这一步停下的回合（被取消，或遇到带内错误）仍然会让下载跑完，
        // 而不是把它们脚下的客户端关掉；这些下载写出来的东西没有消息可归，
        // 因此随后会被删掉。
        final files = await Future.wait(downloads);
        if (!streamCompleted) {
          for (final file in files) {
            if (file != null) await discardClaudeGeneratedFile(file);
          }
        }
      }
      for (final chunk in decoder.onClosed()) {
        yield chunk;
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
      container = decoder.container ?? container;

      // 续轮会原样发出这些，所以它们要和重放历史一样过一遍清理 —— 存下来
      // 的那份保持完整。
      lastAssistantBlocks = history.sanitize(assistantBlocks);
      yield* recordTurn(assistantBlocks);
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
          ),
      ];
      for (final tool in decoder.clientTools.values) {
        var res = toolResultsContent[tool.id] ?? '';
        if (res.isEmpty && onToolCall != null) {
          res = ClientToolResult.fromHandler(
            await onToolCall(
              tool.name,
              tool.decodedArguments,
              toolCallId: tool.id,
            ),
          ).content;
        }
        lastStreamResults.add({
          'type': 'tool_result',
          'tool_use_id': tool.id,
          'content': claudeToolResultContent(res),
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
                  'content': claudeToolResultContent(item.content),
                },
            ];
      convo = [
        ...convo,
        {'role': 'assistant', 'content': lastAssistantBlocks},
        {'role': 'user', 'content': results},
      ];
    },
    finish: () async* {
      yield* emitDone(
        ids: StreamChunkIds('finish'),
        content: nonStreamText.toString(),
        usage: totalUsage,
        totalTokens: totalUsage?.totalTokens ?? 0,
      );
    },
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
