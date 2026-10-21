import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../../../../test/support/fixtures.dart';
import '../../../../test/support/recovery_fixtures.dart';
import '../../../../test/support/storage_fixtures.dart';
import '../support/database_fixture.dart';

void main() {
  test(
    'transient request and raw handler errors never enter database files',
    () async {
      const secret = 'private-payload-and-error-sentinel-38457';
      final fixture = DatabaseFixture();
      final handler = ScriptedHandler<String>();
      handler.onSubmit = (_, request) async {
        expect(request, secret);
        throw StateError(secret);
      };
      final registration = OperationRegistration(
        type: 'transfer',
        handler: handler,
      );
      final facade = OperationRecovery(
        scope: identity().scope,
        store: fixture.store,
        handlers: [registration],
        policy: RecoveryPolicy(
          maxAttempts: 3,
          initialDelay: const Duration(seconds: 1),
          maxDelay: const Duration(seconds: 4),
        ),
      );
      addTearDown(facade.close);
      await expectLater(
        facade.start(registration, identity: identity(), request: secret),
        throwsA(
          isA<OperationHandlerException>().having(
            (error) => error.toString().contains(secret),
            'safe description',
            isFalse,
          ),
        ),
      );
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('${fixture.path}$suffix');
        if (file.existsSync()) {
          expect(
            utf8.decode(file.readAsBytesSync(), allowMalformed: true),
            isNot(contains(secret)),
          );
        }
      }
      await facade.close();
      fixture.reopen();
      expect(
        (await fixture.store.read(
          id: identity().id,
          scope: identity().scope,
        ))!.state,
        OperationState.awaitingOutcome,
      );
    },
  );

  for (final stage in [
    'creation',
    'uncertainty',
    'submission-result',
    'reservation',
    'lookup-result',
  ]) {
    for (final fault in [
      (
        name: 'definite-before',
        status: StoreCommitStatus.notCommitted,
        after: false,
      ),
      (
        name: 'ambiguous-before',
        status: StoreCommitStatus.unknown,
        after: false,
      ),
      (name: 'ambiguous-after', status: StoreCommitStatus.unknown, after: true),
    ]) {
      test(
        'SQLite + simulated acknowledgement: $stage ${fault.name}',
        () async {
          final fixture = DatabaseFixture();
          final lookup = stage == 'reservation' || stage == 'lookup-result';
          if (lookup) {
            await seedState(fixture.store, OperationState.awaitingOutcome);
          }
          final probe = StoreProbe(fixture.store);
          final handler = ScriptedHandler<String>();
          handler.onSubmit = (value, _) async =>
              OperationSucceeded(identity: value);
          handler.onLookup = (value) async =>
              OperationSucceeded(identity: value);
          final registration = OperationRegistration(
            type: 'transfer',
            handler: handler,
          );
          final facade = OperationRecovery(
            scope: identity().scope,
            store: probe,
            handlers: [registration],
            policy: RecoveryPolicy(
              maxAttempts: 3,
              initialDelay: const Duration(seconds: 1),
              maxDelay: const Duration(seconds: 4),
            ),
            clock: FakeClock(epoch.add(const Duration(seconds: 10))),
          );
          addTearDown(facade.close);
          final events = <OperationEvent>[];
          final done = Completer<void>();
          facade.events.listen(events.add, onDone: done.complete);
          final version = switch (stage) {
            'creation' => 0,
            'uncertainty' => 1,
            'submission-result' || 'reservation' => 2,
            _ => 3,
          };
          final failure = OperationStoreWriteException(
            commitStatus: fault.status,
          );
          Future<void> createFault(OperationRecord _) async => throw failure;
          Future<void> casFault(OperationRecord record, int _) async {
            if (record.version == version) throw failure;
          }

          if (stage == 'creation') {
            if (fault.after) {
              probe.afterCreate = createFault;
            } else {
              probe.beforeCreate = createFault;
            }
          } else {
            if (fault.after) {
              probe.afterCas = casFault;
            } else {
              probe.beforeCas = casFault;
            }
          }
          await expectLater(
            lookup
                ? facade.reconcile(identity())
                : facade.start(
                    registration,
                    identity: identity(),
                    request: 'not persisted',
                  ),
            throwsA(same(failure)),
          );
          expect(
            handler.submissions.length,
            stage == 'submission-result' ? 1 : 0,
          );
          expect(handler.lookups.length, stage == 'lookup-result' ? 1 : 0);
          await facade.close();
          await done.future;
          expect(
            events.any((event) => event.record.version == version),
            isFalse,
          );
          fixture.reopen();
          final restored = await fixture.store.read(
            id: identity().id,
            scope: identity().scope,
          );
          expect(
            restored?.version,
            fault.after
                ? version
                : stage == 'creation'
                ? null
                : version - 1,
          );
          if (fault.after && stage == 'uncertainty') {
            final restoredFacade = OperationRecovery(
              scope: identity().scope,
              store: fixture.store,
              handlers: [registration],
              policy: RecoveryPolicy(
                maxAttempts: 3,
                initialDelay: const Duration(seconds: 1),
                maxDelay: const Duration(seconds: 4),
              ),
              clock: FakeClock(epoch.add(const Duration(seconds: 10))),
            );
            addTearDown(restoredFacade.close);
            await restoredFacade.get(identity().id);
            await restoredFacade.start(
              registration,
              identity: identity(),
              request: 'fresh explicit request',
            );
            expect(handler.submissions, isEmpty);
            expect(
              (await restoredFacade.reconcile(identity())).state,
              OperationState.succeeded,
            );
            expect(handler.submissions, isEmpty);
          }
        },
      );
    }
  }
}
