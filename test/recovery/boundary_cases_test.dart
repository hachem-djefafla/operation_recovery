import 'dart:async';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/recovery_fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  test(
    'mixed request types preserve typed submission and restored routing',
    () async {
      final text = ScriptedHandler<String>();
      final numbers = ScriptedHandler<int>();
      final textToken = OperationRegistration<String>(
        type: 'transfer',
        handler: text,
      );
      final numberToken = OperationRegistration<int>(
        type: 'invoice',
        handler: numbers,
      );
      final recovery = OperationRecovery(
        scope: identity().scope,
        store: MemoryOperationStore(),
        handlers: [textToken, numberToken],
        policy: RecoveryPolicy(
          maxAttempts: 2,
          initialDelay: const Duration(seconds: 1),
          maxDelay: const Duration(seconds: 2),
        ),
        clock: FakeClock(epoch),
      );
      addTearDown(recovery.close);
      final invoice = identity(id: 'invoice-1', type: 'invoice');
      await recovery.start(
        textToken,
        identity: identity(),
        request: 'transfer',
      );
      await recovery.start(numberToken, identity: invoice, request: 42);
      await recovery.reconcilePending();
      expect(text.requests, ['transfer']);
      expect(numbers.requests, [42]);
      expect(text.lookups, [identity()]);
      expect(numbers.lookups, [invoice]);
      await expectLater(
        recovery.start<Object?>(
          numberToken,
          identity: identity(id: 'invoice-2', type: 'invoice'),
          request: 'wrong',
        ),
        throwsA(isA<InvalidOperationRequestException>()),
      );
      expect(await recovery.get('invoice-2'), isNull);
    },
  );

  test('slow lookup schedules backoff from completion, not dispatch', () async {
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
    final result = rig.recovery.reconcile(identity());
    await entered.future;
    final at = rig.clock.value;
    rig.clock.advance(const Duration(seconds: 20));
    release.complete();
    final saved = await result;
    expect(saved.recovery.lastAttemptAt, at);
    expect(
      saved.recovery.nextCheckAt,
      rig.clock.value.add(const Duration(seconds: 2)),
    );
    await rig.recovery.reconcile(identity());
    expect(rig.handler.lookups, hasLength(1));
  });

  test(
    'physically committed uncertainty without acknowledgement cannot dispatch or emit',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      rig.store.afterCas = (record, _) async {
        if (record.version == 1) {
          entered.complete();
          await release.future;
        }
      };
      final events = <OperationEvent>[];
      final delivered = Completer<void>();
      final subscription = rig.recovery.events.listen((event) {
        events.add(event);
        if (event.record.version == 2) delivered.complete();
      });
      addTearDown(subscription.cancel);
      final start = rig.start();
      await entered.future;
      expect(
        (await rig.memory.read(
          id: identity().id,
          scope: identity().scope,
        ))!.state,
        OperationState.awaitingOutcome,
      );
      await rig.recovery.get('independent-missing');
      expect(rig.handler.submissions, isEmpty);
      expect(events.map((event) => event.record.version), [0]);
      release.complete();
      await start;
      await delivered.future;
      expect(events.map((event) => event.record.version), [0, 1, 2]);
      expect(rig.handler.submissions, hasLength(1));
    },
  );

  test(
    'closing an active batch drains dispatched checks and rejects remaining IDs',
    () async {
      final rig = RecoveryRig();
      for (var i = 0; i < 5; i++) {
        await seedState(
          rig.memory,
          OperationState.awaitingOutcome,
          operationIdentity: identity(id: 'batch-$i'),
        );
      }
      final ready = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      rig.handler.onLookup = (value) async {
        if (rig.handler.lookups.length == 2) ready.complete();
        await release.future;
        return OperationPending(identity: value);
      };
      final batch = rig.recovery.reconcilePending(concurrency: 2);
      await ready.future;
      final closed = rig.recovery.close();
      release.complete();
      final results = await batch;
      await closed;
      expect(results.whereType<ReconciliationCompleted>(), hasLength(2));
      expect(
        results.whereType<ReconciliationFailed>().map((result) => result.error),
        everyElement(isA<OperationRecoveryClosedException>()),
      );
      expect(results.whereType<ReconciliationFailed>(), hasLength(3));
      expect(rig.handler.lookups, hasLength(2));
    },
  );

  test(
    'metadata cannot invent reservations at an impossible record version',
    () {
      expect(
        () => OperationRecord.restore(
          identity: identity(),
          state: OperationState.awaitingOutcome,
          version: 1,
          createdAt: epoch,
          updatedAt: epoch,
          recovery: RecoveryMetadata.restore(
            cycleAttempts: 1,
            totalAttempts: 1,
            lastAttemptAt: epoch,
          ),
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    },
  );

  test(
    'execution error descriptions omit explicitly retained private causes',
    () {
      final errors = <Exception>[
        OperationHandlerException(
          action: HandlerAction.submit,
          cause: StateError('private-token-and-payload'),
          stackTrace: StackTrace.current,
        ),
        const OperationRecoveryClosedException(),
        const InvalidOperationRequestException(),
        const InvalidOperationRegistrationException('duplicate type'),
      ];
      for (final error in errors) {
        expect(error.toString(), startsWith(error.runtimeType.toString()));
        expect(error.toString(), isNot(contains('private-token-and-payload')));
      }
    },
  );
}
