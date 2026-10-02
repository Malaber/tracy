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

Successful `main` CI runs create the next patch release (or the `RELEASE_MINIMUM`
version when a feature release raises that floor), publish matching version and `latest`
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

## Administration and review accounts

[Manual passkey enrollment and Apple review setup](docs/admin/passkey-review-accounts.md)
explains administrator bootstrap, account creation, and expiring one-time passkey links.
No passwords or email delivery are required.

## Native iOS app

[Tracy Time Tracking](ios/TracyIOS/README.md) is the native SwiftUI iPhone/iPad client. It focuses
on quick time entry, reviewing recent days, and durable offline entry with automatic retry and
explicit conflict resolution. It supports system/light/dark appearance and native Liquid Glass
on iOS 26+. Bundle ID and App Store Connect SKU: `de.malaber.tracy`.

### App Store screenshots

Every GitHub release receives `tracy-app-store-<version>.zip` after the native
screenshot job succeeds. Unzip it and upload the PNGs from `en-US/iphone-6.5`
(1284 × 2778) and `en-US/ipad-13` (2064 × 2752) to the corresponding App Store
Connect display slots. Each folder contains Today, entry editing, recent-day
review, offline saving, and dark-mode screenshots. They show the actual app with
synthetic local data; no production account is used. `manifest.json` records the
release version, source commit, dimensions, and checksums.

To generate the same files locally with Xcode 27.0 (27A266a), XcodeGen, and the
iOS 26.2 (23C52) simulator runtime installed:

```sh
.codex/setup.sh --ios
.venv/bin/pip install --retries 0 Pillow==12.1.1
.venv/bin/inv capture-ios-screenshots
```

Output is under `e2e-artifacts/app-store/`. Captures run once on fresh isolated
simulators; no retries or image resizing. The separate marketing test scheme
keeps capture work out of the regular accessibility suite. Pull requests validate
capture and publish downloadable workflow artifacts; releases additionally attach
the ZIP to the exact release tag. A failed capture fails its job and publishes no
partial screenshot archive. App Store uploads remain manual.
