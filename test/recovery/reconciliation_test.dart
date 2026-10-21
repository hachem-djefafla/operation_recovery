import 'dart:async';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/recovery_fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  for (final state in [
    OperationState.prepared,
    OperationState.needsAttention,
    OperationState.succeeded,
    OperationState.rejected,
  ]) {
    test('reconcile skips ${state.name}', () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      final old = await seedState(rig.memory, state);
      expectSnapshot(await rig.recovery.reconcile(identity()), old);
      expect(rig.handler.lookups, isEmpty);
      expect(rig.handler.submissions, isEmpty);
      expect(rig.store.casCalls, 0);
    });
  }

  test('due boundary and capped backoff use persisted reservations', () async {
    final rig = RecoveryRig(maxAttempts: 5);
    addTearDown(rig.recovery.close);
    await seedState(rig.memory, OperationState.awaitingOutcome);
    final delays = [2, 4, 5, 5];
    for (var attempt = 1; attempt <= 5; attempt++) {
      final at = rig.clock.value;
      final saved = await rig.recovery.reconcile(identity());
      expect(saved.recovery.cycleAttempts, attempt);
      expect(saved.recovery.totalAttempts, attempt);
      expect(saved.recovery.lastAttemptAt, at);
      if (attempt == 5) {
        expect(saved.state, OperationState.needsAttention);
        expect(saved.recovery.nextCheckAt, isNull);
      } else {
        final due = at.add(Duration(seconds: delays[attempt - 1]));
        expect(saved.recovery.nextCheckAt, due);
        rig.clock.value = due.subtract(const Duration(microseconds: 1));
        expectSnapshot(await rig.recovery.reconcile(identity()), saved);
        expect(rig.handler.lookups, hasLength(attempt));
        rig.clock.value = due;
      }
    }
    expect(rig.handler.lookups, hasLength(5));
    expect(rig.handler.submissions, isEmpty);
    expect(rig.store.casCalls, 10);
  });

  for (final kind in ['pending', 'unknown', 'auth', 'transport', 'service']) {
    test('$kind never establishes rejection, including exhaustion', () async {
      final rig = RecoveryRig(maxAttempts: 1);
      addTearDown(rig.recovery.close);
      await seedState(rig.memory, OperationState.awaitingOutcome);
      rig.handler.onLookup = (value) async => switch (kind) {
        'pending' => OperationPending(identity: value),
        'unknown' => OperationUnknown(identity: value),
        'auth' => LookupUnavailable(
          identity: value,
          reason: LookupFailureReason.authenticationRequired,
        ),
        'transport' => LookupUnavailable(
          identity: value,
          reason: LookupFailureReason.transportFailure,
        ),
        _ => LookupUnavailable(
          identity: value,
          reason: LookupFailureReason.serviceUnavailable,
        ),
      };
      final saved = await rig.recovery.reconcile(identity());
      expect(saved.state, OperationState.needsAttention);
      expect(saved.state.isUnresolved, isTrue);
      expect(
        saved.version,
        3,
        reason: 'Reserve and completion each commit once',
      );
      expect(saved.recovery.cycleAttempts, 1);
      await rig.recovery.reconcile(identity());
      expect(rig.handler.lookups, hasLength(1));
    });
  }

  for (final success in [true, false]) {
    test(
      'authoritative success=$success wins on the last allowed attempt',
      () async {
        final rig = RecoveryRig(maxAttempts: 1);
        addTearDown(rig.recovery.close);
        await seedState(rig.memory, OperationState.awaitingOutcome);
        rig.handler.onLookup = (value) async => success
            ? OperationSucceeded(identity: value)
            : OperationRejected(identity: value);
        final saved = await rig.recovery.reconcile(identity());
        expect(
          saved.state,
          success ? OperationState.succeeded : OperationState.rejected,
        );
        expect(saved.recovery.nextCheckAt, isNull);
        expect(saved.recovery.totalAttempts, 1);
      },
    );
  }

  test('authentication can recover without resubmitting a write', () async {
    final rig = RecoveryRig();
    addTearDown(rig.recovery.close);
    await rig.start();
    var authenticated = false;
    rig.handler.onLookup = (value) async => authenticated
        ? OperationSucceeded(identity: value)
        : LookupUnavailable(
            identity: value,
            reason: LookupFailureReason.authenticationRequired,
          );
    final blocked = await rig.recovery.reconcile(identity());
    expect(blocked.state, OperationState.awaitingOutcome);
    expect(
      (blocked.lastObservation! as LookupUnavailable).reason,
      LookupFailureReason.authenticationRequired,
    );
    authenticated = true;
    rig.clock.value = blocked.recovery.nextCheckAt!;
    expect(
      (await rig.recovery.reconcile(identity())).state,
      OperationState.succeeded,
    );
    expect(rig.handler.submissions, hasLength(1));
    expect(rig.handler.lookups, hasLength(2));
  });

  test('resume resets cycle only and does not dispatch', () async {
    final rig = RecoveryRig(maxAttempts: 1);
    addTearDown(rig.recovery.close);
    await seedState(rig.memory, OperationState.awaitingOutcome);
    final attention = await rig.recovery.reconcile(identity());
    final resumed = await rig.recovery.resume(identity());
    expect(resumed.recovery.cycleAttempts, 0);
    expect(resumed.recovery.totalAttempts, 1);
    expect(resumed.recovery.lastAttemptAt, attention.recovery.lastAttemptAt);
    expect(resumed.recovery.nextCheckAt, rig.clock.value);
    expect(rig.handler.lookups, hasLength(1));
    expect(rig.handler.submissions, isEmpty);
    await expectLater(
      rig.recovery.resume(identity()),
      throwsA(isA<IllegalOperationTransitionException>()),
    );
    expect(
      (await rig.recovery.reconcile(identity())).recovery.totalAttempts,
      2,
    );
  });

  test(
    'recreated facade respects abandoned reservation and exhaustion',
    () async {
      final rig = RecoveryRig(maxAttempts: 1);
      await seedState(rig.memory, OperationState.awaitingOutcome);
      rig.store.afterCas = (record, _) async {
        if (record.recovery.cycleAttempts == 1) {
          throw const OperationStoreWriteException(
            commitStatus: StoreCommitStatus.unknown,
          );
        }
      };
      await expectLater(
        rig.recovery.reconcile(identity()),
        throwsA(isA<OperationStoreWriteException>()),
      );
      final reserved = (await rig.recovery.get(identity().id))!;
      expect(reserved.recovery.totalAttempts, 1);
      expect(rig.handler.lookups, isEmpty);
      await rig.recovery.close();
      rig.store.afterCas = null;
      final restored = rig.createFacade();
      addTearDown(restored.close);
      expectSnapshot(await restored.reconcile(identity()), reserved);
      rig.clock.value = reserved.recovery.nextCheckAt!;
      expect(
        (await restored.reconcile(identity())).state,
        OperationState.needsAttention,
      );
      expect(rig.handler.lookups, isEmpty);
      await restored.resume(identity());
      expect((await restored.reconcile(identity())).recovery.totalAttempts, 2);
    },
  );

  for (final asynchronous in [true, false]) {
    test(
      'lookup timeout async=$asynchronous is transport uncertainty',
      () async {
        final rig = RecoveryRig();
        addTearDown(rig.recovery.close);
        await seedState(rig.memory, OperationState.awaitingOutcome);
        rig.handler.onLookup = (_) {
          if (asynchronous) return Future.error(TimeoutException('lookup'));
          throw TimeoutException('lookup');
        };
        final saved = await rig.recovery.reconcile(identity());
        expect(saved.state, OperationState.awaitingOutcome);
        expect(
          (saved.lastObservation! as LookupUnavailable).reason,
          LookupFailureReason.transportFailure,
        );
        expect(saved.recovery.totalAttempts, 1);
        expect(rig.handler.submissions, isEmpty);
      },
    );
  }

  test(
    'unexpected lookup exception persists uncertainty then surfaces safely',
    () async {
      final rig = RecoveryRig(maxAttempts: 1);
      addTearDown(rig.recovery.close);
      await seedState(rig.memory, OperationState.awaitingOutcome);
      rig.handler.onLookup = (_) => throw StateError('private bug');
      await expectLater(
        rig.recovery.reconcile(identity()),
        throwsA(
          isA<OperationHandlerException>().having(
            (error) => error.action,
            'action',
            HandlerAction.lookupStatus,
          ),
        ),
      );
      final saved = (await rig.recovery.get(identity().id))!;
      expect(saved.lastObservation, isA<OperationUnknown>());
      expect(saved.state, OperationState.needsAttention);
      expect(saved.toString(), isNot(contains('private bug')));
    },
  );

  test(
    'wrong-identity lookup result cannot confirm or erase reservation',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      await seedState(rig.memory, OperationState.awaitingOutcome);
      rig.handler.onLookup = (_) async =>
          OperationSucceeded(identity: identity(scope: 'foreign'));
      await expectLater(
        rig.recovery.reconcile(identity()),
        throwsA(isA<OperationIdentityConflictException>()),
      );
      final saved = (await rig.recovery.get(identity().id))!;
      expect(saved.state, OperationState.awaitingOutcome);
      expect(saved.version, 2);
      expect(saved.recovery.totalAttempts, 1);
      expect(saved.lastObservation, isNull);
    },
  );

  test('missing restored handler consumes no reservation', () async {
    final rig = RecoveryRig();
    addTearDown(rig.recovery.close);
    final old = await seedState(rig.memory, OperationState.awaitingOutcome);
    final facade = OperationRecovery(
      scope: identity().scope,
      store: rig.store,
      handlers: [],
      policy: rig.policy,
      clock: rig.clock,
    );
    addTearDown(facade.close);
    await expectLater(
      facade.reconcile(identity()),
      throwsA(isA<InvalidOperationRegistrationException>()),
    );
    expectSnapshot(await facade.get(identity().id), old);
    expect(rig.store.casCalls, 0);
  });

  test(
    'scope isolation holds for all facade entrypoints and batches',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      final foreign = identity(scope: 'foreign');
      await seedState(
        rig.memory,
        OperationState.awaitingOutcome,
        operationIdentity: foreign,
      );
      for (final call in [
        () => rig.recovery.reconcile(foreign),
        () => rig.recovery.resume(foreign),
        () => rig.start(operationIdentity: foreign),
      ]) {
        await expectLater(
          call(),
          throwsA(isA<OperationIdentityConflictException>()),
        );
      }
      expect(rig.store.calls, isEmpty);
      expect(await rig.recovery.get(foreign.id), isNull);
      expect(await rig.recovery.get('missing'), isNull);
      await expectLater(
        rig.recovery.reconcile(identity()),
        throwsA(isA<OperationNotFoundException>()),
      );
      expect(await rig.recovery.reconcilePending(), isEmpty);
      expect(rig.handler.submissions, isEmpty);
      expect(rig.handler.lookups, isEmpty);
    },
  );

  test('clock rollback never regresses committed timestamps', () async {
    final rig = RecoveryRig();
    addTearDown(rig.recovery.close);
    final old = await rig.start();
    rig.clock.value = epoch;
    final next = await rig.recovery.reconcile(identity());
    expect(next.updatedAt, old.updatedAt);
    expect(next.recovery.lastAttemptAt, old.updatedAt);
    expect(
      next.recovery.nextCheckAt,
      old.updatedAt.add(const Duration(seconds: 2)),
    );
  });

  test('new policy honors stored due time and existing counters', () async {
    final rig = RecoveryRig();
    await seedState(rig.memory, OperationState.awaitingOutcome);
    final old = await rig.recovery.reconcile(identity());
    await rig.recovery.close();
    final restored = rig.createFacade(
      overridePolicy: RecoveryPolicy(
        maxAttempts: 1,
        initialDelay: const Duration(microseconds: 1),
        maxDelay: const Duration(seconds: 1),
      ),
    );
    addTearDown(restored.close);
    expectSnapshot(await restored.reconcile(identity()), old);
    rig.clock.value = old.recovery.nextCheckAt!;
    expect(
      (await restored.reconcile(identity())).state,
      OperationState.needsAttention,
    );
    expect(rig.handler.lookups, hasLength(1));
  });
}
