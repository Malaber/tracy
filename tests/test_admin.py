import asyncio
import re
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from fastpasskey import FastPasskey, PasskeyCredential
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url

from app.core.database import Base, get_db
from app.main import create_app
from app.models import Passkey, PasskeyAddLink, User
from app.services.passkey_links import issue_link, token_hash
from app.services.passkey_repository import TracyPasskeyRepository


@pytest.fixture
async def admin_env(tmp_path, monkeypatch):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'admin.db'}")
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    async def db_dependency():
        async with factory() as db:
            yield db

    def registration(self, *, credential, state):
        return SimpleNamespace(
            credential_id=base64url_to_bytes(credential["id"]),
            credential_public_key=b"key",
            sign_count=0,
        )

    monkeypatch.setattr(FastPasskey, "verify_registration", registration)
    app = create_app(with_lifespan=False, admin_session_maker=factory)
    app.dependency_overrides[get_db] = db_dependency
    async with AsyncClient(transport=ASGITransport(app), base_url="http://test") as client:
        yield client, factory
    await engine.dispose()


async def register(client, email="owner@example.com"):
    await client.post(
        "/api/v1/auth/register/options", json={"email": email, "display_name": "Owner"}
    )
    response = await client.post(
        "/api/v1/auth/register/verify",
        json={"credential": {"id": bytes_to_base64url(email.encode())}},
    )
    assert response.status_code == 200, response.text
    return response.json()["id"]


async def promote(client, factory):
    user_id = await register(client)
    async with factory() as db:
        user = await db.scalar(select(User).where(User.email == "owner@example.com"))
        user.is_admin = True
        await db.commit()
    return user_id


def csrf(html):
    return re.search(r'name="csrf" value="([^"]+)"', html).group(1)


def token_from(html):
    return re.search(
        r'id="generated-link"[^>]+value="http://test/passkey-add/([^"#]+)#identifier=[^"]+"', html
    ).group(1)


async def test_admin_guards_creation_and_link_lifecycle(admin_env):
    client, factory = admin_env
    assert (await client.get("/admin/user/create")).status_code == 303
    await register(client)
    assert (await client.get("/admin/user/create")).status_code == 403
    assert (await client.post("/admin/user/create", data={})).status_code == 403
    async with factory() as db:
        owner = await db.scalar(select(User))
        owner.is_admin = True
        await db.commit()
    page = await client.get("/admin/user/create")
    assert page.headers["cache-control"] == "no-store"
    form_token = csrf(page.text)
    assert (await client.post("/admin/user/create", data={"email": "x"})).status_code == 403
    assert (
        await client.post("/admin/user/create", data={"csrf": form_token, "email": "invalid"})
    ).status_code == 400
    fields = {"csrf": form_token, "email": "review@example.com", "display_name": "Apple Review"}
    assert (await client.post("/admin/user/create", data=fields)).status_code == 302
    assert (await client.post("/admin/user/create", data=fields)).status_code == 400
    async with factory() as db:
        review = await db.scalar(select(User).where(User.email == "review@example.com"))
        assert not review.is_admin
        review_id = review.id
    url = f"/admin/user/{review_id}/passkey-add-link"
    assert (await client.post(url, data={"csrf": form_token, "hours": "0"})).status_code == 400
    assert (await client.post(url, data={"csrf": form_token, "hours": "721"})).status_code == 400
    assert (await client.post(url, data={"csrf": form_token, "hours": "x"})).status_code == 400
    assert (
        await client.post(
            f"/admin/user/{uuid4()}/passkey-add-link", data={"csrf": form_token, "hours": "24"}
        )
    ).status_code == 404
    response = await client.post(url, data={"csrf": form_token, "hours": "720"})
    token = token_from(response.text)
    assert token not in (await client.get("/admin/user/create")).text
    async with factory() as db:
        link = await db.scalar(select(PasskeyAddLink))
        assert link.token_hash == token_hash(token)
        link_id = link.id
    landing = await client.get(f"/passkey-add/{token}")
    assert landing.status_code == 200
    assert landing.headers["referrer-policy"] == "no-referrer"
    assert "Create passkey" in landing.text
    assert (
        await client.post(f"/admin/passkey-add-link/{link_id}/revoke", data={"csrf": form_token})
    ).status_code == 303
    assert (await client.get(f"/passkey-add/{token}")).status_code == 404
    assert (await client.post(f"/api/v1/auth/passkey-add/{token}/options")).status_code == 404
    async with factory() as db:
        review = await db.get(User, review_id)
        review.is_active = False
        await db.commit()
    assert (await client.post(url, data={"csrf": form_token, "hours": "24"})).status_code == 400


