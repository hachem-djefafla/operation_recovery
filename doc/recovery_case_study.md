# A backend succeeded, but the client never learned the result

A timeout says the response was not received. It cannot establish that a transfer
failed. Repeating the write could duplicate an effect. This package records the
client's uncertainty, preserves the original identity, and queries authoritative
backend status.

## The protocol and the unavoidable gap

The coordinator first creates a prepared record, then acknowledges the durable
transition to `awaitingOutcome`, then invokes submission once. Only that original
successful acknowledgement authorizes dispatch. CAS protects against stale records,
and per-ID coordination prevents duplicate dispatch inside one coordinator.

There is still a gap between uncertainty persistence and dispatch. If a process
dies there, recovery cannot prove whether it sent the request. It looks up status
only. If absence is indistinguishable from delayed visibility, the operation can
remain unresolved and eventually need attention. This is an intentional consequence
of preserving uncertainty, not permission to replay the business write.

## The process demonstration

The [SQLite example](../example/sqlite_recovery/README.md) runs an independent HTTP
backend and a child client with a real SQLite file. The backend commits one effect
and drops the response. An IPC checkpoint holds the client before it saves a
result. The harness kills that actual client, waits for exit, and starts a fresh
client. It opens the existing database and performs authoritative lookup. A further
client verifies the final state survived closing and reopening.

The demo fails unless there was exactly one HTTP submission, exactly one effect,
at least one lookup, and persisted success with the same identity. Separate counters
matter: backend idempotency could conceal two requests by applying only one effect.
An additional backend test deliberately submits twice to validate this distinction.

Other scenarios kill after preparation, before dispatch, in flight, after lookup
before terminal persistence, or during an attempt reservation. Corruption cases
must fail explicitly without creating a new prepared record. Authentication
recovery adds two restarts around a recoverable HTTP 401 and retains its due time.

## Evidence and limits

The developer independently ran the Windows suites: 539 core, 90 SQLite storage,
58 codec, and 32 real process tests passed. The lost-response demonstration
confirmed exactly **one HTTP submission, one business effect, and one authoritative
lookup**, ending in persisted success. The loaded SQLite version was 3.54.0 with
WAL and synchronous=FULL. Previously failing shutdown, concurrent protocol output,
corruption-fixture, and concurrent-open cases were fixed and the process suite passed.

These are developer-supplied Windows results. The restricted agent's native storage
tests and diagnostics are separately recorded; Linux, minimum SDK compatibility,
and actual hosted CI remain outstanding. Reproduction commands and required checks
are in the [contribution guide](../CONTRIBUTING.md). No CI badge or workflow file
substitutes for an executed run.

SQLite WAL/FULL process-crash recovery assumes a functioning local filesystem,
locking, and honest flush semantics. These tests cannot establish survival of
arbitrary hardware faults. CAS does not establish distributed handler ownership.
This example supplies neither production mobile integration nor background
execution, cross-process coordinators, automatic write retries, or exactly-once
business execution.
