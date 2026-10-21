import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Future<OperationRecord> seedState(
  OperationStore store,
  OperationState state, {
  OperationIdentity? operationIdentity,
}) async {
  final value = operationIdentity ?? identity();
  final prepared = OperationRecord.prepared(identity: value, at: epoch);
  expect(await store.createIfAbsent(prepared), isTrue);
  if (state == OperationState.prepared) return prepared;
  final awaiting = machine.beginSubmission(
    prepared,
    identity: value,
    at: epoch.add(const Duration(seconds: 1)),
  );
  expect(await store.compareAndSwap(awaiting, expectedVersion: 0), isTrue);
  if (state == OperationState.awaitingOutcome) return awaiting;
  final at = epoch.add(const Duration(seconds: 2));
  final next = switch (state) {
    OperationState.succeeded => machine.applyObservation(
      awaiting,
      OperationSucceeded(identity: value, backendReference: 'tx-987'),
      at: at,
    ),
    OperationState.rejected => machine.applyObservation(
      awaiting,
      OperationRejected(identity: value, code: 'declined'),
      at: at,
    ),
    OperationState.needsAttention => machine.pause(awaiting, at: at),
    _ => throw StateError('Unexpected fixture state'),
  };
  expect(await store.compareAndSwap(next, expectedVersion: 1), isTrue);
  return next;
}

void expectSnapshot(OperationRecord? actual, OperationRecord expected) {
  expect(actual, isNotNull);
  final record = actual!;
  expect(record.identity, expected.identity);
  expect(record.state, expected.state);
  expect(record.version, expected.version);
  expect(record.createdAt, expected.createdAt);
  expect(record.updatedAt, expected.updatedAt);
  expect(record.recovery.cycleAttempts, expected.recovery.cycleAttempts);
  expect(record.recovery.totalAttempts, expected.recovery.totalAttempts);
  expect(record.recovery.lastAttemptAt, expected.recovery.lastAttemptAt);
  expect(record.recovery.nextCheckAt, expected.recovery.nextCheckAt);
  final observed = record.lastObservation;
  final expectedObservation = expected.lastObservation;
  expect(observed?.runtimeType, expectedObservation?.runtimeType);
  expect(observed?.identity, expectedObservation?.identity);
  switch (expectedObservation) {
    case OperationSucceeded():
      expect(
        (observed! as OperationSucceeded).backendReference,
        expectedObservation.backendReference,
      );
    case OperationRejected():
      expect((observed! as OperationRejected).code, expectedObservation.code);
    case LookupUnavailable():
      expect(
        (observed! as LookupUnavailable).reason,
        expectedObservation.reason,
      );
    case OperationPending() || OperationUnknown() || null:
      break;
  }
}

/// Test-only instrumentation around a real adapter; production has no hooks.
final class StoreProbe implements OperationStore {
  StoreProbe(this.delegate);

  final OperationStore delegate;
  final List<String> calls = [];
  Future<void> Function(String id)? beforeRead;
  Future<void> Function(OperationRecord record)? beforeCreate;
  Future<void> Function(OperationRecord record)? afterCreate;
  Future<void> Function(OperationRecord record, int expectedVersion)? beforeCas;
  Future<void> Function(OperationRecord record, int expectedVersion)? afterCas;
  Future<void> Function()? beforeList;

  int get readCalls => calls.where((call) => call.startsWith('read:')).length;
  int get createCalls =>
      calls.where((call) => call.startsWith('create:')).length;
  int get casCalls => calls.where((call) => call.startsWith('cas:')).length;

  @override
  Future<OperationRecord?> read({
    required String id,
    required String scope,
  }) async {
    calls.add('read:$id');
    await beforeRead?.call(id);
    return delegate.read(id: id, scope: scope);
  }

  @override
  Future<bool> createIfAbsent(OperationRecord record) async {
    calls.add('create:${record.identity.id}');
    await beforeCreate?.call(record);
    final created = await delegate.createIfAbsent(record);
    if (created) await afterCreate?.call(record);
    return created;
  }

  @override
  Future<bool> compareAndSwap(
    OperationRecord replacement, {
    required int expectedVersion,
  }) async {
    calls.add('cas:${replacement.identity.id}');
    await beforeCas?.call(replacement, expectedVersion);
    final committed = await delegate.compareAndSwap(
      replacement,
      expectedVersion: expectedVersion,
    );
    if (committed) await afterCas?.call(replacement, expectedVersion);
    return committed;
  }

  @override
  Future<List<OperationRecord>> listUnresolved({required String scope}) async {
    calls.add('list');
    await beforeList?.call();
    return delegate.listUnresolved(scope: scope);
  }
}