async def test_enrollment_preserves_keys_and_consumes_only_after_valid_ceremony(
    admin_env, monkeypatch
):
    client, factory = admin_env
    await promote(client, factory)
    token_csrf = csrf((await client.get("/admin/user/create")).text)
    async with factory() as db:
        owner = await db.scalar(select(User))
        user_id = owner.id
    response = await client.post(
        f"/admin/user/{user_id}/passkey-add-link", data={"csrf": token_csrf, "hours": 24}
    )
    token = token_from(response.text)
    await client.post("/logout")
    base = f"/api/v1/auth/passkey-add/{token}"
    assert (
        await client.post(base + "/verify", json={"credential": {"id": "abcd"}})
    ).status_code == 400
    options = await client.post(base + "/options")
    assert options.status_code == 200
    assert options.json()["authenticatorSelection"]["userVerification"] == "required"
    with monkeypatch.context() as patch:

        def fail(*args, **kwargs):
            raise ValueError("Invalid signature")

        patch.setattr(FastPasskey, "verify_registration", fail)
        assert (
            await client.post(base + "/verify", json={"credential": {"id": "abcd"}})
        ).status_code == 400
    credential = bytes_to_base64url(b"apple-review-key")
    result = await client.post(base + "/verify", json={"credential": {"id": credential}})
    assert result.status_code == 200, result.text
    assert result.json()["id"] == str(user_id)
    assert (await client.get("/")).status_code == 200
    assert (await client.post(base + "/options")).status_code == 404
    async with factory() as db:
        keys = (await db.scalars(select(Passkey).where(Passkey.user_id == user_id))).all()
        assert len(keys) == 2
        assert (await db.scalar(select(PasskeyAddLink))).used_at is not None
    # Account deletion removes enrollment secrets, even with SQLite foreign keys disabled.
    assert (await client.delete("/api/v1/account")).status_code == 204
    async with factory() as db:
        assert await db.scalar(select(PasskeyAddLink)) is None


async def test_link_atomic_claim_expiry_revocation_and_rollback(admin_env):
    _, factory = admin_env
    async with factory() as db:
        user = User(email="target@example.com", display_name="Target")
        other = User(email="other@example.com", display_name="Other")
        db.add_all([user, other])
        await db.commit()
        user_id, other_id = user.id, other.id
        token, link = await issue_link(db, user, admin_id=user.id, hours=24)
        link_id = link.id
        repo = TracyPasskeyRepository(db)
        assert (
            await repo.complete_add_link(
                token=token,
                user_id=other_id,
                name="Wrong",
                credential=PasskeyCredential(
                    credential_id="wrong", public_key=b"key", sign_count=0
                ),
            )
            is None
        )

    async def redeem(identifier):
        async with factory() as db:
            return await TracyPasskeyRepository(db).complete_add_link(
                token=token,
                user_id=user_id,
                name=identifier,
                credential=PasskeyCredential(
                    credential_id=identifier, public_key=b"key", sign_count=0
                ),
            )

    results = await asyncio.gather(redeem("first"), redeem("second"))
    assert sum(result is not None for result in results) == 1
    async with factory() as db:
        user = await db.get(User, user_id)
        token, link = await issue_link(db, user, admin_id=user_id, hours=24)
        key = await db.scalar(select(Passkey))
        # Failed insert rolls back the consumed marker.
        assert (
            await TracyPasskeyRepository(db).complete_add_link(
                token=token,
                user_id=user_id,
                name="Duplicate",
                credential=PasskeyCredential(
                    credential_id=key.credential_id, public_key=b"key", sign_count=0
                ),
            )
            is None
        )
        assert await TracyPasskeyRepository(db).add_link_user(token) is not None
        link = await db.scalar(
            select(PasskeyAddLink).where(PasskeyAddLink.token_hash == token_hash(token))
        )
        link.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        await db.commit()
        assert await TracyPasskeyRepository(db).add_link_user(token) is None
        link.expires_at = datetime.now(UTC) + timedelta(hours=1)
        link.revoked_at = datetime.now(UTC)
        await db.commit()
        assert await TracyPasskeyRepository(db).add_link_user(token) is None
        assert await db.get(PasskeyAddLink, link_id) is not None


async def test_admin_bootstrap_requires_existing_active_account(admin_env, monkeypatch):
    from app.services import admin_access

    client, factory = admin_env
    monkeypatch.setattr(admin_access, "AsyncSessionLocal", factory)
    with pytest.raises(ValueError):
        await admin_access.set_admin("missing@example.com")
    await register(client)
    await admin_access.set_admin("OWNER@example.com")
    assert (await client.get("/admin/user/create")).status_code == 200
    await admin_access.set_admin("owner@example.com", revoke=True)
    assert (await client.get("/admin/user/create")).status_code == 403


async def test_pending_ceremony_cannot_bypass_revocation_or_disabled_user(admin_env):
    client, factory = admin_env
    await promote(client, factory)
    async with factory() as db:
        owner = await db.scalar(select(User))
        user_id = owner.id
        token, link = await issue_link(db, owner, admin_id=user_id, hours=24)
        link_id = link.id
    await client.post("/logout")
    base = f"/api/v1/auth/passkey-add/{token}"
    assert (await client.post(base + "/options")).status_code == 200
    async with factory() as db:
        link = await db.get(PasskeyAddLink, link_id)
        link.revoked_at = datetime.now(UTC)
        await db.commit()
    assert (
        await client.post(base + "/verify", json={"credential": {"id": "abcd"}})
    ).status_code == 404
    async with factory() as db:
        owner = await db.get(User, user_id)
        token, link = await issue_link(db, owner, admin_id=user_id, hours=24)
        owner.is_active = False
        await db.commit()
    assert (await client.get(f"/passkey-add/{token}")).status_code == 404
    assert (await client.post(f"/api/v1/auth/passkey-add/{token}/options")).status_code == 404


