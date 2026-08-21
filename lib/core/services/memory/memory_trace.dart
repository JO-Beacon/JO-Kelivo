import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/assistant.dart';

/// 触发后台记忆运行的原因。
enum MemoryTraceTrigger {
  /// 助手轮次达到阈值后自动整理。
  autoTurns,

  /// 用户点击“立即整理”。
  manual,

  /// 模型工具调用（`memory_*` / `chat_search`）。
  toolCall,

  /// 后台会话摘要生成（用于过往会话回忆）。
  conversationSummary,
}

/// 本次运行写入的是助手作用域还是全局记忆。
enum MemoryTraceScope { assistant, global }

/// 将助手写入策略映射为 trace 中显示的作用域标签。
MemoryTraceScope memoryTraceScopeOf(MemoryWriteScope scope) {
  switch (scope) {
    case MemoryWriteScope.alwaysGlobal:
    case MemoryWriteScope.toolDefaultGlobal:
      return MemoryTraceScope.global;
    case MemoryWriteScope.alwaysAssistant:
    case MemoryWriteScope.toolDefaultAssistant:
      return MemoryTraceScope.assistant;
  }
}

/// 后台记忆工作的一个阶段。
enum MemoryTraceStepKind {
  gatekeeper,
  extract,
  smartAdd,
  profileDistiller,
  conversationSummary,
  chatSearch,
  memoryTool,
}

enum MemoryTraceStepStatus { running, skipped, success, failed }

/// 本次运行对存储状态应用的具体变更。
enum MemoryTraceMutationKind {
  memoryCreated,
  memoryMerged,
  memoryEdited,
  memoryArchived,
  memoryLinked,
  profileFieldWritten,
  profileFieldCleared,
  conversationSummaryWritten,
}

class MemoryTraceMutation {
  const MemoryTraceMutation({
    required this.kind,
    this.targetId,
    this.label,
    this.before,
    this.after,
  });

  final MemoryTraceMutationKind kind;

  /// 记忆条目 id / profile 字段键 / 会话 id。
  final String? targetId;

  /// 额外限定信息，例如记忆类型或作用域。
  final String? label;

  final String? before;
  final String? after;
}

/// 一个已记录的流水线阶段，包含调试所需的全部信息。
class MemoryTraceStep {
  MemoryTraceStep({required this.kind, required this.startedAt, this.label});

  final MemoryTraceStepKind kind;

  /// 自由格式限定信息，例如 [MemoryTraceStepKind.memoryTool] 的工具名。
  final String? label;

  final DateTime startedAt;
  DateTime? endedAt;

  MemoryTraceStepStatus status = MemoryTraceStepStatus.running;

  /// 发送给模型的精确 prompt。多次调用按顺序追加。
  String get prompt => _prompt.toString();

  /// 模型的原始响应，顺序与 [prompt] 一致。
  String get rawResponse => _rawResponse.toString();

  /// 人类可读的解析结果（结构化时为 JSON）。
  String? parsedResult;

  String? error;

  final List<MemoryTraceMutation> mutations = <MemoryTraceMutation>[];

  final StringBuffer _prompt = StringBuffer();
  final StringBuffer _rawResponse = StringBuffer();
  int _promptParts = 0;
  int _responseParts = 0;

  Duration? get duration => endedAt?.difference(startedAt);

  void appendPrompt(String text) {
    _promptParts++;
    if (_promptParts > 1) {
      _prompt.write('\n\n─── #$_promptParts ───\n\n');
    }
    _prompt.write(text);
  }

  void appendResponse(String text) {
    _responseParts++;
    if (_responseParts > 1) {
      _rawResponse.write('\n\n─── #$_responseParts ───\n\n');
    }
    _rawResponse.write(text);
  }

  void addMutation(MemoryTraceMutation mutation) => mutations.add(mutation);

  void setParsedJson(Object? value) {
    try {
      parsedResult = const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      parsedResult = value?.toString();
    }
  }

  void finish(MemoryTraceStepStatus status, {String? error, DateTime? at}) {
    this.status = status;
    this.error = error ?? this.error;
    endedAt = at ?? DateTime.now();
  }
}

/// 单次后台记忆触发所发生的全部事件。
class MemoryTrace {
  MemoryTrace({
    required this.id,
    required this.startedAt,
    required this.trigger,
    required this.scope,
    this.conversationId,
    this.conversationTitle,
    this.assistantId,
    this.assistantName,
    this.watermark,
    this.windowStartOrder,
    this.windowEndOrder,
    this.windowSize = 0,
  });

  final String id;
  final DateTime startedAt;
  DateTime? endedAt;

  final MemoryTraceTrigger trigger;
  final MemoryTraceScope scope;

  final String? conversationId;
  final String? conversationTitle;

  /// 未绑定助手的运行为 null。
  final String? assistantId;
  final String? assistantName;

  /// 本次运行起始的水位线（消息顺序）。
  int? watermark;
  int? windowStartOrder;
  int? windowEndOrder;
  int windowSize;

  final List<MemoryTraceStep> steps = <MemoryTraceStep>[];

  bool advanced = false;
  bool forcedAdvance = false;

