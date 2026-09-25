import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/models/message_part.dart';

/// 流式消息内容更新的轻量通知器。
///
/// 本类提供一种更新流式消息内容的方式，
/// 不会触发整页重建。它不用 ChangeNotifier.notifyListeners()
///（那会导致整个 HomePage 重建），而是用 ValueNotifier，
/// 因此只有正在监听的那条消息控件会重建。
///
/// 用法：
/// 1. 流控制器通过 updateContent() 更新内容
/// 2. ChatMessageWidget 用 ValueListenableBuilder 监听 contentNotifier
/// 3. 只有流式消息控件重建，整页不重建
/// 供 [MessageListView] 高度失效使用的轻量工具高度信号。
///
/// 列表不得比较 [oldWidget.toolParts] —— 那张表是原地修改的。
/// 流式路径走本事件；
/// 非流式重建由存下来的签名快照覆盖。
@immutable
class ToolHeightEvent {
  const ToolHeightEvent({required this.messageId, required this.version});

  final String messageId;
  final int version;
}

/// 自动重试等待下一次尝试时，气泡内的倒计时。
@immutable
class RetryStatus {
  const RetryStatus({
    required this.attempt,
    required this.maxRetries,
    required this.retryAt,
  });

  final int attempt;
  final int maxRetries;
  final DateTime retryAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RetryStatus &&
          attempt == other.attempt &&
          maxRetries == other.maxRetries &&
          retryAt == other.retryAt;

  @override
  int get hashCode => Object.hash(attempt, maxRetries, retryAt);
}

class StreamingContentNotifier {
  /// 消息 ID 到其内容通知器的映射。
  /// 每条流式消息都有自己的 `ValueNotifier<String>`。
  final Map<String, ValueNotifier<StreamingContentData>> _notifiers =
      <String, ValueNotifier<StreamingContentData>>{};

  /// 工具高度事件的自增计数。监听方不得重建整页。
  final ValueNotifier<ToolHeightEvent?> toolHeightEvents =
      ValueNotifier<ToolHeightEvent?>(null);

  int _toolHeightVersion = 0;
  final Set<String> _pendingHeightIds = <String>{};
  var _heightFlushScheduled = false;
  var _disposed = false;

  /// 取得或创建某个消息的通知器。
  ValueNotifier<StreamingContentData> getNotifier(String messageId) {
    return _notifiers.putIfAbsent(
      messageId,
      () => ValueNotifier<StreamingContentData>(
        StreamingContentData(content: '', totalTokens: 0),
      ),
    );
  }

  /// 判断某个消息是否已有通知器。
  bool hasNotifier(String messageId) => _notifiers.containsKey(messageId);

  /// 更新某条流式消息的内容。
  /// 只会通知正在监听该消息通知器的那个控件。
  void updateContent(
    String messageId,
    String content,
    int totalTokens, {
    List<MessagePart>? parts,
    String? reasoningText,
    DateTime? reasoningStartAt,
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      final next = current.copyWith(
        content: content,
        totalTokens: totalTokens,
        parts: parts ?? current.parts,
        reasoningText: reasoningText,
        reasoningStartAt: reasoningStartAt,
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
        promptTokens: promptTokens ?? current.promptTokens,
        completionTokens: completionTokens ?? current.completionTokens,
        cachedTokens: cachedTokens ?? current.cachedTokens,
        durationMs: durationMs ?? current.durationMs,
      );
      notifier.value = next;
      if (current.timelineStructureSignature !=
          next.timelineStructureSignature) {
        notifyToolHeightChanged(messageId);
      }
    }
  }

  /// 更新某条流式消息的推理内容。
  void updateReasoning(
    String messageId, {
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      final next = current.copyWith(
        reasoningText: reasoningText ?? current.reasoningText,
        reasoningStartAt: reasoningStartAt ?? current.reasoningStartAt,
        reasoningFinishedAt: reasoningFinishedAt ?? current.reasoningFinishedAt,
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
      );
      notifier.value = next;
      if (current.timelineStructureSignature !=
          next.timelineStructureSignature) {
        notifyToolHeightChanged(messageId);
      }
    }
  }

