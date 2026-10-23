from uuid import uuid4

from app.api.deps import get_current_user
from app.models import User


async def test_project_lifecycle_bookings_defaults_and_history(client):
    assert (await client.get("/api/v1/projects")).json()["projects"] == []
    catalog = (await client.post("/api/v1/projects", json={"name": " Project X "})).json()
    x = catalog["projects"][0]["id"]
    catalog = (await client.post("/api/v1/projects", json={"name": "Project Y"})).json()
    y = next(p["id"] for p in catalog["projects"] if p["name"] == "Project Y")
    assert (await client.post("/api/v1/projects", json={"name": "project x"})).status_code == 409
    assert (await client.post("/api/v1/projects", json={"name": "  "})).status_code == 422
    assert (
        await client.put(f"/api/v1/projects/{y}", json={"name": "Project X"})
    ).status_code == 409
    assert (await client.put("/api/v1/projects/default", json={"project_id": x})).status_code == 200
    payload = {
        "check_in": "08:00",
        "check_out": "12:00",
        "project_allocations": [{"project_id": y, "minutes": 120}],
    }
    entry = (await client.put("/api/v1/entries/2026-10-22", json=payload)).json()
    assert entry["default_project_id"] == x
    assert entry["project_bookings"] == [
        {"project_id": y, "minutes": 120},
        {"project_id": x, "minutes": 120},
    ]
    # Older clients omit project fields: time edits must not erase existing bookings.
    updated = (
        await client.put(
            "/api/v1/entries/2026-10-22", json={"check_in": "08:00", "check_out": "12:01"}
        )
    ).json()
    assert updated["project_allocations"] == payload["project_allocations"]
    assert updated["project_bookings"][1]["minutes"] == 135
    stats = (await client.get("/api/v1/statistics?period=week&anchor=2026-10-22")).json()
    assert stats["project_totals"] == [
        {"project_id": x, "minutes": 135},
        {"project_id": y, "minutes": 120},
    ]
    assert stats["summary"]["balance_minutes"] == 255 - stats["summary"]["target_minutes"]
    archived = (
        await client.put(f"/api/v1/projects/{x}", json={"name": "Project X", "archived": True})
    ).json()
    assert archived["default_project_id"] is None
    assert (await client.put("/api/v1/projects/default", json={"project_id": x})).status_code == 422
    assert (await client.get("/api/v1/entries/2026-10-22")).json()["project_bookings"] == updated[
        "project_bookings"
    ]
    assert (
        await client.put(f"/api/v1/projects/{x}", json={"name": "Project X", "archived": False})
    ).status_code == 200
    assert (
        await client.put("/api/v1/projects/default", json={"project_id": None})
    ).status_code == 200
    payload["project_allocations"][0]["minutes"] = 300
    assert (await client.put("/api/v1/entries/2026-10-22", json=payload)).status_code == 422
    assert (await client.get("/api/v1/entries/2026-10-22")).json()["check_out"] == "12:01"
    payload["project_allocations"][0] = {"project_id": 99999, "minutes": 30}
    assert (await client.put("/api/v1/entries/2026-10-22", json=payload)).status_code == 422
    assert (
        await client.put("/api/v1/projects/default", json={"project_id": 99999})
    ).status_code == 422
    # Ownership applies even when an attacker knows a real project ID.
    app = client._transport.app
    original = app.dependency_overrides[get_current_user]
    app.dependency_overrides[get_current_user] = lambda: User(
        id=uuid4(), email="other@example.com", display_name="Other"
    )
    try:
        assert (
            await client.put(f"/api/v1/projects/{x}", json={"name": "Stolen"})
        ).status_code == 422
        assert (
            await client.put("/api/v1/projects/default", json={"project_id": x})
        ).status_code == 422
    finally:
        app.dependency_overrides[get_current_user] = original


async def test_shortening_day_removes_only_automatic_break(client):
    path = "/api/v1/entries/2026-10-22"
    entry = (await client.put(path, json={"check_in": "08:44", "check_out": "17:00"})).json()
    assert entry["breaks"][0]["automatic"] is True
    payload = {"check_in": "08:44", "check_out": "14:16", "breaks": entry["breaks"]}
    short = (await client.put(path, json=payload)).json()
    assert short["break_minutes"] == 0
    assert short["exact_minutes"] == 332
    assert short["billable_minutes"] == 345
    payload["check_out"] = "14:44"
    assert (await client.put(path, json=payload)).json()["break_minutes"] == 0
    payload["breaks"][0]["automatic"] = False
    assert (await client.put(path, json=payload)).json()["break_minutes"] == 30
    fresh = (
        await client.put(
            "/api/v1/entries/2026-10-23", json={"check_in": "08:44", "check_out": "14:45"}
        )
    ).json()
    assert fresh["break_minutes"] == 30


async def test_legacy_editor_preserves_automatic_break_origin(client):
    path = "/api/v1/entries/2026-10-21"
    saved = (await client.put(path, json={"check_in": "08:00", "check_out": "17:00"})).json()
    old_client_breaks = [
        {key: value for key, value in item.items() if key != "automatic"}
        for item in saved["breaks"]
    ]
    shortened = await client.put(
        path, json={"check_in": "08:00", "check_out": "13:32", "breaks": old_client_breaks}
    )
    assert shortened.status_code == 200
    assert shortened.json()["break_minutes"] == 0
    assert shortened.json()["billable_minutes"] == 345
