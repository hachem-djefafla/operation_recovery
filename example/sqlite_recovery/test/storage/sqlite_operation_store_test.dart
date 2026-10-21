import 'dart:io';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:operation_recovery_sqlite_example/sqlite_operation_store.dart';
import 'package:test/test.dart';

import '../../../../test/storage/operation_store_contract.dart';
import '../../../../test/support/fixtures.dart';
import '../../../../test/support/storage_fixtures.dart';
import '../support/database_fixture.dart';

void main() {
  operationStoreContract(
    'SqliteOperationStore contract',
    () => DatabaseFixture().store,
  );

  test('IDs and scopes use exact case-sensitive comparisons', () async {
    final fixture = DatabaseFixture();
    final lower = OperationRecord.prepared(
      identity: identity(id: 'operation'),
      at: epoch,
    );
    final upper = OperationRecord.prepared(
      identity: identity(id: 'OPERATION'),
      at: epoch,
    );
    expect(await fixture.store.createIfAbsent(lower), isTrue);
    expect(await fixture.store.createIfAbsent(upper), isTrue);
    expectSnapshot(
      await fixture.store.read(
        id: lower.identity.id,
        scope: lower.identity.scope,
      ),
      lower,
    );
    expect(
      await fixture.store.read(
        id: lower.identity.id,
        scope: lower.identity.scope.toUpperCase(),
      ),
      isNull,
    );
    expect(
      await fixture.store.listUnresolved(
        scope: lower.identity.scope.toUpperCase(),
      ),
      isEmpty,
    );
    fixture.reopen();
    expectSnapshot(
      await fixture.store.read(
        id: upper.identity.id,
        scope: upper.identity.scope,
      ),
      upper,
    );
  });

  test('effective WAL/FULL is verified on creation and each reopening', () {
    final fixture = DatabaseFixture();
    for (var count = 0; count < 5; count++) {
      fixture.reopen();
      expect(fixture.store.configuration['journal_mode'], 'wal');
      expect(fixture.store.configuration['synchronous'], 2);
      expect(fixture.store.configuration['busy_timeout'], 5000);
      fixture.sql((db) {
        expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');
        // synchronous is per connection; the adapter configures its own connection.
        expect(db.select('PRAGMA user_version').single.values.single, 1);
        expect(
          db.select('PRAGMA application_id').single.values.single,
          0x4f524543,
        );
      });
    }
  });

  for (final state in OperationState.values) {
    test(
      'persisted ${state.name} survives repeated connection reopening',
      () async {
        final fixture = DatabaseFixture();
        final record = await seedState(fixture.store, state);
        for (var count = 0; count < 4; count++) {
          fixture.reopen();
          expectSnapshot(
            await fixture.store.read(
              id: identity().id,
              scope: identity().scope,
            ),
            record,
          );
        }
      },
    );
  }

  test('reservation and resumed metadata persist atomically', () async {
    final fixture = DatabaseFixture();
    final awaiting = await seedState(
      fixture.store,
      OperationState.awaitingOutcome,
    );
    final reserved = machine.reserveRecoveryAttempt(
      awaiting,
      at: awaiting.updatedAt,
      nextCheckAt: awaiting.updatedAt.add(const Duration(seconds: 3)),
      attemptLimit: 3,
    );
    expect(
      await fixture.store.compareAndSwap(
        reserved,
        expectedVersion: awaiting.version,
      ),
      isTrue,
    );
    fixture.reopen();
    expectSnapshot(
      await fixture.store.read(id: identity().id, scope: identity().scope),
      reserved,
    );
    final attention = machine.pause(reserved, at: reserved.updatedAt);
    await fixture.store.compareAndSwap(
      attention,
      expectedVersion: reserved.version,
    );
    final resumed = machine.resume(attention, at: attention.updatedAt);
    await fixture.store.compareAndSwap(
      resumed,
      expectedVersion: attention.version,
    );
    fixture.reopen();
    expectSnapshot(
      await fixture.store.read(id: identity().id, scope: identity().scope),
      resumed,
    );
  });

  for (final observation in <BackendObservation>[
    OperationSucceeded(
      identity: identity(),
      backendReference: 'opaque-reference',
    ),
    OperationRejected(identity: identity(), code: 'declined'),
    OperationPending(identity: identity()),
    OperationUnknown(identity: identity()),
    for (final reason in LookupFailureReason.values)
      LookupUnavailable(identity: identity(), reason: reason),
  ]) {
    test(
      'SQLite observation/reservation reopen: ${observation.runtimeType} ${observation is LookupUnavailable ? observation.reason : ''}',
      () async {
        final fixture = DatabaseFixture();
        final awaiting = await seedState(
          fixture.store,
          OperationState.awaitingOutcome,
        );
        final reserved = machine.reserveRecoveryAttempt(
          awaiting,
          at: awaiting.updatedAt,
          nextCheckAt: awaiting.updatedAt.add(const Duration(seconds: 1)),
          attemptLimit: 3,
        );
        expect(
          await fixture.store.compareAndSwap(
            reserved,
            expectedVersion: awaiting.version,
          ),
          isTrue,
        );
        final completed = machine.completeRecoveryAttempt(
          reserved,
          observation,
          at: reserved.updatedAt,
          nextCheckAt: reserved.updatedAt.add(const Duration(seconds: 1)),
          attemptLimit: 3,
        );
        expect(
          await fixture.store.compareAndSwap(
            completed,
            expectedVersion: reserved.version,
          ),
          isTrue,
        );
        fixture.reopen();
        expectSnapshot(
          await fixture.store.read(id: identity().id, scope: identity().scope),
          completed,
        );
      },
    );
  }

  test(
    'actual SQLite rollback leaves snapshot and reservation unchanged',
    () async {
      final fixture = DatabaseFixture();
      final original = await seedState(
        fixture.store,
        OperationState.awaitingOutcome,
      );
      final next = machine.reserveRecoveryAttempt(
        original,
        at: original.updatedAt,
        nextCheckAt: original.updatedAt.add(const Duration(seconds: 1)),
        attemptLimit: 3,
      );
      fixture.sql(
        (db) => db.execute('''
CREATE TRIGGER reject_update AFTER UPDATE ON operations
BEGIN SELECT RAISE(ROLLBACK, 'test rollback'); END;
'''),
      );
      await expectLater(
        fixture.store.compareAndSwap(next, expectedVersion: original.version),
        throwsA(
          isA<OperationStoreWriteException>().having(
            (error) => error.commitStatus,
            'status',
            StoreCommitStatus.notCommitted,
          ),
        ),
      );
      expectSnapshot(
        await fixture.store.read(id: identity().id, scope: identity().scope),
        original,
      );
      fixture.sql((db) => db.execute('DROP TRIGGER reject_update'));
      expect(
        await fixture.store.compareAndSwap(
          next,
          expectedVersion: original.version,
        ),
        isTrue,
      );
      fixture.reopen();
      expectSnapshot(
        await fixture.store.read(id: identity().id, scope: identity().scope),
        next,
      );
    },
  );

  test(
    'foreign corrupt records remain concealed and excluded from own listing',
    () async {
      final fixture = DatabaseFixture();
      final original = await seedState(fixture.store, OperationState.prepared);
      fixture.sql(
        (db) => db.execute('UPDATE operations SET record_schema_version = 99'),
      );
      expect(
        await fixture.store.read(id: original.identity.id, scope: 'foreign'),
        isNull,
      );
      expect(await fixture.store.listUnresolved(scope: 'foreign'), isEmpty);
      await expectLater(
        fixture.store.read(
          id: original.identity.id,
          scope: original.identity.scope,
        ),
        throwsA(isA<InvalidOperationRecordException>()),
      );
      await expectLater(
        fixture.store.createIfAbsent(original),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    },
  );

  for (final sql in [
    "UPDATE operations SET state = 'future'",
    'UPDATE operations SET record_version = -1',
    'UPDATE operations SET cycle_attempts = 1',
    "UPDATE operations SET observation_kind = 'succeeded'",
    "UPDATE operations SET lookup_failure_reason = 'future'",
    'UPDATE operations SET record_schema_version = 99',
  ]) {
    test('corrupt row fails reads/listing after reopening: $sql', () async {
      final fixture = DatabaseFixture();
      await seedState(fixture.store, OperationState.prepared);
      fixture.sql((db) {
        db.execute('PRAGMA ignore_check_constraints = ON');
        db.execute(sql);
      });
      fixture.reopen();
      await expectLater(
        fixture.store.read(id: identity().id, scope: identity().scope),
        throwsA(isA<InvalidOperationRecordException>()),
      );
      await expectLater(
        fixture.store.listUnresolved(scope: identity().scope),
        throwsA(isA<InvalidOperationRecordException>()),
      );
    });
  }

  for (final sql in [
    'PRAGMA user_version = 2',
    'PRAGMA application_id = 123',
    'DROP INDEX operations_by_scope',
    'ALTER TABLE operations ADD COLUMN unexpected TEXT',
  ]) {
    test('unsupported or malformed schema is never repaired: $sql', () {
      final fixture = DatabaseFixture();
      fixture.store.close();
      fixture.sql((db) => db.execute(sql));
      expect(
        () => SqliteOperationStore.open(fixture.path),
        throwsA(isA<SqliteStoreOpenException>()),
      );
    });
  }

  test(
    'missing, uninitialized, non-database files fail without recreation',
    () {
      final directory = temporaryDatabaseDirectory();
      addTearDown(() => removeDatabaseDirectory(directory));
      final path = '${directory.path}${Platform.pathSeparator}missing.sqlite';
      expect(
        () => SqliteOperationStore.open(path),
        throwsA(isA<SqliteStoreOpenException>()),
      );
      expect(File(path).existsSync(), isFalse);
      File(path).writeAsStringSync('');
      expect(
        () => SqliteOperationStore.open(path),
        throwsA(isA<SqliteStoreOpenException>()),
      );
      expect(
        () => SqliteOperationStore.create(path),
        throwsA(isA<SqliteStoreOpenException>()),
      );
      File(path).writeAsStringSync('not a database');
      expect(
        () => SqliteOperationStore.open(path),
        throwsA(isA<SqliteStoreOpenException>()),
      );
      expect(File(path).readAsStringSync(), 'not a database');
      expect(
        () => SqliteOperationStore.create(':memory:'),
        throwsA(isA<SqliteStoreOpenException>()),
      );
    },
  );

  test('closed adapter fails safely and close is idempotent', () async {
    final fixture = DatabaseFixture();
    fixture.store.close();
    fixture.store.close();
    await expectLater(
      fixture.store.read(id: identity().id, scope: identity().scope),
      throwsA(isA<OperationStoreReadException>()),
    );
    await expectLater(
      fixture.store.listUnresolved(scope: identity().scope),
      throwsA(isA<OperationStoreReadException>()),
    );
    await expectLater(
      fixture.store.createIfAbsent(recordIn(OperationState.prepared)),
      throwsA(
        isA<OperationStoreWriteException>().having(
          (error) => error.commitStatus,
          'status',
          StoreCommitStatus.notCommitted,
        ),
      ),
    );
  });

  test(
    'verified checkpoint precedes irreversible main-file corruption',
    () async {
      final fixture = DatabaseFixture();
      await fixture.store.createIfAbsent(recordIn(OperationState.prepared));
      fixture.store.close();
      checkpointDatabase(fixture.path);
      final file = File(fixture.path);
      expect(file.lengthSync(), greaterThan(100));
      file.writeAsStringSync(
        'malformed after verified checkpoint',
        flush: true,
      );
      expect(
        () => SqliteOperationStore.open(fixture.path),
        throwsA(isA<SqliteStoreOpenException>()),
      );
      expect(file.readAsStringSync(), 'malformed after verified checkpoint');
    },
  );

  test('a valid committed WAL remains readable before checkpoint', () async {
    final fixture = DatabaseFixture();
    final prepared = recordIn(OperationState.prepared);
    await fixture.store.createIfAbsent(prepared);
    // This connection remains open so the real committed WAL is still present.
    expect(File('${fixture.path}-wal').lengthSync(), greaterThan(0));
    final reader = SqliteOperationStore.open(fixture.path);
    try {
      final restored = await reader.read(
        id: prepared.identity.id,
        scope: prepared.identity.scope,
      );
      expect(restored!.identity, prepared.identity);
      expect(restored.state, OperationState.prepared);
      expect(reader.configuration['busy_timeout'], 5000);
    } finally {
      reader.close();
    }
  });

  test('exclusive creation refuses orphan WAL/SHM without deleting them', () {
    final directory = temporaryDatabaseDirectory();
    addTearDown(() => removeDatabaseDirectory(directory));
    for (final suffix in ['-wal', '-shm']) {
      final path =
          '${directory.path}${Platform.pathSeparator}orphan$suffix.sqlite';
      final sidecar = File('$path$suffix')
        ..writeAsStringSync('preserve for investigation');
      expect(
        () => SqliteOperationStore.create(path),
        throwsA(isA<SqliteStoreOpenException>()),
      );
      expect(File(path).existsSync(), isFalse);
      expect(sidecar.readAsStringSync(), 'preserve for investigation');
    }
  });
}
