class AutoRetryOptions {
  const AutoRetryOptions({
    required this.enabled,
    this.maxRetries = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.multiplier = 2,
    this.maxDelay = const Duration(seconds: 30),
    this.jitter = true,
  });

  const AutoRetryOptions.defaults()
    : enabled = true,
      maxRetries = 3,
      initialDelay = const Duration(seconds: 1),
      multiplier = 2,
      maxDelay = const Duration(seconds: 30),
      jitter = true;

  final bool enabled;

  /// 首次请求失败后允许追加的尝试次数。
  final int maxRetries;
  final Duration initialDelay;
  final double multiplier;
  final Duration maxDelay;
  final bool jitter;

  AutoRetryOptions copyWith({bool? enabled}) {
    return AutoRetryOptions(
      enabled: enabled ?? this.enabled,
      maxRetries: maxRetries,
      initialDelay: initialDelay,
      multiplier: multiplier,
      maxDelay: maxDelay,
      jitter: jitter,
    );
  }
}
