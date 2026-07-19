from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import HTTPException
from fastpasskey import FastPasskey, PasskeyConflictError, PasskeyCredential
from jose import jwt
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from starlette.requests import Request
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url

from app.api.deps import get_current_user
from app.api.v1.auth import _passkey_service
from app.core.config import Settings, settings
from app.core.database import Base
from app.core.security import create_access_token
from app.models import Preferences, User, WorkEntry
from app.services.auth_sessions import (
    AUTH_SESSION_ID_KEY,
    create_auth_session,
    get_session_user,
    revoke_auth_session,
)
from app.services.passkey_repository import TracyPasskeyRepository


def _request(session: dict | None = None) -> Request:
    return Request(
        {
            "type": "http",
            "method": "GET",
            "scheme": "http",
            "path": "/",
            "server": ("test", 80),
            "headers": [(b"host", b"test")],
            "session": session if session is not None else {},
        }
    )


@pytest.fixture
async def auth_db(tmp_path):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'auth.db'}")
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    async with session_factory() as session:
        yield session
    await engine.dispose()


@pytest.mark.asyncio
async def test_passkey_registration_login_and_user_data_isolation(
    unauthenticated_client, monkeypatch
):
    def fake_registration(self, *, credential, state):
        return SimpleNamespace(
            credential_id=base64url_to_bytes(credential["id"]),
            credential_public_key=b"public-key",
            sign_count=0,
        )

    def fake_authentication(self, **_kwargs):
        return SimpleNamespace(new_sign_count=1)

    monkeypatch.setattr(FastPasskey, "verify_registration", fake_registration)
    monkeypatch.setattr(FastPasskey, "verify_authentication", fake_authentication)

    first_id = bytes_to_base64url(b"first-credential")
    options = await unauthenticated_client.post(
        "/api/v1/auth/register/options",
        json={"email": "first@example.com", "display_name": "First User"},
    )
    assert options.status_code == 200
    assert options.json()["authenticatorSelection"]["residentKey"] == "required"
    registered = await unauthenticated_client.post(
        "/api/v1/auth/register/verify",
        json={"credential": {"id": first_id}},
    )
    assert registered.status_code == 200, registered.text
    assert registered.json()["email"] == "first@example.com"
    assert "Track your working day" in (await unauthenticated_client.get("/")).text
    assert (await unauthenticated_client.get("/security")).status_code == 200

    work_date = "2026-07-19"
    saved = await unauthenticated_client.put(
        f"/api/v1/entries/{work_date}",
        json={"check_in": "08:00", "check_out": "09:00", "breaks": [], "notes": "first"},
    )
    assert saved.status_code == 200

    assert (await unauthenticated_client.post("/logout")).status_code == 303
    assert (await unauthenticated_client.get("/api/v1/preferences")).status_code == 401

    second_id = bytes_to_base64url(b"second-credential")
    await unauthenticated_client.post(
        "/api/v1/auth/register/options",
        json={"email": "second@example.com", "display_name": "Second User"},
    )
    registered = await unauthenticated_client.post(
        "/api/v1/auth/register/verify",
        json={"credential": {"id": second_id}},
    )
    assert registered.status_code == 200, registered.text
    second_entry = await unauthenticated_client.get(f"/api/v1/entries/{work_date}")
    assert second_entry.json()["saved"] is False

    await unauthenticated_client.post("/api/v1/auth/logout")
    await unauthenticated_client.post("/api/v1/auth/login/options", json={})
    logged_in = await unauthenticated_client.post(
        "/api/v1/auth/login/verify",
        json={"credential": {"id": first_id}},
    )
    assert logged_in.status_code == 200, logged_in.text
    assert jwt.decode(
        logged_in.json()["access_token"], settings.secret_key, algorithms=[settings.algorithm]
    )["sub"]
    first_entry = await unauthenticated_client.get(f"/api/v1/entries/{work_date}")
    assert first_entry.json()["notes"] == "first"


