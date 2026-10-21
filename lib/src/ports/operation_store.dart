import '../domain/operation_record.dart';

/// Atomic storage for immutable operation snapshots.
///
/// IDs are unique across all scopes in one store. Reads conceal foreign-scope
/// records; conflicting writes fail without changing them. Adapters enforce
/// identity, version, timestamp, and terminal immutability invariants. Domain
/// transition decisions belong to the state machine, not the adapter.
///
/// A successful write acknowledges the adapter's documented persistence
/// guarantee. Only a genuinely durable adapter can support crash recovery.
/// Operational write failures must distinguish definitely uncommitted changes
/// from unknown commit outcomes; an exception never acknowledges success.
abstract interface class OperationStore {
  /// Returns the snapshot in [scope], or null for both absent and foreign IDs.
  ///
  /// Foreign records must not produce distinguishing metadata or an
  /// existence-specific error. Returned snapshots are immutable.
  Future<OperationRecord?> read({required String id, required String scope});

  /// Atomically inserts a prepared, version-zero [record] if its ID is absent.
  ///
  /// Returns false for an existing matching identity, regardless of its state.
  /// A conflicting identity throws without modifying the existing snapshot.
  /// Invalid creation snapshots are rejected before attempting a write.
  Future<bool> createIfAbsent(OperationRecord record);

  /// Atomically replaces the current snapshot only at [expectedVersion].
  ///
  /// [expectedVersion] must be nonnegative and [replacement] must have version
  /// exactly one greater. Returns false for a missing ID or version mismatch.
  /// Identity conflicts throw, even when the expected version is stale.
  ///
  /// After matching the version, reject changes to creation time, timestamp
  /// regression, or any rewrite of a terminal record. Perform all checks and
  /// the replacement as one atomic operation. False means no write occurred.
  Future<bool> compareAndSwap(
    OperationRecord replacement, {
    required int expectedVersion,
  });

  /// Returns an unmodifiable snapshot of unresolved records in [scope] only.
  ///
  /// Includes prepared, awaiting-outcome, and attention records. Ordering is
  /// unspecified. This query does not lock the coordinator's per-ID queues.
  Future<List<OperationRecord>> listUnresolved({required String scope});
}
