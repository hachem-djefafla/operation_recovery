import 'operation_state.dart';

/// A typed domain failure whose description omits operation identity values.
sealed class OperationRecoveryException implements Exception {
  const OperationRecoveryException();
}

/// A domain action addressed a record unavailable in the coordinator's scope.
///
/// Missing and foreign-scope records produce the same failure without identity
/// values or any indication that a record exists in another scope.
final class OperationNotFoundException extends OperationRecoveryException {
  /// Creates a failure without exposing operation identity or existence.
  const OperationNotFoundException();

  @override
  String toString() => 'OperationNotFoundException';
}

/// An identity or snapshot violates the domain's structural requirements.
final class InvalidOperationRecordException extends OperationRecoveryException {
  /// Creates a validation failure without retaining the rejected value.
  const InvalidOperationRecordException(this.field, this.reason);

  /// The invalid field's name, not its value.
  final String field;

  /// A description of the violated requirement.
  final String reason;

  @override
  String toString() => 'InvalidOperationRecordException($field: $reason)';
}

/// An operation was addressed using a different immutable identity.
final class OperationIdentityConflictException
    extends OperationRecoveryException {
  /// Creates a conflict without retaining either identity.
  const OperationIdentityConflictException();

  @override
  String toString() => 'OperationIdentityConflictException';
}

/// An internal action is not permitted in the record's current state.
final class IllegalOperationTransitionException
    extends OperationRecoveryException {
  /// Describes the rejected action and state without changing the snapshot.
  const IllegalOperationTransitionException({
    required this.state,
    required this.action,
  });

  /// The state in which the action was attempted.
  final OperationState state;

  /// The name of the rejected domain action.
  final String action;

  @override
  String toString() =>
      'IllegalOperationTransitionException(${state.name}, $action)';
}

/// A backend observation contains invalid outcome metadata.
final class InvalidBackendObservationException
    extends OperationRecoveryException {
  /// Creates a validation failure without retaining backend response data.
  const InvalidBackendObservationException(this.field, this.reason);

  /// The invalid metadata field's name.
  final String field;

  /// A description of the violated requirement.
  final String reason;

  @override
  String toString() => 'InvalidBackendObservationException($field: $reason)';
}

/// Authoritative evidence conflicts with an already confirmed business outcome.
///
/// The original record stays unchanged. Equal states can still contradict when
/// both observations supply different non-null final references or codes.
final class ContradictoryBackendObservationException
    extends OperationRecoveryException {
  /// Describes the conflicting states without retaining sensitive metadata.
  const ContradictoryBackendObservationException({
    required this.confirmedState,
    required this.observedState,
  });

  /// The immutable outcome already confirmed locally.
  final OperationState confirmedState;

  /// The outcome asserted by the contradictory observation.
  final OperationState observedState;

  @override
  String toString() =>
      'ContradictoryBackendObservationException('
      '${confirmedState.name}, ${observedState.name})';
}
