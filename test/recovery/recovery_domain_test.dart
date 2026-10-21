import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/recovery_fixtures.dart';

void main() {
  test('bounded exponential backoff saturates for huge attempts', () {
    final policy = RecoveryPolicy(
      maxAttempts: 100,
      initialDelay: const Duration(microseconds: 3),
      maxDelay: const Duration(microseconds: 20),
    );
    expect(
      [for (var n = 1; n <= 6; n++) policy.delayForAttempt(n).inMicroseconds],
      [3, 6, 12, 20, 20, 20],
    );
    expect(
      policy.delayForAttempt(1000000000),
      const Duration(microseconds: 20),
    );
    expect(() => policy.delayForAttempt(0), throwsArgumentError);
  });

  for (final values in [
    (0, 1, 2),
    (-1, 1, 2),
    (1, 0, 2),
    (1, -1, 2),
    (1, 3, 2),
  ]) {
    test('invalid policy $values fails', () {
      expect(
        () => RecoveryPolicy(
          maxAttempts: values.$1,
          initialDelay: Duration(seconds: values.$2),
          maxDelay: Duration(seconds: values.$3),
        ),
        throwsArgumentError,
      );
    });
  }

  for (final counts in [(-1, 0), (2, 1), (0, -1)]) {
    test('invalid counters $counts fail', () {
      expect(
        () => RecoveryMetadata.restore(
          cycleAttempts: counts.$1,
          totalAttempts: counts.$2,
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }
  for (final total in [0, 1]) {
    test('reservation timestamp matches total count $total', () {
      expect(
        () => RecoveryMetadata.restore(
          cycleAttempts: 0,
          totalAttempts: total,
          lastAttemptAt: total == 0 ? epoch : null,
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }

  test('metadata restoration normalizes UTC', () {
    final local = DateTime(2026, 10, 20);
    final metadata = RecoveryMetadata.restore(
      cycleAttempts: 1,
      totalAttempts: 2,
      lastAttemptAt: local,
      nextCheckAt: local.add(const Duration(seconds: 1)),
    );
    expect(metadata.lastAttemptAt!.isUtc, isTrue);
    expect(metadata.nextCheckAt!.isUtc, isTrue);
    expect(metadata.lastAttemptAt, local.toUtc());
  });

  for (final state in OperationState.values) {
    test('reservation action enforces state ${state.name}', () {
      final record = recordIn(state);
      OperationRecord reserve() => machine.reserveRecoveryAttempt(
        record,
        at: epoch.add(const Duration(seconds: 10)),
        nextCheckAt: epoch.add(const Duration(seconds: 12)),
        attemptLimit: 3,
      );
      if (state == OperationState.awaitingOutcome) {
        final after = reserve();
        expect(after.version, record.version + 1);
        expect(after.recovery.totalAttempts, 1);
        expect(after.recovery.cycleAttempts, 1);
        expect(
          restoreRecord(after).recovery.lastAttemptAt,
          after.recovery.lastAttemptAt,
        );
      } else {
        expect(reserve, throwsA(isA<IllegalOperationTransitionException>()));
      }
    });
  }

  for (final outcome in ['pending', 'unknown', 'auth', 'success', 'rejected']) {
    test('last attempt completes atomically for $outcome', () {
      final before = recordIn(OperationState.awaitingOutcome);
      final at = epoch.add(const Duration(seconds: 10));
      final reserved = machine.reserveRecoveryAttempt(
        before,
        at: at,
        nextCheckAt: at.add(const Duration(seconds: 2)),
        attemptLimit: 1,
      );
      final observation = switch (outcome) {
        'pending' => OperationPending(identity: identity()),
        'unknown' => OperationUnknown(identity: identity()),
        'auth' => LookupUnavailable(
          identity: identity(),
          reason: LookupFailureReason.authenticationRequired,
        ),
        'success' => OperationSucceeded(identity: identity()),
        _ => OperationRejected(identity: identity()),
      };
      final after = machine.completeRecoveryAttempt(
        reserved,
        observation,
        at: at,
        nextCheckAt: at.add(const Duration(seconds: 2)),
        attemptLimit: 1,
      );
      expect(after.version, reserved.version + 1);
      expect(
        after.state,
        outcome == 'success'
            ? OperationState.succeeded
            : outcome == 'rejected'
            ? OperationState.rejected
            : OperationState.needsAttention,
      );
      expect(after.recovery.nextCheckAt, isNull);
      expect(after.lastObservation, same(observation));
      if (after.state == OperationState.needsAttention) {
        final resumed = machine.resume(after, at: at);
        expect(resumed.recovery.cycleAttempts, 0);
        expect(resumed.recovery.totalAttempts, 1);
        expect(resumed.recovery.lastAttemptAt, reserved.recovery.lastAttemptAt);
        expect(resumed.recovery.nextCheckAt, at);
      }
    });
  }

  test('reservation enforces due time, budget and positive delay', () {
    final before = recordIn(OperationState.awaitingOutcome);
    final at = epoch.add(const Duration(seconds: 10));
    final reserved = machine.reserveRecoveryAttempt(
      before,
      at: at,
      nextCheckAt: at.add(const Duration(seconds: 2)),
      attemptLimit: 1,
    );
    expect(
      () => machine.reserveRecoveryAttempt(
        reserved,
        at: at,
        nextCheckAt: at.add(const Duration(seconds: 2)),
        attemptLimit: 3,
      ),
      throwsA(isA<IllegalOperationTransitionException>()),
    );
    expect(
      () => machine.reserveRecoveryAttempt(
        reserved,
        at: at.add(const Duration(seconds: 2)),
        nextCheckAt: at.add(const Duration(seconds: 4)),
        attemptLimit: 1,
      ),
      throwsA(isA<IllegalOperationTransitionException>()),
    );
    expect(
      () => machine.reserveRecoveryAttempt(
        before,
        at: at,
        nextCheckAt: at,
        attemptLimit: 3,
      ),
      throwsA(isA<InvalidOperationRecordException>()),
    );
    expect(
      () => machine.completeRecoveryAttempt(
        before,
        OperationPending(identity: identity()),
        at: at,
        nextCheckAt: at.add(const Duration(seconds: 2)),
        attemptLimit: 3,
      ),
      throwsA(isA<IllegalOperationTransitionException>()),
    );
  });

  for (final state in [
    OperationState.prepared,
    OperationState.succeeded,
    OperationState.rejected,
    OperationState.needsAttention,
  ]) {
    test('restoration rejects scheduled ${state.name}', () {
      final record = recordIn(state);
      expect(
        () => OperationRecord.restore(
          identity: record.identity,
          state: state,
          version: record.version,
          createdAt: record.createdAt,
          updatedAt: record.updatedAt,
          lastObservation: record.lastObservation,
          recovery: RecoveryMetadata.restore(
            cycleAttempts: 0,
            totalAttempts: 0,
            nextCheckAt: epoch,
          ),
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }

  for (final at in [
    epoch.subtract(const Duration(seconds: 1)),
    epoch.add(const Duration(seconds: 100)),
  ]) {
    test('restoration rejects out-of-record reservation time $at', () {
      expect(
        () => OperationRecord.restore(
          identity: identity(),
          state: OperationState.awaitingOutcome,
          version: 3,
          createdAt: epoch,
          updatedAt: epoch.add(const Duration(seconds: 10)),
          recovery: RecoveryMetadata.restore(
            cycleAttempts: 1,
            totalAttempts: 1,
            lastAttemptAt: at,
          ),
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }

  test('system clock is UTC and fake clock advances deterministically', () {
    expect(const SystemClock().now().isUtc, isTrue);
    final clock = FakeClock(epoch)..advance(const Duration(seconds: 3));
    expect(clock.now(), epoch.add(const Duration(seconds: 3)));
  });
}
