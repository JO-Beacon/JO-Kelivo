import 'memory_prompts.dart';

/// Gatekeeper 解析结果（§12.4 / §12.8）。
///
/// 成功解析为 `false` 会完成本次运行并推进 watermark。
/// [malformed] 或请求失败**不得**推进（§12.8）。
enum MemoryGateParseResult { worthRemembering, skip, malformed }

/// 纯 Gatekeeper 辅助函数（§12.4）。
abstract final class MemoryGatekeeper {
  MemoryGatekeeper._();

  static final RegExp _userMemoryRe = RegExp(
    r'<user_memory>\s*(true|false)',
    caseSensitive: false,
  );

  /// 解析 prompt 模板：用户覆盖项非空时使用它，否则使用内置模板。
  static String resolveTemplate({
    required MemoryPromptLang lang,
    String? overrideZh,
    String? overrideEn,
  }) {
    if (lang == MemoryPromptLang.zh) {
      final o = overrideZh?.trim();
      if (o != null && o.isNotEmpty) return o;
      return MemoryPrompts.gateZh;
    }
    final o = overrideEn?.trim();
    if (o != null && o.isNotEmpty) return o;
    return MemoryPrompts.gateEn;
  }

  static String buildPrompt({
    required MemoryPromptLang lang,
    required String conversation,
    String? overrideZh,
    String? overrideEn,
  }) {
    return resolveTemplate(
      lang: lang,
      overrideZh: overrideZh,
      overrideEn: overrideEn,
    ).replaceAll('{{conversation}}', conversation);
  }

  /// 解析 Gatekeeper XML。容忍周围正文；无法匹配时返回 [malformed]。
  static MemoryGateParseResult parse(String response) {
    final match = _userMemoryRe.firstMatch(response);
    if (match == null) return MemoryGateParseResult.malformed;
    final value = match.group(1)!.toLowerCase();
    if (value == 'true') return MemoryGateParseResult.worthRemembering;
    if (value == 'false') return MemoryGateParseResult.skip;
    return MemoryGateParseResult.malformed;
  }
}
