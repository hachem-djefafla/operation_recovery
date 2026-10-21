import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/storage_fixtures.dart';

/// Shared semantic tests; a future durable adapter must run this same contract.
void operationStoreContract(
  String name,
  OperationStore Function() createStore,
) {
  group(name, () {
    late OperationStore store;
    setUp(() => store = createStore());

    test('absent and foreign-scope reads both return null', () async {
      final original = await seedState(store, OperationState.prepared);
      expect(await store.read(id: 'absent', scope: identity().scope), isNull);
      expect(
        await store.read(id: original.identity.id, scope: 'another-account'),
        isNull,
      );
      expectSnapshot(
        await store.read(
          id: original.identity.id,
          scope: original.identity.scope,
        ),
        original,
      );
    });

    test('concurrent identical creates insert exactly once', () async {
      final record = recordIn(OperationState.prepared);
      final results = await Future.wait([
        for (var index = 0; index < 12; index++) store.createIfAbsent(record),
      ]);
      expect(results.where((created) => created), hasLength(1));
      expectSnapshot(
        await store.read(id: record.identity.id, scope: record.identity.scope),
        record,
      );
    });

    for (final state in OperationState.values) {
      test('matching create never overwrites existing ${state.name}', () async {
        final original = await seedState(store, state);
        final duplicate = OperationRecord.prepared(
          identity: identity(),
          at: epoch.add(const Duration(days: 1)),
        );
        expect(await store.createIfAbsent(duplicate), isFalse);
        expectSnapshot(
          await store.read(
            id: original.identity.id,
            scope: original.identity.scope,
          ),
          original,
        );
      });
      if (state != OperationState.prepared) {
        test('creation rejects ${state.name} before insertion', () async {
          final record = recordIn(state);
          await expectLater(
            store.createIfAbsent(record),
            throwsA(isA<InvalidOperationRecordException>()),
          );
          expect(
            await store.read(
              id: record.identity.id,
              scope: record.identity.scope,
            ),
            isNull,
          );
        });
      }
    }

    for (final entry in <String, OperationIdentity>{
      'scope': identity(scope: 'another-account'),
      'type': identity(type: 'another-type'),
      'key': identity(idempotencyKey: 'another-key'),
      'fingerprint': identity(requestFingerprint: 'another-fingerprint'),
    }.entries) {
      test('create conflict in ${entry.key} leaves original intact', () async {
        final original = await seedState(store, OperationState.prepared);
        await expectLater(
          store.createIfAbsent(
            OperationRecord.prepared(identity: entry.value, at: epoch),
          ),
          throwsA(isA<OperationIdentityConflictException>()),
        );
        expectSnapshot(
          await store.read(
            id: original.identity.id,
            scope: original.identity.scope,
          ),
          original,
        );
      });

      for (final stale in [false, true]) {
        test(
          'CAS conflict in ${entry.key}, stale=$stale, leaves original intact',
          () async {
            final original = await seedState(
              store,
              OperationState.awaitingOutcome,
            );
            final replacement = OperationRecord.restore(
              identity: entry.value,
              state: OperationState.awaitingOutcome,
              version: stale ? 1 : 2,
              createdAt: epoch,
              updatedAt: epoch.add(const Duration(seconds: 5)),
            );
            await expectLater(
              store.compareAndSwap(replacement, expectedVersion: stale ? 0 : 1),
              throwsA(isA<OperationIdentityConflictException>()),
            );
            expectSnapshot(
              await store.read(
                id: original.identity.id,
                scope: original.identity.scope,
              ),
              original,
            );
          },
        );
      }
    }

    test('different IDs have independent records', () async {
      final first = await seedState(store, OperationState.prepared);
      final second = await seedState(
        store,
        OperationState.prepared,
        operationIdentity: identity(id: 'another-id'),
      );
      expectSnapshot(
        await store.read(id: first.identity.id, scope: first.identity.scope),
        first,
      );
      expectSnapshot(
        await store.read(id: second.identity.id, scope: second.identity.scope),
        second,
      );
    });

    test('concurrent conditional updates have exactly one winner', () async {
      final original = await seedState(store, OperationState.awaitingOutcome);
      final candidates = [
        for (var index = 0; index < 12; index++)
          machine.applyObservation(
            original,
            OperationPending(identity: original.identity),
            at: epoch.add(Duration(seconds: index + 2)),
          ),
      ];
      final results = await Future.wait([
        for (final candidate in candidates)
          store.compareAndSwap(candidate, expectedVersion: original.version),
      ]);
      expect(results.where((updated) => updated), hasLength(1));
      expectSnapshot(
        await store.read(
          id: original.identity.id,
          scope: original.identity.scope,
        ),
        candidates[results.indexOf(true)],
      );
    });

    test('CAS does not create a missing record', () async {
      final replacement = recordIn(OperationState.awaitingOutcome);
      expect(
        await store.compareAndSwap(replacement, expectedVersion: 0),
        isFalse,
      );
      expect(
        await store.read(id: identity().id, scope: identity().scope),
        isNull,
      );
    });

    for (final expected in [-1, 0, 2]) {
      test(
        'invalid expected/replacement version relation $expected is rejected',
        () async {
          final original = await seedState(
            store,
            OperationState.awaitingOutcome,
          );
          final next = machine.applyObservation(
            original,
            OperationUnknown(identity: identity()),
            at: epoch.add(const Duration(seconds: 2)),
          );
          await expectLater(
            store.compareAndSwap(next, expectedVersion: expected),
            throwsA(isA<InvalidOperationRecordException>()),
          );
          expectSnapshot(
            await store.read(id: identity().id, scope: identity().scope),
            original,
          );
        },
      );
    }

    for (final newerState in [
      OperationState.awaitingOutcome,
      OperationState.succeeded,
      OperationState.rejected,
    ]) {
      test(
        'stale snapshot cannot overwrite newer ${newerState.name}',
        () async {
          final original = await seedState(
            store,
            OperationState.awaitingOutcome,
          );
          final stale = machine.applyObservation(
            original,
            OperationUnknown(identity: identity()),
            at: epoch.add(const Duration(seconds: 2)),
          );
          final observation = switch (newerState) {
            OperationState.succeeded => OperationSucceeded(
              identity: identity(),
            ),
            OperationState.rejected => OperationRejected(identity: identity()),
            _ => OperationPending(identity: identity()),
          };
          final newer = machine.applyObservation(
            original,
            observation,
            at: epoch.add(const Duration(seconds: 3)),
          );
          expect(await store.compareAndSwap(newer, expectedVersion: 1), isTrue);
          expect(
            await store.compareAndSwap(stale, expectedVersion: 1),
            isFalse,
          );
          expectSnapshot(
            await store.read(id: identity().id, scope: identity().scope),
            newer,
          );
        },
      );
    }

    for (final terminal in [
      OperationState.succeeded,
      OperationState.rejected,
    ]) {
      for (final replacementState in [
        OperationState.awaitingOutcome,
        OperationState.succeeded,
        OperationState.rejected,
      ]) {
        test(
          'current-version rewrite ${terminal.name} -> ${replacementState.name} fails',
          () async {
            final original = await seedState(store, terminal);
            final replacement = OperationRecord.restore(
              identity: original.identity,
              state: replacementState,
              version: original.version + 1,
              createdAt: original.createdAt,
              updatedAt: epoch.add(const Duration(seconds: 5)),
              lastObservation: switch (replacementState) {
                OperationState.succeeded => OperationSucceeded(
                  identity: identity(),
                ),
                OperationState.rejected => OperationRejected(
                  identity: identity(),
                ),
                _ => null,
              },
            );
            await expectLater(
              store.compareAndSwap(
                replacement,
                expectedVersion: original.version,
              ),
              throwsA(isA<IllegalOperationTransitionException>()),
            );
            expectSnapshot(
              await store.read(id: identity().id, scope: identity().scope),
              original,
            );
          },
        );
      }
    }

    for (final changedField in ['createdAt', 'updatedAt']) {
      test('CAS rejects invalid $changedField without a write', () async {
        final original = await seedState(store, OperationState.awaitingOutcome);
        final replacement = OperationRecord.restore(
          identity: identity(),
          state: OperationState.awaitingOutcome,
          version: 2,
          createdAt: changedField == 'createdAt'
              ? epoch.subtract(const Duration(seconds: 1))
              : epoch,
          updatedAt: changedField == 'updatedAt'
              ? epoch
              : epoch.add(const Duration(seconds: 3)),
        );
        await expectLater(
          store.compareAndSwap(replacement, expectedVersion: 1),
          throwsA(isA<InvalidOperationRecordException>()),
        );
        expectSnapshot(
          await store.read(id: identity().id, scope: identity().scope),
          original,
        );
      });
    }

    test(
      'listing filters scope and terminal records and is an immutable snapshot',
      () async {
        final expected = <OperationRecord>[];
        for (final state in OperationState.values) {
          final own = await seedState(
            store,
            state,
            operationIdentity: identity(id: 'own-${state.name}'),
          );
          if (state.isUnresolved) expected.add(own);
          await seedState(
            store,
            state,
            operationIdentity: identity(
              id: 'foreign-${state.name}',
              scope: 'foreign',
            ),
          );
        }
        final snapshots = await store.listUnresolved(scope: identity().scope);
        expect(
          snapshots.map((record) => record.identity.id),
          unorderedEquals(expected.map((record) => record.identity.id)),
        );
        expect(await store.listUnresolved(scope: 'missing-scope'), isEmpty);
        expect(() => snapshots.clear(), throwsUnsupportedError);
        final original = expected.firstWhere(
          (record) => record.state == OperationState.prepared,
        );
        final next = machine.beginSubmission(
          original,
          identity: original.identity,
          at: epoch,
        );
        expect(await store.compareAndSwap(next, expectedVersion: 0), isTrue);
        expectSnapshot(
          snapshots.firstWhere(
            (record) => record.identity.id == original.identity.id,
          ),
          original,
        );
        await seedState(
          store,
          OperationState.prepared,
          operationIdentity: identity(id: 'later'),
        );
        expect(snapshots, hasLength(3));
      },
    );

    test('equal update timestamp is permitted with a new version', () async {
      final original = await seedState(store, OperationState.awaitingOutcome);
      final next = machine.applyObservation(
        original,
        OperationUnknown(identity: identity()),
        at: original.updatedAt,
      );
      expect(await store.compareAndSwap(next, expectedVersion: 1), isTrue);
      expectSnapshot(
        await store.read(id: identity().id, scope: identity().scope),
        next,
      );
    });
  });
}
