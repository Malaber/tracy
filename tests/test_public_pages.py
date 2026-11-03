from importlib.metadata import version

import pytest


@pytest.mark.asyncio
async def test_public_store_pages_need_no_login(unauthenticated_client):
    for path, title in [
        ("/app", "Your time, entered simply."),
        ("/support", "Help with Tracy"),
        ("/privacy", "Privacy for Tracy"),
    ]:
        response = await unauthenticated_client.get(path)
        assert response.status_code == 200
        assert '<meta name="apple-itunes-app" content="app-id=6817695924">' in response.text
        assert title in response.text
        assert "mailto:tracy@schaedler.rocks" in response.text
        assert f"https://tracy.malaber.de{path}" in response.text
        assert 'href="/privacy"' in response.text
        assert 'href="/support"' in response.text
    login = await unauthenticated_client.get("/login")
    assert '<meta name="apple-itunes-app" content="app-id=6817695924">' in login.text
    assert 'href="/privacy"' in login.text
    assert f'Tracy {version("tracy")}' in login.text


@pytest.mark.asyncio
async def test_account_deletion_requires_authentication(unauthenticated_client):
    response = await unauthenticated_client.delete("/api/v1/account")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_account_deletion_removes_owned_records(client):
    from sqlalchemy import select
    from app.core.database import get_db
    from app.models import User, WorkEntry, BreakEntry, Preferences

    await client.put("/api/v1/entries/2026-09-30", json={"check_in": "08:00", "check_out": "17:00"})
    assert (await client.delete("/api/v1/account")).status_code == 204
    application = client._transport.app
    async for db in application.dependency_overrides[get_db]():
        for model in (User, WorkEntry, BreakEntry, Preferences):
            assert (await db.execute(select(model))).scalars().all() == []


@pytest.mark.asyncio
async def test_app_page_links_to_published_app(unauthenticated_client):
    response = await unauthenticated_client.get("/app")
    assert 'href="https://apps.apple.com/app/id6817695924"' in response.text
    assert "not yet announced" not in response.text
    assert "app-argument" not in response.text
