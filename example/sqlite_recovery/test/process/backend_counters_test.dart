import 'package:test/test.dart';

import '../../tool/support/crash_harness.dart';
import '../../tool/support/http_backend.dart';
import '../../tool/support/protocol.dart';
import '../support/database_fixture.dart';

void main() {
  test(
    'failed initialization is reaped before removing worker resources',
    () async {
      final directory = temporaryDatabaseDirectory();
      addTearDown(() => removeDatabaseDirectory(directory));
      final worker = await WorkerProcess.start(defaultWorkerPath(), 'client');
      addTearDown(worker.dispose);
      await expectLater(
        worker.request('init', {
          'path': directory.uri.resolve('missing.sqlite').toFilePath(),
        }),
        throwsA(isA<RemoteWorkerFailure>()),
      );
      await worker.dispose();
      expect(worker.ended, isTrue);
      await expectLater(worker.process.exitCode, completes);
    },
  );

  test(
    'backend distinguishes duplicate requests from deduplicated effects',
    () async {
      final backend = await WorkerProcess.start(defaultWorkerPath(), 'backend');
      addTearDown(backend.dispose);
      final initialized = await backend.request('init', {
        'loseResponse': false,
      });
      final handler = CrashHttpHandler(
        Uri.parse(initialized['uri']! as String),
      );
      await handler.submit(demoIdentity, 'private first request');
      await handler.submit(demoIdentity, 'private duplicate request');
      await handler.lookupStatus(demoIdentity);
      final counters = await backend.request('stats');
      expect(counters['submissions'], 2);
      expect(counters['effects'], 1);
      expect(counters['lookups'], 1);
      await backend.shutdown();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'acknowledged shutdown closes stdin and reaps the actual worker',
    () async {
      final backend = await WorkerProcess.start(defaultWorkerPath(), 'backend');
      addTearDown(backend.dispose);
      await backend.request('init');
      await backend.shutdown();
      expect(await backend.process.exitCode, 0);
      expect(backend.ended, isTrue);
      final disposal = backend.dispose();
      expect(identical(disposal, backend.dispose()), isTrue);
      await disposal;
    },
  );

  test(
    'HTTP callbacks and control replies share ordered protocol output',
    () async {
      final backend = await WorkerProcess.start(defaultWorkerPath(), 'backend');
      addTearDown(backend.dispose);
      final initialized = await backend.request('init', {
        'loseResponse': false,
        'pauseSubmission': true,
      });
      final handler = CrashHttpHandler(
        Uri.parse(initialized['uri']! as String),
      );
      final submissions = Future.wait([
        for (var index = 0; index < 4; index++)
          handler.submit(demoIdentity, 'same transient request'),
      ]);
      for (var index = 0; index < 4; index++) {
        await backend.checkpoint('submission-received');
      }
      await Future.wait([
        backend.request('stats'),
        backend.request('release'),
        backend.request('stats'),
      ]);
      await submissions;
      final counters = await backend.request('stats');
      expect(counters['submissions'], 4);
      expect(counters['effects'], 1);
      expect(counters['lookups'], 0);
      await backend.shutdown();
    },
  );
}
