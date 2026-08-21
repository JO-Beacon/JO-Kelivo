import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/token_usage.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../chat/widgets/chat_message_widget.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import 'streaming_content_notifier.dart';

export 'streaming_content_notifier.dart';

/// 管理流式消息生成的控制器。
///
/// 此控制器负责：
/// - 流式分块处理（内容、推理、工具调用、工具结果）
/// - 流式节流，降低 UI 重建频率
/// - 推理状态管理（包括片段）
/// - 工具 UI 状态管理
/// - 流式处理期间的行内图片清理
///
/// 此控制器设计为与 ChatController 配合使用，
/// 供主页处理流式生成，而不会使 UI 代码杂乱。
class StreamController {
  StreamController({
    required this._chatService,
    required this.onStateChanged,
    required this.getSettingsProvider,
    required this.getCurrentConversationId,
    this.onStreamTick,
  });

  final ChatService _chatService;

  /// 状态变化时的回调（在控件中触发 setState）。
  /// 注意：此回调只应用于非流式状态变化。
  /// 流式内容更新请改用 streamingContentNotifier。
  final VoidCallback onStateChanged;

  /// 流式更新期间触发的可选回调（例如自动滚动）。
  final VoidCallback? onStreamTick;

  /// 流式内容更新的轻量通知器。
  /// 这样可避免在流式处理期间触发整页重建。
  final StreamingContentNotifier streamingContentNotifier =
      StreamingContentNotifier();

  /// 当前正在流式处理的消息 ID 集合。
  /// 用于在流式处理期间抑制 onStateChanged 调用。
  final Set<String> _activeStreamingIds = <String>{};

  /// 检查当前是否有消息正在流式处理。
  bool get isAnyMessageStreaming => _activeStreamingIds.isNotEmpty;

  /// 将消息标记为正在流式处理。
  /// 同时为此消息创建 StreamingContentNotifier，使 MessageListView
  /// 能检测到它并使用 ValueListenableBuilder。
  void markStreamingStarted(String messageId) {
    _activeStreamingIds.add(messageId);
    // 预先创建通知器，使 MessageListView 能检测到流式状态
    streamingContentNotifier.getNotifier(messageId);
  }

  /// 将消息标记为不再流式处理。
  void markStreamingEnded(String messageId) {
    _activeStreamingIds.remove(messageId);
  }

  /// 仅当没有消息正在流式处理时调用 onStateChanged。
  /// 流式处理期间的 UI 更新由 ValueListenableBuilder 处理。
  void _safeNotifyStateChanged() {
    if (_activeStreamingIds.isEmpty) {
      onStateChanged();
    }
  }

  /// 获取当前设置提供器（用于自动折叠设置等）。
  final SettingsProvider Function() getSettingsProvider;

  /// 获取当前会话 ID（用于检查是否应更新 UI）。
  final String? Function() getCurrentConversationId;

  // ============================================================================
  // 状态映射
  // ============================================================================

  /// 每条助手消息的推理数据。
  final Map<String, ReasoningData> _reasoning = <String, ReasoningData>{};
  Map<String, ReasoningData> get reasoning => _reasoning;

  /// 每条助手消息的推理片段（用于工具/思考交错显示）。
  final Map<String, List<ReasoningSegmentData>> _reasoningSegments =
      <String, List<ReasoningSegmentData>>{};
  Map<String, List<ReasoningSegmentData>> get reasoningSegments =>
      _reasoningSegments;

  /// 每条助手消息的内容/文本拆分元数据。
  final Map<String, ContentSplitData> _contentSplits =
      <String, ContentSplitData>{};
  Map<String, ContentSplitData> get contentSplits => _contentSplits;

  /// 每条助手消息的工具 UI 部分。
  final Map<String, List<ToolUIPart>> _toolParts = <String, List<ToolUIPart>>{};
  Map<String, List<ToolUIPart>> get toolParts => _toolParts;

  /// 每条助手消息的 Gemini 思考签名。
  final Map<String, String> _geminiThoughtSigs = <String, String>{};
  Map<String, String> get geminiThoughtSigs => _geminiThoughtSigs;

  /// 每条助手消息的供应商推理详情（OpenRouter 风格的 `reasoning_details`，
  /// 可能携带思考签名）。持久化在 reasoningSegmentsJson 负载中，
  /// 以便在后续轮次中回传。
  final Map<String, dynamic> _reasoningDetails = <String, dynamic>{};
  Map<String, dynamic> get reasoningDetails => _reasoningDetails;

  /// 按消息记忆化已解码的 reasoningSegmentsJson 负载，
  /// 使重复恢复共享一次 JSON 解码。
  final Map<String, _DecodedReasoningPayload> _decodedReasoningPayloads =
      <String, _DecodedReasoningPayload>{};

  /// 已恢复持久化 UI 状态的助手消息 ID；重复恢复
  /// （例如分页重新遍历整个窗口）会跳过它们，直到其状态被清除。
  final Set<String> _restoredUiMessageIds = <String>{};

  int _reasoningPayloadDecodeCount = 0;

  /// 实际执行的 reasoningSegmentsJson 负载解码次数。
  @visibleForTesting
  int get reasoningPayloadDecodeCount => _reasoningPayloadDecodeCount;

  /// 存储消息的最新推理详情快照。
  void setReasoningDetails(String messageId, dynamic details) {
    if (details == null) return;
    _reasoningDetails[messageId] = details;
  }

  // ============================================================================
  // 节流状态
  // ============================================================================

  /// 流式内容的 UI 输出间隔。
  static const Duration _streamThrottleInterval = Duration(milliseconds: 50);
  static const int _streamSmoothMinCount = 2;
  static const int _streamSmoothBaseCount = 40;
  static const int _streamSmoothMaxCount = 240;
  static const double _streamSmoothPickRate = 0.1;
  static const int _streamSmoothMoveAverageLength = 10;

  /// 按消息 ID 的节流计时器。
  final Map<String, Timer?> _streamThrottleTimers = <String, Timer?>{};

  /// 按消息的平滑输出状态。
  final Map<String, _StreamSmoothState> _streamSmoothStates =
      <String, _StreamSmoothState>{};

  /// 清理行内 base64 图片前的延迟。
  static const Duration _inlineImageSanitizeDelay = Duration(milliseconds: 120);

  /// 按消息的行内图片清理计时器。
  final Map<String, Timer?> _inlineImageSanitizeTimers = <String, Timer?>{};

  /// 当前正在清理的消息 ID 集合。
  final Set<String> _inlineImageSanitizing = <String>{};

  /// 用于捕获 Gemini 思考签名注释的正则表达式。
  static final RegExp _geminiThoughtSigRe = RegExp(
    r'<!--\s*gemini_thought_signatures:.*?-->',
    dotAll: true,
  );

  // ============================================================================
  // 公共方法 - 状态访问
  // ============================================================================

  /// 获取消息的推理数据。
  ReasoningData? getReasoningData(String messageId) => _reasoning[messageId];

  /// 设置消息的推理数据。
  void setReasoningData(String messageId, ReasoningData data) {
    _reasoning[messageId] = data;
  }

  /// 移除消息的推理数据。
  void removeReasoningData(String messageId) {
    _reasoning.remove(messageId);
  }