async def test_admin_forms_reject_cross_session_and_non_ascii_tokens(admin_env):
    client, factory = admin_env
    await promote(client, factory)
    await client.get("/admin/user/create")
    for value in ("other-session", "🔑"):
        response = await client.post(
            "/admin/user/create",
            data={"csrf": value, "email": "evil@example.com", "display_name": "Injected"},
        )
        assert response.status_code == 403
    async with factory() as db:
        assert await db.scalar(select(User).where(User.email == "evil@example.com")) is None


async def test_sqladmin_paginates_searches_and_caps_large_requests(admin_env):
    client, factory = admin_env
    await promote(client, factory)
    async with factory() as db:
        accounts = [
            User(email=f"bulk{i:04}@example.com", display_name=f"Bulk {i:04}") for i in range(1005)
        ]
        db.add_all(accounts)
        await db.flush()
        account_id = accounts[0].id
        links = [
            PasskeyAddLink(
                user_id=account_id,
                token_hash=token_hash(f"bulk{i}"),
                expires_at=datetime.now(UTC) + timedelta(hours=1),
            )
            for i in range(105)
        ]
        db.add_all(links)
        await db.commit()
        link_id = links[-1].id
    first = await client.get("/admin/user/list")
    second = await client.get("/admin/user/list?page=2")
    assert first.status_code == second.status_code == 200
    assert "bulk0000@example.com" in first.text and "bulk0025@example.com" not in first.text
    assert "bulk0025@example.com" in second.text and "bulk0000@example.com" not in second.text
    assert len(set(re.findall(r"bulk\d{4}@example.com", first.text))) == 25
    capped = await client.get("/admin/user/list?pageSize=1000000")
    assert len(set(re.findall(r"bulk\d{4}@example.com", capped.text))) == 100
    search = await client.get("/admin/user/list?search=bulk1004")
    assert "bulk1004@example.com" in search.text and "bulk0000@example.com" not in search.text
    by_name = await client.get("/admin/user/list?search=Bulk+1003")
    assert "bulk1003@example.com" in by_name.text
    history = await client.get(f"/admin/passkey-add-link/list?search={account_id}")
    tbody = history.text.split("<tbody>")[1].split("</tbody>")[0]
    assert tbody.count("<tr>") == 25
    found = await client.get(f"/admin/passkey-add-link/list?search={link_id}")
    assert str(link_id) in found.text
    assert found.text.split("<tbody>")[1].split("</tbody>")[0].count("<tr>") == 1
    assert "token_hash" not in found.text
    details = await client.get(f"/admin/user/details/{account_id}")
    assert "View this account" in details.text
    # History is not loaded inline on an account page.
    assert str(link_id) not in details.text
    assert (await client.get("/admin/")).headers["location"].endswith("/admin/user/list")


async def test_sqladmin_fragment_matches_searchable_record_and_routes_are_guarded(admin_env):
    client, factory = admin_env
    user_id = await promote(client, factory)
    token_csrf = csrf((await client.get(f"/admin/user/details/{user_id}")).text)
    created = await client.post(
        f"/admin/user/{user_id}/passkey-add-link", data={"csrf": token_csrf, "hours": 24}
    )
    identifier = re.search(r"#identifier=([0-9a-f-]{36})", created.text).group(1)
    async with factory() as db:
        link = await db.get(PasskeyAddLink, UUID(identifier))
        assert link.token_hash == token_hash(token_from(created.text))
    detail = await client.get(f"/admin/passkey-add-link/details/{identifier}")
    assert identifier in detail.text and "Revoke link" in detail.text
    assert "token_hash" not in detail.text
    assert (
        await client.post("/admin/user/not-a-uuid/passkey-add-link", data={"csrf": token_csrf})
    ).status_code == 404
    assert (
        await client.post("/admin/passkey-add-link/not-a-uuid/revoke", data={"csrf": token_csrf})
    ).status_code == 404
    await client.post("/logout")
    for route in [
        "/admin/user/list",
        "/admin/passkey-add-link/list",
        f"/admin/user/details/{user_id}",
    ]:
        assert (await client.get(route)).status_code == 303
    assert (
        await client.post(f"/admin/passkey-add-link/{identifier}/revoke", data={"csrf": token_csrf})
    ).status_code == 303


async def test_admin_logout_confirms_before_revoking_session(admin_env):
    client, factory = admin_env
    await promote(client, factory)
    response = await client.get("/admin/logout")
    assert response.status_code == 200 and "Sign out of Tracy?" in response.text
    assert (await client.get("/admin/user/list")).status_code == 200
    await client.post("/logout")
    assert (await client.get("/admin/user/list")).status_code == 303
