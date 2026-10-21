# ADR-006: Domain-safe coordination and strict scoped reads

Status: Accepted, implemented in Milestone 3.

An arbitrary replacement API on the coordinator could bypass the state machine,
even if storage correctly checks versions. Expose narrow internal actions only:
prepare, read/list, persist uncertainty, apply supplied observation, pause, resume.
All state changes use the existing `OperationStateMachine`; no networking occurs.

The raw storage port remains responsible for atomicity, identity, versions, time
invariants, terminal immutability, and its documented persistence guarantee. It
does not duplicate the domain transition graph. Direct port callers are trusted
snapshot producers; future application flows must use the coordinator boundary.

Foreign-scope and absent reads both return null. This supersedes any earlier
interpretation that reads should raise identity conflicts for foreign records.
Conflicting writes still fail without mutation. Coordinators reject explicitly
foreign identities before store access and scope-filter returned records.

Preserve version increments for repeated nonterminal observations because each
accepted observation records another revision. Terminal duplicates remain no-ops.
Avoid adding observation equality or attempt-count semantics to record versions.

Consequence: concurrent external writers can still cause CAS conflicts. Surface
them without replay, version refresh, or success inferred from rereading. Multiple
submission owners, distributed locking, and durable recovery remain outside this
milestone. Memory atomicity is limited to one instance in one isolate/context.
