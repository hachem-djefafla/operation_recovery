import 'dart:async';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:operation_recovery/src/application/recovery_coordinator.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  final at = epoch.add(const Duration(seconds: 10));

  test(
    'same-ID actions are FIFO while a different ID proceeds independently',
    () async {
      final memory = MemoryOperationStore();
      await seedState(memory, OperationState.prepared);
      final probe = StoreProbe(memory);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      probe.beforeRead = (id) async {
        if (id == identity().id && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final uncertainty = coordinator.persistUncertainty(identity(), at: at);
      await entered.future;
      final pending = coordinator.applyObservation(
        OperationPending(identity: identity()),
        at: at.add(const Duration(seconds: 1)),
      );
      final paused = coordinator.pause(
        identity(),
        at: at.add(const Duration(seconds: 2)),
      );
      final queuedRead = coordinator.read(identity().id);
      final independent = await coordinator.prepare(
        identity(id: 'independent'),
        at: epoch,
      );
      expect(independent.state, OperationState.prepared);
      expect(probe.calls, ['read:op-123', 'create:independent']);
      release.complete();
      expect((await uncertainty).version, 1);
      expect((await pending).version, 2);
      final attention = await paused;
      expect(attention.version, 3);
      expect(attention.state, OperationState.needsAttention);
      expectSnapshot(await queuedRead, attention);
      expect(probe.calls.where((call) => call.endsWith(':op-123')), [
        'read:op-123',
        'cas:op-123',
        'read:op-123',
        'cas:op-123',
        'read:op-123',
        'cas:op-123',
        'read:op-123',
      ]);
      final resumed = await coordinator.resume(
        identity(),
        at: at.add(const Duration(seconds: 3)),
      );
      expect(resumed.version, 4);
    },
  );

  test(
    'concurrent duplicate preparation preserves the first creation',
    () async {
      final probe = StoreProbe(MemoryOperationStore());
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final records = await Future.wait([
        for (var index = 0; index < 12; index++)
          coordinator.prepare(
            identity(),
            at: epoch.add(Duration(seconds: index)),
          ),
      ]);
      for (final record in records) {
        expect(record.createdAt, epoch);
        expect(record.version, 0);
      }
      expect(probe.createCalls, 12);
      expect(probe.readCalls, 11);
      expect(probe.casCalls, 0);
    },
  );

  test(
    'a failed queued write releases later same-ID actions and reads',
    () async {
      final memory = MemoryOperationStore();
      await seedState(memory, OperationState.prepared);
      final probe = StoreProbe(memory);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      const failure = OperationStoreWriteException(
        commitStatus: StoreCommitStatus.notCommitted,
      );
      var failFirst = true;
      probe.beforeCas = (_, _) async {
        if (failFirst) {
          failFirst = false;
          entered.complete();
          await release.future;
          throw failure;
        }
      };
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final failed = expectLater(
        coordinator.persistUncertainty(identity(), at: at),
        throwsA(same(failure)),
      );
      await entered.future;
      final next = coordinator.persistUncertainty(
        identity(),
        at: at.add(const Duration(seconds: 1)),
      );
      final read = coordinator.read(identity().id);
      expect(await coordinator.read('independent-missing'), isNull);
      expect(probe.casCalls, 1);
      release.complete();
      await failed;
      final committed = await next;
      expect(committed.version, 1);
      expectSnapshot(await read, committed);
      expect(probe.casCalls, 2);
    },
  );

  test('a domain error does not poison queued work', () async {
    final memory = MemoryOperationStore();
    await seedState(memory, OperationState.prepared);
    final coordinator = RecoveryCoordinator(
      store: memory,
      scope: identity().scope,
    );
    final failure = expectLater(
      coordinator.pause(identity(), at: at),
      throwsA(isA<IllegalOperationTransitionException>()),
    );
    final next = coordinator.persistUncertainty(identity(), at: at);
    final read = coordinator.read(identity().id);
    await failure;
    expectSnapshot(await read, await next);
  });

  test('CAS protects stored state even when two coordinators race', () async {
    final memory = MemoryOperationStore();
    await seedState(memory, OperationState.prepared);
    final probe = StoreProbe(memory);
    final bothReady = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    var arrivals = 0;
    probe.beforeCas = (_, _) async {
      arrivals++;
      if (arrivals == 2) bothReady.complete();
      await release.future;
    };
    Future<Object> outcome(RecoveryCoordinator coordinator) async {
      try {
        return await coordinator.persistUncertainty(identity(), at: at);
      } on OperationStoreConflictException catch (error) {
        return error;
      }
    }

    final first = outcome(
      RecoveryCoordinator(store: probe, scope: identity().scope),
    );
    final second = outcome(
      RecoveryCoordinator(store: probe, scope: identity().scope),
    );
    await bothReady.future;
    release.complete();
    final results = await Future.wait([first, second]);
    expect(results.whereType<OperationRecord>(), hasLength(1));
    expect(results.whereType<OperationStoreConflictException>(), hasLength(1));
    expect(probe.readCalls, 2);
    expect(probe.casCalls, 2);
    expect(
      (await memory.read(id: identity().id, scope: identity().scope))!.version,
      1,
    );
    // This is a snapshot-CAS guarantee, not support for multiple submission owners.
  });

  test(
    'queued stale and contradictory evidence cannot overwrite terminal state',
    () async {
      final memory = MemoryOperationStore();
      await seedState(memory, OperationState.awaitingOutcome);
      final probe = StoreProbe(memory);
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final success = coordinator.applyObservation(
        OperationSucceeded(identity: identity()),
        at: at,
      );
      final stale = coordinator.applyObservation(
        OperationUnknown(identity: identity()),
        at: epoch,
      );
      final contradiction = expectLater(
        coordinator.applyObservation(
          OperationRejected(identity: identity()),
          at: epoch,
        ),
        throwsA(isA<ContradictoryBackendObservationException>()),
      );
      final read = coordinator.read(identity().id);
      final confirmed = await success;
      expectSnapshot(await stale, confirmed);
      await contradiction;
      expectSnapshot(await read, confirmed);
      expect(probe.casCalls, 1);
      expect(confirmed.version, 2);
    },
  );
}
