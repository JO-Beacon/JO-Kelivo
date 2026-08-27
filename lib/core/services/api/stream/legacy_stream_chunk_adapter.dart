import 'dart:convert';

import '../chat_api_service.dart';
import 'stream_chunk.dart';

/// 将 JO-Kelivo 现有的兼容分块投影为 provider-independent 事件。
///
/// 这是流式架构迁移期间的桥接层：现有供应商仍可返回
/// [ChatStreamChunk]，新的下游代码可以先按 [StreamChunk] 消费，
/// 而不改变当前请求、工具循环和上下文树持久化契约。
Iterable<StreamChunk> legacyChunkToEvents(
  ChatStreamChunk chunk, {
  String textId = 'legacy:text',
  String reasoningId = 'legacy:reasoning',
}) sync* {
  if (chunk.reasoning case final reasoning? when reasoning.isNotEmpty) {
    yield ReasoningDelta(
      id: reasoningId,
      text: reasoning,
      details: chunk.reasoningDetails,
    );
  } else if (chunk.reasoningDetails != null) {
    yield ReasoningDelta(
      id: reasoningId,
      text: '',
      details: chunk.reasoningDetails,
    );
  }

  for (final call in chunk.toolCalls ?? const <ToolCallInfo>[]) {
    yield ToolCallStart(
      id: call.id,
      toolName: call.name,
      metadata: call.metadata,
    );
    yield ToolCallDelta(
      id: call.id,
      inputDelta: _encodeArguments(call.arguments),
      metadata: call.metadata,
    );
    yield ToolCallEnd(call.id);
  }

  for (final result in chunk.toolResults ?? const <ToolResultInfo>[]) {
    yield ToolCallResult(
      id: result.id,
      output: result.content,
      metadata: result.metadata,
    );
  }

  if (chunk.content.isNotEmpty) {
    yield TextDelta(id: textId, text: chunk.content);
  }

  if (chunk.usage != null) yield Usage(chunk.usage!);
  if (chunk.isDone) yield const Finish();
}

String _encodeArguments(Map<String, dynamic> arguments) {
  if (arguments.isEmpty) return '';
  return jsonEncode(arguments);
}
