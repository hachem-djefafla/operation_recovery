import 'dart:io';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:operation_recovery_sqlite_example/sqlite_operation_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:operation_recovery_sqlite_example/src/record_codec.dart';
import '../tool/support/http_backend.dart';
import '../tool/support/protocol.dart';

Future<void> main(List<String> arguments) async {
  final channel = WorkerChannel();
  await channel.emit({'kind': 'hello', 'pid': pid, 'protocol': 1});
  try {
    switch (arguments.single) {
      case 'backend':
        await CrashBackend(channel).run();
      case 'client':
        await _client(channel);
      case 'storage':
        await _storage(channel);
      default:
        throw StateError('Unsupported worker role');
    }
  } catch (error) {
    stderr.writeln('Worker failed: ${error.runtimeType}');
    exitCode = 1;
  } finally {
    await channel.close();
  }
}

Future<void> _client(WorkerChannel channel) async {
  final init = await channel.next();
  SqliteOperationStore store;
  try {
    store = init['create'] == true
        ? SqliteOperationStore.create(init['path']! as String)
        : SqliteOperationStore.open(init['path']! as String);
  } catch (error) {
    await channel.emit({
      'kind': 'error',
      'seq': init['seq'],
      'type': '${error.runtimeType}',
      'message': '$error',
    });
    return;
  }
  final clock = DemoClock(demoEpoch);
  var sequence = 0;
  var paused = false;
  final pauseName = init['pause'] as String?;
  Future<void> pause(String name) async {
    if (pauseName == name && !paused) {
      paused = true;
      await channel.checkpoint(name, sequence);
    }
  }

  final wrapped = _CheckpointStore(
    store,
    pause,
    init['pauseAtAttempt'] as int? ?? 1,
  );
  final handler = CrashHttpHandler(
    Uri.parse(init['uri']! as String),
    beforeSubmission: () => pause('before-submit'),
    afterLostResponse: () => pause('lost-response'),
  );
  handler.authenticated = init['authenticated'] != false;
  final token = OperationRegistration<String>(
    type: demoIdentity.type,
    handler: handler,
  );
  final facade = OperationRecovery(
    scope: demoIdentity.scope,
    store: wrapped,
    handlers: [token],
    clock: clock,
    policy: RecoveryPolicy(
      maxAttempts: 3,
      initialDelay: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 4),
    ),
  );
  await channel.emit({
    'kind': 'result',
    'seq': init['seq'],
    'configuration': store.configuration,
  });
  try {
    while (true) {
      final command = await channel.next();
      sequence = command['seq']! as int;
      try {
        Map<String, Object?> data;
        switch (command['action']) {
          case 'start':
            data = snapshot(
              await facade.start(
                token,
                identity: demoIdentity,
                request: 'transient-private-request',
              ),
            );
          case 'get':
            data = snapshot(await facade.get(demoIdentity.id));
          case 'reconcile':
            final record = await facade.get(demoIdentity.id);
            if (record == null) throw const OperationNotFoundException();
            data = snapshot(await facade.reconcile(record.identity));
          case 'batch':
            final results = await facade.reconcilePending();
            data = {
              'results': [
                for (final result in results)
                  switch (result) {
                    ReconciliationCompleted(:final record) => snapshot(record),
                    ReconciliationFailed(:final error) => {
                      'error': '${error.runtimeType}',
                    },
                  },
              ],
            };
          case 'resume':
            final record = await facade.get(demoIdentity.id);
            if (record == null) throw const OperationNotFoundException();
            data = snapshot(await facade.resume(record.identity));
          case 'advance':
            clock.value = DateTime.parse(command['at']! as String).toUtc();
            data = {'at': clock.value.toIso8601String()};
          case 'authenticate':
            handler.authenticated = command['authenticated'] == true;
            data = {'authenticated': handler.authenticated};
          case 'exit':
            await channel.emit({'kind': 'result', 'seq': sequence});
            return;
          default:
            throw StateError('Unsupported client action');
        }
        await channel.emit({'kind': 'result', 'seq': sequence, ...data});
      } catch (error) {
        final safe =
            error is OperationRecoveryException ||
            error is OperationStoreException;
        await channel.emit({
          'kind': 'error',
          'seq': sequence,
          'type': '${error.runtimeType}',
          'message': safe ? '$error' : 'Client action failed',
        });
      }
    }
  } finally {
    await facade.close();
    store.close();
  }
}

