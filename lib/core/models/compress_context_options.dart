import 'chat_message.dart';
import '../../utils/utf16_safe_cut.dart';

enum CompressContextLimitMode { start, recent, unlimited, keepRecent }

class CompressContextOptions {
  const CompressContextOptions({
    required this.mode,
    this.maxChars,
    this.keepUserMessages,
  });

  static const int defaultMaxChars = 6000;
  static const int defaultRequestMaxChars = 6000;
  static const int defaultKeepUserMessages = 3;

  final CompressContextLimitMode mode;
  final int? maxChars;
  final int? keepUserMessages;
}

/// Resolve the model used by context compression.
///
/// Provider and model id intentionally follow independent fallback chains,
/// matching the settings behavior already used by the compression flow.
({String? providerKey, String? modelId}) resolveCompressContextModel({
  String? compressProvider,
  String? compressModelId,
  String? summaryProvider,
  String? summaryModelId,
  String? titleProvider,
  String? titleModelId,
  String? assistantProvider,
  String? assistantModelId,
  String? currentProvider,
  String? currentModelId,
}) {
  return (
    providerKey:
        compressProvider ??
        summaryProvider ??
        titleProvider ??
        assistantProvider ??
        currentProvider,
    modelId:
        compressModelId ??
        summaryModelId ??
        titleModelId ??
        assistantModelId ??
        currentModelId,
  );
}

String buildCompressContextContent(
  String joined,
  CompressContextOptions options,
) {
  if (options.mode == CompressContextLimitMode.unlimited) return joined;
  final maxChars = options.maxChars ?? CompressContextOptions.defaultMaxChars;
  if (maxChars <= 0 || joined.length <= maxChars) return joined;
  return switch (options.mode) {
    CompressContextLimitMode.start => truncateHeadUtf16Safe(joined, maxChars),
    CompressContextLimitMode.recent => truncateTailUtf16Safe(joined, maxChars),
    CompressContextLimitMode.unlimited => joined,
    CompressContextLimitMode.keepRecent => joined,
  };
}

/// Select the trailing messages beginning at the last N non-empty user turns.
/// Assistant/tool messages after the selected user turn remain verbatim.
List<ChatMessage> selectKeepRecentMessages(
  List<ChatMessage> messages,
  int keepUserMessages,
) {
  if (keepUserMessages <= 0) return const <ChatMessage>[];
  final userIndices = <int>[];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message.role == 'user' && message.content.trim().isNotEmpty) {
      userIndices.add(i);
    }
  }
  if (userIndices.isEmpty) return const <ChatMessage>[];
  if (userIndices.length <= keepUserMessages) return List.of(messages);
  return messages.sublist(userIndices[userIndices.length - keepUserMessages]);
}

int countUserMessages(List<ChatMessage> messages) {
  return messages
      .where(
        (message) =>
            message.role == 'user' && message.content.trim().isNotEmpty,
      )
      .length;
}

int defaultKeepUserMessageCountFor(int userMessageCount) {
  if (userMessageCount < 5) return 1;
  if (userMessageCount < 10) return 2;
  return 3;
}

class CompressionTokenEstimate {
  const CompressionTokenEstimate({
    required this.totalTokens,
    required this.keptTokens,
    required this.minResultTokens,
    required this.maxResultTokens,
  });

  final int totalTokens;
  final int keptTokens;
  final int minResultTokens;
  final int maxResultTokens;
}

bool _isCjkRune(int rune) {
  return (rune >= 0x2E80 && rune <= 0x9FFF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFF00 && rune <= 0xFFEF);
}

int _estimateCharsToTokens(String text) {
  var cjk = 0;
  var other = 0;
  for (final rune in text.runes) {
    if (_isCjkRune(rune)) {
      cjk++;
    } else {
      other++;
    }
  }
  return (cjk / 1.6 + other / 4).round();
}

CompressionTokenEstimate estimateCompressionTokens({
  required String totalText,
  required String keptText,
}) {
  final totalTokens = _estimateCharsToTokens(totalText);
  if (totalText.isEmpty) {
    return const CompressionTokenEstimate(
      totalTokens: 0,
      keptTokens: 0,
      minResultTokens: 0,
      maxResultTokens: 0,
    );
  }
  final keptTokens = (totalTokens * keptText.length / totalText.length).round();
  final oldTokens = totalTokens - keptTokens;
  return CompressionTokenEstimate(
    totalTokens: totalTokens,
    keptTokens: keptTokens,
    minResultTokens: keptTokens + (oldTokens * 0.10).round(),
    maxResultTokens: keptTokens + (oldTokens * 0.30).round(),
  );
}

String buildConversationTextForCompression(List<ChatMessage> messages) {
  return _compressionMessageTexts(messages).join('\n\n');
}

