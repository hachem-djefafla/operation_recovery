# Architecture

The package coordinates client knowledge of a backend operation. It cannot
guarantee exactly-once backend execution. A timeout and an authentication failure
are observations about communication, not authoritative business outcomes.

## Boundaries

- Domain: immutable identity and records, semantic backend observations, typed
  exceptions, and pure transition logic. No I/O, timers, persistence, or ambient
  time. The internal state machine produces proposed snapshots only.
- Application (Milestone 4 implemented): a public recovery facade backed by one
  scoped coordinator with full-sequence per-ID serialization, explicit conflicts,
  state-machine-only mutations, typed registrations, policy, and notifications.
- Ports: atomic scoped storage, typed submission/status handlers, and an injectable
  clock. The core does not depend on any network or database implementation.
- Adapters: memory reference adapter implemented for one in-memory context only.
  Simulated HTTP backends/handlers live outside core. The separate SQLite example
  and real process-crash harness are implemented for Milestone 5. The developer
  initially verified native storage and 32 process tests on Windows. The
  maintainer subsequently confirmed Windows/Linux release CI on Dart 3.10.0 and
  stable; see the [contribution guide](../CONTRIBUTING.md).

Only deliberate exports from `lib/operation_recovery.dart` are supported public
API. The state machine remains internal until an actual public use case requires
it. There are no empty future infrastructure layers or placeholder facades.

## Implemented storage coordination

The internal coordinator provides prepare, read/list, persist uncertainty, apply
supplied observations, pause, and resume, plus submission and reconciliation through
application-supplied handlers. Mutations use the existing state machine; there is
no arbitrary replacement API or reusable submission permission.
Only state-machine changes with successful CAS acknowledgements return new records.
No-ops skip CAS; failures and conflicts surface without replay or success-by-reread.

Scoped reads conceal both foreign and absent records with null. Conflicting writes
fail without changes. Incoming foreign identities are rejected before store access.
See [the storage contract](storage_contract.md) for the exact ordering and guarantees.

## Implemented business orchestration

One coordinator is bound to one immutable account/application scope. Operation
IDs are globally unique within a store. Identity includes scope, type, request
fingerprint, and idempotency key. Reads never expose a foreign record or its
existence; conflicting writes fail without exposing the record's contents.

A typed registration binds a stable type string to `OperationHandler<TRequest>`.
Explicit `start` receives that registration, an identity, and transient request data.
Neither raw requests nor credentials enter default records or diagnostics.
The application owns fingerprint canonicalization and payload consistency.

Submission order is: create prepared record; acknowledge the uncertainty commit
under the adapter's persistence guarantee; then call the handler once. Memory
acknowledges only its in-memory change. Repeating `start` for matching identity after the
uncertainty transition reads the existing record instead of submitting again.
A prepared record requires another explicit start and fresh request data.

Reconciliation is application-driven and performs lookups only for due
`awaitingOutcome` records. It skips prepared, attention, and terminal records.
Explicit resume reopens an attention record for lookups, never submission.
Persist recovery attempt reservations and next-check times before lookup.
Recovery policy limits and bounded exponential backoff are explicit application
configuration. Reservation counters are persisted separately from record versions.

Serialize activity per operation in one coordinator; allow different IDs to
progress independently. Version checks protect stored snapshots, not server
side effects or multiple process ownership. Do not hold database transactions
open across network calls. HTTP handlers must disable write retry middleware.

## Verification coverage

1. Contracts, ADRs, scaffolding, acceptance matrix.
2. Domain model and exhaustive deterministic transition tests.
3. Storage port, memory adapter, concurrency and storage fault tests.
4. Submission/reconciliation and lost-response/authentication/stale-response tests.
5. SQLite integration and actual process-termination recovery tests.
6. Documentation, CI, licensing, and publication checks.

Milestone 4 establishes storage-contract, local coordination, submission-gating,
and lookup-only recovery behavior, including real HTTP lost-response tests.
It does not establish storage durability or ownership across coordinators/processes.
Milestone 5 adds SQLite persistence and real process-crash evidence. See the
[acceptance matrix](failure_model.md) for verification coverage and release limits.
