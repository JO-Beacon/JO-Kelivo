import 'dart:convert';

import '../../../../utils/multimodal_input_utils.dart';
import '../../../../../utils/sandbox_path_resolver.dart';
import '../../chat_api_helpers.dart';
import 'claude_container.dart';
import 'claude_role_normalizer.dart';

/// 一次 Claude 回合的各个响应以此 artifact 类型存放在发起它们的助手消息上：
/// 按顺序记录该回合 API 产出的每一个响应，各自是一串块列表。一个回合若在托管
/// 工具与客户端工具之间交接，或是在 `pause_turn` 之后继续，会跨越多个响应；
/// 协议会把每个响应各自作为一条助手消息重放，客户端工具结果夹在它们之间
/// —— 所以这里显式记下边界，而不是事后从块里推断。
///
/// 该回合一旦调用过工具，此后每个响应写完都会更新它，因此被中断的回合也能
/// 重放到最后一个完整响应。没有记录的回合仅凭文本重放，不存任何东西。
/// 它会随下一条请求、以 [multimodalInternalClaudeTurnKey] 的形式发送，
/// 挂在持有该回合工具调用的那条助手消息上。
const String claudeTurnArtifactKind = 'claude_turn';

String encodeClaudeTurn(List<List<Map<String, dynamic>>> responses) =>
    jsonEncode(responses);

List<List<Map<String, dynamic>>>? decodeClaudeTurn(Object? payload) {
  if (payload is! String || payload.isEmpty) return null;
  try {
    return _responsesOf(jsonDecode(payload));
  } catch (_) {
    return null;
  }
}

/// 从持久化 JSON 中读出的块列表，空的会被丢弃。
List<List<Map<String, dynamic>>>? _responsesOf(Object? raw) {
  if (raw is! List) return null;
  final read = [
    for (final blocks in raw)
      if (blocks is List)
        [
          for (final block in blocks.whereType<Map>())
            block.cast<String, dynamic>(),
        ],
  ]..removeWhere((blocks) => blocks.isEmpty);
  return read.isEmpty ? null : read;
}

/// Anthropic 拒绝空的文本块，而整个丢掉 `content` 会让这次工具调用无人应答，
/// 在模型看来就是一个畸形回合。什么都没产出的工具会收到一个显式占位符。
String claudeToolResultContent(String result) =>
    result.trim().isEmpty ? '(no output)' : result;

String joinedTextOfBlocks(Iterable<Map> blocks) => blocks
    .where((block) => block['type'] == 'text')
    .map((block) => (block['text'] ?? '').toString())
    .join();

Set<String> toolUseIdsInBlocks(
  Iterable<Map> blocks, {
  bool clientOnly = false,
}) {
  return {
    for (final block in blocks)
      if (block['type'] == 'tool_use' ||
          (!clientOnly && block['type'] == 'server_tool_use'))
        if ((block['id'] ?? '').toString() case final id when id.isNotEmpty) id,
  };
}

Set<String> toolResultIdsInBlocks(Iterable<Map> blocks) {
  return {
    for (final block in blocks)
      if ((block['type'] ?? '').toString().endsWith('_tool_result'))
        if ((block['tool_use_id'] ?? '').toString() case final id
            when id.isNotEmpty)
          id,
  };
}

/// 把应用的消息历史转换成 Anthropic 的 `messages` 数组。
///
/// 工具回合被持久化为一条放着各个卡片的助手消息、每张卡片对应的 `tool`
/// 消息，以及紧跟其后的、以普通助手消息承载的整回合文本。重放时它会还原成
/// API 实际产出的那些响应 —— 见 [claudeTurnArtifactKind] —— 每个响应各自
/// 是一条助手消息，排在其等待的客户端工具结果之后，回合文本折进它们之中，
/// 而不是再发一次。
class ClaudeHistory {
  ClaudeHistory({
    required this.replayServerToolBlocks,
    required this.skipRedactedThinkingBlocks,
    this.skipImageParsing = false,
    this.userImagePaths,
    this.remoteMediaBase64,
  });

