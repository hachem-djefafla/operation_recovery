# Backend and handler contract

The backend must expose a stable client-known identifier and an authoritative
operation-status lookup. Document pending/final statuses, visibility lag,
authorization, operation retention, and idempotency expiration. A handler must
verify response correlation before asserting a result for the supplied identity.
An idempotency key alone does not establish permanent duplicate protection.

| Backend/transport observation | Domain meaning |
| --- | --- |
| Confirmed completed operation | Authoritative success |
| Confirmed final business refusal | Authoritative rejection |
| Still processing | Pending |
| Timeout, connection reset, ambiguous server error | Unknown or lookup unavailable |
| Missing credentials, expired authentication, HTTP 401 during lookup | Lookup unavailable: authentication required |
| Lookup 404 with unspecified semantics | Unknown |

A 401 response is not a business rejection. Keep identity and the unresolved
outcome, report that authentication is required, and allow lookup once the
application restores credentials. The core neither persists nor refreshes
credentials. Repeated unavailable checks may exhaust recovery policy and pause
in `needsAttention`; that state is still not business rejection.

Submission and status lookup are separate handler actions. Disable automatic
write retries in clients/interceptors. A lookup must never secretly submit a
write. A timeout does not cancel or roll back a backend request already sent.

Terminal observations must come from the authoritative operation contract, not
inferences from generic HTTP status codes. Contradictory final results are
integration/protocol errors and cannot overwrite a confirmed local outcome.

Do not persist access tokens, payment details, raw server error bodies, or request
payloads in default records. References and rejection codes must be safe metadata.
Default string representations omit identity values and outcome metadata;
applications must still control what they explicitly log.

## Implemented integration boundary

`OperationHandler<TRequest>` exposes explicit submission and status lookup;
`OperationRegistration<TRequest>` binds it to a stable type. The engine validates
every identity field in returned observations. Handlers still own validation of
authority, request/fingerprint consistency, account-bound credentials, deadlines,
and retry-disabled network clients. The core contains no HTTP imports or status
code assumptions.

Expected failures should be returned as semantic observations. A thrown
`TimeoutException` becomes unknown submission or unavailable lookup. Other handler
exceptions first save safe unknown evidence, then surface a typed handler error;
a failure of that save surfaces the storage error. There is no automatic write
retry in either path. Wrong-identity results are never applied.

The [HTTP example](../example/simulated_backend.dart) and integration tests exercise
lost responses, real 401 followed by restored credentials, and ambiguous 404.
They use memory storage and do not prove production authentication or durable
process-restart recovery.
