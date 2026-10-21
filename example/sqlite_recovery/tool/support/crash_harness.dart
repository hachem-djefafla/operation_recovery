import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

/// Test/demo control failure; never contains private requests or SQL parameters.
final class WorkerFailure implements Exception {
  WorkerFailure(this.message);
  final String message;
  @override
  String toString() => 'WorkerFailure($message)';
}

String defaultWorkerPath() => File(
  'build/crash_worker/bundle/bin/crash_worker${Platform.isWindows ? '.exe' : ''}',
).absolute.path;

/// An explicit action rejection, distinct from IPC and process failures.
final class RemoteWorkerFailure implements Exception {
  RemoteWorkerFailure(this.type, this.message);
  final String type;
  final String message;
  @override
  String toString() => 'RemoteWorkerFailure($type: $message)';
}

/// Directly launched process with buffered, predicate-addressable IPC messages.
final class WorkerProcess {
  WorkerProcess._(this.process) {
    _output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              _messages.add(jsonObject(line));
              _notify();
            } catch (_) {
              _failure = 'Worker emitted invalid protocol';
              _notify();
            }
          },
          onDone: () {
            _failure ??= 'Worker output ended';
            _notify();
          },
          onError: (Object _) {
            _failure = 'Worker output failed';
            _notify();
          },
        );
    _errors = process.stderr.transform(utf8.decoder).listen((text) {
      if (_diagnostics.length < 8192) _diagnostics += text;
    });
    unawaited(
      process.exitCode.then((_) {
        ended = true;
      }),
    );
  }

  final Process process;
  final List<Map<String, Object?>> _messages = [];
  late final StreamSubscription<String> _output;
  late final StreamSubscription<String> _errors;
  Completer<void> _changed = Completer<void>();
  String? _failure;
  String _diagnostics = '';
  int _sequence = 0;
  bool ended = false;
  Future<void> _inputWrites = Future<void>.value();
  Future<void>? _inputClosing;
  Future<void>? _disposing;

  static Future<WorkerProcess> start(String executable, String role) async {
    if (!File(executable).existsSync()) {
      throw WorkerFailure(
        'Missing worker bundle. Run dart build cli --target=bin/crash_worker.dart --output=build/crash_worker',
      );
    }
    final worker = WorkerProcess._(
      await Process.start(executable, [role], runInShell: false),
    );
    try {
      final hello = await worker.wait((message) => message['kind'] == 'hello');
      if (hello['protocol'] != 1 || hello['pid'] != worker.process.pid) {
        throw WorkerFailure('Worker identity/protocol mismatch');
      }
      return worker;
    } catch (_) {
      await worker.dispose();
      rethrow;
    }
  }

  void _notify() {
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
  }

  Future<Map<String, Object?>> wait(
    bool Function(Map<String, Object?>) predicate,
  ) async {
    Future<Map<String, Object?>> find() async {
      while (true) {
        final index = _messages.indexWhere(predicate);
        if (index >= 0) return _messages.removeAt(index);
        if (_messages.any((message) => message['kind'] == 'backend-error')) {
          throw WorkerFailure('Backend request failed');
        }
        if (_failure != null) throw WorkerFailure('$_failure; $_diagnostics');
        await _changed.future;
      }
    }

    return find().timeout(
      const Duration(seconds: 30),
      onTimeout: () =>
          throw WorkerFailure('Checkpoint deadline exceeded; $_diagnostics'),
    );
  }

  Future<int> send(
    String action, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (_inputClosing != null) throw WorkerFailure('Worker input is closed');
    final sequence = ++_sequence;
    final line = jsonEncode({'action': action, 'seq': sequence, ...arguments});
    await (_inputWrites = _inputWrites.then((_) async {
      process.stdin.writeln(line);
      await process.stdin.flush();
    }));
    return sequence;
  }

  Future<Map<String, Object?>> result(int sequence) => wait(
    (message) =>
        message['seq'] == sequence &&
        (message['kind'] == 'result' || message['kind'] == 'error'),
  );

  Future<Map<String, Object?>> request(
    String action, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final response = await result(await send(action, arguments));
    if (response['kind'] == 'error') {
      throw RemoteWorkerFailure(
        response['type']! as String,
        response['message']! as String,
      );
    }
    return response;
  }

  Future<Map<String, Object?>> checkpoint(String name) => wait(
    (message) => message['kind'] == 'checkpoint' && message['name'] == name,
  );

  Future<void> kill() async {
    if (ended || !process.kill(ProcessSignal.sigkill)) {
      throw WorkerFailure(
        'Client was not alive at the forced-termination checkpoint',
      );
    }
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    if (code == 0) {
      throw WorkerFailure('Forced client termination exited normally');
    }
    ended = true;
  }

  Future<void> shutdown() async {
    await request('exit');
    // EOF releases the worker's Windows stdin read/cancellation. Waiting for
    // exit before closing this pipe creates a parent/child shutdown cycle.
    await _closeInput();
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    if (code != 0) throw WorkerFailure('Graceful worker exit failed');
    ended = true;
  }

  Future<void> _closeInput() => _inputClosing ??= _inputWrites.then((_) async {
    await process.stdin.close();
  });

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    try {
      if (!ended) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 10));
        ended = true;
      }
    } finally {
      try {
        await _output.cancel();
      } finally {
        try {
          await _errors.cancel();
        } finally {
          try {
            await _closeInput();
          } on IOException {
            // Forced termination intentionally leaves a closed child pipe.
          }
        }
      }
    }
  }
}

