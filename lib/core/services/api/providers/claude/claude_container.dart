import 'dart:convert';

/// Provider artifact 的 kind：一轮对话的代码执行容器，存在执行它的那条
/// 助手消息上。
///
/// 只有**声明了代码执行工具**的请求才会存取容器。动态搜索过滤也会跑代码
/// 执行，但那是服务端自己准备的、且没有为它约定 `container` 契约 ——
/// 因此只做过搜索的一轮，无论响应里带了什么，都视为没有容器。
const String claudeContainerArtifactKind = 'claude_container';

/// 代码执行那一轮所运行的容器，按 API 报告的形式保存。
///
/// 文件与 REPL 状态都活在容器里，所以下一轮会把 id 送回去，接着上一轮
/// 继续。容器自创建起存活 30 天，空闲几分钟后会被打检查点；API 返回的
/// `expires_at` 只是那个短的滚动窗口、不是生命周期，因此不读它 ——
/// 容器会一直沿用，直到 API 拒绝它。
class ClaudeContainerRef {
  const ClaudeContainerRef({required this.id});

  final String id;

  /// 读取 Messages API 响应里的 `container` 对象。
  static ClaudeContainerRef? fromResponse(Object? container) {
    if (container is! Map) return null;
    final id = (container['id'] ?? '').toString();
    if (id.isEmpty) return null;
    return ClaudeContainerRef(id: id);
  }

  String encode() => jsonEncode({'id': id});

  static ClaudeContainerRef? decode(Object? payload) {
    if (payload is! String || payload.isEmpty) return null;
    try {
      return fromResponse(jsonDecode(payload));
    } catch (_) {
      return null;
    }
  }
}

/// 一个指名了容器的请求失败，是否就是因为它失败。
///
/// API 对过期或未知的容器没有专门的错误码，所以这里只能读错误消息。调用方
/// 只在请求确实带了 `container` 时才来问，因此一条提到容器的错误就是在说
/// 那个容器 —— 除非它说的是 `container_upload` 块，那种情况换个新容器
/// 也治不好。
bool isClaudeStaleContainerError(int statusCode, String errorBody) {
  if (statusCode < 400 || statusCode >= 500) return false;
  final message = errorBody.toLowerCase();
  return message.replaceAll('container_upload', '').contains('container');
}
