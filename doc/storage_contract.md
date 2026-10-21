# Storage and coordination contract

## Responsibilities

`OperationStore` provides atomic creation, conditional replacement, scoped reads,
and unresolved snapshots. Adapters enforce identity, version, time, and terminal
immutability invariants. They do not interpret backend authority or implement the
domain transition graph. Callers of the raw port are trusted snapshot producers.

The internal `RecoveryCoordinator` supplies the domain boundary: every mutation
reads the current scoped record, calls the existing `OperationStateMachine`, and
conditionally commits its result. It accepts no replacement snapshot or arbitrary
mutation callback. Preparing a new identity creates only a version-zero prepared
record; duplicate preparation never resets the existing state.

Milestone 4 extends the same coordinator to hold each ID's queue across the entire
storage-handler-storage sequence. All proposed changes, including reservation,
completion, and resume, still pass through the state machine.

## Scope isolation

IDs are globally unique within a store, not reusable namespaces per account.
`read(id: ..., scope: ...)` returns null for both absent and foreign-scope IDs,
without an existence-specific error or record metadata. Unresolved listings are
scope-filtered, exclude terminal records, and return an unmodifiable snapshot.

Writes that reuse an ID with different scope/type/key/fingerprint fail without
changing the original. Write conflicts disclose no existing record contents.
Write conflict behavior is distinct from the read non-disclosure requirement.

The coordinator is bound to one nonblank scope. Incoming foreign-scope identities
and observations are rejected before any store call. Read/list scope fences also
exclude misrouted foreign results. Domain actions addressing a missing record or
an ID visible only in another scope produce the same `OperationNotFoundException`.
Adapters still require correct application authorization; a scope parameter is
not an authentication mechanism.

## Atomic writes

`createIfAbsent` accepts prepared version-zero snapshots only. Its atomic check
and insertion return true for creation and false for existing matching identity.
An existing matching identity may already be unresolved, paused, or terminal;
neither its data nor creation time is overwritten.

`compareAndSwap(replacement, expectedVersion: ...)`:

1. Reject a negative expected version or a replacement not exactly one version
   higher. This is argument validation, before checking stored data.
2. Within one atomic operation, locate the ID, verify full identity, check current
   version, verify storage invariants, and replace.
3. A missing ID or stale version returns false without writing. Identity conflicts
   throw, including when the expected version is stale.
4. After a version match, reject terminal rewrites, changed creation times, and
   update-time regression. Equal update times with a new version are permitted.

CAS is not an upsert. Terminal no-ops are recognized by the state machine and do
not reach CAS. A stale update never becomes valid by refreshing its version.

## Acknowledgements and failures

True acknowledges the adapter's documented persistence guarantee. For a durable
adapter that must include its durable commit; for memory it is only a memory change.
False confirms that the conditional operation did not write.

Operational read/list failures use `OperationStoreReadException`. Operational
write failures use `OperationStoreWriteException` with one of:

- `StoreCommitStatus.notCommitted`: the invocation definitely did not commit.
- `StoreCommitStatus.unknown`: it may have committed; a lost acknowledgement is
  always represented this way, even in a test that knows the underlying write happened.

Neither exception is success. The coordinator propagates errors, including
unexpected adapter exceptions. It does not reread, retry, or return a proposed
snapshot after an unsuccessful acknowledgement. A CAS false becomes an explicit
`OperationStoreConflictException` containing the expected version only.

A later explicit read may reveal that an ambiguous write committed. This does
not alter the failed invocation or authorize business submission. Retrying the
uncertainty action against an already awaiting record is an illegal transition.
The public `start` API submits only on this invocation's acknowledged uncertainty
CAS path. There is no stored or reusable submission-permission object.

## Coordination and memory limits

Complete coordinator operations use per-ID FIFO queues. Reads for that ID wait
behind its current action. Errors release queued successors, and idle queue entries
are removed. Different IDs progress independently. Listing is a snapshot query,
not a global transaction or lock across every operation.

The serialization callback is private implementation machinery, not an API for
applications to run arbitrary tasks. It is not reentrant on the same ID; the
coordinator uses direct internal storage reads inside queued actions rather than
calling its own public read method. No cancellation or scheduler is introduced.

`MemoryOperationStore` checks and mutates its private map synchronously without
awaiting inside critical sections. Atomicity applies only to the same instance
in one isolate's execution context. Instances do not share maps. It provides no
atomicity, ownership, or sharing across isolates/processes and no persistence
across restarts. Tests against it establish local behavior, not durable recovery.

The separate SQLite reference uses this same port with explicit versioned decoding,
verified WAL/FULL, and acknowledged transaction commits. Its actual SQLite/process
verification passed in the developer's unrestricted Windows run. See
[the persistence contract](sqlite_persistence_contract.md) and
[contribution guide](../CONTRIBUTING.md) for platform gates.

## Observation revisions

Every accepted nonterminal observation advances the version once and records its
supplied update time, even when its semantic value is unchanged or the supplied
time is equal. This preserves the reviewed domain behavior: a new observation is
a record revision. Versions are neither business-state-change counts nor lookup
attempt counts. Milestone 4 stores separate recovery-attempt reservation counters
and due times in immutable `RecoveryMetadata`; a reservation and its completion
are distinct revisions. Neither changes the raw storage atomicity contract.

Matching terminal confirmations and stale nonauthoritative terminal observations
remain no-ops, preserving the version/time/metadata and performing no write.
