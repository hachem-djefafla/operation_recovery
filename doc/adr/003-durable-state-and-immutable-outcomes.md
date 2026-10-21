# ADR-003: Durable state and immutable outcomes

Status: Accepted.

Use prepared, awaitingOutcome, succeeded, rejected, and needsAttention. Submission
and checking are transient activity. Attention is unresolved and requires explicit
resume. The latest semantic observation is retained, not an event history.

Only authoritative observations produce success or rejection. After completion,
nonauthoritative observations and matching confirmations return the same record.
Opposite outcomes or conflicting non-null final metadata raise a typed error;
the confirmed record is never rewritten. Identity mismatch always fails first.

Consequence: the engine cannot repair contradictory backend truth automatically.
The domain intentionally does not infer ordering from client arrival time or
invent server revision numbers. Internal actions stay separate from the public
read model and cannot bypass the later coordinator's persistence checks.
