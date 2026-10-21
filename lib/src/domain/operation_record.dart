import 'backend_observation.dart';
import 'operation_exception.dart';
import 'operation_identity.dart';
import 'operation_state.dart';
import 'recovery_metadata.dart';

/// An immutable snapshot of local knowledge about one operation.
///
/// Constructing or restoring a snapshot does not establish that it is persisted.
/// The latest observation is recovery metadata, not a durable audit history.
final class OperationRecord {
  const OperationRecord._({
    required this.identity,
    required this.state,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.lastObservation,
    required this.recovery,
  });

  /// Creates a version-zero prepared snapshot at the supplied time.
  ///
  /// [at] is normalized to UTC. No clock, storage, or external action is invoked.
  factory OperationRecord.prepared({
    required OperationIdentity identity,
    required DateTime at,
  }) {
    final utc = at.toUtc();
    return OperationRecord._(
      identity: identity,
      state: OperationState.prepared,
      version: 0,
      createdAt: utc,
      updatedAt: utc,
      lastObservation: null,
      recovery: const RecoveryMetadata.empty(),
    );
  }

  /// Validates and restores a snapshot, normalizing times to UTC.
  ///
  /// This validates structural consistency, not the provenance of a backend
  /// assertion or the durability of storage. Adapters must also validate their
  /// serialization schema. Invalid records are never treated as safe to submit.
  factory OperationRecord.restore({
    required OperationIdentity identity,
    required OperationState state,
    required int version,
    required DateTime createdAt,
    required DateTime updatedAt,
    BackendObservation? lastObservation,
    RecoveryMetadata recovery = const RecoveryMetadata.empty(),
  }) {
    final createdUtc = createdAt.toUtc();
    final updatedUtc = updatedAt.toUtc();
    if (version < 0) {
      throw const InvalidOperationRecordException(
        'version',
        'must be nonnegative',
      );
    }
    if (updatedUtc.isBefore(createdUtc)) {
      throw const InvalidOperationRecordException(
        'updatedAt',
        'must not precede createdAt',
      );
    }
    if (lastObservation != null && lastObservation.identity != identity) {
      throw const InvalidOperationRecordException(
        'lastObservation.identity',
        'must match the record identity',
      );
    }

    final minimumVersion = switch (state) {
      OperationState.prepared => 0,
      OperationState.awaitingOutcome => lastObservation == null ? 1 : 2,
      OperationState.succeeded || OperationState.rejected => 2,
      OperationState.needsAttention => lastObservation == null ? 2 : 3,
    };
    if (version < minimumVersion ||
        (state == OperationState.prepared && version != 0)) {
      throw const InvalidOperationRecordException(
        'version',
        'is inconsistent with state and observation',
      );
    }
    if (state == OperationState.prepared && createdUtc != updatedUtc) {
      throw const InvalidOperationRecordException(
        'updatedAt',
        'a prepared record must retain its creation time',
      );
    }

    final observationIsValid = switch (state) {
      OperationState.prepared => lastObservation == null,
      OperationState.succeeded => lastObservation is OperationSucceeded,
      OperationState.rejected => lastObservation is OperationRejected,
      OperationState.awaitingOutcome || OperationState.needsAttention =>
        lastObservation == null || !lastObservation.isAuthoritative,
    };
    if (!observationIsValid) {
      throw const InvalidOperationRecordException(
        'lastObservation',
        'is inconsistent with the durable state',
      );
    }

    if ((state == OperationState.prepared &&
            (recovery.totalAttempts != 0 || recovery.nextCheckAt != null)) ||
        ((state.isTerminal || state == OperationState.needsAttention) &&
            recovery.nextCheckAt != null) ||
        (recovery.lastAttemptAt != null &&
            (recovery.lastAttemptAt!.isBefore(createdUtc) ||
                recovery.lastAttemptAt!.isAfter(updatedUtc))) ||
        (state != OperationState.prepared &&
            recovery.totalAttempts >= version)) {
      throw const InvalidOperationRecordException(
        'recovery',
        'is inconsistent with state, version, or timestamps',
      );
    }

    return OperationRecord._(
      identity: identity,
      state: state,
      version: version,
      createdAt: createdUtc,
      updatedAt: updatedUtc,
      lastObservation: lastObservation,
      recovery: recovery,
    );
  }

  /// The immutable identity; it is never replaced by transition logic.
  final OperationIdentity identity;

  /// The latest known durable business state represented by this snapshot.
  final OperationState state;

  /// The local optimistic-concurrency version, not a backend status revision.
  final int version;

  /// The UTC time at which the prepared snapshot was created.
  final DateTime createdAt;

  /// The UTC time of the latest accepted record change.
  final DateTime updatedAt;

  /// The most recent semantic evidence, retained through pause and resume.
  final BackendObservation? lastObservation;

  /// Persisted lookup reservations and due time, not a durable activity log.
  final RecoveryMetadata recovery;

  @override
  String toString() =>
      'OperationRecord(state: ${state.name}, version: $version)';
}
