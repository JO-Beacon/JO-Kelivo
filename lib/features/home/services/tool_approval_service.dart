import 'dart:async';
import 'package:flutter/foundation.dart';

/// 工具审批请求的结果。
class ToolApprovalResult {
  final bool approved;
  final String? denyReason;

  const ToolApprovalResult({required this.approved, this.denyReason});

  factory ToolApprovalResult.approved() =>
      const ToolApprovalResult(approved: true);
  factory ToolApprovalResult.denied([String? reason]) =>
      ToolApprovalResult(approved: false, denyReason: reason);
}

/// 一个待处理的 MCP 工具调用审批请求。
class ToolApprovalRequest {
  final String toolCallId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String? conversationId;
  final Completer<ToolApprovalResult> _completer;

  ToolApprovalRequest({
    required this.toolCallId,
    required this.toolName,
    required this.arguments,
    this.conversationId,
    required this._completer,
  });
}

/// 管理需要用户确认的 MCP 工具调用的审批状态。
///
/// 流程：
/// 1. 工具需要审批时，工具处理器调用 [requestApproval]。
///    它创建一个 [Completer]，将请求存入 [pendingRequests]，并返回
///    该 completer 的 future。工具处理器 `await` 此 future，从而阻塞执行。
/// 2. UI 监听本服务并显示批准/拒绝按钮。
/// 3. 用户点击批准/拒绝时，[approve] 或 [deny] 完成 completer，
///    解除对工具处理器的阻塞。
class ToolApprovalService extends ChangeNotifier {
  final Map<String, ToolApprovalRequest> _pending = {};

  /// 待处理审批请求的不可修改视图。
  Map<String, ToolApprovalRequest> get pendingRequests =>
      Map.unmodifiable(_pending);

  /// 是否存在待处理审批请求。
  bool get hasPending => _pending.isNotEmpty;

  /// 检查特定工具调用是否正在等待审批。
  bool isPending(String toolCallId) => _pending.containsKey(toolCallId);

  /// 为工具调用请求审批。
  /// 返回一个在用户批准或拒绝时完成的 [Future]。
  Future<ToolApprovalResult> requestApproval({
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
    String? conversationId,
  }) {
    final completer = Completer<ToolApprovalResult>();
    _pending[toolCallId] = ToolApprovalRequest(
      toolCallId: toolCallId,
      toolName: toolName,
      arguments: arguments,
      conversationId: conversationId,
      completer: completer,
    );
    notifyListeners();
    return completer.future;
  }

  /// 批准一个待处理工具调用。
  void approve(String toolCallId) {
    final req = _pending.remove(toolCallId);
    if (req != null && !req._completer.isCompleted) {
      req._completer.complete(ToolApprovalResult.approved());
    }
    notifyListeners();
  }

  /// 拒绝一个待处理工具调用，可附原因。
  void deny(String toolCallId, [String? reason]) {
    final req = _pending.remove(toolCallId);
    if (req != null && !req._completer.isCompleted) {
      req._completer.complete(ToolApprovalResult.denied(reason));
    }
    notifyListeners();
  }

  /// 取消所有待处理审批（例如流式被取消时）。
  void cancelAll() {
    for (final req in _pending.values) {
      if (!req._completer.isCompleted) {
        req._completer.complete(ToolApprovalResult.denied('cancelled'));
      }
    }
    _pending.clear();
    notifyListeners();
  }

  /// 取消属于 [conversationId] 的待处理审批。未记录会话的请求也会被取消
  /// （防止泄漏被阻塞的工具处理器的兜底措施），但属于其他会话的审批继续
  /// 等待，使取消一个会话不会破坏另一个会话的流。
  void cancelForConversation(String conversationId) {
    final toCancel = _pending.values
        .where(
          (req) =>
              req.conversationId == null ||
              req.conversationId == conversationId,
        )
        .toList();
    if (toCancel.isEmpty) return;
    for (final req in toCancel) {
      _pending.remove(req.toolCallId);
      if (!req._completer.isCompleted) {
        req._completer.complete(ToolApprovalResult.denied('cancelled'));
      }
    }
    notifyListeners();
  }
}