  /// 获取消息的推理片段。
  List<ReasoningSegmentData>? getReasoningSegments(String messageId) =>
      _reasoningSegments[messageId];

  /// 设置消息的推理片段。
  void setReasoningSegments(
    String messageId,
    List<ReasoningSegmentData> segments,
  ) {
    _reasoningSegments[messageId] = segments;
  }

  /// 移除消息的推理片段。
  void removeReasoningSegments(String messageId) {
    _reasoningSegments.remove(messageId);
  }

  /// 获取消息的内容拆分元数据。
  ContentSplitData? getContentSplitData(String messageId) =>
      _contentSplits[messageId];

  /// 设置消息的内容拆分元数据。
  void setContentSplitData(String messageId, ContentSplitData data) {
    _contentSplits[messageId] = data;
  }

  /// 移除消息的内容拆分元数据。
  void removeContentSplitData(String messageId) {
    _contentSplits.remove(messageId);
  }

  int getReasoningSegmentCount(String messageId) =>
      _reasoningSegments[messageId]?.length ?? 0;

  int getToolPartsCount(String messageId) => _toolParts[messageId]?.length ?? 0;

  /// 获取消息的工具部分。
  List<ToolUIPart>? getToolParts(String messageId) => _toolParts[messageId];

  /// 设置消息的工具部分。
  void setToolParts(String messageId, List<ToolUIPart> parts) {
    _toolParts[messageId] = parts;
  }

  /// 移除消息的工具部分。
  void removeToolParts(String messageId) {
    _toolParts.remove(messageId);
  }

  /// 清除消息的所有状态（推理、片段、工具）。
  void clearMessageState(String messageId) {
    _reasoning.remove(messageId);
    _reasoningSegments.remove(messageId);
    _contentSplits.remove(messageId);
    _toolParts.remove(messageId);
    _geminiThoughtSigs.remove(messageId);
    _reasoningDetails.remove(messageId);
    _decodedReasoningPayloads.remove(messageId);
    _restoredUiMessageIds.remove(messageId);
    _cleanupStreamTimers(messageId);
  }

  /// 清除所有状态映射（用于新会话）。
  void clearAllState() {
    _reasoning.clear();
    _reasoningSegments.clear();
    _contentSplits.clear();
    _toolParts.clear();
    _geminiThoughtSigs.clear();
    _reasoningDetails.clear();
    _decodedReasoningPayloads.clear();
    _restoredUiMessageIds.clear();
    _cancelAllTimers();
    streamingContentNotifier.clear();
  }

  // ============================================================================
  // Gemini 思考签名处理
  // ============================================================================

  /// 从内容中捕获并剥离 Gemini 思考签名。
  String captureGeminiThoughtSignature(String content, String messageId) {
    if (content.isEmpty) return content;
    final m = _geminiThoughtSigRe.firstMatch(content);
    if (m != null) {
      final sig = m.group(0) ?? '';
      if (sig.isNotEmpty) {
        if (_geminiThoughtSigs[messageId] != sig) {
          _geminiThoughtSigs[messageId] = sig;
          unawaited(_chatService.setGeminiThoughtSignature(messageId, sig));
        }
      }
      content = content.replaceAll(_geminiThoughtSigRe, '').trimRight();
    }
    return content;
  }

  /// 在发送历史时，为 API 调用追加 Gemini 思考签名。
  String appendGeminiThoughtSignatureForApi(
    ChatMessage message,
    String content,
  ) {
    String? sig = _geminiThoughtSigs[message.id];
    sig ??= _chatService.getGeminiThoughtSignature(message.id);
    if (sig != null &&
        sig.isNotEmpty &&
        !content.contains('gemini_thought_signatures:')) {
      if (content.isEmpty) return sig;
      return '$content\n$sig';
    }
    return content;
  }

  /// 清除 Gemini 思考签名映射。
  void clearGeminiThoughtSigs() {
    _geminiThoughtSigs.clear();
  }

  // ============================================================================
  // 推理序列化
  // ============================================================================

  /// 将推理片段序列化为 JSON 字符串。
  String serializeReasoningSegments(List<ReasoningSegmentData> segments) {
    final list = segments
        .map(
          (s) => {
            'text': s.text,
            'startAt': s.startAt?.toIso8601String(),
            'finishedAt': s.finishedAt?.toIso8601String(),
            'expanded': s.expanded,
            'toolStartIndex': s.toolStartIndex,
          },
        )
        .toList();
    return _encodeJson(list);
  }

  String serializeReasoningSegmentsWithSplits(
    List<ReasoningSegmentData> segments, {
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
    dynamic reasoningDetails,
  }) {
    final list = segments
        .map(
          (s) => {
            'text': s.text,
            'startAt': s.startAt?.toIso8601String(),
            'finishedAt': s.finishedAt?.toIso8601String(),
            'expanded': s.expanded,
            'toolStartIndex': s.toolStartIndex,
          },
        )
        .toList();

    if (contentSplitOffsets == null &&
        reasoningCountAtSplit == null &&
        toolCountAtSplit == null &&
        reasoningDetails == null) {
      return _encodeJson(list);
    }

    final normalized = _normalizeContentSplitData(
      ContentSplitData(
        offsets: List<int>.of(contentSplitOffsets ?? const <int>[]),
        reasoningCounts: List<int>.of(reasoningCountAtSplit ?? const <int>[]),
        toolCounts: List<int>.of(toolCountAtSplit ?? const <int>[]),
      ),
    );

    return _encodeJson({
      'v': 2,
      'segments': list,
      'contentSplits': {
        'offsets': normalized.offsets,
        'reasoningCounts': normalized.reasoningCounts,
        'toolCounts': normalized.toolCounts,
      },
      if (reasoningDetails != null) 'reasoningDetails': reasoningDetails,
    });
  }

  /// 从序列化的 reasoningSegmentsJson 负载中提取
  /// 已持久化的供应商推理详情（如有）。
  dynamic deserializeReasoningDetails(String? json) {
    return _DecodedReasoningPayload.decode(json).reasoningDetails;
  }

  /// 从 JSON 字符串反序列化推理片段。
  List<ReasoningSegmentData> deserializeReasoningSegments(String? json) {
    return _DecodedReasoningPayload.decode(json).segments;
  }

  ContentSplitData? deserializeContentSplits(String? json) {
    return _DecodedReasoningPayload.decode(json).contentSplits;
  }

  static ContentSplitData _normalizeContentSplitData(ContentSplitData data) {
    final length = math.min(
      data.offsets.length,
      math.min(data.reasoningCounts.length, data.toolCounts.length),
    );
    return ContentSplitData(
      offsets: List<int>.of(data.offsets.take(length)),
      reasoningCounts: List<int>.of(data.reasoningCounts.take(length)),
      toolCounts: List<int>.of(data.toolCounts.take(length)),
    );
  }

  // 简单 JSON 编解码，避免在此文件导入 dart:convert
  String _encodeJson(dynamic obj) {
    return _jsonEncode(obj);
  }

  // ============================================================================
  // 工具部分去重
  // ============================================================================

