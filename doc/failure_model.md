# Failure model and acceptance matrix

## Persistence acknowledgement is a safety boundary

For a durable adapter, storage success means its documented durable commit has
completed. The memory adapter acknowledges only a memory change and proves no
durability across termination, isolates, processes, or restarts.
An exception or missing acknowledgement does not prove rollback: a write may
have committed before communication with the adapter failed.

If creating or transitioning a record has an ambiguous result, the current
invocation must not submit. A later read showing `awaitingOutcome` allows only
reconciliation. It does not retroactively authorize submission. Only the
original invocation receiving confirmed success for its conditional uncertainty
transition may initiate the first write. Recovery never initiates a write.

An acknowledged uncertainty commit followed by a crash before send is deliberately
unresolved. A backend that never received the operation may be unable to resolve
it; attention is preferable to an unsafe second write.

If saving an authoritative result fails, do not advertise the result as durably
saved. Preserve identity and expose the persistence error. Retry lookup later;
never retry the business write because its result could not be saved.

## Acceptance matrix

| ID | Scenario | Required assertion | Proof milestone |
| --- | --- | --- | --- |
| D01 | Identity creation and conflicting reuse | Validate all fields; no repurposing | 2 domain passed; 3 storage/coordinator passed |
| D02 | Every state/action pair | Exact legal transition or typed error | 2 domain and 3 coordinator passed |
| D03 | Uncertain, pending, or unavailable result | Never becomes business rejection | 2 and 4 passed |
| D04 | Expired authentication / 401 | Semantic authentication-required observation stays unresolved | 2 semantic and 4 HTTP passed |
| D05 | Delayed/stale observation after terminal state | Identical terminal snapshot survives | 2 and 4 asynchronous passed |
| D06 | Opposite authoritative outcome or conflicting terminal metadata | Typed contradiction or CAS conflict; original snapshot intact | 2 and 4 asynchronous passed |
| D07 | Malformed restored record | Explicit validation failure | 2; 5 codec/database |
| D08 | Generated observation sequences | Terminal immutability and uncertainty invariants | 2 |
| P01 | Preparation fails before commit | Submission count zero | 3 and 4 fault-injection passed |
| P02 | Uncertainty save definitely fails | Submission count zero | 3 and 4 fault-injection passed |
| P03 | Uncertainty save commits then throws / acknowledgement is lost | Submission count zero, even if reread finds awaitingOutcome | 3 and 4 fault-injection passed |
| P04 | Creation commits then throws | Submission count zero; identity remains recoverable | 3 and 4 fault-injection passed |
| P05 | Compare-and-swap loses race | No stale overwrite or unauthorized submission | 3 and 4 conflict tests passed |
| P06 | Result commit succeeds then throws | No resubmission; reread preserves committed terminal state | 3 and 4 fault-injection passed |
| C01 | Concurrent identical starts | One submission within supported coordinator | 3 and 4 passed |
| C02 | Concurrent lookups for one ID | At most one active lookup per coordinator | 3 and 4 passed |
| C03 | Different IDs | Independent progress | 3 storage and 4 handler activity passed |
| C04 | Observer throws | Committed state preserved; observer error isolated | 4 passed |
| R01 | Server executes but response is lost | Lookup resolves; submission requests and effects each one | 4 real HTTP passed; 5 developer-verified Windows restart passed |
| R02 | Lookup returns 401, then credentials are restored | Unresolved first; later lookup can confirm; no write | 4 real HTTP passed |
| R03 | Repeated reconciliation / ambiguous 404 | Zero new submission calls | 4 real HTTP passed |
| R04 | Budget exhausted then explicit resume | Attention remains unresolved; resume enables lookups only | 4 passed |
| R05 | Late lookup response conflicts with completed operation | No terminal overwrite; conflict surfaced | 4 passed |
| R06 | Logout or scope switch | No cross-scope reads or updates; drain old account handlers before releasing credentials | 3 scope and 4 lifecycle passed; application credential lifecycle remains integration-owned |
| S01 | Termination after prepared commit | Fresh process restores prepared; no automatic write | 5 developer-verified Windows process suite passed |
| S02 | Termination after uncertainty commit before send | Fresh process reconciles only; submission count zero | 5 developer-verified Windows suite, including withheld acknowledgement, passed |
| S03 | Termination in flight / after backend execution | Fresh process resolves without another submission | 5 developer-verified Windows process suite passed |
| S04 | Real SQLite close/reopen and hard process termination | Committed records survive; atomic CAS holds | 5 developer-verified Windows storage/process suites passed |

Domain tests alone cannot establish P01-P06, C01-C04, or actual durability.
Milestone 3 establishes storage-facing fault/concurrency behavior. Milestone 4
adds submission counts, handler concurrency, observable events, shutdown, and
actual HTTP lost-response/authentication evidence. Durable crash recovery remains
Milestone 5 work; none of these memory tests establishes it.

## Additional Milestone 3 acceptance evidence

| Requirement | Evidence |
| --- | --- |
| Atomic create/CAS, identity/time/version invariants | Shared adapter conformance suite, memory implementation |
| Foreign reads conceal existence; listings filter scope | Store conformance and coordinator scope-isolation tests |
| Coordinator rejects foreign identities before access | Instrumented store verifies zero calls |
| No arbitrary snapshot bypass of domain rules | Narrow actions and all 50 state/action coordinator cases |
| Stale snapshots and terminal immutability | Store CAS tests, external-update races, queued stale/contradictory evidence |
| Same-ID FIFO and different-ID progress | Explicit completer barriers; error recovery and queued reads |
| Ambiguous commits never become positive acknowledgements | Before/after-commit faults and successful-continuation counters |
| Repeated nonterminal observation revisions | Focused tests preserve version increments, including equal timestamps |

## Test discipline and release limits

Milestone 5 adds a [SQLite persistence contract](sqlite_persistence_contract.md),
independent backend/client process harness, all A-G crash scenarios, retained
reservation budgets, corruption cases, and actual SQLite rollback/concurrency
tests. The developer independently passed 90 storage, 58 codec and 32 process
tests on unrestricted Windows, including the one-request/one-effect/one-lookup
demo. Agent-host native storage checks are recorded separately; fresh process
launches remain restricted there. See the
[contribution guide](../CONTRIBUTING.md). Linux/minimum-SDK
and hosted CI are still gates. Codec tests alone are not durability evidence.

The [commit-failure tests](../test/recovery/commit_failures_test.dart) and
[event/shutdown tests](../test/recovery/events_shutdown_test.dart) exercise commit
stages, handler faults, observer behavior and lifecycle boundaries. The complete
core suite contains 539 passing tests. Verification through a direct test runner
or analyzer engine in a restricted host must be distinguished from successful
standard CLI commands; required commands are in the contribution guide.

Use completers, barriers, explicit commit checkpoints, and deterministic seeds.
Do not use elapsed sleeps to arrange races. A separately surviving simulated
backend counts submission requests independently of business effects so that
idempotency cannot hide accidental retries.

The SQLite reference must use transactions, atomic version predicates, WAL and
`synchronous=FULL` on a local filesystem, with settings verified on opening.
Document filesystem/OS/hardware flush assumptions and WAL sidecar handling.
Process-crash tests do not prove survival of every power failure or faulty device.

Release requires all P0 gates, strict analysis and formatting, a standalone
example, and at least 90% core line coverage as supporting evidence. Initial
native integration targets are Windows and Linux; other platform guarantees
require their own tests. Multi-process coordination and execution while the
application is terminated are outside v0.1.
