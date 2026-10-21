import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../../../../test/support/fixtures.dart';
import '../../../../test/support/storage_fixtures.dart';
import 'package:operation_recovery_sqlite_example/src/record_codec.dart';

Map<String, Object?> encoded(OperationRecord record) =>
    Map.fromIterables(recordColumns, encodeRecord(record));

void main() {
  for (final state in OperationState.values) {
    test('version-one round trip for ${state.name}', () {
      final record = recordIn(state);
      expectSnapshot(decodeRecord(encoded(record)), record);
    });
  }
  for (final observation in <BackendObservation>[
    OperationSucceeded(identity: identity(), backendReference: 'opaque-123'),
    OperationRejected(identity: identity(), code: 'declined'),
    OperationPending(identity: identity()),
    OperationUnknown(identity: identity()),
    for (final reason in LookupFailureReason.values)
      LookupUnavailable(identity: identity(), reason: reason),
  ]) {
    test(
      'round trip ${observation.runtimeType} ${observation is LookupUnavailable ? observation.reason : ''}',
      () {
        final original = recordIn(OperationState.awaitingOutcome);
        final reserved = machine.reserveRecoveryAttempt(
          original,
          at: original.updatedAt,
          nextCheckAt: original.updatedAt.add(const Duration(seconds: 1)),
          attemptLimit: 3,
        );
        final completed = machine.completeRecoveryAttempt(
          reserved,
          observation,
          at: reserved.updatedAt,
          nextCheckAt: reserved.updatedAt.add(const Duration(seconds: 1)),
          attemptLimit: 3,
        );
        expectSnapshot(decodeRecord(encoded(completed)), completed);
      },
    );
  }

  test(
    'reservation, pause, and resumed counters round trip without defaults',
    () {
      final awaiting = recordIn(OperationState.awaitingOutcome);
      final reserved = machine.reserveRecoveryAttempt(
        awaiting,
        at: awaiting.updatedAt,
        nextCheckAt: awaiting.updatedAt.add(const Duration(seconds: 2)),
        attemptLimit: 2,
      );
      expectSnapshot(decodeRecord(encoded(reserved)), reserved);
      final paused = machine.pause(reserved, at: reserved.updatedAt);
      final resumed = machine.resume(paused, at: paused.updatedAt);
      expectSnapshot(decodeRecord(encoded(paused)), paused);
      expectSnapshot(decodeRecord(encoded(resumed)), resumed);
      expect(resumed.recovery.cycleAttempts, 0);
      expect(resumed.recovery.totalAttempts, 1);
    },
  );

  test('UTF-8 identity and UTC microsecond timestamps retain exact values', () {
    final prepared = OperationRecord.prepared(
      identity: identity(id: " op-é-東京-' "),
      at: DateTime.fromMicrosecondsSinceEpoch(-1234567, isUtc: true),
    );
    expectSnapshot(decodeRecord(encoded(prepared)), prepared);
  });

  test('unpaired surrogate cannot be silently replaced during encoding', () {
    final prepared = OperationRecord.prepared(
      identity: identity(id: String.fromCharCode(0xd800)),
      at: epoch,
    );
    expect(
      () => encodeRecord(prepared),
      throwsA(isA<InvalidOperationRecordException>()),
    );
  });

  for (final column in recordColumns) {
    test('missing $column is rejected even when nullable', () {
      final row = encoded(recordIn(OperationState.prepared))..remove(column);
      expect(
        () => decodeRecord(row),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
    if (!nullableColumns.contains(column)) {
      test('null $column is never defaulted', () {
        final row = encoded(recordIn(OperationState.prepared))..[column] = null;
        expect(
          () => decodeRecord(row),
          throwsA(isA<InvalidOperationRecordException>()),
        );
      });
    }
  }
  final corruptions = <String, Object?>{
    'record_schema_version': 2,
    'state': 'future_state',
    'record_version': -1,
    'created_at_us': '2026-10-20',
    'updated_at_us': 9223372036854775807,
    'cycle_attempts': 1,
    'total_attempts': -1,
    'observation_kind': 'future_observation',
    'backend_reference': 'unexpected',
    'rejection_code': 'unexpected',
    'lookup_failure_reason': 'future_reason',
    'next_check_at_us': 123,
  };
  for (final corruption in corruptions.entries) {
    test('corrupt ${corruption.key} fails with a safe description', () {
      final row = encoded(recordIn(OperationState.prepared))
        ..[corruption.key] = corruption.value;
      expect(
        () => decodeRecord(row),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }
  test(
    'unavailable requires a known reason; state must agree with evidence',
    () {
      final row = encoded(recordIn(OperationState.awaitingOutcome))
        ..['observation_kind'] = 'unavailable'
        ..['record_version'] = 2;
      expect(
        () => decodeRecord(row),
        throwsA(isA<InvalidOperationRecordException>()),
      );
      row['lookup_failure_reason'] = 'authentication_required';
      expect(decodeRecord(row).lastObservation, isA<LookupUnavailable>());
      row['state'] = 'succeeded';
      expect(
        () => decodeRecord(row),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    },
  );
}
