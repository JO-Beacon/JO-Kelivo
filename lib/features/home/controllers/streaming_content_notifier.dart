import 'package:flutter/foundation.dart';

/// 用于流式消息内容更新的轻量 notifier。
///
/// 本类提供一种更新流式消息内容而
/// 不触发整页重建的方式。相比使用 ChangeNotifier.notifyListeners()
/// 会导致整个 HomePage 重建，这里使用 ValueNotifier，
/// 使只有正在监听的特定消息 widget 重建。
///
/// 用法：
/// 1. StreamController 通过 updateContent() 更新内容
/// 2. ChatMessageWidget 用 ValueListenableBuilder 监听 contentNotifier
/// 3. 只有流式消息 widget 重建，而非整页
class StreamingContentNotifier {
  /// 消息 ID 到其 content notifier 的映射。
  /// 每条流式消息都有自己的 `ValueNotifier<String>`。
  final Map<String, ValueNotifier<StreamingContentData>> _notifiers =
      <String, ValueNotifier<StreamingContentData>>{};

  /// 获取或为消息创建 notifier。
  ValueNotifier<StreamingContentData> getNotifier(String messageId) {
    return _notifiers.putIfAbsent(
      messageId,
      () => ValueNotifier<StreamingContentData>(
        const StreamingContentData(content: '', totalTokens: 0),
      ),
    );
  }

  /// 检查某消息是否存在 notifier。
  bool hasNotifier(String messageId) => _notifiers.containsKey(messageId);

  /// 更新流式消息的内容。
  /// 仅通知监听该消息 notifier 的特定 widget。
  void updateContent(
    String messageId,
    String content,
    int totalTokens, {
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
      notifier.value = StreamingContentData(
        content: content,
        totalTokens: totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        promptTokens: promptTokens ?? current.promptTokens,
        completionTokens: completionTokens ?? current.completionTokens,
        cachedTokens: cachedTokens ?? current.cachedTokens,
        durationMs: durationMs ?? current.durationMs,
      );
    }
  }

  /// 更新流式消息的推理内容。
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
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: reasoningText ?? current.reasoningText,
        reasoningStartAt: reasoningStartAt ?? current.reasoningStartAt,
        reasoningFinishedAt: reasoningFinishedAt ?? current.reasoningFinishedAt,
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion,
        promptTokens: current.promptTokens,
        completionTokens: current.completionTokens,
        cachedTokens: current.cachedTokens,
        durationMs: current.durationMs,
      );
    }
  }

  /// 通知工具 parts 已更新。
  /// 使用版本计数触发重建而无需复制工具数据。
  void notifyToolPartsUpdated(
    String messageId, {
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
  }) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        contentSplitOffsets: contentSplitOffsets ?? current.contentSplitOffsets,
        reasoningCountAtSplit:
            reasoningCountAtSplit ?? current.reasoningCountAtSplit,
        toolCountAtSplit: toolCountAtSplit ?? current.toolCountAtSplit,
        toolPartsVersion: current.toolPartsVersion + 1,
        uiVersion: current.uiVersion,
        promptTokens: current.promptTokens,
        completionTokens: current.completionTokens,
        cachedTokens: current.cachedTokens,
        durationMs: current.durationMs,
      );
    }
  }

  /// 强制重建流式消息 widget。
  /// 在推理展开等外部状态变化时使用。
  void forceRebuild(String messageId) {
    final notifier = _notifiers[messageId];
    if (notifier != null) {
      final current = notifier.value;
      notifier.value = StreamingContentData(
        content: current.content,
        totalTokens: current.totalTokens,
        reasoningText: current.reasoningText,
        reasoningStartAt: current.reasoningStartAt,
        reasoningFinishedAt: current.reasoningFinishedAt,
        toolPartsVersion: current.toolPartsVersion,
        uiVersion: current.uiVersion + 1,
        promptTokens: current.promptTokens,
        completionTokens: current.completionTokens,
        cachedTokens: current.cachedTokens,
        durationMs: current.durationMs,
      );
    }
  }

  /// 流式完成时移除 notifier。
  void removeNotifier(String messageId) {
    final notifier = _notifiers.remove(messageId);
    notifier?.dispose();
  }

  /// 清除所有 notifier（例如切换会话时）。
  void clear() {
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
  }

  /// 释放所有资源。
  void dispose() {
    clear();
  }
}

/// 流式内容的数据类。
@immutable
class StreamingContentData {
  const StreamingContentData({
    required this.content,
    required this.totalTokens,
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
  });

  final String content;
  final int totalTokens;
  final String? reasoningText;
  final DateTime? reasoningStartAt;
  final DateTime? reasoningFinishedAt;
  final List<int>? contentSplitOffsets;
  final List<int>? reasoningCountAtSplit;
  final List<int>? toolCountAtSplit;

  /// 工具 parts 更新的版本计数。递增即触发重建。
  final int toolPartsVersion;

  /// UI 状态变化的版本计数（例如推理展开切换）。
  final int uiVersion;

  /// 详细的 token 用量字段。
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
  final int? durationMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamingContentData &&
          runtimeType == other.runtimeType &&
          content == other.content &&
          totalTokens == other.totalTokens &&
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
          durationMs == other.durationMs;

  @override
  int get hashCode =>
      content.hashCode ^
      totalTokens.hashCode ^
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
      durationMs.hashCode;
}
