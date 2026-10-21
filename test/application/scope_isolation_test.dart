import 'package:operation_recovery/operation_recovery.dart';
import 'package:operation_recovery/src/application/recovery_coordinator.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  final foreign = identity(scope: 'foreign-account');
  final at = epoch.add(const Duration(seconds: 10));

  for (final action in [
    'prepare',
    'uncertainty',
    'observation',
    'pause',
    'resume',
  ]) {
    test(
      '$action rejects incoming foreign scope before any store access',
      () async {
        final probe = StoreProbe(MemoryOperationStore());
        final coordinator = RecoveryCoordinator(
          store: probe,
          scope: identity().scope,
        );
        final result = switch (action) {
          'prepare' => coordinator.prepare(foreign, at: at),
          'uncertainty' => coordinator.persistUncertainty(foreign, at: at),
          'observation' => coordinator.applyObservation(
            OperationSucceeded(identity: foreign),
            at: at,
          ),
          'pause' => coordinator.pause(foreign, at: at),
          _ => coordinator.resume(foreign, at: at),
        };
        await expectLater(
          result,
          throwsA(isA<OperationIdentityConflictException>()),
        );
        expect(probe.calls, isEmpty);
      },
    );
  }

  test(
    'foreign and missing scoped reads return the same null result',
    () async {
      final memory = MemoryOperationStore();
      final original = await seedState(
        memory,
        OperationState.succeeded,
        operationIdentity: foreign,
      );
      final coordinator = RecoveryCoordinator(
        store: memory,
        scope: identity().scope,
      );
      expect(await coordinator.read('missing'), isNull);
      expect(await coordinator.read(foreign.id), isNull);
      expectSnapshot(
        await memory.read(id: foreign.id, scope: foreign.scope),
        original,
      );
    },
  );

  test(
    'unavailable action does not distinguish a foreign ID from a missing ID',
    () async {
      final memory = MemoryOperationStore();
      final original = await seedState(
        memory,
        OperationState.prepared,
        operationIdentity: foreign,
      );
      final coordinator = RecoveryCoordinator(
        store: memory,
        scope: identity().scope,
      );
      for (final candidate in [identity(), identity(id: 'missing')]) {
        await expectLater(
          coordinator.persistUncertainty(candidate, at: at),
          throwsA(isA<OperationNotFoundException>()),
        );
      }
      expectSnapshot(
        await memory.read(id: foreign.id, scope: foreign.scope),
        original,
      );
    },
  );

  test(
    'conflicting prepare across scopes cannot replace the owner record',
    () async {
      final memory = MemoryOperationStore();
      final original = await seedState(
        memory,
        OperationState.awaitingOutcome,
        operationIdentity: foreign,
      );
      final coordinator = RecoveryCoordinator(
        store: memory,
        scope: identity().scope,
      );
      await expectLater(
        coordinator.prepare(identity(), at: at),
        throwsA(isA<OperationIdentityConflictException>()),
      );
      expect(await coordinator.read(identity().id), isNull);
      expectSnapshot(
        await memory.read(id: foreign.id, scope: foreign.scope),
        original,
      );
    },
  );

  test('coordinator listing is scoped, unresolved, and unmodifiable', () async {
    final memory = MemoryOperationStore();
    final own = await seedState(memory, OperationState.needsAttention);
    await seedState(
      memory,
      OperationState.prepared,
      operationIdentity: identity(id: 'foreign', scope: foreign.scope),
    );
    await seedState(
      memory,
      OperationState.succeeded,
      operationIdentity: identity(id: 'completed'),
    );
    final coordinator = RecoveryCoordinator(
      store: memory,
      scope: identity().scope,
    );
    final records = await coordinator.listUnresolved();
    expect(records, hasLength(1));
    expectSnapshot(records.single, own);
    expect(() => records.clear(), throwsUnsupportedError);
  });

  test(
    'coordinator scope fence also conceals a misrouted adapter result',
    () async {
      final foreignRecord = OperationRecord.prepared(
        identity: foreign,
        at: epoch,
      );
      final coordinator = RecoveryCoordinator(
        store: _ReturningStore([foreignRecord]),
        scope: identity().scope,
      );
      expect(await coordinator.read(foreign.id), isNull);
      expect(await coordinator.read('missing'), isNull);
      expect(await coordinator.listUnresolved(), isEmpty);
    },
  );

  test('coordinator rejects an adapter result with the wrong ID', () async {
    final coordinator = RecoveryCoordinator(
      store: _ReturningStore([recordIn(OperationState.prepared)]),
      scope: identity().scope,
    );
    await expectLater(
      coordinator.read('different-id'),
      throwsA(isA<OperationStoreReadException>()),
    );
  });
}

/// Deliberately nonconforming read adapter for checking the coordinator's fence.
final class _ReturningStore implements OperationStore {
  _ReturningStore(this.records);

  final List<OperationRecord> records;

  @override
  Future<OperationRecord?> read({
    required String id,
    required String scope,
  }) async => records.first;

  @override
  Future<List<OperationRecord>> listUnresolved({required String scope}) async =>
      records;

  @override
  Future<bool> createIfAbsent(OperationRecord record) =>
      throw UnimplementedError();

  @override
  Future<bool> compareAndSwap(
    OperationRecord replacement, {
    required int expectedVersion,
  }) => throw UnimplementedError();
}