  /// 按 id 去重工具 UI 部分；id 为空时按 name+args 去重。
  List<ToolUIPart> dedupeToolPartsList(List<ToolUIPart> parts) {
    final completedIds = <String>{
      for (final p in parts)
        if (p.id.trim().isNotEmpty && _hasToolContent(p.content)) p.id.trim(),
    };
    final completedNoIdBases = <String>{
      for (final p in parts)
        if (p.id.trim().isEmpty && _hasToolContent(p.content))
          _toolDedupeBase(p.toolName, p.arguments),
    };
    final indexByKey = <String, int>{};
    final out = <ToolUIPart>[];
    for (final p in parts) {
      final id = p.id.trim();
      if (!_hasToolContent(p.content) &&
          ((id.isNotEmpty && completedIds.contains(id)) ||
              (id.isEmpty &&
                  completedNoIdBases.contains(
                    _toolDedupeBase(p.toolName, p.arguments),
                  )))) {
        continue;
      }
      final key = _toolDedupeKey(
        id: p.id,
        name: p.toolName,
        arguments: p.arguments,
        content: p.content,
      );
      final existingIndex = indexByKey[key];
      if (existingIndex != null) {
        if (id.isNotEmpty) out[existingIndex] = p;
        continue;
      }
      indexByKey[key] = out.length;
      out.add(p);
    }
    return out;
  }

