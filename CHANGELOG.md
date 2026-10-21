## 0.1.0

- Prepare the first public release with immutable operation identity, explicit
  submission, authoritative lookup-only reconciliation, scoped atomic storage,
  bounded recovery reservations/backoff, events, and draining shutdown.
- Include a separate SQLite reference adapter and real process-crash examples.
  Developer-verified Windows results: 539 core, 90 storage, 58 codec, and 32 process
  tests; lost-response recovery used one submission, one effect, and one lookup.
- Prepare repository metadata, reproducible release staging, archive inspection,
  and Windows/Linux minimum/stable SDK quality gates. Publication remains disabled
  until final approval; hosted CI and Linux/minimum SDK execution are release gates.

## 0.1.0-dev.1 (development history)

- Add MIT licensing, public integration/lifecycle guidance, a recovery case study,
  contribution instructions, and explicit release-validation guidance.
- Add separate fast-quality and clean-checkout reliability CI workflows for
  Windows/Linux and minimum/stable Dart, plus publication-payload inspection.
- Add a 90% core coverage gate, negative tests for release tools, archive consumer
  validation, native FFI evidence probe, and an authentication restart scenario.
- Keep publication disabled and native/process/CI acceptance explicitly pending
  until actual execution; no supported public signatures are changed.

- Specify operation identity, recovery states, backend authority, and failure gates.
- Establish the pure Dart package and strict analysis configuration.
- Implement immutable identities and validated operation snapshots.
- Add typed backend observations and recoverable authentication unavailability.
- Implement internal pure transitions with immutable terminal outcomes and
  explicit contradiction errors.
- Add exhaustive domain tests and reproducible generated observation sequences.
- Define atomic scoped storage, typed commit uncertainty, and the non-durable
  memory reference adapter.
- Add internal per-ID coordination with state-machine-only mutations, explicit
  CAS conflicts, and no success inferred from ambiguous commit readback.
- Conceal foreign records on reads and enforce scope-filtered unresolved listings.
- Add deterministic store conformance, fault-injection, scope, and concurrency tests.
- Implement typed handlers and the public scoped submission/reconciliation facade.
- Gate submission on this invocation's acknowledged uncertainty commit and keep
  recovery lookup-only, including after ambiguous commits or lost responses.
- Persist lookup reservations, bounded exponential backoff, and explicit attention
  resume with separate cycle/cumulative attempt counts.
- Add committed-state events, per-operation batch results, and draining shutdown.
- Add deterministic handler/concurrency/fault tests and real loopback HTTP tests
  for lost responses, expired authentication, and ambiguous status lookup.
- Add a separate SQLite reference package with explicit schema/codec, exclusive
  creation, existing-only recovery opening, WAL/FULL verification, and atomic CAS.
- Add independent backend/client worker code, forced-process crash scenarios A-G,
  durable-store conformance/fault tests, and a runnable crash-recovery demo.
- Add codec tests and persistence/process ADRs. The initial restricted development
  environment could not execute the native/process gates; the Windows acceptance
  results for 0.1.0 are recorded above.
