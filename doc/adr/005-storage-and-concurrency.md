# ADR-005: Storage atomicity and concurrency boundaries

Status: Accepted.

Storage provides atomic create-if-absent and conditional version updates.
IDs are unique within a store, scope is immutable, and every access enforces the
coordinator's fixed scope. One active coordinator per scope serializes each ID.
Different IDs can proceed independently. In Milestone 3, CAS failures are surfaced
without reread/replay. Neither a stale update nor an ambiguous acknowledgement
can be turned into a successful write by refreshing a version or rereading.

Foreign-scope and absent reads both return null without revealing existence.
Conflicting writes still fail without modifying the original. See ADR-006 for
the state-machine boundary and strict scope-isolation decision.

The memory implementation is atomic only for one instance within one isolate's
execution context, never across isolates, processes, or restarts. It supports
tests, not durable recovery claims. Keep the
core storage-independent; provide the SQLite reference in a separately configured
example and prove its behavior with process-restart tests.

Consequence: database CAS is not a distributed lock and does not extend the
coordinator's guarantees to multiple isolates or processes. SQLite durability
depends on documented journal, synchronization, filesystem, and hardware behavior.
