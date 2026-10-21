# Contributing and reproducing verification

Use Dart >=3.10 and Python >=3.11 for release-tool checks. Python is development
tooling only; the Dart library has no runtime dependencies. The package directory
is the repository root assumed by `.github/workflows`. If hosted in a monorepo,
install the workflows at its actual root and set checkout-relative working paths.

From a clean checkout, run in this order (PowerShell and bash):

```text
dart pub get
cd example/sqlite_recovery
dart pub get
cd ../..
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
dart run example/main.dart
python -m unittest discover -s tool/tests -v
python tool/audit_repository.py
python tool/check_documentation.py
dart test --coverage=coverage
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --report-on=lib
python tool/check_coverage.py coverage/lcov.info
dart doc --output=doc/api .
cd example/sqlite_recovery
dart run tool/verify_native.dart
dart build cli --target=bin/crash_worker.dart --output=build/crash_worker
dart analyze --fatal-infos
dart test test/storage test/codec
dart test test/process --concurrency=1
dart run bin/crash_demo.dart --scenario=lost-response
dart run bin/crash_demo.dart --scenario=authentication
```

Native hooks need access to their release assets as well as pub.dev. Installing
`sqlite3.exe` does not satisfy the Dart dependency. Rebuild the complete worker
bundle whenever its source changes. Do not copy binaries between operating systems.

## Required review gates

The fast workflow checks strict analysis, formatting, core tests, API documentation,
the public example, release-tool negative tests, and >=90% core line coverage. Its
only coverage-file exceptions are four export/declaration-only libraries with no
executable bodies. All state machine, coordinator, persistence/error semantics,
policy, and memory-adapter code remain covered by the threshold. Do not add ignore
annotations to reach it. Review any new exclusion and executable code added to
the declaration-only files.

Full reliability uses fresh Windows/Linux hosted runners on Dart 3.10.0 and stable,
without restoring Pub/native caches. Each combination resolves both packages,
analyzes/tests core, probes actual FFI, builds the native worker, and runs all
SQLite/process tests and demonstrations. Fresh resolution verifies compatible
dependency selection at each SDK; it is not a claim of bit-identical builds.
The example lockfile is retained as per-run evidence; commit the first real
generated lockfile after resolution succeeds, and recheck its minimum-SDK support.

The committed SQLite example lockfile is now a real stable-SDK resolution and
currently requires Dart >=3.13 because of development tooling. Minimum-SDK CI runs
normal `dart pub get` to select compatible versions and retains that resulting
lockfile separately; it must actually pass on 3.10.0 before release. Do not hand
edit lockfiles or interpret source language constraints alone as compatibility.

`python tool/prepare_release.py` audits the Git candidate list and validates a
disposable copy in the system temporary directory, outside Git repositories.
Only that copy drops `publish_to: none`. Set TMP/TEMP outside any Git worktree.
Logs, the inspected archive, and consumer evidence are retained under ignored
`build/release-stage-*/` on success or failure; the temporary workspace is removed.
`--prepare-only` retains its temporary workspace for inspection instead.
The command performs dry-run/archive inspection/consumer checks and never uploads.
Use `--prepare-only` to inspect the copy before invoking external Dart commands.
Both the normal working tree and the SQLite example remain private packages.

Configure repository protection to require `quality-gate` and `reliability-gate`
before merge. Both workflows run on pull requests, pushes, and merge groups. A
failed, cancelled, or skipped prerequisite fails its aggregate gate. GitHub-hosted
results do not exist until the repository is hosted and workflows actually run.
Scheduled runs are unnecessary for merge acceptance; release candidates must run
both workflows again on the exact candidate revision.

Tests must use barriers, controlled checkpoints, injected clocks, and deterministic
seeds. Safety timeouts may fail a test but may not arrange a race. Never report a
fallback source-runner check as a successful standard CLI command, and never
replace fresh-process crash proof with coordinator recreation.

Keep public APIs stable and core independent of Flutter, HTTP, SQLite, and I/O.
Backend assumptions and safety changes require tests and an ADR. Do not log raw
requests, credentials, or backend bodies in failures or CI artifacts.

Public integration assumptions are documented in the
[backend contract](doc/backend_contract.md) and
[persistence contract](doc/sqlite_persistence_contract.md).
Internal engineering reports and release checklists remain local and are excluded
from Git and package archives. Documentation checks validate against Git's file
list, so a local ignored document cannot conceal a broken public link.
Before committing or pushing, inspect the staged diff and run
`python tool/audit_repository.py --staged` and
`python tool/check_documentation.py --staged`. Publication, tags, and pushes require
explicit approval; keep `publish_to: none` in the working tree until then.
