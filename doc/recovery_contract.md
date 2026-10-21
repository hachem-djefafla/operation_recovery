# Submission and reconciliation contract

## Public integration

Construct one `OperationRecovery` per account scope with an `OperationStore`,
explicit `RecoveryPolicy`, optional `Clock`, and typed handler registrations.
`OperationHandler<TRequest>` separates `submit(identity, request)` from
`lookupStatus(identity)`. Use the same `OperationRegistration<TRequest>` token
in the facade constructor and `start(token, identity: ..., request: ...)`.

The registry is frozen. Blank/duplicate type identifiers, unregistered tokens,
wrong runtime request types, identity type mismatches, and foreign scopes fail
before storage or handler activity. Restored operations route lookup by persisted
type without original request data. The application owns fingerprint consistency.
No request body is retained by records, registrations, events, or recovery metadata.

The facade provides `start`, `get`, `reconcile`, `reconcilePending`, `resume`,
`close`, and asynchronous `events`. The coordinator/state machine remain internal,
with no arbitrary snapshot replacement API.

## Submission algorithm

Under the same per-ID FIFO queue:

1. Create prepared identity or obtain its existing matching snapshot. Awaiting,
   attention, and terminal records return without submission.
2. Generate uncertainty through the state machine and CAS the prepared version.
3. Require an unambiguous true acknowledgement, publish that committed revision,
   and recheck closing immediately before one intentional handler dispatch.
4. Validate the observation's complete identity and conditionally persist it.
5. Publish the result only after its acknowledgement.

Dispatch eligibility is local control flow, not a reusable stored permission.
Failures and CAS conflicts surface without reread, version refresh, or retry.
A later read showing awaiting cannot authorize a submission. A later explicit
start still finding prepared requires its own successful uncertainty transition.

Handler invocation and result persistence have separate error-handling blocks.
Failure to save an authoritative result never repeats the handler. The backend
may already have executed; resolve later through lookup.

## Reservations, backoff, and resume

`OperationRecord.recovery` holds immutable `RecoveryMetadata`:

| Field | Meaning |
| --- | --- |
| cycleAttempts | Lookup reservations since creation or explicit resume |
| totalAttempts | Cumulative reservations, retained across resume |
| lastAttemptAt | Latest reservation timestamp, retained across resume |
| nextCheckAt | Earliest next lookup; null means immediately due while awaiting |

Existing constructors remain source-compatible through zero/default metadata.
Old awaiting snapshots without metadata are immediately eligible, never safe to
resubmit. Restoration validates count, time, state, and version consistency.
Actual stored-format/codec versioning remains durable-adapter work in Milestone 5.

Policy requires positive max attempts and positive initial/maximum delay, with
maximum at least initial. Attempt n starts at one and uses saturated
`min(initialDelay * 2^(n-1), maxDelay)`. No jitter, elapsed-time limit, polling,
sleep, or write retry is introduced. Versions are record revisions, not attempts.

Application-triggered reconciliation holds the ID queue throughout:

1. Read and validate latest scoped identity. Skip prepared, attention, terminal,
   and not-yet-due records. Resolve the handler before consuming any budget.
2. If due and already exhausted, commit attention without lookup.
3. Reserve a lookup with CAS: increment both counts, save reservation time and
   a provisional next due time based on this attempt's delay.
4. Require acknowledgement, recheck shutdown, and call lookup once.
5. Complete through one state-machine action/CAS. Authoritative evidence wins
   even on the last attempt. Otherwise schedule delay from completion time, or
   record the unresolved observation and attention together on exhaustion.

Reservation and completion each increment the version once. Completion never
combines two increments into one CAS. Failed or ambiguous reservations dispatch
no lookup. A reservation that committed consumes budget even if no call happens;
no rollback or inferred acknowledgement through readback is permitted.

After facade recreation, stored counts/due times remain in force. An exhausted
awaiting record moves to attention when next due, without another lookup.
Explicit resume accepts attention only, resets cycle attempts, retains cumulative
count/last reservation time, and makes lookup immediately eligible. It dispatches
nothing. New policy settings respect stored due times/counts and do not implicitly
resume attention.

UTC mutation times clamp to the stored update time on clock rollback. Scheduling
is wall-clock based; clock changes can alter real elapsed waiting. There is no
monotonic or cross-machine clock guarantee.

## Observations and failures

Only typed authoritative success/rejection establishes a terminal outcome.
Pending, unknown, ambiguous 404, HTTP 401/authentication required, transport, and
service unavailability remain unresolved. Credentials are application-owned.
Unavailable lookups consume reservations normally and may pause in attention,
never business rejection.

Submission `TimeoutException` becomes unknown. Lookup `TimeoutException` becomes
transport unavailability. Unexpected handler exceptions first persist safe unknown
evidence, then surface as `OperationHandlerException`. Explicit cause/stack fields
are memory-only diagnostics; default descriptions omit them. If that safe save
fails, surface the storage failure instead.

Wrong-identity observations fail without applying their contents. A lookup's
reservation remains consumed. CAS conflicts surface without refresh/replay;
domain and storage terminal immutability fence late or contradictory results.

## Batches, ownership, events, and shutdown

`reconcilePending(concurrency: 4)` selects initially due awaiting records and
rechecks them under their ID queues. The limit applies to that batch only.
Invalid concurrency fails before storage; listing failure fails the batch before
dispatch. Operation failures do not stop independent workers. Return an immutable
list of `ReconciliationCompleted(record)` or
`ReconciliationFailed(identity, error, stackTrace)`. Completed processing can be
a no-op and does not imply business success. Concurrent batches share ID queues.

One queue spans each entire storage-handler-storage sequence, including reads
for that ID. Slow handlers can delay those reads; committed events remain observable.
Different IDs progress independently. Handlers own deadlines and must settle.
They must not reenter this facade for the same ID or await its shutdown.

Support one active coordinator per scope. CAS protects records, not distributed
handler ownership across facades, isolates, or processes. Backend idempotency and
authoritative lookup remain independent requirements. Keep clients/credentials
bound to the account until draining finishes; a facade's scope cannot change.

Events are asynchronous broadcast notifications after acknowledged create/CAS,
including reservations. There is no replay, durable log, notification of external
store writes, or event for reads/no-ops/failed acknowledgements. Order is per ID.
Delivery can occur after a newer revision is saved. No request, credential, or raw
error is added. Subscriber errors remain in subscriber zones and cannot reject
operation futures or roll back stored state; applications handle listener errors.

`close()` immediately rejects new calls, rejects queued jobs when acquired, and
rechecks closing before handler dispatch. Active commits may finish and notify,
but cannot authorize a new handler call after closing. Already-dispatched calls
settle and persist their outcomes. Close drains accepted jobs, then ends publication
without waiting for paused listeners; buffered delivery may finish later. Repeated
close returns the same future. Job errors remain with their callers, not close.

Close never cancels backend effects or closes application-owned stores/clients.
Its duration depends on active handler futures settling; no bounded shutdown-time
guarantee is claimed. Memory storage proves neither crash nor restart durability.
