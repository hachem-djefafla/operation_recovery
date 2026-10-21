import 'dart:async';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/recovery_fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  for (final outcome in ['success', 'timeout', 'result-save-failure']) {
    test('concurrent matching starts submit once after $outcome', () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      rig.handler.onSubmit = (value, _) async {
        if (value.id == identity().id) {
          entered.complete();
          await release.future;
          if (outcome == 'timeout') throw TimeoutException('lost');
        }
        return OperationSucceeded(identity: value);
      };
      if (outcome == 'result-save-failure') {
        rig.store.beforeCas = (record, _) async {
          if (record.identity.id == identity().id && record.version == 2) {
            throw const OperationStoreWriteException(
              commitStatus: StoreCommitStatus.notCommitted,
            );
          }
        };
      }
      final first = rig.start();
      final firstOutcome = outcome == 'result-save-failure'
          ? expectLater(first, throwsA(isA<OperationStoreWriteException>()))
          : first.then<void>((_) {});
      await entered.future;
      final duplicates = [for (var index = 0; index < 10; index++) rig.start()];
      var readCompleted = false;
      final read = rig.recovery.get(identity().id).then((value) {
        readCompleted = true;
        return value;
      });
      final independent = await rig.start(
        operationIdentity: identity(id: 'independent'),
      );
      expect(independent.state, OperationState.succeeded);
      expect(readCompleted, isFalse);
      expect(
        rig.handler.submissions.where((value) => value.id == identity().id),
        hasLength(1),
      );
      release.complete();
      await firstOutcome;
      final records = await Future.wait(duplicates);
      final expected = outcome == 'success'
          ? OperationState.succeeded
          : OperationState.awaitingOutcome;
      expect(records.every((record) => record.state == expected), isTrue);
      expect((await read)!.state, expected);
      expect(
        rig.handler.submissions.where((value) => value.id == identity().id),
        hasLength(1),
      );
    });
  }

  for (final committed in [false, true]) {
    test(
      'queued explicit start after ambiguous uncertainty committed=$committed',
      () async {
        final rig = RecoveryRig();
        addTearDown(rig.recovery.close);
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        var first = true;
        Future<void> fault(OperationRecord record, int _) async {
          if (record.version == 1 && first) {
            first = false;
            entered.complete();
            await release.future;
            throw const OperationStoreWriteException(
              commitStatus: StoreCommitStatus.unknown,
            );
          }
        }

        if (committed) {
          rig.store.afterCas = fault;
        } else {
          rig.store.beforeCas = fault;
        }
        final failed = expectLater(
          rig.start(),
          throwsA(isA<OperationStoreWriteException>()),
        );
        await entered.future;
        final queued = rig.start();
        release.complete();
        await failed;
        await queued;
        expect(rig.handler.submissions.length, committed ? 0 : 1);
      },
    );
  }

  test('lookup and submission cannot overlap for one ID', () async {
    final rig = RecoveryRig();
    addTearDown(rig.recovery.close);
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    rig.handler.onSubmit = (value, _) async {
      entered.complete();
      await release.future;
      return OperationUnknown(identity: value);
    };
    final start = rig.start();
    await entered.future;
    final check = rig.recovery.reconcile(identity());
    await rig.recovery.get('independent-missing');
    expect(rig.handler.lookups, isEmpty);
    release.complete();
    await start;
    await check;
    expect(rig.handler.submissions, hasLength(1));
    expect(rig.handler.lookups, hasLength(1));
  });

  test(
    'simultaneous checks reserve once and use backoff before queued successor',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      await seedState(rig.memory, OperationState.awaitingOutcome);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      rig.handler.onLookup = (value) async {
        entered.complete();
        await release.future;
        return OperationPending(identity: value);
      };
      final first = rig.recovery.reconcile(identity());
      await entered.future;
      final checks = [
        for (var i = 0; i < 10; i++) rig.recovery.reconcile(identity()),
      ];
      await rig.recovery.get('independent-missing');
      expect(rig.handler.lookups, hasLength(1));
      release.complete();
      await first;
      await Future.wait(checks);
      expect(rig.handler.lookups, hasLength(1));
      expect(
        (await rig.recovery.get(identity().id))!.recovery.totalAttempts,
        1,
      );
    },
  );

  test(
    'batch workers are bounded and independent errors do not stop the batch',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      for (var i = 0; i < 6; i++) {
        await seedState(
          rig.memory,
          OperationState.awaitingOutcome,
          operationIdentity: identity(id: 'op-$i'),
        );
      }
      await seedState(
        rig.memory,
        OperationState.prepared,
        operationIdentity: identity(id: 'prepared'),
      );
      final ready = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var active = 0;
      var maximum = 0;
      rig.handler.onLookup = (value) async {
        active++;
        if (active > maximum) maximum = active;
        if (rig.handler.lookups.length == 3) ready.complete();
        await release.future;
        active--;
        if (value.id == 'op-0') throw StateError('isolated adapter bug');
        return OperationSucceeded(identity: value);
      };
      final batch = rig.recovery.reconcilePending(concurrency: 3);
      await ready.future;
      expect(rig.handler.lookups, hasLength(3));
      expect(maximum, 3);
      release.complete();
      final results = await batch;
      expect(results, hasLength(6));
      expect(results.whereType<ReconciliationCompleted>(), hasLength(5));
      final failed = results.whereType<ReconciliationFailed>().single;
      expect(failed.error, isA<OperationHandlerException>());
      expect(failed.identity.id, 'op-0');
      expect(failed.toString(), 'ReconciliationFailed');
      expect(
        results.whereType<ReconciliationCompleted>().first.toString(),
        isNot(contains('account-456')),
      );
      expect(() => results.clear(), throwsUnsupportedError);
      expect(maximum, 3);
      expect(rig.handler.submissions, isEmpty);
    },
  );

  test('concurrent batches do not duplicate a due lookup', () async {
    final rig = RecoveryRig();
    addTearDown(rig.recovery.close);
    await seedState(rig.memory, OperationState.awaitingOutcome);
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    rig.handler.onLookup = (value) async {
      entered.complete();
      await release.future;
      return OperationPending(identity: value);
    };
    final first = rig.recovery.reconcilePending();
    await entered.future;
    final second = rig.recovery.reconcilePending();
    await rig.recovery.get('independent-missing');
    release.complete();
    await first;
    await second;
    expect(rig.handler.lookups, hasLength(1));
  });

  test(
    'listing failure and invalid batch concurrency dispatch nothing',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      for (final count in [0, -1]) {
        await expectLater(
          rig.recovery.reconcilePending(concurrency: count),
          throwsArgumentError,
        );
      }
      expect(rig.store.calls, isEmpty);
      rig.store.beforeList = () async =>
          throw const OperationStoreReadException();
      await expectLater(
        rig.recovery.reconcilePending(),
        throwsA(isA<OperationStoreReadException>()),
      );
      expect(rig.handler.lookups, isEmpty);
    },
  );

  test(
    'delayed lookup cannot overwrite an externally committed terminal result',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      await seedState(rig.memory, OperationState.awaitingOutcome);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      rig.handler.onLookup = (value) async {
        entered.complete();
        await release.future;
        return OperationRejected(identity: value);
      };
      final failed = expectLater(
        rig.recovery.reconcile(identity()),
        throwsA(isA<OperationStoreConflictException>()),
      );
      await entered.future;
      final reserved = (await rig.memory.read(
        id: identity().id,
        scope: identity().scope,
      ))!;
      final finalRecord = machine.applyObservation(
        reserved,
        OperationSucceeded(identity: identity()),
        at: rig.clock.value,
      );
      expect(
        await rig.memory.compareAndSwap(
          finalRecord,
          expectedVersion: reserved.version,
        ),
        isTrue,
      );
      release.complete();
      await failed;
      expectSnapshot(await rig.recovery.get(identity().id), finalRecord);
      expect(rig.handler.lookups, hasLength(1));
      expect(rig.handler.submissions, isEmpty);
    },
  );
}
