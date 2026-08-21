import '../core/models/assistant.dart';
import '../core/models/assistant_regex.dart';

final Map<String, RegExp?> _compiledPatternCache = <String, RegExp?>{};
const int _maxCompiledPatternCacheSize = 256;

enum AssistantRegexTransformTarget {
  /// 持久化时执行的转换，会修改已存储的内容。
  persist,

  /// 仅影响显示的转换，只改变渲染结果。
  visual,

  /// 发送时执行的转换，只影响发送给模型的内容。
  send,
}

String applyAssistantRegexes(
  String input, {
  required Assistant? assistant,
  required AssistantRegexScope scope,
  required AssistantRegexTransformTarget target,
}) {
  if (input.isEmpty) return input;
  if (assistant == null) return input;
  if (assistant.regexRules.isEmpty) return input;

  String out = input;
  for (final rule in assistant.regexRules) {
    if (!rule.enabled) continue;
    if (!rule.scopes.contains(scope)) continue;
    if (rule.visualOnly) {
      if (target != AssistantRegexTransformTarget.visual) continue;
    } else if (rule.replaceOnly) {
      if (target != AssistantRegexTransformTarget.send) continue;
    } else {
      if (target != AssistantRegexTransformTarget.persist) continue;
    }
    final pattern = rule.pattern.trim();
    if (pattern.isEmpty) continue;
    if (!_compiledPatternCache.containsKey(pattern) &&
        _compiledPatternCache.length >= _maxCompiledPatternCacheSize) {
      _compiledPatternCache.clear();
    }
    final regex = _compiledPatternCache.putIfAbsent(pattern, () {
      try {
        return RegExp(pattern);
      } catch (_) {
        return null;
      }
    });
    if (regex == null) continue;
    out = out.replaceAllMapped(regex, (match) {
      return _expandReplacement(rule.replacement, match);
    });
  }
  return out;
}

/// 用捕获组引用（$0、$1、$2 等）展开替换字符串。
String _expandReplacement(String replacement, Match match) {
  // 用于匹配 $0、$1、$2、... $99 的模式
  final refPattern = RegExp(r'\$(\d{1,2})');
  return replacement.replaceAllMapped(refPattern, (m) {
    final groupIndex = int.parse(m.group(1)!);
    if (groupIndex <= match.groupCount) {
      return match.group(groupIndex) ?? '';
    }
    // 如果对应捕获组不存在，则返回原始引用
    return m.group(0)!;
  });
}
