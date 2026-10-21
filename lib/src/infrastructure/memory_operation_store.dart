import '../domain/operation_exception.dart';
import '../domain/operation_record.dart';
import '../domain/operation_state.dart';
import '../ports/operation_store.dart';

/// Non-durable reference adapter with atomic operations in one memory context.
///
/// Atomicity applies to calls sharing this instance in one isolate. Critical
/// sections contain no awaits. This adapter does not coordinate or share state
/// across isolates, processes, different instances, or restarts. A successful
/// write acknowledges a memory change only, never a durable commit.
final class MemoryOperationStore implements OperationStore {
  /// Creates an empty, independent in-memory store.
  MemoryOperationStore();

  final Map<String, OperationRecord> _records = {};

  @override
  Future<OperationRecord?> read({
    required String id,
    required String scope,
  }) async {
    final record = _records[id];
    return record?.identity.scope == scope ? record : null;
  }

  @override
  Future<bool> createIfAbsent(OperationRecord record) async {
    if (record.state != OperationState.prepared || record.version != 0) {
      throw const InvalidOperationRecordException(
        'state',
        'creation requires a prepared version-zero snapshot',
      );
    }
    final existing = _records[record.identity.id];
    if (existing != null) {
      existing.identity.requireMatch(record.identity);
      return false;
    }
    _records[record.identity.id] = record;
    return true;
  }

  @override
  Future<bool> compareAndSwap(
    OperationRecord replacement, {
    required int expectedVersion,
  }) async {
    if (expectedVersion < 0 || replacement.version != expectedVersion + 1) {
      throw const InvalidOperationRecordException(
        'version',
        'replacement must be exactly one greater than a nonnegative expected version',
      );
    }
    final existing = _records[replacement.identity.id];
    if (existing == null) return false;
    existing.identity.requireMatch(replacement.identity);
    if (existing.version != expectedVersion) return false;
    if (existing.state.isTerminal) {
      throw IllegalOperationTransitionException(
        state: existing.state,
        action: 'compareAndSwap',
      );
    }
    if (replacement.createdAt != existing.createdAt) {
      throw const InvalidOperationRecordException(
        'createdAt',
        'must match the stored creation time',
      );
    }
    if (replacement.updatedAt.isBefore(existing.updatedAt)) {
      throw const InvalidOperationRecordException(
        'updatedAt',
        'must not precede the stored update time',
      );
    }
    _records[replacement.identity.id] = replacement;
    return true;
  }

  @override
  Future<List<OperationRecord>> listUnresolved({required String scope}) async =>
      List<OperationRecord>.unmodifiable(
        _records.values.where(
          (record) =>
              record.identity.scope == scope && record.state.isUnresolved,
        ),
      );
}
