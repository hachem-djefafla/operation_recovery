# SQLite persistence and serialization contract

Implementation lives in the separate [SQLite example](../example/sqlite_recovery/README.md).
The main library does not import SQLite, HTTP, filesystem, or platform APIs.
The developer verified native storage and real process recovery on Windows.
The maintainer also confirmed Windows/Linux release CI on Dart 3.10.0 and stable;
see the
[contribution guide](../CONTRIBUTING.md) for reproducible verification.

## Initialization, opening, and versions

The database is dedicated to this adapter. `SqliteOperationStore.create(path)`
exclusively creates a new file and initializes it in a transaction. It cannot
replace an existing file or proceed over orphan WAL/SHM sidecars. `open(path)` uses SQLite read-write mode without create;
missing and uninitialized files fail. Failed initialization may leave an unusable
file for inspection; opening never silently initializes or repairs it.

`application_id = 0x4F524543` identifies the format. `user_version = 1` identifies
the database schema. Every row also has `record_schema_version = 1`, independent
of its optimistic-concurrency version. Unknown database versions/application IDs
fail opening. Unknown row versions fail restoration. These are not prepared data.

Opening validates table columns, types, nullability, primary key, scope index,
binary key/index collations, and STRICT mode. It rejects unexpected user schema
objects and missing structure. It does not run a full-record scan across accounts;
rows are validated only when selected in the requested scope or accessed by a write.

There is no speculative migration framework. Version 1 is the sole supported
format. A future change must introduce explicit version-to-version SQL/codec
migration, transactional conversion, rollback tests, and backup instructions.
Missing metadata cannot be interpreted as legacy defaults under format 1.

## Version-one schema

`operations` is a STRICT table with the following columns. Nullable fields are
listed explicitly; all others are required.

| Columns | SQLite type / meaning |
| --- | --- |
| operation_id | TEXT, NOT NULL PRIMARY KEY, BINARY comparison; globally unique |
| scope | TEXT, BINARY comparison; account/application scope |
| operation_type, idempotency_key, request_fingerprint | TEXT; remaining immutable identity |
| record_schema_version | INTEGER; explicit format version |
| state | TEXT; stable state tag |
| record_version | INTEGER; optimistic-concurrency revision |
| created_at_us, updated_at_us | INTEGER; UTC Unix microseconds |
| observation_kind | Nullable TEXT; latest semantic observation |
| backend_reference, rejection_code, lookup_failure_reason | Nullable TEXT; observation-specific metadata |
| cycle_attempts, total_attempts | INTEGER; current and cumulative lookup reservations |
| last_attempt_at_us, next_check_at_us | Nullable INTEGER; reservation and due timestamps |

`operations_by_scope` indexes scope. SQL CHECK constraints provide basic shape
guards. The codec/domain validation remains mandatory, including for data inserted
through another connection. SQL state filtering never hides invalid scoped rows:
unresolved listing decodes all rows selected by exact scope, then filters states.
This favors corruption visibility over a more selective state index.

State tags are `prepared`, `awaiting_outcome`, `needs_attention`, `succeeded`, and
`rejected`. Observation tags are `succeeded`, `rejected`, `pending`, `unknown`, and
`unavailable`. Failure tags are `authentication_required`, `transport_failure`,
and `service_unavailable`. Explicit switches decouple persistence from enum order
and Dart identifier spelling.

Absent observation requires null observation metadata. References belong only to
success, codes only to rejection, reasons only to unavailability. A lookup reason
is required for unavailability. Observation identity is reconstructed from the
same immutable row identity, rather than a second mutable copy.

Timestamps preserve microseconds as signed SQLite integers, restored with UTC
DateTime constructors and range/round-trip validation. Identity text is retained
exactly; encoding rejects strings that UTF-8 would replace. There is no timezone,
floating-point, trimming, enum-ordinal, or missing-field fallback.

After validating types/tags, decoding calls observation constructors,
`RecoveryMetadata.restore`, and `OperationRecord.restore`. Existing domain checks
enforce counter, state, version, observation, and timestamp consistency. Both
cycle and total counts are required even when zero. Reservations, observations,
and scheduling are replaced in the same row transaction.