  /// 去重原始持久化工具事件。
  List<Map<String, dynamic>> dedupeToolEvents(
    List<Map<String, dynamic>> events,
  ) {
    final completedIds = <String>{
      for (final e in events)
        if ((e['id']?.toString() ?? '').trim().isNotEmpty &&
            _hasToolContent(e['content']?.toString()))
          (e['id']?.toString() ?? '').trim(),
    };
    final completedNoIdBases = <String>{
      for (final e in events)
        if ((e['id']?.toString() ?? '').trim().isEmpty &&
            _hasToolContent(e['content']?.toString()))
          _toolDedupeBase(
            e['name']?.toString() ?? '',
            (e['arguments'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{},
          ),
    };
    final indexByKey = <String, int>{};
    final out = <Map<String, dynamic>>[];
    for (final e in events) {
      final id = (e['id']?.toString() ?? '').trim();
      final name = (e['name']?.toString() ?? '');
      final args =
          ((e['arguments'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{});
      if (!_hasToolContent(e['content']?.toString()) &&
          ((id.isNotEmpty && completedIds.contains(id)) ||
              (id.isEmpty &&
                  completedNoIdBases.contains(_toolDedupeBase(name, args))))) {
        continue;
      }
      final key = _toolDedupeKey(
        id: id,
        name: name,
        arguments: args,
        content: e['content']?.toString(),
      );
      final normalizedEvent = e.map((k, v) => MapEntry(k.toString(), v));
      final existingIndex = indexByKey[key];
      if (existingIndex != null) {
        if (id.isNotEmpty) out[existingIndex] = normalizedEvent;
        continue;
      }
      indexByKey[key] = out.length;
      out.add(normalizedEvent);
    }
    return out;
  }

  String _toolDedupeBase(String name, Map<String, dynamic> arguments) {
    return 'name:$name|args:${_encodeJson(arguments)}';
  }

  bool _hasToolContent(String? content) => content?.trim().isNotEmpty == true;

  String _toolDedupeKey({
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
  }) {
    final trimmedId = id.trim();
    if (trimmedId.isNotEmpty) return 'id:$trimmedId';

    final base = _toolDedupeBase(name, arguments);
    final trimmedContent = content?.trim();
    if (trimmedContent == null || trimmedContent.isEmpty) return base;
    return '$base|content:$trimmedContent';
  }

  // ============================================================================
  // 流式节流
  // ============================================================================

  /// 为流式内容调度节流的 UI 更新。
  ///
  /// 此方法使用 StreamingContentNotifier 只更新流式消息控件，
  /// 避免导致卡顿的整页重建。
  void scheduleThrottledUpdate(
    String messageId,
    String conversationId,
    String Function() contentBuilder, {
    required void Function(String messageId, String content, int totalTokens)
    updateMessageInList,
    required int totalTokens,
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    final state = _streamSmoothStates.putIfAbsent(
      messageId,
      _StreamSmoothState.new,
    );
    state
      ..conversationId = conversationId
      ..contentBuilder = contentBuilder
      ..totalTokens = totalTokens
      ..contentSplitOffsets = contentSplitOffsets
      ..reasoningCountAtSplit = reasoningCountAtSplit
      ..toolCountAtSplit = toolCountAtSplit
      ..promptTokens = promptTokens
      ..completionTokens = completionTokens
      ..cachedTokens = cachedTokens
      ..durationMs = durationMs
      ..updateMessageInList = updateMessageInList;

    // 确保此消息存在通知器
    streamingContentNotifier.getNotifier(messageId);

    _ensureStreamTimer(messageId);
  }

  void _ensureStreamTimer(String messageId) {
    _streamThrottleTimers[messageId] ??= Timer.periodic(
      _streamThrottleInterval,
      (_) => _flushSmoothStreamTick(messageId),
    );
  }

  void _publishDirtyReasoning(
    String messageId,
    _StreamSmoothState state, {
    required bool sameConversation,
  }) {
    if (!state.reasoningDirty) return;
    if (sameConversation) {
      streamingContentNotifier.updateReasoning(
        messageId,
        reasoningText: state.pendingReasoningText,
        reasoningStartAt: state.pendingReasoningStartAt,
        contentSplitOffsets: state.pendingReasoningSplitOffsets,
        reasoningCountAtSplit: state.pendingReasoningCounts,
        toolCountAtSplit: state.pendingToolCounts,
      );
    }
    state.reasoningDirty = false;
  }

  void _applyContentBuilder(_StreamSmoothState state) {
    final builder = state.contentBuilder;
    if (builder == null) return;
    state.targetContent = builder();
  }

  void _flushSmoothStreamTick(String messageId) {
    final state = _streamSmoothStates[messageId];
    if (state == null) return;
    if (getCurrentConversationId() != state.conversationId) return;

    _applyContentBuilder(state);
    final nextContent = state.takeNextContentSlice(
      minCount: _streamSmoothMinCount,
      baseCount: _streamSmoothBaseCount,
      maxCount: _streamSmoothMaxCount,
      pickRate: _streamSmoothPickRate,
      moveAverageLength: _streamSmoothMoveAverageLength,
    );
    final hadDirtyReasoning = state.reasoningDirty;
    _publishDirtyReasoning(messageId, state, sameConversation: true);
    if (nextContent != null) {
      _publishSmoothStreamContent(messageId, state, nextContent);
      return;
    }
    if (hadDirtyReasoning) onStreamTick?.call();
  }

  void _publishSmoothStreamContent(
    String messageId,
    _StreamSmoothState state,
    String content,
  ) {
    streamingContentNotifier.updateContent(
      messageId,
      content,
      state.totalTokens,
      contentSplitOffsets: state.contentSplitOffsets,
      reasoningCountAtSplit: state.reasoningCountAtSplit,
      toolCountAtSplit: state.toolCountAtSplit,
      promptTokens: state.promptTokens,
      completionTokens: state.completionTokens,
      cachedTokens: state.cachedTokens,
      durationMs: state.durationMs,
    );
    state.updateMessageInList?.call(
      messageId,
      state.targetContent,
      state.totalTokens,
    );
    onStreamTick?.call();
  }

  String? _flushPendingStreamUpdate(String messageId) {
    final state = _streamSmoothStates[messageId];
    if (state == null) return null;
    _applyContentBuilder(state);
    final sameConversation = getCurrentConversationId() == state.conversationId;
    final hadDirtyReasoning = state.reasoningDirty;
    _publishDirtyReasoning(
      messageId,
      state,
      sameConversation: sameConversation,
    );
    final content = state.flushTargetContent();
    if (content == null) {
      if (hadDirtyReasoning && sameConversation) onStreamTick?.call();
      return state.visibleContent;
    }
    if (sameConversation) {
      _publishSmoothStreamContent(messageId, state, content);
    } else {
      state.updateMessageInList?.call(
        messageId,
        state.targetContent,
        state.totalTokens,
      );
    }
    return content;
  }

  /// 获取消息的待处理流内容。
  String? getPendingStreamContent(String messageId) {
    final state = _streamSmoothStates[messageId];
    if (state == null) return null;
    _applyContentBuilder(state);
    return state.targetContent;
  }

  /// 设置待处理流内容（由行内图片清理器使用）。
  void setPendingStreamContent(String messageId, String content) {
    final state = _streamSmoothStates.putIfAbsent(
      messageId,
      _StreamSmoothState.new,
    );
    state
      ..targetContent = content
      ..contentBuilder = () => content;
  }

  /// 清理消息的流式节流计时器。
  void _cleanupStreamTimers(String messageId) {
    _flushPendingStreamUpdate(messageId);
    _streamThrottleTimers[messageId]?.cancel();
    _streamThrottleTimers.remove(messageId);
    _streamSmoothStates.remove(messageId);
    _inlineImageSanitizeTimers[messageId]?.cancel();
    _inlineImageSanitizeTimers.remove(messageId);
    _inlineImageSanitizing.remove(messageId);
  }

  /// 清理消息的计时器（公共 API）。
  void cleanupTimers(String messageId) {
    _cleanupStreamTimers(messageId);
  }

  /// 移除消息的流式内容通知器。
  ///
  /// 必须在 onMessagesChanged 之后调用，以避免竞态：
  /// UI 在没有通知器时重建，并回退到过期的
  /// message.content（可能仍为空）。
  /// 幂等操作：可安全调用多次。
  void removeStreamingNotifier(String messageId) {
    streamingContentNotifier.removeNotifier(messageId);
  }

  /// 取消所有节流计时器。
  void _cancelAllTimers() {
    for (final timer in _streamThrottleTimers.values) {
      timer?.cancel();
    }
    _streamThrottleTimers.clear();
    _streamSmoothStates.clear();
    for (final timer in _inlineImageSanitizeTimers.values) {
      timer?.cancel();
    }
    _inlineImageSanitizeTimers.clear();
    _inlineImageSanitizing.clear();
  }

  // ============================================================================
  // 行内图片清理
  // ============================================================================

  /// 调度行内 base64 图片清理。
  void scheduleInlineImageSanitize(
    String messageId, {
    String? latestContent,
    bool immediate = false,
    required Future<void> Function(String messageId, String sanitizedContent)
    onSanitized,
  }) {
    // 快速预检查，避免不必要的计时器
    final snapshot = latestContent ?? '';
    if (snapshot.isEmpty ||
        !snapshot.contains('data:image') ||
        !snapshot.contains('base64,')) {
      return;
    }

    // 按消息防抖
    _inlineImageSanitizeTimers[messageId]?.cancel();
    _inlineImageSanitizeTimers[messageId] = Timer(
      immediate ? Duration.zero : _inlineImageSanitizeDelay,
      () async {
        if (_inlineImageSanitizing.contains(messageId)) return;
        _inlineImageSanitizing.add(messageId);
        try {
          String current = latestContent ?? '';
          if (current.isEmpty ||
              !current.contains('data:image') ||
              !current.contains('base64,')) {
            return;
          }

          final sanitized =
              await MarkdownMediaSanitizer.replaceInlineBase64Images(current);
          if (sanitized == current) return;

          // 保持节流的 UI 更新同步。
          setPendingStreamContent(messageId, sanitized);
          await onSanitized(messageId, sanitized);
        } catch (_) {
          // 吞掉错误，避免流式 UI 崩溃
        } finally {
          _inlineImageSanitizing.remove(messageId);
          _inlineImageSanitizeTimers.remove(messageId);
        }
      },
    );
  }

  // ============================================================================
  // 流式分块处理
  // ============================================================================

  /// 处理流中的推理分块。
  Future<void> handleReasoningChunk(
    ChatStreamChunk chunk,
    StreamingState state,
  ) async {
    if ((chunk.reasoning ?? '').isEmpty || !state.ctx.supportsReasoning) return;

    final messageId = state.messageId;
    final conversationId = state.conversationId;
    state.hadThinkingBlock = true;
    _contentSplits[messageId] = _normalizeContentSplitData(
      ContentSplitData(
        offsets: List<int>.of(state.contentSplitOffsets),
        reasoningCounts: List<int>.of(state.reasoningCountAtSplit),
        toolCounts: List<int>.of(state.toolCountAtSplit),
      ),
    );

    if (state.ctx.streamOutput) {
      final initialExpanded = !getSettingsProvider().autoCollapseThinking;
      final isNewReasoning = !_reasoning.containsKey(messageId);
      final r = _reasoning[messageId] ?? ReasoningData();
      r.text += chunk.reasoning!;
      r.startAt ??= DateTime.now();
      // 注意：此处不要重置 r.expanded，以保留用户在流式处理期间的展开状态
      if (isNewReasoning) {
        r.expanded = initialExpanded;
      }
      _reasoning[messageId] = r;

      // 加入推理片段以进行混合显示
      final segments =
          _reasoningSegments[messageId] ?? <ReasoningSegmentData>[];
      if (segments.isEmpty) {
        final newSegment = ReasoningSegmentData();
        newSegment.text = chunk.reasoning!;
        newSegment.startAt = DateTime.now();
        newSegment.expanded = initialExpanded;
        newSegment.toolStartIndex = (_toolParts[messageId]?.length ?? 0);
        segments.add(newSegment);
      } else {
        final hasToolsAfterLastSegment =
            (_toolParts[messageId]?.isNotEmpty ?? false);
        final lastSegment = segments.last;
        if (hasToolsAfterLastSegment && lastSegment.finishedAt != null) {
          final newSegment = ReasoningSegmentData();
          newSegment.text = chunk.reasoning!;
          newSegment.startAt = DateTime.now();
          newSegment.expanded = initialExpanded;
          newSegment.toolStartIndex = (_toolParts[messageId]?.length ?? 0);
          segments.add(newSegment);
        } else {
          lastSegment.text += chunk.reasoning!;
          lastSegment.startAt ??= DateTime.now();
        }
      }
      _reasoningSegments[messageId] = segments;

      final smooth = _streamSmoothStates.putIfAbsent(
        messageId,
        _StreamSmoothState.new,
      );
      smooth
        ..conversationId = conversationId
        ..pendingReasoningText = r.text
        ..pendingReasoningStartAt = r.startAt
        ..pendingReasoningSplitOffsets = state.contentSplitOffsets
        ..pendingReasoningCounts = state.reasoningCountAtSplit
        ..pendingToolCounts = state.toolCountAtSplit
        ..reasoningDirty = true;
      streamingContentNotifier.getNotifier(messageId);
      _ensureStreamTimer(messageId);
    } else {
      state.reasoningStartAt ??= DateTime.now();
      state.bufferedReasoning += chunk.reasoning!;
    }
  }

  /// 处理流中的工具调用分块。
  Future<void> handleToolCallsChunk(
    ChatStreamChunk chunk,
    StreamingState state, {
    required Future<void> Function(String messageId, String json)
    updateReasoningSegmentsInDb,
    required Future<void> Function(
      String messageId,
      List<Map<String, dynamic>> events,
    )
    setToolEventsInDb,
    required List<Map<String, dynamic>> Function(String messageId)
    getToolEventsFromDb,
  }) async {
    if ((chunk.toolCalls ?? const []).isEmpty) return;

    final messageId = state.messageId;
    final conversationId = state.conversationId;
    state.hadThinkingBlock = true;
    _contentSplits[messageId] = _normalizeContentSplitData(
      ContentSplitData(
        offsets: List<int>.of(state.contentSplitOffsets),
        reasoningCounts: List<int>.of(state.reasoningCountAtSplit),
        toolCounts: List<int>.of(state.toolCountAtSplit),
      ),
    );

    // 工具开始时结束所有未完成的推理片段
    final segments = _reasoningSegments[messageId] ?? <ReasoningSegmentData>[];
    if (segments.isNotEmpty && segments.last.finishedAt == null) {
      segments.last.finishedAt = DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        segments.last.expanded = false;
        final rd = _reasoning[messageId];
        if (rd != null) rd.expanded = false;
      }
      _reasoningSegments[messageId] = segments;
      await updateReasoningSegmentsInDb(
        messageId,
        serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: state.contentSplitOffsets,
          reasoningCountAtSplit: state.reasoningCountAtSplit,
          toolCountAtSplit: state.toolCountAtSplit,
        ),
      );
    }

    // 添加工具调用占位项
    final existing = List<ToolUIPart>.of(_toolParts[messageId] ?? const []);
    for (final c in chunk.toolCalls!) {
      existing.add(
        ToolUIPart(
          id: c.id,
          toolName: c.name,
          arguments: c.arguments,
          loading: true,
        ),
      );
    }
    if (getCurrentConversationId() == conversationId) {
      _toolParts[messageId] = dedupeToolPartsList(existing);
      // 通过 StreamingContentNotifier 通知实时 UI 更新
      streamingContentNotifier.notifyToolPartsUpdated(
        messageId,
        contentSplitOffsets: state.contentSplitOffsets,
        reasoningCountAtSplit: state.reasoningCountAtSplit,
        toolCountAtSplit: state.toolCountAtSplit,
      );
    }

    // 持久化工具事件
    try {
      final prev = getToolEventsFromDb(messageId);
      final newEvents = <Map<String, dynamic>>[
        ...prev,
        for (final c in chunk.toolCalls!)
          {
            'id': c.id,
            'name': c.name,
            'arguments': c.arguments,
            'content': null,
            if (c.metadata != null && c.metadata!.isNotEmpty)
              'metadata': c.metadata,
          },
      ];
      await setToolEventsInDb(messageId, dedupeToolEvents(newEvents));
    } catch (_) {}
  }

  /// 处理流中的工具结果分块。
  Future<void> handleToolResultsChunk(
    ChatStreamChunk chunk,
    StreamingState state, {
    required Future<void> Function(
      String messageId, {
      required String id,
      required String name,
      required Map<String, dynamic> arguments,
      String? content,
      Map<String, dynamic>? metadata,
    })
    upsertToolEventInDb,
  }) async {
    if ((chunk.toolResults ?? const []).isEmpty) return;

    final messageId = state.messageId;
    final conversationId = state.conversationId;

    final parts = List<ToolUIPart>.of(_toolParts[messageId] ?? const []);
    for (final r in chunk.toolResults!) {
      int idx = -1;
      for (int i = 0; i < parts.length; i++) {
        if (parts[i].loading &&
            (parts[i].id == r.id ||
                (parts[i].id.isEmpty && parts[i].toolName == r.name))) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        parts[idx] = ToolUIPart(
          id: parts[idx].id,
          toolName: parts[idx].toolName,
          arguments: r.arguments.isNotEmpty
              ? Map<String, dynamic>.from(r.arguments)
              : parts[idx].arguments,
          content: r.content,
          loading: false,
        );
      } else {
        parts.add(
          ToolUIPart(
            id: r.id,
            toolName: r.name,
            arguments: r.arguments,
            content: r.content,
            loading: false,
          ),
        );
      }
      try {
        final args = Map<String, dynamic>.from(r.arguments);
        await upsertToolEventInDb(
          messageId,
          id: r.id,
          name: r.name,
          arguments: args,
          content: r.content,
          metadata: r.metadata,
        );
      } catch (_) {}
    }
    if (getCurrentConversationId() == conversationId) {
      _toolParts[messageId] = dedupeToolPartsList(parts);
      // 通过 StreamingContentNotifier 通知实时 UI 更新
      final splits = _contentSplits[messageId];
      streamingContentNotifier.notifyToolPartsUpdated(
        messageId,
        contentSplitOffsets: splits?.offsets,
        reasoningCountAtSplit: splits?.reasoningCounts,
        toolCountAtSplit: splits?.toolCounts,
      );
    }
  }

  /// 当内容开始到达时结束推理片段。
  Future<void> finishReasoningOnContent(
    StreamingState state, {
    required Future<void> Function(
      String messageId, {
      String? reasoningText,
      DateTime? reasoningFinishedAt,
      String? reasoningSegmentsJson,
    })
    updateReasoningInDb,
  }) async {
    final messageId = state.messageId;

    final r = _reasoning[messageId];
    if (r != null && r.startAt != null && r.finishedAt == null) {
      r.finishedAt = DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        r.expanded = false;
      }
      _reasoning[messageId] = r;
      await updateReasoningInDb(
        messageId,
        reasoningText: r.text,
        reasoningFinishedAt: r.finishedAt,
      );
      _safeNotifyStateChanged();
    }

    final segments = _reasoningSegments[messageId];
    if (segments != null &&
        segments.isNotEmpty &&
        segments.last.finishedAt == null) {
      segments.last.finishedAt = DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        segments.last.expanded = false;
      }
      _reasoningSegments[messageId] = segments;
      _safeNotifyStateChanged();
      await updateReasoningInDb(
        messageId,
        reasoningSegmentsJson: serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: _contentSplits[messageId]?.offsets,
          reasoningCountAtSplit: _contentSplits[messageId]?.reasoningCounts,
          toolCountAtSplit: _contentSplits[messageId]?.toolCounts,
        ),
      );
    }
  }

