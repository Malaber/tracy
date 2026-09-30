import base64
import hashlib
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse
from uuid import uuid4

import pytest
from fastpasskey import FastPasskey
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url


@pytest.mark.asyncio
async def test_offline_revisions_retry_and_conflict(client):
    path = "/api/v1/entries/2026-09-29"
    payload = {"check_in": "08:00", "check_out": "17:00", "notes": "offline"}
    mutation = str(uuid4())
    headers = {"If-Match": "missing", "Idempotency-Key": mutation}
    first = await client.put(path, json=payload, headers=headers)
    assert first.status_code == 200
    assert first.json()["break_minutes"] == 30
    # A lost success response may be retried safely, including the auto-added break.
    retry = await client.put(path, json=payload, headers=headers)
    assert retry.json() == first.json()
    assert retry.json()["client_mutation_id"] == mutation
    stale = await client.put(
        path, json={**payload, "notes": "stale"}, headers={"If-Match": "missing"}
    )
    assert stale.status_code == 409
    updated = await client.put(path, json={**payload, "notes": "web edit"})
    assert updated.status_code == 200
    assert updated.json()["revision"] != first.json()["revision"]
    assert updated.json()["client_mutation_id"] is None
    conflict = await client.put(path, json=payload, headers={"If-Match": first.json()["revision"]})
    assert conflict.status_code == 409
    assert (await client.get(path)).json()["notes"] == "web edit"
    resolved = await client.put(
        path, json=payload, headers={"If-Match": updated.json()["revision"]}
    )
    assert resolved.status_code == 200
    # Break-only edits must also advance the revision.
    break_edit = await client.put(
        path, json={**payload, "breaks": [{"mode": "duration", "duration_minutes": 45}]}
    )
    assert break_edit.json()["revision"] != resolved.json()["revision"]
    await client.delete(path)
    assert (
        await client.put(path, json=payload, headers={"If-Match": break_edit.json()["revision"]})
    ).status_code == 409


@pytest.mark.asyncio
async def test_mobile_browser_login_pkce_exchange_and_revocation(
    unauthenticated_client, monkeypatch
):
    client = unauthenticated_client
    verifier = "v" * 43
    challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    )
    params = {"state": "s" * 43, "code_challenge": challenge}
    redirect = await client.get("/api/v1/auth/mobile/authorize", params=params)
    assert redirect.status_code == 303
    assert redirect.headers["location"].startswith("/login?next=")
    assert (
        await client.get("/api/v1/auth/mobile/authorize", params={**params, "state": "bad"})
    ).status_code == 422

    def fake_registration(self, *, credential, state):
        return SimpleNamespace(
            credential_id=base64url_to_bytes(credential["id"]),
            credential_public_key=b"public-key",
            sign_count=0,
        )

    monkeypatch.setattr(FastPasskey, "verify_registration", fake_registration)
    await client.post(
        "/api/v1/auth/register/options",
        json={"email": "mobile@example.com", "display_name": "Mobile"},
    )
    registration = await client.post(
        "/api/v1/auth/register/verify", json={"credential": {"id": bytes_to_base64url(b"mobile")}}
    )
    assert registration.status_code == 200
    authorized = await client.get("/api/v1/auth/mobile/authorize", params=params)
    assert authorized.status_code == 303
    assert authorized.headers["Cache-Control"] == "no-store"
    callback = urlparse(authorized.headers["location"])
    assert callback.scheme == "de.malaber.tracy"
    query = parse_qs(callback.query)
    assert query["state"] == [params["state"]]
    assert "access_token" not in query
    exchange = {"code": query["code"][0], "code_verifier": verifier}
    assert (
        await client.post("/api/v1/auth/mobile/token", json={**exchange, "code_verifier": "x" * 43})
    ).status_code == 401
    token_response = await client.post("/api/v1/auth/mobile/token", json=exchange)
    assert token_response.status_code == 200
    assert token_response.headers["Cache-Control"] == "no-store"
    assert (await client.post("/api/v1/auth/mobile/token", json=exchange)).status_code == 401
    client.cookies.clear()
    bearer = {"Authorization": "Bearer " + token_response.json()["access_token"]}
    assert (await client.get("/api/v1/preferences", headers=bearer)).status_code == 200
    assert (await client.post("/api/v1/auth/mobile/logout", headers=bearer)).status_code == 204
    assert (await client.get("/api/v1/preferences", headers=bearer)).status_code == 401


@pytest.mark.asyncio
async def test_expired_mobile_code_is_rejected(tmp_path):
    from httpx import ASGITransport, AsyncClient
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
    from app.core.database import Base, get_db
    from app.main import create_app
    from app.models import MobileAuthorization, User

    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'expired.db'}")
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    verifier = "v" * 43
    code = "c" * 43
    async with factory() as db:
        user = User(email="expired@example.com", display_name="Expired")
        db.add(user)
        await db.flush()
        db.add(
            MobileAuthorization(
                code_hash=hashlib.sha256(code.encode()).hexdigest(),
                user_id=user.id,
                challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
                .decode()
                .rstrip("="),
                expires_at=datetime.now(UTC) - timedelta(seconds=1),
            )
        )
        await db.commit()

    async def override_db():
        async with factory() as db:
            yield db

    app = create_app(with_lifespan=False)
    app.dependency_overrides[get_db] = override_db
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/api/v1/auth/mobile/token", json={"code": code, "code_verifier": verifier}
        )
        assert response.status_code == 401
    await engine.dispose()


@pytest.mark.asyncio
async def test_database_revision_prevents_concurrent_overwrite(tmp_path):
    from datetime import date
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
    from sqlalchemy.orm.exc import StaleDataError
    from app.core.database import Base
    from app.models import User, WorkEntry

    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'concurrent.db'}")
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    async with factory() as db:
        user = User(email="concurrent@example.com", display_name="Concurrent")
        db.add(user)
        await db.flush()
        entry = WorkEntry(user_id=user.id, work_date=date(2026, 9, 29), notes="Original")
        db.add(entry)
        await db.commit()
        entry_id = entry.id
    async with factory() as first, factory() as second:
        first_entry = await first.get(WorkEntry, entry_id)
        second_entry = await second.get(WorkEntry, entry_id)
        first_entry.notes = "First saved edit"
        await first.commit()
        second_entry.notes = "Stale concurrent edit"
        with pytest.raises(StaleDataError):
            await second.commit()
        await second.rollback()
        assert (await second.get(WorkEntry, entry_id)).notes == "First saved edit"
    await engine.dispose()
