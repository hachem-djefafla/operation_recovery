import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../../example/simulated_backend.dart';
import '../support/fixtures.dart';
import '../support/recovery_fixtures.dart';

void main() {
  for (final lost in [true, false]) {
    test(
      'HTTP response lost=$lost, incoming submissions and effects each one',
      () async {
        final server = await SimulatedBackend.start(
          loseSubmissionResponse: lost,
        );
        addTearDown(server.close);
        final handler = DemoHttpHandler(server.baseUri);
        final registration = OperationRegistration<String>(
          type: 'transfer',
          handler: handler,
        );
        final recovery = OperationRecovery(
          scope: identity().scope,
          store: MemoryOperationStore(),
          handlers: [registration],
          policy: RecoveryPolicy(
            maxAttempts: 3,
            initialDelay: const Duration(seconds: 1),
            maxDelay: const Duration(seconds: 4),
          ),
        );
        addTearDown(recovery.close);
        final first = await recovery.start(
          registration,
          identity: identity(),
          request: 'private transfer request',
        );
        expect(
          first.state,
          lost ? OperationState.awaitingOutcome : OperationState.succeeded,
        );
        expect(
          (await recovery.reconcile(identity())).state,
          OperationState.succeeded,
        );
        await recovery.start(
          registration,
          identity: identity(),
          request: 'private transfer request',
        );
        expect(server.submissionRequests, 1);
        expect(server.effects, 1);
        expect(server.lookupRequests, lost ? 1 : 0);
      },
    );
  }

  test('real HTTP 401 is recoverable after credentials are restored', () async {
    final server = await SimulatedBackend.start();
    addTearDown(server.close);
    final handler = DemoHttpHandler(server.baseUri);
    final registration = OperationRegistration<String>(
      type: 'transfer',
      handler: handler,
    );
    final clock = FakeClock(epoch);
    final recovery = OperationRecovery(
      scope: identity().scope,
      store: MemoryOperationStore(),
      handlers: [registration],
      policy: RecoveryPolicy(
        maxAttempts: 3,
        initialDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 4),
      ),
      clock: clock,
    );
    addTearDown(recovery.close);
    await recovery.start(
      registration,
      identity: identity(),
      request: 'transfer',
    );
    handler.authenticated = false;
    final blocked = await recovery.reconcile(identity());
    expect(blocked.state, OperationState.awaitingOutcome);
    expect(
      (blocked.lastObservation! as LookupUnavailable).reason,
      LookupFailureReason.authenticationRequired,
    );
    handler.authenticated = true;
    clock.value = blocked.recovery.nextCheckAt!;
    expect(
      (await recovery.reconcile(identity())).state,
      OperationState.succeeded,
    );
    expect(server.submissionRequests, 1);
    expect(server.effects, 1);
    expect(server.lookupRequests, 2);
  });

  test(
    'real HTTP 404 leaves an operation unknown without submitting',
    () async {
      final server = await SimulatedBackend.start();
      addTearDown(server.close);
      final handler = DemoHttpHandler(server.baseUri);
      final observation = await handler.lookupStatus(identity());
      expect(observation, isA<OperationUnknown>());
      expect(server.submissionRequests, 0);
      expect(server.effects, 0);
    },
  );
}
