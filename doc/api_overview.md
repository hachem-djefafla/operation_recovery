# Recovery API guide

Import only `package:operation_recovery/operation_recovery.dart`. Existing public
types and signatures are preserved. Internal coordinators and state transitions
are implementation details.

## Application integration

Implement `OperationHandler<TRequest>` with two separate methods: `submit` sends
one intentional business write, and `lookupStatus` queries authoritative status.
Validate backend correlation and disable client/interceptor write retries. Give
every handler a deadline; an unsettled handler can also prevent draining shutdown.

Bind the handler to a stable type with `OperationRegistration<TRequest>`. Construct
one `OperationRecovery` per account scope with a store, registrations, and explicit
`RecoveryPolicy`. Keep the registration token and pass it to `start`, together
with immutable identity and transient request data. The application computes a
consistent fingerprint and provides credentials; neither belongs in stored records.

The [complete runnable example](../example/main.dart) uses public imports and
demonstrates response loss, lookup, and independent submission/effect counters.
Run `dart run example/main.dart` from the package root. It uses memory storage.
For real termination and SQLite restoration, follow the
[separate reference package](../example/sqlite_recovery/README.md).

## Submission and restoration

`start` can submit only after that invocation receives an acknowledged successful
uncertainty CAS. A failed or ambiguous acknowledgement never grants permission,
including after readback. An existing awaiting, attention, or terminal operation
is returned without resubmission. A prepared record requires a fresh explicit
start and request data; automatic reconciliation skips it.

On startup, open the existing durable store, recreate registrations for the same
types/scope, and invoke `reconcilePending`. Reconciliation performs lookups only.
Do not recreate an empty database when restoration fails. Missing/corrupt records
must be investigated rather than converted into new submission permission.

## Policy, events, and lifecycle

Each lookup reserves an attempt durably before dispatch. Backoff is bounded
exponential delay, with no background polling. The application invokes recovery
when appropriate. A committed reservation consumes budget even if a crash prevents
lookup. `needsAttention` remains unresolved. Explicit `resume` resets the cycle
budget while retaining cumulative counts and enables lookup only.

Expired authentication and HTTP 401 map to recoverable `LookupUnavailable` with
`authenticationRequired`. Restore credentials outside the engine and honor the
persisted next-check time; resume explicitly if already paused for attention.

`events` reports acknowledged committed snapshots asynchronously, without replay
or a durable event log. Observer failures cannot undo commits. Read `get` for the
current scoped snapshot rather than treating event delivery as persistence proof.

Call `close` to reject new/queued work and drain dispatched handlers and saves.
Then close application-owned stores and clients. On logout, drain the old scope
before releasing credentials; create a new facade for the new scope. Do not share
one facade across accounts or run overlapping coordinators for the same scope.

See the [recovery contract](recovery_contract.md) for exact due-time, conflict,
shutdown, and event semantics. No public API changes are needed for these guides.
