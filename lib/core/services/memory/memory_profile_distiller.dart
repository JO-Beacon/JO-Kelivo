import 'dart:convert';

import '../../database/chat_database_repository.dart';
import '../../models/memory_entry.dart';
import '../../models/user_profile_field.dart';
import 'memory_block_builder.dart';
import 'memory_prompts.dart';
import 'memory_repository.dart';
import 'memory_trace.dart';

/// Distiller JSON 中的一个提炼后的画像字段（§12.7）。
class MemoryDistilledField {
  const MemoryDistilledField({required this.key, required this.value});

  final String key;
  final String value;
}

/// Distiller 解析结果。[ok] 为 false 表示 JSON 无法解析。
class MemoryDistillParseResult {
  const MemoryDistillParseResult._({required this.ok, required this.fields});

  factory MemoryDistillParseResult.ok(List<MemoryDistilledField> fields) =>
      MemoryDistillParseResult._(ok: true, fields: fields);

  factory MemoryDistillParseResult.malformed() =>
      const MemoryDistillParseResult._(
        ok: false,
        fields: <MemoryDistilledField>[],
      );

  final bool ok;
  final List<MemoryDistilledField> fields;
}

/// Profile Distiller（§12.7）。
class MemoryProfileDistiller {
  MemoryProfileDistiller({
    required this.repository,
    required this.chatRepository,
  });

  final MemoryRepository repository;
  final ChatDatabaseRepository chatRepository;

  static String resolveTemplate({
    required MemoryPromptLang lang,
    String? overrideZh,
    String? overrideEn,
  }) {
    if (lang == MemoryPromptLang.zh) {
      final o = overrideZh?.trim();
      if (o != null && o.isNotEmpty) return o;
      return MemoryPrompts.profileDistillZh;
    }
    final o = overrideEn?.trim();
    if (o != null && o.isNotEmpty) return o;
    return MemoryPrompts.profileDistillEn;
  }

  static String buildPrompt({
    required MemoryPromptLang lang,
    required String profileBlock,
    required String identityEntries,
    String? overrideZh,
    String? overrideEn,
  }) {
    return resolveTemplate(
          lang: lang,
          overrideZh: overrideZh,
          overrideEn: overrideEn,
        )
        .replaceAll('{{profileBlock}}', profileBlock)
        .replaceAll('{{identityEntries}}', identityEntries);
  }

  /// 为 `{{identityEntries}}` 格式化身份记忆。
  static String formatIdentityEntries(List<MemoryEntry> entries) {
    if (entries.isEmpty) return '';
    final buf = StringBuffer();
    for (final e in entries) {
      buf.writeln('${e.id} ${e.content}');
    }
    return buf.toString().trimRight();
  }

  /// 从模型输出中提取 JSON 对象（可容忍正文文本 / 代码围栏）。
  static Object? extractJsonObject(String response) {
    var text = response.trim();
    final fence = RegExp(
      r'```(?:json)?\s*([\s\S]*?)```',
      caseSensitive: false,
    ).firstMatch(text);
    if (fence != null) {
      text = fence.group(1)!.trim();
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      return jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }

  static MemoryDistillParseResult parse(String response) {
    final decoded = extractJsonObject(response);
    if (decoded is! Map) return MemoryDistillParseResult.malformed();
    final rawFields = decoded['fields'];
    if (rawFields is! List) return MemoryDistillParseResult.malformed();

    final fields = <MemoryDistilledField>[];
    for (final item in rawFields) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final key = (map['key'] ?? '').toString().trim();
      final value = (map['value'] ?? '').toString().trim();
      if (key.isEmpty || value.isEmpty) continue;
      if (!UserProfileField.isValidKey(key)) continue;
      // Distiller 从不清除（§12.7）；空内容已在前面跳过。
      fields.add(MemoryDistilledField(key: key, value: value));
    }
    return MemoryDistillParseResult.ok(fields);
  }

  /// 在 identity NEW/MERGE/CONFLICT 后运行 Distiller。遇到 LLM/解析失败时返回 false
  /// （调用方仍按 §12.8 推进 watermark）。
  Future<bool> run({
    required MemoryPromptLang lang,
    required String? assistantId,
    required Future<String> Function(String prompt) llmCall,
    String? overrideZh,
    String? overrideEn,
    MemoryTraceStep? traceStep,
  }) async {
    final identity = await chatRepository.queryVisibleMemories(
      assistantId: assistantId,
      type: MemoryType.identity,
    );
    if (identity.isEmpty) {
      traceStep?.parsedResult = 'no_identity_entries';
      return true;
    }

    final profile = await chatRepository.readProfileFields();
    final profileBlock = MemoryBlockBuilder.buildProfileBlock(
      fields: profile,
      lang: lang,
    );
    final prompt = buildPrompt(
      lang: lang,
      profileBlock: profileBlock,
      identityEntries: formatIdentityEntries(identity),
      overrideZh: overrideZh,
      overrideEn: overrideEn,
    );

    traceStep?.appendPrompt(prompt);
    final String raw;
    try {
      raw = await llmCall(prompt);
    } catch (e) {
      traceStep?.appendResponse('<request failed> $e');
      return false;
    }
    traceStep?.appendResponse(raw);

    final parsed = parse(raw);
    if (!parsed.ok) {
      traceStep?.parsedResult = 'malformed';
      return false;
    }
    traceStep?.setParsedJson({
      'fields': [
        for (final f in parsed.fields) {'key': f.key, 'value': f.value},
      ],
    });

    for (final field in parsed.fields) {
      try {
        String? before;
        for (final existing in profile) {
          if (existing.key == field.key) {
            before = existing.value;
            break;
          }
        }
        await repository.putProfileField(
          field.key,
          field.value,
          MemorySource.distilled,
        );
        traceStep?.addMutation(
          MemoryTraceMutation(
            kind: MemoryTraceMutationKind.profileFieldWritten,
            targetId: field.key,
            before: before,
            after: field.value,
          ),
        );
      } catch (_) {
        // 非法键已被过滤；忽略写入竞争。
      }
    }
    return true;
  }
}
