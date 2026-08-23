import '../../../core/database/chat_database_repository.dart';
import '../../../core/services/chat/chat_service.dart';

class GlobalSessionSearchResult {
  const GlobalSessionSearchResult({
    required this.conversationId,
    required this.conversationTitle,
    required this.updatedAt,
    required this.firstMatchedMessageId,
    required this.snippet,
    required this.score,
    required this.titleMatched,
  });

  final String conversationId;
  final String conversationTitle;
  final DateTime updatedAt;
  final String firstMatchedMessageId;
  final String snippet;
  final int score;
  final bool titleMatched;
}

class GlobalSessionSearchService {
  const GlobalSessionSearchService._();

  // 不应参与全局搜索的隐藏或内部块。
  static final RegExp _geminiThoughtSigRe = RegExp(
    r'<!--\s*gemini_thought_signatures:.*?-->',
    dotAll: true,
  );
  static final RegExp _thinkBlockRe = RegExp(
    r'<(?:think|thought)>[\s\S]*?<\/(?:think|thought)>',
    caseSensitive: false,
  );
  static final RegExp _reasoningBlockRe = RegExp(
    r'<reasoning>[\s\S]*?<\/reasoning>',
    caseSensitive: false,
  );

  static Future<List<GlobalSessionSearchResult>> search({
    required ChatService chatService,
    required String query,
    int limit = 200,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const <GlobalSessionSearchResult>[];

    final tokens = _tokensOf(normalized);
    if (tokens.isEmpty) return const <GlobalSessionSearchResult>[];

    final out = <GlobalSessionSearchResult>[];
    final candidates = await chatService.searchConversationMatches(
      tokens: tokens,
      limit: limit,
    );
    final grouped = <String, List<ConversationSearchMatch>>{};
    for (final candidate in candidates) {
      grouped.putIfAbsent(candidate.conversationId, () => []).add(candidate);
    }

    for (final matches in grouped.values) {
      final tree = await chatService.loadConversationTree(
        matches.first.conversationId,
      );
      final activeIds = tree?.activePath().toSet();
      final visibleMatches = activeIds == null
          ? matches
          : matches
                .where(
                  (match) =>
                      match.messageId == null ||
                      activeIds.contains(match.messageId),
                )
                .toList(growable: false);
      final result = _matchConversationFromSqliteCandidates(
        matches: visibleMatches,
        tokens: tokens,
      );
      if (result != null) out.add(result);
    }

    out.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      return b.updatedAt.compareTo(a.updatedAt);
    });

