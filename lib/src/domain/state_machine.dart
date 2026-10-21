import 'backend_observation.dart';
import 'operation_exception.dart';
import 'operation_identity.dart';
import 'operation_record.dart';
import 'operation_state.dart';
import 'recovery_metadata.dart';

/// Internal pure transitions. Returned snapshots have not been persisted.
final class OperationStateMachine {
  /// Creates the stateless transition implementation.
  const OperationStateMachine();

  /// Proposes uncertainty before submission; this is not permission to send.
  OperationRecord beginSubmission(
    OperationRecord record, {
    required OperationIdentity identity,
    required DateTime at,
    DateTime? firstCheckAt,
  }) {
    record.identity.requireMatch(identity);
    _requireState(record, OperationState.prepared, 'beginSubmission');
    return _change(
      record,
      state: OperationState.awaitingOutcome,
      at: at,
      recovery: RecoveryMetadata.restore(
        cycleAttempts: 0,
        totalAttempts: 0,
        nextCheckAt: firstCheckAt,
      ),
    );
  }

  /// Applies semantic evidence without regressing any confirmed outcome.
  OperationRecord applyObservation(
    OperationRecord record,
    BackendObservation observation, {
    required DateTime at,
  }) {
    record.identity.requireMatch(observation.identity);
    if (record.state.isTerminal) {
      _checkTerminalConsistency(record, observation);
      return record;
    }
    _requireState(record, OperationState.awaitingOutcome, 'applyObservation');
    final state = _observedState(observation);
    return _change(record, state: state, at: at, observation: observation);
  }

  /// Pauses recovery without claiming a final business outcome.
  OperationRecord pause(OperationRecord record, {required DateTime at}) {
    _requireState(record, OperationState.awaitingOutcome, 'pause');
    return _change(record, state: OperationState.needsAttention, at: at);
  }

  /// Explicitly reopens recovery for lookups; it never authorizes submission.
  OperationRecord resume(OperationRecord record, {required DateTime at}) {
    _requireState(record, OperationState.needsAttention, 'resume');
    return _change(
      record,
      state: OperationState.awaitingOutcome,
      at: at,
      recovery: RecoveryMetadata.restore(
        cycleAttempts: 0,
        totalAttempts: record.recovery.totalAttempts,
        lastAttemptAt: record.recovery.lastAttemptAt,
        nextCheckAt: at,
      ),
    );
  }

  /// Reserves one lookup before its external invocation, in one record revision.
  OperationRecord reserveRecoveryAttempt(
    OperationRecord record, {
    required DateTime at,
    required DateTime nextCheckAt,
    required int attemptLimit,
  }) {
    _requireState(
      record,
      OperationState.awaitingOutcome,
      'reserveRecoveryAttempt',
    );
    if (attemptLimit < 1 ||
        record.recovery.cycleAttempts >= attemptLimit ||
        (record.recovery.nextCheckAt != null &&
            at.isBefore(record.recovery.nextCheckAt!))) {
      throw IllegalOperationTransitionException(
        state: record.state,
        action: 'reserveRecoveryAttempt',
      );
    }
    _requireFutureCheck(at, nextCheckAt);
    return _change(
      record,
      state: record.state,
      at: at,
      recovery: RecoveryMetadata.restore(
        cycleAttempts: record.recovery.cycleAttempts + 1,
        totalAttempts: record.recovery.totalAttempts + 1,
        lastAttemptAt: at,
        nextCheckAt: nextCheckAt,
      ),
    );
  }

  /// Completes a reserved lookup; final evidence wins over budget exhaustion.
  OperationRecord completeRecoveryAttempt(
    OperationRecord record,
    BackendObservation observation, {
    required DateTime at,
    required DateTime nextCheckAt,
    required int attemptLimit,
  }) {
    record.identity.requireMatch(observation.identity);
    _requireState(
      record,
      OperationState.awaitingOutcome,
      'completeRecoveryAttempt',
    );
    if (attemptLimit < 1 || record.recovery.cycleAttempts < 1) {
      throw IllegalOperationTransitionException(
        state: record.state,
        action: 'completeRecoveryAttempt',
      );
    }
    _requireFutureCheck(at, nextCheckAt);
    final observed = _observedState(observation);
    final state =
        !observed.isTerminal && record.recovery.cycleAttempts >= attemptLimit
        ? OperationState.needsAttention
        : observed;
    return _change(
      record,
      state: state,
      at: at,
      observation: observation,
      recovery: RecoveryMetadata.restore(
        cycleAttempts: record.recovery.cycleAttempts,
        totalAttempts: record.recovery.totalAttempts,
        lastAttemptAt: record.recovery.lastAttemptAt,
        nextCheckAt: state == OperationState.awaitingOutcome
            ? nextCheckAt
            : null,
      ),
    );
  }

  OperationState _observedState(BackendObservation observation) =>
      switch (observation) {
        OperationSucceeded() => OperationState.succeeded,
        OperationRejected() => OperationState.rejected,
        OperationPending() ||
        OperationUnknown() ||
        LookupUnavailable() => OperationState.awaitingOutcome,
      };

  void _requireFutureCheck(DateTime at, DateTime nextCheckAt) {
    if (!nextCheckAt.isAfter(at)) {
      throw const InvalidOperationRecordException(
        'recovery.nextCheckAt',
        'a reservation or completion must schedule a positive delay',
      );
    }
  }

  void _requireState(
    OperationRecord record,
    OperationState expected,
    String action,
  ) {
    if (record.state != expected) {
      throw IllegalOperationTransitionException(
        state: record.state,
        action: action,
      );
    }
  }

  OperationRecord _change(
    OperationRecord record, {
    required OperationState state,
    required DateTime at,
    BackendObservation? observation,
    RecoveryMetadata? recovery,
  }) {
    if (at.isBefore(record.updatedAt)) {
      throw const InvalidOperationRecordException(
        'updatedAt',
        'must not precede the previous update',
      );
    }
    var metadata = recovery ?? record.recovery;
    if (state.isTerminal || state == OperationState.needsAttention) {
      metadata = RecoveryMetadata.restore(
        cycleAttempts: metadata.cycleAttempts,
        totalAttempts: metadata.totalAttempts,
        lastAttemptAt: metadata.lastAttemptAt,
      );
    }
    return OperationRecord.restore(
      identity: record.identity,
      state: state,
      version: record.version + 1,
      createdAt: record.createdAt,
      updatedAt: at,
      lastObservation: observation ?? record.lastObservation,
      recovery: metadata,
    );
  }

  void _checkTerminalConsistency(
    OperationRecord record,
    BackendObservation observation,
  ) {
    if (!observation.isAuthoritative) return;
    final confirmed = record.lastObservation;
    final consistent = switch ((confirmed, observation)) {
      (
        OperationSucceeded(backendReference: final confirmedReference),
        OperationSucceeded(backendReference: final observedReference),
      ) =>
        _compatibleMetadata(confirmedReference, observedReference),
      (
        OperationRejected(code: final confirmedCode),
        OperationRejected(code: final observedCode),
      ) =>
        _compatibleMetadata(confirmedCode, observedCode),
      _ => false,
    };
    if (!consistent) {
      throw ContradictoryBackendObservationException(
        confirmedState: record.state,
        observedState: observation is OperationSucceeded
            ? OperationState.succeeded
            : OperationState.rejected,
      );
    }
  }

  bool _compatibleMetadata(String? confirmed, String? observed) =>
      confirmed == null || observed == null || confirmed == observed;
}