List<String> _compressionMessageTexts(List<ChatMessage> messages) {
  return messages
      .where((m) => m.content.trim().isNotEmpty)
      .map(
        (m) => '${m.role == "assistant" ? "Assistant" : "User"}: ${m.content}',
      )
      .toList(growable: false);
}

int compressionRequestCharBudget({
  required CompressContextOptions options,
  int? contextWindow,
}) {
  var budget = CompressContextOptions.defaultRequestMaxChars;
  if (contextWindow != null && contextWindow > 0) {
    // 保留系统提示词、压缩输出和供应商额外开销，按约 4 字符/token 估算。
    final available = contextWindow - 1200;
    budget = (available <= 512 ? 512 : available * 3 ~/ 4);
  }
  if (options.mode != CompressContextLimitMode.unlimited &&
      options.maxChars != null &&
      options.maxChars! > 0) {
    budget = budget < options.maxChars! ? budget : options.maxChars!;
  }
  return budget.clamp(512, 64000);
}

int? parseContextWindow(Map<String, dynamic> override) {
  const keys = <String>[
    'contextWindow',
    'context_window',
    'contextLength',
    'context_length',
    'maxContextTokens',
    'max_context_tokens',
    'inputTokenLimit',
    'input_token_limit',
  ];
  for (final key in keys) {
    final value = override[key];
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

List<String> chunkPlainTexts(List<String> texts, int maxCodeUnits) {
  final chunks = <String>[];
  var current = StringBuffer();
  void flush() {
    if (current.length > 0) chunks.add(current.toString());
    current = StringBuffer();
  }

  for (final text in texts) {
    if (text.isEmpty) continue;
    final separator = current.length == 0 ? '' : '\n\n';
    if (current.length + separator.length + text.length <= maxCodeUnits) {
      current.write(separator);
      current.write(text);
      continue;
    }
    flush();
    if (text.length <= maxCodeUnits) {
      current.write(text);
    } else {
      final parts = splitUtf16SafeChunks(text, maxCodeUnits);
      chunks.addAll(parts.take(parts.length - 1));
      if (parts.isNotEmpty) current.write(parts.last);
    }
  }
  flush();
  return chunks;
}

List<String> buildCompressRequestContents(
  List<ChatMessage> messages, {
  required CompressContextOptions options,
  required int maxCodeUnits,
}) {
  final texts = _compressionMessageTexts(messages);
  if (texts.isEmpty) return const <String>[];
  if (options.mode == CompressContextLimitMode.unlimited ||
      options.mode == CompressContextLimitMode.keepRecent) {
    return chunkPlainTexts(texts, maxCodeUnits);
  }
  final maxChars = options.maxChars ?? CompressContextOptions.defaultMaxChars;
  if (maxChars <= 0) return chunkPlainTexts(texts, maxCodeUnits);
  final selected = <String>[];
  var remaining = maxChars;
  final source = options.mode == CompressContextLimitMode.start
      ? texts
      : texts.reversed;
  for (final text in source) {
    if (remaining <= 0) break;
    final separator = selected.isEmpty ? 0 : 2;
    final available = remaining - separator;
    if (available <= 0) break;
    final part = text.length <= available
        ? text
        : (options.mode == CompressContextLimitMode.start
              ? truncateHeadUtf16Safe(text, available)
              : truncateTailUtf16Safe(text, available));
    if (part.isEmpty) break;
    selected.add(part);
    remaining -= separator + part.length;
    if (part.length < text.length) break;
  }
  if (options.mode == CompressContextLimitMode.recent) {
    return chunkPlainTexts(selected.reversed.toList(), maxCodeUnits);
  }
  return chunkPlainTexts(selected, maxCodeUnits);
}

bool isContextLengthError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('context length') ||
      text.contains('context_length') ||
      text.contains('maximum context') ||
      text.contains('too many tokens') ||
      text.contains('prompt is too long') ||
      text.contains('input token limit');
}

typedef CompressionTextGenerator = Future<String> Function(String content);

Future<String> summarizeWithContextRetry({
  required String content,
  required CompressionTextGenerator generate,
  int maxDepth = 5,
}) async {
  try {
    return await generate(content);
  } catch (error) {
    if (!isContextLengthError(error) || maxDepth <= 0 || content.length < 2) {
      rethrow;
    }
    final halves = splitUtf16SafeHalves(content);
    if (halves.length != 2 || halves.any((part) => part.isEmpty)) rethrow;
    final results = <String>[];
    for (final half in halves) {
      results.add(
        await summarizeWithContextRetry(
          content: half,
          generate: generate,
          maxDepth: maxDepth - 1,
        ),
      );
    }
    return results.where((part) => part.trim().isNotEmpty).join('\n\n');
  }
}