  // 注意：transformAssistantContent 保留在 home_page.dart，因为它使用 AssistantRegexScope

  /// 完成流式处理并结束推理状态。
  Future<void> finalizeReasoningState(
    String messageId, {
    required Future<void> Function(
      String messageId, {
      String? reasoningText,
      DateTime? reasoningFinishedAt,
      String? reasoningSegmentsJson,
    })
    updateReasoningInDb,
  }) async {
    // 完成推理数据
    final r = _reasoning[messageId];
    if (r != null) {
      r.finishedAt ??= DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        r.expanded = false;
      }
      _reasoning[messageId] = r;
      _safeNotifyStateChanged();
    }

    // 同时结束所有未完成的推理片段
    final segments = _reasoningSegments[messageId];
    if (segments != null &&
        segments.isNotEmpty &&
        segments.last.finishedAt == null) {
      segments.last.finishedAt = DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        segments.last.expanded = false;
      }
      _reasoningSegments[messageId] = segments;
      _safeNotifyStateChanged();
    }

    // 将推理片段保存到数据库
    if (segments != null && segments.isNotEmpty) {
      await updateReasoningInDb(
        messageId,
        reasoningSegmentsJson: serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: _contentSplits[messageId]?.offsets,
          reasoningCountAtSplit: _contentSplits[messageId]?.reasoningCounts,
          toolCountAtSplit: _contentSplits[messageId]?.toolCounts,
        ),
      );
    }
  }

  /// 检查消息是否有任何仍在加载的工具部分。
  bool hasLoadingTools(String messageId) {
    return _toolParts[messageId]?.any((p) => p.loading) ?? false;
  }

  // ============================================================================
  // 统一推理完成
  // ============================================================================

  /// 如果尚未完成，则完成消息的推理。
  ///
  /// 这是处理推理完成逻辑的统一方法，此前该逻辑重复出现在
  /// home_page.dart 的多个位置：
  /// - _cancelStreaming（597-617 行）
  /// - _finishReasoningOnContent（3738-3770 行）
  /// - _finishStreaming（3886-3917 行）
  /// - _handleStreamError（3954-3970 行）
  ///
  /// 如果确实改变了任何状态，返回 true。
  bool finishReasoningIfNeeded(String messageId, {bool forceCollapse = false}) {
    bool changed = false;
    final autoCollapse =
        forceCollapse || getSettingsProvider().autoCollapseThinking;

    // 完成主推理数据（仅在首次完成时执行，后续调用不执行）
    final r = _reasoning[messageId];
    if (r != null && r.finishedAt == null) {
      r.finishedAt = DateTime.now();
      if (autoCollapse) {
        r.expanded = false;
      }
      _reasoning[messageId] = r;
      changed = true;
    }
    // 注意：移除了会在每次调用时强制折叠的“else if”分支。
    // 这样用户在内容流式处理期间展开推理后，不会被立即再次折叠。

    // 完成最后一个推理片段（仅在首次完成时执行）
    final segments = _reasoningSegments[messageId];
    if (segments != null && segments.isNotEmpty) {
      final lastSegment = segments.last;
      if (lastSegment.finishedAt == null) {
        lastSegment.finishedAt = DateTime.now();
        if (autoCollapse) {
          lastSegment.expanded = false;
        }
        _reasoningSegments[messageId] = segments;
        changed = true;
      }
      // 注意：移除了会在每次调用时强制折叠的“else if”分支。
    }

    if (changed) {
      _safeNotifyStateChanged();
    }
    return changed;
  }

  /// 完成推理并持久化到数据库。
  ///
  /// 这是一个便捷方法，将完成推理状态和持久化到数据库
  /// 合并为一次调用。
  Future<void> finishReasoningAndPersist(
    String messageId, {
    bool forceCollapse = false,
    required Future<void> Function(
      String messageId, {
      String? reasoningText,
      DateTime? reasoningFinishedAt,
      String? reasoningSegmentsJson,
    })
    updateReasoningInDb,
  }) async {
    final changed = finishReasoningIfNeeded(
      messageId,
      forceCollapse: forceCollapse,
    );
    final splits = _contentSplits[messageId];
    final segments =
        _reasoningSegments[messageId] ?? const <ReasoningSegmentData>[];
    if (!changed && splits == null) return;

    // 持久化推理数据
    final r = _reasoning[messageId];
    if (r != null) {
      await updateReasoningInDb(
        messageId,
        reasoningText: r.text,
        reasoningFinishedAt: r.finishedAt,
      );
    }

    // 持久化推理片段
    if (segments.isNotEmpty || splits != null) {
      await updateReasoningInDb(
        messageId,
        reasoningSegmentsJson: serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: splits?.offsets,
          reasoningCountAtSplit: splits?.reasoningCounts,
          toolCountAtSplit: splits?.toolCounts,
        ),
      );
    }
  }

  // ============================================================================
  // 从数据库恢复
  // ============================================================================

  /// 从消息的持久化数据恢复其 UI 状态。
  ///
  /// 每条消息只在首次恢复时运行（直到其状态被清除），
  /// 因此重新遍历整个窗口的分页过程只会处理新进入窗口的消息。
  void restoreMessageUiState(
    ChatMessage message, {
    required List<Map<String, dynamic>> Function(String messageId)
    getToolEventsFromDb,
    required String? Function(String messageId) getGeminiThoughtSigFromDb,
  }) {
    if (message.role != 'assistant') return;
    if (!_restoredUiMessageIds.add(message.id)) return;

    final messageId = message.id;

    // 恢复 Gemini 思考签名
    final storedSig = getGeminiThoughtSigFromDb(messageId);
    if (storedSig != null && storedSig.isNotEmpty) {
      _geminiThoughtSigs[messageId] = storedSig;
    }

    // 恢复推理状态
    final txt = message.reasoningText ?? '';
    if (txt.isNotEmpty ||
        message.reasoningStartAt != null ||
        message.reasoningFinishedAt != null) {
      final rd = ReasoningData();
      rd.text = txt;
      rd.startAt = message.reasoningStartAt;
      // 如果 finishedAt 为 null 但 startAt 存在，说明流被中断
      // （例如应用在推理中强制退出）；将推理视为已完成，
      // 避免无限计时器。
      rd.finishedAt = message.reasoningFinishedAt ?? message.reasoningStartAt;
      rd.expanded = false;
      _reasoning[messageId] = rd;
    }

    // 恢复工具事件
    try {
      final events = dedupeToolEvents(getToolEventsFromDb(messageId));
      if (events.isNotEmpty) {
        _toolParts[messageId] = events
            .map(
              (e) => ToolUIPart(
                id: (e['id'] ?? '').toString(),
                toolName: (e['name'] ?? '').toString(),
                arguments:
                    (e['arguments'] as Map?)?.cast<String, dynamic>() ??
                    const <String, dynamic>{},
                content: (e['content']?.toString().isNotEmpty == true)
                    ? e['content'].toString()
                    : null,
                loading: !(e['content']?.toString().isNotEmpty == true),
              ),
            )
            .toList();
      }
    } catch (_) {}

    // 恢复推理片段（所有视图共享一次 JSON 解码）
    final payload = _decodedReasoningPayloadFor(
      messageId,
      message.reasoningSegmentsJson,
    );
    if (payload.segments.isNotEmpty) {
      // 复制：流处理器会原地修改存储列表，这不能泄漏回记忆化负载。
      _reasoningSegments[messageId] = List<ReasoningSegmentData>.of(
        payload.segments,
      );
    }
    final contentSplits = payload.contentSplits;
    if (contentSplits != null) {
      _contentSplits[messageId] = contentSplits;
    }

    // 为 API 重放恢复供应商推理详情（思考签名）
    final details = payload.reasoningDetails;
    if (details != null) {
      _reasoningDetails[messageId] = details;
    }
  }

  _DecodedReasoningPayload _decodedReasoningPayloadFor(
    String messageId,
    String? json,
  ) {
    final cached = _decodedReasoningPayloads[messageId];
    if (cached != null && cached.source == json) return cached;
    final payload = _DecodedReasoningPayload.decode(json);
    _reasoningPayloadDecodeCount++;
    _decodedReasoningPayloads[messageId] = payload;
    return payload;
  }

  // ============================================================================
  // 释放
  // ============================================================================

  /// 释放所有资源。
  void dispose() {
    _cancelAllTimers();
    streamingContentNotifier.dispose();
  }
}

