# Tracy

Tracy is a small self-hosted working-time tracker. It keeps exact daily check-in, check-out,
break, and note data in a database, while deriving invoice-friendly quarter-hour totals and
Germany-aware target hours.

## Current scope

- Daily check-in/check-out with an optional next-day checkout
- Breaks as either a duration or a start/end range
- Exact and configurable rounded billable time
- Week, month, and year statistics
- CSV export for the selected statistics period
- German national and selectable state-wide public holidays
- Personal days off that reduce required target hours
- Passwordless account access and passkey management through FastPasskey
- SQLite locally, with PostgreSQL support through SQLAlchemy
- FastAPI, SQLAlchemy, Alembic, vanilla JavaScript, pytest, and Invoke
- GitHub Actions releases with amd64/arm64 images on GHCR

## Local development

```bash
./.codex/setup.sh
.venv/bin/inv start
```

Open [http://localhost:8000](http://localhost:8000).
Create an account with a passkey on the login screen. Existing tracker data is assigned to the
first account created after upgrading.

Run all checks with:

```bash
.venv/bin/inv verify
```

## Deployment and releases

Every pushed branch runs separate formatting, lint, Python, and JavaScript jobs. Successful commits
publish an immutable multi-architecture image as `ghcr.io/malaber/tracy:sha-<commit>`.

Successful `main` CI runs create the next patch release, publish matching version and `latest`
container tags, and create a Git tag and GitHub Release. Deploy the current release with:

```bash
docker compose pull
docker compose up -d
```

Deployment guides:

- [Docker Compose](docs/deployment/docker-compose.md)
- [Webhooker production and review deployments](docs/deployment/webhooker.md)

## Holiday coverage

The working-day calculation includes national holidays and whole-state public holidays for the
selected German federal state. Municipal holidays such as Augsburg Peace Festival, Bavaria's
municipality-dependent Assumption Day, and local Corpus Christi rules in Saxony/Thuringia are not
treated as state-wide days off.