/// One owned database directory, independent backend, and sequential clients.
final class CrashEnvironment {
  CrashEnvironment._(
    this.executable,
    this.directory,
    this.backend,
    this.uri,
    this.log,
  );
  final String executable;
  final Directory directory;
  final WorkerProcess backend;
  final String uri;
  final void Function(String)? log;
  final List<WorkerProcess> _clients = [];
  final List<Map<String, Object?>> trace = [];
  Map<String, Object?>? configuration;

  String get path =>
      '${directory.path}${Platform.pathSeparator}operations.sqlite';

  static Future<CrashEnvironment> start({
    String? executable,
    bool pauseSubmission = false,
    bool lookupUnknown = false,
    void Function(String)? log,
  }) async {
    final workerPath = executable ?? defaultWorkerPath();
    final directory = Directory.systemTemp.createTempSync(
      'operation_recovery_sqlite_',
    );
    WorkerProcess? backend;
    try {
      backend = await WorkerProcess.start(workerPath, 'backend');
      final started = await backend.request('init', {
        'pauseSubmission': pauseSubmission,
        'lookupUnknown': lookupUnknown,
      });
      return CrashEnvironment._(
        workerPath,
        directory,
        backend,
        started['uri']! as String,
        log,
      );
    } catch (_) {
      try {
        await backend?.dispose();
      } finally {
        removeOwnedDirectory(directory);
      }
      rethrow;
    }
  }

  Future<WorkerProcess> client({
    bool create = false,
    bool authenticated = true,
    String? pause,
    int pauseAtAttempt = 1,
  }) async {
    if (_clients.any((worker) => !worker.ended)) {
      throw WorkerFailure(
        'Sequential-client harness forbids overlapping coordinators',
      );
    }
    final client = await WorkerProcess.start(executable, 'client');
    _clients.add(client);
    final initialized = await client.request('init', {
      'path': path,
      'uri': uri,
      'create': create,
      'authenticated': authenticated,
      'pause': pause,
      'pauseAtAttempt': pauseAtAttempt,
    });
    configuration = Map<String, Object?>.from(
      initialized['configuration']! as Map<String, dynamic>,
    );
    mark('client-opened', {
      'pid': client.process.pid,
      'incarnation': _clients.length,
    });
    return client;
  }

  void mark(String checkpoint, [Map<String, Object?> details = const {}]) {
    trace.add({'checkpoint': checkpoint, ...details});
    log?.call('$checkpoint ${jsonEncode(details)}');
  }

  Future<void> terminate(WorkerProcess client, String checkpoint) async {
    await client.kill();
    mark('client-killed', {'at': checkpoint, 'pid': client.process.pid});
  }

  Future<Map<String, Object?>> stats() => backend.request('stats');

  Future<void> dispose() async {
    try {
      await Future.wait(_clients.map((client) => client.dispose()));
    } finally {
      try {
        await backend.dispose();
      } finally {
        removeOwnedDirectory(directory);
      }
    }
  }
}

void removeOwnedDirectory(Directory directory) {
  if (!directory.existsSync()) return;
  final name = directory.uri.pathSegments.where((part) => part.isNotEmpty).last;
  if (directory.parent.resolveSymbolicLinksSync() !=
          Directory.systemTemp.resolveSymbolicLinksSync() ||
      !name.startsWith('operation_recovery_sqlite_')) {
    throw StateError('Refusing to remove an unowned directory');
  }
  directory.deleteSync(recursive: true);
}

