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

Output is under `e2e-artifacts/app-store/`. The runner builds before simulator boot,
then captures run once on fresh portrait simulators using `test-without-building`.
No device-rotation RPC, retries, or image resizing; packaging verifies portrait
dimensions. The separate marketing test scheme keeps capture work out of the
regular accessibility suite. Pull requests validate
capture and publish downloadable workflow artifacts; releases additionally attach
the ZIP to the exact release tag. A failed capture fails its job and publishes no
partial screenshot archive. App Store uploads remain manual.

### Timed project sessions

Web and iOS check-in/check-out controls have a chevron for choosing a project and a past or future time. Check in again after checkout to start a new session, including another session on the same project. The global default is selected for new sessions. Checkout can also correct the current session's project. Edit the individual sessions in the day editor; overlapping sessions are rejected and only the last session can remain open.

Gaps between sessions are not working time or deducted breaks. Each session longer than six hours gets a 30-minute automatic break charged to that session's project; exactly six hours does not. Override its break minutes (including zero) in the editor. Daily billable time is rounded once, with any rounding remainder assigned to the last completed session's project. For 08:00–10:30 on X, 10:45–19:00 on Y, and 19:30–20:00 on X: X gets 3h, Y gets 7h45, and the day totals 10h45.

Migration `0008_work_sessions` adds nullable session storage without rewriting existing days. Existing manual project allocations remain editable in their original form; they cannot be converted automatically to timed sessions because their timestamps are unknown. iOS retains sessions offline and waits for a server advertising `work_sessions` before syncing. Older clients cannot overwrite a session day with the old single-span format.

### Project bookings

Web and iOS support multiple project bookings per day. Enter billable minutes (120 for two hours), and choose the project that receives the remaining rounded daily total. A global default applies to new days; changing it never rewrites historical assignments. With no default, remaining minutes stay unassigned. Bookings cannot exceed a completed day's billable total. Ongoing days may contain planned bookings; checkout requires enough billable time or reduced bookings.

Projects can be created, made default, archived, and unarchived. Archived names stay on historical bookings but are excluded from new suggestions. Archiving the global default clears that default. Project totals in Statistics cover saved completed days and completed sessions on ongoing session days. Existing project bookings work through the iOS offline queue; creating/managing projects requires a connection.

Deploy the API migration before using project booking features in TestFlight. The app keeps ordinary tracking compatible with older servers and does not sync project bookings to servers lacking support.

Automatic 30-minute breaks apply only after six elapsed hours. New automatic breaks retain provenance and disappear if checkout is shortened to six hours or less. Editing a break manually makes it explicit. Legacy breaks have no provenance and remain manual; they can be removed in Edit entry. This avoids deleting actual breaks from old records. Billable time leads day/week/statistics summaries and balances; exact time remains available as detail.