  /// 只有 Anthropic 会真正执行服务端工具或解密其返回值，所以在别处这些块会被
  /// 丢弃，调用以合成出的客户端工具对形式重放，与这些工具出现之前完全一致。
  final bool replayServerToolBlocks;
  final bool skipRedactedThinkingBlocks;
  final bool skipImageParsing;
  final List<String>? userImagePaths;

  /// 把远程媒体 URL 取回为 base64 的函数，用于不接受 URL 图片源的供应商。
  ///
  /// Vertex 不接受 `image` 块里的远程 URL，必须下载后以 base64 内联；
  /// 提供本函数即启用该行为。为空时远程 URL 照 official Claude 的既有
  /// 行为原样作为文本发出。
  final Future<String> Function(String url)? remoteMediaBase64;

  /// 该会话最后一次代码执行所在的容器，存放在对应那条助手消息上。
  /// 以最新的一个为准。由 [build] 设置。
  ClaudeContainerRef? storedContainer;

  /// 用户附加的数据文件，按会话顺序排列 —— 新建容器需要这些；
  /// [unseenDataFiles] 是记下 [storedContainer] 那条消息之后才附加的，
  /// 也就是该容器仍缺的（没有容器时就是全部）。一条被删掉的回复、一次在发出
  /// 请求前就失败的发送、一个关掉了工具的回合：每一种都会在容器与最后一条
  /// 消息之间留下文件，所以“取最后一条消息的”是错的规则。[turnDataFiles]
  /// 指的是最后一条消息的那些，也就是本回合相关的那些。只算用户自己附加的；
  /// 模型产出的内容存在它自己的消息上，由容器决定留或丢。由 [build] 设置。
  final dataFiles = <InternalDocumentRef>[];
  final unseenDataFiles = <InternalDocumentRef>[];
  final turnDataFiles = <InternalDocumentRef>[];

  /// 一个响应的块列表，已按本端点可发送的形式整理过。
  List<Map<String, dynamic>> sanitize(Iterable<Map> blocks) {
    return [
      for (final block in blocks)
        if (_keepBlock((block['type'] ?? '').toString()))
          block.map((key, value) => MapEntry(key.toString(), value)),
    ];
  }

  bool _keepBlock(String type) {
    if (skipRedactedThinkingBlocks && type == 'redacted_thinking') return false;
    if (!replayServerToolBlocks &&
        (type == 'server_tool_use' || type.endsWith('_tool_result'))) {
      return false;
    }
    return true;
  }