void require(bool condition, String explanation) {
  if (!condition) throw WorkerFailure(explanation);
}

void requireIdentity(Map<String, Object?> record) {
  require(
    identityFromJson(
          Map<String, Object?>.from(
            record['identity']! as Map<String, dynamic>,
          ),
        ) ==
        demoIdentity,
    'Full operation identity must survive restart',
  );
}

Future<Map<String, Object?>> advanceToDue(
  WorkerProcess client,
  Map<String, Object?> record,
) async {
  await client.request('advance', {'at': record['next']});
  return client.request('reconcile');
}

/// Runs A-F using real forced termination; shared by tests and the CLI demo.
Future<Map<String, Object?>> runCrashScenario(
  String scenario, {
  String? executable,
  void Function(String)? log,
}) async {
  const scenarios = {
    'prepared',
    'before-submit',
    'uncertainty-ack-lost',
    'in-flight',
    'lost-response',
    'lookup-before-save',
    'attempts',
    'last-reservation',
    'authentication',
  };
  if (!scenarios.contains(scenario)) {
    throw ArgumentError.value(scenario, 'scenario');
  }
  final attempts = scenario == 'attempts' || scenario == 'last-reservation';
  final env = await CrashEnvironment.start(
    executable: executable,
    pauseSubmission: scenario == 'in-flight',
    lookupUnknown: attempts,
    log: log,
  );
  try {
    Map<String, Object?> finalRecord;
    if (scenario == 'authentication') {
      final first = await env.client(create: true, pause: 'lost-response');
      await first.send('start');
      await first.checkpoint('lost-response');
      await env.terminate(
        first,
        'lost-response-before-authentication-recovery',
      );
      final second = await env.client(authenticated: false);
      final blocked = await second.request('reconcile');
      requireIdentity(blocked);
      require(
        blocked['state'] == 'awaitingOutcome' &&
            blocked['lookupFailure'] == 'authenticationRequired' &&
            blocked['total'] == 1,
        'HTTP 401 was not preserved as recoverable uncertainty',
      );
      await env.terminate(second, 'authentication-required-persisted');
      final third = await env.client();
      final restored = await third.request('get');
      require(
        restored['lookupFailure'] == 'authenticationRequired' &&
            restored['total'] == 1 &&
            restored['next'] == blocked['next'],
        'Authentication observation or reservation did not survive restart',
      );
      final early = await third.request('reconcile');
      require(early['total'] == 1, 'Restart bypassed persisted backoff');
      finalRecord = await advanceToDue(third, restored);
      require(
        finalRecord['state'] == 'succeeded',
        'Authentication recovery failed',
      );
      require(
        (await env.stats())['lookups'] == 2,
        'Unexpected authentication lookups',
      );
      await third.shutdown();
    } else if (attempts) {
      final target = scenario == 'last-reservation' ? 3 : 2;
      final first = await env.client(
        create: true,
        pause: 'reservation',
        pauseAtAttempt: target,
      );
      var record = await first.request('start');
      for (var attempt = 1; attempt < target; attempt++) {
        record = record['next'] == null
            ? await first.request('reconcile')
            : await advanceToDue(first, record);
      }
      await first.request('advance', {'at': record['next']});
      await first.send('reconcile');
      await first.checkpoint('reservation');
      final lookupsBefore = (await env.stats())['lookups'];
      await env.terminate(first, 'reserved-attempt-$target');
      final second = await env.client();
      final restored = await second.request('get');
      requireIdentity(restored);
      require(
        restored['cycle'] == target && restored['total'] == target,
        'Restart reset reservation counters',
      );
      final early = await second.request('reconcile');
      require(
        early['version'] == restored['version'],
        'Lookup happened before its persisted due time',
      );
      require(
        (await env.stats())['lookups'] == lookupsBefore,
        'Early lookup reached backend',
      );
      record = await advanceToDue(second, restored);
      require(
        record['state'] == 'needsAttention' &&
            record['cycle'] == 3 &&
            record['total'] == 3,
        'Exhaustion must retain the budget',
      );
      if (target == 3) {
        require(
          (await env.stats())['lookups'] == lookupsBefore,
          'Abandoned last reservation was repeated',
        );
      }
      await env.terminate(second, 'attention-persisted');
      final third = await env.client();
      final attention = await third.request('get');
      require(
        attention['state'] == 'needsAttention' && attention['total'] == 3,
        'Attention did not persist',
      );
      await third.request('batch');
      final resumed = await third.request('resume');
      require(
        resumed['cycle'] == 0 &&
            resumed['total'] == 3 &&
            resumed['last'] == attention['last'],
        'Resume reset cumulative history',
      );
      await third.shutdown();
      final fourth = await env.client();
      final reopened = await fourth.request('get');
      require(
        reopened['cycle'] == 0 &&
            reopened['total'] == 3 &&
            reopened['next'] == resumed['next'],
        'Resume scheduling did not persist',
      );
      finalRecord = await advanceToDue(fourth, reopened);
      require(
        finalRecord['cycle'] == 1 && finalRecord['total'] == 4,
        'Resumed reservation counters are wrong',
      );
      await fourth.shutdown();
    } else if (scenario == 'lookup-before-save') {
      final first = await env.client(create: true, pause: 'before-terminal');
      await first.request('start');
      await first.send('reconcile');
      await first.checkpoint('before-terminal');
      await env.terminate(first, 'lookup-success-before-terminal-CAS');
      final second = await env.client();
      final restored = await second.request('get');
      requireIdentity(restored);
      require(
        restored['state'] == 'awaitingOutcome' && restored['total'] == 1,
        'Lookup result persisted before checkpoint',
      );
      finalRecord = await advanceToDue(second, restored);
      require(
        finalRecord['state'] == 'succeeded' && finalRecord['total'] == 2,
        'Second lookup did not persist success',
      );
      await second.shutdown();
    } else {
      final pause = switch (scenario) {
        'prepared' => 'prepared',
        'before-submit' => 'before-submit',
        'uncertainty-ack-lost' => 'uncertainty-ack-lost',
        'lost-response' => 'lost-response',
        _ => null,
      };
      final first = await env.client(create: true, pause: pause);
      await first.send('start');
      if (scenario == 'in-flight') {
        await env.backend.checkpoint('submission-received');
      } else {
        await first.checkpoint(pause!);
      }
      await env.terminate(first, pause ?? 'submission-in-flight');
      if (scenario == 'in-flight') {
        await env.backend.request('release');
        await env.backend.checkpoint('effect-committed');
      }
      final second = await env.client();
      final restored = await second.request('get');
      requireIdentity(restored);
      require(
        restored['state'] ==
            (scenario == 'prepared' ? 'prepared' : 'awaitingOutcome'),
        'Wrong restored state',
      );
      if (scenario == 'prepared') {
        final batch = await second.request('batch');
        require(
          (batch['results']! as List).isEmpty,
          'Prepared operation was automatically recovered',
        );
        finalRecord = await second.request('get');
      } else {
        finalRecord = await second.request('reconcile');
        final expected = scenario == 'in-flight' || scenario == 'lost-response'
            ? 'succeeded'
            : 'awaitingOutcome';
        require(
          finalRecord['state'] == expected,
          'Authoritative lookup produced wrong outcome',
        );
      }
      await second.shutdown();
    }
    final verifier = await env.client();
    final persisted = await verifier.request('get');
    requireIdentity(persisted);
    for (final field in [
      'state',
      'version',
      'createdAt',
      'updatedAt',
      'cycle',
      'total',
      'last',
      'next',
    ]) {
      require(
        persisted[field] == finalRecord[field],
        'Final $field did not survive connection closure/reopening',
      );
    }
    await verifier.shutdown();
    final counters = await env.stats();
    final sent = !{
      'prepared',
      'before-submit',
      'uncertainty-ack-lost',
    }.contains(scenario);
    require(
      counters['submissions'] == (sent ? 1 : 0) &&
          counters['effects'] == (sent ? 1 : 0),
      'Duplicate or unexpected HTTP business write',
    );
    if (scenario == 'prepared') {
      require(counters['lookups'] == 0, 'Prepared operation was looked up');
    } else {
      require(
        (counters['lookups']! as int) >= 1,
        'Recovery never consulted authoritative backend',
      );
    }
    if (scenario == 'lookup-before-save') {
      require(
        counters['lookups'] == 2,
        'Lookup after result loss was not repeated exactly once',
      );
    }
    return {
      'scenario': scenario,
      'final': persisted,
      'counters': counters,
      'configuration': env.configuration,
      'trace': env.trace,
    };
  } finally {
    await env.dispose();
  }
}
