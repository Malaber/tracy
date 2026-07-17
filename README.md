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
- SQLite locally, with PostgreSQL support through SQLAlchemy
- FastAPI, SQLAlchemy, Alembic, vanilla JavaScript, pytest, and Invoke

Authentication is intentionally not included yet. The API and data model are isolated so a shared
authentication package can be added in front of the routes later.

## Local development

```bash
./.codex/setup.sh
.venv/bin/inv start
```

Open [http://localhost:8000](http://localhost:8000).

Run all checks with:

```bash
.venv/bin/inv verify
```

## Holiday coverage

The working-day calculation includes national holidays and whole-state public holidays for the
selected German federal state. Municipal holidays such as Augsburg Peace Festival, Bavaria's
municipality-dependent Assumption Day, and local Corpus Christi rules in Saxony/Thuringia are not
treated as state-wide days off.
