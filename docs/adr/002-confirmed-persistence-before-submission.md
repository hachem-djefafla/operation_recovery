# ADR-002: Confirmed persistence before submission

Status: Accepted.

Prepare identity, then durably commit uncertainty, then send. The state machine
only proposes snapshots and has no authority to attest storage durability.

A successful adapter response must attest its documented durability guarantee.
A commit that succeeds but loses its acknowledgement is ambiguous. The caller
must not send, including after a reread discovers the uncertainty record.
That record now requires lookup. No later invocation inherits submission rights.

Consequence: ambiguity sacrifices automatic progress for safety. Actual adapter
and coordinator fault-injection tests must prove zero submissions after definite
or ambiguous uncertainty-write failures; domain tests are insufficient.
