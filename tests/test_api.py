from datetime import date

import pytest


@pytest.mark.asyncio
async def test_health_web_meta_and_preferences(client):
    response = await client.get("/health")
    assert response.json() == {"status": "ok"}
    response = await client.get("/")
    assert response.status_code == 200
    assert "Track your working day" in response.text
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