No payload, token, password, raw response, or raw exception column exists. Identity
and opaque result metadata can still be sensitive in an application; filesystem
permissions, encryption requirements, retention, and explicit logging are owned
by the integrator. This example provides no secure-deletion or encryption claim.

## Atomic operations and acknowledgement

Creation validates prepared/version-zero input, begins IMMEDIATE, reads the ID,
validates existing identity/record, or inserts once. It never uses REPLACE. Matching
existing identity returns false without modifying any state or creation time.

CAS validates its input revision first. Within IMMEDIATE it reads current data,
checks complete identity before version, then checks terminal immutability,
unchanged creation time, and nondecreasing update time. Its UPDATE predicate
includes full identity, expected revision, and a nonterminal-state fence. It checks
affected rows. Missing/stale records return false without refreshing/replaying.

Each transaction contains synchronous SQLite calls only. There are no callbacks,
awaits, or network calls inside it. The adapter implements storage invariants,
not domain transitions. Raw-port callers remain trusted snapshot producers; the
existing coordinator continues to generate transitions through the state machine.

True requires successful COMMIT and autocommit restoration. False follows confirmed
no-change cleanup. Native I/O/locking failures are safely translated:

| Knowledge | Public result |
| --- | --- |
| No commit attempted; rollback/no transaction established | OperationStoreWriteException(notCommitted) |
| COMMIT attempted but success not acknowledged, or cleanup cannot establish transaction state | OperationStoreWriteException(unknown) |
| COMMIT successfully acknowledged | true |
| Conditional no-op with successful cleanup | false |

Commit-stage failure remains unknown even after cleanup. Such a connection is
closed and cannot be reused to infer success. Neither error status authorizes
submission; readback and reopening do not retroactively change the failed call.

Operational read/list failures use `OperationStoreReadException`. Invalid stored
format/domain data uses existing safe validation exceptions, rather than native
SQL errors containing parameters. `SqliteStoreOpenException` exposes only an
example-local failure category. No public core exception classes are extended.

## Scope, configuration, and durability assumptions

Reads apply exact ID and scope predicates before decoding. Foreign/missing records
both return null, including malformed foreign records. Listings select only exact
scope. Conflicting writes disclose no record contents and cannot modify the row.

Each connection verifies SQLite >= 3.51.3, `journal_mode=wal`, `synchronous=2`
(FULL), and `busy_timeout=5000`. Unsupported WAL fails opening. There is no
configuration downgrade, application retry loop, or database abstraction layer.
The timeout bounds SQLite lock waiting; it does not retry a business write.
`configuration` exposes effective connection settings without row/path data.

SQLite synchronizes a WAL commit before acknowledgement under FULL. This depends
on a supported local filesystem, correct OS/VFS locking and synchronization, and
hardware honoring flush requests. Network filesystems, arbitrary disk faults,
power-loss survival, and mobile lifecycle behavior are not established by these
process tests. See [SQLite synchronization](https://www.sqlite.org/pragma.html#pragma_synchronous)
and [WAL behavior](https://www.sqlite.org/wal.html).

Keep WAL files with their database. Never manually delete WAL/SHM to recover from
an error or copy only the main file while a WAL database is active. Use SQLite's
backup facilities or a documented closed/checkpointed backup procedure. Normal
close delegates checkpoint/sidecar management to SQLite. There is no custom
checkpoint scheduler or requirement to checkpoint after every acknowledged commit.

One active recovery coordinator per scope remains the supported model. Multiple
raw SQLite connections can test atomicity without making concurrent handler
ownership supported. Drain the facade before closing the adapter. Slow disk I/O
blocks this synchronous adapter's isolate; applications adapting this example
must assess their platform/performance needs separately.

## Implementing another durable adapter

Implement the existing `OperationStore` port and reuse its conformance suite.
Preserve exact identity, revision ordering, scoped reads, timestamps, and immutable
terminal records. Persist every recovery field atomically. Translate ambiguous
acknowledgements conservatively; never return a proposed snapshot after a failure.
Keep codec validation distinct from trusted domain transition generation. Document
the actual durability boundary and prove it with fresh-process tests appropriate
to that storage system. No alternate recovery facade or submission token is needed.