  /// 流水线错误 / 跳过原因码，例如 `below_threshold`。
  String? error;

  /// 本条目代表的相同连续空操作触发次数。
  int repeatCount = 1;

  Duration? get duration => endedAt?.difference(startedAt);

  bool get hasError => (error ?? '').isNotEmpty;

  /// 从未到达模型的触发（门控 / 阈值检查）。
  bool get isNoOp => steps.isEmpty;

  int get mutationCount {
    var total = 0;
    for (final step in steps) {
      total += step.mutations.length;
    }
    return total;
  }
}

/// 流水线用于填充 trace 的活跃句柄。
///
/// 每个方法都会吞掉自身失败：可观测性绝不能破坏
/// 流水线。
class MemoryTraceHandle {
  MemoryTraceHandle(this._recorder, this.trace);

  final MemoryTraceRecorder _recorder;
  final MemoryTrace trace;
  bool _committed = false;

  MemoryTraceStep? beginStep(MemoryTraceStepKind kind, {String? label}) {
    try {
      final step = MemoryTraceStep(
        kind: kind,
        startedAt: DateTime.now(),
        label: label,
      );
      trace.steps.add(step);
      return step;
    } catch (_) {
      return null;
    }
  }

  void setWindow({int? watermark, int? startOrder, int? endOrder, int? size}) {
    try {
      trace.watermark = watermark ?? trace.watermark;
      trace.windowStartOrder = startOrder ?? trace.windowStartOrder;
      trace.windowEndOrder = endOrder ?? trace.windowEndOrder;
      trace.windowSize = size ?? trace.windowSize;
    } catch (_) {}
  }

  /// 结束结果并发布 trace。
  void commit({
    bool advanced = false,
    bool forcedAdvance = false,
    String? error,
  }) {
    if (_committed) return;
    _committed = true;
    try {
      trace.advanced = advanced;
      trace.forcedAdvance = forcedAdvance;
      trace.error = error;
      trace.endedAt = DateTime.now();
      for (final step in trace.steps) {
        if (step.status == MemoryTraceStepStatus.running) {
          step.finish(MemoryTraceStepStatus.failed, error: error);
        }
      }
      _recorder.publish(trace);
    } catch (_) {}
  }
}

/// 近期后台记忆 trace 的内存环形缓冲。
///
/// trace 持有完整 prompt 和原始响应，因此体积很大：单次
/// 整理运行可能携带约 5 个由 12 KB 会话窗口构建的 prompt，
/// 加上它们的响应（最差约 100 KB）。因此 [maxTraces] 保持在
/// 24——约一个工作会话的运行量、上限两三 MB——
/// 且不进行任何持久化。
class MemoryTraceRecorder extends ChangeNotifier {
  /// [_enabled] 镜像用户偏好；传入 false 以初始即抑制。
  MemoryTraceRecorder([this._enabled = true]);

  /// 流水线与查看页面使用的进程级记录器。
  static final MemoryTraceRecorder instance = MemoryTraceRecorder();

  static const int maxTraces = 24;

  final Queue<MemoryTrace> _traces = Queue<MemoryTrace>();
  bool _enabled;
  int _seq = 0;

  bool get enabled => _enabled;

  /// 最新的在前。
  List<MemoryTrace> get traces =>
      List<MemoryTrace>.unmodifiable(_traces.toList().reversed);

  int get length => _traces.length;

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _traces.clear();
    }
    notifyListeners();
  }

  void clear() {
    if (_traces.isEmpty) return;
    _traces.clear();
    notifyListeners();
  }

  /// 启动一个 trace，录制关闭时返回 null。
  MemoryTraceHandle? begin({
    required MemoryTraceTrigger trigger,
    required MemoryTraceScope scope,
    String? conversationId,
    String? conversationTitle,
    String? assistantId,
    String? assistantName,
  }) {
    if (!_enabled) return null;
    _seq++;
    final trace = MemoryTrace(
      id: 'trace_${DateTime.now().microsecondsSinceEpoch}_$_seq',
      startedAt: DateTime.now(),
      trigger: trigger,
      scope: scope,
      conversationId: conversationId,
      conversationTitle: conversationTitle,
      assistantId: assistantId,
      assistantName: assistantName,
    );
    return MemoryTraceHandle(this, trace);
  }

  /// 存储已完成的 trace。由 [MemoryTraceHandle.commit] 调用。
  @visibleForTesting
  void publish(MemoryTrace trace) {
    if (!_enabled) return;
    // 合并重复的空操作触发（例如每轮后的 "below_threshold"），
    // 使其不会把真实运行挤出缓冲区。
    final newest = _traces.isEmpty ? null : _traces.last;
    if (newest != null &&
        trace.isNoOp &&
        newest.isNoOp &&
        newest.trigger == trace.trigger &&
        newest.conversationId == trace.conversationId &&
        newest.error == trace.error) {
      newest.repeatCount++;
      newest.endedAt = trace.endedAt;
      notifyListeners();
      return;
    }
    _traces.addLast(trace);
    while (_traces.length > maxTraces) {
      _traces.removeFirst();
    }
    notifyListeners();
  }
}
