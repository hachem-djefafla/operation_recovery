/// The client's durable knowledge of an operation's business outcome.
enum OperationState {
  /// Identity is recorded, but submission has not been initiated.
  prepared,

  /// The request may have reached the backend; its outcome is unresolved.
  awaitingOutcome,

  /// An authoritative backend observation confirmed success.
  succeeded,

  /// An authoritative backend observation confirmed final business rejection.
  rejected,

  /// Recovery is paused; the business outcome remains unresolved.
  needsAttention;

  /// Whether an authoritative final business outcome has been recorded.
  bool get isTerminal => this == succeeded || this == rejected;

  /// Whether the client still lacks an authoritative final business outcome.
  bool get isUnresolved => !isTerminal;
}