  /// 通知工具 parts 已更新。
  /// 用版本计数触发重建，不复制工具数据。
  void notifyToolPartsUpdated(
    String messageId, {
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = current.copyWith(
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
        toolPartsVersion: current.toolPartsVersion + 1,
      );
    }
    notifyToolHeightChanged(messageId);
  }

  /// 发出一个合并后的工具高度事件。没有内容通知器时调用也安全。
  void notifyToolHeightChanged(String messageId) {
    if (_disposed) return;
    if (!_pendingHeightIds.add(messageId)) return;
    if (_heightFlushScheduled) return;
    _heightFlushScheduled = true;
    scheduleMicrotask(_flushToolHeightEvents);
  }

  void _flushToolHeightEvents() {
    _heightFlushScheduled = false;
    if (_disposed) return;
    final ids = List<String>.of(_pendingHeightIds);
    _pendingHeightIds.clear();
    for (final id in ids) {
      _toolHeightVersion += 1;
      toolHeightEvents.value = ToolHeightEvent(
        messageId: id,
        version: _toolHeightVersion,
      );
    }
  }

  /// 强制重建流式消息控件。
  /// 用于推理展开状态等外部状态变化时。
  void forceRebuild(String messageId) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = current.copyWith(uiVersion: current.uiVersion + 1);
    }
  }

  void updateRetryStatus(String messageId, RetryStatus? status) {
    final notifier = getNotifier(messageId);
    final current = notifier.value;
    if (current.retryStatus == status) return;
    notifier.value = current.copyWith(
      retryStatus: status,
      clearRetryStatus: status == null,
    );
  }

  /// 流式结束后移除通知器。
  void removeNotifier(String messageId) {
    final notifier = _notifiers.remove(messageId);
    notifier?.dispose();
  }

  /// 释放通知器，但放过仍属在跑生成的那些。
  void clear({Set<String> keepMessageIds = const {}}) {
    _notifiers.removeWhere((id, notifier) {
      if (keepMessageIds.contains(id)) return false;
      notifier.dispose();
      return true;
    });
    _pendingHeightIds.removeWhere((id) => !keepMessageIds.contains(id));
  }

  /// 释放全部资源。
  void dispose() {
    _disposed = true;
    _pendingHeightIds.clear();
    clear();
    toolHeightEvents.dispose();
  }
}

/// 流式内容的数据类。
@immutable
class StreamingContentData {
  factory StreamingContentData({
    required String content,
    required int totalTokens,
    List<MessagePart>? parts,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
    int toolPartsVersion = 0,
    int uiVersion = 0,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
    RetryStatus? retryStatus,
    int? timelineStructureSignature,
    List<int>? partStructureTokens,
  }) {
    final tokens = partStructureTokens ?? _partStructureTokensFor(parts);
    return StreamingContentData._(
      content: content,
      totalTokens: totalTokens,
      parts: parts,
      reasoningText: reasoningText,
      reasoningStartAt: reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt,
      contentSplitOffsets: contentSplitOffsets,
      reasoningCountAtSplit: reasoningCountAtSplit,
      toolCountAtSplit: toolCountAtSplit,
      toolPartsVersion: toolPartsVersion,
      uiVersion: uiVersion,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      durationMs: durationMs,
      retryStatus: retryStatus,
      partStructureTokens: tokens,
      timelineStructureSignature:
          timelineStructureSignature ??
          _timelineStructureSignatureFor(
            partTokens: tokens,
            partsLength: parts?.length ?? 0,
            contentSplitOffsets: contentSplitOffsets,
            reasoningCountAtSplit: reasoningCountAtSplit,
            toolCountAtSplit: toolCountAtSplit,
            toolPartsVersion: toolPartsVersion,
          ),
    );
  }

  const StreamingContentData._({
    required this.content,
    required this.totalTokens,
    this.parts,
    this.reasoningText,
    this.reasoningStartAt,
    this.reasoningFinishedAt,
    this.contentSplitOffsets,
    this.reasoningCountAtSplit,
    this.toolCountAtSplit,
    this.toolPartsVersion = 0,
    this.uiVersion = 0,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    this.durationMs,
    this.retryStatus,
    required this.partStructureTokens,
    required this.timelineStructureSignature,
  });

