# ADR-007: Submission gates, reservations, events, and shutdown

Status: Accepted, implemented in Milestone 4.

Extend the coordinator's private per-ID queue across complete handler sequences.
Expose typed registration and a small facade; keep type erasure private and all
mutations state-machine-generated. Requests remain transient. Reconciliation
routes lookup by persisted type, not request reconstruction or callbacks.

Submission requires this invocation's acknowledged uncertainty CAS. No exception
or readback path can authorize dispatch. Saving the result is outside handler
error translation, so a save failure cannot repeat the handler.

Lookup reserves budget before dispatch, retaining cumulative counts across resume.
An abandoned reservation remains consumed. Completion saves final unresolved
evidence and attention in one version increment. Authority wins over exhaustion;
HTTP 401 remains recoverable uncertainty. Use explicit attempt limits and bounded
backoff without polling. Record versions are not lookup-attempt counters.

Handlers own deadlines and must settle. Surface unexpected errors after safe
uncertainty commits. Publish asynchronous snapshots only for acknowledged commits.
Observer errors stay in subscriber zones. Shutdown rejects queued/new work,
prevents further dispatch, drains active work, and does not await paused observers.

Consequences: a reservation can spend budget without a lookup; pre-send crashes
can require attention; an unsettled handler can hold shutdown open. Scope and CAS
protect local records, not distributed handler ownership. Memory atomicity is not
durability. Actual durable-adapter and process-restart proof remains Milestone 5.