// ============================================================================
// 数据类
// ============================================================================

/// 消息生成的上下文对象。
class GenerationContext {
  GenerationContext({
    required this.assistantMessage,
    required this.apiMessages,
    required this.userImagePaths,
    required this.allowImagesApiRouting,
    required this.providerKey,
    required this.modelId,
    required this.assistant,
    required this.settings,
    required this.config,
    required this.toolDefs,
    this.onToolCall,
    this.extraHeaders,
    this.extraBody,
    required this.supportsReasoning,
    required this.enableReasoning,
    required this.streamOutput,
    this.ocrActive = false,
    this.generateTitleOnFinish = true,
    this.generationRunId,
  });

  final ChatMessage assistantMessage;
  final List<Map<String, dynamic>> apiMessages;
  final List<String> userImagePaths;
  final bool allowImagesApiRouting;
  final String providerKey;
  final String modelId;
  final dynamic assistant;
  final SettingsProvider settings;
  final ProviderConfig config;
  final List<Map<String, dynamic>> toolDefs;
  final ToolCallHandler? onToolCall;
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;
  final bool supportsReasoning;
  final bool enableReasoning;
  final bool streamOutput;
  final bool ocrActive;
  final bool generateTitleOnFinish;
  final String? generationRunId;
}

/// 流式消息生成的状态对象。
class StreamingState {
  StreamingState(this.ctx) : fullContentRaw = ctx.assistantMessage.content;