  /// 已剔除系统提示词的 [messages]。数组以 `user` 回合开头，这是 API 的要求
  /// —— 见 [ensureClaudeFirstTurnIsUser]。
  Future<List<Map<String, dynamic>>> build(
    List<Map<String, dynamic>> messages,
  ) async {
    final out = <Map<String, dynamic>>[];
    final pendingResults = <Map<String, dynamic>>[];
    final replayedClientCalls = <String>{};
    // API 拒绝助手回合里的 `image` 块，但模型画的图表往往正是用户下一个问题
    // 所指。这类图片在此暂存，并作为下一条用户消息的开头，模型仍能看到它们。
    final carriedImages = <Map<String, dynamic>>[];
    _ReplayedTurn? turn;

    /// 结果只在其所应答的调用发出之后才发送：API 会拒绝指向历史上并不存在的
    /// `tool_use` 的结果。
    void flushResults({Set<String>? only}) {
      final taken = <Map<String, dynamic>>[];
      pendingResults.removeWhere((result) {
        final id = (result['tool_use_id'] ?? '').toString();
        if (only != null && !only.contains(id)) return false;
        if (replayedClientCalls.contains(id)) taken.add(result);
        return true;
      });
      if (taken.isNotEmpty) out.add({'role': 'user', 'content': taken});
    }

    /// 发出 [turn] 的下一个响应，排在前一个响应所等待的客户端工具结果之后。
    /// 两者之间若没有结果，它们就是同一个助手回合。
    void emitResponse(_ReplayedTurn turn) {
      final blocks = turn.responses[turn.emitted];
      if (turn.emitted > 0) {
        flushResults(
          only: toolUseIdsInBlocks(
            turn.responses[turn.emitted - 1],
            clientOnly: true,
          ),
        );
      }
      final last = turn.messages.lastOrNull;
      if (last != null && identical(out.last, last)) {
        (last['content'] as List).addAll(blocks);
      } else {
        final message = <String, dynamic>{
          'role': 'assistant',
          'content': blocks,
        };
        out.add(message);
        turn.messages.add(message);
      }
      replayedClientCalls.addAll(toolUseIdsInBlocks(blocks, clientOnly: true));
      turn.emitted++;
    }

    /// 重放回合之后的那条持久化助手消息汇总了该回合每个响应的文本，而重放的块
    /// 本身已经带着这些文本。只有它们没覆盖到的部分 —— 流中途被截断的快照，
    /// 或是最后一个没有卡片记录它的响应 —— 仍需发送；出现其它不一致时以块为准，
    /// 因为那才是 API 实际产出的。
    void foldTurnText(_ReplayedTurn turn, Map<String, dynamic> m) {
      final said = turn.text.trim();
      final text = (m['content'] ?? '').toString().trim();
      final rest = said.isEmpty
          ? text
          : text.startsWith(said)
          ? text.substring(said.length).trim()
          : '';
      // 没有别的要说。此时这些结果可以与紧随其后的用户消息并排，
      // API 会把它们合并成本来就是的同一个回合。
      if (rest.isEmpty) return;
      final last = turn.messages.lastOrNull;
      if (pendingResults.isEmpty && last != null && identical(out.last, last)) {
        (last['content'] as List).add({'type': 'text', 'text': rest});
      } else {
        flushResults();
        out.add({'role': 'assistant', 'content': rest});
      }
    }

    for (var i = 0; i < messages.length; i++) {
      var m = messages[i];
      final role = (m['role'] ?? 'user').toString();
      if (role == 'assistant') {
        final ref = ClaudeContainerRef.decode(
          m[multimodalInternalClaudeContainerKey],
        );
        if (ref != null) {
          storedContainer = ref;
          unseenDataFiles.clear();
        }
      }
      if (role == 'user') {
        final files = parseInternalDocumentRefs(
          m[multimodalInternalDocumentPathsKey],
        ).where((doc) => isSandboxDataFile(fileName: doc.name, mime: doc.mime));
        dataFiles.addAll(files);
        unseenDataFiles.addAll(files);
        if (i == messages.length - 1) turnDataFiles.addAll(files);
      }
      if (role == 'tool') {
        final id = (m['tool_call_id'] ?? '').toString();
        // 以自己块形式重放的服务端工具，已经带着它的结果。
        if (id.isNotEmpty && !(turn?.serverToolIds.contains(id) ?? false)) {
          pendingResults.add({
            'type': 'tool_result',
            'tool_use_id': id,
            'content': claudeToolResultContent((m['content'] ?? '').toString()),
          });
        }
        continue;
      }

      if (role == 'assistant' && m['tool_calls'] is! List && _hasMedia(m)) {
        final split = await _splitParts(m, includeUserPaths: false);
        carriedImages.addAll(split.images);
        // 图片搬走之后，这条消息剩下的内容。
        m = {
          ...m,
          'content': split.text.map((block) => block['text']).join('\n'),
        };
      }

      if (turn != null) {
        while (turn.emitted < turn.responses.length) {
          emitResponse(turn);
        }
        // 图片前移之后，这条助手消息就是纯文本。
        if (role == 'assistant' && m['tool_calls'] is! List) {
          foldTurnText(turn, m);
          turn = null;
          continue;
        }
        turn = null;
      }
      flushResults();

      if (role == 'assistant' && m['tool_calls'] is List) {
        final toolCalls = m['tool_calls'] as List;
        turn = _readTurn(m, toolCalls);
        if (turn != null) {
          if (turn.responses.isNotEmpty) emitResponse(turn);
        } else {
          // 该回合没有任何记录：从工具调用重建它。
          final blocks = <Map<String, dynamic>>[];
          final text = (m['content'] ?? '').toString();
          if (text.trim().isNotEmpty && text.trim() != '\n\n') {
            blocks.add({'type': 'text', 'text': text});
          }
          for (final tc in toolCalls.whereType<Map>()) {
            final block = _toolUseBlockFromToolCall(tc);
            if (block != null) blocks.add(block);
          }
          if (blocks.isNotEmpty) {
            out.add({'role': 'assistant', 'content': blocks});
            replayedClientCalls.addAll(toolUseIdsInBlocks(blocks));
          }
        }
        continue;
      }

      out.add(
        await _plainMessage(
          m,
          role,
          isLast: i == messages.length - 1,
          carriedImages: carriedImages,
        ),
      );
    }

    if (turn != null && turn.emitted < turn.responses.length) {
      // 历史在某个客户端工具结果处截断：后续还没到的响应会预填答案，所以要去掉；
      // 随之去掉的还有那些结果只存在于其中的托管调用 —— 敞开重放，API 会拒绝。
      final lostResults = toolResultIdsInBlocks(
        turn.responses.skip(turn.emitted).expand((blocks) => blocks),
      );
      for (final message in turn.messages) {
        final blocks = message['content'] as List;
        blocks.removeWhere(
          (block) =>
              block['type'] == 'server_tool_use' &&
              lostResults.contains((block['id'] ?? '').toString()),
        );
        if (blocks.isEmpty) out.remove(message);
      }
    }
    flushResults();
    // 若把会话截断到从某条回复开始，开头就会是助手回合，API 会直接拒绝。
    ensureClaudeFirstTurnIsUser(out);
    return out;
  }

