# ADR-009: Independent backend and forced client-process crash evidence

Status: Accepted and implemented; real process-crash acceptance completed.
See the [acceptance evidence](../failure_model.md) for verification scope and limits.

The orchestrator directly launches a bundled Dart worker executable in independent
backend/client roles. The backend survives client death and separately counts
HTTP submissions, effects, and lookups. Control messages use structured stdin/stdout
IPC, including explicit commit/handler checkpoints. Never use sleeps to arrange a
crash. Fake clocks control eligibility; deadlines only detect stuck tests.

Force-kill the actual client without cleanup, await process exit, then start a new
client with the same SQLite database. Never overlap recovery coordinators. Verify
full identity, reservation/scheduling metadata, final state through another reopen,
and submission counts independently of backend idempotency.

Test-only store/handler decorators stop outside actual adapter transactions. A
separate raw-storage worker deliberately stops inside an uncommitted transaction
to verify rollback on death. These hooks do not enter production core or adapter.
Corruption tests require explicit remote validation errors; IPC timeouts cannot
count as successful corruption rejection.

The runnable demo and integration tests share the concrete scenario harness.
Missing executables or blocked process creation fail verification, rather than
skip or substitute same-process restoration. SQLite/OS process tests cannot prove
power-loss survival, distributed ownership, or exactly-once backend execution.
