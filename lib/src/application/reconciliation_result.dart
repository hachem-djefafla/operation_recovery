import '../domain/operation_identity.dart';
import '../domain/operation_record.dart';

/// One independent operation's processing result in a reconciliation batch.
sealed class ReconciliationResult {
  const ReconciliationResult();

  /// The operation identity, always within the facade's scope.
  OperationIdentity get identity;
}

/// Processing completed, possibly without lookup if the record became ineligible.
final class ReconciliationCompleted extends ReconciliationResult {
  /// Creates a successful processing result, not necessarily a final outcome.
  const ReconciliationCompleted(this.record);

  /// The latest snapshot read or acknowledged by this processing invocation.
  final OperationRecord record;

  @override
  OperationIdentity get identity => record.identity;

  @override
  String toString() =>
      'ReconciliationCompleted(${record.state.name}, version: ${record.version})';
}

/// Processing failed while other batch operations may continue independently.
final class ReconciliationFailed extends ReconciliationResult {
  /// Retains explicit diagnostics without including them in default output.
  const ReconciliationFailed({
    required this.identity,
    required this.error,
    required this.stackTrace,
  });

  @override
  final OperationIdentity identity;

  /// The operation error; it is not an authoritative business rejection.
  final Object error;

  /// The stack trace associated with [error].
  final StackTrace stackTrace;

  @override
  String toString() => 'ReconciliationFailed';
}
