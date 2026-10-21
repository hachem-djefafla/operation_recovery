/// Execution-layer failures whose default descriptions omit sensitive data.
sealed class OperationExecutionException implements Exception {
  const OperationExecutionException();
}

/// Work was rejected because this facade is closing or closed.
final class OperationRecoveryClosedException
    extends OperationExecutionException {
  /// Creates a lifecycle rejection.
  const OperationRecoveryClosedException();

  @override
  String toString() => 'OperationRecoveryClosedException';
}

/// Registration configuration or use does not match the frozen registry.
final class InvalidOperationRegistrationException
    extends OperationExecutionException {
  /// Describes a configuration requirement without retaining identity values.
  const InvalidOperationRegistrationException(this.reason);

  /// A safe description of the violated registration requirement.
  final String reason;

  @override
  String toString() => 'InvalidOperationRegistrationException($reason)';
}

/// A transient request does not match the registration's captured request type.
final class InvalidOperationRequestException
    extends OperationExecutionException {
  /// Creates a request-type rejection without retaining the request.
  const InvalidOperationRequestException();

  @override
  String toString() => 'InvalidOperationRequestException';
}

/// The integration action in which an unexpected handler failure occurred.
enum HandlerAction {
  /// The intentional business submission.
  submit,

  /// An authoritative status lookup.
  lookupStatus,
}

/// An unexpected adapter exception after safe uncertainty was acknowledged.
///
/// [cause] and [stackTrace] are in-memory debugging information, never persisted
/// or included in default string output. Storage failures surface separately.
final class OperationHandlerException extends OperationExecutionException {
  /// Retains explicit diagnostic access while keeping default output safe.
  const OperationHandlerException({
    required this.action,
    required this.cause,
    required this.stackTrace,
  });

  /// The handler action which failed.
  final HandlerAction action;

  /// The original exception; applications control any explicit logging of it.
  final Object cause;

  /// The original handler stack trace.
  final StackTrace stackTrace;

  @override
  String toString() => 'OperationHandlerException(${action.name})';
}
