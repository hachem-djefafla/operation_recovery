import 'package:operation_recovery/operation_recovery.dart';
import 'package:operation_recovery/src/domain/state_machine.dart';

final epoch = DateTime.utc(2026, 10, 20, 10);
const machine = OperationStateMachine();

OperationIdentity identity({
  String id = 'op-123',
  String scope = 'account-456',
  String type = 'transfer',
  String idempotencyKey = 'key-123',
  String requestFingerprint = 'sha256:original',
}) => OperationIdentity(
  id: id,
  scope: scope,
  type: type,
  idempotencyKey: idempotencyKey,
  requestFingerprint: requestFingerprint,
);

OperationRecord recordIn(OperationState state) {
  final operationIdentity = identity();
  final prepared = OperationRecord.prepared(
    identity: operationIdentity,
    at: epoch,
  );
  if (state == OperationState.prepared) return prepared;
  final awaiting = machine.beginSubmission(
    prepared,
    identity: operationIdentity,
    at: epoch.add(const Duration(seconds: 1)),
  );
  final at = epoch.add(const Duration(seconds: 2));
  return switch (state) {
    OperationState.prepared => prepared,
    OperationState.awaitingOutcome => awaiting,
    OperationState.succeeded => machine.applyObservation(
      awaiting,
      OperationSucceeded(
        identity: operationIdentity,
        backendReference: 'tx-987',
      ),
      at: at,
    ),
    OperationState.rejected => machine.applyObservation(
      awaiting,
      OperationRejected(identity: operationIdentity, code: 'declined'),
      at: at,
    ),
    OperationState.needsAttention => machine.pause(awaiting, at: at),
  };
}

OperationRecord restoreRecord(OperationRecord record) =>
    OperationRecord.restore(
      identity: record.identity,
      state: record.state,
      version: record.version,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      lastObservation: record.lastObservation,
      recovery: record.recovery,
    );