  final GenerationContext ctx;
  String fullContentRaw;
  int totalTokens = 0;
  TokenUsage? usage;
  String bufferedReasoning = '';
  DateTime? reasoningStartAt;
  bool finishHandled = false;
  bool titleQueued = false;
  DateTime? streamStartedAt;
  int? generationStateRevision;
  bool generationStreamingStarted = false;
  bool hadThinkingBlock = false;
  bool hasInlineBase64 = false;
  String inlineBase64TailProbe = '';
  List<int> contentSplitOffsets = <int>[];
  List<int> reasoningCountAtSplit = <int>[];
  List<int> toolCountAtSplit = <int>[];

  String get messageId => ctx.assistantMessage.id;
  String get conversationId => ctx.assistantMessage.conversationId;
}

/// 助手消息的推理数据。
class ReasoningData {
  String text = '';
  DateTime? startAt;
  DateTime? finishedAt;
  bool expanded = false;
}

/// 推理片段数据（用于思考/工具交错显示）。
class ReasoningSegmentData {
  String text = '';
  DateTime? startAt;
  DateTime? finishedAt;
  bool expanded = true;
  int toolStartIndex = 0;
}

class ContentSplitData {
  const ContentSplitData({
    required this.offsets,
    required this.reasoningCounts,
    required this.toolCounts,
  });

  final List<int> offsets;
  final List<int> reasoningCounts;
  final List<int> toolCounts;
}

/// 对持久化 reasoningSegmentsJson 负载的所有视图，
/// 由一次 JSON 解码生成。
class _DecodedReasoningPayload {
  const _DecodedReasoningPayload._(
    this.source,
    this.segments,
    this.contentSplits,
    this.reasoningDetails,
  );

  static const _DecodedReasoningPayload _empty = _DecodedReasoningPayload._(
    null,
    <ReasoningSegmentData>[],
    null,
    null,
  );

  factory _DecodedReasoningPayload.decode(String? source) {
    if (source == null || source.isEmpty) return _empty;
    try {
      final decoded = _jsonDecode(source);
      if (decoded is Map<String, dynamic>) {
        final list = decoded['segments'] as List? ?? const [];
        final contentSplits = (decoded['contentSplits'] as Map?)
            ?.cast<String, dynamic>();
        final details = decoded['reasoningDetails'];
        return _DecodedReasoningPayload._(
          source,
          _parseSegments(list),
          contentSplits == null ? null : _parseContentSplits(contentSplits),
          details is List && details.isNotEmpty ? details : null,
        );
      }
      if (decoded is List) {
        return _DecodedReasoningPayload._(
          source,
          _parseSegments(decoded),
          null,
          null,
        );
      }
    } catch (_) {}
    return _empty;
  }

  final String? source;
  final List<ReasoningSegmentData> segments;
  final ContentSplitData? contentSplits;
  final dynamic reasoningDetails;

  static List<ReasoningSegmentData> _parseSegments(List list) {
    return list.map((item) {
      final s = ReasoningSegmentData();
      s.text = item['text'] ?? '';
      s.startAt = item['startAt'] != null
          ? DateTime.parse(item['startAt'])
          : null;
      final parsedFinished = item['finishedAt'] != null
          ? DateTime.parse(item['finishedAt'])
          : null;
      // 如果 finishedAt 为 null 但 startAt 存在，说明流被中断；
      // 将片段视为已完成，避免恢复时出现无限计时器。
      s.finishedAt = parsedFinished ?? s.startAt;
      s.expanded = item['expanded'] ?? false;
      s.toolStartIndex = (item['toolStartIndex'] as int?) ?? 0;
      return s;
    }).toList();
  }

  static ContentSplitData _parseContentSplits(Map<String, dynamic> json) {
    return StreamController._normalizeContentSplitData(
      ContentSplitData(
        offsets: (json['offsets'] as List? ?? const [])
            .map((item) => item as int)
            .toList(),
        reasoningCounts: (json['reasoningCounts'] as List? ?? const [])
            .map((item) => item as int)
            .toList(),
        toolCounts: (json['toolCounts'] as List? ?? const [])
            .map((item) => item as int)
            .toList(),
      ),
    );
  }
}

class _StreamSmoothState {
  String conversationId = '';
  String targetContent = '';
  String visibleContent = '';
  String Function()? contentBuilder;
  int totalTokens = 0;
  List<int>? contentSplitOffsets;
  List<int>? reasoningCountAtSplit;
  List<int>? toolCountAtSplit;
  int? promptTokens;
  int? completionTokens;
  int? cachedTokens;
  int? durationMs;
  String? pendingReasoningText;
  DateTime? pendingReasoningStartAt;
  bool reasoningDirty = false;
  List<int>? pendingReasoningSplitOffsets;
  List<int>? pendingReasoningCounts;
  List<int>? pendingToolCounts;
  void Function(String messageId, String content, int totalTokens)?
  updateMessageInList;
  final List<int> _recentPickCounts = <int>[];

