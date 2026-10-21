import 'package:operation_recovery/operation_recovery.dart';

import 'fixtures.dart';
import 'storage_fixtures.dart';

final class FakeClock implements Clock {
  FakeClock(this.value);
  DateTime value;
  @override
  DateTime now() => value;
  void advance(Duration duration) => value = value.add(duration);
}

final class ScriptedHandler<T> implements OperationHandler<T> {
  final List<OperationIdentity> submissions = [];
  final List<OperationIdentity> lookups = [];
  final List<T> requests = [];
  Future<BackendObservation> Function(OperationIdentity, T)? onSubmit;
  Future<BackendObservation> Function(OperationIdentity)? onLookup;

  @override
  Future<BackendObservation> submit(OperationIdentity identity, T request) {
    submissions.add(identity);
    requests.add(request);
    return onSubmit?.call(identity, request) ??
        Future.value(OperationUnknown(identity: identity));
  }

  @override
  Future<BackendObservation> lookupStatus(OperationIdentity identity) {
    lookups.add(identity);
    return onLookup?.call(identity) ??
        Future.value(OperationPending(identity: identity));
  }
}

final class RecoveryRig {
  RecoveryRig({int maxAttempts = 3}) {
    store = StoreProbe(memory);
    registration = OperationRegistration<String>(
      type: 'transfer',
      handler: handler,
    );
    policy = RecoveryPolicy(
      maxAttempts: maxAttempts,
      initialDelay: const Duration(seconds: 2),
      maxDelay: const Duration(seconds: 5),
    );
    recovery = createFacade();
  }

  final memory = MemoryOperationStore();
  final clock = FakeClock(epoch.add(const Duration(seconds: 10)));
  final handler = ScriptedHandler<String>();
  late final StoreProbe store;
  late final OperationRegistration<String> registration;
  late final RecoveryPolicy policy;
  late final OperationRecovery recovery;

  OperationRecovery createFacade({RecoveryPolicy? overridePolicy}) =>
      OperationRecovery(
        scope: identity().scope,
        store: store,
        handlers: [registration],
        policy: overridePolicy ?? policy,
        clock: clock,
      );

  Future<OperationRecord> start({OperationIdentity? operationIdentity}) =>
      recovery.start(
        registration,
        identity: operationIdentity ?? identity(),
        request: 'transient-private-request',
      );
}