  /// 一条持久化的工具消息所记录的回合：优先取存下的回合 artifact；
  /// 若该消息写在 artifact 出现之前，则取其各卡片中最完整的一张 —— 每张卡片
  /// 都持有直到最后写入它的那个响应为止的内容，所以最后写入的那张最全。
  /// 完全没有记录时返回 null。
  _ReplayedTurn? _readTurn(Map<String, dynamic> m, List toolCalls) {
    var recorded = decodeClaudeTurn(m[multimodalInternalClaudeTurnKey]);
    if (recorded == null) {
      for (final tc in toolCalls.whereType<Map>()) {
        final responses = _recordedResponses(tc);
        if (responses != null && responses.length > (recorded?.length ?? 0)) {
          recorded = responses;
        }
      }
    }
    if (recorded == null) return null;

    final cards = <String, Map>{
      for (final tc in toolCalls.whereType<Map>())
        if ((tc['id'] ?? '').toString() case final id when id.isNotEmpty)
          id: tc,
    };
    final resolved = toolResultIdsInBlocks(recorded.expand((blocks) => blocks));
    final declared = <String>{};
    final responses = <List<Map<String, dynamic>>>[];
    for (final raw in recorded) {
      // 结果始终没到的 `server_tool_use`（流在两者之间中断）会重放成一次
      // 没有输出的调用。
      final blocks = sanitize(raw)
        ..removeWhere(
          (block) =>
              block['type'] == 'server_tool_use' &&
              !resolved.contains((block['id'] ?? '').toString()),
        );
      // 本端点丢弃其块的托管调用，改为以客户端工具对的形式重放，
      // 与这些工具出现之前的每次调用一样。
      final kept = toolUseIdsInBlocks(blocks);
      for (final id in toolUseIdsInBlocks(raw)) {
        declared.add(id);
        if (replayServerToolBlocks || kept.contains(id)) continue;
        final block = _toolUseBlockFromToolCall(cards[id]);
        if (block != null) blocks.add(block);
      }
      responses.add(blocks);
    }
    // 记录没覆盖到的调用（该回合在发出它的那个响应里就被截断了）
    // 排在所有已记录内容之后。
    for (final entry in cards.entries) {
      if (declared.contains(entry.key)) continue;
      final block = _toolUseBlockFromToolCall(entry.value);
      if (block != null) responses.last.add(block);
    }
    // 一个最后没东西可发的回合，仍然拥有它自己的 `tool` 消息。
    responses.removeWhere((blocks) => blocks.isEmpty);
    return _ReplayedTurn(
      responses: responses,
      text: joinedTextOfBlocks(recorded.expand((blocks) => blocks)),
      serverToolIds: replayServerToolBlocks
          ? {
              for (final block in recorded.expand((blocks) => blocks))
                if (block['type'] == 'server_tool_use')
                  (block['id'] ?? '').toString(),
            }
          : const <String>{},
    );
  }

