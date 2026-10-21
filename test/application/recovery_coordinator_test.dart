import 'package:operation_recovery/operation_recovery.dart';
import 'package:operation_recovery/src/application/recovery_coordinator.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/storage_fixtures.dart';

typedef _Action = ({
  String name,
  Future<OperationRecord> Function(RecoveryCoordinator) run,
  Map<OperationState, OperationState> allowed,
  Set<OperationState> contradictory,
});

void main() {
  final at = epoch.add(const Duration(seconds: 10));
  final actions = <_Action>[
    (
      name: 'persistUncertainty',
      run: (coordinator) => coordinator.persistUncertainty(identity(), at: at),
      allowed: {OperationState.prepared: OperationState.awaitingOutcome},
      contradictory: {},
    ),
    (
      name: 'pause',
      run: (coordinator) => coordinator.pause(identity(), at: at),
      allowed: {OperationState.awaitingOutcome: OperationState.needsAttention},
      contradictory: {},
    ),
    (
      name: 'resume',
      run: (coordinator) => coordinator.resume(identity(), at: at),
      allowed: {OperationState.needsAttention: OperationState.awaitingOutcome},
      contradictory: {},
    ),
    (
      name: 'success',
      run: (coordinator) => coordinator.applyObservation(
        OperationSucceeded(identity: identity(), backendReference: 'tx-987'),
        at: at,
      ),
      allowed: {
        OperationState.awaitingOutcome: OperationState.succeeded,
        OperationState.succeeded: OperationState.succeeded,
      },
      contradictory: {OperationState.rejected},
    ),
    (
      name: 'rejection',
      run: (coordinator) => coordinator.applyObservation(
        OperationRejected(identity: identity(), code: 'declined'),
        at: at,
      ),
      allowed: {
        OperationState.awaitingOutcome: OperationState.rejected,
        OperationState.rejected: OperationState.rejected,
      },
      contradictory: {OperationState.succeeded},
    ),
    for (final entry in <String, BackendObservation>{
      'pending': OperationPending(identity: identity()),
      'unknown': OperationUnknown(identity: identity()),
      for (final reason in LookupFailureReason.values)
        reason.name: LookupUnavailable(identity: identity(), reason: reason),
    }.entries)
      (
        name: entry.key,
        run: (coordinator) => coordinator.applyObservation(entry.value, at: at),
        allowed: {
          OperationState.awaitingOutcome: OperationState.awaitingOutcome,
          OperationState.succeeded: OperationState.succeeded,
          OperationState.rejected: OperationState.rejected,
        },
        contradictory: {},
      ),
  ];

  for (final state in OperationState.values) {
    for (final action in actions) {
      test(
        'coordinator ${state.name} + ${action.name} obeys domain rules',
        () async {
          final memory = MemoryOperationStore();
          final original = await seedState(memory, state);
          final probe = StoreProbe(memory);
          final coordinator = RecoveryCoordinator(
            store: probe,
            scope: identity().scope,
          );
          final expected = action.allowed[state];
          if (expected != null) {
            final after = await action.run(coordinator);
            expect(after.state, expected);
            expect(
              after.version,
              original.version + (state.isTerminal ? 0 : 1),
            );
            expect(probe.casCalls, state.isTerminal ? 0 : 1);
            expectSnapshot(
              await memory.read(id: identity().id, scope: identity().scope),
              after,
            );
          } else {
            await expectLater(
              action.run(coordinator),
              throwsA(
                action.contradictory.contains(state)
                    ? isA<ContradictoryBackendObservationException>()
                    : isA<IllegalOperationTransitionException>(),
              ),
            );
            expect(probe.casCalls, 0);
            expectSnapshot(
              await memory.read(id: identity().id, scope: identity().scope),
              original,
            );
          }
          expect(probe.readCalls, 1);
        },
      );
    }
  }

  for (final blank in ['', ' ', '\t\n']) {
    test('coordinator rejects blank scope ${blank.codeUnits}', () {
      expect(
        () => RecoveryCoordinator(store: MemoryOperationStore(), scope: blank),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }

  test(
    'prepare persists once and duplicate preparation preserves latest state',
    () async {
      final probe = StoreProbe(MemoryOperationStore());
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final prepared = await coordinator.prepare(identity(), at: epoch);
      expect(prepared.state, OperationState.prepared);
      expect(probe.readCalls, 0);
      final awaiting = await coordinator.persistUncertainty(identity(), at: at);
      final duplicate = await coordinator.prepare(identity(), at: at);
      expectSnapshot(duplicate, awaiting);
      expect(probe.createCalls, 2);
      expect(probe.casCalls, 1);
    },
  );

  for (final entry in <String, OperationIdentity>{
    'type': identity(type: 'different'),
    'key': identity(idempotencyKey: 'different'),
    'fingerprint': identity(requestFingerprint: 'different'),
  }.entries) {
    test(
      'conflicting ${entry.key} cannot prepare or mutate an existing ID',
      () async {
        final memory = MemoryOperationStore();
        final original = await seedState(memory, OperationState.prepared);
        final probe = StoreProbe(memory);
        final coordinator = RecoveryCoordinator(
          store: probe,
          scope: identity().scope,
        );
        await expectLater(
          coordinator.prepare(entry.value, at: at),
          throwsA(isA<OperationIdentityConflictException>()),
        );
        await expectLater(
          coordinator.persistUncertainty(entry.value, at: at),
          throwsA(isA<OperationIdentityConflictException>()),
        );
        expect(probe.casCalls, 0);
        expectSnapshot(
          await memory.read(id: identity().id, scope: identity().scope),
          original,
        );
      },
    );
  }

  for (final name in ['uncertainty', 'observation', 'pause', 'resume']) {
    test('$name on an unavailable scoped ID fails without a write', () async {
      final probe = StoreProbe(MemoryOperationStore());
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final result = switch (name) {
        'uncertainty' => coordinator.persistUncertainty(identity(), at: at),
        'observation' => coordinator.applyObservation(
          OperationUnknown(identity: identity()),
          at: at,
        ),
        'pause' => coordinator.pause(identity(), at: at),
        _ => coordinator.resume(identity(), at: at),
      };
      await expectLater(result, throwsA(isA<OperationNotFoundException>()));
      expect(probe.casCalls, 0);
    });
  }

  for (final observation in [
    OperationPending(identity: identity()),
    OperationUnknown(identity: identity()),
    for (final reason in LookupFailureReason.values)
      LookupUnavailable(identity: identity(), reason: reason),
  ]) {
    test(
      'repeated ${observation.runtimeType} '
      '${observation is LookupUnavailable ? observation.reason.name : ''} advances revisions',
      () async {
        final memory = MemoryOperationStore();
        await seedState(memory, OperationState.awaitingOutcome);
        final coordinator = RecoveryCoordinator(
          store: memory,
          scope: identity().scope,
        );
        final first = await coordinator.applyObservation(observation, at: at);
        final second = await coordinator.applyObservation(
          observation,
          at: at.add(const Duration(seconds: 1)),
        );
        expect(second.state, OperationState.awaitingOutcome);
        expect(second.version, first.version + 1);
        expect(second.updatedAt, at.add(const Duration(seconds: 1)));
        // Same-instant observations also count; versions are not attempt counters.
        final third = await coordinator.applyObservation(
          observation,
          at: second.updatedAt,
        );
        expect(third.version, second.version + 1);
      },
    );
  }

  test(
    'clock regression fails in the state machine before storage CAS',
    () async {
      final memory = MemoryOperationStore();
      final original = await seedState(memory, OperationState.awaitingOutcome);
      final probe = StoreProbe(memory);
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      await expectLater(
        coordinator.applyObservation(
          OperationUnknown(identity: identity()),
          at: epoch,
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
      expect(probe.casCalls, 0);
      expectSnapshot(await coordinator.read(identity().id), original);
    },
  );

  test(
    'read and list failures propagate without poisoning future work',
    () async {
      final memory = MemoryOperationStore();
      final original = await seedState(memory, OperationState.prepared);
      final probe = StoreProbe(memory);
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      const failure = OperationStoreReadException();
      probe.beforeRead = (_) async => throw failure;
      await expectLater(
        coordinator.read(identity().id),
        throwsA(same(failure)),
      );
      probe.beforeRead = null;
      expectSnapshot(await coordinator.read(identity().id), original);
      probe.beforeList = () async => throw failure;
      await expectLater(coordinator.listUnresolved(), throwsA(same(failure)));
      probe.beforeList = null;
      expect(await coordinator.listUnresolved(), hasLength(1));
    },
  );
}
