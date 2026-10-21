/// What a failed write can establish about its commit.
enum StoreCommitStatus {
  /// The adapter establishes that this invocation did not commit its change.
  notCommitted,

  /// The write may have committed, including a lost commit acknowledgement.
  unknown,
}

/// A storage failure with a safe description that omits record contents.
sealed class OperationStoreException implements Exception {
  const OperationStoreException();
}

/// A read or listing could not return a valid storage result.
final class OperationStoreReadException extends OperationStoreException {
  /// Creates a failure without retaining database errors or record data.
  const OperationStoreReadException();

  @override
  String toString() => 'OperationStoreReadException';
}

/// A write did not return a successful persistence acknowledgement.
///
/// Neither status authorizes business submission. Reading a committed record
/// later does not turn this failed invocation into a successful write.
final class OperationStoreWriteException extends OperationStoreException {
  /// Describes whether the adapter can rule out a commit.
  const OperationStoreWriteException({required this.commitStatus});

  /// The adapter's knowledge of this failed invocation's commit outcome.
  final StoreCommitStatus commitStatus;

  @override
  String toString() => 'OperationStoreWriteException(${commitStatus.name})';
}

/// The coordinator's conditional update did not match the current record.
///
/// The coordinator surfaces this conflict without refreshing the version or
/// replaying the transition. No replacement was committed by this invocation.
final class OperationStoreConflictException extends OperationStoreException {
  /// Identifies the attempted version without exposing the stored snapshot.
  const OperationStoreConflictException({required this.expectedVersion});

  /// The local version against which the coordinator attempted its update.
  final int expectedVersion;

  @override
  String toString() =>
      'OperationStoreConflictException(expectedVersion: $expectedVersion)';
}
