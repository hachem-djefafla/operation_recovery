import 'operation_exception.dart';

/// Persisted lookup reservations, separate from the record concurrency version.
final class RecoveryMetadata {
  /// Creates the default for prepared or previously stored legacy snapshots.
  const RecoveryMetadata.empty()
    : cycleAttempts = 0,
      totalAttempts = 0,
      lastAttemptAt = null,
      nextCheckAt = null;

  const RecoveryMetadata._({
    required this.cycleAttempts,
    required this.totalAttempts,
    required this.lastAttemptAt,
    required this.nextCheckAt,
  });

  /// Restores validated counters and UTC timestamps.
  factory RecoveryMetadata.restore({
    required int cycleAttempts,
    required int totalAttempts,
    DateTime? lastAttemptAt,
    DateTime? nextCheckAt,
  }) {
    if (cycleAttempts < 0 || totalAttempts < cycleAttempts) {
      throw const InvalidOperationRecordException(
        'recovery.attempts',
        'must be nonnegative with cycle attempts no greater than total attempts',
      );
    }
    if ((totalAttempts == 0) != (lastAttemptAt == null)) {
      throw const InvalidOperationRecordException(
        'recovery.lastAttemptAt',
        'must be present exactly when a reservation has been recorded',
      );
    }
    return RecoveryMetadata._(
      cycleAttempts: cycleAttempts,
      totalAttempts: totalAttempts,
      lastAttemptAt: lastAttemptAt?.toUtc(),
      nextCheckAt: nextCheckAt?.toUtc(),
    );
  }

  /// Reserved lookups since creation or the latest explicit resume.
  final int cycleAttempts;

  /// Reserved lookups across all recovery cycles, including abandoned attempts.
  final int totalAttempts;

  /// The most recent lookup reservation time, retained across resume.
  final DateTime? lastAttemptAt;

  /// Earliest next lookup; null means immediately due while awaiting outcome.
  final DateTime? nextCheckAt;
}