  /// 旧版本应用写下的卡片在其 metadata 里记录的响应：较新的格式把该回合直到
  /// 自己为止的响应放在 `responses` 下；更早的格式只有一个响应，键名为
  /// `assistant_blocks`。
  static List<List<Map<String, dynamic>>>? _recordedResponses(Map tc) {
    final meta = tc['metadata'];
    if (meta is! Map) return null;
    final anthropic = meta['anthropic'];
    if (anthropic is! Map) return null;
    return _responsesOf(
      anthropic['responses'] ?? [anthropic['assistant_blocks']],
    );
  }

  static Map<String, dynamic>? _toolUseBlockFromToolCall(Map? tc) {
    if (tc == null) return null;
    final id = (tc['id'] ?? '').toString();
    final fn = tc['function'];
    if (id.isEmpty || fn is! Map) return null;
    Map<String, dynamic> input = const <String, dynamic>{};
    try {
      input = (jsonDecode((fn['arguments'] ?? '{}').toString()) as Map)
          .cast<String, dynamic>();
    } catch (_) {}
    return {
      'type': 'tool_use',
      'id': id,
      'name': (fn['name'] ?? '').toString(),
      'input': input,
    };
  }

  /// 只做语义层面的媒体识别 —— 自定义附件标记不予识别。附件通过结构化的
  /// media-path 键 / userImagePaths，以及 Markdown 的 ![](...) 传入。
  bool _hasMedia(Map<String, dynamic> m) =>
      shouldParseMarkdownImages(
        (m['content'] ?? '').toString(),
        skipImageParsing: skipImageParsing,
      ) ||
      parseInternalMediaRefs(m[multimodalInternalMediaPathsKey]).isNotEmpty;

  Future<Map<String, dynamic>> _plainMessage(
    Map<String, dynamic> m,
    String role, {
    required bool isLast,
    required List<Map<String, dynamic>> carriedImages,
  }) async {
    final raw = (m['content'] ?? '').toString();
    final hasAttachedImages =
        isLast && role == 'user' && (userImagePaths?.isNotEmpty == true);
    if (role != 'user' ||
        !(_hasMedia(m) || hasAttachedImages || carriedImages.isNotEmpty)) {
      return {'role': role, 'content': raw};
    }

    final split = await _splitParts(m, includeUserPaths: hasAttachedImages);
    final parts = <Map<String, dynamic>>[
      if (carriedImages.isNotEmpty) ...[
        // 没有这个标注，模型会把自己画的图表当成用户上传。
        {'type': 'text', 'text': 'Images from your previous reply:'},
        ...carriedImages,
      ],
      ...split.text,
      ...split.images,
    ];
    carriedImages.clear();
    return {'role': role, 'content': parts.isEmpty ? raw : parts};
  }

