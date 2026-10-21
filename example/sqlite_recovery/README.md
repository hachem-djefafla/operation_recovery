# SQLite reference and real crash-recovery demonstration

This separate, unpublished Dart package implements `OperationStore` using SQLite.
The main `operation_recovery` package keeps zero runtime dependencies. This example
uses `sqlite3` 3.7.1 and its bundled native library; a separate Windows SQLite
installer is unnecessary. Dart 3.10 or newer is required.

**Verification status:** the developer independently passed 90 storage, 58 codec,
and 32 real process tests on Windows. The lost-response demonstration confirmed
one HTTP submission, one backend effect, and one lookup using SQLite 3.54.0,
WAL and synchronous=FULL. Linux, minimum Dart 3.10 and hosted CI remain release
gates. See the [contribution guide](../../CONTRIBUTING.md) for current verification
commands and CI requirements.

## Run on Windows

From PowerShell:

```powershell
Set-Location D:\development\flutter\packages\operation_recovery\example\sqlite_recovery
dart pub get
dart run tool/verify_native.dart
dart build cli --target=bin/crash_worker.dart --output=build/crash_worker
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test test/storage test/codec
dart test test/process --concurrency=1
dart run bin/crash_demo.dart --scenario=lost-response
```

The initial dependency/build steps require access to pub.dev and the native
library release assets. Keep the generated `pubspec.lock` for reproducibility;
the example's ignore rules allow it to be committed. No lockfile is fabricated
when resolution cannot complete.

Use `dart build cli`, which runs native build hooks and bundles shared libraries.
Keep the entire `build/crash_worker/bundle` directory together. The harness launches
its worker executable directly, including `.exe` on Windows. It does not kill a
`dart run` wrapper. Always rebuild after worker or adapter source changes.

The same commands work from the package directory on Linux; build the worker on
Linux, rather than copying the Windows executable. Windows/Linux runtime results
must be recorded separately.

Run earlier tests from the main package too:

```powershell
Set-Location ..\..
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

## What the demo checks

The parent starts an independent HTTP backend process and a client process. The
backend applies one effect, deliberately severs its response, and remains alive.
After receiving a deterministic checkpoint, the parent forcibly kills the client
without closing its facade or database. A new client opens the same SQLite file,
loads the original identity and unresolved state, and confirms success by lookup.
A further client reopens and verifies that terminal state was persisted.

The demo fails unless submission requests = 1, business effects = 1, lookups >= 1,
and final state = succeeded. It prints process checkpoints, effective SQLite
configuration, and counters. The developer's Windows run met these assertions;
the restricted agent host does not claim its own new process execution.
Temporary databases are owned by the harness and removed
afterward. No production backend or credentials are used.

Other `--scenario=` values:

| Value | Crash point |
| --- | --- |
| `prepared` | Prepared record committed, before uncertainty |
| `before-submit` | Uncertainty acknowledged, before HTTP dispatch |
| `uncertainty-ack-lost` | Uncertainty committed, acknowledgement withheld |
| `in-flight` | HTTP request received, before backend effect |
| `lost-response` | Backend effect committed, response lost, before local result |
| `lookup-before-save` | Authoritative lookup received, before terminal CAS |
| `attempts` | Second recovery reservation committed, before lookup |
| `last-reservation` | Last permitted reservation committed, before lookup |
| `authentication` | Lost response; restart receives 401; another restart restores credentials and confirms by lookup |

Process tests additionally cover corrupted/unsupported persistence, concurrent
SQLite create/CAS calls, backend counter integrity, and death inside an uncommitted
transaction. Barriers use structured stdin/stdout messages, fake-clock commands,
and forced process termination. Safety deadlines never arrange the crash timing.
Missing workers and unsupported process execution fail tests; they are not skips.

`tool/verify_native.dart` verifies that resolution selected package 3.7.1, opens
SQLite through Dart FFI, verifies WAL/FULL through the adapter, and records the
SQLite version/source ID and host SDK in `build/native-evidence.json`. It does not
invoke `sqlite3.exe`. The native worker build separately verifies native-asset
bundling and process execution.

The pinned [3.7.1 manifest](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.7.1/sqlite3/pubspec.yaml)
declares Dart >=3.10. Its [build hook](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.7.1/sqlite3/hook/build.dart)
registers the precompiled library as a bundled dynamic code asset. This project
does not override the default hook with an external/system SQLite. Dart's
[build command](https://dart.dev/tools/dart-build) executes hooks and produces the
executable plus shared-library bundle. Source inspection establishes the intended
mechanism; only successful FFI/build/process runs establish runtime evidence.

## Adapter integration

Import `package:operation_recovery_sqlite_example/sqlite_operation_store.dart`.

Use `SqliteOperationStore.create(path)` only during deliberate first-time setup;
it refuses existing files. During recovery use `SqliteOperationStore.open(path)`;
it refuses missing, uninitialized, incompatible, or unsupported databases.
Do not catch an open failure and replace the database with a new empty one.

Given your application's handler registrations, scope, and recovery policy:

```dart
final store = SqliteOperationStore.open(existingDatabasePath);
final recovery = OperationRecovery(
  scope: accountScope,
  store: store,
  handlers: registrations,
  policy: recoveryPolicy,
);
try {
  await recovery.reconcilePending();
} finally {
  await recovery.close();
  store.close();
}
```

Inspect `store.configuration` immediately after opening for the effective SQLite
version, WAL mode, synchronous setting, and busy timeout. It contains no paths or
operation data. Requests and credentials remain application-owned.

See the [persistence contract](../../docs/sqlite_persistence_contract.md) for the
schema, codec, atomicity, error classification, and guidance for custom adapters.

## Boundaries

Require SQLite >= 3.51.3, WAL and synchronous=FULL on a supported local filesystem.
There is no rollback-journal fallback. One connection executes short synchronous
transactions behind the asynchronous port; it may block its isolate during disk
I/O. No transaction awaits a handler/network call.

Use one active recovery coordinator per scope. Concurrent raw-store tests prove
SQLite atomicity, not handler ownership across coordinators or processes. There
are no automatic business-write retries, background execution, or exactly-once
claims. This is not a production mobile persistence integration.

An operation can remain unresolved if the client dies after committing uncertainty
but before sending. The backend may have no authoritative evidence distinguishing
absence from delayed visibility. Recovery spends its lookup budget and can require
attention; uncertainty never grants permission to repeat a business write.

Never delete WAL sidecars to resolve an error. SQLite process-crash recovery relies
on preserving the database and its WAL. These tests do not prove survival of
arbitrary power loss, broken filesystem locking, or dishonest hardware flushes.
