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

  /// 累加已经结束的不同工具调用轮次；与同一轮流式快照的 [merge] 相反，
  /// 这里的 prompt/completion/cached token 都代表新增消耗。
  TokenUsage accumulate(TokenUsage other) {
    final prompt = promptTokens + other.promptTokens;
    final completion = completionTokens + other.completionTokens;
    final cached = cachedTokens + other.cachedTokens;
    final splitTotal = prompt + completion;
    return TokenUsage(
      promptTokens: prompt,
      completionTokens: completion,
      cachedTokens: cached,
      totalTokens: splitTotal > 0
          ? splitTotal
          : totalTokens + other.totalTokens,
    );
  }
}
