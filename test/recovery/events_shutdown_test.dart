import 'dart:async';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/recovery_fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  test(
    'observer exception stays in subscriber zone and cannot corrupt commits',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      final errors = <Object>[];
      final good = <OperationEvent>[];
      final goodDelivered = Completer<void>();
      final errorsDelivered = Completer<void>();
      late StreamSubscription<OperationEvent> bad;
      runZonedGuarded<void>(
        () {
          bad = rig.recovery.events.listen((_) => throw StateError('observer'));
        },
        (error, _) {
          errors.add(error);
          if (errors.length == 3) errorsDelivered.complete();
        },
      );
      final subscription = rig.recovery.events.listen((event) {
        good.add(event);
        if (good.length == 3) goodDelivered.complete();
      });
      addTearDown(bad.cancel);
      addTearDown(subscription.cancel);
      rig.handler.onSubmit = (value, _) async =>
          OperationSucceeded(identity: value);
      final saved = await rig.start();
      await Future.wait([goodDelivered.future, errorsDelivered.future]);
      expect(saved.state, OperationState.succeeded);
      expect(good.map((event) => event.record.version), [0, 1, 2]);
      expect(errors, hasLength(3));
      await rig.start();
      await rig.recovery.reconcile(identity());
      expect(
        good,
        hasLength(3),
        reason: 'Terminal duplicates and reads emit nothing',
      );
    },
  );

  test(
    'reservation, completion and resume emit acknowledged scoped snapshots',
    () async {
      final rig = RecoveryRig(maxAttempts: 1);
      addTearDown(rig.recovery.close);
      await seedState(rig.memory, OperationState.awaitingOutcome);
      final events = <OperationEvent>[];
      final delivered = Completer<void>();
      final subscription = rig.recovery.events.listen((event) {
        events.add(event);
        if (event.record.version == 4) delivered.complete();
      });
      addTearDown(subscription.cancel);
      await rig.recovery.reconcile(identity());
      await rig.recovery.resume(identity());
      await delivered.future;
      expect(events.map((event) => event.record.version), [2, 3, 4]);
      expect(events.map((event) => event.record.state), [
        OperationState.awaitingOutcome,
        OperationState.needsAttention,
        OperationState.awaitingOutcome,
      ]);
      expect(
        events.every(
          (event) => event.record.identity.scope == identity().scope,
        ),
        isTrue,
      );
      expect(events.last.record.recovery.totalAttempts, 1);
      expect(events.last.record.recovery.cycleAttempts, 0);
    },
  );

  for (final stage in ['creation', 'uncertainty', 'reservation']) {
    test('close during $stage commit prevents handler dispatch', () async {
      final rig = RecoveryRig();
      if (stage == 'reservation') {
        await seedState(rig.memory, OperationState.awaitingOutcome);
      }
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      Future<void> block() async {
        entered.complete();
        await release.future;
      }

      if (stage == 'creation') {
        rig.store.beforeCreate = (_) => block();
      } else {
        rig.store.beforeCas = (record, _) async {
          if (record.version == (stage == 'uncertainty' ? 1 : 2)) await block();
        };
      }
      final failed = expectLater(
        stage == 'reservation'
            ? rig.recovery.reconcile(identity())
            : rig.start(),
        throwsA(isA<OperationRecoveryClosedException>()),
      );
      await entered.future;
      final queued = expectLater(
        rig.start(),
        throwsA(isA<OperationRecoveryClosedException>()),
      );
      final closed = rig.recovery.close();
      expect(identical(closed, rig.recovery.close()), isTrue);
      await expectLater(
        rig.recovery.get(identity().id),
        throwsA(isA<OperationRecoveryClosedException>()),
      );
      release.complete();
      await failed;
      await queued;
      await closed;
      expect(rig.handler.submissions, isEmpty);
      expect(rig.handler.lookups, isEmpty);
      expect(
        (await rig.memory.read(
          id: identity().id,
          scope: identity().scope,
        ))!.state,
        OperationState.awaitingOutcome,
      );
    });
  }

  for (final stage in ['submit', 'lookup']) {
    for (final failure in [false, true]) {
      test(
        'close drains active $stage, handler error=$failure, rejects queued work',
        () async {
          final rig = RecoveryRig();
          if (stage == 'lookup') {
            await seedState(rig.memory, OperationState.awaitingOutcome);
          }
          final entered = Completer<void>();
          final release = Completer<void>();
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          Future<BackendObservation> block(OperationIdentity value) async {
            entered.complete();
            await release.future;
            if (failure) throw StateError('handler error during drain');
            return OperationSucceeded(identity: value);
          }

          rig.handler.onSubmit = (value, _) => block(value);
          rig.handler.onLookup = block;
          final result = stage == 'submit'
              ? rig.start()
              : rig.recovery.reconcile(identity());
          final settlement = failure
              ? expectLater(result, throwsA(isA<OperationHandlerException>()))
              : result.then<void>(
                  (record) => expect(record.state, OperationState.succeeded),
                );
          await entered.future;
          final queued = expectLater(
            rig.recovery.reconcile(identity()),
            throwsA(isA<OperationRecoveryClosedException>()),
          );
          var drained = false;
          final closed = rig.recovery.close().then((_) {
            drained = true;
          });
          expect(drained, isFalse);
          await expectLater(
            rig.start(),
            throwsA(isA<OperationRecoveryClosedException>()),
          );
          release.complete();
          await settlement;
          await queued;
          await closed;
          expect(drained, isTrue);
          final saved = (await rig.memory.read(
            id: identity().id,
            scope: identity().scope,
          ))!;
          expect(
            saved.state,
            failure ? OperationState.awaitingOutcome : OperationState.succeeded,
          );
          expect(rig.handler.submissions.length, stage == 'submit' ? 1 : 0);
          expect(rig.handler.lookups.length, stage == 'lookup' ? 1 : 0);
        },
      );
    }
  }

  test(
    'paused observers cannot block shutdown and shared store remains usable',
    () async {
      final rig = RecoveryRig();
      final subscription = rig.recovery.events.listen((_) {});
      subscription.pause();
      await rig.start();
      await rig.recovery.close();
      expect(
        (await rig.memory.read(
          id: identity().id,
          scope: identity().scope,
        ))!.state,
        OperationState.awaitingOutcome,
      );
      subscription.resume();
      await subscription.cancel();
      await expectLater(
        rig.recovery.resume(identity()),
        throwsA(isA<OperationRecoveryClosedException>()),
      );
      await expectLater(
        rig.recovery.reconcilePending(),
        throwsA(isA<OperationRecoveryClosedException>()),
      );
      final replacement = rig.createFacade();
      addTearDown(replacement.close);
      expect(
        (await replacement.get(identity().id))!.state,
        OperationState.awaitingOutcome,
      );
    },
  );

  test(
    'active persistence failure reaches caller but does not reject close',
    () async {
      final rig = RecoveryRig();
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      rig.handler.onSubmit = (value, _) async {
        entered.complete();
        await release.future;
        return OperationSucceeded(identity: value);
      };
      rig.store.beforeCas = (record, _) async {
        if (record.version == 2) {
          throw const OperationStoreWriteException(
            commitStatus: StoreCommitStatus.notCommitted,
          );
        }
      };
      final failed = expectLater(
        rig.start(),
        throwsA(isA<OperationStoreWriteException>()),
      );
      await entered.future;
      final closed = rig.recovery.close();
      release.complete();
      await failed;
      await closed;
      expect(
        (await rig.memory.read(
          id: identity().id,
          scope: identity().scope,
        ))!.version,
        1,
      );
    },
  );
}
