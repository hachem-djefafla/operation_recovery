# ADR-001: Reconciliation without write retries

Status: Accepted.

A lost response cannot prove the absence of a business effect. v0.1 performs
status lookups and attention escalation; it never resubmits uncertain writes.
Only an explicit start may continue a prepared operation. HTTP clients and
interceptors must also disable submission retries.

Authentication failures, including HTTP 401, are recoverable lookup unavailability,
not business rejection. The application restores credentials before more checks.
Recovery can pause without changing the business outcome.

Consequence: some operations may require manual attention, particularly when a
pre-send crash leaves an uncertainty record for a request the backend never saw.
