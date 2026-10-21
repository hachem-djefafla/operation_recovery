import 'package:operation_recovery/operation_recovery.dart';

/// Standalone consumer smoke check using supported public imports only.
Future<void> main() async {
  final handler = _Handler();
  final registration = OperationRegistration<String>(
    type: 'demo',
    handler: handler,
  );
  final identity = OperationIdentity(
    id: 'consumer-operation',
    scope: 'consumer-account',
    type: 'demo',
    idempotencyKey: 'consumer-key',
    requestFingerprint: 'consumer-fingerprint',
  );
  final recovery = OperationRecovery(
    scope: identity.scope,
    store: MemoryOperationStore(),
    handlers: [registration],
    policy: RecoveryPolicy(
      maxAttempts: 2,
      initialDelay: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 2),
    ),
  );
  try {
    final uncertain = await recovery.start(
      registration,
      identity: identity,
      request: 'transient',
    );
    final confirmed = await recovery.reconcile(identity);
    final repeated = await recovery.start(
      registration,
      identity: identity,
      request: 'transient',
    );
    if (uncertain.state != OperationState.awaitingOutcome ||
        confirmed.state != OperationState.succeeded ||
        repeated.state != OperationState.succeeded ||
        handler.submissions != 1 ||
        handler.lookups != 1) {
      throw StateError('Public API consumer verification failed');
    }
    print(
      'Public API verified: one explicit submission, lookup, immutable success.',
    );
  } finally {
    await recovery.close();
  }
}

final class _Handler implements OperationHandler<String> {
  int submissions = 0;
  int lookups = 0;

  @override
  Future<BackendObservation> submit(
    OperationIdentity identity,
    String request,
  ) async {
    submissions++;
    return OperationUnknown(identity: identity);
  }

  @override
  Future<BackendObservation> lookupStatus(OperationIdentity identity) async {
    lookups++;
    return OperationSucceeded(
      identity: identity,
      backendReference: 'consumer-result',
    );
  }
}
