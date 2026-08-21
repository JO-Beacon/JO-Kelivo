import '../../models/assistant.dart';
import '../../models/memory_entry.dart';
import 'memory_prompts.dart';

/// 从对话窗口提取的一个候选项（§12.5）。
class MemoryExtractedItem {
  const MemoryExtractedItem({
    required this.type,
    required this.content,
    this.scopeAttr,
  });

  final MemoryType type;
  final String content;

  /// 模型中原始的 `scope` 属性（`global` / `assistant`），如果有的话。
  /// 仅当写入策略为 `toolDefault*` 时才会采用（§4.3 / §12.5）。
  final String? scopeAttr;
}

/// Extract 解析结果。
class MemoryExtractParseResult {
  const MemoryExtractParseResult._({required this.ok, required this.items});

  factory MemoryExtractParseResult.ok(List<MemoryExtractedItem> items) =>
      MemoryExtractParseResult._(ok: true, items: items);

  factory MemoryExtractParseResult.malformed() =>
      const MemoryExtractParseResult._(
        ok: false,
        items: <MemoryExtractedItem>[],
      );

  final bool ok;
  final List<MemoryExtractedItem> items;
}

/// 纯 Extract 辅助函数（§12.5）。
abstract final class MemoryExtractor {
  MemoryExtractor._();

  static const int maxItems = 10;

  static final RegExp _extractedOpenRe = RegExp(
    r'<extracted\b',
    caseSensitive: false,
  );
  static final RegExp _itemRe = RegExp(
    r'<item\b([^>]*)>([\s\S]*?)</item>',
    caseSensitive: false,
  );
  static final RegExp _typeAttrRe = RegExp(
    r'''type\s*=\s*["'](identity|workflow|voice|instruction)["']''',
    caseSensitive: false,
  );
  static final RegExp _scopeAttrRe = RegExp(
    r'''scope\s*=\s*["'](global|assistant)["']''',
    caseSensitive: false,
  );

  static String resolveTemplate({
    required MemoryPromptLang lang,
    String? overrideZh,
    String? overrideEn,
  }) {
    if (lang == MemoryPromptLang.zh) {
      final o = overrideZh?.trim();
      if (o != null && o.isNotEmpty) return o;
      return MemoryPrompts.extractZh;
    }
    final o = overrideEn?.trim();
    if (o != null && o.isNotEmpty) return o;
    return MemoryPrompts.extractEn;
  }

  static String buildPrompt({
    required MemoryPromptLang lang,
    required String conversation,
    required String existingMemory,
    required MemoryWriteScope writeScope,
    String? overrideZh,
    String? overrideEn,
  }) {
    var template = resolveTemplate(
      lang: lang,
      overrideZh: overrideZh,
      overrideEn: overrideEn,
    );

    final toolDefault =
        writeScope == MemoryWriteScope.toolDefaultGlobal ||
        writeScope == MemoryWriteScope.toolDefaultAssistant;
    if (toolDefault) {
      final rule = MemoryPrompts.extractToolDefaultScopeRuleFor(lang);
      final marker = lang == MemoryPromptLang.zh
          ? '## 已有记忆'
          : '## Existing memory';
      if (template.contains(marker)) {
        template = template.replaceFirst(marker, '$rule\n\n$marker');
      } else {
        template = '$template\n\n$rule';
      }
    }

    return template
        .replaceAll('{{existingMemory}}', existingMemory)
        .replaceAll('{{conversation}}', conversation);
  }

  /// 解析 Extract XML。必须包含 `<extracted` 标签；否则返回 [malformed]。
  ///
  /// 无效类型或空内容会被丢弃。最多保留 [maxItems] 项。
  static MemoryExtractParseResult parse(String response) {
    if (!_extractedOpenRe.hasMatch(response)) {
      return MemoryExtractParseResult.malformed();
    }

    final items = <MemoryExtractedItem>[];
    for (final match in _itemRe.allMatches(response)) {
      if (items.length >= maxItems) break;
      final attrs = match.group(1) ?? '';
      final body = (match.group(2) ?? '').trim();
      if (body.isEmpty) continue;
      final typeMatch = _typeAttrRe.firstMatch(attrs);
      if (typeMatch == null) continue;
      MemoryType type;
      try {
        type = MemoryEntry.typeFromString(typeMatch.group(1)!.toLowerCase());
      } catch (_) {
        continue;
      }
      final scopeMatch = _scopeAttrRe.firstMatch(attrs);
      items.add(
        MemoryExtractedItem(
          type: type,
          content: body,
          scopeAttr: scopeMatch?.group(1)?.toLowerCase(),
        ),
      );
    }
    return MemoryExtractParseResult.ok(items);
  }
}
