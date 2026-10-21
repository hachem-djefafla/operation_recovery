import 'dart:async';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/recovery_fixtures.dart';
import '../support/storage_fixtures.dart';

void main() {
  test(
    'submission sees acknowledged uncertainty and emits committed revisions',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      final events = <OperationEvent>[];
      final delivered = Completer<void>();
      final subscription = rig.recovery.events.listen((event) {
        events.add(event);
        if (event.record.version == 2) delivered.complete();
      });
      addTearDown(subscription.cancel);
      rig.handler.onSubmit = (value, request) async {
        final stored = await rig.memory.read(id: value.id, scope: value.scope);
        expect(stored!.state, OperationState.awaitingOutcome);
        expect(stored.version, 1);
        expect(request, 'transient-private-request');
        return OperationSucceeded(identity: value, backendReference: 'tx-1');
      };
      final saved = await rig.start();
      await delivered.future;
      expect(saved.state, OperationState.succeeded);
      expect(saved.recovery.totalAttempts, 0);
      expect(saved.recovery.nextCheckAt, isNull);
      expect(rig.handler.submissions, [identity()]);
      expect(events.map((event) => event.record.version), [0, 1, 2]);
      for (final event in events) {
        expect(event.toString(), isNot(contains('transient-private-request')));
        expect(event.toString(), isNot(contains(identity().id)));
      }
    },
  );

  for (final state in OperationState.values) {
    test('start from stored ${state.name} only dispatches prepared', () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      final old = await seedState(rig.memory, state);
      final saved = await rig.start();
      expect(
        rig.handler.submissions.length,
        state == OperationState.prepared ? 1 : 0,
      );
      if (state != OperationState.prepared) expectSnapshot(saved, old);
    });
  }

  test(
    'authoritative rejection is distinct from a thrown rejection exception',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      rig.handler.onSubmit = (value, _) async =>
          OperationRejected(identity: value, code: 'declined');
      expect((await rig.start()).state, OperationState.rejected);
      rig.handler.onSubmit = (_, _) =>
          throw StateError('business refusal is not typed evidence');
      final other = identity(id: 'other');
      await expectLater(
        rig.start(operationIdentity: other),
        throwsA(isA<OperationHandlerException>()),
      );
      expect(
        (await rig.recovery.get(other.id))!.state,
        OperationState.awaitingOutcome,
      );
    },
  );

  for (final asynchronous in [false, true]) {
    test(
      'submission timeout async=$asynchronous stays unknown without retries',
      () async {
        final rig = RecoveryRig();
        addTearDown(rig.recovery.close);
        rig.handler.onSubmit = (_, _) {
          if (asynchronous) {
            return Future.error(TimeoutException('lost response'));
          }
          throw TimeoutException('lost response');
        };
        expect((await rig.start()).lastObservation, isA<OperationUnknown>());
        await rig.start();
        expect(rig.handler.submissions, hasLength(1));
      },
    );
  }

  test(
    'executed write with lost response is resolved through lookup once',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      var effects = 0;
      rig.handler.onSubmit = (_, _) async {
        effects++;
        throw TimeoutException('response lost');
      };
      rig.handler.onLookup = (value) async =>
          OperationSucceeded(identity: value, backendReference: 'effect-1');
      expect((await rig.start()).state, OperationState.awaitingOutcome);
      expect(
        (await rig.recovery.reconcile(identity())).state,
        OperationState.succeeded,
      );
      await rig.recovery.reconcile(identity());
      await rig.start();
      expect(effects, 1);
      expect(rig.handler.submissions, hasLength(1));
      expect(rig.handler.lookups, hasLength(1));
    },
  );

  test(
    'unexpected handler error retains safe uncertainty and explicit diagnostics',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      final error = StateError('private handler error');
      rig.handler.onSubmit = (_, _) => throw error;
      await expectLater(
        rig.start(),
        throwsA(
          isA<OperationHandlerException>()
              .having((value) => value.action, 'action', HandlerAction.submit)
              .having((value) => value.cause, 'cause', same(error)),
        ),
      );
      final saved = (await rig.recovery.get(identity().id))!;
      expect(saved.lastObservation, isA<OperationUnknown>());
      expect(saved.toString(), isNot(contains('private')));
      await rig.start();
      expect(rig.handler.submissions, hasLength(1));
    },
  );

  for (final entry in <String, OperationIdentity>{
    'id': identity(id: 'wrong'),
    'scope': identity(scope: 'wrong'),
    'type': identity(type: 'wrong'),
    'key': identity(idempotencyKey: 'wrong'),
    'fingerprint': identity(requestFingerprint: 'wrong'),
  }.entries) {
    test(
      'wrong result ${entry.key} cannot confirm another operation',
      () async {
        final rig = RecoveryRig();
        addTearDown(rig.recovery.close);
        rig.handler.onSubmit = (_, _) async =>
            OperationSucceeded(identity: entry.value);
        await expectLater(
          rig.start(),
          throwsA(isA<OperationIdentityConflictException>()),
        );
        final saved = (await rig.recovery.get(identity().id))!;
        expect(saved.state, OperationState.awaitingOutcome);
        expect(saved.version, 1);
      },
    );
  }

  test(
    'registration validates blank types, duplicates, token, type and request',
    () async {
      final rig = RecoveryRig();
      addTearDown(rig.recovery.close);
      expect(
        () => OperationRegistration<String>(type: ' ', handler: rig.handler),
        throwsA(isA<InvalidOperationRegistrationException>()),
      );
      expect(
        () => OperationRecovery(
          scope: identity().scope,
          store: rig.store,
          handlers: [rig.registration, rig.registration],
          policy: rig.policy,
        ),
        throwsA(isA<InvalidOperationRegistrationException>()),
      );
      final other = OperationRegistration<String>(
        type: 'transfer',
        handler: rig.handler,
      );
      await expectLater(
        rig.recovery.start(other, identity: identity(), request: 'x'),
        throwsA(isA<InvalidOperationRegistrationException>()),
      );
      await expectLater(
        rig.recovery.start(
          rig.registration,
          identity: identity(type: 'other'),
          request: 'x',
        ),
        throwsA(isA<InvalidOperationRegistrationException>()),
      );
      await expectLater(
        rig.recovery.start<Object?>(
          rig.registration,
          identity: identity(),
          request: Object(),
        ),
        throwsA(isA<InvalidOperationRequestException>()),
      );
      expect(rig.store.calls, isEmpty);
      expect(rig.handler.submissions, isEmpty);
    },
  );

  test('registry is frozen against input collection changes', () async {
    final rig = RecoveryRig();
    addTearDown(rig.recovery.close);
    final entries = <OperationRegistration<Object?>>[rig.registration];
    final facade = OperationRecovery(
      scope: identity().scope,
      store: rig.store,
      handlers: entries,
      policy: rig.policy,
      clock: rig.clock,
    );
    addTearDown(facade.close);
    entries.clear();
    await facade.start(rig.registration, identity: identity(), request: 'x');
    expect(rig.handler.submissions, hasLength(1));
  });

  for (final entry in <String, OperationIdentity>{
    'scope': identity(scope: 'foreign'),
    'type': identity(type: 'other'),
    'key': identity(idempotencyKey: 'other'),
    'fingerprint': identity(requestFingerprint: 'other'),
  }.entries) {
    test(
      'conflicting start ${entry.key} does not modify existing record',
      () async {
        final rig = RecoveryRig();
        addTearDown(rig.recovery.close);
        final before = await seedState(
          rig.memory,
          OperationState.awaitingOutcome,
        );
        await expectLater(
          rig.start(operationIdentity: entry.value),
          throwsA(
            anyOf(
              isA<OperationIdentityConflictException>(),
              isA<InvalidOperationRegistrationException>(),
            ),
          ),
        );
        expectSnapshot(await rig.recovery.get(identity().id), before);
        expect(rig.handler.submissions, isEmpty);
      },
    );
  }
}
