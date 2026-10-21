import '../domain/operation_record.dart';

/// A live notification of an acknowledged commit by this coordinator.
///
/// The snapshot may already be superseded when delivered. Events are not replayed
/// or durably logged, and never contain transient request data or raw errors.
final class OperationEvent {
  /// Creates a committed-snapshot notification.
  const OperationEvent(this.record);

  /// The immutable snapshot acknowledged by storage.
  final OperationRecord record;

  @override
  String toString() =>
      'OperationEvent(${record.state.name}, version: ${record.version})';
}
