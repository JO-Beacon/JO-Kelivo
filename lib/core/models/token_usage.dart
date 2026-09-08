class TokenUsage {
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;
  final int totalTokens;

  const TokenUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cachedTokens = 0,
    this.totalTokens = 0,
  });

  /// 将新的用量快照折叠进运行值：最新的非零字段胜出，
  /// 因此后一轮的数字会替换前一轮而不是相加
  /// （各 provider 每轮都上报完整上下文）。
  TokenUsage merge(TokenUsage other) {
    // 对于流式响应：
    // - prompt tokens：取最大值（通常在初始值后保持不变）
    // - completion tokens：取最大值（随响应流式输出而增长）
    // - cached tokens：取最大值（通常只设置一次）
    final prompt = other.promptTokens > 0 ? other.promptTokens : promptTokens;
    final completion = other.completionTokens > 0
        ? other.completionTokens
        : completionTokens;
    final cached = other.cachedTokens > 0 ? other.cachedTokens : cachedTokens;
    final splitTotal = prompt + completion;
    final explicitTotal = other.totalTokens > 0
        ? other.totalTokens
        : totalTokens;
    final total = splitTotal > 0 ? splitTotal : explicitTotal;
    return TokenUsage(
      promptTokens: prompt,
      completionTokens: completion,
      cachedTokens: cached,
      totalTokens: total,
    );
  }
}
