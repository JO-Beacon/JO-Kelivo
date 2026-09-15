import 'package:Kelivo/core/models/token_usage.dart';
import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';

/// 对一批 [StreamChunk] 做整体判读的测试辅助扩展。
///
/// 与上游 Kelivo 的同名文件保持一致：统一流式接口后，测试不再消费
/// JO 自有的 `ChatStreamChunk`，改为按事件类型聚合。
extension StreamChunkListGeneration on List<StreamChunk> {
  bool get isGenerationDone => any((chunk) => chunk is Finish);

  String get joinedContent =>
      whereType<TextDelta>().map((chunk) => chunk.text).join();

  String get joinedReasoning =>
      whereType<ReasoningDelta>().map((chunk) => chunk.text).join();

  String? get firstImageUri {
    for (final chunk in this) {
      if (chunk is ImageSnapshot) return chunk.data;
    }
    return null;
  }

  TokenUsage? get lastUsage {
    for (var i = length - 1; i >= 0; i--) {
      final chunk = this[i];
      if (chunk is Usage) return chunk.usage;
    }
    return null;
  }

  int get lastTotalTokens => lastUsage?.totalTokens ?? 0;

  dynamic get lastReasoningDetails {
    for (var i = length - 1; i >= 0; i--) {
      final chunk = this[i];
      if (chunk is ReasoningDelta && chunk.details != null) {
        return chunk.details;
      }
    }
    return null;
  }
}
