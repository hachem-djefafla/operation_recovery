import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

typedef _ActionCase = ({
  String name,
  OperationRecord Function(OperationRecord, DateTime) apply,
  Map<OperationState, OperationState> allowed,
  Set<OperationState> contradictory,
});

void main() {
  final cases = <_ActionCase>[
    (
      name: 'beginSubmission',
      apply: (record, at) =>
          machine.beginSubmission(record, identity: identity(), at: at),
      allowed: {OperationState.prepared: OperationState.awaitingOutcome},
      contradictory: {},
    ),
    (
      name: 'pause',
      apply: (record, at) => machine.pause(record, at: at),
      allowed: {OperationState.awaitingOutcome: OperationState.needsAttention},
      contradictory: {},
    ),
    (
      name: 'resume',
      apply: (record, at) => machine.resume(record, at: at),
      allowed: {OperationState.needsAttention: OperationState.awaitingOutcome},
      contradictory: {},
    ),
    (
      name: 'success',
      apply: (record, at) => machine.applyObservation(
        record,
        OperationSucceeded(identity: identity(), backendReference: 'tx-987'),
        at: at,
      ),
      allowed: {
        OperationState.awaitingOutcome: OperationState.succeeded,
        OperationState.succeeded: OperationState.succeeded,
      },
      contradictory: {OperationState.rejected},
    ),
    (
      name: 'rejection',
      apply: (record, at) => machine.applyObservation(
        record,
        OperationRejected(identity: identity(), code: 'declined'),
        at: at,
      ),
      allowed: {
        OperationState.awaitingOutcome: OperationState.rejected,
        OperationState.rejected: OperationState.rejected,
      },
      contradictory: {OperationState.succeeded},
    ),
    for (final entry in <String, BackendObservation>{
      'pending': OperationPending(identity: identity()),
      'unknown': OperationUnknown(identity: identity()),
      for (final reason in LookupFailureReason.values)
        reason.name: LookupUnavailable(identity: identity(), reason: reason),
    }.entries)
      (
        name: entry.key,
        apply: (record, at) =>
            machine.applyObservation(record, entry.value, at: at),
        allowed: {
          OperationState.awaitingOutcome: OperationState.awaitingOutcome,
          OperationState.succeeded: OperationState.succeeded,
          OperationState.rejected: OperationState.rejected,
        },
        contradictory: {},
      ),
  ];

  group('exhaustive state/action contract', () {
    for (final state in OperationState.values) {
      for (final action in cases) {
        test('${state.name} + ${action.name}', () {
          final before = recordIn(state);
          final oldVersion = before.version;
          final oldTime = before.updatedAt;
          final oldObservation = before.lastObservation;
          final at = epoch.add(const Duration(hours: 1));
          final expected = action.allowed[state];
          if (expected != null) {
            final after = action.apply(before, at);
            expect(after.state, expected);
            expect(after.identity, same(before.identity));
            expect(after.createdAt, before.createdAt);
            if (state.isTerminal) {
              expect(after, same(before));
            } else {
              expect(after, isNot(same(before)));
              expect(after.version, oldVersion + 1);
              expect(after.updatedAt, at);
            }
          } else if (action.contradictory.contains(state)) {
            expect(
              () => action.apply(before, at),
              throwsA(isA<ContradictoryBackendObservationException>()),
            );
          } else {
            expect(
              () => action.apply(before, at),
              throwsA(
                isA<IllegalOperationTransitionException>().having(
                  (error) => error.state,
                  'state',
                  state,
                ),
              ),
            );
          }
          expect(before.state, state);
          expect(before.version, oldVersion);
          expect(before.updatedAt, oldTime);
          expect(before.lastObservation, same(oldObservation));
        });
      }
    }
  });

  final mismatches = <String, OperationIdentity>{
    'id': identity(id: 'different'),
    'scope': identity(scope: 'different'),
    'type': identity(type: 'different'),
    'key': identity(idempotencyKey: 'different'),
    'fingerprint': identity(requestFingerprint: 'different'),
  };
  for (final entry in mismatches.entries) {
    test('beginSubmission rejects different ${entry.key}', () {
      final record = recordIn(OperationState.prepared);
      expect(
        () => machine.beginSubmission(record, identity: entry.value, at: epoch),
        throwsA(isA<OperationIdentityConflictException>()),
      );
      expect(record.state, OperationState.prepared);
      expect(record.version, 0);
    });

    for (final state in OperationState.values) {
      test('${state.name} validates observation ${entry.key} before state', () {
        final record = recordIn(state);
        expect(
          () => machine.applyObservation(
            record,
            OperationUnknown(identity: entry.value),
            at: epoch.subtract(const Duration(days: 1)),
          ),
          throwsA(isA<OperationIdentityConflictException>()),
        );
      });
    }
  }

  test(
    'expired authentication remains recoverable through pause and resume',
    () {
      final initial = recordIn(OperationState.awaitingOutcome);
      final unavailable = LookupUnavailable(
        identity: initial.identity,
        reason: LookupFailureReason.authenticationRequired,
      );
      final blocked = machine.applyObservation(
        initial,
        unavailable,
        at: epoch.add(const Duration(seconds: 3)),
      );
      expect(blocked.state, OperationState.awaitingOutcome);
      expect(blocked.state.isUnresolved, isTrue);
      expect(blocked.lastObservation, same(unavailable));
      final paused = machine.pause(
        blocked,
        at: epoch.add(const Duration(seconds: 4)),
      );
      expect(paused.state.isUnresolved, isTrue);
      expect(paused.lastObservation, same(unavailable));
      final resumed = machine.resume(
        paused,
        at: epoch.add(const Duration(seconds: 5)),
      );
      expect(resumed.lastObservation, same(unavailable));
      final confirmed = machine.applyObservation(
        resumed,
        OperationSucceeded(
          identity: identity(),
          backendReference: 'tx-auth-restored',
        ),
        at: epoch.add(const Duration(seconds: 6)),
      );
      expect(confirmed.state, OperationState.succeeded);
      expect(confirmed.version, initial.version + 4);
    },
  );

  test('pending evidence replaces outdated authentication information', () {
    final blocked = machine.applyObservation(
      recordIn(OperationState.awaitingOutcome),
      LookupUnavailable(
        identity: identity(),
        reason: LookupFailureReason.authenticationRequired,
      ),
      at: epoch.add(const Duration(seconds: 3)),
    );
    final pending = OperationPending(identity: identity());
    final after = machine.applyObservation(
      blocked,
      pending,
      at: epoch.add(const Duration(seconds: 4)),
    );
    expect(after.state, OperationState.awaitingOutcome);
    expect(after.lastObservation, same(pending));
  });

  for (final state in [OperationState.succeeded, OperationState.rejected]) {
    for (final observation in [
      OperationPending(identity: identity()),
      OperationUnknown(identity: identity()),
      for (final reason in LookupFailureReason.values)
        LookupUnavailable(identity: identity(), reason: reason),
    ]) {
      for (final stale in [true, false]) {
        test(
          '${state.name} ignores ${observation.runtimeType} stale=$stale '
          '${observation is LookupUnavailable ? observation.reason.name : ''}',
          () {
            final confirmed = recordIn(state);
            final at = stale
                ? epoch.subtract(const Duration(days: 1))
                : epoch.add(const Duration(days: 1));
            expect(
              machine.applyObservation(confirmed, observation, at: at),
              same(confirmed),
            );
          },
        );
      }
    }

    test(
      '${state.name} rejects contradictory outcome even with stale time',
      () {
        final confirmed = recordIn(state);
        final opposite = state == OperationState.succeeded
            ? OperationRejected(identity: identity())
            : OperationSucceeded(identity: identity());
        expect(
          () => machine.applyObservation(
            confirmed,
            opposite,
            at: epoch.subtract(const Duration(days: 1)),
          ),
          throwsA(
            isA<ContradictoryBackendObservationException>()
                .having(
                  (error) => error.confirmedState,
                  'confirmedState',
                  state,
                )
                .having(
                  (error) => error.observedState,
                  'observedState',
                  state == OperationState.succeeded
                      ? OperationState.rejected
                      : OperationState.succeeded,
                ),
          ),
        );
        expect(confirmed.state, state);
        expect(confirmed.version, 2);
      },
    );

    test('${state.name} rejects conflicting non-null final metadata', () {
      final confirmed = recordIn(state);
      final conflicting = state == OperationState.succeeded
          ? OperationSucceeded(
              identity: identity(),
              backendReference: 'different-tx',
            )
          : OperationRejected(identity: identity(), code: 'different-code');
      expect(
        () => machine.applyObservation(confirmed, conflicting, at: epoch),
        throwsA(
          isA<ContradictoryBackendObservationException>()
              .having((error) => error.confirmedState, 'confirmedState', state)
              .having((error) => error.observedState, 'observedState', state),
        ),
      );
    });

    test('${state.name} missing metadata does not contradict confirmation', () {
      final confirmed = recordIn(state);
      final withoutMetadata = state == OperationState.succeeded
          ? OperationSucceeded(identity: identity())
          : OperationRejected(identity: identity());
      expect(
        machine.applyObservation(confirmed, withoutMetadata, at: epoch),
        same(confirmed),
      );
    });

    test('${state.name} duplicate cannot enrich immutable final metadata', () {
      final awaiting = recordIn(OperationState.awaitingOutcome);
      final withoutMetadata = state == OperationState.succeeded
          ? OperationSucceeded(identity: identity())
          : OperationRejected(identity: identity());
      final confirmed = machine.applyObservation(
        awaiting,
        withoutMetadata,
        at: epoch.add(const Duration(seconds: 2)),
      );
      final enriched = state == OperationState.succeeded
          ? OperationSucceeded(
              identity: identity(),
              backendReference: 'new-ref',
            )
          : OperationRejected(identity: identity(), code: 'new-code');
      final after = machine.applyObservation(confirmed, enriched, at: epoch);
      expect(after, same(confirmed));
      expect(after.lastObservation, same(withoutMetadata));
    });
  }

  final timedActions = <String, OperationRecord Function(DateTime)>{
    'beginSubmission': (at) => machine.beginSubmission(
      recordIn(OperationState.prepared),
      identity: identity(),
      at: at,
    ),
    'observation': (at) => machine.applyObservation(
      recordIn(OperationState.awaitingOutcome),
      OperationUnknown(identity: identity()),
      at: at,
    ),
    'pause': (at) =>
        machine.pause(recordIn(OperationState.awaitingOutcome), at: at),
    'resume': (at) =>
        machine.resume(recordIn(OperationState.needsAttention), at: at),
  };
  for (final entry in timedActions.entries) {
    test('${entry.key} rejects time regression', () {
      expect(
        () => entry.value(epoch.subtract(const Duration(seconds: 1))),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
    test('${entry.key} normalizes accepted time to UTC', () {
      final localTime = DateTime(2026, 10, 21);
      final after = entry.value(localTime);
      expect(after.updatedAt.isUtc, isTrue);
      expect(after.updatedAt, localTime.toUtc());
    });
  }

  test('same instant is a valid update and still advances version', () {
    final awaiting = recordIn(OperationState.awaitingOutcome);
    final after = machine.applyObservation(
      awaiting,
      OperationUnknown(identity: identity()),
      at: awaiting.updatedAt,
    );
    expect(after.version, awaiting.version + 1);
    expect(after.updatedAt, awaiting.updatedAt);
  });
}
