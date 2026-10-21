import 'dart:async';

import '../domain/backend_observation.dart';
import '../domain/operation_exception.dart';
import '../domain/operation_identity.dart';
import '../domain/operation_record.dart';
import '../domain/operation_state.dart';
import '../domain/state_machine.dart';
import '../infrastructure/system_clock.dart';
import '../ports/clock.dart';
import '../ports/operation_handler.dart';
import '../ports/operation_store.dart';
import '../ports/operation_store_exception.dart';
import 'operation_event.dart';
import 'operation_execution_exception.dart';
import 'reconciliation_result.dart';
import 'recovery_policy.dart';

/// Typed account-bound registration with private request-type erasure.
/// Use the same token for facade construction and start calls.
final class OperationRegistration<TRequest> {
  /// Binds a stable type to its application-owned handler.
  OperationRegistration({
    required this.type,
    required OperationHandler<TRequest> handler,
  }) : _handler = handler {
    if (type.trim().isEmpty) {
      throw const InvalidOperationRegistrationException(
        'type must not be blank',
      );
    }
  }

  /// The stable type used to route restored records.
  final String type;
  final OperationHandler<TRequest> _handler;

  bool _accepts(Object? request) => request is TRequest;
  Future<BackendObservation> _submit(
    OperationIdentity identity,
    Object? request,
  ) => _handler.submit(identity, request as TRequest);
  Future<BackendObservation> _lookup(OperationIdentity identity) =>
      _handler.lookupStatus(identity);
}

/// Internal state-machine coordination across complete handler sequences.
/// There is no arbitrary replacement API. Serialization belongs to this instance.
final class RecoveryCoordinator {
  /// Creates one scoped coordinator; policy/handlers enable execution methods.
  RecoveryCoordinator({
    required OperationStore store,
    required this.scope,
    Iterable<OperationRegistration<Object?>> handlers = const [],
    RecoveryPolicy? policy,
    Clock clock = const SystemClock(),
  }) : _store = store,
       _policy = policy,
       _clock = clock {
    if (scope.trim().isEmpty) {
      throw const InvalidOperationRecordException('scope', 'must not be blank');
    }
    for (final registration in handlers) {
      if (_handlers.containsKey(registration.type)) {
        throw const InvalidOperationRegistrationException('duplicate type');
      }
      _handlers[registration.type] = registration;
    }
  }

  /// The immutable scope for every storage/handler action.
  final String scope;
  final OperationStore _store;
  final RecoveryPolicy? _policy;
  final Clock _clock;
  final OperationStateMachine _machine = const OperationStateMachine();
  final Map<String, OperationRegistration<Object?>> _handlers = {};
  final Map<String, Future<void>> _tails = {};
  final Set<Future<void>> _jobs = {};
  final StreamController<OperationEvent> _events =
      StreamController<OperationEvent>.broadcast();
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Asynchronous notifications of acknowledged commits only.
  Stream<OperationEvent> get events => _events.stream;

  /// Submits only after this invocation's uncertainty CAS is acknowledged.
  Future<OperationRecord> start<TRequest>(
    OperationRegistration<TRequest> registration, {
    required OperationIdentity identity,
    required TRequest request,
  }) async {
    _requireScope(identity);
    if (!identical(_handlers[identity.type], registration) ||
        registration.type != identity.type) {
      throw const InvalidOperationRegistrationException(
        'token is not registered for identity type',
      );
    }
    if (!registration._accepts(request)) {
      throw const InvalidOperationRequestException();
    }
    return _execute(identity.id, () async {
      final prepared = await _prepare(identity, at: _now());
      if (prepared.state != OperationState.prepared) return prepared;
      final at = _now(prepared);
      final uncertain = await _commit(
        prepared,
        _machine.beginSubmission(
          prepared,
          identity: identity,
          at: at,
          firstCheckAt: at,
        ),
      );
      // Dispatch eligibility is local control flow, never inferred by a reread.
      _ensureOpen();
      final result = await _invoke(
        identity,
        HandlerAction.submit,
        () => registration._submit(identity, request),
      );
      identity.requireMatch(result.observation.identity);
      final saved = await _commit(
        uncertain,
        _machine.applyObservation(
          uncertain,
          result.observation,
          at: _now(uncertain),
        ),
      );
      if (result.failure != null) throw result.failure!;
      return saved;
    });
  }

