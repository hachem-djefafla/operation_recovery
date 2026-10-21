import 'dart:async';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/recovery_fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  final faults = [
    (
      name: 'definite failure',
      status: StoreCommitStatus.notCommitted,
      committed: false,
    ),
    (
      name: 'unknown without commit',
      status: StoreCommitStatus.unknown,
      committed: false,
    ),
    (
      name: 'lost acknowledgement',
      status: StoreCommitStatus.unknown,
      committed: true,
    ),
  ];
  for (final stage in [
    'creation',
    'uncertainty',
    'submission-result',
    'reservation',
    'lookup-result',
  ]) {
    for (final fault in faults) {
      test(
        '$stage: ${fault.name} cannot invent success or retry handlers',
        () async {
          final rig = RecoveryRig();
          addTearDown(rig.recovery.close);
          final lookup = stage == 'reservation' || stage == 'lookup-result';
          if (lookup) {
            await seedState(rig.memory, OperationState.awaitingOutcome);
          }
          rig.handler.onSubmit = (value, _) async =>
              OperationSucceeded(identity: value);
          rig.handler.onLookup = (value) async =>
              OperationSucceeded(identity: value);
          final events = <OperationEvent>[];
          final eventsDone = Completer<void>();
          final subscription = rig.recovery.events.listen(
            events.add,
            onDone: eventsDone.complete,
          );
          addTearDown(subscription.cancel);
          final failure = OperationStoreWriteException(
            commitStatus: fault.status,
          );
          final targetVersion = switch (stage) {
            'creation' => 0,
            'uncertainty' => 1,
            'submission-result' || 'reservation' => 2,
            _ => 3,
          };
          Future<void> createFault(OperationRecord _) async => throw failure;
          Future<void> casFault(OperationRecord record, int _) async {
            if (record.version == targetVersion) throw failure;
          }

          if (stage == 'creation') {
            if (fault.committed) {
              rig.store.afterCreate = createFault;
            } else {
              rig.store.beforeCreate = createFault;
            }
          } else {
            if (fault.committed) {
              rig.store.afterCas = casFault;
            } else {
              rig.store.beforeCas = casFault;
            }
          }
          var acknowledged = false;
          final operation = lookup
              ? rig.recovery.reconcile(identity())
              : rig.start();
          await expectLater(
            operation.then((record) {
              acknowledged = true;
              return record;
            }),
            throwsA(same(failure)),
          );
          expect(acknowledged, isFalse);
          expect(
            events.any((event) => event.record.version == targetVersion),
            isFalse,
          );
          expect(
            rig.handler.submissions.length,
            stage == 'submission-result' ? 1 : 0,
          );
          expect(rig.handler.lookups.length, stage == 'lookup-result' ? 1 : 0);
          expect(
            rig.store.readCalls,
            lookup ? 1 : 0,
            reason: 'No automatic readback after a failed acknowledgement',
          );
          final readsBefore = rig.store.readCalls;
          final saved = await rig.recovery.get(identity().id);
          expect(rig.store.readCalls, readsBefore + 1);
          expect(acknowledged, isFalse);
          if (fault.committed) {
            expect(saved!.version, targetVersion);
          } else if (stage == 'creation') {
            expect(saved, isNull);
          } else {
            expect(saved!.version, targetVersion - 1);
          }
          rig.store.beforeCreate = null;
          rig.store.afterCreate = null;
          rig.store.beforeCas = null;
          rig.store.afterCas = null;
          if (!lookup &&
              saved != null &&
              saved.state != OperationState.prepared) {
            await rig.start();
            expect(
              rig.handler.submissions.length,
              stage == 'submission-result' ? 1 : 0,
            );
          }
          expect(acknowledged, isFalse);
          await rig.recovery.close();
          await eventsDone.future;
          expect(
            events.any((event) => event.record.version == targetVersion),
            isFalse,
          );
        },
      );
    }
  }

  test(
    'later explicit start needs a fresh successful uncertainty commit',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      var first = true;
      rig.store.beforeCas = (record, _) async {
        if (record.version == 1 && first) {
          first = false;
          throw const OperationStoreWriteException(
            commitStatus: StoreCommitStatus.unknown,
          );
        }
      };
      await expectLater(
        rig.start(),
        throwsA(isA<OperationStoreWriteException>()),
      );
      expect(rig.handler.submissions, isEmpty);
      expect(
        (await rig.recovery.get(identity().id))!.state,
        OperationState.prepared,
      );
      await rig.start();
      expect(rig.handler.submissions, hasLength(1));
      expect(rig.store.casCalls, 3);
    },
  );

  test(
    'failed safe-uncertainty save surfaces storage error, not handler error',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      rig.handler.onSubmit = (_, _) => throw StateError('adapter bug');
      const failure = OperationStoreWriteException(
        commitStatus: StoreCommitStatus.notCommitted,
      );
      rig.store.beforeCas = (record, _) async {
        if (record.version == 2) throw failure;
      };
      await expectLater(rig.start(), throwsA(same(failure)));
      expect(rig.handler.submissions, hasLength(1));
      expect((await rig.recovery.get(identity().id))!.version, 1);
    },
  );

  for (final stage in [
    'uncertainty',
    'submission-result',
    'reservation',
    'lookup-result',
  ]) {
    test(
      'CAS race at $stage preserves external outcome without handler replay',
      () async {
        final rig = RecoveryRig();
        addTearDown(rig.recovery.close);
        final lookup = stage == 'reservation' || stage == 'lookup-result';
        if (lookup) await seedState(rig.memory, OperationState.awaitingOutcome);
        rig.handler.onSubmit = (value, _) async =>
            OperationSucceeded(identity: value);
        final target = stage == 'uncertainty'
            ? 1
            : stage == 'lookup-result'
            ? 3
            : 2;
        OperationRecord? external;
        rig.store.beforeCas = (record, expected) async {
          if (record.version == target) {
            final current = (await rig.memory.read(
              id: identity().id,
              scope: identity().scope,
            ))!;
            external = current.state == OperationState.prepared
                ? machine.beginSubmission(
                    current,
                    identity: identity(),
                    at: rig.clock.value,
                  )
                : machine.applyObservation(
                    current,
                    OperationRejected(
                      identity: identity(),
                      code: 'external-final',
                    ),
                    at: rig.clock.value,
                  );
            expect(
              await rig.memory.compareAndSwap(
                external!,
                expectedVersion: expected,
              ),
              isTrue,
            );
          }
        };
        await expectLater(
          lookup ? rig.recovery.reconcile(identity()) : rig.start(),
          throwsA(isA<OperationStoreConflictException>()),
        );
        expectSnapshot(await rig.recovery.get(identity().id), external!);
        expect(
          rig.handler.submissions.length,
          stage == 'submission-result' ? 1 : 0,
        );
        expect(rig.handler.lookups.length, stage == 'lookup-result' ? 1 : 0);
      },
    );
  }
}
