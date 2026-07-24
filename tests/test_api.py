from datetime import date

import pytest


@pytest.mark.asyncio
async def test_health_web_meta_and_preferences(client):
    response = await client.get("/health")
    assert response.json() == {"status": "ok"}
    response = await client.get("/")
    assert response.status_code == 303
    assert response.headers["location"] == "/login"
    meta = (await client.get("/api/v1/meta")).json()
    assert meta["timezone"] == "Europe/Berlin"
    assert meta["federal_states"]["NW"] == "North Rhine-Westphalia"

    preferences = (await client.get("/api/v1/preferences")).json()
    assert preferences == {
        "federal_state": "DE",
        "daily_target_minutes": 480,
        "rounding_minutes": 15,
    }
    updated = await client.put(
        "/api/v1/preferences",
        json={"federal_state": "NW", "daily_target_minutes": 450, "rounding_minutes": 5},
    )
    assert updated.json()["federal_state"] == "NW"
    assert (
        await client.put(
            "/api/v1/preferences",
            json={"federal_state": "XX", "daily_target_minutes": 450, "rounding_minutes": 5},
        )
    ).status_code == 422


@pytest.mark.asyncio
async def test_entry_lifecycle_and_statistics(client):
    work_date = "2026-07-17"
    empty = (await client.get(f"/api/v1/entries/{work_date}")).json()
    assert empty["saved"] is False
    assert empty["status"] == "empty"

    response = await client.put(
        f"/api/v1/entries/{work_date}",
        json={
            "check_in": "8",
            "check_out": "17:10",
            "breaks": [
                {"mode": "duration", "duration_minutes": 15},
                {"mode": "range", "start": "12:00", "end": "12:30"},
            ],
            "notes": "Invoice preparation",
        },
    )
    assert response.status_code == 200, response.text
    entry = response.json()
    assert entry["exact_minutes"] == 505
    assert entry["billable_minutes"] == 510
    assert entry["break_minutes"] == 45
    assert entry["status"] == "complete"
    assert entry["notes"] == "Invoice preparation"
    assert len(entry["breaks"]) == 2

    listed = (await client.get(f"/api/v1/entries?start={work_date}&end={work_date}")).json()
    assert listed == [entry]
    stats = (await client.get(f"/api/v1/statistics?period=week&anchor={work_date}")).json()
    assert stats["summary"]["exact_minutes"] == 505
    assert stats["summary"]["billable_minutes"] == 510
    assert stats["summary"]["completed_days"] == 1

    exported = await client.get(f"/api/v1/statistics/export.csv?period=week&anchor={work_date}")
    assert exported.status_code == 200
    assert exported.headers["content-type"].startswith("text/csv")
    assert (
        'attachment; filename="tracy-2026-07-13-2026-07-19.csv"'
        == exported.headers["content-disposition"]
    )
    assert "2026-07-17,Friday,Working day,8.42,8.50,8.00,0.42,Invoice preparation" in exported.text

    assert (await client.delete(f"/api/v1/entries/{work_date}")).status_code == 204
    assert (await client.get(f"/api/v1/entries/{work_date}")).json()["saved"] is False


@pytest.mark.asyncio
async def test_day_off_range_lifecycle_preserves_recorded_work(client):
    first = await client.put(
        "/api/v1/days-off",
        json={"start": "2026-07-14", "end": "2026-07-16"},
    )
    assert first.status_code == 200, first.text
    assert first.json() == {"days_off": ["2026-07-14", "2026-07-15", "2026-07-16"]}

    overlapping = await client.put(
        "/api/v1/days-off",
        json={"start": "2026-07-15", "end": "2026-07-17"},
    )
    assert overlapping.status_code == 200, overlapping.text
    assert overlapping.json() == {"days_off": ["2026-07-15", "2026-07-16", "2026-07-17"]}
    listed = await client.get("/api/v1/days-off?start=2026-07-13&end=2026-07-17")
    assert listed.json() == {
        "days_off": [
            "2026-07-14",
            "2026-07-15",
            "2026-07-16",
            "2026-07-17",
        ]
    }

    recorded = await client.put(
        "/api/v1/entries/2026-07-15",
        json={
            "check_in": "08:00",
            "check_out": "10:00",
            "breaks": [],
            "notes": "Vacation support",
        },
    )
    assert recorded.status_code == 200, recorded.text
    assert recorded.json()["is_day_off"] is True
    assert recorded.json()["exact_minutes"] == 120

    statistics = (await client.get("/api/v1/statistics?period=week&anchor=2026-07-15")).json()
    assert statistics["summary"]["expected_workdays"] == 1
    assert statistics["summary"]["day_off_workdays"] == 4
    assert statistics["summary"]["target_minutes"] == 480
    worked_day_off = statistics["days"][2]
    assert worked_day_off["is_day_off"] is True
    assert worked_day_off["expected_minutes"] == 0
    assert worked_day_off["balance_minutes"] == 120

    exported = await client.get("/api/v1/statistics/export.csv?period=week&anchor=2026-07-15")
    assert "2026-07-15,Wednesday,Day off,2.00,2.00,0.00,2.00,Vacation support" in exported.text

    cleared = await client.delete("/api/v1/days-off?start=2026-07-15&end=2026-07-16")
    assert cleared.status_code == 204
    assert (await client.get("/api/v1/days-off?start=2026-07-13&end=2026-07-17")).json() == {
        "days_off": ["2026-07-14", "2026-07-17"]
    }
    preserved = (await client.get("/api/v1/entries/2026-07-15")).json()
    assert preserved["saved"] is True
    assert preserved["is_day_off"] is False
    assert preserved["exact_minutes"] == 120
    assert (
        await client.delete("/api/v1/days-off?start=2026-07-15&end=2026-07-16")
    ).status_code == 204


