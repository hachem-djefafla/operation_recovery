import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test('prepared construction is immutable version-zero domain data', () {
    final operationIdentity = identity();
    final record = OperationRecord.prepared(
      identity: operationIdentity,
      at: epoch,
    );
    expect(record.identity, same(operationIdentity));
    expect(record.state, OperationState.prepared);
    expect(record.version, 0);
    expect(record.createdAt, epoch);
    expect(record.updatedAt, epoch);
    expect(record.lastObservation, isNull);
  });

  test('prepared timestamps normalize to UTC', () {
    final localTime = DateTime(2026, 10, 20, 12);
    final record = OperationRecord.prepared(
      identity: identity(),
      at: localTime,
    );
    expect(localTime.isUtc, isFalse);
    expect(record.createdAt.isUtc, isTrue);
    expect(record.updatedAt.isUtc, isTrue);
    expect(record.createdAt, localTime.toUtc());
  });

  for (final state in OperationState.values) {
    test('${state.name} round-trips through structural restoration', () {
      final record = recordIn(state);
      final restored = restoreRecord(record);
      expect(restored, isNot(same(record)));
      expect(restored.identity, record.identity);
      expect(restored.state, record.state);
      expect(restored.version, record.version);
      expect(restored.createdAt, record.createdAt);
      expect(restored.updatedAt, record.updatedAt);
      expect(restored.lastObservation, same(record.lastObservation));
    });

    test('${state.name} terminal classification', () {
      final isFinal = {
        OperationState.succeeded,
        OperationState.rejected,
      }.contains(state);
      expect(state.isTerminal, isFinal);
      expect(state.isUnresolved, !isFinal);
    });

    test('${state.name} rejects negative restored version', () {
      final record = recordIn(state);
      expect(
        () => OperationRecord.restore(
          identity: record.identity,
          state: state,
          version: -1,
          createdAt: record.createdAt,
          updatedAt: record.updatedAt,
          lastObservation: record.lastObservation,
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });

    test('${state.name} rejects update before creation', () {
      final record = recordIn(state);
      expect(
        () => OperationRecord.restore(
          identity: record.identity,
          state: state,
          version: record.version,
          createdAt: epoch,
          updatedAt: epoch.subtract(const Duration(seconds: 1)),
          lastObservation: record.lastObservation,
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }

  test('restoration normalizes both timestamps to UTC', () {
    final created = DateTime(2026, 10, 20, 12);
    final updated = created.add(const Duration(minutes: 1));
    final record = OperationRecord.restore(
      identity: identity(),
      state: OperationState.awaitingOutcome,
      version: 1,
      createdAt: created,
      updatedAt: updated,
    );
    expect(record.createdAt.isUtc, isTrue);
    expect(record.updatedAt.isUtc, isTrue);
    expect(record.createdAt, created.toUtc());
    expect(record.updatedAt, updated.toUtc());
  });

  test('prepared update time cannot differ from creation time', () {
    expect(
      () => OperationRecord.restore(
        identity: identity(),
        state: OperationState.prepared,
        version: 0,
        createdAt: epoch,
        updatedAt: epoch.add(const Duration(seconds: 1)),
      ),
      throwsA(isA<InvalidOperationRecordException>()),
    );
  });

  final operationIdentity = identity();
  final observations = <String, BackendObservation?>{
    'absent': null,
    'success': OperationSucceeded(identity: operationIdentity),
    'rejection': OperationRejected(identity: operationIdentity),
    'pending': OperationPending(identity: operationIdentity),
    'unknown': OperationUnknown(identity: operationIdentity),
    'authenticationRequired': LookupUnavailable(
      identity: operationIdentity,
      reason: LookupFailureReason.authenticationRequired,
    ),
  };
  final validObservations = <OperationState, Set<String>>{
    OperationState.prepared: {'absent'},
    OperationState.awaitingOutcome: {
      'absent',
      'pending',
      'unknown',
      'authenticationRequired',
    },
    OperationState.succeeded: {'success'},
    OperationState.rejected: {'rejection'},
    OperationState.needsAttention: {
      'absent',
      'pending',
      'unknown',
      'authenticationRequired',
    },
  };
  for (final state in OperationState.values) {
    for (final entry in observations.entries) {
      test('restore ${state.name} with ${entry.key}', () {
        OperationRecord restore() => OperationRecord.restore(
          identity: operationIdentity,
          state: state,
          version: state == OperationState.prepared ? 0 : 10,
          createdAt: epoch,
          updatedAt: epoch,
          lastObservation: entry.value,
        );
        if (validObservations[state]!.contains(entry.key)) {
          expect(restore().lastObservation, same(entry.value));
        } else {
          expect(restore, throwsA(isA<InvalidOperationRecordException>()));
        }
      });
    }
  }

  final invalidVersions = <(OperationState, int, BackendObservation?)>[
    (OperationState.prepared, 1, null),
    (OperationState.awaitingOutcome, 0, null),
    (
      OperationState.awaitingOutcome,
      1,
      OperationUnknown(identity: operationIdentity),
    ),
    (
      OperationState.succeeded,
      1,
      OperationSucceeded(identity: operationIdentity),
    ),
    (
      OperationState.rejected,
      1,
      OperationRejected(identity: operationIdentity),
    ),
    (OperationState.needsAttention, 1, null),
    (
      OperationState.needsAttention,
      2,
      OperationUnknown(identity: operationIdentity),
    ),
  ];
  for (var index = 0; index < invalidVersions.length; index++) {
    final (state, version, observation) = invalidVersions[index];
    test('reject inconsistent restored version case $index', () {
      expect(
        () => OperationRecord.restore(
          identity: operationIdentity,
          state: state,
          version: version,
          createdAt: epoch,
          updatedAt: epoch,
          lastObservation: observation,
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }

  for (final entry in <String, OperationIdentity>{
    'id': identity(id: 'another-id'),
    'scope': identity(scope: 'another-scope'),
    'type': identity(type: 'another-type'),
    'key': identity(idempotencyKey: 'another-key'),
    'fingerprint': identity(requestFingerprint: 'another-fingerprint'),
  }.entries) {
    test('restoration rejects observation with different ${entry.key}', () {
      expect(
        () => OperationRecord.restore(
          identity: operationIdentity,
          state: OperationState.awaitingOutcome,
          version: 2,
          createdAt: epoch,
          updatedAt: epoch,
          lastObservation: OperationUnknown(identity: entry.value),
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }

  test('default snapshot string includes only state and version', () {
    final record = recordIn(OperationState.succeeded);
    expect(record.toString(), 'OperationRecord(state: succeeded, version: 2)');
  });
}
