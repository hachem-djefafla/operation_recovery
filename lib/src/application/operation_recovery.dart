import '../domain/operation_identity.dart';
import '../domain/operation_record.dart';
import '../infrastructure/system_clock.dart';
import '../ports/clock.dart';
import '../ports/operation_store.dart';
import 'operation_event.dart';
import 'reconciliation_result.dart';
import 'recovery_coordinator.dart';
import 'recovery_policy.dart';

/// Scoped facade with explicit submission and lookup-only recovery.
///
/// Use one active instance per scope. Handlers own deadlines, authorization,
/// backend correlation, and disabled write retries. Memory storage is not durable.
final class OperationRecovery {
  /// Freezes handler registrations and explicit policy for one account scope.
  OperationRecovery({
    required String scope,
    required OperationStore store,
    required Iterable<OperationRegistration<Object?>> handlers,
    required RecoveryPolicy policy,
    Clock clock = const SystemClock(),
  }) : _coordinator = RecoveryCoordinator(
         scope: scope,
         store: store,
         handlers: handlers,
         policy: policy,
         clock: clock,
       );

  final RecoveryCoordinator _coordinator;

  /// Live asynchronous acknowledged snapshots, without replay or raw errors.
  Stream<OperationEvent> get events => _coordinator.events;

  /// Submits a prepared operation after this invocation confirms uncertainty.
  /// Existing awaiting/attention/terminal records return without resubmission.
  Future<OperationRecord> start<TRequest>(
    OperationRegistration<TRequest> registration, {
    required OperationIdentity identity,
    required TRequest request,
  }) => _coordinator.start(registration, identity: identity, request: request);

  /// Reads a scoped snapshot; foreign and missing IDs both return null.
  Future<OperationRecord?> get(String id) => _coordinator.read(id);

  /// Looks up one due operation without ever submitting a business write.
  Future<OperationRecord> reconcile(OperationIdentity identity) =>
      _coordinator.reconcile(identity);

  /// Processes initially due records with independent per-operation results.
  /// [concurrency] bounds this batch only, not other concurrent facade calls.
  Future<List<ReconciliationResult>> reconcilePending({int concurrency = 4}) =>
      _coordinator.reconcilePending(concurrency: concurrency);

  /// Resets an attention record's cycle budget without dispatching a handler.
  Future<OperationRecord> resume(OperationIdentity identity) =>
      _coordinator.resume(identity);

  /// Rejects queued/new work and drains active work without cancelling effects.
  /// Idempotent; does not wait for paused listeners or close shared resources.
  Future<void> close() => _coordinator.close();
}
