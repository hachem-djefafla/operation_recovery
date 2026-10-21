# operation_recovery

A pure Dart package for operations whose backend outcome is uncertain.
A lost response cannot establish whether a write succeeded. Recovery must ask
the authoritative backend instead of automatically sending the write again.

## Implementation status

Version **0.1.0 is prepared for release and remains unpublished**. The package
provides immutable domain records, atomic scoped storage, typed handlers, explicit
submission, lookup-only reconciliation, and a separate SQLite reference adapter.
The developer independently verified on Windows: **539 core, 90 storage, 58 codec,
and 32 real process tests**. The lost-response crash demo used exactly one HTTP
submission, one backend effect, and one lookup, with SQLite 3.54.0, WAL/FULL.
Memory tests alone do not establish crash recovery.

The repository includes MIT licensing, API/integration guides, separate quality and
reliability workflows, coverage and archive checks, and consumer verification.
Linux, Dart 3.10 execution, hosted GitHub Actions and publication validation remain
release gates. See [CONTRIBUTING.md](CONTRIBUTING.md) for verification commands and
required CI checks. Source:
[hachem-djefafla/operation_recovery](https://github.com/hachem-djefafla/operation_recovery).

Core has no runtime dependencies and no Flutter, HTTP, or database imports.
The SQLite dependency belongs only to that separate example package.

## Public domain API

For a local checkout, resolve the core and separate example dependencies before
whole-tree analysis. See [contribution commands](CONTRIBUTING.md) for the complete
sequence. The package is not published; use a local path dependency during review:

```yaml
dependencies:
  operation_recovery:
    path: ../operation_recovery
```

The [API integration guide](doc/api_overview.md) covers handlers, startup recovery,
authentication, account switching, and shutdown. Run
`dart run example/public_api_smoke.dart` for a minimal public-import workflow, or
`dart run example/main.dart` for a real HTTP response-loss example.

After publication, replace the path dependency with `operation_recovery: ^0.1.0`.
The declared Dart minimum is 3.10. Windows is independently verified; Linux is a
declared CI target awaiting its first successful hosted run. SQLite stays in the
separate example package and does not become a core dependency.

Import `package:operation_recovery/operation_recovery.dart`.

| Type | Responsibility |
| --- | --- |
| `OperationIdentity` | Validated immutable identity, value equality, conflict checks |
| `OperationRecord` | Prepared construction and validated snapshot restoration |
| `RecoveryMetadata` | Persisted lookup reservations, cumulative attempts, and next-check time |
| `OperationState` | Five states with terminal/unresolved classification |
| `BackendObservation` | Closed set of semantic backend observations |
| `LookupFailureReason` | Authentication, transport, or service unavailability |
| `OperationRecoveryException` | Base of the exported typed domain exceptions |

```dart
final identity = OperationIdentity(
  id: 'op-123',
  scope: 'account-456',
  type: 'transfer',
  idempotencyKey: 'key-123',
  requestFingerprint: 'sha256:application-provided',
);
final snapshot = OperationRecord.prepared(
  identity: identity,
  at: DateTime.utc(2026, 10, 20),
);
assert(snapshot.state == OperationState.prepared);
assert(snapshot.state.isUnresolved);
```

This creates domain data only. It performs no persistence or submission.
Run the HTTP lost-response example with `dart run example/main.dart`. It submits
once, loses the response after the simulated backend applies the operation, and
resolves the outcome by lookup. Its storage is memory-only.

Backend observations are `OperationSucceeded`, `OperationRejected`,
`OperationPending`, `OperationUnknown`, and `LookupUnavailable`. The last can
carry `LookupFailureReason.authenticationRequired`; expired credentials and
HTTP 401 during reconciliation must map to that recoverable condition.

The state machine and storage coordinator live under `lib/src/` and are not
exported. All coordinator state changes use the state machine. The coordinator
serializes each complete storage-handler-storage sequence per operation ID.

## Public recovery API

This workflow uses the real loopback backend from
[example/main.dart](example/main.dart), which drops a successful response.
Applications supply their own `OperationHandler` with authoritative status lookup
and no HTTP write retries. Run this within `example/`, alongside its backend source:

```dart
import 'package:operation_recovery/operation_recovery.dart';
import 'simulated_backend.dart';

Future<void> main() async {
  final backend = await SimulatedBackend.start();
  final registration = OperationRegistration<String>(
    type: 'transfer',
    handler: DemoHttpHandler(backend.baseUri),
  );
  final recovery = OperationRecovery(
    scope: 'account-456',
    store: MemoryOperationStore(),
    handlers: [registration],
    policy: RecoveryPolicy(
      maxAttempts: 3,
      initialDelay: const Duration(seconds: 1),
      maxDelay: const Duration(seconds: 8),
    ),
  );
  final identity = OperationIdentity(
    id: 'op-123',
    scope: 'account-456',
    type: 'transfer',
    idempotencyKey: 'key-123',
    requestFingerprint: 'sha256:application-provided',
  );
  try {
    final uncertain = await recovery.start(
      registration,
      identity: identity,
      request: 'demo transfer',
    );
    print(uncertain.state); // awaitingOutcome after response loss
    final confirmed = await recovery.reconcile(identity);
    print(confirmed.state); // succeeded after authoritative lookup
  } finally {
    await recovery.close();
    await backend.close();
  }
}
```

Implement `OperationHandler<TRequest>` with separate `submit` and `lookupStatus`
methods. Register it using an `OperationRegistration<TRequest>` token and pass that
same token to `start`. Construct one `OperationRecovery` per scope with a store,
the registrations, and an explicit `RecoveryPolicy`. Request data is transient;
the application supplies its matching fingerprint and owns credentials.

| API | Behavior |
| --- | --- |
| `start(registration, identity: ..., request: ...)` | Submit once only after this invocation acknowledges its uncertainty CAS |
| `get(id)` | Read a scoped snapshot |
| `reconcile(identity)` | Reserve and perform one due lookup; never submit |
| `reconcilePending(concurrency: ...)` | Process due records with per-operation success/failure results |
| `resume(identity)` | Reset an attention record's cycle budget without dispatching |
| `events` | Asynchronous committed-snapshot notifications, including reservations |
| `close()` | Stop new/queued work and drain already-dispatched handlers and saves |

Failed or ambiguous uncertainty acknowledgements never permit submission,
including after a successful read. Recovery uses persisted attempt reservations
and bounded exponential backoff. Exhaustion pauses in `needsAttention`; explicit
resume enables lookups only. Handlers own deadlines and must disable write retry
middleware. Observer exceptions cannot change committed business state.

On startup, open the existing durable database, recreate handlers for the same
scope, and call `reconcilePending()`. No background polling or write replay runs
automatically. Restore expired credentials in the application, honor persisted
due times, and use `resume(identity)` explicitly if recovery reached attention.
Subscribe to `events` for live committed snapshots and use `get` for current state.
On logout, await `close()` before releasing the old account's clients/credentials;
create a new scoped facade for the next account and close stores separately.

One coordinator serializes matching IDs; independent IDs can progress concurrently.
Multiple coordinators/processes have no shared handler-ownership guarantee.
Shutdown waits for dispatched handlers to settle and does not own stores/clients.
See the [recovery contract](doc/recovery_contract.md) for precise semantics and the
[runnable example](example/main.dart) for integration.

## Public storage API

`OperationStore` defines atomic create-if-absent, versioned compare-and-swap,
scoped reads, and scoped unresolved listing. `MemoryOperationStore` is the
non-durable reference implementation:

```dart
final store = MemoryOperationStore();
await store.createIfAbsent(snapshot);
final stored = await store.read(id: identity.id, scope: identity.scope);
```

Use this snippet inside an async function. Memory atomicity applies only to calls
sharing one instance within one isolate's execution context. It does not provide
sharing or atomicity across processes/isolates, or persistence across restarts.

Foreign-scope and missing reads both return null. Conflicting writes fail without
modification. Lists contain only unresolved records in the requested scope.

`OperationStoreWriteException` distinguishes definitely uncommitted writes from
unknown commit outcomes through `StoreCommitStatus`. Neither is an acknowledgement.
The coordinator surfaces CAS conflicts with `OperationStoreConflictException`
without retrying or refreshing the version. See the storage contract for details.

## Contracts and verification

- [Architecture and verification boundaries](doc/architecture.md)
- [State machine, identity, and validation](doc/domain_contract.md)
- [Storage, concurrency, and scope guarantees](doc/storage_contract.md)
- [Submission, reconciliation, events, and shutdown](doc/recovery_contract.md)
- [SQLite persistence and serialization](doc/sqlite_persistence_contract.md)
- [Backend integration contract](doc/backend_contract.md)
- [Failure model and acceptance matrix](doc/failure_model.md)
- [Architecture decisions](doc/adr/README.md)
- [Case study: a successful write with a lost response](doc/recovery_case_study.md)
- [Contribution and CI instructions](CONTRIBUTING.md)

From this directory:

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

Licensed under [MIT](LICENSE). Core coverage measured through the source-mode
runner is 99.33% (442/445 executable lines). Hosted CI, Linux/minimum-SDK execution,
and final publication validation remain open release gates.
`publish_to: none` prevents accidental publication.
