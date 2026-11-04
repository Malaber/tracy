# AGENTS.md

## Build and test rules

Run `.codex/setup.sh` before validation (`.codex/setup.sh --ios` for native-only checks). Prefer the shared Invoke entrypoints over ad-hoc
commands whenever an Invoke task exists.

- `.venv/bin/inv install-deps` installs Python and JavaScript dependencies.
- `.venv/bin/inv check-python` runs formatting, linting, and Python tests.
- `.venv/bin/inv check-js` runs JavaScript tests.
- `.venv/bin/inv verify` runs all local checks.
- `.venv/bin/inv start` starts the application for local use.
- `.venv/bin/inv check-ios-package` tests native time-entry and offline-sync logic.
- `.venv/bin/inv build-ios-simulator` generates and builds the native app (Xcode 27.1, XcodeGen).
- `.venv/bin/inv check-ios-ui` runs native UI and accessibility tests on an installed iPhone simulator.

New calculation, API, or UI behavior should include focused automated coverage. Keep the local
SQLite database out of version control and use a temporary database for tests.

### Quiet test execution

Run local tests once and wait for completion. Use a blocking process wait or a tool-level
completion wait; do not repeatedly inspect logs, query test progress, or narrate unchanged
status. Save output to a log and inspect the exit status and results after completion.
Report the final result, or an actionable failure that requires intervention.

Do not poll GitHub CI. Check results when requested, fix reported failures, and return
after pushing rather than waiting on repeated status queries.

For changes limited to `AGENTS.md`, skip local setup and tests. Include `[skip ci]` in
the commit message to skip push and pull-request workflows for that documentation-only
change. GitHub may leave required checks pending; do not weaken branch protection to
bypass them.

Use Xcode 27.1 and the iOS 27.1 SDK for all new native development. Keep the iOS 27.0
simulator runtime for ordinary iPhone/iPad testing until newer runtimes support those device types.
See [Duo migration guide](docs/ios-27.1-duo-migration.md) for the pinned runtime matrix.

## Release workflow

CI publishes tested commit images as `ghcr.io/malaber/tracy:sha-<commit>`. A successful `main` CI
run promotes that exact image to the next patch version and `latest`, creates the GitHub Release,
and wakes Webhooker when its repository settings are configured.

Pull request descriptions may include `Release title: <title>`. The release workflow uses that
value for the GitHub Release title; otherwise it uses the PR or commit title.

## CI cost constraint

The user has a cost cap. Use standard included GitHub runners only. Never switch
to billed larger runners or enable paid capacity without explicit user approval.
Reduce workload/recording overhead or explain remaining limitations instead.
