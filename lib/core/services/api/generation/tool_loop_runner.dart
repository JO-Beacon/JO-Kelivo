import 'dart:async';

import '../../../../utils/mcp_structured_image.dart';
import '../../../models/token_usage.dart';
import '../chat_api_helpers.dart';
import '../stream/stream_chunk.dart';
import '../stream/stream_chunk_emit.dart';

/// Wraps one tool round with the caller's per-round retry policy.
typedef StreamRoundRunner =
    Stream<StreamChunk> Function(Stream<StreamChunk> Function() sendRound);

/// 给每个 HTTP 轮次的首个用量打上标记（含非流式响应：用量解完才有）。
/// 标记放在重试器外面，用量记录就不会影响空失败请求的重试。
/// 调用方每轮重置 [usageOf]，避免它拿回上一轮的用量。
Stream<StreamChunk> _withRequestUsage(
  Stream<StreamChunk> source,
  TokenUsage? Function()? usageOf,
) async* {
  var startsRequest = true;
  await for (final chunk in source) {
    if (chunk is Usage) {
      yield Usage(chunk.usage, startsRequest: startsRequest);
      startsRequest = false;
    } else {
      yield chunk;
    }
  }
  final usage = usageOf?.call();
  if (usage != null || startsRequest) {
    // 缺失用量不得把上一轮重复计入。
    yield Usage(usage ?? const TokenUsage(), startsRequest: startsRequest);
  }
}

final class ExecutedClientTool {
  const ExecutedClientTool({
    required this.call,
    required this.content,
    this.metadata,
  });

  final EmitToolCall call;
  final Map<String, dynamic>? metadata;
  final String content;
}

EmitToolResult _emitExecuted(ExecutedClientTool item) {
  return emitToolResult(
    id: item.call.id,
    name: item.call.name,
    arguments: item.call.arguments,
    content: item.content,
    metadata: mergeToolResultMetadata(item.call.metadata, item.metadata),
  );
}

/// Execute [calls] and yield [ToolCallResult]s (and optionally [ToolCall*]).
Stream<StreamChunk> executeClientTools({
  required List<EmitToolCall> calls,
  required ToolCallHandler onToolCall,
  bool emitCalls = false,
  TokenUsage? usage,
  int totalTokens = 0,
}) async* {
  if (calls.isEmpty) return;
  if (emitCalls) {
    yield* emitToolCalls(calls, usage: usage, totalTokens: totalTokens);
  }
  final executed = <ExecutedClientTool>[];
  for (final call in calls) {
    executed.add(await _executeClientTool(call, onToolCall));
  }
  yield* emitToolResults(
    [for (final item in executed) _emitExecuted(item)],
    usage: usage,
    totalTokens: totalTokens,
  );
}

/// After-round client-tool loop: execute → append → send follow-up → repeat.
///
/// The host owns protocol-specific HTTP and transcript shape. This runner
/// owns execute + [ToolCallResult] emit + the loop.
///
/// Two entries stay on purpose. [runProviderToolRounds] owns the first HTTP
/// round via [sendRound] (Claude / Gemini). OpenAI's first round is consumed
/// by the caller (`await for` SSE or one-shot JSON); only later rounds enter
/// [runClientToolFollowUps]. Unifying stream/non-stream return types does not
/// change who drives the first request, so these cannot merge.
Stream<StreamChunk> runClientToolFollowUps({
  required List<EmitToolCall> initialCalls,
  required ToolCallHandler onToolCall,
  required FutureOr<void> Function(List<ExecutedClientTool> executed) append,
  required Stream<StreamChunk> Function() sendFollowUp,
  required List<EmitToolCall> Function() takeCallsAfterRound,
  required Stream<StreamChunk> Function() finish,
  StreamRoundRunner? retryRound,
  bool emitCalls = false,
  TokenUsage? Function()? usageOf,
}) async* {
  var calls = List<EmitToolCall>.from(initialCalls);
  while (calls.isNotEmpty) {
    final usage = usageOf?.call();
    final totalTokens = usage?.totalTokens ?? 0;
    final executed = <ExecutedClientTool>[];
    // Do not clear [emitCalls] after the first round. OpenAI non-stream
    // follow-ups have no decoder emitting ToolCall*, so later rounds would
    // otherwise land as ToolCallResult-only cards with empty name/args.
    if (emitCalls) {
      yield* emitToolCalls(calls, usage: usage, totalTokens: totalTokens);
    }
    for (final call in calls) {
      executed.add(await _executeClientTool(call, onToolCall));
    }
    yield* emitToolResults(
      [for (final item in executed) _emitExecuted(item)],
      usage: usage,
      totalTokens: totalTokens,
    );
    await append(executed);
    yield* _withRequestUsage(
      retryRound?.call(sendFollowUp) ?? sendFollowUp(),
      usageOf,
    );
    calls = takeCallsAfterRound();
  }
  yield* finish();
}

/// In-round loop used by Claude / Gemini: send (and maybe execute mid-stream),
/// then append and repeat until [takeCalls] and [continueWithoutCalls] are both
/// empty/false.
Stream<StreamChunk> runProviderToolRounds({
  required Stream<StreamChunk> Function() sendRound,
  required List<EmitToolCall> Function() takeCalls,
  required FutureOr<void> Function(List<ExecutedClientTool> executed) append,
  required bool Function() continueWithoutCalls,
  required Stream<StreamChunk> Function() finish,
  ToolCallHandler? onToolCall,
  StreamRoundRunner? retryRound,
  bool emitCalls = false,
  bool executeAfterRound = true,
  TokenUsage? Function()? usageOf,
}) async* {
  var roundIndex = 0;
  while (true) {
    // 首轮由调用方（chat_api_service）统一包重试，这里不再重复包一层——
    // 否则首轮失败会形成 4×4=16 次请求、退避叠加超过 30s。
    if (roundIndex == 0) {
      yield* sendRound();
    } else {
      yield* _withRequestUsage(
        retryRound?.call(sendRound) ?? sendRound(),
        usageOf,
      );
    }
    roundIndex++;
    final calls = takeCalls();
    if (calls.isEmpty && !continueWithoutCalls()) {
      yield* finish();
      return;
    }
    final executed = <ExecutedClientTool>[];
    if (executeAfterRound && calls.isNotEmpty && onToolCall != null) {
      final usage = usageOf?.call();
      final totalTokens = usage?.totalTokens ?? 0;
      if (emitCalls) {
        yield* emitToolCalls(calls, usage: usage, totalTokens: totalTokens);
      }
      for (final call in calls) {
        executed.add(await _executeClientTool(call, onToolCall));
      }
      yield* emitToolResults(
        [for (final item in executed) _emitExecuted(item)],
        usage: usage,
        totalTokens: totalTokens,
      );
    }
    await append(executed);
  }
}

Future<ExecutedClientTool> _executeClientTool(
  EmitToolCall call,
  ToolCallHandler onToolCall,
) async {
  final raw = await onToolCall(call.name, call.arguments, toolCallId: call.id);
  final parsed = ClientToolResult.fromHandler(raw);
  return ExecutedClientTool(
    call: call,
    content: parsed.content,
    metadata: parsed.metadata,
  );
}