  /// 把一条消息拆成 Claude 接受的文本块与图片块：Markdown 图片和内部媒体引用
  /// 变成图片块，远程 URL 与不支持的媒体保持为文本。
  Future<({List<Map<String, dynamic>> text, List<Map<String, dynamic>> images})>
  _splitParts(Map<String, dynamic> m, {required bool includeUserPaths}) async {
    final raw = (m['content'] ?? '').toString();
    final text = <Map<String, dynamic>>[];
    final images = <Map<String, dynamic>>[];
    final seenSources = <String>{};
    String normalizeSrc(String src) {
      if (src.startsWith('http') || src.startsWith('data:')) return src;
      try {
        return SandboxPathResolver.fix(src);
      } catch (_) {
        return src;
      }
    }

    Future<void> addClaudeImage(String source, {String? explicitMime}) async {
      final normalized = normalizeSrc(source);
      if (!seenSources.add(normalized)) return;
      if (source.startsWith('http://') || source.startsWith('https://')) {
        final download = remoteMediaBase64;
        if (download == null) {
          // 远程 URL 保持官方 Claude 一贯的行为。
          text.add({'type': 'text', 'text': source});
          return;
        }
        // Vertex 不接受 URL 形式的图片源，必须先下载再以 base64 内联。
        final mime = normalizeClaudeImageMime(
          (explicitMime != null && explicitMime.trim().isNotEmpty)
              ? explicitMime.trim()
              : mimeFromPath(source),
        );
        // 视频、音频等非 Claude 图像 MIME 不输出图像块，改以文本发出原链接。
        if (!isClaudeSupportedImageMime(mime)) {
          text.add({'type': 'text', 'text': source});
          return;
        }
        try {
          final b64 = await download(source);
          images.add({
            'type': 'image',
            'source': {'type': 'base64', 'media_type': mime, 'data': b64},
          });
        } catch (_) {
          text.add({
            'type': 'text',
            'text': '(image failed to download) $source',
          });
        }
        return;
      }
      if (source.startsWith('data:')) {
        final mime = normalizeClaudeImageMime(
          (explicitMime != null && explicitMime.trim().isNotEmpty)
              ? explicitMime.trim()
              : mimeFromDataUrl(source),
        );
        final idx = source.indexOf('base64,');
        if (idx > 0) {
          images.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': mime,
              'data': source.substring(idx + 7),
            },
          });
        }
        return;
      }
      final mime = normalizeClaudeImageMime(
        (explicitMime != null && explicitMime.trim().isNotEmpty)
            ? explicitMime.trim()
            : mimeFromPath(source),
      );
      final b64 = await tryEncodeBase64File(source, withPrefix: false);
      if (b64 == null) return;
      images.add({
        'type': 'image',
        'source': {'type': 'base64', 'media_type': mime, 'data': b64},
      });
    }

    final parsed = await parseTextAndImages(
      raw,
      allowRemoteImages: true,
      allowLocalImages: true,
      keepRemoteMarkdownText: true,
      // 本处与上面的调用一样要把“跳过图片解析”透传下去，否则沙盒/工作区
      // 场景下本路径仍会去解析图片，与调用方的意图不符。
      skipImageParsing: skipImageParsing,
    );
    if (parsed.text.isNotEmpty) {
      text.add({'type': 'text', 'text': parsed.text});
    }
    for (final ref in parsed.images) {
      if (ref.kind == 'data' || ref.kind == 'path' || ref.kind == 'url') {
        await addClaudeImage(ref.src);
      }
    }
    final supplementalRefs = supplementalMediaRefs(
      internalRaw: m[multimodalInternalMediaPathsKey],
      userPaths: userImagePaths,
      includeUserPaths: includeUserPaths,
    );
    for (final mediaRef in supplementalRefs) {
      final mime = mimeForInternalMediaRef(mediaRef);
      // 视频/音频以及其它非 Claude 图片类型（例如 video/mp4），一律不生成
      // Anthropic 图片块。
      if (isVideoMime(mime) ||
          isAudioMime(mime) ||
          !isClaudeSupportedImageMime(mime)) {
        final uri = mediaRef.uri;
        final isRemote =
            uri.startsWith('http://') || uri.startsWith('https://');
        if (isRemote) {
          final normalized = normalizeSrc(uri);
          if (seenSources.add(normalized)) {
            text.add({'type': 'text', 'text': uri});
          }
        }
        continue;
      }
      await addClaudeImage(mediaRef.uri, explicitMime: mediaRef.mime);
    }
    return (text: text, images: images);
  }
}

String normalizeClaudeImageMime(String mime) {
  final normalized = mime.trim().toLowerCase();
  if (normalized == 'image/jpg') return 'image/jpeg';
  return normalized;
}

bool isClaudeSupportedImageMime(String mime) {
  switch (normalizeClaudeImageMime(mime)) {
    case 'image/jpeg':
    case 'image/png':
    case 'image/gif':
    case 'image/webp':
      return true;
    default:
      return false;
  }
}

/// 正在重放的持久化工具回合：它的各个响应（按 API 产出的顺序、已按本端点
/// 清洗过），以及重放进行到了哪里。
class _ReplayedTurn {
  _ReplayedTurn({
    required this.responses,
    required this.text,
    required this.serverToolIds,
  });

  final List<List<Map<String, dynamic>>> responses;

  /// 整回合的文本，由每个响应拼接而成 —— 也就是其后那条持久化助手消息
  /// 所汇总的内容。
  final String text;

  /// 以自己块形式重放的服务端工具；若为它们合成 `tool` 消息，
  /// 就会产生孤立的 `tool_result`。
  final Set<String> serverToolIds;

  int emitted = 0;
  final List<Map<String, dynamic>> messages = [];
}