@pytest.mark.asyncio
async def test_repository_adopts_legacy_rows_and_manages_passkeys(auth_db):
    legacy_preferences = Preferences(id=1)
    legacy_entry = WorkEntry(work_date=datetime(2026, 7, 18).date())
    auth_db.add_all([legacy_preferences, legacy_entry])
    await auth_db.commit()

    repository = TracyPasskeyRepository(auth_db)
    first_credential = PasskeyCredential(
        credential_id="first", public_key=b"first-key", sign_count=0
    )
    user = await repository.register_user(
        user_id=uuid4(),
        email="owner@example.com",
        display_name="Owner",
        passkey_name="Laptop",
        credential=first_credential,
    )
    await auth_db.refresh(legacy_preferences)
    await auth_db.refresh(legacy_entry)
    assert legacy_preferences.user_id == user.id
    assert legacy_entry.user_id == user.id
    assert (await repository.user_by_email(user.email)).id == user.id
    assert (await repository.passkey_by_credential_id("first")).user.id == user.id

    second = await repository.add_passkey(
        user_id=user.id,
        name="Phone",
        credential=PasskeyCredential(
            credential_id="second", public_key=b"second-key", sign_count=2
        ),
    )
    await repository.record_passkey_use(second, new_sign_count=3)
    assert second.sign_count == 3
    renamed = await repository.rename_passkey(second, name="Mobile", new_sign_count=4)
    assert renamed.name == "Mobile"

    first = await repository.passkey_by_credential_id("first")
    await repository.delete_passkey(
        user_id=user.id,
        passkey_id=second.id,
        confirming_passkey=first,
        new_sign_count=5,
    )
    assert await repository.passkey_by_credential_id("second") is None
    replaced = await repository.replace_passkeys(
        user_id=user.id,
        passkey_name="Replacement",
        credential=PasskeyCredential(
            credential_id="replacement", public_key=b"replacement-key", sign_count=0
        ),
    )
    assert [entry.name for entry in replaced.passkeys] == ["Replacement"]
    assert await repository.add_link_user("unsupported") is None
    assert (
        await repository.complete_add_link(
            token="unsupported",
            user_id=user.id,
            name="Ignored",
            credential=first_credential,
        )
        is None
    )

    request = _request()
    assert await repository.authenticate(request, user) is user
    assert AUTH_SESSION_ID_KEY in request.session
    assert jwt.decode(
        repository.access_token(user), settings.secret_key, algorithms=[settings.algorithm]
    )["sub"] == str(user.id)
    await repository.logout(request)
    assert AUTH_SESSION_ID_KEY not in request.session

    with pytest.raises(PasskeyConflictError):
        await repository.register_user(
            user_id=uuid4(),
            email=user.email,
            display_name="Duplicate",
            passkey_name="Duplicate",
            credential=PasskeyCredential(
                credential_id="duplicate", public_key=b"duplicate", sign_count=0
            ),
        )


@pytest.mark.asyncio
async def test_auth_sessions_and_current_user_guard_invalid_state(auth_db):
    user = User(email="session@example.com", display_name="Session User")
    auth_db.add(user)
    await auth_db.commit()
    await auth_db.refresh(user)

    request = _request()
    auth_session = await create_auth_session(request, auth_db, user)
    assert (await get_session_user(request, auth_db)).id == user.id
    assert (await get_current_user(request, auth_db, None)).id == user.id

    token = create_access_token(user.id)
    assert (await get_current_user(_request(), auth_db, token)).id == user.id
    with pytest.raises(HTTPException) as invalid_token:
        await get_current_user(_request(), auth_db, "not-a-token")
    assert invalid_token.value.status_code == 401

    auth_session.expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await auth_db.commit()
    assert await get_session_user(request, auth_db) is None
    assert AUTH_SESSION_ID_KEY not in request.session

    malformed = _request({AUTH_SESSION_ID_KEY: "invalid"})
    assert await get_session_user(malformed, auth_db) is None
    await revoke_auth_session(malformed, auth_db)
    with pytest.raises(HTTPException):
        await get_current_user(_request(), auth_db, None)

    missing = _request({AUTH_SESSION_ID_KEY: str(uuid4())})
    assert await get_session_user(missing, auth_db) is None
    await revoke_auth_session(_request(), auth_db)


def test_auth_configuration_and_service_resolution():
    assert Settings(app_base_url="   ").app_base_url is None
    assert Settings(app_base_url="https://tracy.example/").app_base_url == "https://tracy.example"
    for invalid_origin in ("not-a-url", "https://tracy.example/path"):
        with pytest.raises(ValueError):
            Settings(app_base_url=invalid_origin)
    with pytest.raises(ValueError):
        Settings(secret_key="too-short")
    service = _passkey_service()
    assert service.rp_name == settings.app_name
    assert service.flow_ttl == timedelta(seconds=settings.auth_flow_expire_seconds)
