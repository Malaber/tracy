# AGENTS.md

## Build and test rules

Run `.codex/setup.sh` before validation. Prefer the shared Invoke entrypoints over ad-hoc
commands whenever an Invoke task exists.

- `.venv/bin/inv install-deps` installs Python and JavaScript dependencies.
- `.venv/bin/inv check-python` runs formatting, linting, and Python tests.
- `.venv/bin/inv check-js` runs JavaScript tests.
- `.venv/bin/inv verify` runs all local checks.
- `.venv/bin/inv start` starts the application for local use.

New calculation, API, or UI behavior should include focused automated coverage. Keep the local
SQLite database out of version control and use a temporary database for tests.
