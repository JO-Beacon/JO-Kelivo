/// Smart Add 候选 tokenizer (§12.6) 与 LIKE 转义 (§5.9)。
abstract final class MemoryTokenizer {
  MemoryTokenizer._();

  /// 必须从 CJK 二元组中过滤的中文停用字/词。
  static const Set<String> cjkStopwords = {
    '用户',
    '的',
    '了',
    '是',
    '在',
    '和',
    '与',
    '会',
    '要',
    '对',
    '这',
    '那',
    '他',
    '她',
    '它',
  };

  /// 英文停用词（小写）。包含 `user` / `users`（附录第 8 项）。
  static const Set<String> englishStopwords = {
    'the',
    'a',
    'an',
    'of',
    'to',
    'and',
    'or',
    'in',
    'on',
    'for',
    'with',
    'user',
    'users',
    'prefer',
    'prefers',
  };

  static final RegExp _cjkChar = RegExp(
    r'[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]',
  );
  static final RegExp _latinWord = RegExp(r'[a-z0-9]{2,}');

  /// 为 Smart Add 候选召回对 [text] 分词。
  ///
  /// - 英文/数字：按空白与标点拆分；保留长度 ≥ 2；
  ///   丢弃停用词；小写。
  /// - CJK：二元组；丢弃含停用字/词的二元组；小写。
  /// - 最多 8 个 token，按从左到右出现顺序。
  /// token 去重：重复 token 会在 `hits` 中被计两次，
  /// 扭曲候选排序。
  static List<String> tokenize(String text) {
    final lower = text.toLowerCase();
    final tokens = <String>{};

    var index = 0;
    while (index < lower.length && tokens.length < 8) {
      final ch = lower[index];
      if (_cjkChar.hasMatch(ch)) {
        final start = index;
        while (index < lower.length && _cjkChar.hasMatch(lower[index])) {
          index++;
        }
        final run = lower.substring(start, index);
        _addCjkBigrams(run, tokens);
      } else {
        final start = index;
        while (index < lower.length && !_cjkChar.hasMatch(lower[index])) {
          index++;
        }
        final run = lower.substring(start, index);
        _addLatinWords(run, tokens);
      }
    }

    return tokens.toList(growable: false);
  }

  static void _addCjkBigrams(String run, Set<String> tokens) {
    if (run.length < 2) return;
    for (var i = 0; i < run.length - 1 && tokens.length < 8; i++) {
      final gram = run.substring(i, i + 2);
      if (_cjkGramHasStopword(gram)) continue;
      tokens.add(gram);
    }
  }

  static bool _cjkGramHasStopword(String gram) {
    for (final stop in cjkStopwords) {
      if (gram.contains(stop)) return true;
    }
    return false;
  }

  static void _addLatinWords(String run, Set<String> tokens) {
    for (final match in _latinWord.allMatches(run)) {
      if (tokens.length >= 8) return;
      final word = match.group(0)!;
      if (englishStopwords.contains(word)) continue;
      tokens.add(word);
    }
  }

  /// 用 `\` 转义 `%`、`_`、`\`，用于 SQL `LIKE ... ESCAPE '\'` (§5.9)。
  static String escapeLike(String token) {
    return token
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }
}
