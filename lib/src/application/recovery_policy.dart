/// Explicit lookup budget and bounded exponential delay, without polling.
final class RecoveryPolicy {
  /// Creates a policy with a positive attempt limit and positive bounded delays.
  RecoveryPolicy({
    required this.maxAttempts,
    required this.initialDelay,
    required this.maxDelay,
  }) {
    if (maxAttempts < 1) throw ArgumentError('maxAttempts must be positive');
    if (initialDelay <= Duration.zero || maxDelay < initialDelay) {
      throw ArgumentError(
        'Delays must be positive with maxDelay >= initialDelay',
      );
    }
  }

  /// Maximum reserved lookups in one cycle; submission is not a lookup attempt.
  final int maxAttempts;

  /// Delay following the first lookup reservation/result.
  final Duration initialDelay;

  /// Maximum delay between eligible lookups.
  final Duration maxDelay;

  /// Returns min(initialDelay * 2^(attempt - 1), maxDelay), with saturation.
  Duration delayForAttempt(int attempt) {
    if (attempt < 1) throw ArgumentError('attempt must be positive');
    var delay = initialDelay.inMicroseconds;
    final cap = maxDelay.inMicroseconds;
    var remaining = attempt - 1;
    while (remaining > 0 && delay < cap) {
      delay = delay >= cap - delay ? cap : delay * 2;
      remaining--;
    }
    return Duration(microseconds: delay);
  }
}
