# ADR-004: Typed transient requests and restart identity

Status: Accepted.

Bind a stable type identifier to a typed handler registration in later orchestration.
Explicit start supplies a transient business request. Persist only identity and
safe recovery/outcome metadata; the caller owns fingerprint generation and the
relationship between that fingerprint and the request.

After restart, reconciliation uses the stable type and identity, not a serialized
callback or stored business payload. A prepared record requires an explicit start
with fresh request data. Credentials remain application-owned.

Consequence: request reconstruction and secure application storage are outside
the core. No handler scaffolding is needed to implement the pure domain model.