  final String content;
  final int totalTokens;
  final List<MessagePart>? parts;
  final String? reasoningText;
  final DateTime? reasoningStartAt;
  final DateTime? reasoningFinishedAt;
  final List<int>? contentSplitOffsets;
  final List<int>? reasoningCountAtSplit;
  final List<int>? toolCountAtSplit;

  /// 工具 parts 更新的版本计数。自增即触发重建。
  final int toolPartsVersion;

  /// 界面状态变化的版本计数（例如推理块展开／收起）。
  final int uiVersion;

  /// 逐 part 的结构指纹。仅文本／token 字段变化时复用。
  final List<int> partStructureTokens;

  /// 会改变时间线高度的 parts／切分／工具版本的标识。
  ///
  /// TextPart 与 ReasoningPart 的内容被忽略，这样 token 增长不会
  /// 被当成新块。ToolCallPart 只取 id 与 name。只在那些输入
  /// 变化时计算一次 —— 不是每次读取都算。
  final int timelineStructureSignature;

  /// 详细 token 用量字段。
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
  final int? durationMs;
  final RetryStatus? retryStatus;

  StreamingContentData copyWith({
    String? content,
    int? totalTokens,
    List<MessagePart>? parts,
    String? reasoningText,
    DateTime? reasoningStartAt,
    DateTime? reasoningFinishedAt,
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
    int? toolPartsVersion,
    int? uiVersion,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
    RetryStatus? retryStatus,
    bool clearRetryStatus = false,
  }) {
    final nextParts = parts ?? this.parts;
    final nextSplits = contentSplitOffsets ?? this.contentSplitOffsets;
    final nextReasoningCounts =
        reasoningCountAtSplit ?? this.reasoningCountAtSplit;
    final nextToolCounts = toolCountAtSplit ?? this.toolCountAtSplit;
    final nextToolVersion = toolPartsVersion ?? this.toolPartsVersion;
    final structureUnchanged =
        identical(nextParts, this.parts) &&
        identical(nextSplits, this.contentSplitOffsets) &&
        identical(nextReasoningCounts, this.reasoningCountAtSplit) &&
        identical(nextToolCounts, this.toolCountAtSplit) &&
        nextToolVersion == this.toolPartsVersion;
    final nextPartTokens = structureUnchanged
        ? partStructureTokens
        : _reuseOrComputePartTokens(
            nextParts,
            previousParts: this.parts,
            previousTokens: partStructureTokens,
          );
    return StreamingContentData(
      content: content ?? this.content,
      totalTokens: totalTokens ?? this.totalTokens,
      parts: nextParts,
      reasoningText: reasoningText ?? this.reasoningText,
      reasoningStartAt: reasoningStartAt ?? this.reasoningStartAt,
      reasoningFinishedAt: reasoningFinishedAt ?? this.reasoningFinishedAt,
      contentSplitOffsets: nextSplits,
      reasoningCountAtSplit: nextReasoningCounts,
      toolCountAtSplit: nextToolCounts,
      toolPartsVersion: nextToolVersion,
      uiVersion: uiVersion ?? this.uiVersion,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      cachedTokens: cachedTokens ?? this.cachedTokens,
      durationMs: durationMs ?? this.durationMs,
      retryStatus: clearRetryStatus ? null : (retryStatus ?? this.retryStatus),
      partStructureTokens: nextPartTokens,
      timelineStructureSignature: structureUnchanged
          ? timelineStructureSignature
          : _timelineStructureSignatureFor(
              partTokens: nextPartTokens,
              partsLength: nextParts?.length ?? 0,
              contentSplitOffsets: nextSplits,
              reasoningCountAtSplit: nextReasoningCounts,
              toolCountAtSplit: nextToolCounts,
              toolPartsVersion: nextToolVersion,
            ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamingContentData &&
          runtimeType == other.runtimeType &&
          content == other.content &&
          totalTokens == other.totalTokens &&
          listEquals(parts, other.parts) &&
          reasoningText == other.reasoningText &&
          reasoningStartAt == other.reasoningStartAt &&
          reasoningFinishedAt == other.reasoningFinishedAt &&
          listEquals(contentSplitOffsets, other.contentSplitOffsets) &&
          listEquals(reasoningCountAtSplit, other.reasoningCountAtSplit) &&
          listEquals(toolCountAtSplit, other.toolCountAtSplit) &&
          toolPartsVersion == other.toolPartsVersion &&
          uiVersion == other.uiVersion &&
          promptTokens == other.promptTokens &&
          completionTokens == other.completionTokens &&
          cachedTokens == other.cachedTokens &&
          durationMs == other.durationMs &&
          retryStatus == other.retryStatus;

  @override
  int get hashCode =>
      content.hashCode ^
      totalTokens.hashCode ^
      Object.hashAll(parts ?? const <MessagePart>[]) ^
      reasoningText.hashCode ^
      reasoningStartAt.hashCode ^
      reasoningFinishedAt.hashCode ^
      Object.hashAll(contentSplitOffsets ?? const <int>[]) ^
      Object.hashAll(reasoningCountAtSplit ?? const <int>[]) ^
      Object.hashAll(toolCountAtSplit ?? const <int>[]) ^
      toolPartsVersion.hashCode ^
      uiVersion.hashCode ^
      promptTokens.hashCode ^
      completionTokens.hashCode ^
      cachedTokens.hashCode ^
      durationMs.hashCode ^
      retryStatus.hashCode;
}

/// 仅在 ToolCallPart 的载荷真的被 jsonDecode 时自增。
@visibleForTesting
int debugToolIdentityDecodeCount = 0;

List<int> _partStructureTokensFor(List<MessagePart>? parts) {
  if (parts == null || parts.isEmpty) return const <int>[];
  return [for (final part in parts) _partStructureToken(part)];
}

List<int> _reuseOrComputePartTokens(
  List<MessagePart>? parts, {
  required List<MessagePart>? previousParts,
  required List<int> previousTokens,
}) {
  if (parts == null || parts.isEmpty) return const <int>[];
  if (identical(parts, previousParts)) return previousTokens;
  return [
    for (var i = 0; i < parts.length; i++)
      if (previousParts != null &&
          i < previousParts.length &&
          i < previousTokens.length &&
          _canReusePartToken(parts[i], previousParts[i]))
        previousTokens[i]
      else
        _partStructureToken(parts[i]),
  ];
}

bool _canReusePartToken(MessagePart next, MessagePart previous) {
  if (identical(next, previous)) return true;
  if (next.runtimeType != previous.runtimeType) return false;
  if (next is ToolCallPart && previous is ToolCallPart) {
    return next.payloadJson == previous.payloadJson;
  }
  if (next is ImagePart && previous is ImagePart) {
    return next.unavailable == previous.unavailable &&
        next.uri.trim().isEmpty == previous.uri.trim().isEmpty &&
        next.assetId == previous.assetId &&
        next.id == previous.id;
  }
  return true;
}

int _timelineStructureSignatureFor({
  required List<int> partTokens,
  required int partsLength,
  required List<int>? contentSplitOffsets,
  required List<int>? reasoningCountAtSplit,
  required List<int>? toolCountAtSplit,
  required int toolPartsVersion,
}) {
  return Object.hash(
    partsLength,
    Object.hashAll(partTokens),
    Object.hashAll(contentSplitOffsets ?? const <int>[]),
    Object.hashAll(reasoningCountAtSplit ?? const <int>[]),
    Object.hashAll(toolCountAtSplit ?? const <int>[]),
    toolPartsVersion,
  );
}

int _partStructureToken(MessagePart part) {
  if (part is ToolCallPart) {
    return Object.hash(3, _toolCallIdentity(part.payloadJson));
  }
  if (part is ImagePart) {
    return Object.hash(
      4,
      part.unavailable,
      part.uri.trim().isNotEmpty,
      part.assetId,
      part.id,
    );
  }
  return part.runtimeType.hashCode;
}

String _toolCallIdentity(String payloadJson) {
  debugToolIdentityDecodeCount++;
  try {
    final decoded = jsonDecode(payloadJson);
    if (decoded is Map) {
      return '${decoded['id']}|${decoded['name']}';
    }
  } catch (_) {}
  return '';
}