  String? takeNextContentSlice({
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
    required int moveAverageLength,
  }) {
    if (targetContent == visibleContent) return null;
    if (!targetContent.startsWith(visibleContent)) {
      visibleContent = targetContent;
      _recentPickCounts.clear();
      return visibleContent;
    }

    final backlog = targetContent.length - visibleContent.length;
    if (backlog <= 0) return null;
    final pickCount = _nextPickCount(
      backlog: backlog,
      minCount: minCount,
      baseCount: baseCount,
      maxCount: maxCount,
      pickRate: pickRate,
      moveAverageLength: moveAverageLength,
    );
    final nextLength = math.min(
      targetContent.length,
      visibleContent.length + pickCount,
    );
    visibleContent = targetContent.substring(0, nextLength);
    return visibleContent;
  }

  String? flushTargetContent() {
    if (targetContent == visibleContent) return null;
    visibleContent = targetContent;
    _recentPickCounts.clear();
    return visibleContent;
  }

  int _nextPickCount({
    required int backlog,
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
    required int moveAverageLength,
  }) {
    if (backlog <= minCount) return backlog;

    final rawPick = _rawPickCount(
      backlog: backlog,
      minCount: minCount,
      baseCount: baseCount,
      maxCount: maxCount,
      pickRate: pickRate,
    );
    _recentPickCounts.add(rawPick);
    if (_recentPickCounts.length > moveAverageLength) {
      _recentPickCounts.removeAt(0);
    }

    final average =
        _recentPickCounts.reduce((a, b) => a + b) / _recentPickCounts.length;
    return average.round().clamp(minCount, backlog).toInt();
  }

  int _rawPickCount({
    required int backlog,
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
  }) {
    if (backlog <= minCount) return backlog;

    double effectivePickRate;
    if (backlog < baseCount) {
      effectivePickRate = pickRate * backlog / baseCount;
    } else if (backlog >= maxCount) {
      effectivePickRate = math.max((backlog - baseCount) / backlog, pickRate);
    } else {
      final t = (backlog - baseCount) / (maxCount - baseCount);
      effectivePickRate = pickRate + (0.5 - pickRate) * t;
    }

    return math.max(minCount, (backlog * effectivePickRate).round());
  }
}

// ============================================================================
// JSON 辅助函数（避免循环导入）
// ============================================================================

String _jsonEncode(dynamic obj) {
  // 此处不导入 dart:convert 的简单实现
  // 实际导入位于文件顶部
  return _JsonEncoder.encode(obj);
}

dynamic _jsonDecode(String json) {
  return _JsonDecoder.decode(json);
}

class _JsonEncoder {
  static String encode(dynamic obj) {
    if (obj == null) return 'null';
    if (obj is bool) return obj.toString();
    if (obj is num) return obj.toString();
    if (obj is String) return '"${_escapeString(obj)}"';
    if (obj is List) {
      final items = obj.map((e) => encode(e)).join(',');
      return '[$items]';
    }
    if (obj is Map) {
      final entries = obj.entries
          .map((e) => '"${_escapeString(e.key.toString())}":${encode(e.value)}')
          .join(',');
      return '{$entries}';
    }
    return '"${_escapeString(obj.toString())}"';
  }

  static String _escapeString(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }
}

class _JsonDecoder {
  static dynamic decode(String json) {
    final trimmed = json.trim();
    if (trimmed.isEmpty) return null;
    return _parseValue(trimmed, _Position(0)).value;
  }

  static _ParseResult _parseValue(String json, _Position pos) {
    _skipWhitespace(json, pos);
    if (pos.index >= json.length) return _ParseResult(null, pos.index);

    final c = json[pos.index];
    if (c == '{') return _parseObject(json, pos);
    if (c == '[') return _parseArray(json, pos);
    if (c == '"') return _parseString(json, pos);
    if (c == 't' || c == 'f') return _parseBool(json, pos);
    if (c == 'n') return _parseNull(json, pos);
    return _parseNumber(json, pos);
  }

  static _ParseResult _parseObject(String json, _Position pos) {
    pos.index++; // 跳过 {
    final map = <String, dynamic>{};
    _skipWhitespace(json, pos);
    while (pos.index < json.length && json[pos.index] != '}') {
      _skipWhitespace(json, pos);
      final keyResult = _parseString(json, pos);
      final key = keyResult.value as String;
      _skipWhitespace(json, pos);
      if (json[pos.index] == ':') pos.index++;
      _skipWhitespace(json, pos);
      final valueResult = _parseValue(json, pos);
      map[key] = valueResult.value;
      _skipWhitespace(json, pos);
      if (json[pos.index] == ',') pos.index++;
    }
    if (pos.index < json.length) pos.index++; // 跳过 }
    return _ParseResult(map, pos.index);
  }

  static _ParseResult _parseArray(String json, _Position pos) {
    pos.index++; // 跳过 [
    final list = <dynamic>[];
    _skipWhitespace(json, pos);
    while (pos.index < json.length && json[pos.index] != ']') {
      final result = _parseValue(json, pos);
      list.add(result.value);
      _skipWhitespace(json, pos);
      if (json[pos.index] == ',') pos.index++;
    }
    if (pos.index < json.length) pos.index++; // 跳过 ]
    return _ParseResult(list, pos.index);
  }

  static _ParseResult _parseString(String json, _Position pos) {
    pos.index++; // 跳过开头的 "
    final buffer = StringBuffer();
    while (pos.index < json.length) {
      final c = json[pos.index];
      if (c == '"') {
        pos.index++;
        break;
      }
      if (c == '\\' && pos.index + 1 < json.length) {
        pos.index++;
        final escaped = json[pos.index];
        switch (escaped) {
          case 'n':
            buffer.write('\n');
            break;
          case 'r':
            buffer.write('\r');
            break;
          case 't':
            buffer.write('\t');
            break;
          case '\\':
            buffer.write('\\');
            break;
          case '"':
            buffer.write('"');
            break;
          default:
            buffer.write(escaped);
        }
      } else {
        buffer.write(c);
      }
      pos.index++;
    }
    return _ParseResult(buffer.toString(), pos.index);
  }

  static _ParseResult _parseNumber(String json, _Position pos) {
    final start = pos.index;
    while (pos.index < json.length &&
        (json[pos.index].contains(RegExp(r'[\d.eE+-]')))) {
      pos.index++;
    }
    final numStr = json.substring(start, pos.index);
    if (numStr.contains('.') || numStr.contains('e') || numStr.contains('E')) {
      return _ParseResult(double.parse(numStr), pos.index);
    }
    return _ParseResult(int.parse(numStr), pos.index);
  }

  static _ParseResult _parseBool(String json, _Position pos) {
    if (json.substring(pos.index).startsWith('true')) {
      pos.index += 4;
      return _ParseResult(true, pos.index);
    }
    pos.index += 5;
    return _ParseResult(false, pos.index);
  }

  static _ParseResult _parseNull(String json, _Position pos) {
    pos.index += 4;
    return _ParseResult(null, pos.index);
  }

  static void _skipWhitespace(String json, _Position pos) {
    while (pos.index < json.length &&
        (json[pos.index] == ' ' ||
            json[pos.index] == '\n' ||
            json[pos.index] == '\r' ||
            json[pos.index] == '\t')) {
      pos.index++;
    }
  }
}

class _Position {
  _Position(this.index);
  int index;
}

class _ParseResult {
  _ParseResult(this.value, this.endIndex);
  final dynamic value;
  final int endIndex;
}