@pytest.mark.asyncio
async def test_day_off_range_validation(client):
    assert (await client.get("/api/v1/days-off?start=2026-07-20&end=2026-07-01")).status_code == 422
    assert (
        await client.put(
            "/api/v1/days-off",
            json={"start": "2026-07-20", "end": "2026-07-01"},
        )
    ).status_code == 422
    assert (
        await client.put(
            "/api/v1/days-off",
            json={"start": "2024-01-01", "end": "2027-01-01"},
        )
    ).status_code == 422
    assert (
        await client.delete("/api/v1/days-off?start=2024-01-01&end=2027-01-01")
    ).status_code == 422
    maximum_date = await client.put(
        "/api/v1/days-off",
        json={"start": "9999-12-31", "end": "9999-12-31"},
    )
    assert maximum_date.status_code == 200, maximum_date.text
    assert maximum_date.json() == {"days_off": ["9999-12-31"]}


@pytest.mark.asyncio
async def test_day_off_csv_keeps_overlapping_calendar_labels(client):
    for day in ("2026-07-18", "2026-12-25"):
        response = await client.put(
            "/api/v1/days-off",
            json={"start": day, "end": day},
        )
        assert response.status_code == 200, response.text

    weekend = await client.get(
        "/api/v1/statistics/export.csv" "?period=custom&start=2026-07-18&end=2026-07-18"
    )
    assert "2026-07-18,Saturday,Day off; Weekend" in weekend.text

    holiday = await client.get(
        "/api/v1/statistics/export.csv" "?period=custom&start=2026-12-25&end=2026-12-25"
    )
    assert "2026-12-25,Friday,Day off; Christmas Day" in holiday.text


@pytest.mark.asyncio
async def test_in_progress_actions_and_validation(client):
    work_date = date.today().isoformat()
    assert (await client.post(f"/api/v1/entries/{work_date}/check-out")).status_code == 409
    checked_in = await client.post(f"/api/v1/entries/{work_date}/check-in")
    assert checked_in.status_code == 200
    assert checked_in.json()["status"] == "in_progress"
    assert (await client.post(f"/api/v1/entries/{work_date}/check-in")).status_code == 409

    invalid = await client.put(
        "/api/v1/entries/2026-07-18",
        json={"check_in": "10:00", "check_out": "09:00", "breaks": [], "notes": ""},
    )
    assert invalid.status_code == 422
    assert (await client.get("/api/v1/entries?start=2026-07-20&end=2026-07-01")).status_code == 422
    assert (await client.get("/api/v1/entries?start=2024-01-01&end=2027-01-01")).status_code == 422
    assert (await client.get("/api/v1/statistics?period=custom")).status_code == 422
    assert (
        await client.get("/api/v1/statistics?period=custom&start=2027-01-01&end=2026-01-01")
    ).status_code == 422


@pytest.mark.asyncio
async def test_authentication_gates_web_and_api(unauthenticated_client):
    root = await unauthenticated_client.get("/", follow_redirects=False)
    assert root.status_code == 303
    assert root.headers["location"] == "/login"
    login = await unauthenticated_client.get("/login")
    assert login.status_code == 200
    assert "Sign in with passkey" in login.text
    assert "Create passkey" in login.text
    assert (await unauthenticated_client.get("/api/v1/preferences")).status_code == 401
    assert (
        await unauthenticated_client.get("/api/v1/days-off?start=2026-07-01&end=2026-07-01")
    ).status_code == 401
    asset = await unauthenticated_client.get("/api/v1/auth/assets/fastpasskey.js")
    assert asset.status_code == 200
    assert "navigator.credentials.create" in asset.text
    styles = await unauthenticated_client.get("/api/v1/auth/assets/fastpasskey.css")
    assert styles.status_code == 200
    assert "[hidden]" in styles.text
    assert (
        await unauthenticated_client.post("/api/v1/auth/passkey-add/unsupported/options")
    ).status_code == 404
