import 'package:operation_recovery/operation_recovery.dart';

import 'simulated_backend.dart';

Future<void> main() async {
  final backend = await SimulatedBackend.start();
  final registration = OperationRegistration<String>(
    type: 'transfer',
    handler: DemoHttpHandler(backend.baseUri),
  );
  final recovery = OperationRecovery(
    scope: 'account-456',
    store: MemoryOperationStore(),
    handlers: [registration],
    policy: RecoveryPolicy(
      maxAttempts: 3,
      initialDelay: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 8),
    ),
  );
  final identity = OperationIdentity(
    id: 'op-123',
    scope: 'account-456',
    type: 'transfer',
    idempotencyKey: 'key-123',
    requestFingerprint: 'sha256:application-provided',
  );
  try {
    final initial = await recovery.start(
      registration,
      identity: identity,
      request: 'demo transfer',
    );
    print('After lost response: ${initial.state.name}');
    final confirmed = await recovery.reconcile(identity);
    print('After lookup: ${confirmed.state.name}');
    print(
      'Submission requests: ${backend.submissionRequests}; effects: ${backend.effects}',
    );
    print(
      'Storage is memory-only; this demo does not prove restart durability.',
    );
  } finally {
    await recovery.close();
    await backend.close();
  }
}
