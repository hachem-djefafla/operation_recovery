import 'package:operation_recovery/operation_recovery.dart';
import 'package:operation_recovery/src/application/recovery_coordinator.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  final at = epoch.add(const Duration(seconds: 10));
  final faults = [
    (
      name: 'definitely not committed',
      status: StoreCommitStatus.notCommitted,
      committed: false,
    ),
    (
      name: 'unknown and not committed',
      status: StoreCommitStatus.unknown,
      committed: false,
    ),
    (
      name: 'committed with acknowledgement lost',
      status: StoreCommitStatus.unknown,
      committed: true,
    ),
  ];

  for (final fault in faults) {
    test('creation failure: ${fault.name}', () async {
      final memory = MemoryOperationStore();
      final probe = StoreProbe(memory);
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final failure = OperationStoreWriteException(commitStatus: fault.status);
      if (fault.committed) {
        probe.afterCreate = (_) async => throw failure;
      } else {
        probe.beforeCreate = (_) async => throw failure;
      }
      var acknowledged = false;
      await expectLater(
        coordinator.prepare(identity(), at: epoch).then((record) {
          acknowledged = true;
          return record;
        }),
        throwsA(same(failure)),
      );
      expect(acknowledged, isFalse);
      expect(probe.createCalls, 1);
      expect(
        probe.readCalls,
        0,
        reason: 'No reread may turn a failed create into success',
      );
      expect(probe.casCalls, 0);
      final later = await coordinator.read(identity().id);
      if (fault.committed) {
        expectSnapshot(later, recordIn(OperationState.prepared));
      } else {
        expect(later, isNull);
      }
      expect(acknowledged, isFalse);
      expect(probe.createCalls, 1);
    });

    test('uncertainty failure: ${fault.name}', () async {
      final memory = MemoryOperationStore();
      final original = await seedState(memory, OperationState.prepared);
      final probe = StoreProbe(memory);
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final failure = OperationStoreWriteException(commitStatus: fault.status);
      if (fault.committed) {
        probe.afterCas = (_, _) async => throw failure;
      } else {
        probe.beforeCas = (_, _) async => throw failure;
      }
      var successfulCommitContinuations = 0;
      await expectLater(
        coordinator.persistUncertainty(identity(), at: at).then((record) {
          successfulCommitContinuations++;
          return record;
        }),
        throwsA(same(failure)),
      );
      expect(successfulCommitContinuations, 0);
      expect(probe.casCalls, 1);
      expect(
        probe.readCalls,
        1,
        reason: 'Only the original pre-update read is allowed',
      );
      final later = await coordinator.read(identity().id);
      if (fault.committed) {
        expectSnapshot(
          later,
          machine.beginSubmission(original, identity: identity(), at: at),
        );
        await expectLater(
          coordinator.persistUncertainty(identity(), at: at),
          throwsA(isA<IllegalOperationTransitionException>()),
        );
      } else {
        expectSnapshot(later, original);
      }
      expect(successfulCommitContinuations, 0);
      expect(
        probe.casCalls,
        1,
        reason: 'No retry or reread grants a new acknowledged write',
      );
    });

    test('terminal result failure: ${fault.name}', () async {
      final memory = MemoryOperationStore();
      final original = await seedState(memory, OperationState.awaitingOutcome);
      final probe = StoreProbe(memory);
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      final failure = OperationStoreWriteException(commitStatus: fault.status);
      if (fault.committed) {
        probe.afterCas = (_, _) async => throw failure;
      } else {
        probe.beforeCas = (_, _) async => throw failure;
      }
      final success = OperationSucceeded(
        identity: identity(),
        backendReference: 'tx-final',
      );
      var acknowledged = false;
      await expectLater(
        coordinator.applyObservation(success, at: at).then((record) {
          acknowledged = true;
          return record;
        }),
        throwsA(same(failure)),
      );
      expect(acknowledged, isFalse);
      expect(probe.readCalls, 1);
      expect(probe.casCalls, 1);
      final later = await coordinator.read(identity().id);
      expectSnapshot(
        later,
        fault.committed
            ? machine.applyObservation(original, success, at: at)
            : original,
      );
      if (fault.committed) {
        await expectLater(
          coordinator.applyObservation(
            OperationRejected(identity: identity()),
            at: at,
          ),
          throwsA(isA<ContradictoryBackendObservationException>()),
        );
        expect(probe.casCalls, 1);
      }
      expect(acknowledged, isFalse);
    });
  }

  for (final action in ['uncertainty', 'pending', 'success']) {
    test(
      'external commit makes $action CAS fail without replay or overwrite',
      () async {
        final memory = MemoryOperationStore();
        final original = await seedState(
          memory,
          action == 'uncertainty'
              ? OperationState.prepared
              : OperationState.awaitingOutcome,
        );
        final external = action == 'uncertainty'
            ? machine.beginSubmission(original, identity: identity(), at: at)
            : machine.applyObservation(
                original,
                OperationRejected(identity: identity()),
                at: at,
              );
        final probe = StoreProbe(memory);
        probe.beforeCas = (_, expected) async {
          expect(
            await memory.compareAndSwap(external, expectedVersion: expected),
            isTrue,
          );
        };
        final coordinator = RecoveryCoordinator(
          store: probe,
          scope: identity().scope,
        );
        final result = action == 'uncertainty'
            ? coordinator.persistUncertainty(identity(), at: at)
            : coordinator.applyObservation(
                action == 'pending'
                    ? OperationPending(identity: identity())
                    : OperationSucceeded(identity: identity()),
                at: at,
              );
        await expectLater(
          result,
          throwsA(
            isA<OperationStoreConflictException>().having(
              (error) => error.expectedVersion,
              'expectedVersion',
              original.version,
            ),
          ),
        );
        expect(probe.casCalls, 1);
        expect(probe.readCalls, 1);
        expectSnapshot(
          await memory.read(id: identity().id, scope: identity().scope),
          external,
        );
      },
    );
  }

  test(
    'unclassified exception after commit still cannot become success',
    () async {
      final memory = MemoryOperationStore();
      await seedState(memory, OperationState.prepared);
      final probe = StoreProbe(memory);
      final failure = StateError('test adapter failure');
      probe.afterCas = (_, _) async => throw failure;
      final coordinator = RecoveryCoordinator(
        store: probe,
        scope: identity().scope,
      );
      var acknowledged = false;
      await expectLater(
        coordinator.persistUncertainty(identity(), at: at).then((record) {
          acknowledged = true;
          return record;
        }),
        throwsA(same(failure)),
      );
      expect(
        (await coordinator.read(identity().id))!.state,
        OperationState.awaitingOutcome,
      );
      expect(acknowledged, isFalse);
      expect(probe.casCalls, 1);
    },
  );

  test('new storage and missing-record errors omit record values', () {
    final errors = <Exception>[
      const OperationStoreReadException(),
      const OperationStoreWriteException(
        commitStatus: StoreCommitStatus.notCommitted,
      ),
      const OperationStoreWriteException(
        commitStatus: StoreCommitStatus.unknown,
      ),
      const OperationStoreConflictException(expectedVersion: 7),
      const OperationNotFoundException(),
    ];
    for (final error in errors) {
      expect(error.toString(), startsWith(error.runtimeType.toString()));
      for (final value in [
        identity().id,
        identity().scope,
        identity().idempotencyKey,
        identity().requestFingerprint,
      ]) {
        expect(error.toString(), isNot(contains(value)));
      }
    }
  });
}