  /// Reconciles through lookup only, respecting persisted due time and budget.
  Future<OperationRecord> reconcile(OperationIdentity identity) async {
    _requireScope(identity);
    return _execute(identity.id, () => _reconcile(identity));
  }

  /// Processes initially due records with independent results and bounded workers.
  Future<List<ReconciliationResult>> reconcilePending({
    int concurrency = 4,
  }) async {
    _ensureOpen();
    if (concurrency < 1) throw ArgumentError('concurrency must be positive');
    return _execute(null, () async {
      final records = (await _listUnresolved())
          .where(
            (record) =>
                record.state == OperationState.awaitingOutcome &&
                _due(record, _now(record)),
          )
          .toList();
      final results = List<ReconciliationResult?>.filled(records.length, null);
      var next = 0;
      Future<void> worker() async {
        while (next < records.length) {
          final index = next++;
          final identity = records[index].identity;
          try {
            results[index] = ReconciliationCompleted(await reconcile(identity));
          } catch (error, stackTrace) {
            results[index] = ReconciliationFailed(
              identity: identity,
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
      }

      final count = concurrency < records.length ? concurrency : records.length;
      await Future.wait([for (var index = 0; index < count; index++) worker()]);
      return List<ReconciliationResult>.unmodifiable(
        results.cast<ReconciliationResult>(),
      );
    });
  }

  Future<OperationRecord> _reconcile(OperationIdentity identity) async {
    final record = await _readRequired(identity);
    final at = _now(record);
    if (record.state != OperationState.awaitingOutcome || !_due(record, at)) {
      return record;
    }
    final handler = _handlers[identity.type];
    if (handler == null) {
      throw const InvalidOperationRegistrationException(
        'no handler for stored type',
      );
    }
    final policy = _policy;
    if (policy == null) throw StateError('Recovery policy is required');
    if (record.recovery.cycleAttempts >= policy.maxAttempts) {
      return _commit(record, _machine.pause(record, at: at));
    }
    final delay = policy.delayForAttempt(record.recovery.cycleAttempts + 1);
    final reserved = await _commit(
      record,
      _machine.reserveRecoveryAttempt(
        record,
        at: at,
        nextCheckAt: at.add(delay),
        attemptLimit: policy.maxAttempts,
      ),
    );
    _ensureOpen();
    final result = await _invoke(
      identity,
      HandlerAction.lookupStatus,
      () => handler._lookup(identity),
    );
    identity.requireMatch(result.observation.identity);
    final completedAt = _now(reserved);
    final saved = await _commit(
      reserved,
      _machine.completeRecoveryAttempt(
        reserved,
        result.observation,
        at: completedAt,
        nextCheckAt: completedAt.add(delay),
        attemptLimit: policy.maxAttempts,
      ),
    );
    if (result.failure != null) throw result.failure!;
    return saved;
  }

  Future<({BackendObservation observation, OperationHandlerException? failure})>
  _invoke(
    OperationIdentity identity,
    HandlerAction action,
    Future<BackendObservation> Function() call,
  ) async {
    // Only handler invocation belongs here. Storage/protocol failures must not
    // be caught as transport errors or trigger a second handler invocation.
    try {
      return (observation: await call(), failure: null);
    } on TimeoutException {
      return (
        observation: action == HandlerAction.submit
            ? OperationUnknown(identity: identity)
            : LookupUnavailable(
                identity: identity,
                reason: LookupFailureReason.transportFailure,
              ),
        failure: null,
      );
    } catch (error, stackTrace) {
      return (
        observation: OperationUnknown(identity: identity),
        failure: OperationHandlerException(
          action: action,
          cause: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// Creates prepared identity or returns its existing matching snapshot.
  Future<OperationRecord> prepare(
    OperationIdentity identity, {
    required DateTime at,
  }) async {
    _requireScope(identity);
    return _execute(identity.id, () => _prepare(identity, at: at));
  }

  Future<OperationRecord> _prepare(
    OperationIdentity identity, {
    required DateTime at,
  }) async {
    final prepared = OperationRecord.prepared(identity: identity, at: at);
    if (!await _store.createIfAbsent(prepared)) return _readRequired(identity);
    _events.add(OperationEvent(prepared));
    return prepared;
  }

  /// Reads scoped committed state, concealing foreign and missing records.
  Future<OperationRecord?> read(String id) => _execute(id, () => _read(id));

  /// Lists scoped snapshots without a global per-ID lock.
  Future<List<OperationRecord>> listUnresolved() =>
      _execute(null, _listUnresolved);

  Future<List<OperationRecord>> _listUnresolved() async =>
      List<OperationRecord>.unmodifiable(
        (await _store.listUnresolved(scope: scope)).where(
          (record) =>
              record.identity.scope == scope && record.state.isUnresolved,
        ),
      );

  /// Persists uncertainty without dispatch; retained for storage contract tests.
  Future<OperationRecord> persistUncertainty(
    OperationIdentity identity, {
    required DateTime at,
  }) => _mutate(
    identity,
    (record) => _machine.beginSubmission(record, identity: identity, at: at),
  );

  /// Records supplied evidence without lookup; retained as an internal action.
  Future<OperationRecord> applyObservation(
    BackendObservation observation, {
    required DateTime at,
  }) => _mutate(
    observation.identity,
    (record) => _machine.applyObservation(record, observation, at: at),
  );

  /// Persists the legal pause transition without claiming a final outcome.
  Future<OperationRecord> pause(
    OperationIdentity identity, {
    required DateTime at,
  }) => _mutate(identity, (record) => _machine.pause(record, at: at));

  /// Resets only the cycle budget and never dispatches a handler.
  Future<OperationRecord> resume(OperationIdentity identity, {DateTime? at}) =>
      _mutate(
        identity,
        (record) => _machine.resume(record, at: at ?? _now(record)),
      );

  void _requireScope(OperationIdentity identity) {
    _ensureOpen();
    if (identity.scope != scope) {
      throw const OperationIdentityConflictException();
    }
  }

  Future<OperationRecord?> _read(String id) async {
    final record = await _store.read(id: id, scope: scope);
    if (record == null || record.identity.scope != scope) return null;
    if (record.identity.id != id) throw const OperationStoreReadException();
    return record;
  }

  Future<OperationRecord> _readRequired(OperationIdentity identity) async {
    final record = await _read(identity.id);
    if (record == null) throw const OperationNotFoundException();
    record.identity.requireMatch(identity);
    return record;
  }

  Future<OperationRecord> _mutate(
    OperationIdentity identity,
    OperationRecord Function(OperationRecord) transition,
  ) async {
    _requireScope(identity);
    return _execute(identity.id, () async {
      final before = await _readRequired(identity);
      return _commit(before, transition(before));
    });
  }

  Future<OperationRecord> _commit(
    OperationRecord before,
    OperationRecord after,
  ) async {
    if (identical(before, after)) return before;
    if (!await _store.compareAndSwap(after, expectedVersion: before.version)) {
      throw OperationStoreConflictException(expectedVersion: before.version);
    }
    _events.add(OperationEvent(after));
    return after;
  }

  DateTime _now([OperationRecord? record]) {
    final now = _clock.now().toUtc();
    return record != null && now.isBefore(record.updatedAt)
        ? record.updatedAt
        : now;
  }

  bool _due(OperationRecord record, DateTime at) =>
      record.recovery.nextCheckAt == null ||
      !at.isBefore(record.recovery.nextCheckAt!);

  void _ensureOpen() {
    if (_closing) throw const OperationRecoveryClosedException();
  }

  Future<T> _execute<T>(String? id, Future<T> Function() action) {
    if (_closing) {
      return Future<T>.error(const OperationRecoveryClosedException());
    }
    final settled = Completer<void>();
    _jobs.add(settled.future);
    Future<T> run() async {
      try {
        return id == null ? await action() : await _serialize(id, action);
      } finally {
        _jobs.remove(settled.future);
        settled.complete();
      }
    }

    return run();
  }

  /// Stops new/queued work and drains active handlers and persistence.
  /// Does not cancel effects, close shared resources, or wait for paused listeners.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    final closed = Completer<void>();
    _closeFuture = closed.future;
    Future<void> drain() async {
      await Future.wait(_jobs.toList());
      unawaited(_events.close());
      closed.complete();
    }

    unawaited(drain());
    return closed.future;
  }

  Future<T> _serialize<T>(String id, Future<T> Function() action) async {
    final previous = _tails[id];
    final completed = Completer<void>();
    _tails[id] = completed.future;
    try {
      if (previous != null) await previous;
      _ensureOpen();
      return await action();
    } finally {
      if (identical(_tails[id], completed.future)) _tails.remove(id);
      completed.complete();
    }
  }
}
