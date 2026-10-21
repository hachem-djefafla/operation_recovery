import 'dart:io';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:operation_recovery_sqlite_example/src/record_codec.dart';
import '../../tool/support/crash_harness.dart';
import '../../tool/support/protocol.dart';
import '../support/database_fixture.dart';

void main() {
  for (final scenario in [
    'prepared',
    'before-submit',
    'uncertainty-ack-lost',
    'in-flight',
    'lost-response',
    'lookup-before-save',
    'attempts',
    'last-reservation',
    'authentication',
  ]) {
    test('real process crash: $scenario', () async {
      final report = await runCrashScenario(scenario);
      final config = report['configuration']! as Map<String, Object?>;
      expect(config['journal_mode'], 'wal');
      expect(config['synchronous'], 2);
      expect(config['busy_timeout'], 5000);
      final counters = report['counters']! as Map<String, Object?>;
      if (scenario == 'lost-response') {
        expect(counters['submissions'], 1);
        expect(counters['effects'], 1);
        expect(counters['lookups'], greaterThanOrEqualTo(1));
        expect(
          (report['final']! as Map<String, Object?>)['state'],
          'succeeded',
        );
      }
      final trace = report['trace']! as List<Map<String, Object?>>;
      expect(
        trace.where((event) => event['checkpoint'] == 'client-killed'),
        isNotEmpty,
      );
      expect(
        trace.where((event) => event['checkpoint'] == 'client-opened').length,
        greaterThanOrEqualTo(3),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  final corruptions = <String, void Function(String)>{
    for (final sql in [
      'UPDATE operations SET record_schema_version = 99',
      "UPDATE operations SET state = 'future'",
      'UPDATE operations SET record_version = -1',
      'UPDATE operations SET total_attempts = 1',
      'UPDATE operations SET updated_at_us = created_at_us - 1',
      "UPDATE operations SET observation_kind = 'succeeded'",
      "UPDATE operations SET lookup_failure_reason = 'future_reason'",
      'PRAGMA user_version = 2',
      'PRAGMA application_id = 123',
      'DROP TABLE operations',
      'ALTER TABLE operations DROP COLUMN next_check_at_us',
    ])
      sql: (path) {
        final db = sqlite3.open(path, mode: OpenMode.readWrite);
        try {
          db.execute('PRAGMA ignore_check_constraints = ON');
          db.execute(sql);
        } finally {
          db.close();
        }
      },
    'malformed database file': (path) {
      checkpointDatabase(path);
      File(path).writeAsStringSync(
        'malformed database, never safe preparation',
        flush: true,
      );
      expect(
        File(path).readAsStringSync(),
        'malformed database, never safe preparation',
      );
    },
    'missing database': (path) {
      checkpointDatabase(path);
      File(path).deleteSync();
    },
  };
  for (final corruption in corruptions.entries) {
    test('fresh process rejects corruption: ${corruption.key}', () async {
      final env = await CrashEnvironment.start();
      addTearDown(env.dispose);
      final first = await env.client(create: true, pause: 'prepared');
      await first.send('start');
      await first.checkpoint('prepared');
      await env.terminate(first, 'prepared-before-corruption');
      corruption.value(env.path);
      var failed = false;
      try {
        final second = await env.client();
        final response = await second.result(await second.send('start'));
        expect(response['kind'], 'error');
        expect(response['type'], 'InvalidOperationRecordException');
        failed = true;
        await second.shutdown();
      } on RemoteWorkerFailure catch (error) {
        expect(error.type, 'SqliteStoreOpenException');
        failed = true; // Explicit schema/file validation rejection during init.
      }
      expect(failed, isTrue);
      final counters = await env.stats();
      expect(counters['submissions'], 0);
      expect(counters['effects'], 0);
      expect(counters['lookups'], 0);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  for (final action in ['create', 'cas']) {
    test('independent SQLite writer processes race on $action', () async {
      final fixture = DatabaseFixture();
      final prepared = OperationRecord.prepared(
        identity: demoIdentity,
        at: demoEpoch,
      );
      if (action == 'cas') await fixture.store.createIfAbsent(prepared);
      fixture.store.close();
      final first = await WorkerProcess.start(defaultWorkerPath(), 'storage');
      addTearDown(first.dispose);
      final second = await WorkerProcess.start(defaultWorkerPath(), 'storage');
      addTearDown(second.dispose);
      await Future.wait([
        first.request('init', {'path': fixture.path}),
        second.request('init', {'path': fixture.path}),
      ]);
      final candidate = action == 'create'
          ? prepared
          : OperationRecord.restore(
              identity: demoIdentity,
              state: OperationState.awaitingOutcome,
              version: 1,
              createdAt: demoEpoch,
              updatedAt: demoEpoch.add(const Duration(seconds: 1)),
            );
      final arguments = {
        'record': Map<String, Object?>.fromIterables(
          recordColumns,
          encodeRecord(candidate),
        ),
        'expectedVersion': 0,
      };
      final results = await Future.wait([
        first.request(action, arguments),
        second.request(action, arguments),
      ]);
      expect(results.where((value) => value['changed'] == true), hasLength(1));
      expect(results.where((value) => value['changed'] == false), hasLength(1));
      await Future.wait([first.shutdown(), second.shutdown()]);
      fixture.reopen();
      final stored = await fixture.store.read(
        id: demoIdentity.id,
        scope: demoIdentity.scope,
      );
      expect(stored!.version, action == 'create' ? 0 : 1);
      expect(stored.identity, demoIdentity);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('real process death rolls back uncommitted recovery metadata', () async {
    final fixture = DatabaseFixture();
    await fixture.store.createIfAbsent(
      OperationRecord.prepared(identity: demoIdentity, at: demoEpoch),
    );
    final original = OperationRecord.restore(
      identity: demoIdentity,
      state: OperationState.awaitingOutcome,
      version: 1,
      createdAt: demoEpoch,
      updatedAt: demoEpoch,
    );
    await fixture.store.compareAndSwap(original, expectedVersion: 0);
    fixture.store.close();
    final worker = await WorkerProcess.start(defaultWorkerPath(), 'storage');
    addTearDown(worker.dispose);
    await worker.request('init', {'path': fixture.path});
    await worker.send('uncommitted');
    await worker.checkpoint('transaction-uncommitted');
    await worker.kill();
    fixture.reopen();
    final restored = await fixture.store.read(
      id: demoIdentity.id,
      scope: demoIdentity.scope,
    );
    expect(restored!.version, original.version);
    expect(restored.recovery.totalAttempts, 0);
    expect(restored.recovery.cycleAttempts, 0);
    expect(restored.recovery.lastAttemptAt, isNull);
    expect(restored.recovery.nextCheckAt, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
