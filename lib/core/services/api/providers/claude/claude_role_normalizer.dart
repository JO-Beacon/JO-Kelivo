/// The `messages` array of an Anthropic request must open with a `user` turn:
/// the API answers a request whose first message is `assistant` with a 400, and
/// a relay speaking the same protocol refuses it just as readily. Two things
/// here can leave an assistant turn first — a conversation whose opening
/// message is the reply it branched from, and a context window cut so that the
/// earliest surviving message is a reply — so every Anthropic request is
/// normalised at its own wire boundary rather than trusting the array to start
/// correctly.
///
/// The filler, and why it is not the period other clients use. This sits at the
/// first content position of the request, where attention is concentrated, so
/// what it carries matters more than its one token suggests. A period is
/// punctuation of the Latin script; a chat model told to answer its user will
/// read the language of what the user says and answer in it — that rule is
/// about *language*, and it applies downward from the user turn. Format is
/// different: a conversation model attributes the user's formatting to the
/// user, not to itself, so a lone `#` is read as the user's own quirk rather
/// than an instruction to change how the reply is written. A hash sign belongs
/// to no language's punctuation — numbering, markup and tags are not natural
/// language — so it carries no language signal for the model to answer in.
const String claudeFirstTurnPlaceholder = '#';

/// Longest filler the settings screen accepts. One character is the point of
/// the value; the cap only stops a paste from turning the filler into a
/// paragraph.
const int claudeFirstTurnPlaceholderMaxLength = 32;

/// Reduces [raw] to the form the wire can carry: a single line, no leading or
/// trailing whitespace, no longer than [claudeFirstTurnPlaceholderMaxLength].
/// Returns an empty string when nothing usable is left, which callers read as
/// "keep what you had" — an empty text block is a 400, so a filler of blanks
/// must never reach the request.
String normalizeClaudeFirstTurnPlaceholder(String raw) {
  final singleLine = raw.replaceAll(RegExp(r'[\s]+'), ' ').trim();
  if (singleLine.isEmpty) return '';
  return singleLine.length > claudeFirstTurnPlaceholderMaxLength
      ? singleLine.substring(0, claudeFirstTurnPlaceholderMaxLength)
      : singleLine;
}

/// Process-wide filler settings, synced from the settings provider.
///
/// Serialisation runs without a widget tree, so the request builders read this
/// instead of threading the preference through every call. Tests assign the
/// fields directly.
class ClaudeFirstTurnPlaceholderConfig {
  /// Whether an assistant-first request is repaired at all. Off by default: an
  /// assistant-first request is sent as it stands until the user turns this on,
  /// and the API's refusal stands with it.
  static bool enabled = false;

  /// What the filler turn says. Meaningless while [enabled] is false.
  static String text = claudeFirstTurnPlaceholder;

  /// The value to send, or null when there is nothing worth sending.
  static String? get filler {
    if (!enabled) return null;
    final value = normalizeClaudeFirstTurnPlaceholder(text);
    return value.isEmpty ? null : value;
  }
}

/// Makes [messages] — an Anthropic `messages` array with the system prompt
/// already taken out — open with a `user` turn, putting
/// [ClaudeFirstTurnPlaceholderConfig.filler] ahead of an assistant turn when one
/// is first.
///
/// It costs a token and never reaches the conversation: it exists in the
/// request body alone, so nothing the user typed is rewritten and nothing is
/// stored.
///
/// A run of turns sharing one role needs nothing: the API combines those into a
/// single turn itself, so the role of the first message is the only thing this
/// app has to get right.
void ensureClaudeFirstTurnIsUser(List<Map<String, dynamic>> messages) {
  if (messages.isEmpty) return;
  if ((messages.first['role'] ?? '').toString() == 'user') return;
  final filler = ClaudeFirstTurnPlaceholderConfig.filler;
  if (filler == null) return;
  messages.insert(0, {'role': 'user', 'content': filler});
}