    if (out.length <= limit) return out;
    return out.sublist(0, limit);
  }

  static GlobalSessionSearchResult? _matchConversationFromSqliteCandidates({
    required List<ConversationSearchMatch> matches,
    required List<String> tokens,
  }) {
    if (matches.isEmpty) return null;
    final first = matches.first;
    final title = first.conversationTitle.trim();
    final lowerTitle = title.toLowerCase();

    final contentItems = <_ContentRef>[];
    for (final m in matches) {
      // 只搜索可见会话正文：用户和助手消息。
      // 排除工具或系统类消息以及隐藏的推理或思考块。
      if (m.messageRole != 'user' && m.messageRole != 'assistant') continue;
      final body = _searchableBody(m.messageContent ?? '');
      if (body.isEmpty) continue;
      final messageId = m.messageId;
      if (messageId == null || messageId.isEmpty) continue;
      contentItems.add(_ContentRef(messageId: messageId, text: body));
    }
    if (contentItems.isEmpty && title.isEmpty) return null;

    final contentLower = contentItems
        .map((e) => e.text.toLowerCase())
        .join('\n');
    final searchHaystack = '$lowerTitle\n$contentLower';
    for (final t in tokens) {
      if (!searchHaystack.contains(t)) return null;
    }

    final titleMatches = _countMatches(lowerTitle, tokens);
    final firstMatchedIndex = _firstMatchedContentIndex(contentItems, tokens);
    final contentMatches = _countMatches(contentLower, tokens);
    final hasTitleMatch = titleMatches > 0;

    final fallbackMessageId = contentItems.isNotEmpty
        ? contentItems.first.messageId
        : '';
    final matchedMessageId =
        (firstMatchedIndex >= 0 && firstMatchedIndex < contentItems.length)
        ? contentItems[firstMatchedIndex].messageId
        : '';
    final targetMessageId = matchedMessageId.isNotEmpty
        ? matchedMessageId
        : fallbackMessageId;
    // 仅标题命中的会话：targetMessageId 为空但标题匹配，以空 messageId 包含结果。

    final displayTitle = title.isEmpty ? '(Untitled)' : title;
    var snippet = firstMatchedIndex >= 0
        ? _contextSnippet(
            items: contentItems,
            centerIndex: firstMatchedIndex,
            tokens: tokens,
          )
        : _snippetFor(title, tokens);

    final titleHasVisibleHit = _containsAnyToken(
      displayTitle.toLowerCase(),
      tokens,
    );
    var snippetHasVisibleHit = _containsAnyToken(snippet.toLowerCase(), tokens);

    // 保证每个可见结果在标题或摘要中至少有一个可高亮 token。
    // 如果当前摘要缺少所有 token，则回退到第一条匹配消息的聚焦摘要。
    if (!titleHasVisibleHit && !snippetHasVisibleHit) {
      if (firstMatchedIndex >= 0 && firstMatchedIndex < contentItems.length) {
        snippet = _snippetFor(contentItems[firstMatchedIndex].text, tokens);
        snippetHasVisibleHit = _containsAnyToken(snippet.toLowerCase(), tokens);
      }
    }

    if (!titleHasVisibleHit && !snippetHasVisibleHit) {
      return null;
    }

    final score = (titleMatches * 30) + (contentMatches * 10);

    return GlobalSessionSearchResult(
      conversationId: first.conversationId,
      conversationTitle: displayTitle,
      updatedAt: first.updatedAt,
      firstMatchedMessageId: targetMessageId,
      snippet: snippet,
      score: score,
      titleMatched: hasTitleMatch,
    );
  }

  static List<String> _tokensOf(String query) {
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static int _countMatches(String text, List<String> tokens) {
    if (text.isEmpty) return 0;
    var score = 0;
    for (final t in tokens) {
      var start = 0;
      while (true) {
        final idx = text.indexOf(t, start);
        if (idx < 0) break;
        score++;
        start = idx + t.length;
      }
    }
    return score;
  }

  static int _firstMatchedContentIndex(
    List<_ContentRef> items,
    List<String> tokens,
  ) {
    for (var i = 0; i < items.length; i++) {
      final lower = items[i].text.toLowerCase();
      for (final t in tokens) {
        if (lower.contains(t)) return i;
      }
    }
    return -1;
  }

  static String _contextSnippet({
    required List<_ContentRef> items,
    required int centerIndex,
    required List<String> tokens,
    int minChars = 110,
    int maxChars = 180,
  }) {
    if (items.isEmpty) return '';

    final center = centerIndex.clamp(0, items.length - 1);
    var left = center;
    var right = center;

    String joinWindow() {
      return [
        for (var i = left; i <= right; i++) _normalize(items[i].text),
      ].where((e) => e.isNotEmpty).join('  ');
    }

    var windowText = joinWindow();
    var step = 1;
    while (windowText.length < minChars &&
        (center - step >= 0 || center + step <= items.length - 1)) {
      if (center - step >= 0) left = center - step;
      if (center + step <= items.length - 1) right = center + step;
      step++;
      windowText = joinWindow();
    }

    if (windowText.isEmpty) return '';

    final lower = windowText.toLowerCase();
    var hit = -1;
    for (final t in tokens) {
      final idx = lower.indexOf(t);
      if (idx >= 0 && (hit < 0 || idx < hit)) hit = idx;
    }

    var start = 0;
    var end = windowText.length;
    if (windowText.length > maxChars) {
      if (hit >= 0) {
        // 让命中位置保持在预览中间，使其在三行摘要中很可能可见，
        // 并大致落在第二行附近。
        final anchor = (maxChars * 0.45).round();
        start = (hit - anchor).clamp(0, windowText.length - maxChars);
      }
      end = (start + maxChars).clamp(0, windowText.length);
    }

    final hasBefore = left > 0 || start > 0;
    final hasAfter = right < items.length - 1 || end < windowText.length;
    var frag = windowText.substring(start, end).trim();
    if (hasBefore) frag = '... $frag';
    if (hasAfter) frag = '$frag ...';
    return frag;
  }

  static String _normalize(String input) {
    return input
        .replaceAll(RegExp(r'[\t\n\r]+'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  }

  static String _searchableBody(String content) {
    if (content.trim().isEmpty) return '';
    return _normalize(
      content
          .replaceAll(_geminiThoughtSigRe, ' ')
          .replaceAll(_thinkBlockRe, ' ')
          .replaceAll(_reasoningBlockRe, ' '),
    );
  }

  static String _snippetFor(String source, List<String> tokens) {
    final s = source.trim();
    if (s.isEmpty) return '';
    final lower = s.toLowerCase();
    var hit = -1;
    for (final t in tokens) {
      final idx = lower.indexOf(t);
      if (idx >= 0 && (hit < 0 || idx < hit)) hit = idx;
    }
    if (hit < 0) {
      return s.length <= 140 ? s : '${s.substring(0, 140)}...';
    }
    const maxChars = 180;
    final start = (hit - (maxChars * 0.45).round()).clamp(
      0,
      (s.length - maxChars).clamp(0, s.length),
    );
    final end = (start + maxChars).clamp(0, s.length);
    final frag = s.substring(start, end).trim();
    final prefix = start > 0 ? '... ' : '';
    final suffix = end < s.length ? ' ...' : '';
    return '$prefix$frag$suffix';
  }

  static bool _containsAnyToken(String text, List<String> tokens) {
    if (text.isEmpty || tokens.isEmpty) return false;
    for (final t in tokens) {
      if (text.contains(t)) return true;
    }
    return false;
  }
}

class _ContentRef {
  const _ContentRef({required this.messageId, required this.text});

  final String messageId;
  final String text;
}
