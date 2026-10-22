# ADR-008: Separate SQLite reference, explicit format, and commit acknowledgements

Status: Accepted and implemented; SQLite runtime acceptance completed.
See the [acceptance evidence](../failure_model.md) for verification scope and limits.

Keep the main package unchanged and dependency-free. Implement the existing store
port in a separately configured example with pinned sqlite3/native assets. Use a
single STRICT relational table, explicit tags, UTC microseconds, mandatory recovery
metadata, database/row format versions, and domain restoration validation.

Separate exclusive creation from recovery opening. Never recreate a missing or
uninitialized database during restart. Require verified WAL/FULL with no fallback,
SQLite >= 3.51.3, and a bounded busy timeout. Preserve sidecars and document the
underlying filesystem/hardware assumptions.

Use synchronous IMMEDIATE transactions and conditional, affected-row-checked
updates. Return true only after acknowledged COMMIT; commit-stage failures remain
unknown. Failed cleanup makes a connection unusable. Do not add domain transitions,
business retries, network awaits, distributed ownership, or public database ports.

Malformed rows use existing validation exceptions; operational failures use the
existing storage errors. Opening has an example-local safe error category. Thus
sealed core exceptions and public APIs require no changes. Explicit future
version-specific migrations are required; no framework is implemented in advance.

Consequences: synchronous disk I/O blocks its isolate; scoped listings validate
all selected rows before filtering. These are practical reference trade-offs.
Native downloads and real process execution must pass before durability is claimed.
