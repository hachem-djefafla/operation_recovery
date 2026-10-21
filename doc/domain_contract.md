# Domain contract

## Identity

An identity contains ID, scope, stable operation type, idempotency key, and
request fingerprint. Each is a nonblank, case-sensitive string, retained exactly
as supplied. The application owns canonicalization and key uniqueness. Equality
compares every field; no field can be changed on a record. IDs are unique within
the future store, including across scopes. A different scope for an existing ID
is a conflict, not a way to reuse the ID.

## Durable states and internal actions

| Current state | Action | Result |
| --- | --- | --- |
| prepared | begin submission with matching identity | awaitingOutcome |
| awaitingOutcome | authoritative success | succeeded |
| awaitingOutcome | authoritative rejection | rejected |
| awaitingOutcome | pending, unknown, lookup unavailable | awaitingOutcome |
| awaitingOutcome | pause recovery | needsAttention |
| needsAttention | explicit resume | awaitingOutcome |
| succeeded/rejected | nonauthoritative observation | unchanged |
| succeeded/rejected | matching terminal confirmation | unchanged |
| succeeded/rejected | contradictory authoritative observation | typed error, unchanged |

All other actions fail explicitly. In particular, observing an attention record
requires explicit resume first. Resuming never authorizes sending a write.
Submission/checking activity is not a durable state.

An opposite terminal status is contradictory. Two matching terminal statuses
with different non-null backend references or rejection codes are also
contradictory. Missing optional metadata does not contradict an outcome.
Repeated confirmations never enrich or overwrite a completed record.

Identity is validated before all observations, including stale observations.
Late nonauthoritative observations after completion are no-ops even if their
supplied timestamp is older. An authoritative contradiction remains an error
regardless of arrival time; the domain does not invent server revision ordering.

## Records and observations

Records contain immutable identity, state, concurrency version, UTC creation and
update times, and the latest semantic backend observation, if any. Retaining the
latest observation preserves authentication-required information through pause
and resume. This is not a durable event history.

New records are prepared at version zero. Every accepted record change increments
the version once; ignored observations return the identical snapshot. Caller
times normalize to UTC. Mutations reject time regression; later orchestration
must supply a time at least as recent as the persisted update time.

Repeated identical nonterminal observations remain accepted record changes: each
advances the version and records the supplied observation time. Versions are not
recovery-attempt counters. Matching terminal confirmations remain no-ops. The
internal coordinator preserves these semantics and skips persistence for no-ops.

Restoration validates nonnegative versions, chronological timestamps, prepared
version/timestamp invariants, minimum versions for later states, observation
identity, and consistency between state and observation. It performs no I/O or
serialization. A storage adapter will additionally validate its schema and codec.

Backend observations form a closed set: success, rejection, pending, unknown,
and lookup unavailable. Unavailability distinguishes authentication required,
transport failure, and service unavailable. Success may contain a safe opaque
backend reference; rejection may contain a safe machine-readable code. Raw HTTP
responses, credentials, and request payloads are excluded.

Public constructors express application assertions, not cryptographic proof of
backend authority. The handler is responsible for validating actual responses.

The state machine is internal and pure. Producing `awaitingOutcome` in memory
does not confirm a commit and does not grant permission to submit a request.

## Recovery reservations

`OperationRecord.recovery` holds `RecoveryMetadata`: cycle and cumulative lookup
reservation counts, last reservation time, and next-check time. Existing record
constructors default to empty metadata. Prepared records cannot have reservations;
attention and terminal records cannot have a next-check time. Reservation times
must fall between record creation and update; count/version consistency is validated.

Only a due awaiting record within its attempt budget can reserve a lookup. The
state machine increments both counters and the version once. Completion is a
separate action/revision; authoritative results win even on the last attempt.
Otherwise exhaustion combines the unresolved observation and attention state
in one revision. Terminal observations clear the due time. Explicit resume resets
cycle count, retains cumulative count and last reservation time, and enables an
immediate lookup. None of these actions authorizes submission.

The application layer supplies policy/time and acknowledges writes. The domain
does not call handlers or storage. See the [recovery contract](recovery_contract.md)
for backoff, abandoned reservations, and error behavior.