final class _CheckpointStore implements OperationStore {
  _CheckpointStore(this.delegate, this.pause, this.pauseAtAttempt);
  final OperationStore delegate;
  final Future<void> Function(String) pause;
  final int pauseAtAttempt;

  @override
  Future<bool> createIfAbsent(OperationRecord record) async {
    final changed = await delegate.createIfAbsent(record);
    if (changed) await pause('prepared');
    return changed;
  }

  @override
  Future<bool> compareAndSwap(
    OperationRecord replacement, {
    required int expectedVersion,
  }) async {
    if (replacement.state.isTerminal) await pause('before-terminal');
    final before = await delegate.read(
      id: replacement.identity.id,
      scope: replacement.identity.scope,
    );
    final changed = await delegate.compareAndSwap(
      replacement,
      expectedVersion: expectedVersion,
    );
    if (changed) {
      if (replacement.version == 1) await pause('uncertainty-ack-lost');
      if (before != null &&
          replacement.recovery.totalAttempts > before.recovery.totalAttempts &&
          replacement.recovery.totalAttempts == pauseAtAttempt) {
        await pause('reservation');
      }
    }
    return changed;
  }

  @override
  Future<OperationRecord?> read({required String id, required String scope}) =>
      delegate.read(id: id, scope: scope);
  @override
  Future<List<OperationRecord>> listUnresolved({required String scope}) =>
      delegate.listUnresolved(scope: scope);
}

Future<void> _storage(WorkerChannel channel) async {
  final init = await channel.next();
  final store = SqliteOperationStore.open(init['path']! as String);
  await channel.emit({
    'kind': 'result',
    'seq': init['seq'],
    'configuration': store.configuration,
  });
  try {
    final command = await channel.next();
    if (command['action'] == 'cas' || command['action'] == 'create') {
      final record = decodeRecord(
        Map<String, Object?>.from(command['record']! as Map<String, dynamic>),
      );
      final changed = command['action'] == 'create'
          ? await store.createIfAbsent(record)
          : await store.compareAndSwap(
              record,
              expectedVersion: command['expectedVersion']! as int,
            );
      await channel.emit({
        'kind': 'result',
        'seq': command['seq'],
        'changed': changed,
      });
    } else if (command['action'] == 'uncommitted') {
      final db = sqlite3.open(
        init['path']! as String,
        mode: OpenMode.readWrite,
      );
      try {
        db.execute('PRAGMA synchronous = FULL');
        db.execute('BEGIN IMMEDIATE');
        db.execute(
          '''UPDATE operations SET
record_version = record_version + 1, cycle_attempts = cycle_attempts + 1,
total_attempts = total_attempts + 1, updated_at_us = ?, last_attempt_at_us = ?,
next_check_at_us = ? WHERE operation_id = ?''',
          [
            demoEpoch.microsecondsSinceEpoch + 1000000,
            demoEpoch.microsecondsSinceEpoch + 1000000,
            demoEpoch.microsecondsSinceEpoch + 2000000,
            demoIdentity.id,
          ],
        );
        await channel.checkpoint(
          'transaction-uncommitted',
          command['seq']! as int,
        );
        db.execute('COMMIT');
        await channel.emit({'kind': 'result', 'seq': command['seq']});
      } finally {
        db.close();
      }
    } else {
      throw StateError('Unsupported storage action');
    }
    // Raw writer tests also use acknowledged exit + parent-side EOF. Returning
    // here used to leave Windows stdin cancellation waiting on an open pipe.
    final exit = await channel.next();
    if (exit['action'] != 'exit') {
      throw StateError('Storage worker requires exit');
    }
    await channel.emit({'kind': 'result', 'seq': exit['seq']});
  } finally {
    store.close();
  }
}
